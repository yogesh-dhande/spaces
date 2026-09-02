import Foundation

/// Which Sparkle appcast the app asks for updates from.
///
/// Every Spaces build is signed and packaged identically and carries the stable feed as its baked-in
/// `SUFeedURL`. The "Receive pre-release updates" setting is the only thing that moves a Mac to the
/// pre-release feed, and it does so at runtime rather than by installing a differently built binary,
/// so a user can opt in and back out without reinstalling.
enum UpdateFeed {
    /// Serves the newest tagged release, promoted or not. A Mac on this feed always moves forward:
    /// when a release is superseded, whether by a promotion or by the next patch tag, this feed
    /// names the newer one.
    static let prereleaseAppcastURLString = "https://usespaces.dev/releases/prerelease/appcast.xml"

    /// The feed override for the current setting, in the shape `SPUUpdaterDelegate.feedURLString(for:)`
    /// wants: `nil` means "no override", which leaves Sparkle on the stable `SUFeedURL` baked into the
    /// app bundle at build time. Kept free of Sparkle and AppKit so the choice itself is unit-testable.
    static func feedURLString(prereleaseUpdatesEnabled: Bool) -> String? {
        prereleaseUpdatesEnabled ? prereleaseAppcastURLString : nil
    }
}
