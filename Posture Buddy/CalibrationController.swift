import Combine
import Foundation
import UIKit

/// Drives the guided-calibration flow end-to-end: voice prompts, marimba countdown,
/// haptics, and snapshot capture at each of the three head positions (middle/left/right).
/// Publishes `instruction` and `countdown` so the UI can reflect progress; holds a single
/// cancellable `Task` so `cancel()` unwinds the flow cleanly from anywhere.
@MainActor
final class CalibrationController: ObservableObject {
    @Published private(set) var instruction: String?
    @Published private(set) var countdown: Int?

    var isActive: Bool { instruction != nil || countdown != nil }

    private var task: Task<Void, Never>?

    // Pacing. File-scope constants would also work, but keeping them here keeps the
    // flow's tunables colocated with the code that uses them.
    private static let postVoicePause: Duration = .milliseconds(300)
    private static let captureHoldAfterBeat: Duration = .milliseconds(500)
    private static let postCaptureMarimbaPause: Duration = .milliseconds(400)
    private static let countdownBeatInterval: Duration = .seconds(1)

    private static let steps: [(instruction: String, voice: VoicePrompt)] = [
        ("Look at the middle of your screen", .lookMiddle),
        ("Look at the left of your screen", .lookLeft),
        ("Look at the right of your screen", .lookRight),
    ]

    /// Starts a fresh guided calibration. If one was already running, it's cancelled first.
    /// On success, commits three baselines to the pose estimator and resets the sound coach.
    func start(poseEstimator: PoseEstimator, soundCoach: PostureSoundCoach) {
        task?.cancel()
        instruction = "Get ready…"
        task = Task { @MainActor in
            do {
                try await runFlow(poseEstimator: poseEstimator, soundCoach: soundCoach)
            } catch {
                cleanup()
            }
        }
    }

    /// Cancels any running flow and resets UI state. Previous baselines on the pose
    /// estimator are left intact.
    func cancel() {
        task?.cancel()
        task = nil
        cleanup()
    }

    private func runFlow(poseEstimator: PoseEstimator, soundCoach: PostureSoundCoach) async throws {
        // Warm up audio pipeline before the first real tone.
        await SoundEffects.prime()
        try Task.checkCancellation()

        instruction = "Sit up straight"
        await VoiceGuide.shared.say(.letsCalibrate)
        try Task.checkCancellation()
        try await Task.sleep(for: Self.postVoicePause)

        var snapshots: [PostureAngles] = []
        for step in Self.steps {
            guard let angles = try await captureSnapshot(for: step, poseEstimator: poseEstimator) else {
                return  // capture aborted with voice prompt; cleanup() will have run
            }
            snapshots.append(angles)
        }

        let committed = poseEstimator.calibrate(
            middle: snapshots[0],
            left: snapshots[1],
            right: snapshots[2]
        )
        guard committed else {
            await VoiceGuide.shared.say(.poseNotDetected)
            cleanup()
            return
        }
        soundCoach.reset()

        instruction = "Calibration complete"
        await VoiceGuide.shared.say(.calibrationComplete)
        instruction = nil
    }

    /// Runs one position's full sequence: voice → countdown beats → capture → hold.
    /// Returns nil (after triggering cleanup + playing the failure prompt) if the pose
    /// estimator couldn't snapshot valid angles at the capture moment.
    private func captureSnapshot(
        for step: (instruction: String, voice: VoicePrompt),
        poseEstimator: PoseEstimator
    ) async throws -> PostureAngles? {
        instruction = step.instruction
        await VoiceGuide.shared.say(step.voice)
        try Task.checkCancellation()
        try await Task.sleep(for: Self.postVoicePause)

        // Beats 3 and 2 are "tick" notes; beat 1 is the capture.
        try await playBeat(number: 3, tick: 0)
        try await playBeat(number: 2, tick: 1)

        countdown = 1
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        SoundEffects.playCapture()

        guard let angles = poseEstimator.snapshotCurrentAngles() else {
            await VoiceGuide.shared.say(.poseNotDetected)
            cleanup()
            return nil
        }
        let telemetry = poseEstimator.snapshotCurrentTelemetry()?.debugString ?? "n/a"
        print("[YawTelemetry] \(step.voice.rawValue): \(telemetry)")

        try await Task.sleep(for: Self.captureHoldAfterBeat)
        countdown = nil
        try await Task.sleep(for: Self.postCaptureMarimbaPause)
        return angles
    }

    /// Sets the countdown number, plays the matching marimba tick + light haptic, then
    /// waits one beat interval.
    private func playBeat(number: Int, tick: Int) async throws {
        countdown = number
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        SoundEffects.playTick(index: tick)
        try await Task.sleep(for: Self.countdownBeatInterval)
    }

    private func cleanup() {
        VoiceGuide.shared.cancel()
        instruction = nil
        countdown = nil
    }
}
