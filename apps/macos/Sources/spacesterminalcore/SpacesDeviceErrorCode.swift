import Foundation

/// Machine-readable failure category carried alongside a response's human-readable
/// `message`. Clients branch on this instead of substring-matching messages.
public enum SpacesDeviceErrorCode: String, Codable, Sendable, Equatable {
    case unauthorized
    case notFound
    case invalidArgument
    case sessionNotRunning
    case sessionNotAvailable
    case ownershipRejected
    case busy
    case payloadTooLarge
    case unsupportedFormat
    case capabilityMissing
    case misroutedRequest
    case shuttingDown
    case internalError
}
