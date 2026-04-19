import Foundation

public struct AppConfig: Sendable {
    public var editor: EditorPreference?
    public var portRange: PortRange
    public var terminalHost: TerminalHost

    public init(editor: EditorPreference? = nil, portRange: PortRange, terminalHost: TerminalHost = .iterm2) {
        self.editor = editor
        self.portRange = portRange
        self.terminalHost = terminalHost
    }
}
