import AVFoundation
import Vision
import Combine
import os

private extension OSAllocatedUnfairLock where State == CFTimeInterval {
    /// Returns true and stamps `now` if at least `minInterval` has passed since the last fire.
    nonisolated func shouldFire(now: CFTimeInterval, minInterval: CFTimeInterval) -> Bool {
        withLock { last in
            guard now - last >= minInterval else { return false }
            last = now
            return true
        }
    }
}

final class PoseEstimator: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    @Published var currentPose: DetectedPose?
    @Published var isCalibrated: Bool = false
    @Published var isTrackingReady: Bool = false

    nonisolated private let analyzer = PostureAnalyzer()
    private let lastProcessedTime = OSAllocatedUnfairLock(initialState: CFTimeInterval(0))
    private let emaState = OSAllocatedUnfairLock(initialState: Float(100))
    // EMA-smoothed yaw signature. Single-frame detector jitter on direction / frontality
    // can push a frame back and forth across the classification threshold when the user
    // sits between two baselines; smoothing before classify() keeps it stable.
    // α = 0.3 (new weight); reaches ~80% of a step change in ~4-5 frames (~450 ms at 10 Hz).
    nonisolated static let yawSignatureSmoothingAlpha: Float = 0.3
    private let smoothedYawSignature = OSAllocatedUnfairLock<YawSignature?>(initialState: nil)
    private let visionOrientation = OSAllocatedUnfairLock(initialState: CGImagePropertyOrientation.leftMirrored)
    private let lastLogTime = OSAllocatedUnfairLock(initialState: CFTimeInterval(0))
    private let lastLogState = OSAllocatedUnfairLock<FrameLogState>(initialState: .noValidSide)
    // Last-known 2D location per joint. Frames that drop a joint (low confidence for
    // a frame or two) fall back to this cache so the skeleton stops flickering.
    // Stale points are surfaced to the UI via `Keypoint.isStale` so they render purple.
    private let lastKnownKeypoints = OSAllocatedUnfairLock<[VNHumanBodyPoseObservation.JointName: CGPoint]>(initialState: [:])
    // Running counters used at calibration commit to decide which ear is the
    // "dominant" (camera-side) one. Only that ear gets stale-cached — the occluded
    // far-side ear can occasionally flicker into view at extreme head yaws and then
    // render as a ghost after the user's head turns back, which looks wrong.
    private let earSightings = OSAllocatedUnfairLock<(left: Int, right: Int)>(initialState: (0, 0))
    // The dominant ear, locked in at calibration. nil pre-calibration → neither ear
    // is stale-eligible (ears just disappear when not detected).
    private let dominantEar = OSAllocatedUnfairLock<VNHumanBodyPoseObservation.JointName?>(initialState: nil)

    // Most-recent per-frame angles (for calibration capture)
    private let currentAngles = OSAllocatedUnfairLock<PostureAngles?>(initialState: nil)
    // Most-recent per-frame telemetry (debug-only; logged during calibration to evaluate
    // candidate yaw features)
    private let currentTelemetry = OSAllocatedUnfairLock<YawTelemetry?>(initialState: nil)
    // Calibrated references (middle / left / right); nil until user completes calibration
    private let baselines = OSAllocatedUnfairLock<PostureBaselines?>(initialState: nil)

    /// What we last logged for a frame. Used to force a log line on state transitions
    /// (scored ↔ paused ↔ awaiting) regardless of the 2s throttle — so flutter is visible.
    nonisolated enum FrameLogState: Equatable {
        case scored(grade: PostureScore.Grade, position: CalibrationPosition)
        case paused
        case awaitingCalibration
        case noValidSide
    }

    func updateOrientation(_ orientation: CGImagePropertyOrientation) {
        visionOrientation.withLock { $0 = orientation }
    }

    /// Returns the most-recent frame's computed angles, or nil if the current frame
    /// didn't yield a valid pose. Used by the calibration flow to snapshot per-position.
    /// Requires yaw telemetry to be present — a calibration snapshot without a detected
    /// face would be useless downstream.
    func snapshotCurrentAngles() -> PostureAngles? {
        currentAngles.withLock { a in
            guard let a, a.yawTelemetry != nil else { return nil }
            return a
        }
    }

    /// Returns the most-recent frame's yaw telemetry (debug). Logged by the calibration
    /// flow at each position to compare candidate features.
    func snapshotCurrentTelemetry() -> YawTelemetry? {
        currentTelemetry.withLock { $0 }
    }

    /// Discards any committed baselines so scoring pauses. Called at the start of a
    /// fresh calibration so stale scores don't leak into timers / sounds while the
    /// user is repositioning.
    func resetCalibration() {
        baselines.withLock { $0 = nil }
        emaState.withLock { $0 = 100 }
        smoothedYawSignature.withLock { $0 = nil }
        // Clear ear tallies so recalibration picks the dominant ear from fresh
        // observation (e.g. user flipped the phone to the other side of their desk).
        earSightings.withLock { $0 = (0, 0) }
        dominantEar.withLock { $0 = nil }
        isCalibrated = false
    }

    /// Commits the baselines. Returns false if the adaptive yaw-feature selector
    /// couldn't find a pair that separates the three yaw positions (e.g. face landmarks
    /// too sparse in one of the snapshots) — caller should surface the "try again"
    /// voice prompt in that case. `forwardLean` is captured at the middle yaw with the
    /// user intentionally slouching; stored for future forward-sign derivation but not
    /// yet wired into scoring.
    func calibrate(
        middle: PostureAngles,
        forwardLean: PostureAngles,
        left: PostureAngles,
        right: PostureAngles
    ) -> Bool {
        guard
            let mT = middle.yawTelemetry,
            let lT = left.yawTelemetry,
            let rT = right.yawTelemetry,
            let yawCal = YawCalibration.make(middle: mT, left: lT, right: rT)
        else {
            return false
        }
        // Forward-direction sign for asymmetric scoring: the sign of the ear-shoulder
        // angle delta between leaning forward and sitting upright at the same yaw.
        // Require a meaningful magnitude (≥1°) — small deltas mean the user didn't
        // really lean, and trusting a noisy sign would silently penalize the wrong
        // direction. nil → fall back to symmetric scoring.
        let earForwardDelta = forwardLean.earShoulderAngle - middle.earShoulderAngle
        let forwardSign: Float? = abs(earForwardDelta) >= 1.0
            ? (earForwardDelta >= 0 ? 1.0 : -1.0)
            : nil

        let b = PostureBaselines(
            middle: middle,
            forwardLean: forwardLean,
            left: left,
            right: right,
            yaw: yawCal,
            forwardSign: forwardSign
        )
        baselines.withLock { $0 = b }
        emaState.withLock { $0 = 100 }
        // Decide the camera-side ear from the sightings accumulated during the
        // calibration period. Break ties toward .leftEar (arbitrary — if neither
        // ear was seen at all, the user can recalibrate).
        let (lEar, rEar) = earSightings.withLock { $0 }
        let dominant: VNHumanBodyPoseObservation.JointName = lEar >= rEar ? .leftEar : .rightEar
        dominantEar.withLock { $0 = dominant }
        Log.line(
            "[Posture]",
            "  dominant ear = \(dominant.rawValue)  (left seen \(lEar), right seen \(rEar))"
        )
        isCalibrated = true
        lastLogState.withLock { $0 = .awaitingCalibration }  // force next frame to log as a transition
        Log.line(
            "[Posture]",
            "calibrated  selection=(\(yawCal.selection.direction.rawValue), "
            + "\(yawCal.selection.frontality.rawValue))  "
            + "threshold=\(String(format: "%.3f", yawCal.classificationThreshold))  "
            + "minPair=\(String(format: "%.3f", yawCal.minPairwiseDistance))"
        )
        Log.line(
            "[Posture]",
            "  middle=\(yawCal.middle.debugString)  "
            + "left=\(yawCal.left.debugString)  "
            + "right=\(yawCal.right.debugString)"
        )
        Log.line(
            "[Posture]",
            "  ear-shoulder angles: "
            + "middle=\(String(format: "%.2f°", middle.earShoulderAngle))  "
            + "forwardLean=\(String(format: "%.2f°", forwardLean.earShoulderAngle))  "
            + "Δ=\(String(format: "%+.2f°", earForwardDelta))  "
            + "forwardSign=\(forwardSign.map { String(format: "%+.0f", $0) } ?? "nil (symmetric)")"
        )
        return true
    }

    nonisolated func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        let now = CACurrentMediaTime()
        guard lastProcessedTime.shouldFire(now: now, minInterval: 0.1) else { return }
        guard let (body, face) = runVisionRequests(on: sampleBuffer) else { return }

        // Per-frame yaw telemetry: raw candidate features for the adaptive selector.
        // Which two we actually use for classification is decided at calibration time
        // and lives in `baselines.yaw.selection`.
        let telemetry = YawTelemetry.from(face: face, body: body)
        let angles = analyzer.computeAngles(body, yawTelemetry: telemetry)
        currentAngles.withLock { $0 = angles }
        currentTelemetry.withLock { $0 = telemetry }

        let currentBaselines = baselines.withLock { $0 }

        // Project the current frame via the calibrated selection, then EMA-smooth so
        // per-frame detector jitter doesn't push us across the classification threshold
        // when the user is between baselines.
        let rawSig = telemetry.flatMap { currentBaselines?.yaw.selection.signature(from: $0) }
        let runtimeSig = smoothedYawSignature.withLock { prev -> YawSignature? in
            guard let rawSig else { return prev }
            let α = Self.yawSignatureSmoothingAlpha
            let next: YawSignature
            if let prev {
                next = YawSignature(
                    direction: (1 - α) * prev.direction + α * rawSig.direction,
                    frontality: (1 - α) * prev.frontality + α * rawSig.frontality
                )
            } else {
                next = rawSig
            }
            prev = next
            return next
        }
        let scored = scoreFrame(angles: angles, baselines: currentBaselines, yawSignature: runtimeSig)
        let classification = runtimeSig.flatMap { sig in currentBaselines.map { $0.yaw.classify(sig) } }

        let state: FrameLogState
        if let scored {
            state = .scored(grade: scored.score.grade, position: scored.position)
        } else if currentBaselines != nil, angles != nil {
            state = .paused
        } else if angles != nil {
            state = .awaitingCalibration
        } else {
            state = .noValidSide
        }

        let stateChanged = lastLogState.withLock { last in
            let changed = last != state
            last = state
            return changed
        }
        if stateChanged || lastLogTime.shouldFire(now: now, minInterval: 2.0) {
            logFrame(
                state: state,
                yaw: runtimeSig,
                classification: classification,
                score: scored?.score,
                position: scored?.position
            )
        }

        let pose = DetectedPose(
            keypoints: extractKeypoints(from: body),
            faceLandmarks: Self.extractFaceLandmarks(from: face),
            score: scored?.score
        )
        let hasValidAngles = angles != nil

        Task { @MainActor in
            self.currentPose = pose
            if hasValidAngles && !self.isTrackingReady {
                self.isTrackingReady = true
            }
        }
    }

    /// Runs body + face detection on the given sample buffer using the latest
    /// orientation. Returns nil if no body observation was found (face is optional).
    nonisolated private func runVisionRequests(
        on sampleBuffer: CMSampleBuffer
    ) -> (body: VNHumanBodyPoseObservation, face: VNFaceObservation?)? {
        let bodyRequest = VNDetectHumanBodyPoseRequest()
        let faceRequest = VNDetectFaceLandmarksRequest()
        faceRequest.revision = VNDetectFaceLandmarksRequest.currentRevision

        let orientation = visionOrientation.withLock { $0 }
        let handler = VNImageRequestHandler(cmSampleBuffer: sampleBuffer, orientation: orientation)
        try? handler.perform([bodyRequest, faceRequest])

        guard let body = bodyRequest.results?.first else { return nil }
        return (body, faceRequest.results?.first)
    }

    /// Scores the current frame against the calibrated baselines with exponential
    /// smoothing. Returns nil when not calibrated, when angles couldn't be computed,
    /// or when the analyzer can't classify the head position.
    nonisolated private func scoreFrame(
        angles: PostureAngles?,
        baselines: PostureBaselines?,
        yawSignature sig: YawSignature?
    ) -> (score: PostureScore, position: CalibrationPosition)? {
        guard let angles,
              let baselines,
              let sig,
              let raw = analyzer.score(current: angles, baselines: baselines, yawSignature: sig)
        else { return nil }
        let smoothed = emaState.withLock { current in
            current = 0.8 * current + 0.2 * raw.score.value
            return PostureScore(value: current)
        }
        return (smoothed, raw.position)
    }

    nonisolated private func logFrame(
        state: FrameLogState,
        yaw: YawSignature?,
        classification: YawClassification?,
        score: PostureScore?,
        position: CalibrationPosition?
    ) {
        let yawStr = yaw?.debugString ?? "n/a"
        let clsStr = classification?.debugString ?? "n/a"
        switch state {
        case .scored:
            guard let score, let position else { return }
            Log.line(
                "[Posture]",
                "score=\(String(format: "%.1f", score.value)) [\(score.grade.label)] "
                + "mode=\(position.rawValue)  yaw=\(yawStr)  cls=\(clsStr)"
            )
        case .paused:
            Log.line(
                "[Posture]",
                "paused — head position not recognized  yaw=\(yawStr)  cls=\(clsStr)"
            )
        case .awaitingCalibration:
            Log.line("[Posture]", "angles available; awaiting calibration  yaw=\(yawStr)")
        case .noValidSide:
            Log.line("[Posture]", "no valid keypoints")
        }
    }

    // Only the joints we actually draw / use for scoring. Face-facing upper body only;
    // arms, hips, legs never contributed to the posture score and the desk occluded
    // them anyway.
    nonisolated private static let trackedJoints: [VNHumanBodyPoseObservation.JointName] = [
        .nose, .leftEye, .rightEye,
        .leftEar, .rightEar,
        .neck,
        .leftShoulder, .rightShoulder
    ]

    // Joints that are always cached + fall back to last-known when this frame drops
    // them. Ears are handled separately — only the calibration-determined dominant
    // (camera-side) ear is stale-eligible at runtime; the far-side ear can flicker
    // in briefly at extreme yaws and we don't want it ghosting afterward.
    nonisolated private static let alwaysStaleEligible: Set<VNHumanBodyPoseObservation.JointName> = [
        .nose, .leftEye, .rightEye,
        .neck,
        .leftShoulder, .rightShoulder
    ]

    nonisolated private func extractKeypoints(
        from observation: VNHumanBodyPoseObservation
    ) -> [VNHumanBodyPoseObservation.JointName: Keypoint] {
        // Collect whatever Vision confidently found this frame.
        var fresh: [VNHumanBodyPoseObservation.JointName: CGPoint] = [:]
        for joint in Self.trackedJoints {
            if let pt = try? observation.recognizedPoint(joint), pt.confidence >= 0.3 {
                fresh[joint] = pt.location
            }
        }

        // Tally ear sightings so calibrate() can decide which side is dominant.
        // Cheap single-lock update regardless of calibration state.
        if fresh[.leftEar] != nil || fresh[.rightEar] != nil {
            earSightings.withLock { counts in
                if fresh[.leftEar] != nil { counts.left += 1 }
                if fresh[.rightEar] != nil { counts.right += 1 }
            }
        }

        // Dynamic stale-eligibility set: always-eligible joints plus the dominant
        // ear once calibration has locked it in.
        var eligible = Self.alwaysStaleEligible
        if let dominant = dominantEar.withLock({ $0 }) {
            eligible.insert(dominant)
        }

        // Merge with the last-known cache. For eligible joints: fresh writes through
        // to the cache, cached-but-not-fresh renders stale. For non-eligible joints
        // (far-side ear, and both ears pre-calibration): never cached, never stale —
        // present only when fresh.
        return lastKnownKeypoints.withLock { cache in
            var result: [VNHumanBodyPoseObservation.JointName: Keypoint] = [:]
            for joint in Self.trackedJoints {
                let isEligible = eligible.contains(joint)
                if let pt = fresh[joint] {
                    if isEligible { cache[joint] = pt }
                    result[joint] = Keypoint(location: pt, isStale: false)
                } else if isEligible, let pt = cache[joint] {
                    result[joint] = Keypoint(location: pt, isStale: true)
                }
            }
            return result
        }
    }

    // Converts face landmark region points (which are in bbox-local normalized coords)
    // into image-normalized coords so the overlay can draw them in the same coordinate
    // system as the body skeleton.
    nonisolated private static func extractFaceLandmarks(from observation: VNFaceObservation?) -> FaceLandmarks? {
        guard let observation else { return nil }
        let bbox = observation.boundingBox
        let points = observation.landmarks?.allPoints?.normalizedPoints.map { p in
            CGPoint(
                x: bbox.origin.x + CGFloat(p.x) * bbox.width,
                y: bbox.origin.y + CGFloat(p.y) * bbox.height
            )
        } ?? []
        return FaceLandmarks(points: points, boundingBox: bbox)
    }
}
