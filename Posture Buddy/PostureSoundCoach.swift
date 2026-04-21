import Foundation
import Combine

/// Plays subtle audio feedback when posture state transitions:
///   • Yellow/red (fair or poor) sustained for 10 seconds → quiet descending "beep-boop"
///   • Green (good) sustained for 10 seconds after a slouch alert → quiet ascending "boop-beep"
///
/// Sustained-state timers in both directions mean brief grade flutters don't trigger sounds.
/// The recovery sound only fires if the slouch sound played first (hysteresis).
@MainActor
final class PostureSoundCoach: ObservableObject {
    var slouchDelay: TimeInterval = 10.0
    var recoveryDelay: TimeInterval = 10.0

    private var slouchTimerTask: Task<Void, Never>?
    private var recoveryTimerTask: Task<Void, Never>?
    private var isAlerted = false  // true once the slouch sound has played

    func update(score: PostureScore?) {
        guard let grade = score?.grade else {
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
            recoveryTimerTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(self?.recoveryDelay ?? 10.0))
                if Task.isCancelled { return }
                guard let self else { return }
                self.recoveryTimerTask = nil
                self.isAlerted = false
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
            slouchTimerTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(self?.slouchDelay ?? 10.0))
                if Task.isCancelled { return }
                guard let self else { return }
                self.slouchTimerTask = nil
                self.isAlerted = true
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
    }
}
