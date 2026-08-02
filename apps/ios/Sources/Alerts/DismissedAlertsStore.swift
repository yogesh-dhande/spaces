import Foundation

/// Persists the attention events the user dismissed, so a dismissed alert stays dismissed across
/// launches instead of coming back the moment the app is reopened.
///
/// Scoped per device (one bucket of event identities per device id, keyed in a single UserDefaults
/// dictionary): dismissals are derived from one device's overview, so a set shared across devices would
/// get pruned against whichever device's overview last published, resurfacing every other device's
/// dismissals the moment the active device changed. Each device's bucket is kept small by pruning it
/// against the currently derivable events on every overview refresh for the device it belongs to (see
/// `SpacesMobileAttention.retainedDismissedEventIDs`).
enum SpacesMobileDismissedAlertsStore {
    static let dismissedIDsKey = "spaces.mobile.dismissed-alert-ids-by-device"

    static func load(deviceID: String, defaults: UserDefaults = .standard) -> Set<String> { Set(buckets(defaults: defaults)[deviceID] ?? []) }

    static func save(_ ids: Set<String>, deviceID: String, defaults: UserDefaults = .standard) {
        var all = buckets(defaults: defaults)
        if ids.isEmpty { all.removeValue(forKey: deviceID) } else { all[deviceID] = Array(ids) }
        defaults.set(all, forKey: dismissedIDsKey)
    }

    /// Drops buckets for devices no longer known — a device that was unpaired, or a stale demo-mode
    /// bucket — so the persisted store stays bounded to devices the app can still show rather than
    /// growing for the life of the install.
    static func retainDevices(_ knownDeviceIDs: Set<String>, defaults: UserDefaults = .standard) {
        var all = buckets(defaults: defaults)
        let staleKeys = Set(all.keys).subtracting(knownDeviceIDs)
        guard !staleKeys.isEmpty else { return }
        for key in staleKeys { all.removeValue(forKey: key) }
        defaults.set(all, forKey: dismissedIDsKey)
    }

    private static func buckets(defaults: UserDefaults) -> [String: [String]] {
        defaults.dictionary(forKey: dismissedIDsKey) as? [String: [String]] ?? [:]
    }
}
