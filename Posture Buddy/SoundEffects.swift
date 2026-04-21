import AVFoundation
import Foundation

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
    private var slouchBuffer: AVAudioPCMBuffer?   // descending "beep-boop" on poor posture
    private var recoveryBuffer: AVAudioPCMBuffer? // ascending "boop-beep" on return to good posture

    // Rising C major scale fragment (F, G, A, B) resolving to C5 on capture.
    private static let tickFrequencies: [Float] = [
        349.23, // F4
        392.00, // G4
        440.00, // A4
        493.88, // B4
    ]
    private static let captureFrequency: Float = 523.25 // C5 (octave tonic)

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
    static func prime() {
        shared.primeInternal()
    }

    static func playTick(index: Int) {
        shared.play(buffer: shared.bufferForTick(at: index))
    }

    static func playCapture() {
        shared.play(buffer: shared.captureBuffer)
    }

    /// Quiet descending "beep-boop" — posture has slouched.
    static func playSlouch() {
        shared.play(buffer: shared.slouchBuffer)
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
            let ticks = Self.tickFrequencies.compactMap {
                Self.generateTone(frequency: $0, duration: 0.7, amplitude: 0.35, format: self.format, sampleRate: self.sampleRate)
            }
            let capture = Self.generateTone(
                frequency: Self.captureFrequency,
                duration: 1.4,
                amplitude: 0.5,
                format: self.format,
                sampleRate: self.sampleRate
            )
            // G3 → C3 descending for slouch; C3 → G3 ascending for recovery.
            // Quiet amplitude (0.15), short notes (180ms each), low register.
            let slouch = Self.generateBeepPair(
                firstFreq: 196.00, secondFreq: 130.81,  // G3, C3
                format: self.format, sampleRate: self.sampleRate
            )
            let recovery = Self.generateBeepPair(
                firstFreq: 130.81, secondFreq: 196.00,  // C3, G3
                format: self.format, sampleRate: self.sampleRate
            )
            DispatchQueue.main.async {
                self.tickBuffers = ticks
                self.captureBuffer = capture
                self.slouchBuffer = slouch
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

    /// Synthesizes two short sine-based notes back-to-back with a small gap.
    /// Used for posture-state feedback (descending = slouch, ascending = recovery).
    /// Simpler timbre than marimba (no clink harmonic) — meant to be subtle.
    private static func generateBeepPair(
        firstFreq: Float,
        secondFreq: Float,
        noteDuration: Float = 0.18,
        gap: Float = 0.03,
        amplitude: Float = 0.15,
        format: AVAudioFormat,
        sampleRate: Double
    ) -> AVAudioPCMBuffer? {
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

        for i in 0..<Int(frameCount) {
            var sample: Float = 0
            if i < noteFrames {
                let localIdx = i
                let t = Float(localIdx) / Float(sampleRate)
                let phase = twoPiOverSR * firstFreq * Float(localIdx)
                // Softer envelope than marimba — shaped like a gentle beep (fade-in + exp decay)
                let fadeIn = min(1, t / 0.02)
                let env = fadeIn * expf(-3.0 * t / noteDuration)
                let fundamental = sinf(phase)
                let h2 = 0.3 * sinf(phase * 2.0)
                sample = amplitude * env * (fundamental + h2)
            } else if i >= noteFrames + gapFrames {
                let localIdx = i - (noteFrames + gapFrames)
                let t = Float(localIdx) / Float(sampleRate)
                let phase = twoPiOverSR * secondFreq * Float(localIdx)
                let fadeIn = min(1, t / 0.02)
                let env = fadeIn * expf(-3.0 * t / noteDuration)
                let fundamental = sinf(phase)
                let h2 = 0.3 * sinf(phase * 2.0)
                sample = amplitude * env * (fundamental + h2)
            }
            data[i] = sample
        }
        return buffer
    }

    private static func generateTone(
        frequency: Float,
        duration: Float,
        amplitude: Float,
        format: AVAudioFormat,
        sampleRate: Double
    ) -> AVAudioPCMBuffer? {
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
