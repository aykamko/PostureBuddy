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
    private let visionOrientation = OSAllocatedUnfairLock(initialState: CGImagePropertyOrientation.leftMirrored)
    private let lastLogTime = OSAllocatedUnfairLock(initialState: CFTimeInterval(0))

    // Most-recent per-frame angles (for calibration capture)
    private let currentAngles = OSAllocatedUnfairLock<PostureAngles?>(initialState: nil)
    // Most-recent per-frame telemetry (debug-only; logged during calibration to evaluate
    // candidate yaw features)
    private let currentTelemetry = OSAllocatedUnfairLock<YawTelemetry?>(initialState: nil)
    // Calibrated references (middle / left / right); nil until user completes calibration
    private let baselines = OSAllocatedUnfairLock<PostureBaselines?>(initialState: nil)

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
        print(
            "[Posture] calibrated  selection=(\(yawCal.selection.direction.rawValue), "
            + "\(yawCal.selection.frontality.rawValue))  "
            + "threshold=\(String(format: "%.3f", yawCal.classificationThreshold))  "
            + "minPair=\(String(format: "%.3f", yawCal.minPairwiseDistance))"
        )
        print(
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
        let scored = scoreFrame(angles: angles, baselines: currentBaselines)
        let runtimeSig = telemetry.flatMap { currentBaselines?.yaw.selection.signature(from: $0) }

        if lastLogTime.shouldFire(now: now, minInterval: 2.0) {
            logFrame(
                yaw: runtimeSig,
                score: scored?.score,
                position: scored?.position,
                hasAngles: angles != nil,
                hasBaselines: currentBaselines != nil
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
        baselines: PostureBaselines?
    ) -> (score: PostureScore, position: CalibrationPosition)? {
        guard let angles,
              let baselines,
              let raw = analyzer.score(current: angles, baselines: baselines)
        else { return nil }
        let smoothed = emaState.withLock { current in
            current = 0.8 * current + 0.2 * raw.score.value
            return PostureScore(value: current)
        }
        return (smoothed, raw.position)
    }

    nonisolated private func logFrame(
        yaw: YawSignature?,
        score: PostureScore?,
        position: CalibrationPosition?,
        hasAngles: Bool,
        hasBaselines: Bool
    ) {
        let yawStr = yaw?.debugString ?? "n/a"
        if let score, let position {
            print("[Posture] score=\(String(format: "%.1f", score.value)) [\(score.grade.label)] mode=\(position.rawValue) yaw=\(yawStr)")
        } else if hasBaselines && hasAngles {
            print("[Posture] paused — head position not recognized  yaw=\(yawStr)")
        } else if hasAngles {
            print("[Posture] angles available; awaiting calibration  yaw=\(yawStr)")
        } else {
            print("[Posture] no valid keypoints")
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
