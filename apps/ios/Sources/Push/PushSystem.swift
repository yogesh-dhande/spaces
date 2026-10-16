import UIKit
import UserNotifications

/// The iOS notification surface the push flow drives, behind a protocol so tests observe it without
/// asking the simulator for permission.
@MainActor protocol PushSystem {
    func authorizationStatus() async -> UNAuthorizationStatus
    /// Shows the system permission prompt (alert, badge, sound); true when the user allows.
    func requestAuthorization() async -> Bool
    func registerForRemoteNotifications()
    func setBadgeCount(_ count: Int) async
    func removeAllDeliveredNotifications()
}

@MainActor struct UserNotificationsPushSystem: PushSystem {
    private var center: UNUserNotificationCenter { .current() }

    func authorizationStatus() async -> UNAuthorizationStatus { await center.notificationSettings().authorizationStatus }

    func requestAuthorization() async -> Bool { (try? await center.requestAuthorization(options: [.alert, .badge, .sound])) ?? false }

    func registerForRemoteNotifications() { UIApplication.shared.registerForRemoteNotifications() }

    func setBadgeCount(_ count: Int) async { try? await center.setBadgeCount(count) }

    func removeAllDeliveredNotifications() { center.removeAllDeliveredNotifications() }
}

/// What the relay sends in a background push to clear the delivered notification once no alert is left.
enum PushPayload {
    static func isWithdraw(_ userInfo: [AnyHashable: Any]) -> Bool { (userInfo["spaces"] as? [String: Any])?["withdraw"] as? Bool == true }
}

/// Reports notifications as denied, which keeps every push path inert.
@MainActor struct DisabledPushSystem: PushSystem {
    func authorizationStatus() async -> UNAuthorizationStatus { .denied }
    func requestAuthorization() async -> Bool { false }
    func registerForRemoteNotifications() {}
    func setBadgeCount(_ count: Int) async {}
    func removeAllDeliveredNotifications() {}
}
