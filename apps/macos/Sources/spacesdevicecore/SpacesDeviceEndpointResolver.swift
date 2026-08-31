import Dispatch
import Foundation
import spacesterminalcore

#if canImport(Darwin)
    import Darwin
#endif
#if canImport(Glibc)
    import Glibc
#endif

public enum SpacesDeviceEndpointResolverError: LocalizedError, Equatable {
    /// The device carries no candidate address at all, so there is nothing to dial. A stored record
    /// always has at least one, so this is an unusable record rather than an unreachable device.
    case noCandidateHosts
    /// Every candidate was tried and none answered, and no candidate reported a pinned-identity
    /// failure. Retryable: the device is off, asleep, or on a network none of these addresses reach.
    case allCandidatesUnreachable(hosts: [String])
    /// A candidate accepted TCP but never completed the pinned-TLS handshake, which means the daemon
    /// there is not the one this client pinned at pairing time. Recognized by
    /// `SpacesDeviceAPIAuthentication.isTransportAuthenticationFailure`, so it reaches the re-pair
    /// recovery flow instead of reading as an ordinary outage.
    case transportAuthenticationFailed(host: String)

    public var errorDescription: String? {
        switch self {
        case .noCandidateHosts: "No Device API address is stored for this device. Remove this device and pair it again."
        case .allCandidatesUnreachable(let hosts):
            "Could not reach the Device API at \(hosts.joined(separator: ", ")). Check that the device is awake and reachable on the network or Tailscale."
        case .transportAuthenticationFailed(let host): "The secure Device API transport could not authenticate \(host)."
        }
    }
}

/// Resolves which of a paired device's candidate addresses to dial, and dials it.
///
/// A paired device is reachable at more than one address depending on where this client currently is:
/// the device's LAN address on the same network, its Tailscale `100.x` address away from it. The
/// pinned-TLS handshake validates the daemon by certificate fingerprint alone, never by address, so any
/// candidate that completes that handshake is provably the same trusted daemon this client paired with
/// — racing candidates concurrently is therefore safe, not a guess: whichever one answers first is
/// provably correct, not merely convenient. This type owns that race (a "happy eyeballs" walk: the
/// preferred candidate starts immediately, the rest start staggered — see `connect(timeout:)`), caches
/// the winner, and goes straight to it on every call after the first so steady-state connects pay no
/// discovery cost. Mirrors the iOS client's `SpacesDeviceEndpointResolver`, adapted to this platform's
/// blocking connector.
///
/// One instance is shared per device across the command path and the stream path (see
/// `SpacesDeviceEndpointRegistry` in `spacesclientcore`): a command-channel request that fails over
/// from the LAN address to the tailnet address must mean the very next stream reconnect starts from the
/// tailnet address too, instead of repeating the same failed LAN attempt from scratch. Every method is
/// therefore thread-safe; callers reach it from request queues, stream callbacks, and the main actor.
///
/// Commands and streams pick a candidate two different ways for the same underlying reason: a command
/// (`connect(timeout:)`) can afford to race every candidate within one call because a caller waiting on
/// a response is already paying for a round trip. A stream cannot race — its connect is one blocking
/// step inside a reconnect driver that owns the retry schedule — so it picks one candidate per attempt
/// (`nextStreamHost()`) and rotates to the next on failure (`noteStreamFailed(host:)`), converging on
/// the right address across reconnect attempts rather than within a single one.
public final class SpacesDeviceEndpointResolver: @unchecked Sendable {
    /// A connection whose pinned-TLS handshake completed, plus the candidate host it answered on.
    public struct Resolved {
        public let connection: any SpacesPinnedTLSLineConnection
        public let host: String
    }

    /// Opens one pinned-TLS connection. Replaced in tests to simulate per-host latency, refusal, and
    /// pinned-identity failures without a live daemon; product code always gets
    /// `SpacesPinnedTLSConnector.connect`.
    typealias ConnectSeam =
        @Sendable (_ host: String, _ port: Int, _ certificateFingerprint: String, _ timeout: TimeInterval) throws -> any SpacesPinnedTLSLineConnection
    /// Answers whether a plain TCP connection to a candidate is accepted. Replaced in tests alongside
    /// `ConnectSeam` to drive the stalled-handshake classification below.
    typealias PlainTCPProbeSeam = @Sendable (_ host: String, _ port: Int, _ timeout: TimeInterval) -> Bool

    /// Caps a single candidate's connect attempt when more than one candidate is in play, so one
    /// unreachable address (typically the LAN address when away from that network) cannot consume the
    /// whole caller-supplied budget before the next candidate even gets a turn.
    static let perCandidateTimeoutCap: TimeInterval = 5
    /// Delay before starting each successive candidate, relative to the first. Staggered rather than
    /// fully concurrent: on the LAN the first candidate's handshake completes well inside this window,
    /// so the Tailscale attempt is never even started and the daemon still sees exactly one connection
    /// per cold connect — racing everything at once would cost the daemon a second, wasted TLS handshake
    /// on every connect. Away from that network, where the LAN candidate is dead, trying it first costs
    /// this window alone (250 ms) instead of the whole per-candidate timeout.
    static let candidateStaggerDelay: TimeInterval = 0.25
    /// Budget for the plain-TCP probe that tells a stalled pinned handshake apart from nothing
    /// listening. Short: the port either accepts immediately or it is not the daemon's.
    private static let plainTCPProbeTimeout: TimeInterval = 0.75

    public let port: Int
    public let certificateFingerprint: String

    private let onProvenHost: @Sendable (String) -> Void
    private let connectSeam: ConnectSeam
    private let plainTCPProbeSeam: PlainTCPProbeSeam
    /// Tracks every in-flight candidate attempt so tests can wait for losers to finish unwinding.
    private let attemptGroup = DispatchGroup()
    private let lock = NSLock()
    private var hosts: [String]
    /// The candidate that most recently completed the pinned handshake. Tried first on every later
    /// call; cleared when a caller learns the cached address may no longer be right (its connection
    /// just broke).
    private var cachedHost: String?
    /// Candidates a stream has recently failed on — consulted by `nextStreamHost()`, never by
    /// `connect(timeout:)`. See `nextStreamHost()` for why streams need this and races do not.
    private var streamFailedHosts: Set<String> = []

    /// - Parameters:
    ///   - activeHost: the address a connection last succeeded on, as persisted with the device record.
    ///     Warm-starts the cache so a freshly constructed resolver does not re-race every candidate on
    ///     its first use. Honored only while it is still a member of `hosts`.
    ///   - onProvenHost: invoked when a connect proves an address that was not already the cached
    ///     winner, so the owner can persist it.
    public convenience init(
        hosts: [String], port: Int, certificateFingerprint: String, activeHost: String? = nil,
        onProvenHost: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.init(
            hosts: hosts, port: port, certificateFingerprint: certificateFingerprint, activeHost: activeHost, onProvenHost: onProvenHost,
            connect: { host, port, fingerprint, timeout in
                try SpacesPinnedTLSConnector.connect(host: host, port: port, certificateFingerprint: fingerprint, timeout: timeout)
            }, plainTCPProbe: { host, port, timeout in PlainTCPProbe.portAccepts(host: host, port: port, timeout: timeout) })
    }

    init(
        hosts: [String], port: Int, certificateFingerprint: String, activeHost: String?, onProvenHost: @escaping @Sendable (String) -> Void,
        connect: @escaping ConnectSeam, plainTCPProbe: @escaping PlainTCPProbeSeam
    ) {
        self.hosts = Self.normalized(hosts)
        self.port = port
        self.certificateFingerprint = certificateFingerprint
        self.onProvenHost = onProvenHost
        connectSeam = connect
        plainTCPProbeSeam = plainTCPProbe
        cachedHost = activeHost.flatMap { self.hosts.contains($0) ? $0 : nil }
    }

    /// The candidate addresses this resolver dials, in preference order.
    public var candidateHosts: [String] {
        lock.lock()
        defer { lock.unlock() }
        return hosts
    }

    /// The candidate most recently proven reachable, if any.
    public func currentCachedHost() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return cachedHost
    }

    /// Swallows a widened (or otherwise changed) candidate list without losing what this resolver has
    /// learned: a cached winner and any recent stream failures survive as long as they still name a
    /// member of the new list.
    public func updateHosts(_ updated: [String]) {
        let normalized = Self.normalized(updated)
        lock.lock()
        defer { lock.unlock() }
        guard normalized != hosts else { return }
        hosts = normalized
        if let cachedHost, !normalized.contains(cachedHost) { self.cachedHost = nil }
        streamFailedHosts.formIntersection(normalized)
    }

    /// Forgets the cached winner. The next `connect(timeout:)` re-walks the candidates from the top.
    public func clearCachedWinner() {
        lock.lock()
        cachedHost = nil
        lock.unlock()
    }

    /// Forgets everything this resolver learned about *where* the device is: the cached winner and the
    /// candidates a stream has recently failed on. For when the ground the learning happened on has
    /// moved, which today means this client's own network path changed.
    ///
    /// The failed set has to go too, and clearing only the winner is the bug that hides here: a stream
    /// that failed on the LAN address while away from that network leaves it marked failed, and
    /// `nextStreamHost()` keeps skipping it after the client comes home — so the stream converges on the
    /// tailnet address it can still reach and never re-tries the address that is now the right one.
    /// Both facts were learned about a network that no longer applies, so both are dropped together.
    ///
    /// Distinct from the per-failure invalidation (`noteStreamFailed(host:)`, `noteConnectionFailed(host:)`),
    /// which is evidence about one address on the current network and keeps its meaning.
    public func resetForNetworkChange() {
        lock.lock()
        cachedHost = nil
        streamFailedHosts.removeAll()
        lock.unlock()
    }

    /// Records that a connection on `host` broke, so the next connect re-walks the candidates instead
    /// of going straight back to an address that may no longer be reachable (this client left the
    /// network it was on, the daemon moved). Invoked by the request transports on a send/read failure.
    public func noteConnectionFailed(host: String) {
        lock.lock()
        if cachedHost == host { cachedHost = nil }
        lock.unlock()
    }

    /// The host a new stream should use. Unlike `connect(timeout:)` this never races: a stream's
    /// connect is a single blocking step inside a reconnect driver that already owns the retry
    /// schedule, so it converges across reconnect attempts instead of within one.
    ///
    /// Prefers the cached winner (a command-channel request already proved it, or it was seeded from
    /// the persisted record). Otherwise walks the candidates for the first not already reported failed;
    /// if every candidate has failed, the failed set is cleared and the walk restarts from the top —
    /// bounded and self-resetting, so it can never wedge on a permanently dead candidate.
    public func nextStreamHost() -> String? {
        lock.lock()
        defer { lock.unlock() }
        if let cachedHost { return cachedHost }
        if let candidate = hosts.first(where: { !streamFailedHosts.contains($0) }) { return candidate }
        streamFailedHosts.removeAll()
        return hosts.first
    }

    /// Records that a stream failed on `host`, so the next `nextStreamHost()` moves on to a different
    /// candidate. Also clears the cached winner when `host` was it, so a command-channel request racing
    /// right after does not trust the same now-suspect address either.
    public func noteStreamFailed(host: String) {
        lock.lock()
        streamFailedHosts.insert(host)
        if cachedHost == host { cachedHost = nil }
        lock.unlock()
    }

    /// Opens one pinned-TLS connection to a specific candidate, without racing. Used by the stream
    /// transports, which pick their candidate through `nextStreamHost()`.
    ///
    /// A completed handshake here proves the address exactly as much as a race win does (the pin is what
    /// validates the daemon, and it is the same pin), so it is recorded the same way. Without that, a
    /// failover led by a stream would stay invisible to everything else: the next command-channel request
    /// would re-race from a candidate the stream already knows is dead, and the persisted `active_host`
    /// behind the Devices list and `spaces device list` would keep naming the path that stopped working.
    public func connect(host: String, timeout: TimeInterval) throws -> any SpacesPinnedTLSLineConnection {
        let connection = try connectSeam(host, port, certificateFingerprint, timeout)
        recordProven(host: host)
        return connection
    }

    /// Opens a pinned-TLS connection to the first candidate that answers, racing the preferred order
    /// (the cached winner first, then the rest) happy-eyeballs style: the first candidate starts
    /// immediately, each later one `candidateStaggerDelay` after the last. Whichever completes its
    /// handshake first wins; every other candidate's connection is cancelled, and candidates whose turn
    /// has not come yet are never dialed at all.
    ///
    /// `timeout` is the caller's whole budget when there is exactly one candidate, which preserves the
    /// pre-multi-address behavior for a device with a single known address. With more than one
    /// candidate each attempt is capped at `min(timeout, perCandidateTimeoutCap)`, so a dead address
    /// cannot consume the entire budget before the others are tried; the race as a whole therefore
    /// settles within the stagger schedule plus one capped attempt.
    ///
    /// Throws a pinned-identity failure whenever any candidate reported one, in preference to reporting
    /// the rest of the field as merely unreachable: an identity failure is the only outcome a user can
    /// act on (it has a re-pair recovery flow), while "unreachable" means try again later, and burying
    /// the former under the latter leaves the caller silently retrying forever.
    public func connect(timeout: TimeInterval) throws -> Resolved {
        let candidates = orderedCandidates()
        guard !candidates.isEmpty else { throw SpacesDeviceEndpointResolverError.noCandidateHosts }
        guard candidates.count > 1 else {
            let host = candidates[0]
            do {
                let connection = try connectSeam(host, port, certificateFingerprint, timeout)
                recordProven(host: host)
                return Resolved(connection: connection, host: host)
            } catch {
                throw failureError(
                    candidates: candidates, authenticationError: authenticationFailure(host: host, error: error, shouldProbe: { true }))
            }
        }
        return try race(candidates: candidates, timeout: min(timeout, Self.perCandidateTimeoutCap))
    }

    /// Runs the staggered race and returns its winner. Waits until a candidate wins or every attempt
    /// has finished: each attempt is bounded by its own connect timeout and the stagger schedule is
    /// bounded, so this cannot outlast `candidateStaggerDelay * (candidates.count - 1)` plus one
    /// per-candidate timeout — even when the Swift cooperative pool and the kernel workqueue behind
    /// GCD's non-overcommit queues are both fully occupied. Each attempt runs on its own dedicated
    /// `Thread` (via `SpacesBlockingIOThread`) rather than a `DispatchQueue.asyncAfter`, specifically
    /// because a concurrent-but-non-overcommit queue is never guaranteed a thread once the kernel
    /// workqueue is saturated: that starvation is what let a synchronous test running on the last free
    /// cooperative-pool thread deadlock a 3-core CI runner outright (issue #611), since `awaitOutcome()`
    /// below had nothing left to wake it. A real `Thread` is guaranteed to start regardless.
    private func race(candidates: [String], timeout: TimeInterval) throws -> Resolved {
        let state = RaceState(pending: candidates.count)
        for (index, host) in candidates.enumerated() {
            attemptGroup.enter()
            let staggerDelay = Self.candidateStaggerDelay * Double(index)
            SpacesBlockingIOThread.spawn(name: "spaces.device.endpoint.resolver.attempt") { [self] in
                defer { attemptGroup.leave() }
                if staggerDelay > 0 { Thread.sleep(forTimeInterval: staggerDelay) }
                // A candidate whose turn comes after the race is already decided is never dialed, which
                // is what keeps the common on-network case to exactly one connection per connect.
                guard !state.isDecided() else {
                    state.finishSkipped()
                    return
                }
                do {
                    let connection = try connectSeam(host, port, certificateFingerprint, timeout)
                    state.finishSucceeded(host: host, connection: connection)
                } catch {
                    state.finishFailed(authenticationError: authenticationFailure(host: host, error: error, shouldProbe: { !state.isDecided() }))
                }
            }
        }

        let outcome = state.awaitOutcome()
        if let winner = outcome.winner {
            recordProven(host: winner.host)
            return Resolved(connection: winner.connection, host: winner.host)
        }
        throw failureError(candidates: candidates, authenticationError: outcome.authenticationError)
    }

    /// Reduces one candidate's failed connect to the single bit the caller-facing error depends on: the
    /// pinned-identity failure to surface, or nil when the candidate simply did not answer.
    /// `shouldProbe` gates the follow-up plain-TCP probe so a loser that fails after the race is already
    /// decided does not spend a further probe budget on a classification nobody will read.
    private func authenticationFailure(host: String, error: any Error, shouldProbe: () -> Bool) -> (any Error)? {
        // The common shape of a pinned-identity failure: the connector's verify block rejects the
        // certificate and the connect fails outright. Classified through the same authority
        // `SpacesDeviceAPIAuthentication.recoveryMessage(for:)` uses to route a raw transport failure
        // into the re-pair flow, so the two stay in agreement about what counts as one.
        if SpacesDeviceAPIAuthentication.isTransportAuthenticationFailure(error) { return error }
        // The other shape: an endpoint that accepts TCP and then stalls without ever completing or
        // rejecting the handshake. A timed-out connect alone cannot tell that apart from "nothing is
        // listening there", so it only classifies as an identity failure once the probe proves
        // something answered.
        if case SpacesPinnedTLSConnectionError.timeout = error, shouldProbe(), plainTCPProbeSeam(host, port, Self.plainTCPProbeTimeout) {
            return SpacesDeviceEndpointResolverError.transportAuthenticationFailed(host: host)
        }
        return nil
    }

    private func failureError(candidates: [String], authenticationError: (any Error)?) -> any Error {
        authenticationError ?? SpacesDeviceEndpointResolverError.allCandidatesUnreachable(hosts: candidates)
    }

    private func orderedCandidates() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        guard let cachedHost, let cachedIndex = hosts.firstIndex(of: cachedHost) else { return hosts }
        var ordered = hosts
        ordered.remove(at: cachedIndex)
        ordered.insert(cachedHost, at: 0)
        return ordered
    }

    /// Caches the winner and, when it is a new one, reports it so the owner can persist it. Reporting
    /// only on a change keeps a steady-state connect free of persistence work.
    private func recordProven(host: String) {
        lock.lock()
        let isNewWinner = cachedHost != host
        cachedHost = host
        streamFailedHosts.remove(host)
        lock.unlock()
        if isNewWinner { onProvenHost(host) }
    }

    private static func normalized(_ hosts: [String]) -> [String] {
        var seen = Set<String>()
        return hosts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// Waits for every attempt this resolver has started to unwind, so a test can assert that losing
    /// connections were cancelled rather than leaked. Never called from product code.
    func drainPendingAttemptsForTesting() { attemptGroup.wait() }

    /// The shared state a race's attempts report into: the first winner, the first pinned-identity
    /// failure any candidate reported, and the pending count that tells the waiter when the field is
    /// exhausted.
    private final class RaceState: @unchecked Sendable {
        struct Outcome {
            let winner: (host: String, connection: any SpacesPinnedTLSLineConnection)?
            let authenticationError: (any Error)?
        }

        private let condition = NSCondition()
        private var winner: (host: String, connection: any SpacesPinnedTLSLineConnection)?
        private var authenticationError: (any Error)?
        private var pending: Int

        init(pending: Int) { self.pending = pending }

        func isDecided() -> Bool {
            condition.lock()
            defer { condition.unlock() }
            return winner != nil
        }

        func finishSucceeded(host: String, connection: any SpacesPinnedTLSLineConnection) {
            condition.lock()
            let isWinner = winner == nil
            if isWinner { winner = (host: host, connection: connection) }
            pending -= 1
            condition.broadcast()
            condition.unlock()
            // A candidate that completed its handshake after another one already won is never handed to
            // a caller, so its connection is closed here rather than left to time out on the daemon.
            if !isWinner { connection.cancel() }
        }

        func finishFailed(authenticationError: (any Error)?) {
            condition.lock()
            if self.authenticationError == nil { self.authenticationError = authenticationError }
            pending -= 1
            condition.broadcast()
            condition.unlock()
        }

        func finishSkipped() {
            condition.lock()
            pending -= 1
            condition.broadcast()
            condition.unlock()
        }

        func awaitOutcome() -> Outcome {
            condition.lock()
            defer { condition.unlock() }
            while winner == nil, pending > 0 { condition.wait() }
            return Outcome(winner: winner, authenticationError: authenticationError)
        }
    }
}

/// Whether a plain TCP connection to an address is accepted, which is the only way to tell a pinned
/// handshake that stalled (something is listening, but it is not the daemon this client pinned) apart
/// from nothing listening at all. Deliberately POSIX rather than Network.framework: this runs on the
/// Linux client too.
private enum PlainTCPProbe {
    static func portAccepts(host: String, port: Int, timeout: TimeInterval) -> Bool {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        #if canImport(Glibc)
            hints.ai_socktype = Int32(SOCK_STREAM.rawValue)
        #else
            hints.ai_socktype = SOCK_STREAM
        #endif
        var results: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &results) == 0, results != nil else { return false }
        defer { freeaddrinfo(results) }
        var candidate = results
        while let info = candidate {
            candidate = info.pointee.ai_next
            if accepts(address: info.pointee, timeout: timeout) { return true }
        }
        return false
    }

    private static func accepts(address: addrinfo, timeout: TimeInterval) -> Bool {
        let descriptor = socket(address.ai_family, address.ai_socktype, address.ai_protocol)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else { return false }
        if connect(descriptor, address.ai_addr, address.ai_addrlen) == 0 { return true }
        guard errno == EINPROGRESS else { return false }
        var pollDescriptor = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
        guard poll(&pollDescriptor, 1, Int32(timeout * 1000)) > 0 else { return false }
        var socketError: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        return getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &socketError, &length) == 0 && socketError == 0
    }
}
