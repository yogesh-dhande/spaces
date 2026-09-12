import Foundation

/// The restorable record this app has already answered, per device, persisted as a device id to
/// generation map.
///
/// A device keeps its record until a client answers it, and every status refresh re-reports it, so
/// without this memory the same record would be offered again on every refresh for as long as the user
/// leaves it unanswered elsewhere. A later capture on the same device carries a different generation and
/// is therefore offered, which is exactly the intent: an offer is shown once per record.
///
/// Same semantics as the Mac's `session_restore_answered_generations` client setting, in this app's own
/// store: one entry per device, replaced rather than appended, since only the record a device is
/// currently offering can be answered.
enum SessionRestoreAnsweredGenerationsStore {
    private static let generationsKey = "spaces.mobile.session-restore-answered-generations"

    static func generation(deviceID: String, defaults: UserDefaults = .standard) -> String? { generations(defaults: defaults)[deviceID] }

    /// Records that this client answered a device's record. Called only after the device accepted the
    /// answer: a device that refused still has its record, and the user has not been given what they
    /// asked for.
    static func record(generation: String, deviceID: String, defaults: UserDefaults = .standard) {
        var all = generations(defaults: defaults)
        all[deviceID] = generation
        defaults.set(all, forKey: generationsKey)
    }

    private static func generations(defaults: UserDefaults) -> [String: String] {
        defaults.dictionary(forKey: generationsKey) as? [String: String] ?? [:]
    }
}
