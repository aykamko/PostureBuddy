//
//  WatchPostureReceiver.swift
//  Posture Buddy
//
//  Created by Aleks Kamko on 4/21/26.
//

import Combine
import Foundation
import WatchConnectivity
import WatchKit

@MainActor
final class WatchPostureReceiver: NSObject, ObservableObject, WCSessionDelegate {
    @Published var lastEvent: String?

    override init() {
        super.init()
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    nonisolated func session(
        _: WCSession,
        activationDidCompleteWith _: WCSessionActivationState,
        error _: Error?
    ) {}

    nonisolated func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any]
    ) {
        guard let event = message["event"] as? String else { return }
        Task { @MainActor in
            lastEvent = event
            switch event {
            case "slouch":
                WKInterfaceDevice.current().play(.notification)
            case "recovery":
                WKInterfaceDevice.current().play(.success)
            default:
                break
            }
        }
    }
}
