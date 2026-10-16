import Foundation

/// Stores a paired phone's push registration on the daemon, against the pairing record of the phone
/// that sent it. Sending it again replaces the stored registration, which is how a toggle change or a
/// rotated capability reaches the daemon.
public struct SpacesDeviceRegisterPushNotificationsRequest: Codable, Sendable, Equatable {
    /// The opaque string the push relay issued the phone for its APNs token. It is all a daemon needs to
    /// push to the phone, so it is a bearer secret.
    public let capability: String
    /// Buzz when a new visible alert is an agent waiting on the user.
    public let notifyBlocked: Bool
    /// Buzz when a new visible alert is an agent that finished.
    public let notifyFinished: Bool

    public init(capability: String, notifyBlocked: Bool, notifyFinished: Bool) {
        self.capability = capability
        self.notifyBlocked = notifyBlocked
        self.notifyFinished = notifyFinished
    }
}

/// Clears the calling phone's push registration and asks the relay to drop this daemon's counts from the
/// phone's badge.
public struct SpacesDeviceUnregisterPushNotificationsRequest: Codable, Sendable, Equatable { public init() {} }
