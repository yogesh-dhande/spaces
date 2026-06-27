import Foundation

/// Inspects an installed VS Code-family editor bundle to locate its command-line tool and
/// decide whether it can open remote workspaces over SSH.
///
/// A remote open hands the editor a `vscode-remote://ssh-remote+…` folder URI, which only
/// resolves when the editor has an SSH-remote extension. Forks (Cursor, Devin Desktop)
/// bundle one as a built-in extension; stock VS Code requires the user to install
/// Microsoft's Remote - SSH. Everything here is derived from the bundle's `product.json`
/// so it tracks each editor's own CLI name and data directory instead of hardcoding them.
public struct EditorRemoteSSHSupport: Sendable {
    /// The editor's CLI command name (`product.json` `applicationName`), e.g. `code`.
    public let applicationName: String
    /// The editor's per-user data directory name (`product.json` `dataFolderName`),
    /// e.g. `.vscode`; user-installed extensions live under `~/<dataFolderName>/extensions`.
    public let dataFolderName: String
    private let appBundleURL: URL

    /// Reads `Contents/Resources/app/product.json` from the editor bundle. Fails when the
    /// bundle lacks the expected fields, i.e. it is not a VS Code-family editor.
    public init?(appBundleURL: URL) {
        let productURL = appBundleURL.appendingPathComponent("Contents/Resources/app/product.json")
        guard let data = try? Data(contentsOf: productURL), let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let applicationName = json["applicationName"] as? String, !applicationName.isEmpty,
            let dataFolderName = json["dataFolderName"] as? String, !dataFolderName.isEmpty
        else { return nil }
        self.appBundleURL = appBundleURL
        self.applicationName = applicationName
        self.dataFolderName = dataFolderName
    }

    /// The editor's CLI executable inside the bundle (e.g. `.../Resources/app/bin/code`).
    /// Launches and remote opens go through this rather than `open`, because `open`'s
    /// `--args` are dropped for an already-running editor; the CLI forwards to the running
    /// instance (and focuses the existing window for a folder) or cold-launches the app.
    public var cliExecutableURL: URL { appBundleURL.appendingPathComponent("Contents/Resources/app/bin/\(applicationName)") }

    /// True when an SSH-remote extension is present, checking both the bundle's built-in
    /// extensions and the user's installed extensions for this editor.
    public func hasRemoteSSHExtension(homeDirectory: URL) -> Bool {
        let builtIn = appBundleURL.appendingPathComponent("Contents/Resources/app/extensions")
        let userInstalled = homeDirectory.appendingPathComponent("\(dataFolderName)/extensions")
        return [builtIn, userInstalled].contains(where: Self.directoryHoldsRemoteSSHExtension)
    }

    /// An extension folder is an SSH-remote provider when its name mentions both "remote"
    /// and "ssh" — covering `ms-vscode-remote.remote-ssh`, `jeanp413.open-remote-ssh`, and
    /// the forks' `codeium.windsurf-remote-openssh`.
    private static func directoryHoldsRemoteSSHExtension(_ directory: URL) -> Bool {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return false }
        return entries.contains { name in
            let lower = name.lowercased()
            return lower.contains("remote") && lower.contains("ssh")
        }
    }
}
