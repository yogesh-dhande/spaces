import Foundation

public struct TerminalTargetRecord: Codable, Sendable {
    public let runtimeTargetID: String?
    public let app: String
    public let name: String?
    public let detail: String?
    public let windowID: Int?
    public let provider: String?
    public let trackingID: String?
    public let nativeID: String?
    public let containerID: String?
    public let itermTabIndex: Int?
    public let tmuxWindowID: String?

    public init(
        runtimeTargetID: String? = nil, app: String, name: String? = nil, detail: String? = nil, windowID: Int? = nil, provider: String? = nil,
        trackingID: String? = nil, nativeID: String? = nil, containerID: String? = nil, itermTabIndex: Int? = nil, tmuxWindowID: String? = nil
    ) {
        self.runtimeTargetID = runtimeTargetID
        self.app = app
        self.name = name
        self.detail = detail
        self.windowID = windowID
        self.provider = provider
        self.trackingID = trackingID
        self.nativeID = nativeID
        self.containerID = containerID
        self.itermTabIndex = itermTabIndex
        self.tmuxWindowID = tmuxWindowID
    }
}
