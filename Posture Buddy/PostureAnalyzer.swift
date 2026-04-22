import Vision

// Pure-math analyzer; runs on the video queue alongside Vision requests.
nonisolated struct PostureAnalyzer {
    private static let confidenceThreshold: Float = 0.3
    // How far (in degrees) from the baseline before the score hits zero. Larger values
    // make scoring less sensitive — a 3° drift at 15° maxDev is already a "fair" grade,
    // which felt too aggressive in practice for normal small head movements.
    private static let maxDeviation: Float = 20.0

    func computeAngles(
        _ observation: VNHumanBodyPoseObservation,
        yawTelemetry: YawTelemetry?
    ) -> PostureAngles? {
        guard let allPoints = try? observation.recognizedPoints(.all),
              let side = pickBestSide(allPoints)
        else { return nil }

        let earShoulder = angleFromVertical(from: side.ear, to: side.shoulder)
        let shoulderHip = side.hip.map { angleFromVertical(from: side.shoulder, to: $0) }

        return PostureAngles(
            earShoulderAngle: earShoulder,
            shoulderHipAngle: shoulderHip,
            yawTelemetry: yawTelemetry
        )
    }

    /// Classifies the provided (typically EMA-smoothed) yaw signature against the
    /// calibrated baselines and scores the frame's ear/hip angles against the matching
    /// baseline. Returns nil when the signature is too far from all three baselines
    /// (head in an uncalibrated pose) — callers treat nil as "pause scoring".
    /// The caller is responsible for projecting telemetry → signature and for any
    /// smoothing; passing a raw per-frame signature was producing classification
    /// thrash near baseline boundaries.
    func score(
        current: PostureAngles,
        baselines: PostureBaselines,
        yawSignature sig: YawSignature
    ) -> (score: PostureScore, position: CalibrationPosition)? {
        guard let position = baselines.yaw.classify(sig).acceptedPosition else { return nil }

        let matched: PostureAngles
        switch position {
        case .middle: matched = baselines.middle
        case .left: matched = baselines.left
        case .right: matched = baselines.right
        }

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
