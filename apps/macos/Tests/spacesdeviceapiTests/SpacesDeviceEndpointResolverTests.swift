import Foundation
import XCTest
import spacesterminalcore

@testable import spacesdevicecore

/// Covers how a paired device's candidate addresses are chosen, raced, and invalidated. Every test
/// drives the resolver's connect seam instead of a live daemon, so per-host latency, refusal, and
/// pinned-identity failures are exact rather than timing-dependent.
final class SpacesDeviceEndpointResolverTests: XCTestCase {
    private static let fingerprint = "SHA256:" + String(repeating: "a", count: 64)
    private static let port = 47_847

    func testCachedWinnerIsTriedFirstAndAloneWhenItAnswers() throws {
        let connector = ConnectRecorder()
        connector.setBehavior(host: "lan", .succeeds)
        connector.setBehavior(host: "tailnet", .succeeds)
        let resolver = makeResolver(hosts: ["lan", "other", "tailnet"], activeHost: "tailnet", connector: connector)

        let resolved = try resolver.connect(timeout: 10)
        defer { resolved.connection.cancel() }

        XCTAssertEqual(resolved.host, "tailnet")
        // The proven address answers inside the stagger window, so no other candidate is ever dialed:
        // a steady-state connect costs the daemon exactly one handshake.
        XCTAssertEqual(connector.dialedHosts, ["tailnet"])
    }

    func testFailoverRecordsAndReportsTheAddressThatAnswered() throws {
        let connector = ConnectRecorder()
        connector.setBehavior(host: "lan", .fails(POSIXError(.ECONNREFUSED)))
        connector.setBehavior(host: "tailnet", .succeeds)
        let provenHosts = HostRecorder()
        let resolver = makeResolver(hosts: ["lan", "tailnet"], connector: connector, onProvenHost: provenHosts.append)

        let resolved = try resolver.connect(timeout: 10)
        defer { resolved.connection.cancel() }

        XCTAssertEqual(resolved.host, "tailnet")
        XCTAssertEqual(resolver.currentCachedHost(), "tailnet")
        // Reported once so the owner can persist it; a later connect on the same address reports nothing.
        XCTAssertEqual(provenHosts.hosts(), ["tailnet"])
        let second = try resolver.connect(timeout: 10)
        second.connection.cancel()
        XCTAssertEqual(provenHosts.hosts(), ["tailnet"])
    }

    func testSingleCandidateGetsTheWholeCallerBudgetAndSeveralShareACappedOne() throws {
        let singleConnector = ConnectRecorder()
        singleConnector.setBehavior(host: "lan", .succeeds)
        let single = makeResolver(hosts: ["lan"], connector: singleConnector)
        let resolved = try single.connect(timeout: 30)
        resolved.connection.cancel()
        XCTAssertEqual(singleConnector.timeouts(), [30])

        let racedConnector = ConnectRecorder()
        racedConnector.setBehavior(host: "lan", .fails(POSIXError(.ECONNREFUSED)))
        racedConnector.setBehavior(host: "tailnet", .succeeds)
        let raced = makeResolver(hosts: ["lan", "tailnet"], connector: racedConnector)
        let racedResolution = try raced.connect(timeout: 30)
        racedResolution.connection.cancel()
        // A dead address cannot spend the whole budget before the next candidate is tried.
        XCTAssertEqual(
            racedConnector.timeouts(), [SpacesDeviceEndpointResolver.perCandidateTimeoutCap, SpacesDeviceEndpointResolver.perCandidateTimeoutCap])
    }

    func testPinnedIdentityFailureBeatsTheRestOfTheFieldBeingUnreachable() {
        let connector = ConnectRecorder()
        connector.setBehavior(host: "lan", .fails(POSIXError(.ECONNREFUSED)))
        connector.setBehavior(host: "tailnet", .fails(TerminalServiceTLSError.certificatePinMismatch(expected: "expected", actual: "actual")))
        let resolver = makeResolver(hosts: ["lan", "tailnet"], connector: connector)

        XCTAssertThrowsError(try resolver.connect(timeout: 10)) { error in
            // The only outcome the user can act on: it has to reach the re-pair flow rather than being
            // buried under "everything else was unreachable".
            XCTAssertTrue(SpacesDeviceAPIAuthentication.isTransportAuthenticationFailure(error))
        }
    }

    func testStalledHandshakeOnAnOpenPortIsAPinnedIdentityFailure() {
        let connector = ConnectRecorder()
        connector.setBehavior(host: "lan", .fails(SpacesPinnedTLSConnectionError.timeout))
        let answering = makeResolver(hosts: ["lan"], connector: connector, plainTCPProbeAnswers: true)

        XCTAssertThrowsError(try answering.connect(timeout: 1)) { error in
            XCTAssertEqual(error as? SpacesDeviceEndpointResolverError, .transportAuthenticationFailed(host: "lan"))
            XCTAssertTrue(SpacesDeviceAPIAuthentication.isTransportAuthenticationFailure(error))
        }

        // The same timeout with nothing listening is an ordinary outage, not an identity failure.
        let silent = makeResolver(hosts: ["lan"], connector: connector, plainTCPProbeAnswers: false)
        XCTAssertThrowsError(try silent.connect(timeout: 1)) { error in
            XCTAssertEqual(error as? SpacesDeviceEndpointResolverError, .allCandidatesUnreachable(hosts: ["lan"]))
        }
    }

    func testUnreachableFailureNamesEveryCandidateItTried() {
        let connector = ConnectRecorder()
        connector.setBehavior(host: "lan", .fails(POSIXError(.ECONNREFUSED)))
        connector.setBehavior(host: "tailnet", .fails(POSIXError(.EHOSTUNREACH)))
        let resolver = makeResolver(hosts: ["lan", "tailnet"], connector: connector)

        XCTAssertThrowsError(try resolver.connect(timeout: 2)) { error in
            XCTAssertEqual(error as? SpacesDeviceEndpointResolverError, .allCandidatesUnreachable(hosts: ["lan", "tailnet"]))
            // Naming both is the point: reporting one candidate's raw transport error says nothing about
            // the others that were also tried.
            XCTAssertTrue(error.localizedDescription.contains("lan"))
            XCTAssertTrue(error.localizedDescription.contains("tailnet"))
        }
    }

    func testEveryLosingConnectionIsClosedAndUnstartedCandidatesAreNeverDialed() throws {
        let connector = ConnectRecorder()
        // The preferred candidate answers, but only after the second candidate already won.
        connector.setBehavior(host: "lan", .succeedsAfter(0.6))
        connector.setBehavior(host: "tailnet", .succeeds)
        let resolver = makeResolver(hosts: ["lan", "tailnet"], connector: connector)

        let resolved = try resolver.connect(timeout: 10)
        defer { resolved.connection.cancel() }
        XCTAssertEqual(resolved.host, "tailnet")

        resolver.drainPendingAttemptsForTesting()
        XCTAssertEqual(connector.cancelledHosts(), ["lan"])
        XCTAssertFalse(connector.connection(host: "tailnet")?.isCancelled ?? true)
    }

    func testStreamHostsRotateAcrossAttemptsAndResetWhenEveryCandidateHasFailed() {
        let resolver = makeResolver(hosts: ["lan", "tailnet"], connector: ConnectRecorder())

        XCTAssertEqual(resolver.nextStreamHost(), "lan")
        resolver.noteStreamFailed(host: "lan")
        XCTAssertEqual(resolver.nextStreamHost(), "tailnet")
        resolver.noteStreamFailed(host: "tailnet")
        // Bounded and self-resetting: with every candidate reported failed the walk restarts from the
        // top rather than wedging on nothing to return.
        XCTAssertEqual(resolver.nextStreamHost(), "lan")
    }

    func testStreamPrefersTheProvenAddressAndFailingItClearsTheCache() {
        let resolver = makeResolver(hosts: ["lan", "tailnet"], activeHost: "tailnet", connector: ConnectRecorder())

        XCTAssertEqual(resolver.nextStreamHost(), "tailnet")
        resolver.noteStreamFailed(host: "tailnet")
        // A command-channel request racing right after must not trust the address the stream just lost.
        XCTAssertNil(resolver.currentCachedHost())
        XCTAssertEqual(resolver.nextStreamHost(), "lan")
    }

    /// A stream's failover has to steer everything else. The stream dials one candidate directly rather
    /// than racing, and a completed pinned handshake there proves the address exactly as much as a race
    /// win does, so it must land in the shared cache and be reported for persistence.
    func testDirectStreamDialProvesItsAddressForTheCommandPathAndForPersistence() throws {
        let connector = ConnectRecorder()
        connector.setBehavior(host: "lan", .succeeds)
        connector.setBehavior(host: "tailnet", .succeeds)
        let provenHosts = HostRecorder()
        let resolver = makeResolver(hosts: ["lan", "tailnet"], activeHost: "lan", connector: connector, onProvenHost: provenHosts.append)

        // The stream rotates off the proven address and dials the next candidate itself.
        resolver.noteStreamFailed(host: "lan")
        let host = try XCTUnwrap(resolver.nextStreamHost())
        XCTAssertEqual(host, "tailnet")
        try resolver.connect(host: host, timeout: 10).cancel()

        XCTAssertEqual(resolver.currentCachedHost(), "tailnet")
        XCTAssertEqual(provenHosts.hosts(), ["tailnet"])
        // The next command-channel connect goes straight to what the stream proved instead of re-racing
        // from the candidate the stream already found dead.
        let resolved = try resolver.connect(timeout: 10)
        resolved.connection.cancel()
        XCTAssertEqual(resolved.host, "tailnet")
        XCTAssertEqual(connector.dialedHosts, ["tailnet", "tailnet"])
        // Proven once, so a steady stream of reconnects on a settled address costs no repeated writes.
        XCTAssertEqual(provenHosts.hosts(), ["tailnet"])
    }

    func testUpdatedCandidatesKeepAProvenAddressOnlyWhileItIsStillACandidate() {
        let resolver = makeResolver(hosts: ["lan", "tailnet"], activeHost: "tailnet", connector: ConnectRecorder())

        resolver.updateHosts(["tailnet", "lan", "relay"])
        XCTAssertEqual(resolver.candidateHosts, ["tailnet", "lan", "relay"])
        XCTAssertEqual(resolver.currentCachedHost(), "tailnet")

        resolver.updateHosts(["lan", "relay"])
        XCTAssertNil(resolver.currentCachedHost())
    }

    func testConnectionFailureClearsTheProvenAddressSoTheNextConnectReWalks() throws {
        let connector = ConnectRecorder()
        connector.setBehavior(host: "lan", .succeeds)
        connector.setBehavior(host: "tailnet", .succeeds)
        let resolver = makeResolver(hosts: ["lan", "tailnet"], activeHost: "tailnet", connector: connector)

        resolver.noteConnectionFailed(host: "tailnet")
        XCTAssertNil(resolver.currentCachedHost())
        let resolved = try resolver.connect(timeout: 10)
        resolved.connection.cancel()
        XCTAssertEqual(resolved.host, "lan")
    }

    /// The session client's replay after a closed connection must go back through the resolver rather
    /// than reusing the address that just broke, so a device that moved is followed within one request.
    func testRequestSessionReplayResolvesAgainAndFailsOverToAnotherCandidate() throws {
        let connector = ConnectRecorder()
        connector.setBehavior(host: "lan", .succeedsThenFailsWith(POSIXError(.ECONNREFUSED)))
        connector.setBehavior(host: "tailnet", .succeeds)
        connector.setResponse(host: "lan", .closesBeforeResponding)
        connector.setResponse(host: "tailnet", .respondsPong)
        let resolver = makeResolver(hosts: ["lan", "tailnet"], connector: connector)
        let client = try SpacesDeviceAPIRequestSessionClient(resolver: resolver)
        defer { client.cancel() }

        let response = try client.send(SpacesDeviceAPIRequest(command: .ping, authToken: "token", clientApp: nil))

        XCTAssertTrue(response.ok)
        XCTAssertEqual(connector.dialedHosts, ["lan", "lan", "tailnet"])
        XCTAssertEqual(resolver.currentCachedHost(), "tailnet")
    }

    private func makeResolver(
        hosts: [String], activeHost: String? = nil, connector: ConnectRecorder, plainTCPProbeAnswers: Bool = false,
        onProvenHost: @escaping @Sendable (String) -> Void = { _ in }
    ) -> SpacesDeviceEndpointResolver {
        SpacesDeviceEndpointResolver(
            hosts: hosts, port: Self.port, certificateFingerprint: Self.fingerprint, activeHost: activeHost, onProvenHost: onProvenHost,
            connect: { host, _, _, timeout in try connector.connect(host: host, timeout: timeout) },
            plainTCPProbe: { _, _, _ in plainTCPProbeAnswers })
    }
}

/// Records what a resolver dialed and with which budget, and hands back scripted connections.
private final class ConnectRecorder: @unchecked Sendable {
    enum Behavior {
        case succeeds
        case succeedsAfter(TimeInterval)
        case fails(any Error)
        /// Answers the first dial and refuses every later one, the shape of a device that moved.
        case succeedsThenFailsWith(any Error)
    }

    enum ResponseBehavior {
        case respondsPong
        case closesBeforeResponding
    }

    private let lock = NSLock()
    private var behaviors: [String: Behavior] = [:]
    private var responses: [String: ResponseBehavior] = [:]
    private var dialed: [String] = []
    private var recordedTimeouts: [TimeInterval] = []
    private var connections: [String: FakeLineConnection] = [:]

    func setBehavior(host: String, _ behavior: Behavior) {
        lock.lock()
        behaviors[host] = behavior
        lock.unlock()
    }

    func setResponse(host: String, _ response: ResponseBehavior) {
        lock.lock()
        responses[host] = response
        lock.unlock()
    }

    var dialedHosts: [String] {
        lock.lock()
        defer { lock.unlock() }
        return dialed
    }

    func timeouts() -> [TimeInterval] {
        lock.lock()
        defer { lock.unlock() }
        return recordedTimeouts
    }

    func connection(host: String) -> FakeLineConnection? {
        lock.lock()
        defer { lock.unlock() }
        return connections[host]
    }

    func cancelledHosts() -> [String] {
        lock.lock()
        let all = connections
        lock.unlock()
        return all.filter { $0.value.isCancelled }.keys.sorted()
    }

    func connect(host: String, timeout: TimeInterval) throws -> any SpacesPinnedTLSLineConnection {
        lock.lock()
        dialed.append(host)
        recordedTimeouts.append(timeout)
        let behavior = behaviors[host] ?? .fails(POSIXError(.ECONNREFUSED))
        let dialCount = dialed.filter { $0 == host }.count
        let response = responses[host] ?? .respondsPong
        lock.unlock()

        switch behavior {
        case .succeeds: break
        case .succeedsAfter(let delay): Thread.sleep(forTimeInterval: delay)
        case .fails(let error): throw error
        case .succeedsThenFailsWith(let error): if dialCount > 1 { throw error }
        }
        let connection = FakeLineConnection(response: response)
        lock.lock()
        connections[host] = connection
        lock.unlock()
        return connection
    }
}

/// A pinned-TLS line connection that answers from a script, so transport behavior is exact.
private final class FakeLineConnection: SpacesPinnedTLSLineConnection, @unchecked Sendable {
    private let lock = NSLock()
    private let response: ConnectRecorder.ResponseBehavior
    private var cancelled = false

    init(response: ConnectRecorder.ResponseBehavior) { self.response = response }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func sendLine(_ line: Data, timeout: TimeInterval) throws {}

    func readLine(timeout: TimeInterval) throws -> Data {
        switch response {
        case .respondsPong: return try SpacesDeviceAPICodec.encodeResponse(SpacesDeviceAPIResponse(ok: true, message: "pong"))
        case .closesBeforeResponding: throw SpacesPinnedTLSConnectionError.connectionClosed
        }
    }

    func startReceiveLoop(onLine: @escaping @Sendable (Data) -> Void, onClosed: @escaping @Sendable ((any Error)?) -> Void) {}

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}

private final class HostRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []

    func append(_ host: String) {
        lock.lock()
        recorded.append(host)
        lock.unlock()
    }

    func hosts() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }
}
