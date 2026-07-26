import Foundation

/// This app's own marketing version, read straight from the bundle rather than any shared version
/// source: `workspacecore.AppVersion` belongs to the macOS app target and is not linked into this iOS
/// target. `CFBundleShortVersionString` is kept in sync by `scripts/sync-app-version.sh`, so it is the
/// honest value for this app's build.
///
/// Display only. Never compare this against a daemon's `version` or `installedVersion` to decide
/// anything — this app and a given device's daemon ship on unrelated release trains, so that
/// comparison would be meaningless (see `DaemonUpdateRemedy`'s doc comment). This exists purely so
/// compatibility copy can name a concrete version instead of saying "this app".
enum MobileAppVersion { static var current: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown" } }
