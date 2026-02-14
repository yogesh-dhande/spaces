import Foundation
import appctl

public enum EditorLauncher {
    public static func open(editor: EditorPreference?, directory: String) throws {
        guard let editor, editor != .none else { return }
        switch editor {
        case .vscode: _ = try Shell.run(["open", "-a", "Visual Studio Code", directory])
        case .cursor: _ = try Shell.run(["open", "-a", "Cursor", directory])
        case .windsurf: _ = try Shell.run(["open", "-a", "Windsurf", directory])
        case .vim: _ = try Shell.run(["open", "-a", "Terminal", directory])
        case .none: return
        }
    }
}
