import Foundation

/// The single user-runnable Linux install/upgrade path. Renders the version-pinned one-liner a user
/// runs on an Ubuntu 24.04 device to install or update the Spaces daemon to `version`, matching the
/// published `scripts/spaces-install-linux.sh` release asset. Spaces never auto-installs remote daemons.
public enum SpacesLinuxInstaller {
    public static let repository = "yogesh-dhande/spaces"

    /// e.g. `curl -fsSL https://github.com/yogesh-dhande/spaces/releases/download/v0.1.0/spaces-install-linux.sh | bash -s -- 0.1.0`
    public static func installCommand(version: String) -> String {
        let normalized = version.hasPrefix("v") ? String(version.dropFirst()) : version
        return
            "curl -fsSL https://github.com/\(repository)/releases/download/v\(normalized)/spaces-install-linux.sh | bash -s -- \(normalized)"
    }
}
