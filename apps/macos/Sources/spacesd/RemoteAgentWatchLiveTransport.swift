import Foundation
import spacesclientcore
import spacesdevicecore
import workspacecore

extension SpacesDeviceAPIOverviewStreamClient: RemoteAgentOverviewStreamHandle {}

/// Thrown when a listing pull targets a device that vanished from the client database between the
/// signal and the pull; the watch logs the failed pull and keeps its snapshot untouched (an empty
/// listing would instead read as every watched agent having exited).
private struct RemoteAgentWatchDeviceUnresolvedError: Error {}

extension RemoteAgentWatchTransport {
    /// The daemon's live transport: resolves the paired-device record and pinned-TLS credentials from
    /// the client database and dials the device's overview stream / agent-session listing through
    /// `SpacesDeviceClient`. All closures run off the main actor (the watch service detaches them).
    static func live(clientApp: SpacesDeviceClientApp) -> RemoteAgentWatchTransport {
        RemoteAgentWatchTransport(
            connect: { deviceID, onSignal, onDisconnect in
                let resolved: SpacesPairedDeviceRecord?
                do { resolved = try SpacesClientDatabase.defaultDatabase().pairedDevice(id: deviceID) } catch {
                    return .unavailable(reason: "resolve_device error=\(error)")
                }
                guard let device = resolved else { return .deviceUnpaired }
                guard pairedDeviceHasRequiredCredentials(device: device) else { return .unavailable(reason: "missing_credentials") }
                do {
                    let client = try SpacesDeviceClient.subscribeOverview(
                        device: device, clientApp: clientApp, onOverview: { _ in onSignal() }, onDisconnect: onDisconnect)
                    return .connected(client)
                } catch {
                    return .unavailable(reason: "connect_failed error=\(error)")
                }
            },
            listAgentSessions: { deviceID in
                guard let device = try SpacesClientDatabase.defaultDatabase().pairedDevice(id: deviceID) else {
                    throw RemoteAgentWatchDeviceUnresolvedError()
                }
                return try SpacesDeviceClient.listAgentSessions(device: device, clientApp: clientApp)
            })
    }

    /// A paired device is usable when its auth-token secret is present and its record carries the daemon's
    /// pinned TLS certificate fingerprint. Mirrors `AppKitController.pairedDeviceHasRequiredCredentials`,
    /// which is not reachable from the daemon target.
    private static func pairedDeviceHasRequiredCredentials(device: SpacesPairedDeviceRecord) -> Bool {
        let hasToken = (try? SpacesDeviceCredentialStore.hasToken(deviceID: device.id)) ?? false
        return hasToken && !device.certificateFingerprint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
