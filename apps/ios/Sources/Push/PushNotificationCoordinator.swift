import Foundation
import Observation
import UserNotifications

/// Owns the phone's push registration: the notification permission, the APNs token, the relay capability
/// sealed from it, and handing that capability to every paired device.
///
/// Nothing is persisted here. The capability is requested again whenever the app has a token and none in
/// memory, and the relay keys its state by install id rather than by capability, so a fresh capability costs
/// nothing and there is no secret to store. Every failure is silent: the next trigger (launch, reconnect,
/// pairing, a toggle change, a token change) runs the same registration again.
@MainActor @Observable final class PushNotificationCoordinator {
    let preferences: PushNotificationPreferences
    /// The system's notification permission, nil until first read. Settings reads it to explain a denial.
    private(set) var authorizationStatus: UNAuthorizationStatus?

    @ObservationIgnored private let system: any PushSystem
    @ObservationIgnored private let relay: any PushRelayClient
    @ObservationIgnored private let environment: PushEnvironment
    @ObservationIgnored private var apnsToken: String?
    @ObservationIgnored private var capability: String?
    /// The token `capability` was sealed from, so a rotated token asks the relay again.
    @ObservationIgnored private var capabilityToken: String?
    @ObservationIgnored private var pendingSync: (installID: String, pairedDeviceIDs: [String], targets: [PushDeviceTarget])?
    @ObservationIgnored private var isSyncing = false

    init(system: any PushSystem, relay: any PushRelayClient, preferences: PushNotificationPreferences, environment: PushEnvironment) {
        self.system = system
        self.relay = relay
        self.preferences = preferences
        self.environment = environment
    }

    /// Whether the user denied notifications in iOS, so Settings can say where to turn them back on. False
    /// before the permission was ever asked.
    var isDenied: Bool { authorizationStatus == .denied }

    private var isAuthorized: Bool {
        switch authorizationStatus {
        case .authorized, .provisional, .ephemeral: true
        default: false
        }
    }

    func refreshAuthorization() async { authorizationStatus = await system.authorizationStatus() }

    /// Gets APNs started: asks for permission when `askIfNeeded` and the user was never asked, then, when
    /// allowed, requests a device token (which arrives through `deviceTokenReceived`). Callers ask only once
    /// a pairing exists, when the user has a reason to want alerts. The token is also requested without
    /// permission while the relay still holds paired devices, because retiring them needs a token but not
    /// the right to show notifications.
    func prepare(askIfNeeded: Bool) async {
        await refreshAuthorization()
        if askIfNeeded, authorizationStatus == .notDetermined {
            _ = await system.requestAuthorization()
            await refreshAuthorization()
        }
        if isAuthorized || !preferences.relayPairedDeviceIDs.isEmpty { system.registerForRemoteNotifications() }
    }

    func deviceTokenReceived(_ token: Data) { apnsToken = token.map { String(format: "%02x", $0) }.joined() }

    /// Registers with the relay when the token or the set of paired devices changed, then sends the
    /// capability with the toggles to every target. Registration happens with both toggles off too, because
    /// the badge counts every alert. Calls that overlap collapse to the latest, so a toggle flipped
    /// mid-registration is not overtaken by the older value.
    ///
    /// `pairedDeviceIDs` is every paired device, credentialed or not: it is the relay's allowlist of who may
    /// report for this phone. The relay call finishes before any device is told, so a device paired a
    /// moment ago is already allowed when its first report arrives; otherwise the relay would refuse it and
    /// the device would drop the registration.
    func sync(installID: String, pairedDeviceIDs: [String], targets: [PushDeviceTarget]) async {
        pendingSync = (installID, pairedDeviceIDs, targets)
        guard !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }
        while let request = pendingSync {
            pendingSync = nil
            await perform(installID: request.installID, pairedDeviceIDs: request.pairedDeviceIDs, targets: request.targets)
        }
    }

    private func perform(installID: String, pairedDeviceIDs: [String], targets: [PushDeviceTarget]) async {
        await refreshAuthorization()
        // Unpairing a device the phone could not reach is only ever undone by this list: that daemon keeps
        // its registration and would otherwise restore its counts when it came back. The relay's list is
        // persisted, so the difference is sent on a later launch even when the removal found the relay
        // down; once an empty list is accepted nothing more is registered until a device is paired.
        let registeredDevices = Set(pairedDeviceIDs)
        let relayDevices = preferences.relayPairedDeviceIDs
        guard let token = apnsToken, isAuthorized || registeredDevices.isEmpty else { return }
        if registeredDevices.isEmpty && relayDevices.isEmpty { return }
        if capability == nil || capabilityToken != token || relayDevices != registeredDevices {
            guard
                let issued = try? await relay.register(
                    apnsToken: token, environment: environment, installID: installID, deviceIDs: pairedDeviceIDs.sorted())
            else { return }
            capability = issued
            capabilityToken = token
            preferences.relayPairedDeviceIDs = registeredDevices
        }
        guard let capability else { return }
        let notifyBlocked = preferences.notifyBlocked
        let notifyFinished = preferences.notifyFinished
        await withTaskGroup(of: Void.self) { group in
            for target in targets {
                group.addTask {
                    try? await target.endpoint.register(capability: capability, notifyBlocked: notifyBlocked, notifyFinished: notifyFinished)
                }
            }
        }
    }

    /// Tells an unpaired device to forget this phone, best effort: a device that is offline never hears it.
    /// What keeps such a device out of the badge is the relay's paired list, which the next `sync` sends
    /// without it.
    func unpair(_ target: PushDeviceTarget) async { try? await target.endpoint.unregister() }

    /// Mirrors the app's own alert count onto the icon while the app is open; the relay owns it otherwise.
    func updateBadge(_ count: Int) async { await system.setBadgeCount(count) }
}

extension PushNotificationCoordinator {
    /// A coordinator that never asks, registers, or sets a badge: the model's test-only initializer uses it
    /// so suites that pair devices do not raise the system permission prompt.
    static func disabled() -> PushNotificationCoordinator {
        PushNotificationCoordinator(
            system: DisabledPushSystem(), relay: URLSessionPushRelayClient(),
            preferences: PushNotificationPreferences(defaults: UserDefaults(suiteName: "spaces.mobile.push.disabled") ?? .standard),
            environment: .sandbox)
    }
}
