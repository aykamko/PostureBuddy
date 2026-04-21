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
    // Resolved once on first use. Falls back gracefully if enhanced/premium aren't installed.
    private lazy var preferredVoice: AVSpeechSynthesisVoice? = Self.pickBestVoice()

    private override init() {
        super.init()
        synthesizer.delegate = self
    }

    /// Picks the best available en-US voice: premium > enhanced > default.
    /// Premium/enhanced voices require the user to download them via
    /// Settings → Accessibility → Spoken Content → Voices.
    private static func pickBestVoice() -> AVSpeechSynthesisVoice? {
        let enUS = AVSpeechSynthesisVoice.speechVoices().filter { $0.language == "en-US" }
        let qualityOrder: [AVSpeechSynthesisVoiceQuality] = [.premium, .enhanced, .default]
        for quality in qualityOrder {
            if let voice = enUS.first(where: { $0.quality == quality }) {
                print("[VoiceGuide] using voice \(voice.name) quality=\(quality.label)")
                return voice
            }
        }
        print("[VoiceGuide] no en-US voice found; falling back to default")
        return AVSpeechSynthesisVoice(language: "en-US")
    }

    /// Speaks the given text and suspends until the utterance is finished or cancelled.
    func say(_ text: String, rate: Float = AVSpeechUtteranceDefaultSpeechRate * 0.95) async {
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            finishContinuation = cont
            let utterance = AVSpeechUtterance(string: text)
            utterance.rate = rate
            utterance.voice = preferredVoice
            synthesizer.speak(utterance)
        }
    }

    func cancel() {
        synthesizer.stopSpeaking(at: .immediate)
    }
}

private extension AVSpeechSynthesisVoiceQuality {
    var label: String {
        switch self {
        case .default: return "default"
        case .enhanced: return "enhanced"
        case .premium: return "premium"
        @unknown default: return "unknown"
        }
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
