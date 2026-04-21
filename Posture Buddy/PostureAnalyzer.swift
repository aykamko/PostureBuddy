import Vision

// Pure-math analyzer; runs on the video queue alongside Vision requests.
nonisolated struct PostureAnalyzer {
    private static let confidenceThreshold: Float = 0.3
    // How far (in degrees) from the baseline before the score hits zero.
    private static let maxDeviation: Float = 15.0
    // Max 2D Euclidean distance between current yawSignature and the nearest baseline
    // before we treat the head as "unknown position" and pause scoring. Units combine
    // direction (bbox-width fractions, ~[-0.5, 0.5]) and frontality ([0, 1]). 0.2 is
    // a starting value — tune as baselines land in real data.
    private static let yawClassificationThreshold: Float = 0.2

    func computeAngles(
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
    func score(
        current: PostureAngles,
        baselines: PostureBaselines
    ) -> (score: PostureScore, position: CalibrationPosition)? {
        guard let currentYaw = current.yawSignature else { return nil }

        let sources: [(baseline: PostureAngles, position: CalibrationPosition)] = [
            (baselines.middle, .middle),
            (baselines.left, .left),
            (baselines.right, .right),
        ]
        let candidates = sources.compactMap { c -> (baseline: PostureAngles, position: CalibrationPosition, dist: Float)? in
            guard let baseYaw = c.baseline.yawSignature else { return nil }
            return (c.baseline, c.position, currentYaw.distance(to: baseYaw))
        }

        guard let best = candidates.min(by: { $0.dist < $1.dist }),
              best.dist <= Self.yawClassificationThreshold
        else { return nil }
        let matched = best.baseline
        let position = best.position

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

    private func pickBestSide(
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

            // Keep the hip only if it's confident enough — otherwise fall back to ear-shoulder alone.
            let validHip = points[side.hip].flatMap { $0.confidence >= Self.confidenceThreshold ? $0 : nil }
            let total = earPt.confidence + shoulderPt.confidence + (validHip?.confidence ?? 0)

            if total > bestConfidence {
                bestConfidence = total
                best = (earPt.location, shoulderPt.location, validHip?.location)
            }
        }
        return best
    }

    private func angleFromVertical(from a: CGPoint, to b: CGPoint) -> Float {
        let dx = Float(b.x - a.x)
        let dy = Float(b.y - a.y)
        return atan2(abs(dx), abs(dy)) * 180 / .pi
    }
}
