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

    /// Classifies `sig` to the nearest baseline and scores the frame's ear/hip angles
    /// against it. Never pauses on yaw — all three baselines are calibrated upright,
    /// so a large ear-shoulder deviation produces a low score regardless of which
    /// baseline we snap to. The threshold on the returned classification is
    /// informational only (surfaced in logs as ✓/✗).
    func score(
        current: PostureAngles,
        baselines: PostureBaselines,
        yawSignature sig: YawSignature
    ) -> (score: PostureScore, position: CalibrationPosition)? {
        let position = baselines.yaw.classify(sig).closest

        let matched: PostureAngles
        switch position {
        case .middle: matched = baselines.middle
        case .left: matched = baselines.left
        case .right: matched = baselines.right
        }

        // Asymmetric scoring: only penalize deviations in the calibrated forward
        // direction. `forwardSign` is +1 or -1 indicating which sign of (current -
        // baseline) corresponds to leaning forward; multiplying by it gives a
        // "forward component" where positive = forward lean. max(0, …) zeroes out
        // backward lean. Falls back to symmetric `abs` if the calibration sample
        // wasn't decisive enough to derive a sign.
        let earDev = forwardDeviation(
            current: current.earShoulderAngle,
            baseline: matched.earShoulderAngle,
            sign: baselines.forwardSign
        )
        let earScore = max(0, 1.0 - earDev / Self.maxDeviation)

        let value: Float
        if let curHip = current.shoulderHipAngle, let baseHip = matched.shoulderHipAngle {
            let hipDev = forwardDeviation(
                current: curHip,
                baseline: baseHip,
                sign: baselines.forwardSign
            )
            let hipScore = max(0, 1.0 - hipDev / Self.maxDeviation)
            value = (0.6 * earScore + 0.4 * hipScore) * 100
        } else {
            value = earScore * 100
        }
        return (PostureScore(value: value), position)
    }

    private func forwardDeviation(current: Float, baseline: Float, sign: Float?) -> Float {
        let signed = current - baseline
        guard let sign else { return abs(signed) }   // no forward calibration → symmetric
        return max(0, signed * sign)                  // forward only; backward = 0
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

    /// Signed angle (in degrees) of vector a→b from image-vertical, in [-90, +90].
    /// Sign of the result reflects which side of vertical the vector tips toward;
    /// scoring uses it to distinguish forward vs backward lean (see `forwardSign`).
    private func angleFromVertical(from a: CGPoint, to b: CGPoint) -> Float {
        let dx = Float(b.x - a.x)
        let dy = Float(b.y - a.y)
        return atan2(dx, abs(dy)) * 180 / .pi
    }
}
