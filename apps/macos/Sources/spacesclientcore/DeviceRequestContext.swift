import Foundation
import spacesdevicecore
import spacesterminalcore

/// The identity every device request carries: which paired device to reach and
/// which client app/profile is asking. Bundled so call chains forward one value
/// instead of re-threading the same three parameters.
public struct DeviceRequestContext: Sendable {
    public var device: SpacesPairedDeviceRecord
    public var clientApp: SpacesDeviceClientApp
    public var profile: SpacesProfile?

    public init(device: SpacesPairedDeviceRecord, clientApp: SpacesDeviceClientApp = SpacesDeviceClient.macOSClientApp(), profile: SpacesProfile? = nil) {
        self.device = device
        self.clientApp = clientApp
        self.profile = profile
    }
}
