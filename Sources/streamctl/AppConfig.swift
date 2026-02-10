import Foundation

public struct AppConfig: Codable, Sendable {
    public var editor: EditorPreference?
    public var portRange: PortRange
    public var projects: [ProjectConfig]

    public init(editor: EditorPreference? = nil, portRange: PortRange, projects: [ProjectConfig]) {
        self.editor = editor
        self.portRange = portRange
        self.projects = projects
    }

    private enum CodingKeys: String, CodingKey {
        case editor
        case portRange = "port_range"
        case projects
    }
}
