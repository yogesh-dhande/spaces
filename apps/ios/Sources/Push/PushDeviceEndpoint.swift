import Foundation

/// A paired device's push registration commands, behind a protocol so tests record what each device
/// was told without a daemon.
protocol PushDeviceEndpoint: Sendable {
    func register(capability: String, notifyBlocked: Bool, notifyFinished: Bool) async throws
    func unregister() async throws
}

struct ClientPushDeviceEndpoint: PushDeviceEndpoint {
    let client: SpacesDeviceAPIClient

    func register(capability: String, notifyBlocked: Bool, notifyFinished: Bool) async throws {
        _ = try await client.registerPushNotifications(capability: capability, notifyBlocked: notifyBlocked, notifyFinished: notifyFinished)
    }

    func unregister() async throws { _ = try await client.unregisterPushNotifications() }
}

/// One paired device the push registration goes to. `deviceID` is also the id the device's daemon files its
/// counts under at the relay (`SpacesDevicePushRelayDeviceID`), which is what an unpair removes.
struct PushDeviceTarget: Sendable {
    let deviceID: String
    let endpoint: any PushDeviceEndpoint
}
