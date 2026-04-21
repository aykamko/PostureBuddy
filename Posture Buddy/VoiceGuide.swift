import AVFoundation
import Foundation

/// Thin wrapper around `AVSpeechSynthesizer` that exposes an `async` `say(_:)`
/// which returns when the utterance finishes (or is cancelled). Used to guide
/// the user through multi-step calibration.
@MainActor
final class VoiceGuide: NSObject {
    static let shared = VoiceGuide()

    private let synthesizer = AVSpeechSynthesizer()
    private var finishContinuation: CheckedContinuation<Void, Never>?

    private override init() {
        super.init()
        synthesizer.delegate = self
    }

    /// Speaks the given text and suspends until the utterance is finished or cancelled.
    /// Safe to call on MainActor; internally uses the delegate for completion.
    func say(_ text: String, rate: Float = AVSpeechUtteranceDefaultSpeechRate * 0.95) async {
        // If something was previously speaking, stop it so we don't queue up.
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            finishContinuation = cont
            let utterance = AVSpeechUtterance(string: text)
            utterance.rate = rate
            utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
            synthesizer.speak(utterance)
        }
    }

    func cancel() {
        synthesizer.stopSpeaking(at: .immediate)
    }
}

extension VoiceGuide: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.resumeContinuation() }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.resumeContinuation() }
    }

    private func resumeContinuation() {
        finishContinuation?.resume()
        finishContinuation = nil
    }
}
