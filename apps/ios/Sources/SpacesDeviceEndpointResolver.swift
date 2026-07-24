import Foundation
import Network
import spacesterminalcore

/// Resolves the daemon endpoint for a paired Mac out of its ordered list of candidate addresses.
///
/// A paired Mac is reachable at more than one address depending on where this device currently is:
/// its LAN IPv4 address at home, its Tailscale `100.x` address away from home. The pinned-TLS
/// handshake validates the daemon by certificate fingerprint alone, never by address, so any
/// candidate that completes that handshake is provably the same trusted daemon this device paired
/// with — racing candidates concurrently is therefore safe, not a guess: whichever one answers first
/// is provably correct, not merely convenient. This type owns that race (a "happy eyeballs" walk: the
/// preferred candidate starts immediately, the rest start staggered — see `connect`), caches the
/// winner, and goes straight to it on every call after the first so steady-state connects pay no
/// discovery cost.
///
/// Must be a reference type (an actor, here) shared across every copy of the `SpacesDeviceNetworkBackend`
/// value that owns it: that backend is a struct created once per `SpacesDeviceAPIClient` but read from
/// two independent call paths (the request-transport path and the session-stream path), and both must
/// converge on the same cached winner — a command-channel request that fails over from the LAN address
/// to the tailnet address should mean the very next stream subscribe also starts from the tailnet
/// address, not repeat the same failed LAN attempt from scratch.
///
/// Commands and streams pick a candidate two different ways for the same underlying reason: a command
/// (`connect(timeout:queue:)`) can afford to race every candidate within one call because a caller
/// waiting on a response is already paying for a round trip. A session stream cannot — it has to stay
/// non-blocking (see `SpacesDeviceNetworkBackend.openSessionStream`) so a hung endpoint never delays
/// the viewer's post-subscribe state refresh, which is what surfaces an authentication failure
/// promptly. So a stream instead picks one candidate per attempt (`nextStreamHost()`) and rotates to
/// the next on failure (`noteStreamFailed(host:)`), converging on the right address across reconnect
/// attempts rather than within a single one.
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

    /// Delay before starting each successive candidate, relative to the first. Staggered rather than
    /// fully concurrent: at home the LAN candidate's handshake completes well inside this window, so
    /// the Tailscale attempt is never even started and the daemon still sees exactly one connection per
    /// cold connect — racing everything at once would cost the daemon a second, wasted TLS handshake on
    /// every single connect, at home or away. Away from home, where the LAN candidate is dead, the cost
    /// of trying it first drops from this window alone (250 ms) instead of waiting out the whole
    /// per-candidate timeout (up to 5 s) before the Tailscale candidate even starts.
    private static let candidateStaggerDelay: Duration = .milliseconds(250)

    private let hosts: [String]
    private let port: Int
    private let certificateFingerprint: String
    /// The candidate that most recently completed the pinned handshake. Tried first on every later
    /// call (if still present in `hosts`); cleared by `clearCachedWinner()` when a caller learns the
    /// cached address may no longer be right (its connection just broke, or the app returned to the
    /// foreground on a possibly different network).
    private var cachedHost: String?
    /// Candidates a session stream has recently failed on — consulted by `nextStreamHost()`, never by
    /// `connect(timeout:queue:)`. See `nextStreamHost()` for why streams need this and races don't.
    private var streamFailedHosts: Set<String> = []

    init(settings: SpacesMobileConnectionSettings) {
        hosts = settings.trimmedHosts
        port = settings.port
        certificateFingerprint = settings.certificateFingerprint
        // Warm-starts the cache from the last address that actually worked, so a freshly constructed
        // resolver (e.g. after `settings(from:)` rebuilds the live client with a widened `hosts` list)
        // does not have to re-race every candidate on its very first use. Reads the persisted record
        // the same way `recordActiveHost` below writes it — by certificate fingerprint — and only
        // trusts a value that is still a member of this instance's own `hosts`, exactly like `connect`
        // already re-validates a cached winner before using it.
        if let seeded = SpacesMobileDeviceStore.activeHost(certificateFingerprint: certificateFingerprint), hosts.contains(seeded) {
            cachedHost = seeded
        }
    }

    /// The candidate most recently proven reachable by this resolver instance, if any.
    func currentCachedHost() -> String? { cachedHost }

    /// Forgets the cached winner. The next `connect` call re-walks `hosts` from the top.
    func clearCachedWinner() { cachedHost = nil }

    /// The host a new session stream should use. Unlike `connect(timeout:queue:)`, this never races:
    /// `SpacesDeviceNetworkBackend.openSessionStream` must stay non-blocking so a hung endpoint cannot
    /// stall the viewer's post-subscribe state refresh — the thing that surfaces an authentication
    /// failure promptly against an endpoint that accepts TCP but never completes TLS. A stream
    /// therefore cannot pay a blocking race without delaying the error reporting the viewer depends
    /// on, so instead of converging within one attempt like a command does, a stream converges across
    /// reconnect attempts: each fresh stream tries the next untried candidate, and `noteStreamFailed`
    /// records the ones that didn't work.
    ///
    /// Prefers the cached winner (a command-channel request already proved it, or it was seeded from
    /// the persisted record at construction). Otherwise walks `hosts` for the first candidate not
    /// already reported failed; if every candidate has failed, the failed set is cleared and the walk
    /// restarts from the top — bounded (at most `hosts.count` candidates are ever "recently failed" at
    /// once) and self-resetting, so it can never wedge on a permanently dead candidate.
    func nextStreamHost() -> String? {
        if let cachedHost { return cachedHost }
        if let candidate = hosts.first(where: { !streamFailedHosts.contains($0) }) { return candidate }
        streamFailedHosts.removeAll()
        return hosts.first
    }

    /// Records that a session stream failed on `host`, so the next call to `nextStreamHost()` moves on
    /// to a different candidate instead of retrying the one that just broke. Also clears the cached
    /// winner if `host` was it, so a command-channel request racing right after does not trust the same
    /// now-suspect address either.
    func noteStreamFailed(host: String) {
        streamFailedHosts.insert(host)
        if cachedHost == host { cachedHost = nil }
    }

    /// Opens a ready, pinned-TLS connection to the first candidate that answers, racing the preferred
    /// order (the cached winner first, if it is still a member of `hosts`, then the rest of `hosts`)
    /// happy-eyeballs style: the first candidate starts immediately, each later one `candidateStaggerDelay`
    /// after the last (see `race`). Whichever completes its pinned-TLS handshake first wins; every other
    /// candidate's connection — in flight or not yet started — is cancelled.
    ///
    /// `timeout` is the caller's whole budget when there is exactly one candidate, which preserves the
    /// pre-multi-address behavior byte for byte for a device with a single known address. With more
    /// than one candidate, each attempt is capped at `min(timeout, perCandidateTimeoutCap)` so a dead
    /// address cannot consume the entire budget before the other candidates are tried.
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

        switch await Self.race(hosts: orderedHosts, port: nwPort, certificateFingerprint: certificateFingerprint, timeout: perCandidateTimeout, queue: queue)
        {
        case .success(let host, let connection):
            cachedHost = host
            SpacesMobileDeviceStore.recordActiveHost(host, certificateFingerprint: certificateFingerprint)
            return ResolvedConnection(connection: connection, host: host)
        case .failure(let sawPinMismatch):
            // No candidate answered and no pin mismatch was seen anywhere: name every address that was
            // tried and point at Tailscale, rather than surfacing whichever raw transport error happened
            // to come from one candidate (which says nothing about the others also tried).
            if sawPinMismatch { throw SpacesDeviceAPIClientError.transportAuthenticationFailed }
            throw SpacesDeviceAPIClientError.allCandidatesUnreachable(hosts: orderedHosts)
        }
    }

    /// Outcome of racing every candidate: either the winning connection, or a failure across the whole
    /// field — collapsing every candidate's individual outcome down to the one bit `connect` needs to
    /// classify (see its pin-mismatch documentation).
    private enum RaceOutcome {
        case success(host: String, connection: NWConnection)
        case failure(sawPinMismatch: Bool)
    }

    /// One candidate's outcome, before folding into `RaceOutcome` across the whole field.
    private enum CandidateOutcome: Sendable {
        case success(host: String, connection: NWConnection)
        /// Distinguishes "this candidate's TLS handshake never completed, but a plain TCP probe to the
        /// same address succeeded" (the pinned certificate did not match — a genuine re-pair signal,
        /// `pinMismatch: true`) from "nothing answered" or "this attempt was cancelled by the race
        /// (another candidate already won)" (`pinMismatch: false`).
        case failure(pinMismatch: Bool)
    }

    /// Races every candidate in `hosts` (already ordered, cached winner first): starts the first
    /// immediately and each subsequent one `candidateStaggerDelay` after the last, and returns the
    /// first connection whose pinned-TLS handshake completes. Nonisolated (a static method, not
    /// actor-isolated) since it touches no actor state — a pure function of its arguments — which lets
    /// its `withTaskGroup` children run concurrently instead of serializing through the actor.
    ///
    /// Every `NWConnection` this creates that is not the winner is cancelled before returning: a
    /// `TaskGroup` awaits every child task to finish (even cancelled ones) before yielding control back
    /// here, and each child's own `attempt(...)` cancels its connection on every path except the one
    /// that becomes the winner — including the cancellation a losing candidate observes when
    /// `group.cancelAll()` runs, since `SpacesDeviceAPIConnectionSupport.withTimeout` resumes a
    /// cancelled attempt by throwing into that same catch block. So by the time this function returns,
    /// no connection is left dangling.
    private static func race(hosts: [String], port: NWEndpoint.Port, certificateFingerprint: String, timeout: Duration, queue: DispatchQueue)
        async -> RaceOutcome
    {
        await withTaskGroup(of: CandidateOutcome.self) { group in
            for (index, candidateHost) in hosts.enumerated() {
                group.addTask {
                    if index > 0 {
                        do { try await Task.sleep(for: candidateStaggerDelay * index) } catch { return .failure(pinMismatch: false) }
                    }
                    return await attempt(host: candidateHost, port: port, certificateFingerprint: certificateFingerprint, timeout: timeout, queue: queue)
                }
            }

            var winner: (host: String, connection: NWConnection)?
            var sawPinMismatch = false
            for await outcome in group {
                switch outcome {
                case .success(let host, let connection):
                    guard winner == nil else {
                        // Lost the race to an earlier winner (e.g. two candidates answered within the
                        // same stagger step); this connection is otherwise never returned to a caller.
                        connection.cancel()
                        continue
                    }
                    winner = (host, connection)
                    group.cancelAll()
                case .failure(let pinMismatch):
                    if pinMismatch { sawPinMismatch = true }
                }
            }
            if let winner { return .success(host: winner.host, connection: winner.connection) }
            return .failure(sawPinMismatch: sawPinMismatch)
        }
    }

    /// One candidate's connect attempt: opens a pinned-TLS connection to `host` and waits for the
    /// handshake, capped at `timeout`. Always resolves to an outcome rather than throwing — `race`'s
    /// task group collects every candidate's result rather than tearing down on the first failure.
    private static func attempt(host: String, port: NWEndpoint.Port, certificateFingerprint: String, timeout: Duration, queue: DispatchQueue)
        async -> CandidateOutcome
    {
        let parameters = SpacesPinnedTLSConnector.tlsParameters(certificateFingerprint: certificateFingerprint)
        let connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: parameters)
        do {
            try await SpacesDeviceAPIConnectionSupport.waitUntilReady(connection, queue: queue, timeout: timeout)
            return .success(host: host, connection: connection)
        } catch {
            connection.cancel()
            if SpacesDeviceAPIConnectionSupport.isRequestTimedOut(error),
                await SpacesDeviceAPIConnectionSupport.canOpenPlainTCPConnection(host: host, port: port, timeout: .milliseconds(750))
            {
                return .failure(pinMismatch: true)
            }
            return .failure(pinMismatch: false)
        }
    }
}
