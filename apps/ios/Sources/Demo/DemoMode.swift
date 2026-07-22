import Foundation

/// Persistence for the Demo Mode enabled flag. Deliberately narrow: it touches only its own
/// `UserDefaults` key and never the paired-device records or the Keychain, so toggling Demo Mode
/// on and off leaves a user's real paired devices and their auth tokens exactly as they were.
///
/// Follows the same injection shape as `SpacesMobileSettingsStore`/`SpacesMobileDeviceStore` — the
/// production path uses `.standard`, and tests pass their own `UserDefaults` instance.
enum DemoModeStore {
    static let enabledKey = "spaces.mobile.demo-mode-enabled"

    static func load(defaults: UserDefaults = .standard) -> Bool { defaults.bool(forKey: enabledKey) }

    static func save(_ enabled: Bool, defaults: UserDefaults = .standard) { defaults.set(enabled, forKey: enabledKey) }
}

/// The single synthetic device Demo Mode presents in place of the user's real paired devices. Its
/// connection settings are obviously fake (`demo.local`, a placeholder fingerprint and token) and
/// never routable — nothing ever dials them because the demo `SpacesDeviceAPIClient` is built on the
/// in-memory `DemoDeviceBackend`, not the network backend. The placeholders exist only so the demo
/// settings read as `isPaired`, which the UI uses to decide it has a device to talk to.
enum SpacesMobileDemoDevice {
    static let id = "demo-mac"
    static let name = "Demo Mac"

    /// A non-routable placeholder host. The `.local` mDNS-style name makes it obvious in any log or UI
    /// that this is synthetic, and it is never contacted because the demo client bypasses the network.
    private static let host = "demo.local"
    /// Any valid port; the value is never dialed.
    private static let port = 1
    private static let certificateFingerprint = "SHA256:DEMO-MODE-PLACEHOLDER-NOT-A-REAL-CERTIFICATE"
    private static let authToken = "demo-mode-placeholder-token"
    /// Fixed so the demo record encodes identically across launches (nothing about Demo Mode should
    /// look like it "changed" between sessions).
    private static let timestamp = "2026-01-01T00:00:00Z"

    /// The paired-device record shown in the device list while Demo Mode is on. Held only in memory —
    /// it is never written to `SpacesMobileDeviceStore`.
    static func record() -> SpacesMobilePairedDeviceRecord {
        SpacesMobilePairedDeviceRecord(
            id: id, name: name, host: host, port: port, certificateFingerprint: certificateFingerprint, createdAt: timestamp, updatedAt: timestamp,
            lastSelectedAt: timestamp)
    }

    /// Connection settings for the synthetic device. `isPaired` is `true` (both a token and a
    /// fingerprint are present), carrying the real installation ID through so browser-proxy identity
    /// stays stable across the toggle.
    static func settings(installationID: String) -> SpacesMobileConnectionSettings {
        var settings = SpacesMobileConnectionSettings()
        settings.host = host
        settings.port = port
        settings.authToken = authToken
        settings.certificateFingerprint = certificateFingerprint
        settings.installationID = installationID
        return settings
    }
}
