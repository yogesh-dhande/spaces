import Foundation

/// Where a client sits relative to the session it attaches to — purely locality, not a trust or
/// liveness distinction. `local` names a client that talks to the daemon on the same machine (this
/// Mac's own window onto its own daemon's session); `remote` names a client reaching the session over
/// a network hop, whether that is another paired Mac, an iPhone, or a Mac's own pane onto a session
/// hosted by a different paired device.
///
/// Every client kind is judged live the same way: by whether `lease_refreshed_at` was refreshed within
/// `TerminalSessionPersistence.remoteClientLeaseInterval` (`TerminalSessionAttachmentSnapshot.liveAttachments`,
/// `TerminalSessionPersistence.staleRemoteClients`). A `local` client reaches the daemon as a separate
/// process over a unix socket exactly like a `remote` one reaches it over the network — a force-quit or
/// a hung app leaves the identical kind of ghost attachment either way — so no kind is exempt from
/// expiry; every attached client, local or remote, keeps its lease fresh (see
/// `TerminalSessionPaneViewController`'s heartbeat and the touch-on-every-control-request pattern in
/// `GhosttyEmbeddedSessionHost`).
///
/// The one place `kind` still changes behavior is `TerminalRemoteSessionStatePolicy.shouldIncludeScreenState`'s
/// `.inputOutput` case: a `local` owner gets the terminal's own local echo instead of a duplicate
/// broadcast frame, an optimization that only makes sense when the owner is rendering the same PTY
/// output the daemon is.
public enum TerminalClientKind: String, Codable, Sendable, CaseIterable {
    case local
    case remote
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
