import Foundation

/// Machine-readable failure category carried alongside a response's human-readable
/// `message`. Clients branch on this instead of substring-matching messages.
public enum SpacesDeviceErrorCode: String, Codable, Sendable, Equatable {
    case unauthorized
    case notFound
    case invalidArgument
    case sessionNotRunning
    case sessionNotAvailable
    case serviceNotRunning
    case ownershipRejected
    case busy
    case payloadTooLarge
    case unsupportedFormat
    case capabilityMissing
    case misroutedRequest
    /// The daemon is exiting for good; no successor is coming, so a client should stop waiting and
    /// spawn a fresh daemon immediately. Distinct from `.handingOff` — see that case's doc.
    case shuttingDown
    /// The daemon is alive and mid exec-in-place handoff to an updated image; a successor is about to
    /// rebind the socket, so a client should wait for it rather than racing to spawn a competing
    /// daemon. Distinct from `.shuttingDown`, where no successor is coming — see
    /// `TerminalService.isTransitionalHandoffPing`, the sole consumer of that distinction.
    case handingOff
    case internalError
}

extension SpacesDeviceErrorCode {
    /// Whether this code is a verdict on the request itself — the daemon refused it and changed nothing —
    /// as opposed to a report that something went wrong while, or after, it acted.
    ///
    /// This is what lets a client tell a refused mutation from one whose outcome it simply does not know.
    /// `internalError` is the case that forces the distinction: the daemon answers with it both for a
    /// failure part-way through the work and for a request that SUCCEEDED and then failed while building
    /// the refreshed overview it answers with. A client reading that as a refusal tells the user a
    /// completed delete failed, and puts the deleted row back for them to act on again.
    ///
    /// Anything not listed here — including a code from a newer daemon this client does not know — is
    /// treated as not a verdict, deliberately. Reconciling a refusal costs one extra overview read;
    /// reporting a completed mutation as refused costs the user a row that lies to them.
    public var isRequestVerdict: Bool {
        switch self {
        // Rejected before any work: authorization, an unresolvable target, an argument the daemon would
        // not act on (a default workspace, a workspace already busy), or a daemon declining mid-handoff.
        case .unauthorized, .notFound, .invalidArgument, .handingOff: true
        default: false
        }
    }
}
