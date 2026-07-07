import Foundation

/// Computes the daemon process PATH value that includes the `spaces` CLI shipped next to
/// the running daemon executable. The Linux installer creates a shell-facing
/// `~/.local/bin/spaces` alias, but the systemd user service starts spacesd with the
/// distro default PATH, so daemon-launched processes still prepend the sibling CLI.
public enum SpacesCLISearchPath {
    public static let cliExecutableName = "spaces"

    /// Returns the PATH value with the CLI directory sibling to `executablePath` prepended,
    /// or nil when no adjustment is needed (no sibling `spaces` executable, or the directory
    /// already leads PATH). Prepending the daemon's own directory guarantees the resolved
    /// CLI version matches the running daemon.
    public static func pathPrependingSiblingCLIDirectory(executablePath: String?, currentPATH: String?, fileManager: FileManager = .default)
        -> String?
    {
        guard let executablePath, !executablePath.isEmpty else { return nil }
        let binDirectory = URL(fileURLWithPath: executablePath).deletingLastPathComponent().path
        let cliPath = URL(fileURLWithPath: binDirectory).appendingPathComponent(cliExecutableName).path
        guard fileManager.isExecutableFile(atPath: cliPath) else { return nil }
        let components: [String]
        if let currentPATH, !currentPATH.isEmpty {
            components = currentPATH.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        } else {
            components = []
        }
        guard components.first != binDirectory else { return nil }
        return ([binDirectory] + components.filter { $0 != binDirectory }).joined(separator: ":")
    }
}
