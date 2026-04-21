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

// A snapshot of the side-profile angles for one frame.
// Baseline = same struct captured when the user taps Calibrate.
struct PostureAngles {
    let earShoulderAngle: Float       // degrees from image-vertical
    let shoulderHipAngle: Float?      // nil if hip was occluded
}

struct PostureAnalyzer {
    private nonisolated static let confidenceThreshold: Float = 0.3
    // How far (in degrees) from the baseline before the score hits zero.
    private nonisolated static let maxDeviation: Float = 15.0

    nonisolated func computeAngles(_ observation: VNHumanBodyPoseObservation) -> PostureAngles? {
        guard let allPoints = try? observation.recognizedPoints(.all),
              let side = pickBestSide(allPoints)
        else { return nil }

        let earShoulder = angleFromVertical(from: side.ear, to: side.shoulder)
        let shoulderHip = side.hip.map { angleFromVertical(from: side.shoulder, to: $0) }
        return PostureAngles(earShoulderAngle: earShoulder, shoulderHipAngle: shoulderHip)
    }

    // Score = how close current posture is to the calibrated baseline.
    // Ear-shoulder deviation weighted 60%, shoulder-hip 40% (when available).
    nonisolated func score(current: PostureAngles, baseline: PostureAngles) -> PostureScore {
        let earDev = abs(current.earShoulderAngle - baseline.earShoulderAngle)
        let earScore = max(0, 1.0 - earDev / Self.maxDeviation)

        let value: Float
        if let curHip = current.shoulderHipAngle, let baseHip = baseline.shoulderHipAngle {
            let hipDev = abs(curHip - baseHip)
            let hipScore = max(0, 1.0 - hipDev / Self.maxDeviation)
            value = (0.6 * earScore + 0.4 * hipScore) * 100
        } else {
            value = earScore * 100
        }
        return PostureScore(value: value)
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
