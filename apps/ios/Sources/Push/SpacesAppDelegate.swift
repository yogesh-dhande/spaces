import UIKit
import UserNotifications

/// The app delegate SwiftUI's `App` lacks, adopted only for the push callbacks. All behavior is in
/// `PushNotificationRouter`.
@MainActor final class SpacesAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    let router = PushNotificationRouter(system: UserNotificationsPushSystem())

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool
    {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        router.deviceTokenReceived(deviceToken)
    }

    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any]) async -> UIBackgroundFetchResult {
        router.backgroundPushReceived(userInfo)
        return .noData
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions
    { await router.foregroundPresentationOptions }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        await router.notificationTapped()
    }
}
