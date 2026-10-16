import Foundation
import spacesdevicecore
import spacesterminalcore

@testable import spacesdeviceapi

/// A clock and timer queue the test advances by hand: `advance(by:)` runs every timer that falls due, in
/// order, on the calling thread.
final class ManualPushScheduler: SpacesDevicePushScheduler, @unchecked Sendable {
    private final class Task: SpacesDevicePushScheduledWork, @unchecked Sendable {
        let due: Date
        let work: @Sendable () -> Void
        private(set) var isCancelled = false
        init(due: Date, work: @escaping @Sendable () -> Void) {
            self.due = due
            self.work = work
        }
        func cancel() { isCancelled = true }
    }

    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_000_000)
    private var tasks: [Task] = []

    var now: Date {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    func schedule(after seconds: TimeInterval, _ work: @escaping @Sendable () -> Void) -> any SpacesDevicePushScheduledWork {
        lock.lock()
        defer { lock.unlock() }
        let task = Task(due: current.addingTimeInterval(seconds), work: work)
        tasks.append(task)
        return task
    }

    var pendingCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return tasks.filter { !$0.isCancelled }.count
    }

    func advance(by seconds: TimeInterval) {
        lock.lock()
        let target = current.addingTimeInterval(seconds)
        lock.unlock()
        while true {
            lock.lock()
            tasks.removeAll { $0.isCancelled }
            guard let next = tasks.filter({ $0.due <= target }).min(by: { $0.due < $1.due }) else {
                current = target
                lock.unlock()
                return
            }
            tasks.removeAll { $0 === next }
            current = max(current, next.due)
            lock.unlock()
            next.work()
        }
    }
}

/// Records relay calls and answers each with `respond`, synchronously.
final class RecordingPushRelay: SpacesDevicePushRelayClient, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [SpacesDevicePushRelayRequest] = []
    private var responder: @Sendable (SpacesDevicePushRelayRequest) -> SpacesDevicePushRelayOutcome = { _ in .delivered }

    var requests: [SpacesDevicePushRelayRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func respond(_ responder: @escaping @Sendable (SpacesDevicePushRelayRequest) -> SpacesDevicePushRelayOutcome) {
        lock.lock()
        self.responder = responder
        lock.unlock()
    }

    /// The `(total, blockedAgents, notify)` of every report, in order.
    var reports: [(total: Int, blocked: Int, notify: Bool)] {
        requests.compactMap {
            if case .report(_, _, let counts, let notify) = $0 { return (counts.total, counts.blockedAgents, notify) }
            return nil
        }
    }

    /// While true, an unregister call is recorded but its completion waits for `completeHeldUnregisters()`.
    var holdsUnregisters: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return holding
        }
        set {
            lock.lock()
            holding = newValue
            lock.unlock()
        }
    }
    private var holding = false
    private var held: [@Sendable (SpacesDevicePushRelayOutcome) -> Void] = []

    func completeHeldUnregisters(with outcome: SpacesDevicePushRelayOutcome = .delivered) {
        lock.lock()
        let completions = held
        held = []
        lock.unlock()
        for completion in completions { completion(outcome) }
    }

    func send(_ request: SpacesDevicePushRelayRequest, completion: @escaping @Sendable (SpacesDevicePushRelayOutcome) -> Void) {
        lock.lock()
        recorded.append(request)
        if holding, case .unregister = request {
            held.append(completion)
            lock.unlock()
            return
        }
        let outcome = responder(request)
        lock.unlock()
        completion(outcome)
    }
}

/// Push registrations held in memory, standing in for the pairing store.
final class InMemoryPushRegistrations: SpacesDevicePushRegistrationStore, @unchecked Sendable {
    private let lock = NSLock()
    private var registrations: [String: SpacesDevicePushRegistration]

    init(_ registrations: [String: SpacesDevicePushRegistration] = [:]) { self.registrations = registrations }

    func pushRegistrations() throws -> [String: SpacesDevicePushRegistration] {
        lock.lock()
        defer { lock.unlock() }
        return registrations
    }

    func setPushRegistration(_ registration: SpacesDevicePushRegistration, forInstallationID installationID: String) throws {
        lock.lock()
        defer { lock.unlock() }
        registrations[installationID] = registration
    }

    func clearPushRegistration(forInstallationID installationID: String, matchingCapability: String?) throws -> SpacesDevicePushRegistration? {
        lock.lock()
        defer { lock.unlock() }
        guard let existing = registrations[installationID], matchingCapability == nil || matchingCapability == existing.capability else { return nil }
        registrations.removeValue(forKey: installationID)
        return existing
    }
}

/// Overview fixtures for push tests: agent rows in a visible workspace.
enum PushOverviewFixture {
    static func agentKey(_ id: String, state: SpacesDeviceCodingAgentActivityState, updatedAt: String = "2026-07-14T09:00:00Z") -> String {
        "agent:\(id):\(state.rawValue):\(updatedAt)"
    }

    static func overview(
        agents: [(id: String, state: SpacesDeviceCodingAgentActivityState)] = [], dismissed: [String] = [], workspaceHidden: Bool = false
    ) -> SpacesDeviceOverviewPayload {
        let rows = agents.map { agent in
            SpacesDeviceWorkspaceCodingAgentRow(
                id: agent.id, workspaceID: "w1", name: agent.id, command: "claude", agentID: agent.id, sessionID: "session-\(agent.id)",
                runState: .running, activityState: agent.state, updatedAt: "2026-07-14T09:00:00Z", brief: nil, briefUpdatedAt: nil, canStop: true)
        }
        let workspace = SpacesDeviceWorkspaceSummary(
            id: "w1", projectID: "p1", projectName: "Project", branch: "main", baseBranch: nil, dir: "/tmp/w1", isRunning: true,
            isHidden: workspaceHidden, isDefault: false, hasTrackedRuntimeIndicators: false, processRows: [], codingAgentRows: rows, terminalRows: [])
        return SpacesDeviceOverviewPayload(
            projects: [], workspaces: [workspace], sessions: [],
            daemonStatus: TerminalServiceDaemonStatus(version: "test", installedVersion: nil, certificateFingerprint: nil, activeSessionCount: 0),
            dismissedAlertKeys: dismissed)
    }
}

/// Holds one call at a chosen point until the test releases it.
final class LoadGate: @unchecked Sendable {
    private let held = DispatchSemaphore(value: 0)
    private let released = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var armed = false

    func arm() {
        lock.lock()
        armed = true
        lock.unlock()
    }

    /// Called from the code under test: blocks the first call after `arm()` until `release()`.
    func holdIfArmed() {
        lock.lock()
        let shouldHold = armed
        armed = false
        lock.unlock()
        guard shouldHold else { return }
        held.signal()
        released.wait()
    }

    func waitUntilHeld() { held.wait() }
    func release() { released.signal() }
}
