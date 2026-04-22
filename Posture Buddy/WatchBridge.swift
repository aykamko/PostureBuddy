import Combine
import Foundation
import WatchConnectivity

/// Bridges posture events from the iOS app to a paired Apple Watch companion. The
/// watch side receives messages in `session(_:didReceiveMessage:)` and plays a haptic
/// per event type. Uses `sendMessage` (live-only, no background queue) — stale slouch
/// pings would be confusing, and we'd rather drop than deliver late.
///
/// Apple Watch notification mirroring skips our alerts because the iPhone is
/// foreground-active during a session (screen on, app running). This bridge is the
/// workaround: iPhone stays active, watch still haptics via direct WCSession delivery.
@MainActor
final class WatchBridge: NSObject, ObservableObject, WCSessionDelegate {
    static let shared = WatchBridge()

    enum Event: String {
        case slouchAlert   // 10s/30s threshold crossed — firm haptic
        case slouchCoach   // PostureSoundCoach slouch sound fired — lighter
        case recovery      // PostureSoundCoach recovery sound fired — upbeat
    }

    private let session: WCSession?

    override init() {
        session = WCSession.isSupported() ? WCSession.default : nil
        super.init()
        guard let session else { return }
        session.delegate = self
        session.activate()
    }

    func notify(_ event: Event) {
        guard let session else { return }
        guard session.activationState == .activated else {
            Log.line("[Watch]", "skip \(event.rawValue) — session not activated (\(session.activationState.rawValue))")
            return
        }
        guard session.isReachable else {
            Log.line("[Watch]", "skip \(event.rawValue) — watch not reachable")
            return
        }
        session.sendMessage(
            ["event": event.rawValue],
            replyHandler: nil,
            errorHandler: { error in
                Log.line("[Watch]", "send \(event.rawValue) failed: \(error.localizedDescription)")
            }
        )
    }

    // MARK: - WCSessionDelegate

    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        if let error {
            Log.line("[Watch]", "activation error: \(error.localizedDescription)")
            return
        }
        Log.line(
            "[Watch]",
            "activated state=\(activationState.rawValue) "
            + "paired=\(session.isPaired) "
            + "installed=\(session.isWatchAppInstalled) "
            + "reachable=\(session.isReachable)"
        )
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {
        Log.line("[Watch]", "session inactive")
    }

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        // Per Apple docs, must re-activate to pair with a new watch.
        Log.line("[Watch]", "session deactivated — reactivating")
        session.activate()
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Log.line("[Watch]", "reachability=\(session.isReachable)")
    }
}
