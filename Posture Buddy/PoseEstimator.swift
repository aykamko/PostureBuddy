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

final class PoseEstimator: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureDataOutputSynchronizerDelegate {
    @Published var currentPose: DetectedPose?
    @Published var isCalibrated: Bool = false
    @Published var isTrackingReady: Bool = false
    /// Latest TrueDepth map rendered as a jet-colormap CGImage for debug overlay.
    /// nil when running on wide-angle fallback (no depth) or before the first frame.
    @Published var depthVisualization: CGImage?

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
    private let lastDepthLogTime = OSAllocatedUnfairLock(initialState: CFTimeInterval(0))
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

    // MARK: - AVCaptureVideoDataOutputSampleBufferDelegate (fallback: no TrueDepth)

    nonisolated func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        processFrame(sampleBuffer: sampleBuffer, depthData: nil)
    }

    // MARK: - AVCaptureDataOutputSynchronizerDelegate (preferred: video + depth)

    nonisolated func dataOutputSynchronizer(
        _ synchronizer: AVCaptureDataOutputSynchronizer,
        didOutput synchronizedDataCollection: AVCaptureSynchronizedDataCollection
    ) {
        // Pull the video+depth pair out of the collection. Iteration yields the
        // `AVCaptureSynchronizedData` entries directly (no output-keyed lookup needed).
        var video: AVCaptureSynchronizedSampleBufferData?
        var depth: AVCaptureSynchronizedDepthData?
        for entry in synchronizedDataCollection {
            if let v = entry as? AVCaptureSynchronizedSampleBufferData {
                video = v
            } else if let d = entry as? AVCaptureSynchronizedDepthData {
                depth = d
            }
        }
        guard let video, !video.sampleBufferWasDropped else { return }
        // Depth can be absent (slower frame) or dropped; we still score on video alone
        // in that case and flag the keypoints' depth as nil.
        let usableDepth = (depth?.depthDataWasDropped == false) ? depth?.depthData : nil
        processFrame(sampleBuffer: video.sampleBuffer, depthData: usableDepth)
    }

    // MARK: - Shared pipeline

    nonisolated private func processFrame(
        sampleBuffer: CMSampleBuffer,
        depthData: AVDepthData?
    ) {
        let now = CACurrentMediaTime()
        guard lastProcessedTime.shouldFire(now: now, minInterval: 0.1) else { return }
        guard let (body, face) = runVisionRequests(on: sampleBuffer) else { return }

        // Per-frame yaw telemetry: raw candidate features for the adaptive selector.
        // Which two we actually use for classification is decided at calibration time
        // and lives in `baselines.yaw.selection`.
        let telemetry = YawTelemetry.from(face: face, body: body)

        // Prep the depth buffer once: orient to match Vision's upright space and
        // convert to Float32 metric depth. Lock it for the duration of all consumers
        // (keypoint sampling + viz rendering) so we only pay the lock once.
        let orientation = visionOrientation.withLock { $0 }
        let preparedDepth: CVPixelBuffer? = depthData
            .map { $0.applyingExifOrientation(orientation) }
            .map { $0.converting(toDepthDataType: kCVPixelFormatType_DepthFloat32) }
            .map { $0.depthDataMap }
        if let preparedDepth {
            CVPixelBufferLockBaseAddress(preparedDepth, .readOnly)
        }
        defer {
            if let preparedDepth {
                CVPixelBufferUnlockBaseAddress(preparedDepth, .readOnly)
            }
        }

        // Extract keypoints first (with per-keypoint depth sampled from the depth
        // map) so the analyzer can decorate the angles with depth deltas using the
        // exact same side it picks for the 2D angle.
        let keypoints = extractKeypoints(from: body, preparedDepth: preparedDepth)
        let angles = analyzer.computeAngles(body, yawTelemetry: telemetry, keypoints3D: keypoints)
        currentAngles.withLock { $0 = angles }
        currentTelemetry.withLock { $0 = telemetry }

        // Debug overlay: render the depth buffer as a jet-colormap image. ~80k
        // pixels per frame at 10 Hz is cheap; only generate when depth is present.
        let depthViz = preparedDepth.flatMap { Self.makeDepthVisualization(from: $0) }

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
                position: scored?.position,
                angles: angles
            )
        }
        // Depth telemetry: only when this packet actually contained depth (skips
        // the 2-of-3 video-only frames from the 30 Hz video / 10 Hz depth cadence)
        // and throttled to 1 Hz so the log stays readable during observation.
        if depthViz != nil,
           let angles,
           lastDepthLogTime.shouldFire(now: now, minInterval: 1.0) {
            Self.logDepthTelemetry(angles: angles, currentBaselines: currentBaselines)
        }

        let pose = DetectedPose(
            keypoints: keypoints,
            faceLandmarks: Self.extractFaceLandmarks(from: face),
            score: scored?.score
        )
        let hasValidAngles = angles != nil

        Task { @MainActor in
            self.currentPose = pose
            // Only publish *new* depth viz — depth runs at 10 Hz while video arrives
            // at 30 Hz, so 2/3 of synchronized packets have `depthDataWasDropped` and
            // would blank the overlay. Keep the last valid image on screen instead.
            if let depthViz {
                self.depthVisualization = depthViz
            }
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
        position: CalibrationPosition?,
        angles: PostureAngles?
    ) {
        let yawStr = yaw?.debugString ?? "n/a"
        let clsStr = classification?.debugString ?? "n/a"
        let depthStr = Self.depthSummary(angles: angles)
        switch state {
        case .scored:
            guard let score, let position else { return }
            Log.line(
                "[Posture]",
                "score=\(String(format: "%.1f", score.value)) [\(score.grade.label)] "
                + "mode=\(position.rawValue)  yaw=\(yawStr)  cls=\(clsStr)  \(depthStr)"
            )
        case .paused:
            Log.line(
                "[Posture]",
                "paused — head position not recognized  yaw=\(yawStr)  cls=\(clsStr)  \(depthStr)"
            )
        case .awaitingCalibration:
            Log.line(
                "[Posture]",
                "angles available; awaiting calibration  yaw=\(yawStr)  \(depthStr)"
            )
        case .noValidSide:
            Log.line("[Posture]", "no valid keypoints")
        }
    }

    /// Compact summary of depth-derived metrics for inclusion in the `[Posture]` line.
    /// `n/a` when the frame had no valid depth deltas (e.g. wide-angle fallback or holes).
    nonisolated private static func depthSummary(angles: PostureAngles?) -> String {
        guard let angles else { return "depth=n/a" }
        func cm(_ m: Float?) -> String {
            guard let m else { return "—" }
            return String(format: "%+.2fcm", m * 100)
        }
        return "depth=earSh:\(cm(angles.earShoulderZDelta)) earNk:\(cm(angles.earNeckZDelta))"
    }

    /// One CSV-ish line per frame. Pull off device with Console.app and plot.
    /// Columns: `t,earShCm,earNkCm,baseEarShCm,baseEarNkCm,position`
    nonisolated private static func logDepthTelemetry(
        angles: PostureAngles,
        currentBaselines: PostureBaselines?
    ) {
        // Use whichever baseline is closest by yaw classification if calibrated.
        // For simplicity in this telemetry pass we always reference the middle
        // baseline — Phase 5 plot is per-yaw-position anyway.
        let baseline = currentBaselines?.middle
        func cm(_ m: Float?) -> String {
            guard let m else { return "" }
            return String(format: "%.3f", m * 100)
        }
        let line = [
            cm(angles.earShoulderZDelta),
            cm(angles.earNeckZDelta),
            cm(baseline?.earShoulderZDelta),
            cm(baseline?.earNeckZDelta)
        ].joined(separator: ",")
        Log.line("[DepthTelemetry]", "earShCm,earNkCm,baseEarShCm,baseEarNkCm = \(line)")
    }

    /// Caller must lock `preparedDepth` (if non-nil) before calling and unlock after —
    /// this method does NOT manage the buffer's lock lifecycle so the same prepared
    /// buffer can be shared with `makeDepthVisualization`.
    nonisolated private func extractKeypoints(
        from observation: VNHumanBodyPoseObservation,
        preparedDepth: CVPixelBuffer?
    ) -> [VNHumanBodyPoseObservation.JointName: Keypoint3D] {
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

        var result: [VNHumanBodyPoseObservation.JointName: Keypoint3D] = [:]
        for joint in joints {
            guard let pt = try? observation.recognizedPoint(joint),
                  pt.confidence >= 0.3 else { continue }
            let depth = preparedDepth.flatMap { Self.sampleDepth(at: pt.location, buffer: $0) }
            result[joint] = Keypoint3D(location: pt.location, depthMeters: depth)
        }
        return result
    }

    /// Renders a Float32 depth buffer (already orientation-corrected, locked by the
    /// caller) into a jet-colormap RGB image for the debug overlay. Closer = red,
    /// farther = blue, IR holes = magenta. Range clamped to 0.25–1.0 m (TrueDepth
    /// usable range; desk distance sits in the middle).
    nonisolated private static func makeDepthVisualization(from buffer: CVPixelBuffer) -> CGImage? {
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let bpr = CVPixelBufferGetBytesPerRow(buffer)
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }

        let nearMeters: Float = 0.25
        let farMeters: Float = 1.0
        let range = farMeters - nearMeters

        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { raw in
            let out = raw.baseAddress!.assumingMemoryBound(to: UInt8.self)
            for y in 0..<height {
                let row = base.advanced(by: y * bpr).assumingMemoryBound(to: Float32.self)
                for x in 0..<width {
                    let d = row.advanced(by: x).pointee
                    let i = (y * width + x) * 4
                    if !d.isFinite || d <= 0 {
                        // IR hole — magenta, opaque
                        out[i] = 255; out[i+1] = 0; out[i+2] = 255; out[i+3] = 255
                    } else {
                        let t = max(0, min(1, (d - nearMeters) / range))
                        let (r, g, b) = jetColor(t: t)
                        out[i] = r; out[i+1] = g; out[i+2] = b; out[i+3] = 255
                    }
                }
            }
        }

        let cfData = Data(pixels) as CFData
        guard let provider = CGDataProvider(data: cfData) else { return nil }
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
    }

    /// Standard "jet" colormap: red → yellow → green → cyan → blue.
    nonisolated private static func jetColor(t: Float) -> (UInt8, UInt8, UInt8) {
        let t = max(0, min(1, t))
        if t < 0.25 {
            return (255, UInt8(t * 4 * 255), 0)
        } else if t < 0.5 {
            return (UInt8((1 - (t - 0.25) * 4) * 255), 255, 0)
        } else if t < 0.75 {
            return (0, 255, UInt8((t - 0.5) * 4 * 255))
        } else {
            return (0, UInt8((1 - (t - 0.75) * 4) * 255), 255)
        }
    }

    /// Samples a 3×3 patch of Float32 depth around the given image-normalized
    /// location and returns the median of finite positive values. `nil` when every
    /// sample in the patch was NaN/0/negative (IR hole).
    nonisolated private static func sampleDepth(
        at location: CGPoint,
        buffer: CVPixelBuffer
    ) -> Float? {
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        // Vision: origin bottom-left, y-up, normalized. Depth buffer (after
        // `applyingExifOrientation`): origin top-left, y-down. Flip y.
        let cx = Int((Double(location.x) * Double(width)).rounded())
        let cy = Int(((1.0 - Double(location.y)) * Double(height)).rounded())
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let bpr = CVPixelBufferGetBytesPerRow(buffer)

        var samples: [Float] = []
        samples.reserveCapacity(9)
        for dy in -1...1 {
            let py = cy + dy
            guard py >= 0, py < height else { continue }
            let rowStart = base.advanced(by: py * bpr).assumingMemoryBound(to: Float32.self)
            for dx in -1...1 {
                let px = cx + dx
                guard px >= 0, px < width else { continue }
                let pixel = rowStart.advanced(by: px).pointee
                if pixel.isFinite && pixel > 0 {
                    samples.append(pixel)
                }
            }
        }
        guard !samples.isEmpty else { return nil }
        samples.sort()
        return samples[samples.count / 2]
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
