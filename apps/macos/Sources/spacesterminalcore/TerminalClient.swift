import Foundation

public enum TerminalClientKind: String, Codable, Sendable, CaseIterable {
    case localWindow
    case cliObserver
    case remoteViewer
}

public struct TerminalClientIdentity: Codable, Sendable, Equatable {
    public let label: String
    public let hostName: String?
    public let deviceName: String?
    public let networkAddress: String?

    public init(label: String, hostName: String? = nil, deviceName: String? = nil, networkAddress: String? = nil) {
        self.label = label
        self.hostName = hostName
        self.deviceName = deviceName
        self.networkAddress = networkAddress
    }
}

public struct TerminalClient: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let kind: TerminalClientKind
    public let identity: TerminalClientIdentity
    public let connectedAt: String
    public let disconnectedAt: String?

    public init(
        id: String = UUID().uuidString, kind: TerminalClientKind, identity: TerminalClientIdentity, connectedAt: String, disconnectedAt: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.identity = identity
        self.connectedAt = connectedAt
        self.disconnectedAt = disconnectedAt
    }
}
