import Foundation
import Sparkle
import spacesclientcore

/// Points Sparkle at the pre-release feed while the "Receive pre-release updates" setting is on.
///
/// The setting is read on every check rather than cached, so toggling it in Settings takes effect on
/// the next update check without restarting the app. `AppKitController` holds this object in a stored
/// property because Sparkle keeps only a weak reference to its delegate.
final class SpacesUpdaterDelegate: NSObject, SPUUpdaterDelegate {
    func feedURLString(for updater: SPUUpdater) -> String? {
        UpdateFeed.feedURLString(prereleaseUpdatesEnabled: Self.prereleaseUpdatesEnabled())
    }

    /// The stored toggle, defaulting to off when it has never been set (or the client database cannot
    /// be opened): an install that has not opted in stays on the stable feed.
    static func prereleaseUpdatesEnabled() -> Bool {
        let stored = (try? SpacesClientDatabase.defaultDatabase().setting(key: ClientSettingsKey.appPrereleaseUpdates)) ?? nil
        return stored == "1"
    }
}
