import Foundation

/// Wire-contract version negotiated between Spaces clients (macOS, iOS, CLI) and the per-device
/// `spacesd` daemon. This is intentionally distinct from the app/marketing version (`AppVersion`):
/// marketing versions drift freely on every release, while this integer changes only when the
/// Device API / TerminalService wire contract changes.
///
/// Client and daemon must speak the exact same version (lockstep — there is no backwards-compatibility
/// window). Raise `version` whenever the wire contract changes.
public enum SpacesWireProtocol {
    // 2: SpacesDeviceTerminalSessionSummary carries the session shell/command (shell is a
    //    required decode field) and TerminalClient carries leaseRefreshedAt. A protocol-1
    //    daemon's overview omits these, so client and daemon must match exactly.
    // 3: Device API adds renameTerminalSession and terminalPasteImage (uploads an image
    //    payload to the owning daemon and injects the daemon-local temp path into the
    //    terminal). Both are new mutating wire operations a protocol-2 daemon cannot decode,
    //    so clients and daemons must update in lockstep.
    // 4: Device API transport moves from TLS-PSK (transport key) to the daemon's pinned
    //    self-signed TLS identity with pairing-issued bearer tokens; pairing links drop the
    //    psk field (link v2) and overview rows drop the always-nil daemonEndpoint. A
    //    protocol-3 client cannot even complete a TLS handshake with a protocol-4 daemon,
    //    so devices must re-pair after updating both sides. Also adds the agent-facing
    //    sendTerminalInput and tailTerminalOutput commands (one-shot terminal input and
    //    rendered output tail, token-authorized without attachment/owner gating).
    // 5: Pairing is version-gated at redemption. Pairing links become v3, advertising the
    //    daemon's wire-protocol version (pv) and app version (av); the client refuses to
    //    redeem an incompatible link, and the daemon symmetrically rejects a pair request
    //    whose clientProtocolVersion does not match before it validates the code. A v4 client
    //    and v5 daemon can still complete the TLS handshake, so the pairing gate — not the
    //    transport — is what stops the mismatch.
    // 6: The `profileCommand` payload changes from a flat operation-enum struct (one `operation`
    //    plus fifteen optionals) to `TerminalServiceProfileCommand`, a one-key-tagged union whose
    //    per-operation payload owns only that operation's fields, and terminal-send input becomes
    //    the tagged `TerminalProfileInput` (text xor bytes). A protocol-5 daemon cannot decode the
    //    new shape, so clients and daemons must update in lockstep.
    public static let version = 6

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
