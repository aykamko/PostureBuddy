import AVFoundation
import Vision
import Combine
import os
import simd

struct DetectedPose {
    let keypoints: [HumanBodyPose3DObservation.JointName: CGPoint]
    let score: PostureScore
}

enum ThreeDStatus {
    case unknown
    case available
    case unavailable
}

final class PoseEstimator: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    @Published var currentPose: DetectedPose?
    @Published var threeDStatus: ThreeDStatus = .unknown

    nonisolated private let analyzer = PostureAnalyzer()
    private let lastProcessedTime = OSAllocatedUnfairLock(initialState: CFTimeInterval(0))
    private let smoothedScore = OSAllocatedUnfairLock(initialState: Float(100))
    private let visionOrientation = OSAllocatedUnfairLock(initialState: CGImagePropertyOrientation.leftMirrored)
    private let lastLogTime = OSAllocatedUnfairLock(initialState: CFTimeInterval(0))
    private let sessionStartTime = OSAllocatedUnfairLock<CFTimeInterval?>(initialState: nil)
    private let requestInFlight = OSAllocatedUnfairLock(initialState: false)
    private static let threeDProbationSeconds: CFTimeInterval = 5.0

    func updateOrientation(_ orientation: CGImagePropertyOrientation) {
        visionOrientation.withLock { $0 = orientation }
    }

    nonisolated func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        let now = CACurrentMediaTime()

        let shouldProcess = lastProcessedTime.withLock { lastTime in
            guard now - lastTime >= 0.1 else { return false }
            lastTime = now
            return true
        }
        guard shouldProcess else { return }

        // Only one Vision request in flight at a time (prevents task pile-up if inference is slow)
        let claimed = requestInFlight.withLock { inFlight in
            guard !inFlight else { return false }
            inFlight = true
            return true
        }
        guard claimed else { return }

        sessionStartTime.withLock { start in
            if start == nil { start = now }
        }

        let orientation = visionOrientation.withLock { $0 }

        Task { [weak self] in
            guard let self else { return }
            defer { self.requestInFlight.withLock { $0 = false } }

            let request = DetectHumanBodyPose3DRequest()
            do {
                let observations = try await request.perform(on: sampleBuffer, orientation: orientation)
                self.handle(observations: observations, now: now)
            } catch {
                self.handleFailure(error: error, now: now)
            }
        }
    }

    private func handle(observations: [HumanBodyPose3DObservation], now: CFTimeInterval) {
        let shouldLog = lastLogTime.withLock { last in
            guard now - last >= 2.0 else { return false }
            last = now
            return true
        }

        guard let observation = observations.first else {
            checkProbation(now: now)
            if shouldLog { print("[Posture] no 3D observation") }
            return
        }

        Task { @MainActor in
            if self.threeDStatus != .available { self.threeDStatus = .available }
        }

        guard let score = analyzer.analyze3D(observation) else {
            if shouldLog { print("[Posture] 3D observation present but analyzer returned nil") }
            return
        }

        let finalScore = smoothedScore.withLock { currentSmoothed in
            let newSmoothed = 0.8 * currentSmoothed + 0.2 * score.value
            currentSmoothed = newSmoothed
            return PostureScore(value: newSmoothed)
        }

        if shouldLog {
            print("[Posture] score=\(String(format: "%.1f", finalScore.value))")
        }

        let keypoints = extractKeypoints(from: observation)
        let pose = DetectedPose(keypoints: keypoints, score: finalScore)

        Task { @MainActor in
            self.currentPose = pose
        }
    }

    private func handleFailure(error: Error, now: CFTimeInterval) {
        let shouldLog = lastLogTime.withLock { last in
            guard now - last >= 2.0 else { return false }
            last = now
            return true
        }
        if shouldLog { print("[Posture] 3D Vision error: \(error)") }
        checkProbation(now: now)
    }

    private func checkProbation(now: CFTimeInterval) {
        let startedAt = sessionStartTime.withLock { $0 } ?? now
        if now - startedAt >= Self.threeDProbationSeconds {
            Task { @MainActor in
                if self.threeDStatus == .unknown { self.threeDStatus = .unavailable }
            }
        }
    }

    private func extractKeypoints(
        from observation: HumanBodyPose3DObservation
    ) -> [HumanBodyPose3DObservation.JointName: CGPoint] {
        let joints: [HumanBodyPose3DObservation.JointName] = [
            .topHead, .centerHead,
            .leftShoulder, .rightShoulder,
            .leftElbow, .rightElbow,
            .leftWrist, .rightWrist,
            .spine, .root,
            .leftHip, .rightHip,
            .leftKnee, .rightKnee,
            .leftAnkle, .rightAnkle
        ]
        var result: [HumanBodyPose3DObservation.JointName: CGPoint] = [:]
        for joint in joints {
            let np = observation.pointInImage(for: joint)
            result[joint] = CGPoint(x: np.x, y: np.y)
        }
        return result
    }
}
