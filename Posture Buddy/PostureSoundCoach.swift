import Foundation
import Combine

/// Plays subtle audio feedback when posture state transitions:
///   • Yellow/red (fair or poor) sustained for 10 seconds → quiet descending "beep-boop"
///   • Green (good) sustained for 10 seconds after a slouch alert → quiet ascending "boop-beep"
///
/// Sustained-state timers in both directions mean brief grade flutters don't trigger sounds.
/// The recovery sound only fires if the slouch sound played first (hysteresis).
private let slouchDelay: TimeInterval = 6.0
private let recoveryDelay: TimeInterval = 3.0

@MainActor
final class PostureSoundCoach: ObservableObject {
    private var slouchTimerTask: Task<Void, Never>?
    private var recoveryTimerTask: Task<Void, Never>?
    private var isAlerted = false  // true once the slouch sound has played
    private var lastGrade: PostureScore.Grade? = nil

    func update(score: PostureScore?) {
        let grade = score?.grade
        if grade != lastGrade {
            Log.line("[Coach]", "grade: \(Self.describe(lastGrade)) → \(Self.describe(grade))")
            lastGrade = grade
        }

        guard let grade else {
            // Upstream stream cleared (pose lost, pause, or calibration reset). Cancel
            // everything in flight so we don't fire stale sounds when scoring resumes.
            if slouchTimerTask != nil || recoveryTimerTask != nil || isAlerted {
                Log.line(
                    "[Coach]",
                    "score cleared — resetting  "
                    + "(slouch=\(slouchTimerTask != nil) recovery=\(recoveryTimerTask != nil) "
                    + "alerted=\(isAlerted))"
                )
            }
            reset()
            return
        }

        switch grade {
        case .good:
            // Not fair/poor anymore — cancel slouch timer
            slouchTimerTask?.cancel()
            slouchTimerTask = nil
            // Start recovery timer only if we previously alerted and one isn't already running
            guard isAlerted, recoveryTimerTask == nil else { return }
            Log.line("[Coach]", "good posture — starting \(recoveryDelay)s recovery timer")
            recoveryTimerTask = scheduleDelayed(delay: recoveryDelay) { [weak self] in
                self?.recoveryTimerTask = nil
                self?.isAlerted = false
                Log.line("[Coach]", "🔊 playing recovery sound")
                SoundEffects.playRecovery()
            }

        case .fair, .poor:
            // Not good anymore — cancel recovery timer
            recoveryTimerTask?.cancel()
            recoveryTimerTask = nil
            // Already alerted — wait for recovery
            guard !isAlerted else { return }
            // Already waiting — let the timer finish
            guard slouchTimerTask == nil else { return }
            Log.line("[Coach]", "poor posture — starting \(slouchDelay)s slouch timer")
            slouchTimerTask = scheduleDelayed(delay: slouchDelay) { [weak self] in
                self?.slouchTimerTask = nil
                self?.isAlerted = true
                Log.line("[Coach]", "🔊 playing slouch sound")
                SoundEffects.playSlouch()
            }
        }
    }

    func reset() {
        slouchTimerTask?.cancel()
        slouchTimerTask = nil
        recoveryTimerTask?.cancel()
        recoveryTimerTask = nil
        isAlerted = false
        lastGrade = nil
    }

    private static func describe(_ grade: PostureScore.Grade?) -> String {
        grade?.label ?? "nil"
    }

    private func scheduleDelayed(
        delay: TimeInterval,
        _ action: @escaping @MainActor () -> Void
    ) -> Task<Void, Never> {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            action()
        }
    }
}
