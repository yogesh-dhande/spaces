import Foundation

public struct AppConfig: Codable, Sendable {
    public var editor: EditorPreference?
    public var portRange: PortRange

    public init(editor: EditorPreference? = nil, portRange: PortRange) {
        self.editor = editor
        self.portRange = portRange
    }

    private enum CodingKeys: String, CodingKey {
        case editor
        case portRange = "port_range"
    }
}
