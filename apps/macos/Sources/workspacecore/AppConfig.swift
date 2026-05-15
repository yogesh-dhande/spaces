import Foundation

public struct AppConfig: Sendable {
    public var editor: EditorPreference?
    public var portRange: PortRange
    public var processShell: ProcessShell

    public init(editor: EditorPreference? = nil, portRange: PortRange, processShell: ProcessShell = .zsh) {
        self.editor = editor
        self.portRange = portRange
        self.processShell = processShell
    }
}
