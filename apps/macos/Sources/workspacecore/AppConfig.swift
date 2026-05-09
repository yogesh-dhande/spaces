import Foundation

public struct AppConfig: Sendable {
    public var editor: EditorPreference?
    public var portRange: PortRange
    public var terminalHost: TerminalHost
    public var processShell: ProcessShell

    public init(editor: EditorPreference? = nil, portRange: PortRange, terminalHost: TerminalHost = .spaces, processShell: ProcessShell = .zsh) {
        self.editor = editor
        self.portRange = portRange
        self.terminalHost = terminalHost
        self.processShell = processShell
    }
}
