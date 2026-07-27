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
