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
    private final class FakeStreamHandle: RemoteAgentOverviewStreamHandle {
        func stop() {}
    }

    /// Scriptable transport: records every connection's callbacks so tests can fire overview signals
    /// and disconnects, serves a settable listing, and can gate listing pulls to observe concurrency.
    private final class FakeTransport: @unchecked Sendable {
        private let lock = NSLock()
        private var connections: [(onSignal: @Sendable () -> Void, onDisconnect: @Sendable ((any Error)?) -> Void)] = []
        private var listing: [SpacesDeviceAgentSessionRow] = []
        private var listGate: DispatchSemaphore?
        private var listCallCount = 0
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
        timeout: TimeInterval = 10, pollInterval: TimeInterval = 0.02, file: StaticString = #filePath, line: UInt = #line, message: String = "",
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
    @MainActor private func makeWatchedService(
        transport: FakeTransport, recorder: DeliveryRecorder, baselineStatus: String
    ) throws -> (service: RemoteAgentWatchService, store: SQLiteStore) {
        let (store, path) = try makeStoreAndPath()
        try store.insertAgentRemoteSubscription(
            subscriberTerminalSessionID: "sub-1", deviceID: "device-1", agentSessionID: "child-1", createdAt: "t")
        transport.setListing([makeRow(status: baselineStatus)])
        let service = RemoteAgentWatchService(
            databasePath: path, transport: transport.transport, deliver: { sessionID, line in recorder.record(sessionID, line) },
            logError: { _ in })
        service.start()
        try waitUntil(message: "stream never connected") { service.debugStreamingDeviceIDs == ["device-1"] }
        try waitUntil(message: "baseline listing never applied") {
            service.debugSnapshot(deviceID: "device-1")?["child-1"]?.status == baselineStatus
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
}
