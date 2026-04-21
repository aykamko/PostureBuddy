import AVFoundation
import Vision
import Combine
import os

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
    let yawDegrees: Float?       // head yaw for debugging display
}

final class PoseEstimator: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    @Published var currentPose: DetectedPose?
    @Published var isCalibrated: Bool = false
    @Published var isTrackingReady: Bool = false

    nonisolated private let analyzer = PostureAnalyzer()
    private let lastProcessedTime = OSAllocatedUnfairLock(initialState: CFTimeInterval(0))
    private let smoothedScore = OSAllocatedUnfairLock(initialState: Float(100))
    private let visionOrientation = OSAllocatedUnfairLock(initialState: CGImagePropertyOrientation.leftMirrored)
    private let lastLogTime = OSAllocatedUnfairLock(initialState: CFTimeInterval(0))

    // Most-recent per-frame angles (for calibration capture)
    private let currentAngles = OSAllocatedUnfairLock<PostureAngles?>(initialState: nil)
    // Calibrated references (middle / left / right); nil until user completes calibration
    private let baselines = OSAllocatedUnfairLock<PostureBaselines?>(initialState: nil)

    func updateOrientation(_ orientation: CGImagePropertyOrientation) {
        visionOrientation.withLock { $0 = orientation }
    }

    /// Returns the most-recent frame's computed angles, or nil if the current frame
    /// didn't yield a valid pose. Used by the calibration flow to snapshot per-position.
    func snapshotCurrentAngles() -> PostureAngles? {
        currentAngles.withLock { $0 }
    }

    /// Commits the three-position baselines (after guided calibration completes).
    func calibrate(middle: PostureAngles, left: PostureAngles, right: PostureAngles) {
        let b = PostureBaselines(middle: middle, left: left, right: right)
        baselines.withLock { $0 = b }
        smoothedScore.withLock { $0 = 100 }
        isCalibrated = true
        func format(_ s: YawSignature?) -> String {
            guard let s else { return "nil" }
            return String(format: "(dir=%+.3f front=%.2f)", s.direction, s.frontality)
        }
        print("[Posture] calibrated 3 positions  middle=\(format(middle.yawSignature))  left=\(format(left.yawSignature))  right=\(format(right.yawSignature))")
    }

    func clearCalibration() {
        baselines.withLock { $0 = nil }
        isCalibrated = false
    }

    nonisolated func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        let now = CACurrentMediaTime()

        let shouldProcess = lastProcessedTime.withLock { lastTime in
            guard now - lastTime >= 0.1 else { return false }
            lastTime = now
            return true
        }
        guard shouldProcess else { return }

        let bodyRequest = VNDetectHumanBodyPoseRequest()
        let faceRequest = VNDetectFaceLandmarksRequest()
        faceRequest.revision = VNDetectFaceLandmarksRequest.currentRevision
        let orientation = visionOrientation.withLock { $0 }
        let handler = VNImageRequestHandler(cmSampleBuffer: sampleBuffer, orientation: orientation)
        try? handler.perform([bodyRequest, faceRequest])

        guard let observation = bodyRequest.results?.first else { return }

        // 2D yaw signature.
        //   • direction = face median-line offset within the bbox (left/right)
        //   • frontality = body-pose ear-confidence symmetry (how much face is visible)
        // Vision's `VNFaceObservation.yaw` property is quantized to 45° even at revision 3+,
        // so we compute both components ourselves.
        let yawSignature: YawSignature? = {
            guard let faceObs = faceRequest.results?.first,
                  let direction = Self.computeYawDirection(from: faceObs)
            else { return nil }
            let frontality = Self.computeFrontality(from: observation)
            return YawSignature(direction: direction, frontality: frontality)
        }()

        let shouldLog = lastLogTime.withLock { last in
            guard now - last >= 2.0 else { return false }
            last = now
            return true
        }

        let angles = analyzer.computeAngles(observation, yawSignature: yawSignature)
        currentAngles.withLock { $0 = angles }

        let currentBaselines = baselines.withLock { $0 }

        // Compute score only if calibrated AND analyzer can classify the head position
        let finalScore: PostureScore?
        var matchedPosition: CalibrationPosition?
        if let angles, let currentBaselines, let raw = analyzer.score(current: angles, baselines: currentBaselines) {
            let smoothed = smoothedScore.withLock { current in
                let new = 0.8 * current + 0.2 * raw.score.value
                current = new
                return PostureScore(value: new)
            }
            finalScore = smoothed
            matchedPosition = raw.position
        } else {
            finalScore = nil
        }

        if shouldLog {
            let yawStr: String
            if let ys = yawSignature {
                yawStr = String(format: "dir=%+.3f front=%.2f", ys.direction, ys.frontality)
            } else {
                yawStr = "n/a"
            }
            if let finalScore, let matchedPosition {
                print("[Posture] score=\(String(format: "%.1f", finalScore.value)) [\(finalScore.grade.label)] mode=\(matchedPosition.rawValue) yaw=\(yawStr)")
            } else if currentBaselines != nil && angles != nil {
                print("[Posture] paused — head position not recognized  yaw=\(yawStr)")
            } else if angles != nil {
                print("[Posture] angles available; awaiting calibration  yaw=\(yawStr)")
            } else {
                print("[Posture] no valid keypoints")
            }
        }

        let keypoints = extractKeypoints(from: observation)
        let faceLandmarks = Self.extractFaceLandmarks(from: faceRequest.results?.first)
        let pose = DetectedPose(keypoints: keypoints, faceLandmarks: faceLandmarks, score: finalScore)
        let hasValidAngles = angles != nil

        Task { @MainActor in
            self.currentPose = pose
            if hasValidAngles && !self.isTrackingReady {
                self.isTrackingReady = true
            }
        }
    }

    nonisolated private func extractKeypoints(
        from observation: VNHumanBodyPoseObservation
    ) -> [VNHumanBodyPoseObservation.JointName: CGPoint] {
        let joints: [VNHumanBodyPoseObservation.JointName] = [
            .nose, .leftEye, .rightEye,
            .leftEar, .rightEar,
            .neck,
            .leftShoulder, .rightShoulder,
            .leftElbow, .rightElbow,
            .leftWrist, .rightWrist,
            .leftHip, .rightHip,
            .leftKnee, .rightKnee,
            .leftAnkle, .rightAnkle,
            .root
        ]
        var result: [VNHumanBodyPoseObservation.JointName: CGPoint] = [:]
        for joint in joints {
            if let pt = try? observation.recognizedPoint(joint), pt.confidence >= 0.3 {
                result[joint] = pt.location
            }
        }
        return result
    }

    /// Yaw "direction" component: face median-line horizontal offset within the bbox.
    /// Roughly [-0.5, +0.5] — 0 means face midline is at the bbox center.
    /// Captures left/right head rotation but NOT frontality (center vs. 3/4 view both
    /// have their midline near the bbox edge).
    nonisolated private static func computeYawDirection(from observation: VNFaceObservation) -> Float? {
        // Prefer medianLine (runs the full face centerline, more robust average) and
        // fall back to noseCrest (nose bridge, still a good yaw signal).
        let region = observation.landmarks?.medianLine ?? observation.landmarks?.noseCrest
        guard let points = region?.normalizedPoints, !points.isEmpty else { return nil }
        let avgX = points.reduce(Float(0)) { $0 + Float($1.x) } / Float(points.count)
        return avgX - 0.5
    }

    /// Yaw "frontality" component: ratio of ear confidences from the body pose model.
    /// Ranges [0, 1]. Near 0 = deep side profile (only one ear visible); closer to 1 =
    /// head turned toward camera (both ears visible). This is the signal that separates
    /// "clean side profile" from "3/4 view toward camera" when the median line offset
    /// barely moves between them.
    nonisolated private static func computeFrontality(from observation: VNHumanBodyPoseObservation) -> Float {
        let leftConf = (try? observation.recognizedPoint(.leftEar))?.confidence ?? 0
        let rightConf = (try? observation.recognizedPoint(.rightEar))?.confidence ?? 0
        let maxConf = max(leftConf, rightConf)
        guard maxConf > 0 else { return 0 }
        return min(leftConf, rightConf) / maxConf
    }

    // Converts face landmark region points (which are in bbox-local normalized coords)
    // into image-normalized coords so the overlay can draw them in the same coordinate
    // system as the body skeleton.
    nonisolated private static func extractFaceLandmarks(from observation: VNFaceObservation?) -> FaceLandmarks? {
        guard let observation else { return nil }
        let bbox = observation.boundingBox
        let yawDeg: Float? = observation.yaw.map { $0.floatValue * 180 / .pi }
        let points: [CGPoint]
        if let all = observation.landmarks?.allPoints {
            points = all.normalizedPoints.map { p in
                CGPoint(
                    x: bbox.origin.x + CGFloat(p.x) * bbox.width,
                    y: bbox.origin.y + CGFloat(p.y) * bbox.height
                )
            }
        } else {
            points = []
        }
        return FaceLandmarks(points: points, boundingBox: bbox, yawDegrees: yawDeg)
    }
}
