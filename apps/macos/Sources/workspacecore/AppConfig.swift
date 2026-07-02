import Foundation

public struct AppConfig: Sendable {
    /// Shared high port the Caddy router listens on; service URLs are `http://<svc>.<slug>.localhost:<routerPort>`.
    public static let defaultRouterPort = 8088

    public var editor: EditorPreference?
    public var portRange: PortRange
    public var routerPort: Int

    public init(editor: EditorPreference? = nil, portRange: PortRange, routerPort: Int = AppConfig.defaultRouterPort) {
        self.editor = editor
        self.portRange = portRange
        self.routerPort = routerPort
    }
}
