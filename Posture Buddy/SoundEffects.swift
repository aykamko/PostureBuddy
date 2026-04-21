import AVFoundation
import Foundation

enum SoundEffects {
    enum Effect: String {
        case tick = "Tink"            // short tick for each countdown second
        case capture = "begin_record" // distinct chime at calibration moment
    }

    private static var players: [Effect: AVAudioPlayer] = [:]
    private static let lock = NSLock()
    private static var audioSessionConfigured = false

    static func configureAudioSession() {
        lock.withLock {
            guard !audioSessionConfigured else { return }
            // .playback + .mixWithOthers = audible even when silent switch is on,
            // and doesn't interrupt any background audio.
            try? AVAudioSession.sharedInstance().setCategory(
                .playback,
                mode: .default,
                options: [.mixWithOthers]
            )
            try? AVAudioSession.sharedInstance().setActive(true)
            audioSessionConfigured = true
        }
    }

    static func play(_ effect: Effect) {
        configureAudioSession()
        let player = lock.withLock { () -> AVAudioPlayer? in
            if let cached = players[effect] { return cached }
            let url = URL(fileURLWithPath: "/System/Library/Audio/UISounds/\(effect.rawValue).caf")
            guard let player = try? AVAudioPlayer(contentsOf: url) else { return nil }
            player.prepareToPlay()
            players[effect] = player
            return player
        }
        guard let player else { return }
        player.currentTime = 0
        player.play()
    }
}
