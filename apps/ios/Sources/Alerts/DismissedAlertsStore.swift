import Foundation

/// Persists the attention events the user dismissed, so a dismissed alert stays dismissed across
/// launches instead of coming back the moment the app is reopened.
///
/// Stored as a plain array of event identities; the set is kept small by pruning it against the
/// currently derivable events on every overview refresh (see
/// `SpacesMobileAttention.retainedDismissedEventIDs`).
enum SpacesMobileDismissedAlertsStore {
    static let dismissedIDsKey = "spaces.mobile.dismissed-alert-ids"

    static func load(defaults: UserDefaults = .standard) -> Set<String> { Set(defaults.stringArray(forKey: dismissedIDsKey) ?? []) }

    static func save(_ ids: Set<String>, defaults: UserDefaults = .standard) { defaults.set(Array(ids), forKey: dismissedIDsKey) }
}
