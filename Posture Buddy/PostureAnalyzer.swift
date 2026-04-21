import Vision

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
struct YawSignature {
    let direction: Float   // ~[-0.5, +0.5], 0 = face midline at bbox center
    let frontality: Float  // [0, 1], 0 = deep profile (one ear), 1 = frontal (both ears equally visible)

    func distance(to other: YawSignature) -> Float {
        let dd = direction - other.direction
        let df = frontality - other.frontality
        return sqrtf(dd * dd + df * df)
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

struct PostureAnalyzer {
    private nonisolated static let confidenceThreshold: Float = 0.3
    // How far (in degrees) from the baseline before the score hits zero.
    private nonisolated static let maxDeviation: Float = 15.0
    // Max 2D Euclidean distance between current yawSignature and the nearest baseline
    // before we treat the head as "unknown position" and pause scoring. Units combine
    // direction (bbox-width fractions, ~[-0.5, 0.5]) and frontality ([0, 1]). 0.2 is
    // a starting value — tune as baselines land in real data.
    private nonisolated static let yawClassificationThreshold: Float = 0.2

    nonisolated func computeAngles(
        _ observation: VNHumanBodyPoseObservation,
        yawSignature: YawSignature?
    ) -> PostureAngles? {
        guard let allPoints = try? observation.recognizedPoints(.all),
              let side = pickBestSide(allPoints)
        else { return nil }

        let earShoulder = angleFromVertical(from: side.ear, to: side.shoulder)
        let shoulderHip = side.hip.map { angleFromVertical(from: side.shoulder, to: $0) }

        return PostureAngles(
            earShoulderAngle: earShoulder,
            shoulderHipAngle: shoulderHip,
            yawSignature: yawSignature
        )
    }

    /// Matches the current frame to one of three calibrated baselines (middle / left / right)
    /// using yawSignature, then scores against that baseline. Returns nil when:
    ///   • current frame has no yawSignature (nose not detected), or
    ///   • current yaw is too far from all three baselines (head in an uncalibrated pose)
    /// Callers treat nil as "pause scoring".
    nonisolated func score(
        current: PostureAngles,
        baselines: PostureBaselines
    ) -> (score: PostureScore, position: CalibrationPosition)? {
        guard let currentYaw = current.yawSignature else { return nil }

        let candidates: [(baseline: PostureAngles, position: CalibrationPosition)] = [
            (baselines.middle, .middle),
            (baselines.left, .left),
            (baselines.right, .right),
        ]
        var bestIdx: Int?
        var bestDist: Float = .greatestFiniteMagnitude
        for (i, candidate) in candidates.enumerated() {
            guard let baseYaw = candidate.baseline.yawSignature else { continue }
            let dist = currentYaw.distance(to: baseYaw)
            if dist < bestDist {
                bestDist = dist
                bestIdx = i
            }
        }

        guard let bestIdx, bestDist <= Self.yawClassificationThreshold else {
            return nil
        }
        let matched = candidates[bestIdx].baseline
        let position = candidates[bestIdx].position

        let earDev = abs(current.earShoulderAngle - matched.earShoulderAngle)
        let earScore = max(0, 1.0 - earDev / Self.maxDeviation)

        let value: Float
        if let curHip = current.shoulderHipAngle, let baseHip = matched.shoulderHipAngle {
            let hipDev = abs(curHip - baseHip)
            let hipScore = max(0, 1.0 - hipDev / Self.maxDeviation)
            value = (0.6 * earScore + 0.4 * hipScore) * 100
        } else {
            value = earScore * 100
        }
        return (PostureScore(value: value), position)
    }

    private nonisolated func pickBestSide(
        _ points: [VNHumanBodyPoseObservation.JointName: VNRecognizedPoint]
    ) -> (ear: CGPoint, shoulder: CGPoint, hip: CGPoint?)? {
        let sides: [(ear: VNHumanBodyPoseObservation.JointName,
                     shoulder: VNHumanBodyPoseObservation.JointName,
                     hip: VNHumanBodyPoseObservation.JointName)] = [
            (.leftEar, .leftShoulder, .leftHip),
            (.rightEar, .rightShoulder, .rightHip)
        ]

        var best: (ear: CGPoint, shoulder: CGPoint, hip: CGPoint?)? = nil
        var bestConfidence: Float = 0

        for side in sides {
            guard
                let earPt = points[side.ear],
                let shoulderPt = points[side.shoulder],
                earPt.confidence >= Self.confidenceThreshold,
                shoulderPt.confidence >= Self.confidenceThreshold
            else { continue }

            let hipPt = points[side.hip]
            let hipValid = (hipPt?.confidence ?? 0) >= Self.confidenceThreshold
            let total = earPt.confidence + shoulderPt.confidence + (hipValid ? hipPt!.confidence : 0)

            if total > bestConfidence {
                bestConfidence = total
                best = (earPt.location, shoulderPt.location, hipValid ? hipPt?.location : nil)
            }
        }
        return best
    }

    nonisolated private func angleFromVertical(from a: CGPoint, to b: CGPoint) -> Float {
        let dx = Float(b.x - a.x)
        let dy = Float(b.y - a.y)
        return atan2(abs(dx), abs(dy)) * 180 / .pi
    }
}
