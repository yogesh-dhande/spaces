import Foundation

public struct AppConfig: Sendable {
    public var editor: EditorPreference?
    public var portRange: PortRange

    public init(editor: EditorPreference? = nil, portRange: PortRange) {
        self.editor = editor
        self.portRange = portRange
    }
}
