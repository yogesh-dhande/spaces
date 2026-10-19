import Foundation

/// Where an installed release daemon finds the installer bundled with its own release.
public enum DaemonSelfUpdateInstallLayout {
    public static let installerFileName = "spaces-install-linux.sh"

    /// The bundled installer for the release `executableURL` runs from, or nil when the executable is
    /// not inside `<root>/releases/<version>/bin/` (a development build, which has nothing to update
    /// from). The daemon runs its own release's copy: it carries the embedded public key and the
    /// signature and checksum verification, the same script as the website's `install.sh`.
    public static func installerURL(forExecutable executableURL: URL) -> URL? {
        let binDir = executableURL.resolvingSymlinksInPath().deletingLastPathComponent()
        let releaseDir = binDir.deletingLastPathComponent()
        guard binDir.lastPathComponent == "bin", releaseDir.deletingLastPathComponent().lastPathComponent == "releases" else { return nil }
        return releaseDir.appendingPathComponent(installerFileName, isDirectory: false)
    }
}
