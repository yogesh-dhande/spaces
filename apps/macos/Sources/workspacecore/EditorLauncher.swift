import Foundation
import systembridge

/// Drives an editor through its command-line tool.
///
/// Launches go through the editor CLI (resolved from the bundle) rather than `open -b`.
/// `open`'s `--args` are silently dropped when the editor is already running, so
/// `open -b <id> --args …` never delivers a remote URI to a running editor. The CLI
/// forwards the request to the running instance — focusing the existing window for a
/// folder, the editor focus mechanism — or cold-launches the app.
public enum EditorLauncher {
    /// Opens a local workspace directory in the editor.
    public static func open(cliExecutablePath: String, directory: String) throws { _ = try Shell.run([cliExecutablePath, directory]) }

    /// Opens a workspace on a paired remote device in a VS Code-family editor by handing it
    /// a `vscode-remote://ssh-remote+[user@]host[:port]/path` folder URI, which the editor's
    /// SSH remote extension resolves into a local window backed by the remote filesystem.
    public static func openRemoteVSCode(cliExecutablePath: String, sshHost: String, sshUser: String?, sshPort: Int?, directory: String) throws {
        let target = try remoteTarget(sshHost: sshHost, sshUser: sshUser, sshPort: sshPort, directory: directory)
        _ = try Shell.run([cliExecutablePath, "--folder-uri", "vscode-remote://ssh-remote+\(target.authority)\(target.encodedPath)"])
    }

    /// Opens a workspace on a paired remote device in Zed via its built-in SSH remoting,
    /// passing a `ssh://[user@]host[:port]/path` URL that Zed resolves into a local window.
    public static func openRemoteZed(cliExecutablePath: String, sshHost: String, sshUser: String?, sshPort: Int?, directory: String) throws {
        let target = try remoteTarget(sshHost: sshHost, sshUser: sshUser, sshPort: sshPort, directory: directory)
        _ = try Shell.run([cliExecutablePath, "ssh://\(target.authority)\(target.encodedPath)"])
    }

    /// Installs an SSH-remote extension into the editor via its CLI, throwing when the CLI
    /// reports a non-zero exit so the caller can surface the failure.
    public static func installRemoteSSHExtension(cliExecutablePath: String, extensionID: String) throws {
        let status = try Shell.run([cliExecutablePath, "--install-extension", extensionID])
        guard status == 0 else { throw WorkspaceError.configError(message: "Installing the \(extensionID) extension failed (exit \(status)).") }
    }

    /// Builds the SSH authority (`[user@]host[:port]`) and percent-encoded workspace path
    /// shared by the remote launchers, rejecting a paired device with no SSH host.
    private static func remoteTarget(sshHost: String, sshUser: String?, sshPort: Int?, directory: String) throws -> (
        authority: String, encodedPath: String
    ) {
        let authority = [
            sshUser?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty.map { "\($0)@" } ?? "",
            sshHost.trimmingCharacters(in: .whitespacesAndNewlines), sshPort.map { ":\($0)" } ?? "",
        ].joined()
        guard !authority.isEmpty else {
            throw WorkspaceError.invalidArgument(message: "Remote editor launch requires an SSH host for the paired device.")
        }
        return (authority, directory.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? directory)
    }
}

extension String { fileprivate var nilIfEmpty: String? { isEmpty ? nil : self } }
