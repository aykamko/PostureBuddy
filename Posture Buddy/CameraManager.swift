import AVFoundation
import Combine

final class CameraManager: ObservableObject {
    let session = AVCaptureSession()

    @Published var isAuthorized = false
    @Published var isRunning = false

    private let videoQueue = DispatchQueue(label: "posture.video", qos: .userInitiated)
    private var videoOutput: AVCaptureVideoDataOutput?

    func requestAccessAndSetup() async {
        let status = await AVCaptureDevice.requestAccess(for: .video)
        await MainActor.run { self.isAuthorized = status }
        guard status else { return }
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
            Task { @MainActor in self.isRunning = true }
        }
    }

    func stop() {
        videoQueue.async {
            guard self.session.isRunning else { return }
            self.session.stopRunning()
            Task { @MainActor in self.isRunning = false }
        }
    }

    private func configureSession() {
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

        try? device.lockForConfiguration()
        device.videoZoomFactor = device.minAvailableVideoZoomFactor
        device.unlockForConfiguration()

        let output = AVCaptureVideoDataOutput()
        // Vision's 3D pose pipeline needs IOSurface-backed, Metal-compatible BGRA buffers.
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as CFDictionary,
            kCVPixelBufferMetalCompatibilityKey as String: true
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
