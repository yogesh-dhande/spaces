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
    public static func open(cliExecutablePath: String, directory: String) throws { try runEditorCLI([cliExecutablePath, directory]) }

    /// Opens a workspace on a paired remote device in a VS Code-family editor by handing it
    /// a `vscode-remote://ssh-remote+[user@]host[:port]/path` folder URI, which the editor's
    /// SSH remote extension resolves into a local window backed by the remote filesystem.
    public static func openRemoteVSCode(cliExecutablePath: String, sshHost: String, sshUser: String?, sshPort: Int?, directory: String) throws {
        let target = try remoteTarget(sshHost: sshHost, sshUser: sshUser, sshPort: sshPort, directory: directory)
        try runEditorCLI([cliExecutablePath, "--folder-uri", "vscode-remote://ssh-remote+\(target.authority)\(target.encodedPath)"])
    }

    /// Opens a workspace on a paired remote device in Zed via its built-in SSH remoting,
    /// passing a `ssh://[user@]host[:port]/path` URL that Zed resolves into a local window.
    public static func openRemoteZed(cliExecutablePath: String, sshHost: String, sshUser: String?, sshPort: Int?, directory: String) throws {
        let target = try remoteTarget(sshHost: sshHost, sshUser: sshUser, sshPort: sshPort, directory: directory)
        try runEditorCLI([cliExecutablePath, "ssh://\(target.authority)\(target.encodedPath)"])
    }

    /// Installs an SSH-remote extension into the editor via its CLI, throwing when the CLI
    /// reports a non-zero exit so the caller can surface the failure.
    public static func installRemoteSSHExtension(cliExecutablePath: String, extensionID: String) throws {
        let status = try Shell.run([cliExecutablePath, "--install-extension", extensionID])
        guard status == 0 else { throw WorkspaceError.configError(message: "Installing the \(extensionID) extension failed (exit \(status)).") }
    }

    /// Runs an editor CLI command with `TMPDIR` pinned to the stable per-user temp directory.
    ///
    /// The editor is a detached, long-lived GUI app. Launching it through the CLI makes it
    /// inherit the Spaces process environment, including `TMPDIR`. When Spaces runs under a
    /// harness that scopes `TMPDIR` to an ephemeral per-step directory, that directory is torn
    /// down while the editor is still using it — e.g. Zed writes its SSH askpass script under
    /// `TMPDIR` and then fails with ENOENT. Pinning `TMPDIR` to the per-user temp directory
    /// (what a LaunchServices-opened app would get) keeps launches robust; in normal use this
    /// is the same directory the editor would have used anyway.
    private static func runEditorCLI(_ command: [String]) throws {
        _ = try Shell.run(["/usr/bin/env", "TMPDIR=\(stableTemporaryDirectory())"] + command)
    }

    /// The per-user temporary directory, independent of the `TMPDIR` environment variable a
    /// harness may have overridden. Falls back to `/tmp`, which is also stable.
    ///
    /// Editor launching is a macOS-client concern, but `workspacecore` also cross-compiles
    /// for the Linux daemon, so the Darwin-only `_CS_DARWIN_USER_TEMP_DIR` lookup is guarded.
    private static func stableTemporaryDirectory() -> String {
        #if os(Linux)
            return NSTemporaryDirectory()
        #else
            var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
            let length = confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, buffer.count)
            guard length > 0, length <= buffer.count else { return "/tmp" }
            let path = buffer.withUnsafeBufferPointer { pointer -> String in
                guard let base = pointer.baseAddress, let value = String(validatingCString: base) else { return "" }
                return value
            }
            return path.isEmpty ? "/tmp" : path
        #endif
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
