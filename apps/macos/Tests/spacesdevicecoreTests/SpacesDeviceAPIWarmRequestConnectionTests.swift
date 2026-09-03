import Foundation
import Testing
import spacesterminalcore

@testable import spacesdevicecore

/// Covers the request path's warm connection: which requests reuse the connection parked for an
/// endpoint, when a request dials its own instead, and what happens when the daemon closed the parked
/// one under us. Every test drives the resolver's connect seam, so connection counts are exact.
@Suite struct SpacesDeviceAPIWarmRequestConnectionTests {
    private static let fingerprint = "SHA256:" + String(repeating: "a", count: 64)
    private static let otherFingerprint = "SHA256:" + String(repeating: "b", count: 64)
    private static let port = 47_847

    /// The behavior the issue is about: a command path that keeps asking the same daemon pays one
    /// handshake, not one per request.
    @Test func sequentialRequestsShareOneConnection() throws {
        let dialer = ConnectionDialer()
        let store = SpacesDeviceAPIWarmConnectionStore()
        let resolver = Self.makeResolver(hosts: ["lan"], dialer: dialer)

        for _ in 0..<5 {
            let client = try SpacesDeviceAPIRequestClient(resolver: resolver, timeoutSeconds: 5, warmConnections: store)
            #expect(try client.request(Self.request(.overview)).ok)
        }

        #expect(dialer.dialedHosts() == ["lan"])
        #expect(dialer.connections().first?.roundTrips() == 5)
    }

    /// Each device is a separate endpoint with its own pinned identity, so one device's connection is
    /// never handed to another's request.
    @Test func devicesDoNotShareAConnection() throws {
        let dialer = ConnectionDialer()
        let store = SpacesDeviceAPIWarmConnectionStore()
        let device = Self.makeResolver(hosts: ["lan"], dialer: dialer)
        let otherDevice = Self.makeResolver(hosts: ["lan"], fingerprint: Self.otherFingerprint, dialer: dialer)

        for resolver in [device, otherDevice, device, otherDevice] {
            let client = try SpacesDeviceAPIRequestClient(resolver: resolver, timeoutSeconds: 5, warmConnections: store)
            #expect(try client.request(Self.request(.overview)).ok)
        }

        // Two dials, one per endpoint, and each endpoint's connection carried both of its requests.
        #expect(dialer.dialedHosts() == ["lan", "lan"])
        #expect(dialer.connections().map { $0.roundTrips() } == [2, 2])
    }

    /// The daemon can close a parked connection at any time. A replay-safe request that finds it closed
    /// redials once, resolves again rather than going straight back to the address that just broke, and
    /// answers normally — the reuse stays invisible to the caller.
    @Test func aClosedParkedConnectionIsRedialedOnceAndResolvedAgain() throws {
        let dialer = ConnectionDialer()
        let store = SpacesDeviceAPIWarmConnectionStore()
        dialer.setDial(host: "lan", .succeedsThenFails(POSIXError(.ECONNREFUSED)))
        dialer.setScript(host: "lan", [.answersOK, .closes])
        dialer.setDial(host: "tailnet", .succeeds)
        let resolver = Self.makeResolver(hosts: ["lan", "tailnet"], dialer: dialer)

        let first = try SpacesDeviceAPIRequestClient(resolver: resolver, timeoutSeconds: 5, warmConnections: store)
        #expect(try first.request(Self.request(.overview)).ok)
        let second = try SpacesDeviceAPIRequestClient(resolver: resolver, timeoutSeconds: 5, warmConnections: store)
        #expect(try second.request(Self.request(.overview)).ok)

        // The parked connection was tried, then the candidates were re-walked: the dead address refused
        // and the request failed over rather than being reported as a failure to the caller.
        #expect(dialer.dialedHosts() == ["lan", "lan", "tailnet"])
        #expect(resolver.currentCachedHost() == "tailnet")
    }

    /// A request that must not run twice never takes a parked connection, because a connection the
    /// daemon closed cannot be told apart from one it closed after reading the request.
    @Test func aRequestThatIsNotReplaySafeDialsItsOwnConnection() throws {
        let dialer = ConnectionDialer()
        let store = SpacesDeviceAPIWarmConnectionStore()
        let resolver = Self.makeResolver(hosts: ["lan"], dialer: dialer)

        let read = try SpacesDeviceAPIRequestClient(resolver: resolver, timeoutSeconds: 5, warmConnections: store)
        #expect(try read.request(Self.request(.overview)).ok)
        let mutation = try SpacesDeviceAPIRequestClient(resolver: resolver, timeoutSeconds: 5, warmConnections: store)
        #expect(try mutation.request(Self.request(.requestDaemonRestart)).ok)
        // The mutation's own connection is parked in turn, so the next read reuses it.
        let readAgain = try SpacesDeviceAPIRequestClient(resolver: resolver, timeoutSeconds: 5, warmConnections: store)
        #expect(try readAgain.request(Self.request(.overview)).ok)

        #expect(dialer.dialedHosts() == ["lan", "lan"])
        #expect(dialer.connections().map { $0.roundTrips() } == [1, 2])
        // Only one connection is kept per endpoint: the read's connection was closed when the mutation's
        // replaced it, rather than being left open.
        #expect(dialer.connections().map { $0.isCancelled() } == [true, false])
    }

    /// The server closes a request connection after the response it composes for a rejected request, so
    /// a rejection must not leave a connection parked for the next request to find gone.
    @Test func aRejectedAnswerIsNotParked() throws {
        let dialer = ConnectionDialer()
        let store = SpacesDeviceAPIWarmConnectionStore()
        dialer.setScript(host: "lan", [.answersRejection])
        let resolver = Self.makeResolver(hosts: ["lan"], dialer: dialer)

        let rejected = try SpacesDeviceAPIRequestClient(resolver: resolver, timeoutSeconds: 5, warmConnections: store)
        #expect(try rejected.request(Self.request(.overview)).ok == false)
        let next = try SpacesDeviceAPIRequestClient(resolver: resolver, timeoutSeconds: 5, warmConnections: store)
        #expect(try next.request(Self.request(.overview)).ok == false)

        #expect(dialer.dialedHosts() == ["lan", "lan"])
        #expect(dialer.connections().allSatisfy { $0.isCancelled() })
    }

    /// A connection parked longer than the daemon keeps an idle request socket is dropped unused
    /// instead of being sent a request that would fail.
    @Test func aLongParkedConnectionIsDroppedInsteadOfReused() throws {
        let dialer = ConnectionDialer()
        let clock = TestUptime()
        let store = SpacesDeviceAPIWarmConnectionStore(maximumIdleInterval: 90, uptime: { clock.value() })
        let resolver = Self.makeResolver(hosts: ["lan"], dialer: dialer)

        let first = try SpacesDeviceAPIRequestClient(resolver: resolver, timeoutSeconds: 5, warmConnections: store)
        #expect(try first.request(Self.request(.overview)).ok)
        clock.advance(by: 91)
        let second = try SpacesDeviceAPIRequestClient(resolver: resolver, timeoutSeconds: 5, warmConnections: store)
        #expect(try second.request(Self.request(.overview)).ok)

        #expect(dialer.dialedHosts() == ["lan", "lan"])
        #expect(dialer.connections().first?.isCancelled() == true)
    }

    /// An endpoint nobody asks for again (a rebound port, a re-paired identity) is not held open for the
    /// life of the process: another endpoint's traffic sweeps its parked connection once it is stale.
    @Test func anotherEndpointsTrafficSweepsAnAbandonedParkedConnection() throws {
        let dialer = ConnectionDialer()
        let clock = TestUptime()
        let store = SpacesDeviceAPIWarmConnectionStore(maximumIdleInterval: 90, uptime: { clock.value() })
        let abandoned = try SpacesDeviceAPIRequestClient(
            resolver: Self.makeResolver(hosts: ["old"], dialer: dialer), timeoutSeconds: 5, warmConnections: store)
        #expect(try abandoned.request(Self.request(.overview)).ok)
        let live = try SpacesDeviceAPIRequestClient(
            resolver: Self.makeResolver(hosts: ["lan"], fingerprint: Self.otherFingerprint, dialer: dialer), timeoutSeconds: 5, warmConnections: store
        )

        clock.advance(by: 30)
        #expect(try live.request(Self.request(.overview)).ok)
        #expect(dialer.connections().first?.isCancelled() == false, "a parked connection inside the idle limit is kept")

        clock.advance(by: 61)
        #expect(try live.request(Self.request(.overview)).ok)
        #expect(dialer.connections().first?.isCancelled() == true, "parking on another endpoint sweeps the stale one")
        #expect(dialer.dialedHosts() == ["old", "lan"])
    }

    /// A network-path change invalidates every parked connection: they were established on a network
    /// this client has left.
    @Test func aNetworkChangeDiscardsParkedConnections() throws {
        let dialer = ConnectionDialer()
        let store = SpacesDeviceAPIWarmConnectionStore()
        let resolver = Self.makeResolver(hosts: ["lan"], dialer: dialer)

        let first = try SpacesDeviceAPIRequestClient(resolver: resolver, timeoutSeconds: 5, warmConnections: store)
        #expect(try first.request(Self.request(.overview)).ok)
        store.discardAll()
        let second = try SpacesDeviceAPIRequestClient(resolver: resolver, timeoutSeconds: 5, warmConnections: store)
        #expect(try second.request(Self.request(.overview)).ok)

        #expect(dialer.dialedHosts() == ["lan", "lan"])
        #expect(dialer.connections().first?.isCancelled() == true)
    }

    /// A network change can land while a request is out on a connection `discardAll` cannot see. That
    /// request finishes, but its connection belongs to the network this client left and is closed
    /// rather than parked, so the next request never dials into the old path.
    @Test func aConnectionInFlightAcrossANetworkChangeIsNotParked() throws {
        let store = SpacesDeviceAPIWarmConnectionStore()
        let endpoint = SpacesDeviceAPIWarmConnectionStore.endpointKey(certificateFingerprint: Self.fingerprint, port: Self.port)
        let inFlight = FakeLineConnection(script: [.answersOK])

        let generation = store.currentGeneration
        store.discardAll()
        store.park(inFlight, host: "lan", endpoint: endpoint, generation: generation)

        #expect(store.take(endpoint: endpoint) == nil)
        #expect(inFlight.isCancelled())
    }

    /// A request aimed at one address is asking whether that address answers, which a connection parked
    /// from a race cannot answer, so it dials its own and leaves the parked one alone.
    @Test func aPinnedRequestNeitherTakesNorParksTheWarmConnection() throws {
        let dialer = ConnectionDialer()
        let store = SpacesDeviceAPIWarmConnectionStore()
        let resolver = Self.makeResolver(hosts: ["lan"], dialer: dialer)

        let warming = try SpacesDeviceAPIRequestClient(resolver: resolver, timeoutSeconds: 5, warmConnections: store)
        #expect(try warming.request(Self.request(.overview)).ok)
        let probe = try SpacesDeviceAPIRequestClient(resolver: resolver, timeoutSeconds: 5, warmConnections: store)
        #expect(try probe.request(Self.request(.ping), pinnedHost: "lan").ok)
        let afterProbe = try SpacesDeviceAPIRequestClient(resolver: resolver, timeoutSeconds: 5, warmConnections: store)
        #expect(try afterProbe.request(Self.request(.overview)).ok)

        // The probe dialed and closed its own connection; the parked one carried both raced requests.
        #expect(dialer.dialedHosts() == ["lan", "lan"])
        #expect(dialer.connections().map { $0.roundTrips() } == [2, 1])
        #expect(dialer.connections().map { $0.isCancelled() } == [false, true])
    }

    private static func request(_ command: SpacesDeviceAPICommand) -> SpacesDeviceAPIRequest {
        SpacesDeviceAPIRequest(command: command, authToken: "token", clientApp: nil)
    }

    private static func makeResolver(
        hosts: [String], fingerprint: String = SpacesDeviceAPIWarmRequestConnectionTests.fingerprint, dialer: ConnectionDialer
    ) -> SpacesDeviceEndpointResolver {
        SpacesDeviceEndpointResolver(
            hosts: hosts, port: port, certificateFingerprint: fingerprint, activeHost: nil, onProvenHost: { _ in },
            connect: { host, _, _, _ in try dialer.connect(host: host) }, plainTCPProbe: { _, _, _ in false })
    }
}

/// A movable uptime clock, so idle expiry is exact rather than timed.
private final class TestUptime: @unchecked Sendable {
    private let lock = NSLock()
    private var seconds: TimeInterval = 0

    func value() -> TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return seconds
    }

    func advance(by interval: TimeInterval) {
        lock.lock()
        seconds += interval
        lock.unlock()
    }
}

/// Records every dial and hands back connections that answer from a script.
private final class ConnectionDialer: @unchecked Sendable {
    enum DialBehavior {
        case succeeds
        /// Answers the first dial and refuses every later one, the shape of an address that went away.
        case succeedsThenFails(any Error)
    }

    private let lock = NSLock()
    private var dialBehaviors: [String: DialBehavior] = [:]
    private var scripts: [String: [FakeLineConnection.Answer]] = [:]
    private var dialed: [String] = []
    private var made: [FakeLineConnection] = []

    func setDial(host: String, _ behavior: DialBehavior) {
        lock.lock()
        dialBehaviors[host] = behavior
        lock.unlock()
    }

    func setScript(host: String, _ answers: [FakeLineConnection.Answer]) {
        lock.lock()
        scripts[host] = answers
        lock.unlock()
    }

    func dialedHosts() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return dialed
    }

    /// Every connection handed out, in the order it was dialed.
    func connections() -> [FakeLineConnection] {
        lock.lock()
        defer { lock.unlock() }
        return made
    }

    func connect(host: String) throws -> any SpacesPinnedTLSLineConnection {
        lock.lock()
        dialed.append(host)
        let dialCount = dialed.filter { $0 == host }.count
        let behavior = dialBehaviors[host] ?? .succeeds
        let script = scripts[host] ?? []
        lock.unlock()

        if case .succeedsThenFails(let error) = behavior, dialCount > 1 { throw error }
        let connection = FakeLineConnection(script: script)
        lock.lock()
        made.append(connection)
        lock.unlock()
        return connection
    }
}

/// A pinned-TLS line connection that answers from a script, so what the daemon does on each round trip
/// is exact. Unscripted round trips answer `ok`.
private final class FakeLineConnection: SpacesPinnedTLSLineConnection, @unchecked Sendable {
    enum Answer {
        case answersOK
        case answersRejection
        /// The daemon closed this connection before answering.
        case closes
    }

    private let lock = NSLock()
    private var script: [Answer]
    private var completedRoundTrips = 0
    private var cancelled = false

    init(script: [Answer]) { self.script = script }

    func roundTrips() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return completedRoundTrips
    }

    func isCancelled() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func sendLine(_ line: Data, timeout: TimeInterval) throws {}

    func readLine(timeout: TimeInterval) throws -> Data {
        lock.lock()
        let answer = script.isEmpty ? Answer.answersOK : script.removeFirst()
        if case .closes = answer {
            lock.unlock()
            throw SpacesPinnedTLSConnectionError.connectionClosed
        }
        completedRoundTrips += 1
        lock.unlock()
        switch answer {
        case .answersOK: return try SpacesDeviceAPICodec.encodeResponse(SpacesDeviceAPIResponse(ok: true, message: "ok"))
        case .answersRejection: return try SpacesDeviceAPICodec.encodeResponse(SpacesDeviceAPIResponse(ok: false, message: "no"))
        case .closes: throw SpacesPinnedTLSConnectionError.connectionClosed
        }
    }

    func startReceiveLoop(
        onLine: @escaping @Sendable (Data) -> Void, onBytesReceived: @escaping @Sendable () -> Void,
        onClosed: @escaping @Sendable ((any Error)?) -> Void
    ) {}

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}
