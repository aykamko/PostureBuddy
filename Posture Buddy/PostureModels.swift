import CoreGraphics
import Vision

// MARK: - Pose frame data

struct DetectedPose {
    let keypoints: [VNHumanBodyPoseObservation.JointName: CGPoint]
    let faceLandmarks: FaceLandmarks?  // nil if no face detected
    let score: PostureScore?           // nil until user calibrates
}

// Face landmarks in Vision's image-normalized coordinates (0-1, y-up from bottom).
// Points are already transformed out of the bounding box's local space.
struct FaceLandmarks {
    let points: [CGPoint]        // all face landmarks (eye outlines, nose, lips, contour, etc.)
    let boundingBox: CGRect      // image-normalized face box
}

// MARK: - Posture score

struct PostureScore {
    let value: Float
    let grade: Grade

    enum Grade {
        case good, fair, poor

        nonisolated var color: (red: Double, green: Double, blue: Double) {
            switch self {
            case .good: return (0.2, 0.8, 0.3)
            case .fair: return (1.0, 0.8, 0.0)
            case .poor: return (0.9, 0.2, 0.2)
            }
        }

        nonisolated var label: String {
            switch self {
            case .good: return "good"
            case .fair: return "fair"
            case .poor: return "poor"
            }
        }
    }

    nonisolated init(value: Float) {
        self.value = value
        switch value {
        case 80...: grade = .good
        case 60..<80: grade = .fair
        default: grade = .poor
        }
    }
}

// MARK: - Angles and baselines

// A snapshot of the side-profile angles + head-yaw signature for one frame.
// Baseline = same struct captured during calibration at one head position.
struct PostureAngles {
    let earShoulderAngle: Float       // degrees from image-vertical
    let shoulderHipAngle: Float?      // nil if hip was occluded
    // 2D head-position signature used at runtime to pick which calibrated baseline
    // to score against. Nil if face wasn't detected.
    let yawSignature: YawSignature?
}

// 2D head-position signature. `direction` captures left/right rotation (from the
// face median-line position within the bbox). `frontality` captures how much of the
// face is visible to the camera (from body-pose ear-confidence symmetry). Together
// they separate head positions that would collapse in a single-axis yaw measure.
// Built on the video-processing thread; never needs the main actor.
nonisolated struct YawSignature {
    let direction: Float   // ~[-0.5, +0.5], 0 = face midline at bbox center
    let frontality: Float  // [0, 1], 0 = deep profile (one ear), 1 = frontal (both ears equally visible)

    /// Compact debug representation, e.g. `dir=+0.123 front=0.45`.
    var debugString: String {
        String(format: "dir=%+.3f front=%.2f", direction, frontality)
    }

    func distance(to other: YawSignature) -> Float {
        let dd = direction - other.direction
        let df = frontality - other.frontality
        return sqrtf(dd * dd + df * df)
    }

    /// Builds a signature from a face observation (for `direction`) and a body-pose
    /// observation (for `frontality`). Returns nil if the face detector didn't give
    /// us enough landmarks to estimate direction.
    static func from(
        face: VNFaceObservation?,
        body: VNHumanBodyPoseObservation
    ) -> YawSignature? {
        guard let face, let direction = directionComponent(from: face) else { return nil }
        return YawSignature(direction: direction, frontality: frontalityComponent(from: body))
    }

    /// Face median-line horizontal offset within the bbox. Roughly [-0.5, +0.5].
    /// Captures left/right head rotation.
    private static func directionComponent(from observation: VNFaceObservation) -> Float? {
        // Prefer medianLine (full face centerline, more robust average); fall back to
        // noseCrest (nose bridge, still a good yaw signal).
        let region = observation.landmarks?.medianLine ?? observation.landmarks?.noseCrest
        guard let points = region?.normalizedPoints, !points.isEmpty else { return nil }
        let avgX = points.reduce(Float(0)) { $0 + Float($1.x) } / Float(points.count)
        return avgX - 0.5
    }

    /// Ratio of ear confidences from the body pose model. [0, 1]. Near 0 = deep side
    /// profile (one ear visible); closer to 1 = head turned toward camera (both ears
    /// visible). Separates "clean side profile" from "3/4 view" when the median line
    /// offset barely moves between them.
    private static func frontalityComponent(from observation: VNHumanBodyPoseObservation) -> Float {
        let leftConf = (try? observation.recognizedPoint(.leftEar))?.confidence ?? 0
        let rightConf = (try? observation.recognizedPoint(.rightEar))?.confidence ?? 0
        let maxConf = max(leftConf, rightConf)
        guard maxConf > 0 else { return 0 }
        return min(leftConf, rightConf) / maxConf
    }
}

// Three calibrated baselines corresponding to the user looking at the middle,
// left, and right of their screen. At runtime the current frame's yawSignature
// is matched to the closest baseline.
struct PostureBaselines {
    let middle: PostureAngles
    let left: PostureAngles
    let right: PostureAngles
}

enum CalibrationPosition: String {
    case middle, left, right
}
