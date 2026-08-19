import Foundation

/// Wire-contract version negotiated between Spaces clients (macOS, iOS, CLI) and the per-device
/// `spacesd` daemon. This is intentionally distinct from the app/marketing version (`AppVersion`):
/// marketing versions drift freely on every release, while this integer changes only when the
/// Device API / TerminalService wire contract changes.
///
/// Client and daemon must speak the exact same version (lockstep — there is no backwards-compatibility
/// window). Raise `version` whenever the wire contract changes.
///
/// Raise it on a branch even when the value already looks raised: two branches that each bump the same
/// starting number land on the same literal, so git merges them without conflict and two genuinely
/// different contracts end up both claiming that number. Peers then pass the exact-match gate and fail
/// afterwards, which is precisely what this integer exists to prevent. Rebase or merge first, then take
/// the next unused number.
public enum SpacesWireProtocol {
    public static let version = currentVersion()

    // A non-literal initializer keeps dependent targets from baking the value into default arguments;
    // an incremental rebuild must observe the contract exported by this module.
    @inline(never) private static func currentVersion() -> Int { 30 }

    /// Compares dotted numeric version strings (e.g. "0.1.0"). Non-numeric components count as 0 and
    /// empty inputs compare equal, so a missing version never reports an update. Shared by macOS and
    /// iOS so the "daemon is running an older app build" check can't drift between the two clients.
    public static func isVersion(_ lhs: String, olderThan rhs: String) -> Bool {
        guard !lhs.isEmpty, !rhs.isEmpty else { return false }
        let lhsParts = lhs.split(separator: ".").map { Int($0) ?? 0 }
        let rhsParts = rhs.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(lhsParts.count, rhsParts.count) {
            let l = index < lhsParts.count ? lhsParts[index] : 0
            let r = index < rhsParts.count ? rhsParts[index] : 0
            if l != r { return l < r }
        }
        return false
    }
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

    public static func evaluate(daemonProtocolVersion: Int, localVersion: Int = SpacesWireProtocol.version) -> SpacesWireCompatibility {
        if daemonProtocolVersion == localVersion { return .compatible }
        return daemonProtocolVersion < localVersion ? .daemonTooOld : .clientTooOld
    }

    public static func evaluate(daemonStatus: TerminalServiceDaemonStatus) -> SpacesWireCompatibility {
        evaluate(daemonProtocolVersion: daemonStatus.protocolVersion)
    }
}
