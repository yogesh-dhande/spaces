import Foundation
import Observation

/// The two per-phone buzz toggles. The badge always counts every alert, so these only choose which new
/// alerts also buzz the phone (and raise the in-app banner).
@MainActor @Observable final class PushNotificationPreferences {
    static let notifyBlockedKey = "spaces.mobile.push.notifyBlocked"
    static let notifyFinishedKey = "spaces.mobile.push.notifyFinished"

    /// An agent that needs input. On by default: it is the alert that is time-sensitive.
    var notifyBlocked: Bool { didSet { defaults.set(notifyBlocked, forKey: Self.notifyBlockedKey) } }
    /// An agent that finished. Off by default: finishing is routine and would buzz often.
    var notifyFinished: Bool { didSet { defaults.set(notifyFinished, forKey: Self.notifyFinishedKey) } }

    /// The paired device ids the relay last accepted as this phone's allowlist. Persisted so a launch can
    /// tell that the relay still holds a device the phone no longer has (the last one removed while the
    /// relay was unreachable) and send the difference, the empty list included.
    var relayPairedDeviceIDs: Set<String> {
        get { Set(defaults.stringArray(forKey: Self.relayPairedDeviceIDsKey) ?? []) }
        set { defaults.set(newValue.sorted(), forKey: Self.relayPairedDeviceIDsKey) }
    }

    @ObservationIgnored private let defaults: UserDefaults
    private static let relayPairedDeviceIDsKey = "spaces.mobile.push.relayPairedDeviceIDs"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        notifyBlocked = defaults.object(forKey: Self.notifyBlockedKey) as? Bool ?? true
        notifyFinished = defaults.object(forKey: Self.notifyFinishedKey) as? Bool ?? false
    }
}
