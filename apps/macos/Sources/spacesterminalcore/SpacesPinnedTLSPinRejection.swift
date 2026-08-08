import Foundation

/// Records whether the pinned-TLS verify block rejected the peer's certificate during one connection
/// attempt.
///
/// The verify block is the only place that actually compares the peer's leaf certificate against the
/// pinned fingerprint, so a rejection recorded here is the authoritative "this is not the daemon this
/// client paired with" signal. Callers that drive their own `NWConnection` (the iOS Device API client)
/// read it after a failed handshake instead of inferring identity from the `NWError` shape: an
/// `NWError.tls` covers a handshake the OS aborted or reset as much as it covers a rejected pin, and
/// treating those alike turns an ordinary transport blip into a spurious re-pair prompt.
///
/// An attempt where the verify block never ran at all leaves this empty, which is the correct answer:
/// a peer that never presented a certificate said nothing about the daemon's identity.
public final class SpacesPinnedTLSPinRejection: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: TerminalServiceTLSError?

    public init() {}

    /// The verify block's rejection, or nil when it never rejected this peer.
    public var error: TerminalServiceTLSError? {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    /// First write wins: Network.framework can redial a rejected handshake on its own, running the
    /// verify block again, and the first rejection is the one that describes the identity first seen.
    public func record(_ error: TerminalServiceTLSError) {
        lock.lock()
        if recorded == nil { recorded = error }
        lock.unlock()
    }
}
