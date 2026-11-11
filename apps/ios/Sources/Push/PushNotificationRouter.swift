import Foundation
import UserNotifications

/// Turns system notification callbacks into app actions. It lives apart from the model because the system
/// can deliver them before the model exists (a tap that launches the app, a token that arrives at launch, a
/// background push that wakes the app without opening its UI): what the callback needs from the model is
/// held until `connect`, and a withdraw needs nothing from it.
@MainActor final class PushNotificationRouter {
    private let system: any PushSystem
    private var openAlerts: (() -> Void)?
    private var deviceTokenHandler: ((Data) -> Void)?
    private var tappedBeforeConnect = false
    private var tokenBeforeConnect: Data?

    init(system: any PushSystem) { self.system = system }

    func connect(openAlerts: @escaping () -> Void, deviceToken: @escaping (Data) -> Void) {
        self.openAlerts = openAlerts
        deviceTokenHandler = deviceToken
        if tappedBeforeConnect {
            tappedBeforeConnect = false
            openAlerts()
        }
        if let token = tokenBeforeConnect {
            tokenBeforeConnect = nil
            deviceToken(token)
        }
    }

    /// The one system notification is a count of alerts, so tapping it opens the Alerts tab.
    func notificationTapped() { if let openAlerts { openAlerts() } else { tappedBeforeConnect = true } }

    func deviceTokenReceived(_ token: Data) { if let deviceTokenHandler { deviceTokenHandler(token) } else { tokenBeforeConnect = token } }

    /// A background push carrying the relay's withdraw marker removes the delivered notification, which the
    /// relay sends once no alert is left to show.
    func backgroundPushReceived(_ userInfo: [AnyHashable: Any]) { if PushPayload.isWithdraw(userInfo) { system.removeAllDeliveredNotifications() } }

    /// Nothing is presented while the app is open: the in-app banner covers new alerts and the app sets its
    /// own badge.
    var foregroundPresentationOptions: UNNotificationPresentationOptions { [] }
}
