import UIKit
import UserNotifications
import Combine

enum AlertState: Equatable {
    case none
    case warning(secondsRemaining: Int)
    case triggered
}

@MainActor
final class NotificationManager: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    @Published var alertState: AlertState = .none

    let scoreThreshold: Float = 70.0
    let alertDelay: TimeInterval = 10.0  // TODO: bump back to 30s after Watch testing
    let minimumAlertInterval: TimeInterval = 120.0

    private var poorPostureStartTime: Date?
    private var lastAlertTime: Date?
    private let haptic = UIImpactFeedbackGenerator(style: .heavy)

    override init() {
        super.init()
        // Own the center's delegate so we can show banners/sound while the app is
        // foreground. Without this, iOS silently files notifications into Notification
        // Center and Apple Watch mirroring never sees them.
        UNUserNotificationCenter.current().delegate = self
    }

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
        // `.timeSensitive` interruption level on the content honors the
        // `com.apple.developer.usernotifications.time-sensitive` entitlement (if set);
        // the dedicated auth option was deprecated in iOS 15.
        _ = try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound, .badge])
    }

    private func triggerAlert() {
        haptic.prepare()
        haptic.impactOccurred()
        // No watch haptic here — the coach already fired `.slouch` at 6s; another
        // haptic 4s later for the same slouch condition is just noise on the wrist.

        let content = UNMutableNotificationContent()
        content.title = "Posture Check"
        content.body = "You've been slouching for a while. Time to sit up straight!"
        content.sound = .default
        content.interruptionLevel = .timeSensitive

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .list])
    }
}
