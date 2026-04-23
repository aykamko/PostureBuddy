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
    private static let postCaptureMarimbaPause: Duration = .milliseconds(400)
    private static let countdownBeatInterval: Duration = .seconds(1)

    // Burst-sample the pose estimator during the hold-after-beat window and take the
    // median. Single-frame capture was catching detector spikes; a short burst gives
    // a baseline that matches the user's steady state.
    private static let burstSampleInterval: Duration = .milliseconds(125)
    private static let burstSampleCount: Int = 10
    private static let burstMinSuccessfulSamples: Int = 6

    // Order drives snapshot index → baseline slot mapping in `runFlow`
    // (0=center/middle, 1=left, 2=right, 3=leanForward). The three yaw captures
    // run first in one natural head-scan sequence; the forward-lean sample comes
    // last, at the center yaw, to derive `forwardSign` (see PostureModels).
    // `voice == nil` falls back to a stub sound effect — no steps use that now that
    // every prompt has a recorded clip, but we keep the optional for flexibility.
    private static let steps: [(label: String, instruction: String, voice: VoicePrompt?)] = [
        ("middle", "Sit up straight, look at the center", .sitStraightLookCenter),
        ("left", "Look at the left of your screen", .lookLeft),
        ("right", "Look at the right of your screen", .lookRight),
        ("leanForward", "Look at the center and lean forward", .leanForward),
    ]

    /// Starts a fresh guided calibration. If one was already running, it's cancelled first.
    /// Discards any existing calibration and quiets in-flight slouch/recovery timers +
    /// the pending-alert banner so nothing fires while the user is repositioning.
    /// On success, commits three baselines to the pose estimator and resets the sound coach.
    func start(
        poseEstimator: PoseEstimator,
        soundCoach: PostureSoundCoach,
        notificationManager: NotificationManager
    ) {
        task?.cancel()
        poseEstimator.resetCalibration()
        soundCoach.reset()
        notificationManager.update(score: nil)
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

        // No separate intro voice — the first step's prompt ("Starting calibration,
        // please sit up straight and look at the center of your screen") does double
        // duty as the session intro.
        var snapshots: [PostureAngles] = []
        for step in Self.steps {
            guard let angles = try await captureSnapshot(for: step, poseEstimator: poseEstimator) else {
                return  // capture aborted with voice prompt; cleanup() will have run
            }
            snapshots.append(angles)
        }

        // Index order must match Self.steps: 0=center (middle yaw), 1=left, 2=right, 3=leanForward.
        let committed = poseEstimator.calibrate(
            middle: snapshots[0],
            forwardLean: snapshots[3],
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
        for step: (label: String, instruction: String, voice: VoicePrompt?),
        poseEstimator: PoseEstimator
    ) async throws -> PostureAngles? {
        instruction = step.instruction
        if let voice = step.voice {
            await VoiceGuide.shared.say(voice)
        } else {
            // Stub audio for positions without a recorded voice prompt (currently
            // the lean-forward step). Using `playSlouch` because leaning forward is
            // the posture it maps to — placeholder until we cut a real clip.
            SoundEffects.playSlouch()
        }
        try Task.checkCancellation()
        try await Task.sleep(for: Self.postVoicePause)

        // Beats 3 and 2 are "tick" notes; beat 1 is the capture.
        try await playBeat(number: 3, tick: 0)
        try await playBeat(number: 2, tick: 1)

        countdown = 1
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        SoundEffects.playCapture()

        // Burst-sample the pose estimator for ~1s so the baseline is a median across
        // several frames, not one jittery snapshot.
        var samples: [PostureAngles] = []
        for _ in 0..<Self.burstSampleCount {
            try await Task.sleep(for: Self.burstSampleInterval)
            try Task.checkCancellation()
            if let a = poseEstimator.snapshotCurrentAngles() { samples.append(a) }
        }

        guard
            samples.count >= Self.burstMinSuccessfulSamples,
            let merged = PostureAngles.median(of: samples)
        else {
            await VoiceGuide.shared.say(.poseNotDetected)
            cleanup()
            return nil
        }

        let telemetry = merged.yawTelemetry?.debugString ?? "n/a"
        Log.line(
            "[YawTelemetry]",
            "\(step.label) (median of \(samples.count)): \(telemetry)"
        )

        countdown = nil
        try await Task.sleep(for: Self.postCaptureMarimbaPause)
        return merged
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
