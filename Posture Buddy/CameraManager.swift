import AVFoundation
import Combine

final class CameraManager: ObservableObject {
    let session = AVCaptureSession()

    private let videoQueue = DispatchQueue(label: "posture.video", qos: .userInitiated)
    private var videoOutput: AVCaptureVideoDataOutput?

    func requestAccessAndSetup() async {
        guard await AVCaptureDevice.requestAccess(for: .video) else { return }
        await withCheckedContinuation { continuation in
            videoQueue.async {
                self.configureSession()
                continuation.resume()
            }
        }
    }

    func setSampleBufferDelegate(_ delegate: AVCaptureVideoDataOutputSampleBufferDelegate) {
        videoOutput?.setSampleBufferDelegate(delegate, queue: videoQueue)
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

        guard
            let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front),
            let input = try? AVCaptureDeviceInput(device: device),
            session.canAddInput(input)
        else {
            session.commitConfiguration()
            return
        }
        session.addInput(input)

        // Disable Center Stage: we want the raw wide frame, not iOS auto-framing
        // on the user's face (which would crop/pan the feed and invalidate our
        // bbox-normalized yaw features). `.app` mode overrides the system-wide
        // toggle for this session only. Both properties are class-level on
        // AVCaptureDevice, not per-device, so they live outside the lock.
        AVCaptureDevice.centerStageControlMode = .app
        AVCaptureDevice.isCenterStageEnabled = false

        try? device.lockForConfiguration()
        device.videoZoomFactor = device.minAvailableVideoZoomFactor
        device.unlockForConfiguration()

        let output = AVCaptureVideoDataOutput()
        // Use the camera's native YUV format — avoids on-the-fly conversion per frame.
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        ]
        output.alwaysDiscardsLateVideoFrames = true

        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            return
        }
        session.addOutput(output)
        videoOutput = output

        session.commitConfiguration()
    }
}
