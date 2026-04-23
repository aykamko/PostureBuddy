import AVFoundation
import Foundation

/// Equal-tempered note frequencies (Hz, A4 = 440). Add cases as needed; keeping
/// only the ones we actually use here.
private enum Note: Float {
    case c3 = 130.81
    case g3 = 196.00
    case f4 = 349.23
    case g4 = 392.00
    case a4 = 440.00
    case b4 = 493.88
    case c5 = 523.25
}

/// Plays synthesized marimba-like tones.
/// Design notes for smooth playback:
///  - Tone buffers are pre-generated on a background queue at startup so playback never
///    synthesizes on the main thread.
///  - `prime()` schedules a 1-second silent buffer so the audio render thread warms up
///    before the first real tone arrives. Call it and wait ~1s before starting a countdown.
///  - The format matches the hardware sample rate so the mainMixerNode never has to
///    resample on the real-time audio thread.
///  - A 40ms I/O buffer is requested (vs. the ~23ms default) for more tolerance of CPU spikes.
final class SoundEffects {
    static let shared = SoundEffects()

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let sampleRate: Double
    private let format: AVAudioFormat
    private var audioSessionConfigured = false

    // Pre-generated buffers, populated asynchronously by configure()
    private var tickBuffers: [AVAudioPCMBuffer] = []
    private var captureBuffer: AVAudioPCMBuffer?
    private var slouchBuffer: AVAudioPCMBuffer?         // descending "beep-boop" on poor posture (initial)
    private var slouchReminderBuffer: AVAudioPCMBuffer? // two low C3 boops, fired every 6s while still slouching
    private var recoveryBuffer: AVAudioPCMBuffer?       // ascending "boop-beep" on return to good posture

    // Rising C major scale fragment resolving to C5 on capture.
    private static let tickNotes: [Note] = [.f4, .g4, .a4, .b4]
    private static let captureNote: Note = .c5

    /// Duration of the silent prime buffer. Callers should wait at least this long
    /// after `prime()` before scheduling real tones.
    static let primeDuration: Double = 1.0

    private init() {
        let hwRate = AVAudioSession.sharedInstance().sampleRate
        sampleRate = hwRate > 0 ? hwRate : 48000
        format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
    }

    static func configureAudioSession() {
        shared.configure()
    }

    /// Primes the render thread with a silent buffer so the first real tone plays cleanly.
    /// Awaitable — returns after the silence has played out (roughly `primeDuration`),
    /// so callers don't need to maintain their own sleep/state.
    static func prime() async {
        shared.primeInternal()
        try? await Task.sleep(for: .seconds(primeDuration))
    }

    static func playTick(index: Int) {
        shared.play(buffer: shared.bufferForTick(at: index))
    }

    static func playCapture() {
        shared.play(buffer: shared.captureBuffer)
    }

    /// Quiet descending "beep-boop" — posture has slouched (first cue only).
    static func playSlouch() {
        shared.play(buffer: shared.slouchBuffer)
    }

    /// Two low C3 boops — fired every 6s while the user is still slouching, after
    /// the initial `playSlouch()`. Same low note as the second half of the slouch
    /// pair so it feels like a continuation, not a fresh alert.
    static func playSlouchReminder() {
        shared.play(buffer: shared.slouchReminderBuffer)
    }

    /// Quiet ascending "boop-beep" — posture recovered.
    static func playRecovery() {
        shared.play(buffer: shared.recoveryBuffer)
    }

    private func configure() {
        guard !audioSessionConfigured else { return }
        audioSessionConfigured = true

        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try? session.setPreferredIOBufferDuration(0.04)
        try? session.setActive(true)
        try? engine.start()
        player.play()

        // Generate all tones off the main thread; when done, swap them in.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let ticks = Self.tickNotes.compactMap {
                Self.generateTone(note: $0, duration: 0.7, amplitude: 0.35, format: self.format, sampleRate: self.sampleRate)
            }
            let capture = Self.generateTone(
                note: Self.captureNote,
                duration: 1.4,
                amplitude: 0.5,
                format: self.format,
                sampleRate: self.sampleRate
            )
            // G3 → C3 descending for slouch; C3 → G3 ascending for recovery.
            // Reminder = two C3 boops (the resolved low note from the slouch pair),
            // played periodically while still slouching so it sounds like a sustain
            // rather than a fresh alert.
            let slouch = Self.generateBeepPair(
                first: .g3, second: .c3,
                format: self.format, sampleRate: self.sampleRate
            )
            let slouchReminder = Self.generateBeepPair(
                first: .c3, second: .c3,
                format: self.format, sampleRate: self.sampleRate
            )
            let recovery = Self.generateBeepPair(
                first: .c3, second: .g3,
                format: self.format, sampleRate: self.sampleRate
            )
            DispatchQueue.main.async {
                self.tickBuffers = ticks
                self.captureBuffer = capture
                self.slouchBuffer = slouch
                self.slouchReminderBuffer = slouchReminder
                self.recoveryBuffer = recovery
            }
        }
    }

    private func primeInternal() {
        configure()
        if let silence = Self.silentBuffer(format: format, duration: Float(Self.primeDuration)) {
            player.scheduleBuffer(silence, at: nil, options: [], completionHandler: nil)
        }
    }

    private func bufferForTick(at index: Int) -> AVAudioPCMBuffer? {
        guard !tickBuffers.isEmpty else { return nil }
        let clamped = min(max(index, 0), tickBuffers.count - 1)
        return tickBuffers[clamped]
    }

    private func play(buffer: AVAudioPCMBuffer?) {
        guard let buffer else { return }
        player.scheduleBuffer(buffer, at: nil, options: [], completionHandler: nil)
    }

    // MARK: - Synthesis

    private static func silentBuffer(format: AVAudioFormat, duration: Float) -> AVAudioPCMBuffer? {
        let frameCount = AVAudioFrameCount(Double(duration) * format.sampleRate)
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)
        else { return nil }
        buffer.frameLength = frameCount
        if let data = buffer.floatChannelData?[0] {
            for i in 0..<Int(frameCount) { data[i] = 0 }
        }
        return buffer
    }

    /// Synthesizes two short notes back-to-back with a small gap. Used for posture-state
    /// feedback (descending = slouch, ascending = recovery).
    /// Iphone speakers have poor response below ~250Hz, so we boost mid-frequency harmonics
    /// for perceived loudness while keeping the low fundamental for character.
    private static func generateBeepPair(
        first: Note,
        second: Note,
        noteDuration: Float = 0.25,
        gap: Float = 0.03,
        amplitude: Float = 1.0,
        format: AVAudioFormat,
        sampleRate: Double
    ) -> AVAudioPCMBuffer? {
        let firstFreq = first.rawValue
        let secondFreq = second.rawValue
        let totalDuration = noteDuration * 2 + gap
        let frameCount = AVAudioFrameCount(Double(totalDuration) * sampleRate)
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)
        else { return nil }
        buffer.frameLength = frameCount
        guard let data = buffer.floatChannelData?[0] else { return nil }

        let noteFrames = Int(noteDuration * Float(sampleRate))
        let gapFrames = Int(gap * Float(sampleRate))
        let twoPiOverSR = 2.0 * Float.pi / Float(sampleRate)

        // Harmonic coefficients. The 3rd harmonic gives phone-speaker presence.
        // Sum of coefficients = 1.55 → divide to keep output in [-1, 1] at amplitude 1.0.
        let h1: Float = 1.0
        let h2Coef: Float = 0.3
        let h3Coef: Float = 0.25
        let normalizer: Float = h1 + h2Coef + h3Coef

        func noteSample(localIdx: Int, frequency: Float) -> Float {
            let t = Float(localIdx) / Float(sampleRate)
            let phase = twoPiOverSR * frequency * Float(localIdx)
            // Fade-in 20ms, fade-out 30ms to avoid clicks, plus slower exp decay for sustain.
            let fadeIn = min(1, t / 0.02)
            let fadeOut = min(1, (noteDuration - t) / 0.03)
            let env = fadeIn * fadeOut * expf(-1.5 * t / noteDuration)
            let fundamental = h1 * sinf(phase)
            let h2 = h2Coef * sinf(phase * 2.0)
            let h3 = h3Coef * sinf(phase * 3.0)
            return amplitude * env * (fundamental + h2 + h3) / normalizer
        }

        for i in 0..<Int(frameCount) {
            var sample: Float = 0
            if i < noteFrames {
                sample = noteSample(localIdx: i, frequency: firstFreq)
            } else if i >= noteFrames + gapFrames {
                sample = noteSample(localIdx: i - (noteFrames + gapFrames), frequency: secondFreq)
            }
            data[i] = sample
        }
        return buffer
    }

    private static func generateTone(
        note: Note,
        duration: Float,
        amplitude: Float,
        format: AVAudioFormat,
        sampleRate: Double
    ) -> AVAudioPCMBuffer? {
        let frequency = note.rawValue
        let frameCount = AVAudioFrameCount(Double(duration) * sampleRate)
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)
        else { return nil }
        buffer.frameLength = frameCount
        guard let data = buffer.floatChannelData?[0] else { return nil }

        let twoPiOverSR = 2.0 * Float.pi / Float(sampleRate)
        for i in 0..<Int(frameCount) {
            let t = Float(i) / Float(sampleRate)
            let phase = twoPiOverSR * frequency * Float(i)
            let fundamentalEnv = expf(-3.0 * t / duration)
            let fundamental = sinf(phase)
            let h2Env = expf(-4.5 * t / duration)
            let h2 = 0.45 * sinf(phase * 2.0)
            let clinkEnv = expf(-18.0 * t / duration)
            let clink = 0.25 * sinf(phase * 5.0)
            data[i] = amplitude * (fundamentalEnv * fundamental + h2Env * h2 + clinkEnv * clink)
        }
        return buffer
    }
}
