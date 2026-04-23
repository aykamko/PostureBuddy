import AVFoundation
import Foundation

/// Keys for the pre-recorded voice prompts bundled under `VoicePrompts/*.aiff`.
/// Raw values match the filename (without extension).
enum VoicePrompt: String, CaseIterable {
    // Fused intro + first-position prompt: "Starting calibration! Please sit up
    // straight and look at the center of your screen."
    case sitStraightLookCenter = "sit_straight_look_center"
    case lookLeft = "look_left"
    case lookRight = "look_right"
    case leanForward = "lean_forward"
    case calibrationComplete = "calibration_complete"
    case poseNotDetected = "pose_not_detected"
}

/// Plays pre-recorded voice prompts from the app bundle.
/// Previously used `AVSpeechSynthesizer`, but iOS default TTS voices sound robotic
/// and premium voices require per-user downloads. Instead we ship recordings
/// generated with ElevenLabs (Clara) and bundled as `VoicePrompts/*.aiff`. Raw
/// editing + conversion workflow lives in `CLAUDE.md` under "Re-recording the
/// voice prompts."
@MainActor
final class VoiceGuide: NSObject {
    static let shared = VoiceGuide()

    private var players: [VoicePrompt: AVAudioPlayer] = [:]
    private var currentPlayer: AVAudioPlayer?
    private var finishContinuation: CheckedContinuation<Void, Never>?

    private override init() {
        super.init()
    }

    /// Plays the given prompt and suspends until it finishes or is cancelled.
    func say(_ prompt: VoicePrompt) async {
        // Stop anything currently playing so we don't queue or overlap.
        cancelCurrent()
        guard let player = loadPlayer(for: prompt) else { return }
        player.delegate = self
        player.currentTime = 0
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            finishContinuation = cont
            currentPlayer = player
            player.play()
        }
    }

    func cancel() {
        cancelCurrent()
    }

    private func cancelCurrent() {
        currentPlayer?.stop()
        currentPlayer = nil
        resumePendingContinuation()
    }

    private func resumePendingContinuation() {
        guard let continuation = finishContinuation else { return }
        finishContinuation = nil
        continuation.resume()
    }

    @discardableResult
    private func loadPlayer(for prompt: VoicePrompt) -> AVAudioPlayer? {
        if let existing = players[prompt] { return existing }
        guard let url = Bundle.main.url(forResource: prompt.rawValue, withExtension: "aiff") else {
            print("[VoiceGuide] missing audio file: \(prompt.rawValue).aiff")
            return nil
        }
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.prepareToPlay()
            players[prompt] = player
            return player
        } catch {
            print("[VoiceGuide] failed to load \(prompt.rawValue): \(error)")
            return nil
        }
    }
}

extension VoiceGuide: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.handlePlaybackComplete()
        }
    }

    private func handlePlaybackComplete() {
        currentPlayer = nil
        resumePendingContinuation()
    }
}
