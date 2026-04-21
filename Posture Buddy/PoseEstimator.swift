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
    // Calibrated reference; nil until user taps Calibrate
    private let baseline = OSAllocatedUnfairLock<PostureAngles?>(initialState: nil)
g 
    func updateOrientation(_ orientation: CGImagePropertyOrientation) {
        visionOrientation.withLock { $0 = orientation }
    }

    // Called from UI when user taps Calibrate. Snapshots the last observed angles as baseline.
    func calibrate() {
        let snapshot = currentAngles.withLock { $0 }
        guard let snapshot else { return }
        baseline.withLock { $0 = snapshot }
        smoothedScore.withLock { $0 = 100 }
        isCalibrated = true
        print("[Posture] calibrated: earShoulder=\(snapshot.earShoulderAngle)° shoulderHip=\(snapshot.shoulderHipAngle.map { "\($0)°" } ?? "nil")")
    }

    func clearCalibration() {
        baseline.withLock { $0 = nil }
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

        let currentBaseline = baseline.withLock { $0 }

        // Compute score only if calibrated
        let finalScore: PostureScore?
        if let angles, let currentBaseline {
            let raw = analyzer.score(current: angles, baseline: currentBaseline)
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
