import UIKit
import UserNotifications
import Combine

enum AlertState: Equatable {
    case none
    case warning(secondsRemaining: Int)
    case triggered
}

@MainActor
final class NotificationManager: ObservableObject {
    @Published var alertState: AlertState = .none

    let scoreThreshold: Float = 70.0
    let alertDelay: TimeInterval = 30.0
    let minimumAlertInterval: TimeInterval = 120.0

    private var poorPostureStartTime: Date?
    private var lastAlertTime: Date?
    private let haptic = UIImpactFeedbackGenerator(style: .heavy)

    func update(score: PostureScore?) {
        guard let score, score.value < scoreThreshold else {
            poorPostureStartTime = nil
            alertState = .none
            return
        }

        let now = Date()
        if poorPostureStartTime == nil {
            poorPostureStartTime = now
        }

        let elapsed = now.timeIntervalSince(poorPostureStartTime!)
        let cooldownClear = lastAlertTime.map { now.timeIntervalSince($0) >= minimumAlertInterval } ?? true

        if elapsed >= alertDelay && cooldownClear {
            triggerAlert()
            lastAlertTime = now
            poorPostureStartTime = now
            alertState = .triggered
        } else {
            let remaining = max(0, Int(alertDelay - elapsed))
            alertState = .warning(secondsRemaining: remaining)
        }
    }

    func requestNotificationPermission() async {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
    }

    private func triggerAlert() {
        haptic.prepare()
        haptic.impactOccurred()

        let content = UNMutableNotificationContent()
        content.title = "Posture Check"
        content.body = "You've been slouching for a while. Time to sit up straight!"
        content.sound = .default

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request)
    }
}
