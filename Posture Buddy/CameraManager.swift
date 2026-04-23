import AVFoundation
import Combine

/// A delegate that can receive both a synchronized video+depth collection (preferred,
/// when TrueDepth is available) OR a bare video sample buffer (fallback). PoseEstimator
/// implements both — we wire the one that matches the active device mode.
typealias FrameDelegate = AVCaptureDataOutputSynchronizerDelegate & AVCaptureVideoDataOutputSampleBufferDelegate & NSObjectProtocol

final class CameraManager: ObservableObject {
    let session = AVCaptureSession()

    private let videoQueue = DispatchQueue(label: "posture.video", qos: .userInitiated)
    private var videoOutput: AVCaptureVideoDataOutput?
    private var depthOutput: AVCaptureDepthDataOutput?
    private var synchronizer: AVCaptureDataOutputSynchronizer?

    func requestAccessAndSetup() async {
        guard await AVCaptureDevice.requestAccess(for: .video) else { return }
        await withCheckedContinuation { continuation in
            videoQueue.async {
                self.configureSession()
                continuation.resume()
            }
        }
    }

    /// Wires the pose pipeline to whichever capture mode came up: synchronized when
    /// we've got a depth output, plain video-delegate otherwise.
    func setFrameDelegate(_ delegate: FrameDelegate) {
        if let synchronizer {
            synchronizer.setDelegate(delegate, queue: videoQueue)
        } else {
            videoOutput?.setSampleBufferDelegate(delegate, queue: videoQueue)
        }
    }

    func start() {
        videoQueue.async {
            guard !self.session.isRunning else { return }
            self.session.startRunning()
        }
    }

    func stop() {
        videoQueue.async {
            guard self.session.isRunning else { return }
            self.session.stopRunning()
        }
    }

    private func configureSession() {
        // Don't let the capture session touch our audio session — SoundEffects already
        // owns it and the camera reconfiguring it causes audio dropouts on first use.
        session.automaticallyConfiguresApplicationAudioSession = false
        session.beginConfiguration()
        session.sessionPreset = .hd1280x720

        // Prefer TrueDepth (exposes IR depth alongside RGB); fall back to wide-angle
        // on devices without it (SE line, older non-Face-ID phones).
        let trueDepth = AVCaptureDevice.default(.builtInTrueDepthCamera, for: .video, position: .front)
        let wideAngle = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
        guard
            let device = trueDepth ?? wideAngle,
            let input = try? AVCaptureDeviceInput(device: device),
            session.canAddInput(input)
        else {
            session.commitConfiguration()
            Log.line("[Camera]", "no front camera available — session configuration aborted")
            return
        }
        session.addInput(input)

        try? device.lockForConfiguration()
        device.videoZoomFactor = device.minAvailableVideoZoomFactor
        device.unlockForConfiguration()

        let video = AVCaptureVideoDataOutput()
        video.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        ]
        video.alwaysDiscardsLateVideoFrames = true

        guard session.canAddOutput(video) else {
            session.commitConfiguration()
            Log.line("[Camera]", "couldn't add video output — session configuration aborted")
            return
        }
        session.addOutput(video)
        videoOutput = video

        // Depth only when we got TrueDepth. AVCaptureDepthDataOutput is unsupported
        // on wide-angle front cameras without the IR projector.
        let usingTrueDepth = (trueDepth != nil) && (device == trueDepth)
        if usingTrueDepth {
            configureDepth(device: device, video: video)
        } else {
            Log.line("[Camera]", "TrueDepth unavailable — running video-only (no 3D)")
        }

        session.commitConfiguration()
    }

    /// Adds an `AVCaptureDepthDataOutput`, picks the smallest supported depth format
    /// (lower res = less power, plenty of precision for ~15 keypoints), throttles to
    /// 10 FPS to match the Vision pipeline, and creates a synchronizer over video+depth.
    private func configureDepth(device: AVCaptureDevice, video: AVCaptureVideoDataOutput) {
        let depth = AVCaptureDepthDataOutput()
        depth.isFilteringEnabled = false  // raw depth; we handle holes ourselves
        depth.alwaysDiscardsLateDepthData = true

        guard session.canAddOutput(depth) else {
            Log.line("[Camera]", "TrueDepth present but depth output not addable — video-only")
            return
        }
        session.addOutput(depth)
        depthOutput = depth

        let supported = device.activeFormat.supportedDepthDataFormats
        guard !supported.isEmpty else {
            Log.line(
                "[Camera]",
                "active video format exposes no depth formats — video-only"
            )
            return
        }
        // Pick the smallest resolution available (typically 320×240 on newer phones,
        // 640×480 on older). We sample a 3×3 patch per keypoint — we don't need more.
        let chosen = supported.min(by: {
            let a = CMVideoFormatDescriptionGetDimensions($0.formatDescription).width
            let b = CMVideoFormatDescriptionGetDimensions($1.formatDescription).width
            return a < b
        })!

        try? device.lockForConfiguration()
        device.activeDepthDataFormat = chosen
        // Match the Vision pose-estimation throttle; IR pulses per delivered frame,
        // so 10 FPS is ~3× less battery than the default 30 FPS.
        device.activeDepthDataMinFrameDuration = CMTime(value: 1, timescale: 10)
        device.unlockForConfiguration()

        let dims = CMVideoFormatDescriptionGetDimensions(chosen.formatDescription)
        Log.line(
            "[Camera]",
            "TrueDepth active  depth=\(dims.width)×\(dims.height)  throttle=10fps"
        )

        synchronizer = AVCaptureDataOutputSynchronizer(dataOutputs: [video, depth])
    }
}
