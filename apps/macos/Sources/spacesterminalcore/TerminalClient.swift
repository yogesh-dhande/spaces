import Foundation

public enum TerminalClientKind: String, Codable, Sendable, CaseIterable {
    case localWindow
    case cliObserver
    case remoteViewer

    /// Whether a client of this kind is judged live by its attachment lease.
    ///
    /// A client that can vanish without sending a detach — anything reaching the session over a network or a
    /// separate process — proves it is still there by refreshing `lease_refreshed_at`. A local window client
    /// runs inside the app that talks to the daemon on the same machine, so its attachment row alone says
    /// whether it is there: `TerminalSessionAttachmentSnapshot.liveAttachments` counts it live while attached
    /// regardless of its lease, and `staleRemoteClients` never considers it for expiry.
    ///
    /// This is the single declaration of that rule. Every reader of `lease_refreshed_at` derives its
    /// kind filter from it, and the embedded core skips the durable lease write for a kind that answers
    /// `false` — a write no reader would consult.
    public var livenessDependsOnLease: Bool { self != .localWindow }
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
        id: String = UUID().uuidString, kind: TerminalClientKind, identity: TerminalClientIdentity, connectedAt: String,
        disconnectedAt: String? = nil, leaseRefreshedAt: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.identity = identity
        self.connectedAt = connectedAt
        self.disconnectedAt = disconnectedAt
        self.leaseRefreshedAt = leaseRefreshedAt
    }
}
