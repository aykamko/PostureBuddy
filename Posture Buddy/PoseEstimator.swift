import AVFoundation
import Vision
import Combine
import os

struct DetectedPose {
    let keypoints: [VNHumanBodyPoseObservation.JointName: CGPoint]
    let score: PostureScore?   // nil until user calibrates
}

final class PoseEstimator: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    @Published var currentPose: DetectedPose?
    @Published var isCalibrated: Bool = false
    @Published var isTrackingReady: Bool = false

    nonisolated private let analyzer = PostureAnalyzer()
    private let lastProcessedTime = OSAllocatedUnfairLock(initialState: CFTimeInterval(0))
    private let smoothedScore = OSAllocatedUnfairLock(initialState: Float(100))
    private let visionOrientation = OSAllocatedUnfairLock(initialState: CGImagePropertyOrientation.leftMirrored)
    private let lastLogTime = OSAllocatedUnfairLock(initialState: CFTimeInterval(0))

    // Most-recent per-frame angles (for calibration capture)
    private let currentAngles = OSAllocatedUnfairLock<PostureAngles?>(initialState: nil)
    // Calibrated references (middle / left / right); nil until user completes calibration
    private let baselines = OSAllocatedUnfairLock<PostureBaselines?>(initialState: nil)

    func updateOrientation(_ orientation: CGImagePropertyOrientation) {
        visionOrientation.withLock { $0 = orientation }
    }

    /// Returns the most-recent frame's computed angles, or nil if the current frame
    /// didn't yield a valid pose. Used by the calibration flow to snapshot per-position.
    func snapshotCurrentAngles() -> PostureAngles? {
        currentAngles.withLock { $0 }
    }

    /// Commits the three-position baselines (after guided calibration completes).
    func calibrate(middle: PostureAngles, left: PostureAngles, right: PostureAngles) {
        let b = PostureBaselines(middle: middle, left: left, right: right)
        baselines.withLock { $0 = b }
        smoothedScore.withLock { $0 = 100 }
        isCalibrated = true
        print("[Posture] calibrated 3 positions  middle.yaw=\(middle.yawSignature.map { String(format: "%.3f", $0) } ?? "nil")  left.yaw=\(left.yawSignature.map { String(format: "%.3f", $0) } ?? "nil")  right.yaw=\(right.yawSignature.map { String(format: "%.3f", $0) } ?? "nil")")
    }

    func clearCalibration() {
        baselines.withLock { $0 = nil }
        isCalibrated = false
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

        let request = VNDetectHumanBodyPoseRequest()
        let orientation = visionOrientation.withLock { $0 }
        let handler = VNImageRequestHandler(cmSampleBuffer: sampleBuffer, orientation: orientation)
        try? handler.perform([request])

        guard let observation = request.results?.first else { return }

        let shouldLog = lastLogTime.withLock { last in
            guard now - last >= 2.0 else { return false }
            last = now
            return true
        }

        let angles = analyzer.computeAngles(observation)
        currentAngles.withLock { $0 = angles }

        let currentBaselines = baselines.withLock { $0 }

        // Compute score only if calibrated AND analyzer can classify the head position
        let finalScore: PostureScore?
        if let angles, let currentBaselines, let raw = analyzer.score(current: angles, baselines: currentBaselines) {
            let smoothed = smoothedScore.withLock { current in
                let new = 0.8 * current + 0.2 * raw.value
                current = new
                return PostureScore(value: new)
            }
            finalScore = smoothed
        } else {
            finalScore = nil
        }

        if shouldLog {
            if let finalScore {
                print("[Posture] score=\(String(format: "%.1f", finalScore.value)) [\(finalScore.grade.label)]")
            } else if currentBaselines != nil && angles != nil {
                print("[Posture] paused — head position not recognized")
            } else if angles != nil {
                print("[Posture] angles available; awaiting calibration")
            } else {
                print("[Posture] no valid keypoints")
            }
        }

        let keypoints = extractKeypoints(from: observation)
        let pose = DetectedPose(keypoints: keypoints, score: finalScore)
        let hasValidAngles = angles != nil

        Task { @MainActor in
            self.currentPose = pose
            if hasValidAngles && !self.isTrackingReady {
                self.isTrackingReady = true
            }
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
}
