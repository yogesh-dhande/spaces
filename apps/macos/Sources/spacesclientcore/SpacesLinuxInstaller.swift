import Foundation

/// The single user-runnable Linux install/upgrade path. Renders the one-liner a user runs on an
/// Ubuntu 24.04 device to install or update the Spaces daemon. The install script is served at
/// `usespaces.dev/install.sh` (the web build's prebuild copies `scripts/spaces-install-linux.sh`
/// into the published site); it is not a per-release GitHub asset. Spaces never auto-installs remote
/// daemons.
public enum SpacesLinuxInstaller {
    public static let installScriptURL = "https://usespaces.dev/install.sh"

    /// nil/empty version renders the evergreen `curl ... | bash` form (installs the latest
    /// release); a version renders the pinned `| bash -s -- <version>` form the app shows
    /// when the installed daemon must be wire-compatible with this client.
    public static func installCommand(version: String?) -> String {
        guard let version, !version.isEmpty else { return "curl -fsSL \(installScriptURL) | bash" }
        let normalized = version.hasPrefix("v") ? String(version.dropFirst()) : version
        return "curl -fsSL \(installScriptURL) | bash -s -- \(normalized)"
    }
}
