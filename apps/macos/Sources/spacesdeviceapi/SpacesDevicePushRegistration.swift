import Foundation

/// A paired phone's push registration, stored on its pairing record in `device-pairings.json`. The daemon
/// needs nothing else to push to the phone: the capability is the relay's sealed handle on the phone's
/// APNs token.
public struct SpacesDevicePushRegistration: Codable, Equatable, Sendable {
    public let capability: String
    public let notifyBlocked: Bool
    public let notifyFinished: Bool

    public init(capability: String, notifyBlocked: Bool, notifyFinished: Bool) {
        self.capability = capability
        self.notifyBlocked = notifyBlocked
        self.notifyFinished = notifyFinished
    }
}
