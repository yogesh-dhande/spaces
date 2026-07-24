import Foundation
import Network
import spacesterminalcore

/// Resolves the daemon endpoint for a paired Mac out of its ordered list of candidate addresses.
///
/// A paired Mac is reachable at more than one address depending on where this device currently is:
/// its LAN IPv4 address at home, its Tailscale `100.x` address away from home. The pinned-TLS
/// handshake validates the daemon by certificate fingerprint alone, never by address, so any
/// candidate that completes that handshake is provably the same trusted daemon this device paired
/// with — trying candidates in order is therefore safe, not a guess. This type owns that walk: it
/// tries `hosts` (most-preferred first, but starting from whichever candidate last answered), caches
/// the winner, and goes straight to it on every call after the first so steady-state connects pay no
/// discovery cost.
///
/// Must be a reference type (an actor, here) shared across every copy of the `SpacesDeviceNetworkBackend`
/// value that owns it: that backend is a struct created once per `SpacesDeviceAPIClient` but read from
/// two independent call paths (the request-transport path and the session-stream path), and both must
/// converge on the same cached winner — a command-channel request that fails over from the LAN address
/// to the tailnet address should mean the very next stream subscribe also starts from the tailnet
/// address, not repeat the same failed LAN attempt from scratch.
actor SpacesDeviceEndpointResolver {
    /// A connection the resolver has already brought to `.ready` (the pinned-TLS handshake is
    /// complete and the certificate fingerprint matched), plus the candidate host it answered on.
    struct ResolvedConnection {
        let connection: NWConnection
        let host: String
    }

    /// Caps a single candidate's connect attempt when more than one candidate is in play, so one
    /// unreachable address (typically the LAN address when away from home) cannot consume the whole
    /// caller-supplied budget before the next candidate even gets a turn.
    private static let perCandidateTimeoutCap: Duration = .seconds(5)

    private let hosts: [String]
    private let port: Int
    private let certificateFingerprint: String
    /// The candidate that most recently completed the pinned handshake. Tried first on every later
    /// call (if still present in `hosts`); cleared by `clearCachedWinner()` when a caller learns the
    /// cached address may no longer be right (its connection just broke, or the app returned to the
    /// foreground on a possibly different network).
    private var cachedHost: String?

    init(settings: SpacesMobileConnectionSettings) {
        hosts = settings.trimmedHosts
        port = settings.port
        certificateFingerprint = settings.certificateFingerprint
    }

    /// The candidate most recently proven reachable by this resolver instance, if any.
    func currentCachedHost() -> String? { cachedHost }

    /// Forgets the cached winner. The next `connect` call re-walks `hosts` from the top.
    func clearCachedWinner() { cachedHost = nil }

    /// Opens a ready, pinned-TLS connection to the first candidate that answers: the cached winner
    /// first (if it is still a member of `hosts`), then the rest of `hosts` in order.
    ///
    /// `timeout` is the caller's whole budget when there is exactly one candidate, which preserves the
    /// pre-multi-address behavior byte for byte for a device with a single known address. With more
    /// than one candidate, each attempt is capped at `min(timeout, perCandidateTimeoutCap)` so a dead
    /// address cannot consume the entire budget before the next candidate is tried.
    ///
    /// `queue` is the dispatch queue the *returned* connection will run on for the rest of its life —
    /// an `NWConnection` may only be started once, on one queue — so pass the same queue the caller
    /// intends to keep using for send/receive after this returns.
    func connect(timeout: Duration, queue: DispatchQueue) async throws -> ResolvedConnection {
        // `UInt16(exactly:)` rather than `UInt16(_:)`: the latter traps on an out-of-range `Int`, so the
        // guard could never actually reject a bad port — it would crash before reaching it.
        guard !hosts.isEmpty, let portValue = UInt16(exactly: port), let nwPort = NWEndpoint.Port(rawValue: portValue) else {
            throw SpacesDeviceAPIClientError.invalidEndpoint
        }

        var orderedHosts = hosts
        if let cachedHost, let cachedIndex = orderedHosts.firstIndex(of: cachedHost) {
            orderedHosts.remove(at: cachedIndex)
            orderedHosts.insert(cachedHost, at: 0)
        }
        let perCandidateTimeout = orderedHosts.count > 1 ? min(timeout, Self.perCandidateTimeoutCap) : timeout

        // Distinguishes "some candidate's TLS handshake never completed, but a plain TCP probe to that
        // same address succeeds" (the pinned certificate did not match — a genuine re-pair signal) from
        // "nothing answered at all" (just unreachable). A pin mismatch on *any* candidate must surface
        // as `transportAuthenticationFailed` so the caller routes into the re-pair recovery flow, even
        // if another candidate in the list also turns out to be simply unreachable.
        var sawPinMismatch = false

        for candidateHost in orderedHosts {
            let parameters = SpacesPinnedTLSConnector.tlsParameters(certificateFingerprint: certificateFingerprint)
            let connection = NWConnection(host: NWEndpoint.Host(candidateHost), port: nwPort, using: parameters)
            do {
                try await SpacesDeviceAPIConnectionSupport.waitUntilReady(connection, queue: queue, timeout: perCandidateTimeout)
            } catch {
                connection.cancel()
                if SpacesDeviceAPIConnectionSupport.isRequestTimedOut(error),
                    await SpacesDeviceAPIConnectionSupport.canOpenPlainTCPConnection(host: candidateHost, port: nwPort, timeout: .milliseconds(750))
                {
                    sawPinMismatch = true
                }
                continue
            }
            cachedHost = candidateHost
            SpacesMobileDeviceStore.recordActiveHost(candidateHost, certificateFingerprint: certificateFingerprint)
            return ResolvedConnection(connection: connection, host: candidateHost)
        }

        // No candidate answered and no pin mismatch was seen anywhere: name every address that was
        // tried and point at Tailscale, rather than surfacing whichever raw transport error happened to
        // come from the last candidate (which says nothing about the other candidates already tried).
        if sawPinMismatch { throw SpacesDeviceAPIClientError.transportAuthenticationFailed }
        throw SpacesDeviceAPIClientError.allCandidatesUnreachable(hosts: orderedHosts)
    }
}
