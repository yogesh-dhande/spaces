import Foundation
import XCTest
import spacesdevicecore

@testable import workspacecore

/// Behavior coverage for the remote agent watch's stream lifecycle: transitions that happen while the
/// overview stream is disconnected — or while the daemon itself is down, via the persisted baseline —
/// are delivered afterwards (including an exit, whose edge is then dropped), already-reported state
/// never replays across a reconnect, a retired baseline never replays into a fresh watch, and each
/// device runs at most one `listAgentSessions` pull at a time so a stale response can never overwrite
/// newer state.
final class RemoteAgentWatchServiceTests: XCTestCase {
    private final class FakeStreamHandle: RemoteAgentOverviewStreamHandle { func stop() {} }

    /// Scriptable transport: records every connection's callbacks so tests can fire overview signals
    /// and disconnects, serves a settable listing, and can gate listing pulls to observe concurrency.
    private final class FakeTransport: @unchecked Sendable {
        private let lock = NSLock()
        private var connections: [(onSignal: @Sendable () -> Void, onDisconnect: @Sendable ((any Error)?) -> Void)] = []
        private var listing: [SpacesDeviceAgentSessionRow] = []
        private var listGate: DispatchSemaphore?
        private var listCallCount = 0
        private var pendingListFailures = 0
        private var pendingUnpairedFailures = 0
        private var activeListCalls = 0
        private var maxConcurrentListCalls = 0

        var transport: RemoteAgentWatchTransport {
            RemoteAgentWatchTransport(
                connect: { _, onSignal, onDisconnect in
                    self.lock.lock()
                    self.connections.append((onSignal: onSignal, onDisconnect: onDisconnect))
                    self.lock.unlock()
                    return .connected(FakeStreamHandle())
                },
                listAgentSessions: { _ in
                    self.lock.lock()
                    self.listCallCount += 1
                    if self.pendingUnpairedFailures > 0 {
                        self.pendingUnpairedFailures -= 1
                        self.lock.unlock()
                        throw RemoteAgentWatchListingError.deviceUnpaired
                    }
                    if self.pendingListFailures > 0 {
                        self.pendingListFailures -= 1
                        self.lock.unlock()
                        throw NSError(domain: "FakeTransport", code: 1, userInfo: [NSLocalizedDescriptionKey: "scripted listing failure"])
                    }
                    self.activeListCalls += 1
                    self.maxConcurrentListCalls = max(self.maxConcurrentListCalls, self.activeListCalls)
                    let gate = self.listGate
                    self.lock.unlock()
                    gate?.wait()
                    self.lock.lock()
                    self.activeListCalls -= 1
                    let rows = self.listing
                    self.lock.unlock()
                    return rows
                })
        }

        var connectionCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return connections.count
        }

        var listCalls: Int {
            lock.lock()
            defer { lock.unlock() }
            return listCallCount
        }

        var maxConcurrentLists: Int {
            lock.lock()
            defer { lock.unlock() }
            return maxConcurrentListCalls
        }

        func setListing(_ rows: [SpacesDeviceAgentSessionRow]) {
            lock.lock()
            listing = rows
            lock.unlock()
        }

        func setListGate(_ gate: DispatchSemaphore?) {
            lock.lock()
            listGate = gate
            lock.unlock()
        }

        func failNextListings(_ count: Int) {
            lock.lock()
            pendingListFailures = count
            lock.unlock()
        }

        func failNextListingsWithUnpairedDevice(_ count: Int) {
            lock.lock()
            pendingUnpairedFailures = count
            lock.unlock()
        }

        func fireSignal(connection index: Int) {
            lock.lock()
            let connection = connections[index]
            lock.unlock()
            connection.onSignal()
        }

        func fireDisconnect(connection index: Int) {
            lock.lock()
            let connection = connections[index]
            lock.unlock()
            connection.onDisconnect(nil)
        }
    }

    private final class DeliveryRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [(sessionID: String, line: String)] = []

        func record(_ sessionID: String, _ line: String) {
            lock.lock()
            lines.append((sessionID: sessionID, line: line))
            lock.unlock()
        }

        var delivered: [(sessionID: String, line: String)] {
            lock.lock()
            defer { lock.unlock() }
            return lines
        }
    }

    /// Collects the service's injected `logError` lines so a test can assert on (and report) the
    /// errors the service swallowed, instead of discarding them with `{ _ in }`.
    private final class ServiceErrorLog: @unchecked Sendable {
        private let lock = NSLock()
        private var storedLines: [String] = []

        func append(_ line: String) {
            lock.lock()
            storedLines.append(line)
            lock.unlock()
        }

        func lines(containing tag: String) -> [String] {
            lock.lock()
            defer { lock.unlock() }
            return storedLines.filter { $0.contains(tag) }
        }
    }

    private var temporaryDirectory: URL?
    /// Path of the database backing the current test's store, for spinning up a second service
    /// instance on the same database (simulating a daemon restart).
    private var currentDatabasePath: String?

    override func tearDownWithError() throws {
        if let temporaryDirectory { try? FileManager.default.removeItem(at: temporaryDirectory) }
        temporaryDirectory = nil
        currentDatabasePath = nil
        try super.tearDownWithError()
    }

    private func makeStoreAndPath() throws -> (store: SQLiteStore, path: String) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        temporaryDirectory = dir
        let path = dir.appendingPathComponent("spaces-test.db").path
        currentDatabasePath = path
        return (try SQLiteStore(path: path), path)
    }

    private func makeRow(status: String, terminalSessionID: String = "child-1") -> SpacesDeviceAgentSessionRow {
        SpacesDeviceAgentSessionRow(
            id: "row-\(terminalSessionID)", terminalSessionID: terminalSessionID, agent: "claude", label: "Child", status: status, note: nil,
            projectID: "project-1", projectName: "Project", workspaceID: "workspace-1", workspaceName: "Workspace", workspaceDir: "/tmp/workspace-1",
            branch: "main", updatedAt: "t", lastSignalAt: nil)
    }

    @MainActor private func waitUntil(
        timeout: TimeInterval = 30, pollInterval: TimeInterval = 0.02, file: StaticString = #filePath, line: UInt = #line, message: String = "",
        _ condition: @escaping @MainActor () -> Bool
    ) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            RunLoop.main.run(until: Date().addingTimeInterval(pollInterval))
        }
        XCTFail("Timed out waiting for condition. \(message)", file: file, line: line)
        throw NSError(domain: "RemoteAgentWatchServiceTests", code: 1)
    }

    /// Store with one watch edge, service wired to the fake transport, connected with an applied
    /// baseline listing of `child-1` in `baselineStatus`.
    @MainActor private func makeWatchedService(transport: FakeTransport, recorder: DeliveryRecorder, baselineStatus: String) throws -> (
        service: RemoteAgentWatchService, store: SQLiteStore
    ) {
        let (store, path) = try makeStoreAndPath()
        try store.insertAgentRemoteSubscription(subscriberTerminalSessionID: "sub-1", deviceID: "device-1", agentSessionID: "child-1", createdAt: "t")
        transport.setListing([makeRow(status: baselineStatus)])
        let service = RemoteAgentWatchService(
            databasePath: path, transport: transport.transport, deliver: { sessionID, line in recorder.record(sessionID, line) }, logError: { _ in })
        service.start()
        try waitUntil(message: "stream never connected") { service.debugStreamingDeviceIDs == ["device-1"] }
        try waitUntil(message: "baseline listing never applied") { service.debugSnapshot(deviceID: "device-1")?["child-1"]?.status == baselineStatus }
        // The baseline mirror is persisted off the main actor, so the in-memory snapshot landing above
        // no longer implies the row is durable. Wait for the persisted mirror before a test simulates a
        // daemon restart by reading it back from a fresh service on the same database.
        try waitUntil(message: "baseline was never persisted") {
            (try? store.agentRemoteWatchBaselines())?["device-1"]?["child-1"]?.status == baselineStatus
        }
        return (service, store)
    }

    /// A watched child that goes blocked while the stream is down must be reported after the
    /// reconnect: the first post-reconnect listing diffs against the retained snapshot instead of
    /// silently re-seeding a fresh baseline.
    @MainActor func testTransitionDuringOutageIsDeliveredAfterReconnect() throws {
        let transport = FakeTransport()
        let recorder = DeliveryRecorder()
        let (service, _) = try makeWatchedService(transport: transport, recorder: recorder, baselineStatus: AgentWindowStatus.spinning.rawValue)
        defer { service.stop() }

        transport.fireDisconnect(connection: 0)
        try waitUntil(message: "disconnect never processed") { service.debugStreamingDeviceIDs.isEmpty }

        // The child blocked while the stream was down; the reconnect's first listing carries it.
        transport.setListing([makeRow(status: AgentWindowStatus.waiting.rawValue)])
        service.reconcile()
        try waitUntil(message: "stream never reconnected") { service.debugStreamingDeviceIDs == ["device-1"] }

        try waitUntil(message: "blocked transition from the outage window was never delivered") {
            recorder.delivered.contains { $0.sessionID == "sub-1" && $0.line.contains("is blocked") }
        }
    }

    /// A watched child that exits while the stream is down must still produce its exited line after
    /// the reconnect, and the completed watch edge must be dropped — otherwise the subscriber never
    /// hears the terminal fact and the edge leaks forever.
    @MainActor func testExitDuringOutageIsDeliveredAfterReconnectAndDropsEdge() throws {
        let transport = FakeTransport()
        let recorder = DeliveryRecorder()
        let (service, store) = try makeWatchedService(transport: transport, recorder: recorder, baselineStatus: AgentWindowStatus.spinning.rawValue)
        defer { service.stop() }

        transport.fireDisconnect(connection: 0)
        try waitUntil(message: "disconnect never processed") { service.debugStreamingDeviceIDs.isEmpty }

        // The child exited while the stream was down: the reconnect's first listing has no row for it.
        transport.setListing([])
        service.reconcile()
        try waitUntil(message: "stream never reconnected") { service.debugStreamingDeviceIDs == ["device-1"] }

        try waitUntil(message: "exit from the outage window was never delivered") {
            recorder.delivered.contains { $0.sessionID == "sub-1" && $0.line.contains("is exited") }
        }
        try waitUntil(message: "completed watch edge was never dropped") {
            ((try? store.agentRemoteSubscriptions(deviceID: "device-1")) ?? []).isEmpty
        }
    }

    /// State that was already reported before the disconnect must not replay after the reconnect:
    /// the retained snapshot diffs as unchanged.
    @MainActor func testReconnectDoesNotReplayAlreadyReportedState() throws {
        let transport = FakeTransport()
        let recorder = DeliveryRecorder()
        let (service, _) = try makeWatchedService(transport: transport, recorder: recorder, baselineStatus: AgentWindowStatus.spinning.rawValue)
        defer { service.stop() }

        // Reported while the stream was up.
        transport.setListing([makeRow(status: AgentWindowStatus.waiting.rawValue)])
        transport.fireSignal(connection: 0)
        try waitUntil(message: "blocked transition was never delivered") { recorder.delivered.count == 1 }

        transport.fireDisconnect(connection: 0)
        try waitUntil(message: "disconnect never processed") { service.debugStreamingDeviceIDs.isEmpty }
        let listCallsBeforeReconnect = transport.listCalls
        service.reconcile()
        try waitUntil(message: "stream never reconnected") { service.debugStreamingDeviceIDs == ["device-1"] }
        try waitUntil(message: "post-reconnect listing was never pulled") { transport.listCalls > listCallsBeforeReconnect }
        try waitUntil(message: "post-reconnect listing was never applied") {
            service.debugSnapshot(deviceID: "device-1")?["child-1"]?.status == AgentWindowStatus.waiting.rawValue
        }

        XCTAssertEqual(recorder.delivered.count, 1, "an unchanged still-waiting child must not re-notify after a reconnect")
    }

    /// The baseline must survive the daemon itself restarting, not just the stream dropping: a child
    /// that goes blocked while the daemon is down must be reported by the restarted daemon's watch,
    /// whose first listing diffs against the baseline persisted by the previous run.
    @MainActor func testTransitionDuringDaemonRestartIsDeliveredByFreshService() throws {
        let transport = FakeTransport()
        let recorder = DeliveryRecorder()
        let (service, store) = try makeWatchedService(transport: transport, recorder: recorder, baselineStatus: AgentWindowStatus.spinning.rawValue)
        service.stop()

        // The child blocked while no daemon was running; the restarted daemon's watch starts fresh
        // on the same database and its first listing carries the new state.
        let restartTransport = FakeTransport()
        restartTransport.setListing([makeRow(status: AgentWindowStatus.waiting.rawValue)])
        let restartRecorder = DeliveryRecorder()
        let restartedService = RemoteAgentWatchService(
            databasePath: try XCTUnwrap(currentDatabasePath), transport: restartTransport.transport,
            deliver: { sessionID, line in restartRecorder.record(sessionID, line) }, logError: { _ in })
        defer { restartedService.stop() }
        restartedService.start()
        try waitUntil(message: "restarted service never connected") { restartedService.debugStreamingDeviceIDs == ["device-1"] }

        try waitUntil(message: "blocked transition from the daemon-restart window was never delivered") {
            restartRecorder.delivered.contains { $0.sessionID == "sub-1" && $0.line.contains("is blocked") }
        }
    }

    /// A child that exits while the daemon is down must still produce its exited line after the
    /// restart (and the completed edge must drop) — otherwise the subscriber never hears the terminal
    /// fact and the edge leaks until manual cleanup.
    @MainActor func testExitDuringDaemonRestartIsDeliveredByFreshServiceAndDropsEdge() throws {
        let transport = FakeTransport()
        let recorder = DeliveryRecorder()
        let (service, store) = try makeWatchedService(transport: transport, recorder: recorder, baselineStatus: AgentWindowStatus.spinning.rawValue)
        service.stop()

        let restartTransport = FakeTransport()
        restartTransport.setListing([])
        let restartRecorder = DeliveryRecorder()
        let restartedService = RemoteAgentWatchService(
            databasePath: try XCTUnwrap(currentDatabasePath), transport: restartTransport.transport,
            deliver: { sessionID, line in restartRecorder.record(sessionID, line) }, logError: { _ in })
        defer { restartedService.stop() }
        restartedService.start()
        try waitUntil(message: "restarted service never connected") { restartedService.debugStreamingDeviceIDs == ["device-1"] }

        try waitUntil(message: "exit from the daemon-restart window was never delivered") {
            restartRecorder.delivered.contains { $0.sessionID == "sub-1" && $0.line.contains("is exited") }
        }
        try waitUntil(message: "completed watch edge was never dropped") {
            ((try? store.agentRemoteSubscriptions(deviceID: "device-1")) ?? []).isEmpty
        }
    }

    /// Removing a device's last watch edge retires its baseline for good: re-subscribing later starts
    /// a fresh watch that seeds silently instead of replaying transitions diffed against dead state.
    @MainActor func testUnsubscribingRetiresBaselineSoResubscribeSeedsFresh() throws {
        let transport = FakeTransport()
        let recorder = DeliveryRecorder()
        let (service, store) = try makeWatchedService(transport: transport, recorder: recorder, baselineStatus: AgentWindowStatus.spinning.rawValue)
        defer { service.stop() }

        try store.deleteAgentRemoteSubscription(subscriberTerminalSessionID: "sub-1", deviceID: "device-1", agentSessionID: "child-1")
        service.reconcile()
        try waitUntil(message: "unwatched device's stream never closed") { service.debugStreamingDeviceIDs.isEmpty }
        // Retiring the baseline deletes the persisted mirror off the main actor; wait for it to clear so
        // the fresh service below cannot load a stale baseline and replay a spurious exit.
        try waitUntil(message: "retired baseline was never cleared from the persisted mirror") {
            (try? store.agentRemoteWatchBaselines())?["device-1"] == nil
        }

        // Re-subscribe after the child exited: a fresh watch has nothing to diff against, so the
        // absent row must seed silently, not replay an exit from the retired baseline.
        try store.insertAgentRemoteSubscription(
            subscriberTerminalSessionID: "sub-1", deviceID: "device-1", agentSessionID: "child-1", createdAt: "t2")
        let restartTransport = FakeTransport()
        restartTransport.setListing([])
        let restartRecorder = DeliveryRecorder()
        let restartedService = RemoteAgentWatchService(
            databasePath: try XCTUnwrap(currentDatabasePath), transport: restartTransport.transport,
            deliver: { sessionID, line in restartRecorder.record(sessionID, line) }, logError: { _ in })
        defer { restartedService.stop() }
        restartedService.start()
        try waitUntil(message: "re-subscribed service never connected") { restartedService.debugStreamingDeviceIDs == ["device-1"] }
        let listCallsAfterConnect = restartTransport.listCalls
        try waitUntil(message: "first listing never pulled") { restartTransport.listCalls >= max(listCallsAfterConnect, 1) }

        // The edge must survive (nothing exited on a fresh watch) and nothing must be delivered.
        try waitUntil(message: "fresh watch edge disappeared") {
            ((try? store.agentRemoteSubscriptions(deviceID: "device-1")) ?? []).isEmpty == false
        }
        XCTAssertTrue(restartRecorder.delivered.isEmpty, "a fresh watch must seed silently, not replay the retired baseline")
    }

    /// Overview pushes can arrive faster than listing pulls complete. Pulls for one device must run
    /// one at a time (signals arriving mid-pull coalesce into a single follow-up), so a slow, stale
    /// response can never be applied after a fresher one.
    @MainActor func testListingPullsAreSerializedPerDevice() throws {
        let transport = FakeTransport()
        let recorder = DeliveryRecorder()
        let (service, _) = try makeWatchedService(transport: transport, recorder: recorder, baselineStatus: AgentWindowStatus.spinning.rawValue)
        defer { service.stop() }

        let baselineListCalls = transport.listCalls
        let gate = DispatchSemaphore(value: 0)
        transport.setListGate(gate)
        defer {
            transport.setListGate(nil)
            for _ in 0..<8 { gate.signal() }
        }
        transport.setListing([makeRow(status: AgentWindowStatus.waiting.rawValue)])
        transport.fireSignal(connection: 0)
        try waitUntil(message: "signal-driven listing pull never started") { transport.listCalls == baselineListCalls + 1 }
        transport.fireSignal(connection: 0)
        transport.fireSignal(connection: 0)

        // Give the extra signals ample time to (incorrectly) start concurrent pulls.
        let settleDeadline = Date().addingTimeInterval(0.5)
        while Date() < settleDeadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        XCTAssertEqual(transport.maxConcurrentLists, 1, "listing pulls for one device must never run concurrently")
        XCTAssertEqual(transport.listCalls, baselineListCalls + 1, "signals arriving mid-pull must coalesce, not start new pulls")

        // Release the gated pull; the coalesced follow-up runs afterwards and the blocked transition
        // is delivered exactly once.
        gate.signal()
        try waitUntil(message: "coalesced follow-up pull never ran") { transport.listCalls == baselineListCalls + 2 }
        gate.signal()
        try waitUntil(message: "blocked transition was never delivered") {
            recorder.delivered.contains { $0.sessionID == "sub-1" && $0.line.contains("is blocked") }
        }
        XCTAssertEqual(recorder.delivered.count, 1)
    }

    /// An overview signal can be the only cue for a transition, so a listing pull that fails
    /// transiently while the stream stays healthy must schedule its own retry — otherwise the
    /// transition sits undelivered until some unrelated signal or reconnect happens to re-pull.
    @MainActor func testFailedListingPullSchedulesRetry() throws {
        let transport = FakeTransport()
        let recorder = DeliveryRecorder()
        let (service, _) = try makeWatchedService(transport: transport, recorder: recorder, baselineStatus: AgentWindowStatus.spinning.rawValue)
        defer { service.stop() }
        service.reconnectDelay = .milliseconds(20)

        // The child blocked, the device signaled, but the signal-driven pull fails transiently.
        transport.setListing([makeRow(status: AgentWindowStatus.waiting.rawValue)])
        transport.failNextListings(1)
        transport.fireSignal(connection: 0)

        // No further signal arrives; the retry alone must recover the blocked transition.
        try waitUntil(message: "failed listing pull was never retried") {
            recorder.delivered.contains { $0.sessionID == "sub-1" && $0.line.contains("is blocked") }
        }
        XCTAssertEqual(recorder.delivered.count, 1)
    }

    /// A listing pull that discovers the device unpaired must be treated like a connect-time
    /// `.deviceUnpaired`: the connect path's own handling only runs on a fresh connect, so it never
    /// fires again for a device whose overview stream stayed open across the unpairing. The listing
    /// path must stop the stream, drop the edges and persisted baseline itself, and — unlike a
    /// transient listing failure — must not retry a device that can never resolve again.
    @MainActor func testUnpairedDeviceListingFailureDropsEdgesAndStopsRetrying() throws {
        let transport = FakeTransport()
        let recorder = DeliveryRecorder()
        let (service, store) = try makeWatchedService(transport: transport, recorder: recorder, baselineStatus: AgentWindowStatus.spinning.rawValue)
        defer { service.stop() }

        let listCallsBeforeSignal = transport.listCalls
        transport.failNextListingsWithUnpairedDevice(1)
        transport.fireSignal(connection: 0)

        try waitUntil(message: "stream never stopped after unpaired listing failure") { service.debugStreamingDeviceIDs.isEmpty }
        try waitUntil(message: "edges were never dropped after unpaired listing failure") {
            ((try? store.agentRemoteSubscriptions(deviceID: "device-1")) ?? []).isEmpty
        }
        try waitUntil(message: "in-memory baseline was never retired after unpaired listing failure") {
            service.debugSnapshot(deviceID: "device-1") == nil
        }
        try waitUntil(message: "persisted baseline was never retired after unpaired listing failure") {
            (try? store.agentRemoteWatchBaselines())?["device-1"] == nil
        }

        // Give a wrongly-scheduled retry ample time to (incorrectly) fire another listing pull.
        let settleDeadline = Date().addingTimeInterval(0.3)
        while Date() < settleDeadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        XCTAssertEqual(transport.listCalls, listCallsBeforeSignal + 1, "a device dropped for being unpaired must not get a follow-up listing pull")
    }

    /// Store with one watch edge and a service connected with its first `listAgentSessions` pull gated,
    /// so a test can seed a baseline (as the daemon's subscribe path does) before that first listing
    /// applies. Returns once the pull is blocked on the gate.
    @MainActor private func makeServiceWithGatedFirstListing(
        transport: FakeTransport, recorder: DeliveryRecorder, firstListing: [SpacesDeviceAgentSessionRow], gate: DispatchSemaphore
    ) throws -> (service: RemoteAgentWatchService, store: SQLiteStore) {
        let (store, path) = try makeStoreAndPath()
        try store.insertAgentRemoteSubscription(subscriberTerminalSessionID: "sub-1", deviceID: "device-1", agentSessionID: "child-1", createdAt: "t")
        transport.setListGate(gate)
        transport.setListing(firstListing)
        let service = RemoteAgentWatchService(
            databasePath: path, transport: transport.transport, deliver: { sessionID, line in recorder.record(sessionID, line) }, logError: { _ in })
        service.start()
        try waitUntil(message: "stream never connected") { service.debugStreamingDeviceIDs == ["device-1"] }
        try waitUntil(message: "first listing pull never started") { transport.listCalls == 1 }
        return (service, store)
    }

    /// The failing-first case: a child that changes state in the gap between subscribe validation and
    /// the watch's first listing. The subscribe seeds the validated row into the baseline, so the first
    /// listing — which already shows the *new* status — diffs against the seed and emits the transition.
    /// Without the seed the first listing would seed silently and the transition would be lost forever.
    @MainActor func testSeededBaselineEmitsTransitionOnDivergentFirstListing() throws {
        let transport = FakeTransport()
        let recorder = DeliveryRecorder()
        let gate = DispatchSemaphore(value: 0)
        // The first listing already shows the child blocked (it went blocked during the connect gap).
        let (service, _) = try makeServiceWithGatedFirstListing(
            transport: transport, recorder: recorder, firstListing: [makeRow(status: AgentWindowStatus.waiting.rawValue)], gate: gate)
        defer {
            transport.setListGate(nil)
            for _ in 0..<8 { gate.signal() }
            service.stop()
        }

        // The child was spinning when validation fetched it; seed that before the gated listing applies.
        service.seedBaseline(deviceID: "device-1", childTerminalSessionID: "child-1", row: makeRow(status: AgentWindowStatus.spinning.rawValue))
        XCTAssertEqual(service.debugSnapshot(deviceID: "device-1")?["child-1"]?.status, AgentWindowStatus.spinning.rawValue)

        gate.signal()
        try waitUntil(message: "blocked transition from the connect gap was never delivered") {
            recorder.delivered.contains { $0.sessionID == "sub-1" && $0.line.contains("is blocked") }
        }
    }

    /// A child that exits in the connect gap: the first listing omits it. Seeding the validated row
    /// makes it present-in-baseline and absent-from-listing, so the diff emits `exited` and drops the
    /// edge. Without the seed the absence is an unseen agent — no exit, and the edge leaks forever.
    @MainActor func testSeededBaselineEmitsExitedWhenFirstListingOmitsChildAndDropsEdge() throws {
        let transport = FakeTransport()
        let recorder = DeliveryRecorder()
        let gate = DispatchSemaphore(value: 0)
        // The child exited during the connect gap: the first listing has no row for it.
        let (service, store) = try makeServiceWithGatedFirstListing(transport: transport, recorder: recorder, firstListing: [], gate: gate)
        defer {
            transport.setListGate(nil)
            for _ in 0..<8 { gate.signal() }
            service.stop()
        }

        service.seedBaseline(deviceID: "device-1", childTerminalSessionID: "child-1", row: makeRow(status: AgentWindowStatus.spinning.rawValue))

        gate.signal()
        try waitUntil(message: "exit from the connect gap was never delivered") {
            recorder.delivered.contains { $0.sessionID == "sub-1" && $0.line.contains("is exited") }
        }
        try waitUntil(message: "completed watch edge was never dropped") {
            ((try? store.agentRemoteSubscriptions(deviceID: "device-1")) ?? []).isEmpty
        }
    }

    /// Seeding a child that already has a baseline entry — it is already watched by another subscriber,
    /// or its baseline survived a disconnect — must not overwrite it with the possibly-older validation
    /// row. A later listing must diff against the retained entry, not the seed: here the retained
    /// baseline is `spinning`, so a `waiting` listing still emits `blocked`; had the stale `waiting`
    /// seed clobbered it, the diff would be `waiting` → `waiting` and nothing would fire.
    @MainActor func testSeedDoesNotOverwriteExistingBaseline() throws {
        let transport = FakeTransport()
        let recorder = DeliveryRecorder()
        let (service, _) = try makeWatchedService(transport: transport, recorder: recorder, baselineStatus: AgentWindowStatus.spinning.rawValue)
        defer { service.stop() }

        // A second subscribe validation happens to fetch an older `waiting` row; the seed must be ignored.
        service.seedBaseline(deviceID: "device-1", childTerminalSessionID: "child-1", row: makeRow(status: AgentWindowStatus.waiting.rawValue))
        XCTAssertEqual(
            service.debugSnapshot(deviceID: "device-1")?["child-1"]?.status, AgentWindowStatus.spinning.rawValue,
            "an existing baseline entry must not be clobbered by a seed")

        // The retained `spinning` baseline is proven by a `waiting` listing still diffing to blocked.
        transport.setListing([makeRow(status: AgentWindowStatus.waiting.rawValue)])
        transport.fireSignal(connection: 0)
        try waitUntil(message: "blocked transition (proving the retained baseline) was never delivered") {
            recorder.delivered.contains { $0.sessionID == "sub-1" && $0.line.contains("is blocked") }
        }
        XCTAssertEqual(recorder.delivered.count, 1)
    }

    /// A `seedBaseline` for a newly subscribed child that lands while `applyRows` is suspended on its
    /// off-main watched-set read must not be dropped. `applyRows` reads the watched set before the seed
    /// (so it omits the new child) and then filters the next snapshot to that stale set; blindly writing
    /// it would drop the seeded child from the in-memory baseline, and the child's transition — carried in
    /// the very listing being applied — would then be lost as a silent re-seed. The fix re-checks the
    /// per-device snapshot generation after the suspension and, on a mismatch, aborts and coalesces a fresh
    /// listing that re-reads both the rows and the watched set against the updated snapshot, so the child
    /// survives and its `blocked` transition is delivered exactly once.
    @MainActor func testSeedLandingMidApplyRowsSurvivesAndDeliversTransition() throws {
        let transport = FakeTransport()
        let recorder = DeliveryRecorder()
        let (service, store) = try makeWatchedService(transport: transport, recorder: recorder, baselineStatus: AgentWindowStatus.spinning.rawValue)
        defer {
            service.didReadWatchedSetForTest = nil
            service.stop()
        }

        // The listing being applied already shows `child-2` blocked (it went blocked in the connect gap).
        // `child-1` stays spinning, so it never transitions and the only expected delivery is `child-2`'s.
        transport.setListing([
            makeRow(status: AgentWindowStatus.spinning.rawValue, terminalSessionID: "child-1"),
            makeRow(status: AgentWindowStatus.waiting.rawValue, terminalSessionID: "child-2"),
        ])

        // The moment `applyRows` resumes from its watched-set read (which therefore already omits `child-2`),
        // subscribe and seed `child-2` — reproducing a seed landing squarely in that suspension window. Fires
        // once, so the coalesced re-pull's own `applyRows` proceeds against the now-stable snapshot.
        final class Once { var fired = false }
        let once = Once()
        service.didReadWatchedSetForTest = { [weak service] deviceID in
            guard !once.fired, let service else { return }
            once.fired = true
            try? store.insertAgentRemoteSubscription(
                subscriberTerminalSessionID: "sub-2", deviceID: deviceID, agentSessionID: "child-2", createdAt: "t")
            service.seedBaseline(
                deviceID: deviceID, childTerminalSessionID: "child-2",
                row: self.makeRow(status: AgentWindowStatus.spinning.rawValue, terminalSessionID: "child-2"))
        }

        transport.fireSignal(connection: 0)

        try waitUntil(message: "seeded child dropped by the stale-watched-set replace; its blocked transition was lost") {
            recorder.delivered.contains { $0.sessionID == "sub-2" && $0.line.contains("is blocked") }
        }
        // The seeded child must survive in the in-memory baseline (the bug drops it entirely).
        try waitUntil(message: "seeded child never landed in the retained snapshot") {
            service.debugSnapshot(deviceID: "device-1")?["child-2"]?.status == AgentWindowStatus.waiting.rawValue
        }
        XCTAssertEqual(recorder.delivered.count, 1, "child-2's blocked transition must be delivered exactly once")
    }

    /// Two rapid seeds — {child-1} already durable, then {child-1, child-2}, then {child-1, child-2, child-3}
    /// — must leave the durable mirror at the latest union. Firing each seed's persist as an independent
    /// detached write gives no ordering, so a later, larger snapshot could commit before an earlier one and
    /// strand a child in the mirror; after a daemon restart that child's baseline would be missing and its
    /// next transition swallowed. Serializing the per-device baseline writes makes the mirror converge to the
    /// last in-memory snapshot regardless of task-completion order.
    @MainActor func testRapidSeedsConvergeDurableMirrorToLatestUnion() throws {
        let transport = FakeTransport()
        let recorder = DeliveryRecorder()
        let (service, store) = try makeWatchedService(transport: transport, recorder: recorder, baselineStatus: AgentWindowStatus.spinning.rawValue)
        defer { service.stop() }

        // Two seeds back-to-back on the main actor, each a superset of the last.
        service.seedBaseline(
            deviceID: "device-1", childTerminalSessionID: "child-2",
            row: makeRow(status: AgentWindowStatus.spinning.rawValue, terminalSessionID: "child-2"))
        service.seedBaseline(
            deviceID: "device-1", childTerminalSessionID: "child-3",
            row: makeRow(status: AgentWindowStatus.spinning.rawValue, terminalSessionID: "child-3"))

        func mirroredChildren() -> Set<String> { Set(((try? store.agentRemoteWatchBaselines())?["device-1"] ?? [:]).keys) }
        try waitUntil(message: "durable mirror never converged to the latest union of all three children") {
            mirroredChildren() == ["child-1", "child-2", "child-3"]
        }
        // Convergence must be to the *settled* state, not a transient the union briefly passes through before an
        // out-of-order write clobbers it back: assert the mirror stays at the union rather than regressing. An
        // earlier, smaller snapshot committing after the latest one (the bug) would drop a child here.
        let stabilityDeadline = Date().addingTimeInterval(0.3)
        while Date() < stabilityDeadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            XCTAssertEqual(
                mirroredChildren(), ["child-1", "child-2", "child-3"],
                "durable mirror regressed after converging — per-device baseline writes committed out of order")
        }
    }

    /// A2 regression: `applyRows` bumps the per-device generation on every apply, even one whose listing
    /// is byte-for-byte unchanged from the retained snapshot. If a seed's durable write is still queued
    /// behind an earlier, slower write on that same device's baseline chain when the unchanged listing
    /// lands, the spurious bump makes the seed's write look superseded before it ever runs: the seeded
    /// child stays correctly in the in-memory snapshot (nothing there was wrong), but its baseline is
    /// never persisted. Nothing else happens to rewrite the whole per-device mirror afterwards, so a
    /// daemon restart before that loses the seed's baseline entirely and its first real transition is
    /// swallowed as an initial observation instead of being delivered.
    @MainActor func testUnchangedListingDoesNotSkipAQueuedSeedWrite() throws {
        let transport = FakeTransport()
        let recorder = DeliveryRecorder()
        let (service, store) = try makeWatchedService(transport: transport, recorder: recorder, baselineStatus: AgentWindowStatus.spinning.rawValue)
        defer { service.stop() }
        let databasePath = try XCTUnwrap(currentDatabasePath)

        try store.insertAgentRemoteSubscription(subscriberTerminalSessionID: "sub-x", deviceID: "device-1", agentSessionID: "child-x", createdAt: "t")
        try store.insertAgentRemoteSubscription(subscriberTerminalSessionID: "sub-b", deviceID: "device-1", agentSessionID: "child-b", createdAt: "t")

        // Hold an external write lock on the database on a second connection, so the next baseline write
        // this test triggers blocks mid-flight trying to commit — the "slow prior write" already in
        // flight on device-1's chain that the finding describes.
        let lockAcquired = DispatchSemaphore(value: 0)
        let releaseLock = DispatchSemaphore(value: 0)
        let lockThreadFinished = DispatchSemaphore(value: 0)
        let lockThread = Thread {
            defer { lockThreadFinished.signal() }
            guard let lockingStore = try? SQLiteStore(path: databasePath) else { return }
            try? lockingStore.withTransaction {
                lockAcquired.signal()
                releaseLock.wait()
            }
        }
        lockThread.start()
        lockAcquired.wait()

        // Seed child-x: its durable write (P) is chained behind the setup baseline's already-completed
        // write, so it starts almost immediately once the run loop is pumped and then blocks trying to
        // commit against the held external lock.
        service.seedBaseline(
            deviceID: "device-1", childTerminalSessionID: "child-x",
            row: makeRow(status: AgentWindowStatus.spinning.rawValue, terminalSessionID: "child-x"))
        // Pump the run loop just long enough for P to actually start and block in its `Task.detached`
        // write (not merely be scheduled) before child-b is seeded. Without this, both seeds' generation
        // bumps happen back-to-back on this same synchronous call stack before either write's chain-turn
        // arrives, and child-b's write would already be stamped with the post-bump generation instead of
        // genuinely queuing behind a still-in-flight P.
        let priorWriteStartDeadline = Date().addingTimeInterval(0.1)
        while Date() < priorWriteStartDeadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        // Seed child-b: P is still blocked on the external lock, so child-b's write chains behind it and
        // suspends at `await previous?.value` instead of running its generation check yet.
        service.seedBaseline(
            deviceID: "device-1", childTerminalSessionID: "child-b",
            row: makeRow(status: AgentWindowStatus.spinning.rawValue, terminalSessionID: "child-b"))

        // An unrelated listing pull lands on the same device while both writes are still queued. Every
        // watched child (child-1, child-x, child-b) reports back exactly what is already in the in-memory
        // snapshot, so nothing transitions — yet applyRows still bumps the generation for this apply.
        transport.setListing([
            makeRow(status: AgentWindowStatus.spinning.rawValue, terminalSessionID: "child-1"),
            makeRow(status: AgentWindowStatus.spinning.rawValue, terminalSessionID: "child-x"),
            makeRow(status: AgentWindowStatus.spinning.rawValue, terminalSessionID: "child-b"),
        ])
        transport.fireSignal(connection: 0)
        // Give the unchanged listing's applyRows ample time to fully complete while P is still blocked on
        // the external lock.
        let settleDeadline = Date().addingTimeInterval(0.3)
        while Date() < settleDeadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        XCTAssertTrue(recorder.delivered.isEmpty, "an unchanged listing must not deliver any transition")

        // Release the external lock: P's write lands, unblocking child-b's chained write.
        releaseLock.signal()
        try waitUntil(message: "the prior seed's baseline write (child-x) never landed") {
            (try? store.agentRemoteWatchBaselines())?["device-1"]?["child-x"] != nil
        }
        // Give the now-unblocked chained child-b write ample time to run (or, pre-fix, to see itself as
        // superseded and skip).
        let chainSettleDeadline = Date().addingTimeInterval(0.3)
        while Date() < chainSettleDeadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        lockThreadFinished.wait()

        XCTAssertNotNil(service.debugSnapshot(deviceID: "device-1")?["child-b"], "the seeded child must remain in the in-memory snapshot")
        XCTAssertNotNil(
            (try? store.agentRemoteWatchBaselines())?["device-1"]?["child-b"],
            "an unchanged listing must not suppress a seed's still-queued durable baseline write")
    }

    /// Startup baseline load must persist its in-memory merge, not just apply it. The persisted mirror holds
    /// device-1 → {child-1}; a `seedBaseline(child-2)` lands (as the subscribe path fires it) while `start()`'s
    /// off-main baseline load is still in flight, so the load merges the persisted {child-1} into the seed's
    /// {child-2} for an in-memory {child-1, child-2}. If the merge is not persisted, the durable mirror is
    /// stranded — the seed's {child-2} write is superseded by the load's generation bump, so the mirror stays
    /// at {child-1} — and a later daemon restart loses child-2's baseline and swallows its first transition.
    /// The load's own later-chained, newer-generation write must carry the union to disk.
    @MainActor func testStartupBaselineLoadPersistsSeedMergedUnion() async throws {
        let transport = FakeTransport()
        let recorder = DeliveryRecorder()
        let (store, path) = try makeStoreAndPath()
        // Keep device-1 in the desired set so reconcile does not retire the loaded baseline.
        try store.insertAgentRemoteSubscription(subscriberTerminalSessionID: "sub-1", deviceID: "device-1", agentSessionID: "child-1", createdAt: "t")
        // The previous daemon run persisted device-1 → {child-1}.
        try store.replaceAgentRemoteWatchBaseline(
            deviceID: "device-1", baseline: ["child-1": makeRow(status: AgentWindowStatus.spinning.rawValue, terminalSessionID: "child-1")])

        // Fail the post-load reconcile's listing pulls so `applyRows` never runs and cannot rewrite the
        // mirror out from under this test's durable assertion: a failed pull leaves the baseline
        // untouched and schedules its retry beyond this test's lifetime. Deliberately NOT a semaphore
        // gate on the listing: that blocks the cooperative-pool thread running the transport closure,
        // and under machine-wide CPU saturation the pool does not grow past a blocked thread — the
        // startup load below then never gets scheduled and the merge wait deadlocks to its ceiling
        // (the #196 CI signature of this test).
        transport.failNextListings(Int.max)
        transport.setListing([])
        // Capture the service's error log instead of discarding it: the startup load swallows a
        // failed store read (logging it and continuing seed-only, #238), and when that happens the
        // logged error — not the downstream state mismatch — is the diagnosis. The injected listing
        // failures above also log, so the assertion below filters for the load's own op tag.
        let errorLog = ServiceErrorLog()
        let service = RemoteAgentWatchService(
            databasePath: path, transport: transport.transport, deliver: { sessionID, line in recorder.record(sessionID, line) },
            logError: { errorLog.append($0) })
        defer { service.stop() }
        service.start()
        // In the same main-actor turn — before the detached load can round-trip — seed child-2, reproducing the
        // subscribe path firing a seed while start()'s baseline load is still in flight.
        service.seedBaseline(
            deviceID: "device-1", childTerminalSessionID: "child-2",
            row: makeRow(status: AgentWindowStatus.spinning.rawValue, terminalSessionID: "child-2"))

        // Await the startup load (merge + its durable persist) to completion instead of polling under a
        // wall-clock ceiling: on a saturated machine the load's detached task can be starved well past
        // any reasonable poll timeout.
        await service.drainStartupLoadForTesting()

        // A failed (and swallowed) baseline load leaves seed-only state; surface the exact store
        // error here rather than letting the state assertions below report a bare set mismatch.
        XCTAssertEqual(
            errorLog.lines(containing: "op=load_baselines"), [],
            "startup baseline load failed instead of merging (#238)")
        // The load merges the persisted {child-1} into the seed's {child-2}.
        XCTAssertEqual(
            service.debugSnapshot(deviceID: "device-1").map { Set($0.keys) }, ["child-1", "child-2"],
            "startup load never merged the persisted baseline with the seed")
        // The merged union must reach the durable mirror, not just memory.
        func mirroredChildren() -> Set<String> { Set(((try? store.agentRemoteWatchBaselines())?["device-1"] ?? [:]).keys) }
        XCTAssertEqual(
            mirroredChildren(), ["child-1", "child-2"], "durable mirror never converged to the seed-merged union {child-1, child-2}")
        // And it must stay there — not regress once a later, stale-generation write on the chain runs.
        // `Task.sleep` (not `RunLoop.main.run`, which is unavailable from an async context) still yields
        // the main actor between checks so any such queued write gets its turn to run.
        let stabilityDeadline = Date().addingTimeInterval(0.3)
        while Date() < stabilityDeadline {
            try await Task.sleep(for: .milliseconds(20))
            XCTAssertEqual(mirroredChildren(), ["child-1", "child-2"], "durable mirror regressed after converging to the seed-merged union")
        }
    }

    /// A `seedBaseline` for a newly subscribed child that lands while `applyRows` is suspended on its off-main
    /// exited-edge deletion — after `applyRows` captured the generation its (pre-seed) snapshot reflects — must
    /// not have its durable baseline clobbered by that apply. The apply carries an exit for `child-1`, so it
    /// suspends dropping that edge; the seed adds `child-2` and enqueues its own later-chained write of
    /// {child-2}. The apply's baseline write must stay stamped with the pre-seed generation so it loses the
    /// supersession gate to the seed's write, leaving `child-2` durable. Stamping a fresh re-read (the bug)
    /// makes both writes carry the seed's generation, so the apply's pre-seed snapshot clobbers `child-2`.
    @MainActor func testSeedLandingMidExitedEdgeDropKeepsChildDurable() throws {
        let transport = FakeTransport()
        let recorder = DeliveryRecorder()
        let (service, store) = try makeWatchedService(transport: transport, recorder: recorder, baselineStatus: AgentWindowStatus.spinning.rawValue)
        defer {
            service.didDropExitedEdgesForTest = nil
            service.stop()
        }

        // The moment `applyRows` finishes dropping `child-1`'s exited edge and before it enqueues its baseline
        // write, subscribe and seed `child-2` — reproducing a seed landing squarely in that suspension window.
        // Fires once so nothing re-seeds on any coalesced re-pull.
        final class Once { var fired = false }
        let once = Once()
        service.didDropExitedEdgesForTest = { [weak service] deviceID in
            guard !once.fired, let service else { return }
            once.fired = true
            try? store.insertAgentRemoteSubscription(
                subscriberTerminalSessionID: "sub-2", deviceID: deviceID, agentSessionID: "child-2", createdAt: "t")
            service.seedBaseline(
                deviceID: deviceID, childTerminalSessionID: "child-2",
                row: self.makeRow(status: AgentWindowStatus.spinning.rawValue, terminalSessionID: "child-2"))
        }

        // The listing omits child-1: it exited, driving the applyRows exited-edge drop the seam hooks.
        transport.setListing([])
        transport.fireSignal(connection: 0)

        // The seeded child must reach the durable mirror. Pre-fix the apply's write (its pre-seed {} snapshot)
        // carries the seed's re-read generation and clobbers child-2 back out of the mirror.
        try waitUntil(message: "seeded child's durable baseline was clobbered by the exiting apply's write") {
            (try? store.agentRemoteWatchBaselines())?["device-1"]?["child-2"] != nil
        }
        // And it must stay durable — not regress once the apply's chained write runs.
        let stabilityDeadline = Date().addingTimeInterval(0.3)
        while Date() < stabilityDeadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            XCTAssertNotNil(
                (try? store.agentRemoteWatchBaselines())?["device-1"]?["child-2"],
                "seeded child's durable baseline regressed after the exiting apply's chained write ran")
        }
    }
}
