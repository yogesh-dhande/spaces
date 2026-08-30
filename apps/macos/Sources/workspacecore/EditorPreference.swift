import Foundation

/// How an editor opens a remote workspace, which determines its launch mechanism.
public enum EditorFamily: Sendable {
    /// Visual Studio Code or a fork: located via `product.json`, opened with
    /// `--folder-uri vscode-remote://ssh-remote+…`, and needs an SSH-remote extension.
    case vscode
    /// Zed: opened with `zed ssh://…`; SSH remoting is built in, no extension required.
    case zed
}

/// A GUI code editor the client can launch for a workspace, or the built-in Editor pane.
///
/// `.builtin` opens the app's own global Editor window (see `docs/implementation.md`) and is the
/// default: it needs nothing installed and works for local and remote workspaces alike. The other
/// cases launch an external app, located by bundle identifier (rename-proof) and driven through its
/// command-line tool. Remote opens present the workspace as a local window backed by the remote
/// filesystem, and re-launching the same folder focuses the editor's existing window — the client's
/// editor focus mechanism (see `docs/implementation.md`). The VS Code family and Zed differ in how
/// the remote workspace is addressed; see `family`.
public enum EditorPreference: String, Codable, Sendable, CaseIterable {
    case builtin
    case vscode
    case devin
    case zed

    /// Human-readable name shown in settings.
    public var displayName: String {
        switch self {
        case .builtin: return "Built-in"
        case .vscode: return "VS Code"
        case .devin: return "Devin Desktop"
        case .zed: return "Zed"
        }
    }

    /// macOS bundle identifier used to launch and detect the editor; `nil` for `.builtin`, which
    /// opens in-process rather than launching an external app.
    ///
    /// Devin Desktop keeps the legacy Windsurf identifier `com.exafunction.windsurf`
    /// after the rebrand: only the app name changed from `Windsurf.app` to `Devin.app`.
    public var bundleIdentifier: String? {
        switch self {
        case .builtin: return nil
        case .vscode: return "com.microsoft.VSCode"
        case .devin: return "com.exafunction.windsurf"
        case .zed: return "dev.zed.Zed"
        }
    }

    /// Launch family, which selects how a remote workspace is opened.
    public var family: EditorFamily {
        switch self {
        // `.builtin` never reaches an external launch; its value here is never consulted.
        case .builtin, .vscode, .devin: return .vscode
        case .zed: return .zed
        }
    }

    /// Marketplace identifier of the SSH-remote extension to install when the editor has
    /// none, or `nil` when the editor needs no installable extension.
    ///
    /// Stock VS Code does not bundle remote SSH and needs Microsoft's Remote - SSH. The
    /// forks ship their own (Devin Desktop bundles `codeium.windsurf-remote-openssh`) and
    /// Zed has SSH remoting built in, so there is nothing to install for them.
    public var installableRemoteSSHExtensionID: String? {
        switch self {
        case .vscode: return "ms-vscode-remote.remote-ssh"
        case .devin, .zed, .builtin: return nil
        }
    }
}
