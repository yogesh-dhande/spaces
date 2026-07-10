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
        return "curl -fsSL \(installScriptURL) | bash -s -- \(normalized(version))"
    }

    /// The form the app runs over SSH for install-and-pair recovery. Downloads the installer to a
    /// temp file before executing it instead of piping `curl | bash`: under the remote `sh -c`
    /// wrapper a pipeline exits with bash's status — 0 on an empty stream — so a failed download of
    /// `install.sh` itself (DNS/TLS/404) would read as success; download-then-execute propagates
    /// curl's exit code and error text, and never executes a partially downloaded script.
    public static func sshInstallCommand(version: String?) -> String {
        let versionArgument = version.flatMap { $0.isEmpty ? nil : " \(normalized($0))" } ?? ""
        return #"set -e; installer="$(mktemp)"; trap 'rm -f "$installer"' EXIT; curl -fsSL \#(installScriptURL) -o "$installer"; bash "$installer"\#(versionArgument)"#
    }

    private static func normalized(_ version: String) -> String {
        version.hasPrefix("v") ? String(version.dropFirst()) : version
    }
}
