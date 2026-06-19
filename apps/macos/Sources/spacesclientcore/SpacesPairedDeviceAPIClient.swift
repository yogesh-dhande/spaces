import Foundation
import spacesdevicecore
import spacesterminalcore

public enum SpacesPairedDeviceAPIClientError: LocalizedError, Equatable {
    case unavailable(String)
    case requestRejected(String)
    case missingOverview
    case missingTransportKey(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable(let message): message
        case .requestRejected(let message): message
        case .missingOverview: "The device did not return project and workspace data."
        case .missingTransportKey(let deviceName): "Missing secure transport key for \(deviceName). Remove and reconnect this device."
        }
    }
}

public enum SpacesPairedDeviceAPIClient {
    public static func overview(
        for device: SpacesPairedDeviceRecord, clientInstallationID: String = SpacesDevicePairingClient.localMacClientInstallationID(),
        clientDeviceName: String = Host.current().localizedName ?? "Mac", clientAppVersion: String? = nil, profile: SpacesProfile? = nil
    ) throws -> SpacesDeviceOverviewPayload {
        try request(
            SpacesDeviceAPIRequest(
                command: .overview, authToken: SpacesDeviceCredentialStore.token(deviceID: device.id, profile: profile),
                clientApp: SpacesDeviceClientApp(
                    installationID: clientInstallationID, bundleID: SpacesDeviceFirstPartyPolicy.macOSBundleID, platform: "macos",
                    deviceName: clientDeviceName, appVersion: clientAppVersion)), device: device, profile: profile
        ).overviewPayload()
    }

    public static func request(_ request: SpacesDeviceAPIRequest, device: SpacesPairedDeviceRecord, profile: SpacesProfile? = nil) throws
        -> SpacesDeviceAPIResponse
    {
        #if canImport(Network)
            guard let transportKey = try SpacesDeviceCredentialStore.transportKey(deviceID: device.id, profile: profile) else {
                throw SpacesPairedDeviceAPIClientError.missingTransportKey(device.name)
            }
            let client = try SpacesDeviceAPIRequestClient(host: device.host, port: device.port, transportKey: transportKey)
            let response = try client.request(request)
            guard response.ok else { throw SpacesPairedDeviceAPIClientError.requestRejected(response.message) }
            return response
        #else
            throw SpacesPairedDeviceAPIClientError.unavailable("Remote Device API requests require Network.framework.")
        #endif
    }
}

extension SpacesDeviceAPIResponse {
    fileprivate func overviewPayload() throws -> SpacesDeviceOverviewPayload {
        guard let overview else { throw SpacesPairedDeviceAPIClientError.missingOverview }
        return overview
    }
}
