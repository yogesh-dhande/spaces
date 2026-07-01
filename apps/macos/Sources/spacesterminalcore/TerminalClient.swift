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
    /// ISO8601 timestamp of the client's most recent lease refresh. Remote clients
    /// renew their lease periodically; a lease older than `remoteClientLeaseInterval`
    /// means the client is gone even though it never sent an explicit detach. Carried
    /// in the attachment snapshot so liveness can be judged off-device. `nil` for
    /// clients reconstructed without lease data.
    public let leaseRefreshedAt: String?

    public init(
        id: String = UUID().uuidString, kind: TerminalClientKind, identity: TerminalClientIdentity, connectedAt: String, disconnectedAt: String? = nil,
        leaseRefreshedAt: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.identity = identity
        self.connectedAt = connectedAt
        self.disconnectedAt = disconnectedAt
        self.leaseRefreshedAt = leaseRefreshedAt
    }
}
