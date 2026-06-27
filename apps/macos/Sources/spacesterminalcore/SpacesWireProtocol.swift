import Foundation

/// Wire-contract version negotiated between Spaces clients (macOS, iOS, CLI) and the per-device
/// `spacesd` daemon. This is intentionally distinct from the app/marketing version (`AppVersion`):
/// marketing versions drift freely on every release, while this integer changes only when the
/// Device API / TerminalService wire contract changes.
///
/// Client and daemon must speak the exact same version (lockstep — there is no backwards-compatibility
/// window). Raise `version` whenever the wire contract changes.
public enum SpacesWireProtocol {
    public static let version = 1
}

/// Result of comparing this build's wire protocol against a daemon's advertised protocol.
public enum SpacesWireCompatibility: String, Sendable, Equatable, Codable {
    /// Versions match; the client and daemon can talk normally.
    case compatible
    /// The daemon is older than this client; it needs to update/restart.
    case daemonTooOld
    /// This client is older than the daemon; the client app must update.
    case clientTooOld

    /// Whether normal (non-frozen-core) operations should be allowed against the daemon.
    public var isCompatible: Bool { self == .compatible }

    public static func evaluate(
        daemonProtocolVersion: Int, localVersion: Int = SpacesWireProtocol.version
    ) -> SpacesWireCompatibility {
        if daemonProtocolVersion == localVersion { return .compatible }
        return daemonProtocolVersion < localVersion ? .daemonTooOld : .clientTooOld
    }

    public static func evaluate(daemonStatus: TerminalServiceDaemonStatus) -> SpacesWireCompatibility {
        evaluate(daemonProtocolVersion: daemonStatus.protocolVersion)
    }
}
