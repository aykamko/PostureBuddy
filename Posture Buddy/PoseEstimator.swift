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
        isCalibrated = false
    }

    /// Commits the three-position baselines. Returns false if the adaptive yaw-feature
    /// selector couldn't find a pair that separates the three positions (e.g. face
    /// landmarks too sparse in one of the snapshots) — caller should surface the
    /// "try again" voice prompt in that case.
    func calibrate(middle: PostureAngles, left: PostureAngles, right: PostureAngles) -> Bool {
        guard
            let mT = middle.yawTelemetry,
            let lT = left.yawTelemetry,
            let rT = right.yawTelemetry,
            let yawCal = YawCalibration.make(middle: mT, left: lT, right: rT)
        else {
            return false
        }
        let b = PostureBaselines(middle: middle, left: left, right: right, yaw: yawCal)
        baselines.withLock { $0 = b }
        emaState.withLock { $0 = 100 }
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
