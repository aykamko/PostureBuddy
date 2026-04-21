import AVFoundation
import Foundation

/// Plays synthesized marimba-like tones.
/// Tones are pre-generated on a background queue at startup so playback never
/// synthesizes on the main thread (avoids first-play choppiness during camera/Vision init).
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

    // Rising C major scale fragment (F, G, A, B) resolving to C5 on capture.
    private static let tickFrequencies: [Float] = [
        349.23, // F4
        392.00, // G4
        440.00, // A4
        493.88, // B4
    ]
    private static let captureFrequency: Float = 523.25 // C5 (octave tonic)

    private init() {
        // Match the hardware sample rate so the mainMixerNode doesn't have to resample
        // each buffer on the real-time audio thread (a hidden source of glitches).
        let hwRate = AVAudioSession.sharedInstance().sampleRate
        sampleRate = hwRate > 0 ? hwRate : 48000
        format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
    }

    static func configureAudioSession() {
        shared.configure()
    }

    static func playTick(index: Int) {
        shared.play(buffer: shared.bufferForTick(at: index))
    }

    static func playCapture() {
        shared.play(buffer: shared.captureBuffer)
    }

    private func configure() {
        guard !audioSessionConfigured else { return }
        audioSessionConfigured = true

        try? AVAudioSession.sharedInstance().setCategory(
            .playback,
            mode: .default,
            options: [.mixWithOthers]
        )
        try? AVAudioSession.sharedInstance().setActive(true)
        try? engine.start()
        player.play()

        // Warm up the render path with a half-second of silence so the first real tone
        // doesn't glitch as the audio pipeline spins up.
        if let silence = Self.silentBuffer(format: format, duration: 0.5) {
            player.scheduleBuffer(silence, at: nil, options: [], completionHandler: nil)
        }

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
            DispatchQueue.main.async {
                self.tickBuffers = ticks
                self.captureBuffer = capture
            }
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

    /// Synthesizes a marimba-like tone: fundamental + octave harmonic + a fast-decaying
    /// inharmonic "clink" for the struck-bar attack.
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
