import Foundation
import systembridge

public enum EditorLauncher {
    public static func open(editor: EditorPreference?, directory: String) throws {
        guard let editor, editor != .none else { throw WorkspaceError.configError(message: "Preferred editor is not configured.") }
        switch editor {
        case .vscode: _ = try Shell.run(["open", "-a", "Visual Studio Code", directory])
        case .cursor: _ = try Shell.run(["open", "-a", "Cursor", directory])
        case .windsurf: _ = try Shell.run(["open", "-a", "Windsurf", directory])
        case .vim: _ = try Shell.run(["open", "-a", "Terminal", directory])
        case .none: return
        }
    }

    public static func openRemote(editor: EditorPreference?, sshHost: String, sshUser: String?, sshPort: Int?, directory: String) throws {
        guard let editor, editor != .none else { throw WorkspaceError.configError(message: "Preferred editor is not configured.") }
        let authority = [
            sshUser?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty.map { "\($0)@" } ?? "",
            sshHost.trimmingCharacters(in: .whitespacesAndNewlines), sshPort.map { ":\($0)" } ?? "",
        ].joined()
        guard !authority.isEmpty else {
            throw WorkspaceError.invalidArgument(message: "Remote editor launch requires an SSH host for the paired device.")
        }
        let encodedPath = directory.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? directory
        let folderURI = "vscode-remote://ssh-remote+\(authority)\(encodedPath)"
        switch editor {
        case .vscode: _ = try Shell.run(["open", "-a", "Visual Studio Code", "--args", "--folder-uri", folderURI])
        case .cursor: _ = try Shell.run(["open", "-a", "Cursor", "--args", "--folder-uri", folderURI])
        case .windsurf: _ = try Shell.run(["open", "-a", "Windsurf", "--args", "--folder-uri", folderURI])
        case .vim:
            throw WorkspaceError.invalidArgument(message: "The selected editor does not support opening remote workspaces from the Spaces client.")
        case .none: return
        }
    }
}

extension String { fileprivate var nilIfEmpty: String? { isEmpty ? nil : self } }
