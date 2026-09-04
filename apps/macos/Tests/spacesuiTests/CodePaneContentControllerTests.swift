import Foundation
import Testing
import WebKit
import spacesclientcore
import spacesdevicecore
import spacesterminalcore

@testable import spacesui

/// A `CodePaneHosting` double with no device/workspace on file — every lookup fails the way a real
/// host's would for an unregistered workspace. Sufficient for the lifecycle tests below, which never
/// service an RPC.
@MainActor private final class EmptyCodePaneHostingDouble: CodePaneHosting {
    func codePaneDevice(workspaceID: String) -> SpacesPairedDeviceRecord? { nil }
    func codePaneWorkspaceInfo(workspaceID: String) -> (name: String, baseBranch: String?)? { nil }
    func codePaneCurrentAppearance() -> ThemeAppearance { .dark }
    func codePaneRunningAgents(workspaceID: String) -> [CodePaneRunningAgent] { [] }
    func codePaneInstallBackgroundCommandSession(workspaceID: String, deviceID: String, response: SpacesDeviceAPIResponse) {}
}

/// A `CodePaneHosting` double that resolves to a real (fake-populated) device, for the RPC-dispatch
/// tests below that need `performWorkspaceDiff` to reach the gateway seam instead of failing at the
/// device lookup.
@MainActor private final class DeviceCodePaneHostingDouble: CodePaneHosting {
    let device: SpacesPairedDeviceRecord
    private let agents: [CodePaneRunningAgent]
    private(set) var backgroundCommandSessionIDs: [String] = []
    private(set) var backgroundCommandOpenRequests: [AppKitController.DeviceTerminalOpenRequest] = []
    var onInstallBackgroundCommandSession: (() -> Void)?

    init(device: SpacesPairedDeviceRecord, agents: [CodePaneRunningAgent] = []) {
        self.device = device
        self.agents = agents
    }
    func codePaneDevice(workspaceID: String) -> SpacesPairedDeviceRecord? { device }
    func codePaneWorkspaceInfo(workspaceID: String) -> (name: String, baseBranch: String?)? { (name: "workspace", baseBranch: nil) }
    func codePaneCurrentAppearance() -> ThemeAppearance { .dark }
    func codePaneRunningAgents(workspaceID: String) -> [CodePaneRunningAgent] { agents }
    func codePaneInstallBackgroundCommandSession(workspaceID: String, deviceID: String, response: SpacesDeviceAPIResponse) {
        if let sessionID = response.sessionID { backgroundCommandSessionIDs.append(sessionID) }
        if let request = AppKitController.startedWorkspaceCommandPaneOpenRequest(deviceID: deviceID, response: response) {
            backgroundCommandOpenRequests.append(request)
        }
        onInstallBackgroundCommandSession?()
    }
}

/// A `CodePaneHosting` double whose `codePaneDevice` lookup fails (returns `nil`) for a configurable
/// number of calls after the first, then succeeds — reproducing the target scenario where the
/// device is unavailable, as it is by contract while its daemon restarts, for the first retry
/// attempt(s) after a disconnect. The very first call always succeeds (it stands in for the initial
/// `workspaceDiff` dispatch's own device lookup, which every test here does first to get a real
/// subscription established before triggering a disconnect).
@MainActor private final class ToggleableCodePaneHostingDouble: CodePaneHosting {
    let device: SpacesPairedDeviceRecord
    private var unavailableCallsRemaining: Int
    private(set) var codePaneDeviceCallCount = 0
    init(device: SpacesPairedDeviceRecord, unavailableForCalls: Int) {
        self.device = device
        self.unavailableCallsRemaining = unavailableForCalls
    }
    func codePaneDevice(workspaceID: String) -> SpacesPairedDeviceRecord? {
        codePaneDeviceCallCount += 1
        guard codePaneDeviceCallCount > 1 else { return device }
        guard unavailableCallsRemaining <= 0 else {
            unavailableCallsRemaining -= 1
            return nil
        }
        return device
    }
    func codePaneWorkspaceInfo(workspaceID: String) -> (name: String, baseBranch: String?)? { (name: "workspace", baseBranch: nil) }
    func codePaneCurrentAppearance() -> ThemeAppearance { .dark }
    func codePaneRunningAgents(workspaceID: String) -> [CodePaneRunningAgent] { [] }
    func codePaneInstallBackgroundCommandSession(workspaceID: String, deviceID: String, response: SpacesDeviceAPIResponse) {}
}

/// Records every script it's asked to evaluate, standing in for the live `WKWebView` so a test can
/// observe exactly what a reply/pushed event would have sent without a real page running. Internal
/// (not `private`) so `CodePanePlumbingTests` can reuse it to observe `requestMode`'s live-push path
/// at the `PanelCoordinator` level.
@MainActor final class RecordingCodePaneScriptEvaluator: CodePaneScriptEvaluator {
    private(set) var evaluatedScripts: [String] = []
    /// Canned answers for the value-returning variant, consumed FIFO by the next call that has none
    /// captured as a pending completion yet — set via `enqueueCollectResult` before whatever
    /// teardown/flush will consume it.
    private var queuedResults: [Any?] = []
    /// Completions from a value-returning call with no canned result available at call time — lets a
    /// test control exactly when a flush "answers" (e.g. to simulate a stale generation's flush
    /// landing late, after a newer page has already written).
    private var pendingCompletions: [(script: String, completion: @MainActor (Any?) -> Void)] = []

    func evaluateCodePaneScript(_ script: String) { evaluatedScripts.append(script) }

    func evaluateCodePaneScript(_ script: String, completion: @escaping @MainActor (Any?) -> Void) {
        evaluatedScripts.append(script)
        if !queuedResults.isEmpty { completion(queuedResults.removeFirst()) } else { pendingCompletions.append((script, completion)) }
    }

    /// Makes the next value-returning call that has no already-pending completion answer immediately
    /// with `result`.
    func enqueueCollectResult(_ result: Any?) { queuedResults.append(result) }

    /// Answers the oldest still-pending value-returning call (one that arrived with no canned result
    /// ready) with `result`.
    func completeOldestPending(with result: Any?) {
        precondition(!pendingCompletions.isEmpty, "no pending value-returning evaluateCodePaneScript call to complete")
        pendingCompletions.removeFirst().completion(result)
    }
}

/// Holds a collector callback without retaining the evaluator that issued it. This models WebKit's
/// asynchronous evaluator boundary: the controller, not the caller's test-local reference, must
/// keep the concrete evaluator alive until the collection finishes.
@MainActor private final class DeferredCodePaneScriptEvaluationCoordinator {
    private var completion: (@MainActor (Any?) -> Void)?

    func collect(_ completion: @escaping @MainActor (Any?) -> Void) {
        precondition(self.completion == nil, "only one deferred collection is expected")
        self.completion = completion
    }

    func complete(with result: Any?) {
        let completion = self.completion
        self.completion = nil
        completion?(result)
    }
}

@MainActor private final class DeferredCodePaneScriptEvaluator: CodePaneScriptEvaluator {
    private let coordinator: DeferredCodePaneScriptEvaluationCoordinator

    init(coordinator: DeferredCodePaneScriptEvaluationCoordinator) { self.coordinator = coordinator }

    func evaluateCodePaneScript(_: String) {}

    func evaluateCodePaneScript(_ script: String, completion: @escaping @MainActor (Any?) -> Void) { coordinator.collect(completion) }
}

/// An explicit clock keeps Start Agent readiness tests independent of scheduling speed: the test can
/// prove a hook-backed agent is not accepted until the shared stability window has elapsed.
private final class ControllableAgentStartClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ current: Date) { self.current = current }

    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    func advance(by interval: TimeInterval) {
        lock.lock()
        current = current.addingTimeInterval(interval)
        lock.unlock()
    }
}

private final class MemoryCodePaneWorkspaceStateStorage: CodePaneWorkspaceStateStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var stateByWorkspaceID: [String: String] = [:]
    let workspaceStateStorageKey = "memory-code-pane-state-\(UUID().uuidString)"

    func stateJSON(workspaceID: String) throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        return stateByWorkspaceID[workspaceID]
    }

    func setStateJSON(_ stateJSON: String, workspaceID: String) throws {
        lock.lock()
        defer { lock.unlock() }
        stateByWorkspaceID[workspaceID] = stateJSON
    }
}

/// Thread-safe writer probe for the off-main persistence tests. Its optional first-write gate keeps
/// the queue busy so subsequent snapshots have a deterministic coalescing window.
private final class RecordingWorkspaceStateWriter: @unchecked Sendable {
    private let lock = NSLock()
    private let firstWriteStarted = DispatchSemaphore(value: 0)
    private let releaseFirstWrite = DispatchSemaphore(value: 0)
    private let blockFirstWrite: Bool
    private var hasBlocked = false
    private var values: [String] = []

    init(blockFirstWrite: Bool = false) { self.blockFirstWrite = blockFirstWrite }

    func write(_ value: String, workspaceID: String) {
        lock.lock()
        values.append(value)
        let shouldBlock = blockFirstWrite && !hasBlocked
        if shouldBlock { hasBlocked = true }
        lock.unlock()
        guard shouldBlock else { return }
        firstWriteStarted.signal()
        releaseFirstWrite.wait()
    }

    func waitForFirstWrite() { firstWriteStarted.wait() }
    func release() { releaseFirstWrite.signal() }

    func recordedValues() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}

/// A durable-write stand-in that pauses after the shared deletion gate has admitted its first
/// write. The deletion regression uses it to prove the authoritative overview cannot leave a queued
/// recovery document behind after it removes the workspace.
private final class BlockingWorkspaceStateWriter: @unchecked Sendable {
    private let lock = NSLock()
    private let firstWriteStarted = DispatchSemaphore(value: 0)
    private let allowFirstWrite = DispatchSemaphore(value: 0)
    private var hasBlocked = false
    private var values: [String: String] = [:]

    func write(_ value: String, workspaceID: String) {
        lock.lock()
        let shouldBlock = !hasBlocked
        if shouldBlock { hasBlocked = true }
        lock.unlock()
        if shouldBlock {
            firstWriteStarted.signal()
            allowFirstWrite.wait()
        }
        lock.lock()
        values[workspaceID] = value
        lock.unlock()
    }

    func waitForFirstWrite(timeout: DispatchTimeInterval) -> Bool { firstWriteStarted.wait(timeout: .now() + timeout) == .success }

    func releaseFirstWrite() { allowFirstWrite.signal() }

    func delete(workspaceID: String) {
        lock.lock()
        values.removeValue(forKey: workspaceID)
        lock.unlock()
    }

    func value(workspaceID: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return values[workspaceID]
    }
}

/// `CodePaneDiffSignatureStreamHandle` fake: only tracks how many times `stop()` was called.
private final class FakeDiffSignatureStreamHandle: CodePaneDiffSignatureStreamHandle, @unchecked Sendable {
    private(set) var stopCount = 0
    func stop() { stopCount += 1 }
}

/// `CodePaneFileSignatureStreamHandle` fake: only tracks how many times `stop()` was called. Mirrors
/// `FakeDiffSignatureStreamHandle` exactly.
private final class FakeFileSignatureStreamHandle: CodePaneFileSignatureStreamHandle, @unchecked Sendable {
    private(set) var stopCount = 0
    func stop() { stopCount += 1 }
}

/// `CodePaneFileListSignatureStreamHandle` fake: only tracks how many times `stop()` was called. Mirrors
/// `FakeDiffSignatureStreamHandle` exactly.
private final class FakeFileListSignatureStreamHandle: CodePaneFileListSignatureStreamHandle, @unchecked Sendable {
    private(set) var stopCount = 0
    func stop() { stopCount += 1 }
}

/// Gates `workspaceDiff` on demand and records every `subscribeWorkspaceDiffSignature` call, so tests
/// can reproduce lifecycle races: an in-flight diff completing after the
/// pane hibernates, two overlapping diffs completing out of order, and a stream disconnect racing a
/// newer resubscribe. An `actor` because these calls are exercised from the controller's own
/// unstructured `Task`s, concurrently with the test's assertions.
private actor RecordingCodePaneDeviceGateway: CodePaneDeviceGateway {
    // Keyed by a stable arrival index (assigned once, never reused) rather than raw array position:
    // `completeDiffCall` removes entries as they complete, so a test that completes an earlier call
    // before a later one arrives (the disconnect tests do exactly this) would otherwise see
    // `pendingDiffCalls` shrink back toward zero instead of growing, and `at:` positions would drift
    // out from under still-pending calls once an earlier one is removed.
    private var pendingDiffCalls: [(arrivalIndex: Int, continuation: CheckedContinuation<SpacesDeviceWorkspaceDiffManifestChunkResult, any Error>)] =
        []
    private var diffCallArrivalCount = 0
    private var diffArrivalWaiters: [CheckedContinuation<Void, Never>] = []
    /// The `lastCommit` argument of each `workspaceDiff` call, in arrival order — parallels
    /// `pendingDiffCalls`'s arrival indexing so a test can confirm which scope a dispatched
    /// `workspaceDiff` actually resolved to.
    private var diffCallLastCommits: [Bool] = []
    private var subscribedRefNames: [String?] = []
    private var subscribedLastCommits: [Bool] = []
    private var subscribedDisconnectHandlers: [@Sendable (Error?) -> Void] = []
    private var subscribedFrameHandlers: [@Sendable (SpacesDeviceWorkspaceDiffSignatureFrame) -> Void] = []
    private var subscribeArrivalWaiters: [CheckedContinuation<Void, Never>] = []
    private var subscribeFailuresRemaining = 0
    private var subscribeAttempts = 0
    private var subscribeAttemptWaiters: [CheckedContinuation<Void, Never>] = []
    /// Held `subscribeWorkspaceDiffSignature` calls for stale-generation tests: keyed by the same
    /// kind of stable arrival index `pendingDiffCalls` uses, so a test can let later attempts resolve
    /// (or fail) while an earlier one stays outstanding, then choose when the earlier one finally
    /// settles — reproducing an A→B→A scope sequence where the FIRST A's attempt resolves LAST.
    private var pendingSubscribeCalls:
        [(
            arrivalIndex: Int, refName: String?, lastCommit: Bool, onFrame: @Sendable (SpacesDeviceWorkspaceDiffSignatureFrame) -> Void,
            onDisconnect: @Sendable ((any Error)?) -> Void, continuation: CheckedContinuation<any CodePaneDiffSignatureStreamHandle, any Error>
        )] = []
    private var subscribeCallArrivalCount = 0
    /// `subscribeWorkspaceDiffSignature` calls to hold open (not resolve immediately) rather than
    /// answering right away, counted down on each arrival — mirrors `subscribeFailuresRemaining`'s
    /// shape but for "hold" instead of "fail".
    private var holdNextSubscribeAttempts = 0

    /// Thrown by `subscribeWorkspaceDiffSignature` while `subscribeFailuresRemaining > 0`, so a test
    /// can force `resubscribeDiffSignature`'s failure arm deterministically
    /// instead of needing a real subscribe failure.
    private struct InjectedSubscribeFailure: Error {}
    private struct UnexpectedGatewayCall: Error {}

    private(set) var diffChunkCalls:
        [(workspaceID: String, refName: String?, lastCommit: Bool, manifestID: String, relativePath: String, byteOffset: Int, transferID: String?)] =
            []
    private(set) var diffChunkCancelCalls:
        [(workspaceID: String, refName: String?, lastCommit: Bool, manifestID: String, relativePath: String, byteOffset: Int, transferID: String)] =
            []
    private(set) var diffManifestReleaseCalls: [(workspaceID: String, refName: String?, lastCommit: Bool, manifestID: String)] = []
    private var diffChunkResult = SpacesDeviceWorkspaceDiffFileChunkResult(
        scopeSignature: "signature", file: .init(path: "Sources/App.swift", status: .modified))

    func workspaceDiffManifestChunk(
        workspaceID: String, refName: String?, lastCommit: Bool, manifestID: String?, fileIndex: Int, device: SpacesPairedDeviceRecord
    ) async throws -> SpacesDeviceWorkspaceDiffManifestChunkResult {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<SpacesDeviceWorkspaceDiffManifestChunkResult, any Error>) in
            let arrivalIndex = diffCallArrivalCount
            diffCallArrivalCount += 1
            diffCallLastCommits.append(lastCommit)
            pendingDiffCalls.append((arrivalIndex, continuation))
            drainDiffArrivalWaiters()
        }
    }

    func workspaceDiffFileChunk(
        workspaceID: String, refName: String?, lastCommit: Bool, manifestID: String, relativePath: String, byteOffset: Int, transferID: String?,
        device: SpacesPairedDeviceRecord
    ) async throws -> SpacesDeviceWorkspaceDiffFileChunkResult {
        diffChunkCalls.append((workspaceID, refName, lastCommit, manifestID, relativePath, byteOffset, transferID))
        return diffChunkResult
    }

    func cancelWorkspaceDiffFileChunk(
        workspaceID: String, refName: String?, lastCommit: Bool, manifestID: String, relativePath: String, byteOffset: Int, transferID: String,
        device: SpacesPairedDeviceRecord
    ) async throws { diffChunkCancelCalls.append((workspaceID, refName, lastCommit, manifestID, relativePath, byteOffset, transferID)) }

    func cancelWorkspaceDiffManifest(workspaceID: String, refName: String?, lastCommit: Bool, manifestID: String, device: SpacesPairedDeviceRecord)
        async throws
    { diffManifestReleaseCalls.append((workspaceID, refName, lastCommit, manifestID)) }

    func subscribeWorkspaceDiffSignature(
        workspaceID: String, refName: String?, lastCommit: Bool, device: SpacesPairedDeviceRecord,
        onFrame: @escaping @Sendable (SpacesDeviceWorkspaceDiffSignatureFrame) -> Void, onDisconnect: @escaping @Sendable ((any Error)?) -> Void
    ) async throws -> any CodePaneDiffSignatureStreamHandle {
        subscribeAttempts += 1
        drainSubscribeAttemptWaiters()
        if holdNextSubscribeAttempts > 0 {
            holdNextSubscribeAttempts -= 1
            let arrivalIndex = subscribeCallArrivalCount
            subscribeCallArrivalCount += 1
            return try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<any CodePaneDiffSignatureStreamHandle, any Error>) in
                pendingSubscribeCalls.append((arrivalIndex, refName, lastCommit, onFrame, onDisconnect, continuation))
            }
        }
        if subscribeFailuresRemaining > 0 {
            subscribeFailuresRemaining -= 1
            throw InjectedSubscribeFailure()
        }
        subscribedRefNames.append(refName)
        subscribedLastCommits.append(lastCommit)
        subscribedDisconnectHandlers.append(onDisconnect)
        subscribedFrameHandlers.append(onFrame)
        drainSubscribeArrivalWaiters()
        return FakeDiffSignatureStreamHandle()
    }

    /// Makes the next `count` `subscribeWorkspaceDiffSignature` calls throw, so a test can exercise
    /// `resubscribeDiffSignature`'s failure arm without a real failure.
    func failNextSubscribeAttempts(_ count: Int) { subscribeFailuresRemaining = count }

    /// Makes the next `count` `subscribeWorkspaceDiffSignature` calls suspend instead of resolving
    /// immediately, so a test can start a later attempt (or two) while an earlier one is still
    /// outstanding, then complete the held one(s) out of arrival order via `completeHeldSubscribeCall`
    /// or `failHeldSubscribeCall` below — mirrors `failNextSubscribeAttempts`'s counted-remaining shape.
    func holdNextSubscribeAttempts(_ count: Int) { holdNextSubscribeAttempts = count }

    /// Resolves the held `subscribeWorkspaceDiffSignature` call at `index` (0-based, arrival order among
    /// held calls only — stable even once another held call has already been completed and removed,
    /// same convention as `completeDiffCall`) with a fresh `FakeDiffSignatureStreamHandle`, returning it
    /// so a test can assert on its `stopCount` — this is how a test proves a stale attempt's client got
    /// `.stop()`'d rather than installed.
    @discardableResult func completeHeldSubscribeCall(at index: Int) -> FakeDiffSignatureStreamHandle {
        guard let position = pendingSubscribeCalls.firstIndex(where: { $0.arrivalIndex == index }) else {
            preconditionFailure("no held subscribeWorkspaceDiffSignature call at arrival index \(index)")
        }
        let held = pendingSubscribeCalls.remove(at: position)
        let handle = FakeDiffSignatureStreamHandle()
        // Only recorded as a live subscription once it actually resolves, matching the immediate-path's
        // own bookkeeping above — a test asserting `subscribedRefName(at:)`/`subscribeCallCount()` sees
        // this the same way it would see any other successful subscribe, regardless of whether the
        // controller's own completion guard then keeps or discards the returned handle: the low-level
        // subscribe genuinely succeeded, exactly as a real daemon RPC would have.
        subscribedRefNames.append(held.refName)
        subscribedLastCommits.append(held.lastCommit)
        subscribedDisconnectHandlers.append(held.onDisconnect)
        subscribedFrameHandlers.append(held.onFrame)
        drainSubscribeArrivalWaiters()
        held.continuation.resume(returning: handle)
        return handle
    }

    /// Fires a held subscription's transport-disconnect callback before its async subscribe call
    /// returns. Real stream clients can observe this ordering when the daemon drops the socket during
    /// the handshake; the controller must then discard the returned handle and keep its retry alive.
    func triggerHeldSubscribeDisconnect(at index: Int) {
        guard let held = pendingSubscribeCalls.first(where: { $0.arrivalIndex == index }) else {
            preconditionFailure("no held subscribeWorkspaceDiffSignature call at arrival index \(index)")
        }
        held.onDisconnect(nil)
    }

    /// Resolves the held `subscribeWorkspaceDiffSignature` call at `index` with a thrown failure instead
    /// of a success, so a test can drive the stale-attempt-fails variant.
    func failHeldSubscribeCall(at index: Int) {
        guard let position = pendingSubscribeCalls.firstIndex(where: { $0.arrivalIndex == index }) else {
            preconditionFailure("no held subscribeWorkspaceDiffSignature call at arrival index \(index)")
        }
        pendingSubscribeCalls.remove(at: position).continuation.resume(throwing: InjectedSubscribeFailure())
    }

    /// Every `subscribeWorkspaceDiffSignature` call, successful or injected-failure alike — unlike
    /// `subscribeCallCount()`, which counts only the ones that actually opened a subscription.
    func subscribeAttemptCount() -> Int { subscribeAttempts }

    /// Suspends until at least `count` subscribe attempts (successful or injected-failure) have arrived.
    func waitForSubscribeAttemptCount(_ count: Int) async {
        while subscribeAttempts < count {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in subscribeAttemptWaiters.append(continuation) }
        }
    }

    /// Suspends until at least `count` `workspaceDiff` calls have arrived in total (cumulative — a
    /// completed call still counts), regardless of how many are still outstanding.
    func waitForDiffCallCount(_ count: Int) async {
        while diffCallArrivalCount < count {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in diffArrivalWaiters.append(continuation) }
        }
    }

    /// Suspends until at least `count` `subscribeWorkspaceDiffSignature` calls have arrived.
    func waitForSubscribeCallCount(_ count: Int) async {
        while subscribedRefNames.count < count {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in subscribeArrivalWaiters.append(continuation) }
        }
    }

    /// Completes the `workspaceDiffManifestChunk` call at `index` (0-based, arrival order — stable even once an
    /// earlier or later call has already completed and been removed), leaving other pending calls
    /// untouched — this is what lets a test complete calls out of arrival order.
    func completeDiffCall(at index: Int, result: SpacesDeviceWorkspaceDiffManifestChunkResult) {
        guard let position = pendingDiffCalls.firstIndex(where: { $0.arrivalIndex == index }) else {
            preconditionFailure("no pending workspaceDiff call at arrival index \(index)")
        }
        pendingDiffCalls.remove(at: position).continuation.resume(returning: result)
    }

    /// Fails the `workspaceDiff` call at `index` instead of completing it with a result. Mirrors
    /// `failFileReadCall`.
    func failDiffCall(at index: Int, error: any Error) {
        guard let position = pendingDiffCalls.firstIndex(where: { $0.arrivalIndex == index }) else {
            preconditionFailure("no pending workspaceDiff call at arrival index \(index)")
        }
        pendingDiffCalls.remove(at: position).continuation.resume(throwing: error)
    }

    func subscribedRefName(at index: Int) -> String? { subscribedRefNames[index] }

    func subscribedLastCommit(at index: Int) -> Bool { subscribedLastCommits[index] }

    func diffCallLastCommit(at index: Int) -> Bool { diffCallLastCommits[index] }

    func subscribeCallCount() -> Int { subscribedRefNames.count }

    /// Every `workspaceDiff` call that has arrived so far, successful or still pending — a direct
    /// (non-waiting) read, mirroring `subscribeCallCount()`'s shape, for a "this must never happen"
    /// test that settles a fixed duration and then checks the count stayed at zero.
    func diffCallCount() -> Int { diffCallArrivalCount }

    func triggerDisconnect(at index: Int) { subscribedDisconnectHandlers[index](nil) }

    /// Delivers a `spaces:diffSignature`-worthy frame on the subscription opened at `index` (0-based,
    /// subscribe-call arrival order), standing in for the daemon's `DeviceOverviewStreamServer`
    /// pushing a signature over the live stream (dedupe tests).
    func triggerFrame(at index: Int, scopeSignature: String) {
        subscribedFrameHandlers[index](SpacesDeviceWorkspaceDiffSignatureFrame(workspaceID: "workspace-1", scopeSignature: scopeSignature))
    }

    private func drainDiffArrivalWaiters() {
        let waiters = diffArrivalWaiters
        diffArrivalWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    private func drainSubscribeArrivalWaiters() {
        let waiters = subscribeArrivalWaiters
        subscribeArrivalWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    private func drainSubscribeAttemptWaiters() {
        let waiters = subscribeAttemptWaiters
        subscribeAttemptWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    // MARK: - File read / file-signature subscription (mirrors the workspaceDiff/diff-signature seam above)

    private var pendingFileReadCalls: [(arrivalIndex: Int, continuation: CheckedContinuation<SpacesDeviceWorkspaceFileReadResult, any Error>)] = []
    private var fileReadCallArrivalCount = 0
    private var fileReadArrivalWaiters: [CheckedContinuation<Void, Never>] = []
    private var subscribedFilePaths: [String] = []
    private var subscribedFileDisconnectHandlers: [@Sendable (Error?) -> Void] = []
    private var subscribedFileFrameHandlers: [@Sendable (SpacesDeviceWorkspaceFileSignatureFrame) -> Void] = []
    private var subscribeFileArrivalWaiters: [CheckedContinuation<Void, Never>] = []
    private var subscribeFileFailuresRemaining = 0
    private(set) var revisionFileReadCalls: [(workspaceID: String, revision: String, relativePath: String, oldPath: String?)] = []
    private var revisionFileReadResult = SpacesDeviceWorkspaceRevisionFileReadResult(
        worktreeFile: .init(
            base64Data: Data("revision text".utf8).base64EncodedString(), sha256: "revision-sha", size: 13, isBinaryGuess: false),
        isWorktreeEquivalentToRevision: true, comparisonOldBase64Data: Data("revision text".utf8).base64EncodedString())

    private struct InjectedFileSubscribeFailure: Error {}

    func workspaceFileRead(
        workspaceID: String, relativePath: String, comparisonBaseRevision: String?, oldPath: String?, requiresDirectPath _: Bool,
        device: SpacesPairedDeviceRecord
    ) async throws
        -> SpacesDeviceWorkspaceFileReadResult
    {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<SpacesDeviceWorkspaceFileReadResult, any Error>) in
            let arrivalIndex = fileReadCallArrivalCount
            fileReadCallArrivalCount += 1
            pendingFileReadCalls.append((arrivalIndex, continuation))
            drainFileReadArrivalWaiters()
        }
    }

    func workspaceRevisionFileRead(workspaceID: String, revision: String, relativePath: String, oldPath: String?, device: SpacesPairedDeviceRecord) async throws
        -> SpacesDeviceWorkspaceRevisionFileReadResult
    {
        revisionFileReadCalls.append((workspaceID, revision, relativePath, oldPath))
        return revisionFileReadResult
    }

    // MARK: - File list
    //
    // Mirrors the diff/file-read seams above: most tests use a simple canned result, but one
    // regression needs to hold a `workspaceFileList` completion across deactivate/reactivate so it
    // can prove the late completion never re-enables monitoring for a newer page life.

    private(set) var fileListCalls: [String] = []
    private var fileListResult: Result<SpacesDeviceWorkspaceFileListResult, any Error> = .success(
        SpacesDeviceWorkspaceFileListResult(paths: [], truncated: false))
    private var holdNextFileListCallCount = 0
    private var pendingFileListCalls: [(arrivalIndex: Int, continuation: CheckedContinuation<SpacesDeviceWorkspaceFileListResult, any Error>)] = []
    private var fileListCallArrivalCount = 0
    private var fileListArrivalWaiters: [CheckedContinuation<Void, Never>] = []
    private var fileListSignatureSubscribeCount = 0
    private var fileListSignatureSubscribeAttempts = 0
    private var subscribedFileListDisconnectHandlers: [@Sendable (Error?) -> Void] = []
    private var subscribedFileListFrameHandlers: [@Sendable (SpacesDeviceWorkspaceFileListSignatureFrame) -> Void] = []
    private var subscribeFileListArrivalWaiters: [CheckedContinuation<Void, Never>] = []
    private var subscribeFileListAttemptWaiters: [CheckedContinuation<Void, Never>] = []
    private var subscribeFileListFailuresRemaining = 0
    private var holdNextFileListSignatureSubscribeAttempts = 0
    private var pendingFileListSignatureSubscribeCalls:
        [(
            arrivalIndex: Int, onDisconnect: @Sendable ((any Error)?) -> Void,
            onFrame: @Sendable (SpacesDeviceWorkspaceFileListSignatureFrame) -> Void,
            continuation: CheckedContinuation<any CodePaneFileListSignatureStreamHandle, any Error>
        )] = []
    private var fileListSignatureSubscribeCallArrivalCount = 0

    func setFileListResult(_ result: Result<SpacesDeviceWorkspaceFileListResult, any Error>) { fileListResult = result }
    func holdNextFileListCalls(_ count: Int) { holdNextFileListCallCount = count }

    func workspaceFileList(workspaceID: String, device: SpacesPairedDeviceRecord) async throws -> SpacesDeviceWorkspaceFileListResult {
        fileListCalls.append(workspaceID)
        let arrivalIndex = fileListCallArrivalCount
        fileListCallArrivalCount += 1
        drainFileListArrivalWaiters()
        if holdNextFileListCallCount > 0 {
            holdNextFileListCallCount -= 1
            return try await withCheckedThrowingContinuation { continuation in pendingFileListCalls.append((arrivalIndex, continuation)) }
        }
        return try fileListResult.get()
    }

    func waitForFileListCallCount(_ count: Int) async {
        while fileListCallArrivalCount < count {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in fileListArrivalWaiters.append(continuation) }
        }
    }

    func completeFileListCall(at index: Int, result: SpacesDeviceWorkspaceFileListResult) {
        guard let position = pendingFileListCalls.firstIndex(where: { $0.arrivalIndex == index }) else {
            preconditionFailure("no pending workspaceFileList call at arrival index \(index)")
        }
        pendingFileListCalls.remove(at: position).continuation.resume(returning: result)
    }

    func subscribeWorkspaceFileListSignature(
        workspaceID: String, device: SpacesPairedDeviceRecord, onFrame: @escaping @Sendable (SpacesDeviceWorkspaceFileListSignatureFrame) -> Void,
        onDisconnect: @escaping @Sendable ((any Error)?) -> Void
    ) async throws -> any CodePaneFileListSignatureStreamHandle {
        fileListSignatureSubscribeAttempts += 1
        drainSubscribeFileListAttemptWaiters()
        if holdNextFileListSignatureSubscribeAttempts > 0 {
            holdNextFileListSignatureSubscribeAttempts -= 1
            let arrivalIndex = fileListSignatureSubscribeCallArrivalCount
            fileListSignatureSubscribeCallArrivalCount += 1
            return try await withCheckedThrowingContinuation { continuation in
                pendingFileListSignatureSubscribeCalls.append((arrivalIndex, onDisconnect, onFrame, continuation))
            }
        }
        if subscribeFileListFailuresRemaining > 0 {
            subscribeFileListFailuresRemaining -= 1
            throw InjectedFileSubscribeFailure()
        }
        fileListSignatureSubscribeCount += 1
        subscribedFileListDisconnectHandlers.append(onDisconnect)
        subscribedFileListFrameHandlers.append(onFrame)
        drainSubscribeFileListArrivalWaiters()
        return FakeFileListSignatureStreamHandle()
    }

    func failNextFileListSignatureSubscribeAttempts(_ count: Int) { subscribeFileListFailuresRemaining = count }
    func holdNextFileListSignatureSubscribeAttempts(_ count: Int) { holdNextFileListSignatureSubscribeAttempts = count }

    func waitForFileListSignatureSubscribeCount(_ count: Int) async {
        while fileListSignatureSubscribeCount < count {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in subscribeFileListArrivalWaiters.append(continuation) }
        }
    }

    func waitForFileListSignatureSubscribeAttemptCount(_ count: Int) async {
        while fileListSignatureSubscribeAttempts < count {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in subscribeFileListAttemptWaiters.append(continuation) }
        }
    }

    func subscribedFileListSignatureCallCount() -> Int { fileListSignatureSubscribeCount }
    func fileListSignatureSubscribeAttemptCount() -> Int { fileListSignatureSubscribeAttempts }

    @discardableResult func completeHeldFileListSignatureSubscribeCall(at index: Int) -> FakeFileListSignatureStreamHandle {
        guard let position = pendingFileListSignatureSubscribeCalls.firstIndex(where: { $0.arrivalIndex == index }) else {
            preconditionFailure("no held subscribeWorkspaceFileListSignature call at arrival index \(index)")
        }
        let held = pendingFileListSignatureSubscribeCalls.remove(at: position)
        let handle = FakeFileListSignatureStreamHandle()
        fileListSignatureSubscribeCount += 1
        subscribedFileListDisconnectHandlers.append(held.onDisconnect)
        subscribedFileListFrameHandlers.append(held.onFrame)
        drainSubscribeFileListArrivalWaiters()
        held.continuation.resume(returning: handle)
        return handle
    }

    func triggerFileListSignatureDisconnect(at index: Int) { subscribedFileListDisconnectHandlers[index](nil) }

    func triggerPendingFileListSignatureDisconnect(at index: Int) { pendingFileListSignatureSubscribeCalls[index].onDisconnect(nil) }

    func triggerFileListSignatureFrame(at index: Int, signature: String) {
        subscribedFileListFrameHandlers[index](SpacesDeviceWorkspaceFileListSignatureFrame(workspaceID: "workspace-1", fileListSignature: signature))
    }

    private func drainFileListArrivalWaiters() {
        let waiters = fileListArrivalWaiters
        fileListArrivalWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    // MARK: - Ref list
    //
    // Mirrors `workspaceFileList`'s stub exactly: nothing in `CodePaneContentController` races
    // `workspaceRefList` against hibernation or a resubscribe, so a canned `Result` answered
    // synchronously is enough to dispatch-test RPC -> gateway-args wiring and the reply shape.

    private(set) var refListCalls: [String] = []
    private var refListResult: Result<SpacesDeviceWorkspaceRefListResult, any Error> = .success(
        SpacesDeviceWorkspaceRefListResult(branches: [], branchesTruncated: false, commits: [], commitsTruncated: false))

    func setRefListResult(_ result: Result<SpacesDeviceWorkspaceRefListResult, any Error>) { refListResult = result }

    func workspaceRefList(workspaceID: String, device: SpacesPairedDeviceRecord) async throws -> SpacesDeviceWorkspaceRefListResult {
        refListCalls.append(workspaceID)
        return try refListResult.get()
    }

    func subscribeWorkspaceFileSignature(
        workspaceID: String, relativePath: String, device: SpacesPairedDeviceRecord,
        onFrame: @escaping @Sendable (SpacesDeviceWorkspaceFileSignatureFrame) -> Void, onDisconnect: @escaping @Sendable ((any Error)?) -> Void
    ) async throws -> any CodePaneFileSignatureStreamHandle {
        if subscribeFileFailuresRemaining > 0 {
            subscribeFileFailuresRemaining -= 1
            throw InjectedFileSubscribeFailure()
        }
        subscribedFilePaths.append(relativePath)
        subscribedFileDisconnectHandlers.append(onDisconnect)
        subscribedFileFrameHandlers.append(onFrame)
        drainSubscribeFileArrivalWaiters()
        return FakeFileSignatureStreamHandle()
    }

    /// Makes the next `count` `subscribeWorkspaceFileSignature` calls throw, so a test can exercise
    /// `scheduleFileSignatureReconnect`'s failure arm without a real failure. Mirrors
    /// `failNextSubscribeAttempts`.
    func failNextFileSubscribeAttempts(_ count: Int) { subscribeFileFailuresRemaining = count }

    /// Completes the `workspaceFileRead` call at `index` (0-based, arrival order — stable even once an
    /// earlier or later call has already completed and been removed) with a success result, leaving
    /// other pending calls untouched — mirrors `completeDiffCall`.
    func completeFileReadCall(at index: Int, result: SpacesDeviceWorkspaceFileReadResult) {
        guard let position = pendingFileReadCalls.firstIndex(where: { $0.arrivalIndex == index }) else {
            preconditionFailure("no pending workspaceFileRead call at arrival index \(index)")
        }
        pendingFileReadCalls.remove(at: position).continuation.resume(returning: result)
    }

    /// Fails the `workspaceFileRead` call at `index` instead of completing it with a result.
    func failFileReadCall(at index: Int, error: any Error) {
        guard let position = pendingFileReadCalls.firstIndex(where: { $0.arrivalIndex == index }) else {
            preconditionFailure("no pending workspaceFileRead call at arrival index \(index)")
        }
        pendingFileReadCalls.remove(at: position).continuation.resume(throwing: error)
    }

    /// Suspends until at least `count` `workspaceFileRead` calls have arrived in total (cumulative — a
    /// completed call still counts), regardless of how many are still outstanding.
    func waitForFileReadCallCount(_ count: Int) async {
        while fileReadCallArrivalCount < count {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in fileReadArrivalWaiters.append(continuation) }
        }
    }

    /// Suspends until at least `count` `subscribeWorkspaceFileSignature` calls have succeeded.
    func waitForFileSubscribeCallCount(_ count: Int) async {
        while subscribedFilePaths.count < count {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in subscribeFileArrivalWaiters.append(continuation) }
        }
    }

    func subscribedFilePath(at index: Int) -> String { subscribedFilePaths[index] }

    func fileSubscribeCallCount() -> Int { subscribedFilePaths.count }

    func triggerFileDisconnect(at index: Int) { subscribedFileDisconnectHandlers[index](nil) }

    /// Delivers a `spaces:fileSignature`-worthy frame on the subscription opened at `index` (0-based,
    /// subscribe-call arrival order), standing in for the daemon's `DeviceOverviewStreamServer` pushing
    /// a signature over the live stream. Mirrors `triggerFrame`.
    func triggerFileFrame(at index: Int, path: String, sha256: String?, missing: Bool) {
        subscribedFileFrameHandlers[index](
            SpacesDeviceWorkspaceFileSignatureFrame(workspaceID: "workspace-1", path: path, sha256: sha256, missing: missing))
    }

    private func drainFileReadArrivalWaiters() {
        let waiters = fileReadArrivalWaiters
        fileReadArrivalWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    private func drainSubscribeFileArrivalWaiters() {
        let waiters = subscribeFileArrivalWaiters
        subscribeFileArrivalWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    private func drainSubscribeFileListArrivalWaiters() {
        let waiters = subscribeFileListArrivalWaiters
        subscribeFileListArrivalWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    private func drainSubscribeFileListAttemptWaiters() {
        let waiters = subscribeFileListAttemptWaiters
        subscribeFileListAttemptWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    // MARK: - File write

    private(set) var fileWriteCalls: [(workspaceID: String, relativePath: String, base64Data: String, expectedSHA256: String?)] = []
    private var fileWriteResult: Result<SpacesDeviceWorkspaceFileWriteResult, any Error>?
    /// `workspaceFileWrite` calls to hold open rather than answering right away, counted down
    /// on each arrival — mirrors `holdNextUpsertAttempts`'s shape exactly.
    private var holdNextFileWriteAttempts = 0
    private var pendingFileWriteCalls: [(arrivalIndex: Int, continuation: CheckedContinuation<SpacesDeviceWorkspaceFileWriteResult, any Error>)] = []
    private var fileWriteCallArrivalCount = 0
    private var fileWriteArrivalWaiters: [CheckedContinuation<Void, Never>] = []

    func setFileWriteResult(_ result: Result<SpacesDeviceWorkspaceFileWriteResult, any Error>) { fileWriteResult = result }

    func workspaceFileWrite(
        workspaceID: String, relativePath: String, base64Data: String, expectedSHA256: String?, requiresDirectPath _: Bool,
        device: SpacesPairedDeviceRecord
    )
        async throws -> SpacesDeviceWorkspaceFileWriteResult
    {
        fileWriteCalls.append((workspaceID, relativePath, base64Data, expectedSHA256))
        let writeWaiters = fileWriteArrivalWaiters
        fileWriteArrivalWaiters.removeAll()
        for waiter in writeWaiters { waiter.resume() }
        if holdNextFileWriteAttempts > 0 {
            holdNextFileWriteAttempts -= 1
            let arrivalIndex = fileWriteCallArrivalCount
            fileWriteCallArrivalCount += 1
            return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<SpacesDeviceWorkspaceFileWriteResult, any Error>) in
                pendingFileWriteCalls.append((arrivalIndex, continuation))
            }
        }
        guard let fileWriteResult else { return SpacesDeviceWorkspaceFileWriteResult(didWrite: true, sha256: "sha-default") }
        return try fileWriteResult.get()
    }

    /// Makes the next `count` `workspaceFileWrite` calls suspend instead of resolving
    /// immediately, so a test can observe the RPC still in flight (e.g. across a teardown) before
    /// completing it via `completeHeldFileWriteCall`.
    func holdNextFileWriteAttempts(_ count: Int) { holdNextFileWriteAttempts = count }

    func waitForFileWriteCallCount(_ count: Int) async {
        while fileWriteCallArrivalCount < count {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in fileWriteArrivalWaiters.append(continuation) }
        }
    }

    /// Resolves the held `workspaceFileWrite` call at `index` (0-based, arrival order among held calls
    /// only) with `result`.
    func completeHeldFileWriteCall(at index: Int, result: SpacesDeviceWorkspaceFileWriteResult) {
        guard let position = pendingFileWriteCalls.firstIndex(where: { $0.arrivalIndex == index }) else {
            preconditionFailure("no held workspaceFileWrite call at arrival index \(index)")
        }
        pendingFileWriteCalls.remove(at: position).continuation.resume(returning: result)
    }

    /// Fails the held `workspaceFileWrite` call at `index`, mirroring `completeHeldFileWriteCall`.
    func failHeldFileWriteCall(at index: Int, error: any Error) {
        guard let position = pendingFileWriteCalls.firstIndex(where: { $0.arrivalIndex == index }) else {
            preconditionFailure("no held workspaceFileWrite call at arrival index \(index)")
        }
        pendingFileWriteCalls.remove(at: position).continuation.resume(throwing: error)
    }

    // MARK: - Review comments
    //
    // Simple record-and-answer stubs (no arrival ordering/waiters needed): unlike `workspaceDiff` and
    // `subscribeWorkspaceDiffSignature`, nothing in `CodePaneContentController` races these calls against
    // hibernation or a resubscribe, so a canned `Result` answered synchronously is enough to dispatch-test
    // RPC → gateway-args wiring.

    private(set) var reviewCommentListCalls: [String] = []
    private var reviewCommentListResult: Result<[SpacesDeviceReviewComment], any Error> = .success([])

    private(set) var reviewCommentUpsertCalls:
        [(workspaceID: String, id: String?, filePath: String, side: SpacesDeviceReviewCommentSide, lineNumber: Int, lineText: String, body: String)] =
            []
    private var reviewCommentUpsertResult: Result<SpacesDeviceReviewComment, any Error>?
    /// `workspaceReviewCommentUpsert` calls to hold open rather than answering right
    /// away, counted down on each arrival — mirrors `holdNextSubscribeAttempts`'s shape, simplified
    /// (no ref names/handlers to track) since nothing here needs arrival-order bookkeeping beyond a
    /// single held call at a time for the "resumes even after teardown" test.
    private var holdNextUpsertAttempts = 0
    private var pendingUpsertCalls: [(arrivalIndex: Int, continuation: CheckedContinuation<SpacesDeviceReviewComment, any Error>)] = []
    private var upsertCallArrivalCount = 0
    private var upsertArrivalWaiters: [CheckedContinuation<Void, Never>] = []

    private(set) var reviewCommentDeleteCalls: [(workspaceID: String, id: String)] = []
    private var reviewCommentDeleteResult: Result<SpacesDeviceAPIResponse, any Error> = .success(
        SpacesDeviceAPIResponse(ok: true, message: "Deleted."))
    /// `workspaceReviewCommentDelete` calls to hold open rather than answering right away,
    /// counted down on each arrival — mirrors `holdNextUpsertAttempts`'s shape exactly.
    private var holdNextDeleteAttempts = 0
    private var pendingDeleteCalls: [(arrivalIndex: Int, continuation: CheckedContinuation<SpacesDeviceAPIResponse, any Error>)] = []
    private var deleteCallArrivalCount = 0

    private(set) var reviewCommentsSendCalls:
        [(workspaceID: String, sessionID: String, text: String, comments: [SpacesDeviceReviewCommentSendEntry])] = []
    private var reviewCommentsSendResult: Result<SpacesDeviceAPIResponse, any Error> = .success(SpacesDeviceAPIResponse(ok: true, message: "Sent."))

    func setReviewCommentListResult(_ result: Result<[SpacesDeviceReviewComment], any Error>) { reviewCommentListResult = result }
    func setReviewCommentUpsertResult(_ result: Result<SpacesDeviceReviewComment, any Error>) { reviewCommentUpsertResult = result }
    func setReviewCommentDeleteResult(_ result: Result<SpacesDeviceAPIResponse, any Error>) { reviewCommentDeleteResult = result }
    func setReviewCommentsSendResult(_ result: Result<SpacesDeviceAPIResponse, any Error>) { reviewCommentsSendResult = result }

    func workspaceReviewCommentList(workspaceID: String, device: SpacesPairedDeviceRecord) async throws -> [SpacesDeviceReviewComment] {
        reviewCommentListCalls.append(workspaceID)
        return try reviewCommentListResult.get()
    }

    func workspaceReviewCommentUpsert(
        workspaceID: String, id: String?, filePath: String, side: SpacesDeviceReviewCommentSide, lineNumber: Int, lineText: String, body: String,
        device: SpacesPairedDeviceRecord
    ) async throws -> SpacesDeviceReviewComment {
        reviewCommentUpsertCalls.append((workspaceID, id, filePath, side, lineNumber, lineText, body))
        let waiters = upsertArrivalWaiters
        upsertArrivalWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        if holdNextUpsertAttempts > 0 {
            holdNextUpsertAttempts -= 1
            let arrivalIndex = upsertCallArrivalCount
            upsertCallArrivalCount += 1
            return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<SpacesDeviceReviewComment, any Error>) in
                pendingUpsertCalls.append((arrivalIndex, continuation))
            }
        }
        guard let reviewCommentUpsertResult else {
            return SpacesDeviceReviewComment(
                id: id ?? "generated-id", filePath: filePath, side: side, lineNumber: lineNumber, lineText: lineText, body: body,
                createdAt: "2026-01-01T00:00:00Z", revision: 0)
        }
        return try reviewCommentUpsertResult.get()
    }

    /// Makes the next `count` `workspaceReviewCommentUpsert` calls suspend instead of
    /// resolving immediately, so a test can observe the RPC still in flight (e.g. across a teardown)
    /// before completing it via `completeHeldUpsertCall`.
    func holdNextUpsertAttempts(_ count: Int) { holdNextUpsertAttempts = count }

    func waitForUpsertCallCount(_ count: Int) async {
        while upsertCallArrivalCount < count {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in upsertArrivalWaiters.append(continuation) }
        }
    }

    /// Resolves the held `workspaceReviewCommentUpsert` call at `index` (0-based, arrival order among
    /// held calls only) with `result`.
    func completeHeldUpsertCall(at index: Int, result: SpacesDeviceReviewComment) {
        guard let position = pendingUpsertCalls.firstIndex(where: { $0.arrivalIndex == index }) else {
            preconditionFailure("no held workspaceReviewCommentUpsert call at arrival index \(index)")
        }
        pendingUpsertCalls.remove(at: position).continuation.resume(returning: result)
    }

    /// Fails the held `workspaceReviewCommentUpsert` call at `index`, mirroring
    /// `completeHeldUpsertCall(at:result:)` for the reconcile mechanism's "the CREATE never committed"
    /// test — the reconcile must not run at all on this path.
    func failHeldUpsertCall(at index: Int, error: any Error) {
        guard let position = pendingUpsertCalls.firstIndex(where: { $0.arrivalIndex == index }) else {
            preconditionFailure("no held workspaceReviewCommentUpsert call at arrival index \(index)")
        }
        pendingUpsertCalls.remove(at: position).continuation.resume(throwing: error)
    }

    func workspaceReviewCommentDelete(workspaceID: String, id: String, device: SpacesPairedDeviceRecord) async throws -> SpacesDeviceAPIResponse {
        reviewCommentDeleteCalls.append((workspaceID, id))
        if holdNextDeleteAttempts > 0 {
            holdNextDeleteAttempts -= 1
            let arrivalIndex = deleteCallArrivalCount
            deleteCallArrivalCount += 1
            return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<SpacesDeviceAPIResponse, any Error>) in
                pendingDeleteCalls.append((arrivalIndex, continuation))
            }
        }
        return try reviewCommentDeleteResult.get()
    }

    /// Makes the next `count` `workspaceReviewCommentDelete` calls suspend instead of
    /// resolving immediately, so a test can observe the RPC still in flight (e.g. across a teardown)
    /// before completing it via `completeHeldDeleteCall`. Mirrors `holdNextUpsertAttempts`.
    func holdNextDeleteAttempts(_ count: Int) { holdNextDeleteAttempts = count }

    /// Resolves the held `workspaceReviewCommentDelete` call at `index` (0-based, arrival order among
    /// held calls only) with `result`.
    func completeHeldDeleteCall(at index: Int, result: SpacesDeviceAPIResponse) {
        guard let position = pendingDeleteCalls.firstIndex(where: { $0.arrivalIndex == index }) else {
            preconditionFailure("no held workspaceReviewCommentDelete call at arrival index \(index)")
        }
        pendingDeleteCalls.remove(at: position).continuation.resume(returning: result)
    }

    /// Fails the held `workspaceReviewCommentDelete` call at `index`, mirroring `completeHeldDeleteCall`.
    func failHeldDeleteCall(at index: Int, error: any Error) {
        guard let position = pendingDeleteCalls.firstIndex(where: { $0.arrivalIndex == index }) else {
            preconditionFailure("no held workspaceReviewCommentDelete call at arrival index \(index)")
        }
        pendingDeleteCalls.remove(at: position).continuation.resume(throwing: error)
    }

    func workspaceReviewCommentsSend(
        workspaceID: String, sessionID: String, text: String, comments: [SpacesDeviceReviewCommentSendEntry], device: SpacesPairedDeviceRecord
    ) async throws -> SpacesDeviceAPIResponse {
        reviewCommentsSendCalls.append((workspaceID, sessionID, text, comments))
        return try reviewCommentsSendResult.get()
    }

    private(set) var workspaceCommandStartCalls: [(workspaceID: String, command: String)] = []
    private var workspaceCommandStartResult: Result<SpacesDeviceAPIResponse, any Error> = .success(
        SpacesDeviceAPIResponse(ok: true, message: "Started.", result: .mutation(.init(sessionID: "session-start"))))
    private var holdNextWorkspaceCommandStartAttempts = 0
    private var pendingWorkspaceCommandStartCalls: [(arrivalIndex: Int, continuation: CheckedContinuation<SpacesDeviceAPIResponse, any Error>)] = []
    private var workspaceCommandStartArrivalCount = 0
    private var workspaceCommandStartArrivalWaiters: [CheckedContinuation<Void, Never>] = []
    private var workspaceCommandStartSnapshots: [Result<CodePaneAgentStartSnapshot, any Error>] = []

    func setWorkspaceCommandStartResult(_ result: Result<SpacesDeviceAPIResponse, any Error>) { workspaceCommandStartResult = result }

    func holdNextWorkspaceCommandStartAttempts(_ count: Int) { holdNextWorkspaceCommandStartAttempts = count }

    func waitForWorkspaceCommandStartCallCount(_ count: Int) async {
        while workspaceCommandStartArrivalCount < count {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                workspaceCommandStartArrivalWaiters.append(continuation)
            }
        }
    }

    func completeHeldWorkspaceCommandStartCall(at index: Int, result: SpacesDeviceAPIResponse) {
        guard let position = pendingWorkspaceCommandStartCalls.firstIndex(where: { $0.arrivalIndex == index }) else {
            preconditionFailure("no held startWorkspaceCommand call at arrival index \(index)")
        }
        pendingWorkspaceCommandStartCalls.remove(at: position).continuation.resume(returning: result)
    }

    func enqueueWorkspaceCommandStartSnapshot(_ result: Result<CodePaneAgentStartSnapshot, any Error>) {
        workspaceCommandStartSnapshots.append(result)
    }

    func startWorkspaceCommand(workspaceID: String, command: String, device: SpacesPairedDeviceRecord) async throws -> SpacesDeviceAPIResponse {
        workspaceCommandStartCalls.append((workspaceID, command))
        let arrivalIndex = workspaceCommandStartArrivalCount
        workspaceCommandStartArrivalCount += 1
        let waiters = workspaceCommandStartArrivalWaiters
        workspaceCommandStartArrivalWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        if holdNextWorkspaceCommandStartAttempts > 0 {
            holdNextWorkspaceCommandStartAttempts -= 1
            return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<SpacesDeviceAPIResponse, any Error>) in
                pendingWorkspaceCommandStartCalls.append((arrivalIndex, continuation))
            }
        }
        return try workspaceCommandStartResult.get()
    }

    func workspaceCommandStartSnapshot(workspaceID: String, sessionID: String, device: SpacesPairedDeviceRecord) async throws
        -> CodePaneAgentStartSnapshot
    {
        if !workspaceCommandStartSnapshots.isEmpty { return try workspaceCommandStartSnapshots.removeFirst().get() }
        return CodePaneAgentStartSnapshot(state: .running, detectedKind: nil, bracketedPasteActive: false, agent: nil)
    }
}

/// Covers `CodePaneContentController`'s hibernation seam: `contentView` is a stable container that
/// survives the controller's whole lifetime, while the `WKWebView` itself is created by `activate()` and
/// torn down by `deactivate()` — the expensive resource a hidden tab must not keep alive.
@MainActor @Suite(.serialized) struct CodePaneContentControllerTests {
    // Held by the suite instance (Swift Testing gives each test its own), not created inline as a
    // call-site temporary: `CodePaneContentController.hosting` is `weak`, so a temporary with no
    // other strong reference would be deallocated the instant `init` returns.
    private let hostingDouble = EmptyCodePaneHostingDouble()

    private func makeController(
        hosting: (any CodePaneHosting)? = nil, deviceGateway: any CodePaneDeviceGateway = LiveCodePaneDeviceGateway(),
        workspaceStateStore: (any CodePaneWorkspaceStateStoring)? = nil
    ) -> CodePaneContentController {
        CodePaneContentController(
            paneID: "pane-1", deviceID: "device-1", workspaceID: "workspace-1", initialMode: .diff, hosting: hosting ?? hostingDouble,
            initialModePolicy: .restoreWorkspaceMode, deviceGateway: deviceGateway,
            workspaceStateStore: workspaceStateStore ?? DiscardingCodePaneWorkspaceStateStorage())
    }

    /// Polls `predicate` until it's true or `timeout` elapses, yielding between checks so the
    /// controller's own unstructured `Task`s (spawned from `dispatch`/`resubscribeDiffSignature`, with
    /// no handle the test can `await` directly) get a chance to run. Matches the pattern in
    /// `TerminalLinkOpenCoordinatorTests.waitUntil`.
    private func waitUntil(timeout: Duration = .seconds(5), sourceLocation: SourceLocation = #_sourceLocation, _ predicate: @MainActor () -> Bool)
        async
    {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !predicate(), clock.now < deadline {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(5))
        }
        if !predicate() { Issue.record("waitUntil timed out after \(timeout)", sourceLocation: sourceLocation) }
    }

    private func fakeDevice() -> SpacesPairedDeviceRecord {
        SpacesPairedDeviceRecord(
            id: "device-1", name: "Test Device", platform: "macos", hosts: ["127.0.0.1"], port: 47847, certificateFingerprint: "fingerprint",
            createdAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-01T00:00:00Z")
    }

    private func completeWorkspaceState() -> CodePaneBridge.WorkspaceState {
        CodePaneBridge.WorkspaceState(
            mode: "editor", scope: .init(kind: "ref", refName: "main"), diffLayout: "split", diffSelectedPath: "Sources/App.swift",
            diffTreeExpandedPaths: ["Changes", "Sources"], diffTreeSelectedPath: "Sources/App.swift", fileTreeExpandedPaths: ["Sources", "Tests"],
            fileTreeSelectedPath: "Sources/App.swift", editorSidebarMode: "changes",
            editorRecentPaths: ["Sources/App.swift", "Tests/AppTests.swift"], diffScrollLine: 41, diffScrollSide: "old",
            diffFocusedPath: "Sources/App.swift", diffFocusedLine: 42, diffFocusedSide: "new", editorScrollLine: 17, editorFocusedLine: 18,
            editorState: .init(
                path: "Sources/App.swift", baseSHA256: "editor-base", baseContent: "let base = 1", content: "let edited = 2", dirty: true,
                conflict: false),
            diffEditorState: .init(
                path: "Sources/App.swift", baseSHA256: "diff-base", baseContent: "let base = 1", comparisonOldContent: nil, content: "let edited = 3", dirty: true,
                conflict: true, conflictBaseSHA256: "disk-sha"),
            pendingReviewComments: [
                .init(
                    id: "draft-1", provisional: true, filePath: "Sources/App.swift", side: .new, lineNumber: 42, lineText: "let edited = 2",
                    body: "Please keep this.")
            ], selectedAgentSessionId: "session-agent",
            pendingAgentLaunch: .init(
                sessionId: "session-start", command: "custom-agent --review", status: "starting", message: nil,
                deadlineEpochMilliseconds: 9_999_999_999_999))
    }

    private func workspaceStateJSON(_ state: CodePaneBridge.WorkspaceState) throws -> String {
        String(decoding: try JSONEncoder().encode(state), as: UTF8.self)
    }

    private func initWorkspaceState(in script: String) throws -> CodePaneBridge.WorkspaceState {
        let prefix = "window.dispatchEvent(new CustomEvent(\"spaces:init\", {detail: "
        let suffix = "}));"
        guard script.hasPrefix(prefix), script.hasSuffix(suffix) else { throw TestParseError.unexpectedInitScript }
        struct InitDetail: Decodable { let workspaceState: CodePaneBridge.WorkspaceState }
        let detail = String(script.dropFirst(prefix.count).dropLast(suffix.count))
        return try JSONDecoder().decode(InitDetail.self, from: Data(detail.utf8)).workspaceState
    }

    private enum TestParseError: Error { case unexpectedInitScript }

    private func startedCommandResponse(sessionID: String = "session-start") -> SpacesDeviceAPIResponse {
        SpacesDeviceAPIResponse(ok: true, message: "Started.", result: .mutation(.init(sessionID: sessionID)))
    }

    private func startedCommandResponseWithoutOverviewSession(sessionID: String = "session-start") -> SpacesDeviceAPIResponse {
        let launched = SpacesDeviceTerminalSessionSummary(
            id: sessionID, title: "shell-1", workingDirectory: "/tmp/workspace", shell: "/bin/zsh", command: "custom-agent --review", state: .running,
            backend: .ghosttyEmbedded, lifetimePolicy: .persistent, servicePID: 123, childPID: 456, workspaceID: "workspace-1", workspaceTitle: nil,
            projectID: nil, projectName: nil, createdAt: "2026-08-28T18:00:00Z", updatedAt: "2026-08-28T18:00:00Z", isControlAvailable: true,
            isSubscriptionAvailable: true, attachmentSnapshot: .init())
        let overview = SpacesDeviceOverviewPayload(
            workspaces: [
                SpacesDeviceWorkspaceSummary(
                    id: "workspace-1", projectID: "project-1", projectName: "Project", branch: "code-pane", baseBranch: "main", dir: "/tmp/workspace",
                    isRunning: true, isHidden: false, isDefault: false, sessionCount: 0)
            ], sessions: [])
        return SpacesDeviceAPIResponse(
            ok: true, message: "Started.",
            result: .mutation(.init(overview: overview, workspaceID: "workspace-1", sessionID: sessionID, launchedTerminalSession: launched)))
    }

    private func diffRequest(id: String, scopeKind: String, refName: String? = nil) -> CodePaneBridge.Request {
        var scope: [String: Any] = ["kind": scopeKind]
        if let refName { scope["refName"] = refName }
        return CodePaneBridge.Request(id: id, method: "workspaceDiffManifestChunk", params: ["scope": scope, "fileIndex": 0])
    }

    private func fileReadRequest(id: String, path: String) -> CodePaneBridge.Request {
        CodePaneBridge.Request(id: id, method: "workspaceFileRead", params: ["path": path, "purpose": "editor"])
    }

    /// Waits out a window without asserting anything, so a "this must NOT happen" test can give the
    /// controller's Tasks a fair chance to (wrongly) act before checking that they didn't — as
    /// opposed to `waitUntil`, which records a failure if its predicate never turns true.
    private func settle(_ duration: Duration = .milliseconds(200)) async {
        let deadline = ContinuousClock().now.advanced(by: duration)
        while ContinuousClock().now < deadline {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    /// Every subview reachable from `view`, depth-first, in add order — used to locate the crash
    /// notice's Reload button and message label without depending on the exact stack shape.
    private func descendants(in view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants(in: $0) } }

    @Test func descriptorCarriesTheDeviceAndWorkspaceItShows() {
        let content = makeController()

        #expect(content.descriptor == .codePane(deviceID: "device-1", workspaceID: "workspace-1"))
    }

    @Test func activateInstallsAWebViewAndDeactivateTearsItDown() {
        let content = makeController()
        #expect(content.contentView.subviews.isEmpty, "no web view before activation")

        content.activate(focus: false)

        #expect(content.contentView.subviews.contains { $0 is WKWebView }, "activate() installs the web view")

        content.deactivate()

        #expect(content.contentView.subviews.isEmpty, "deactivate() tears the web view down")
    }

    /// The container view itself must not be recreated across the hibernation cycle: the pane tree holds
    /// onto `contentView` and re-parents it, so a fresh instance on every activate would orphan whatever
    /// the pane tree already placed in the view hierarchy.
    @Test func contentViewIdentityIsStableAcrossHibernation() {
        let content = makeController()
        let view = content.contentView

        content.activate(focus: false)
        content.deactivate()
        content.activate(focus: false)

        #expect(content.contentView === view)
    }

    @Test func reactivatingAfterDeactivateInstallsAFreshWebView() {
        let content = makeController()
        content.activate(focus: false)
        let firstWebView = content.contentView.subviews.first { $0 is WKWebView }
        content.deactivate()

        content.activate(focus: false)

        let secondWebView = content.contentView.subviews.first { $0 is WKWebView }
        #expect(secondWebView != nil)
        #expect(secondWebView !== firstWebView, "a new web process is created rather than reusing the torn-down one")
    }

    @Test func ownsRespondersOnlyWhileActivated() throws {
        let content = makeController()

        content.activate(focus: false)
        let webView = try #require(content.contentView.subviews.first { $0 is WKWebView })
        #expect(content.owns(responder: webView))

        content.deactivate()

        #expect(!content.owns(responder: webView), "a torn-down web view is no longer owned")
    }

    /// `close()` is the one-way teardown; it must leave the pane in the same hibernated state as
    /// `deactivate()` so a pane removed mid-preparation cannot leak its web view.
    @Test func closeTearsDownTheWebViewLikeDeactivate() {
        let content = makeController()
        content.activate(focus: false)
        let evaluator = RecordingCodePaneScriptEvaluator()
        content.scriptEvaluator = evaluator

        content.close()
        evaluator.completeOldestPending(with: "__none__")

        #expect(content.contentView.subviews.isEmpty)
    }

    // MARK: - Web content process termination / failed load

    @Test func webContentProcessTerminationShowsNoticeAndRemovesTheWebView() throws {
        let content = makeController()
        content.activate(focus: false)
        let evaluator = RecordingCodePaneScriptEvaluator()
        content.scriptEvaluator = evaluator
        let webView = try #require(content.contentView.subviews.first { $0 is WKWebView } as? WKWebView)

        content.webViewWebContentProcessDidTerminate(webView)

        #expect(!content.contentView.subviews.contains { $0 is WKWebView }, "the dead web view is removed from the pane")
        let notice = content.contentView.subviews.first { $0.accessibilityIdentifier() == "codePaneCrashNotice" }
        #expect(notice != nil, "a crash notice replaces it")
    }

    @Test func reloadAfterTerminationInstallsAFreshWebViewAndRemovesTheNotice() throws {
        let content = makeController()
        content.activate(focus: false)
        let firstWebView = try #require(content.contentView.subviews.first { $0 is WKWebView } as? WKWebView)
        content.webViewWebContentProcessDidTerminate(firstWebView)
        let reloadButton = try #require(
            descendants(in: content.contentView).first { $0.accessibilityIdentifier() == "codePaneCrashNoticeReload" } as? NSButton)

        _ = reloadButton.target?.perform(reloadButton.action, with: reloadButton)

        #expect(
            content.contentView.subviews.first { $0.accessibilityIdentifier() == "codePaneCrashNotice" } == nil,
            "Reload removes the notice")
        let secondWebView = content.contentView.subviews.first { $0 is WKWebView }
        #expect(secondWebView != nil, "Reload installs a fresh web view")
        #expect(secondWebView !== firstWebView, "the fresh web view is a new instance, not the dead one")
    }

    /// Mirrors `staleGenerationReplyIsDroppedAfterHibernationReplacesTheWebView` for the
    /// termination + Reload path: `installWebView()` bumps `pageGeneration` exactly like a hibernation
    /// reactivate does, so a reply for a request the dead page issued must never reach the fresh page.
    @Test func staleGenerationReplyIsDroppedAfterTerminationAndReload() async throws {
        let gateway = RecordingCodePaneDeviceGateway()
        let hosting = DeviceCodePaneHostingDouble(device: fakeDevice())
        let content = makeController(hosting: hosting, deviceGateway: gateway)
        content.activate(focus: false)
        let staleEvaluator = RecordingCodePaneScriptEvaluator()
        content.scriptEvaluator = staleEvaluator

        content.dispatch(diffRequest(id: "req-1", scopeKind: "uncommitted"))
        await gateway.waitForDiffCallCount(1)

        let deadWebView = try #require(content.contentView.subviews.first { $0 is WKWebView } as? WKWebView)
        content.webViewWebContentProcessDidTerminate(deadWebView)
        let reloadButton = try #require(
            descendants(in: content.contentView).first { $0.accessibilityIdentifier() == "codePaneCrashNoticeReload" } as? NSButton)
        _ = reloadButton.target?.perform(reloadButton.action, with: reloadButton)
        let freshEvaluator = RecordingCodePaneScriptEvaluator()
        content.scriptEvaluator = freshEvaluator

        await gateway.completeDiffCall(
            at: 0, result: SpacesDeviceWorkspaceDiffManifestChunkResult(manifestID: "test-manifest", scopeSignature: "sig", files: []))
        await settle()

        #expect(
            !staleEvaluator.evaluatedScripts.contains { $0.contains("req-1") }, "the dead page's evaluator must never receive the stale reply")
        #expect(freshEvaluator.evaluatedScripts.isEmpty, "the fresh page never issued this request, so it must not receive a reply for it either")
    }

    @Test func terminationOfAReplacedWebViewIsIgnored() throws {
        let content = makeController()
        content.activate(focus: false)
        let firstWebView = try #require(content.contentView.subviews.first { $0 is WKWebView } as? WKWebView)
        content.deactivate()
        content.activate(focus: false)
        let currentWebView = try #require(content.contentView.subviews.first { $0 is WKWebView } as? WKWebView)
        #expect(currentWebView !== firstWebView)

        // A stale termination callback for the web view hibernation already replaced must be ignored.
        content.webViewWebContentProcessDidTerminate(firstWebView)

        #expect(
            content.contentView.subviews.first { $0.accessibilityIdentifier() == "codePaneCrashNotice" } == nil, "no notice for a stale termination")
        #expect(content.contentView.subviews.contains { $0 === currentWebView }, "the current web view is untouched")
    }

    @Test func failedNavigationShowsNoticeWithTheFailedLoadMessage() throws {
        let content = makeController()
        content.activate(focus: false)
        let webView = try #require(content.contentView.subviews.first { $0 is WKWebView } as? WKWebView)
        let error = NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "boom"])

        content.webView(webView, didFailProvisionalNavigation: nil, withError: error)

        #expect(!content.contentView.subviews.contains { $0 is WKWebView }, "the failed page's web view is removed")
        let notice = try #require(content.contentView.subviews.first { $0.accessibilityIdentifier() == "codePaneCrashNotice" })
        let messageLabel = descendants(in: notice).compactMap { $0 as? NSTextField }.first { $0.stringValue == "The Editor page failed to load." }
        #expect(messageLabel != nil, "the notice carries the failed-load message")
    }

    @Test func cancelledNavigationFailureIsIgnored() throws {
        let content = makeController()
        content.activate(focus: false)
        let webView = try #require(content.contentView.subviews.first { $0 is WKWebView } as? WKWebView)
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled, userInfo: nil)

        content.webView(webView, didFail: nil, withError: error)

        #expect(content.contentView.subviews.contains { $0 is WKWebView }, "a cancelled navigation leaves the live web view alone")
        #expect(content.contentView.subviews.first { $0.accessibilityIdentifier() == "codePaneCrashNotice" } == nil, "and shows no notice")
    }

    // MARK: - Resource bundle layout

    /// Regression guard for the `.copy("Resources/CodePane")` resource declaration: SwiftPM keeps
    /// only the last path component (`CodePane`) inside the built resource bundle, so this must fail
    /// loudly if the subdirectory argument or the resource declaration ever drifts back out of sync,
    /// instead of silently shipping a blank pane.
    @Test func codePaneIndexURLResolvesTheBuiltBundleOnDisk() throws {
        let indexURL = try #require(CodePaneContentController.codePaneIndexURL())
        #expect(FileManager.default.fileExists(atPath: indexURL.path))

        let assetsURL = indexURL.deletingLastPathComponent().appendingPathComponent("assets", isDirectory: true)
        var isDirectory: ObjCBool = false
        let assetsExists = FileManager.default.fileExists(atPath: assetsURL.path, isDirectory: &isDirectory)
        #expect(assetsExists && isDirectory.boolValue, "the built bundle ships an assets/ directory next to index.html")
    }

    // MARK: - Stale replies after hibernation

    @Test func staleGenerationReplyIsDroppedAfterHibernationReplacesTheWebView() async {
        let gateway = RecordingCodePaneDeviceGateway()
        let hosting = DeviceCodePaneHostingDouble(device: fakeDevice())
        let content = makeController(hosting: hosting, deviceGateway: gateway)
        content.activate(focus: false)
        let staleEvaluator = RecordingCodePaneScriptEvaluator()
        content.scriptEvaluator = staleEvaluator

        content.dispatch(diffRequest(id: "req-1", scopeKind: "uncommitted"))
        await gateway.waitForDiffCallCount(1)

        // Hibernate for real: deactivate/activate is what actually bumps `pageGeneration`, not a
        // simulation of it, so this exercises the exact race the fix guards against.
        content.deactivate()
        content.activate(focus: false)
        let freshEvaluator = RecordingCodePaneScriptEvaluator()
        content.scriptEvaluator = freshEvaluator

        await gateway.completeDiffCall(
            at: 0, result: SpacesDeviceWorkspaceDiffManifestChunkResult(manifestID: "test-manifest", scopeSignature: "sig", files: []))
        await settle()

        // `staleEvaluator` does legitimately receive one script from `deactivate()` itself: the
        // teardown flush's collect script — issued against whatever evaluator was live
        // the instant the page tore down, which is `staleEvaluator` here. What it must never receive
        // is the stale request's own reply.
        #expect(
            !staleEvaluator.evaluatedScripts.contains { $0.contains("req-1") }, "the torn-down page's evaluator must never receive the stale reply")
        #expect(freshEvaluator.evaluatedScripts.isEmpty, "the fresh page never issued this request, so it must not receive a reply for it either")
    }

    @Test func sameGenerationReplyStillDelivers() async {
        let gateway = RecordingCodePaneDeviceGateway()
        let hosting = DeviceCodePaneHostingDouble(device: fakeDevice())
        let content = makeController(hosting: hosting, deviceGateway: gateway)
        content.activate(focus: false)
        let evaluator = RecordingCodePaneScriptEvaluator()
        content.scriptEvaluator = evaluator

        content.dispatch(diffRequest(id: "req-1", scopeKind: "uncommitted"))
        await gateway.waitForDiffCallCount(1)
        await gateway.completeDiffCall(
            at: 0, result: SpacesDeviceWorkspaceDiffManifestChunkResult(manifestID: "test-manifest", scopeSignature: "sig", files: []))

        await waitUntil { evaluator.evaluatedScripts.contains { $0.contains("req-1") } }

        #expect(
            evaluator.evaluatedScripts.contains { $0.contains("req-1") },
            "a reply for a request that's still current (no hibernation in between) must be evaluated")
    }

    // MARK: - Out-of-order diff completions don't retarget the stream

    @Test func lateDiffResponseDoesNotRetargetTheStreamToASupersededScope() async {
        let gateway = RecordingCodePaneDeviceGateway()
        let hosting = DeviceCodePaneHostingDouble(device: fakeDevice())
        let content = makeController(hosting: hosting, deviceGateway: gateway)
        content.activate(focus: false)
        let evaluator = RecordingCodePaneScriptEvaluator()
        content.scriptEvaluator = evaluator

        content.dispatch(diffRequest(id: "req-1", scopeKind: "uncommitted"))
        await gateway.waitForDiffCallCount(1)
        content.dispatch(diffRequest(id: "req-2", scopeKind: "ref", refName: "feature-branch"))
        await gateway.waitForDiffCallCount(2)

        // Complete the SECOND (later) scope first, then the FIRST (now-superseded) scope last.
        await gateway.completeDiffCall(
            at: 1, result: SpacesDeviceWorkspaceDiffManifestChunkResult(manifestID: "test-manifest", scopeSignature: "sig-b", files: []))
        await gateway.waitForSubscribeCallCount(1)
        await gateway.completeDiffCall(
            at: 0, result: SpacesDeviceWorkspaceDiffManifestChunkResult(manifestID: "test-manifest", scopeSignature: "sig-a", files: []))

        await waitUntil { evaluator.evaluatedScripts.count >= 2 }

        let subscribeCount = await gateway.subscribeCallCount()
        #expect(subscribeCount == 1, "only the second (still-current) scope's completion should have triggered a resubscribe")
        let refName = await gateway.subscribedRefName(at: 0)
        #expect(refName == "feature-branch", "the subscription must target the later scope, not the superseded first one")
    }

    // MARK: - Stream disconnect clears state without clobbering a newer subscription

    @Test func disconnectClearsSubscribedScopeSoASameScopeDiffCanResubscribe() async {
        let gateway = RecordingCodePaneDeviceGateway()
        let hosting = DeviceCodePaneHostingDouble(device: fakeDevice())
        let content = makeController(hosting: hosting, deviceGateway: gateway)
        content.activate(focus: false)
        content.scriptEvaluator = RecordingCodePaneScriptEvaluator()

        content.dispatch(diffRequest(id: "req-1", scopeKind: "uncommitted"))
        await gateway.waitForDiffCallCount(1)
        await gateway.completeDiffCall(
            at: 0, result: SpacesDeviceWorkspaceDiffManifestChunkResult(manifestID: "test-manifest", scopeSignature: "sig-1", files: []))
        await gateway.waitForSubscribeCallCount(1)

        // Simulate a real disconnect (e.g. a daemon restart) on the current subscription.
        await gateway.triggerDisconnect(at: 0)
        await settle()

        // A second workspaceDiff for the SAME scope must resubscribe rather than stay skipped
        // forever by `resubscribeDiffSignature`'s same-scope no-op guard.
        content.dispatch(diffRequest(id: "req-2", scopeKind: "uncommitted"))
        await gateway.waitForDiffCallCount(2)
        await gateway.completeDiffCall(
            at: 1, result: SpacesDeviceWorkspaceDiffManifestChunkResult(manifestID: "test-manifest", scopeSignature: "sig-1", files: []))
        await gateway.waitForSubscribeCallCount(2)

        let count = await gateway.subscribeCallCount()
        #expect(count == 2, "a same-scope workspaceDiff after a disconnect must resubscribe instead of staying skipped")
    }

    @Test func staleDisconnectDoesNotClearANewerSubscriptionsState() async {
        let gateway = RecordingCodePaneDeviceGateway()
        let hosting = DeviceCodePaneHostingDouble(device: fakeDevice())
        let content = makeController(hosting: hosting, deviceGateway: gateway)
        content.activate(focus: false)
        content.scriptEvaluator = RecordingCodePaneScriptEvaluator()

        // First subscription: scope "uncommitted".
        content.dispatch(diffRequest(id: "req-1", scopeKind: "uncommitted"))
        await gateway.waitForDiffCallCount(1)
        await gateway.completeDiffCall(
            at: 0, result: SpacesDeviceWorkspaceDiffManifestChunkResult(manifestID: "test-manifest", scopeSignature: "sig-1", files: []))
        await gateway.waitForSubscribeCallCount(1)

        // A scope change supersedes it with a second, different-scope subscription.
        content.dispatch(diffRequest(id: "req-2", scopeKind: "ref", refName: "feature-branch"))
        await gateway.waitForDiffCallCount(2)
        await gateway.completeDiffCall(
            at: 1, result: SpacesDeviceWorkspaceDiffManifestChunkResult(manifestID: "test-manifest", scopeSignature: "sig-2", files: []))
        await gateway.waitForSubscribeCallCount(2)

        // The FIRST (already-superseded) subscription's client disconnects late.
        await gateway.triggerDisconnect(at: 0)
        await settle()

        // A same-scope ("feature-branch") diff must not need to resubscribe: the stale disconnect
        // must not have cleared the newer (still-live) subscription's state.
        content.dispatch(diffRequest(id: "req-3", scopeKind: "ref", refName: "feature-branch"))
        await gateway.waitForDiffCallCount(3)
        await gateway.completeDiffCall(
            at: 2, result: SpacesDeviceWorkspaceDiffManifestChunkResult(manifestID: "test-manifest", scopeSignature: "sig-2", files: []))
        await settle()

        let count = await gateway.subscribeCallCount()
        #expect(count == 2, "the stale (already-superseded) subscription's disconnect must not force a third resubscribe for the still-current scope")
    }

    // MARK: - A stale subscription attempt survives an A→B→A sequence
    //
    // `staleDisconnectDoesNotClearANewerSubscriptionsState` covers a stale disconnect
    // landing late. These two cover the sibling bug: a stale in-flight SUBSCRIBE ATTEMPT'S OWN
    // completion (success or failure) landing late. `resubscribeDiffSignature`'s completion guards
    // originally checked only `subscribedScope`, which is keyed purely by ref name — so after an
    // A→B→A scope sequence, the FIRST A's already-superseded attempt and the SECOND (current) A's
    // attempt share the exact same `DiffSignatureScope` value, and a scope-only guard cannot tell them
    // apart. `diffSignatureSubscriptionGeneration` is what distinguishes one subscription ATTEMPT from
    // another sharing the same scope.

    @Test func aStaleFirstAAttemptThatSucceedsLastIsStoppedNotInstalled() async {
        let gateway = RecordingCodePaneDeviceGateway()
        let hosting = DeviceCodePaneHostingDouble(device: fakeDevice())
        let content = makeController(hosting: hosting, deviceGateway: gateway)
        content.diffSignatureReconnectFloor = .milliseconds(20)
        content.diffSignatureReconnectCap = .milliseconds(20)
        content.activate(focus: false)
        content.scriptEvaluator = RecordingCodePaneScriptEvaluator()

        // First A: hold its subscribe attempt open so it's still outstanding when B's and the second
        // A's attempts start and resolve.
        await gateway.holdNextSubscribeAttempts(1)
        content.dispatch(diffRequest(id: "req-1", scopeKind: "uncommitted"))
        await gateway.waitForDiffCallCount(1)
        await gateway.completeDiffCall(
            at: 0, result: SpacesDeviceWorkspaceDiffManifestChunkResult(manifestID: "test-manifest", scopeSignature: "sig-a1", files: []))
        await gateway.waitForSubscribeAttemptCount(1)  // the first A's subscribe attempt has arrived and is now held

        // B: a genuine scope change, subscribes and succeeds normally.
        content.dispatch(diffRequest(id: "req-2", scopeKind: "ref", refName: "feature-branch"))
        await gateway.waitForDiffCallCount(2)
        await gateway.completeDiffCall(
            at: 1, result: SpacesDeviceWorkspaceDiffManifestChunkResult(manifestID: "test-manifest", scopeSignature: "sig-b", files: []))
        await gateway.waitForSubscribeCallCount(1)  // B's subscription opened

        // Second A: back on the SAME scope the still-outstanding first attempt targets; subscribes and
        // succeeds normally, becoming the CURRENT subscription.
        content.dispatch(diffRequest(id: "req-3", scopeKind: "uncommitted"))
        await gateway.waitForDiffCallCount(3)
        await gateway.completeDiffCall(
            at: 2, result: SpacesDeviceWorkspaceDiffManifestChunkResult(manifestID: "test-manifest", scopeSignature: "sig-a2", files: []))
        await gateway.waitForSubscribeCallCount(2)  // second A's subscription opened (now current)

        // Finally, the FIRST A's held attempt resolves — LAST, and for the SAME scope the current
        // (second A) subscription already holds.
        let staleHandle = await gateway.completeHeldSubscribeCall(at: 0)
        await settle()

        #expect(staleHandle.stopCount == 1, "a stale attempt's client must be stopped, not bare-assigned over the current live client")

        // Prove the CURRENT (second A) subscription — not the stale attempt — is the one actually
        // live: trigger ITS disconnect (subscribedDisconnectHandlers index 1, recorded right after B's
        // at index 0) and confirm the reconnect logic reacts to it by resubscribing the same scope.
        await gateway.triggerDisconnect(at: 1)
        await gateway.waitForSubscribeCallCount(4)  // B, second A, the stale attempt's belated success, and now this reconnect

        let refName = await gateway.subscribedRefName(at: 3)
        #expect(
            refName == nil, "the reconnect must retarget the current (second A) scope, proving it — not the stale attempt — was the live subscription"
        )
    }

    /// Companion to the success-resolves-last test above: the FIRST A's held attempt instead FAILS
    /// last. The catch arm's guard must reject it the same way, leaving the current (second A)
    /// subscription's `subscribedScope` untouched — a scope-only guard would incorrectly clear it
    /// (both attempts share the same scope value), forcing a wasteful, unnecessary resubscribe on the
    /// very next same-scope diff even though the current subscription is alive and healthy.
    @Test func aStaleFirstAAttemptThatFailsLastDoesNotDisturbTheCurrentSubscription() async {
        let gateway = RecordingCodePaneDeviceGateway()
        let hosting = DeviceCodePaneHostingDouble(device: fakeDevice())
        let content = makeController(hosting: hosting, deviceGateway: gateway)
        content.diffSignatureReconnectFloor = .milliseconds(20)
        content.diffSignatureReconnectCap = .milliseconds(20)
        content.activate(focus: false)
        content.scriptEvaluator = RecordingCodePaneScriptEvaluator()

        await gateway.holdNextSubscribeAttempts(1)
        content.dispatch(diffRequest(id: "req-1", scopeKind: "uncommitted"))
        await gateway.waitForDiffCallCount(1)
        await gateway.completeDiffCall(
            at: 0, result: SpacesDeviceWorkspaceDiffManifestChunkResult(manifestID: "test-manifest", scopeSignature: "sig-a1", files: []))
        await gateway.waitForSubscribeAttemptCount(1)

        content.dispatch(diffRequest(id: "req-2", scopeKind: "ref", refName: "feature-branch"))
        await gateway.waitForDiffCallCount(2)
        await gateway.completeDiffCall(
            at: 1, result: SpacesDeviceWorkspaceDiffManifestChunkResult(manifestID: "test-manifest", scopeSignature: "sig-b", files: []))
        await gateway.waitForSubscribeCallCount(1)

        content.dispatch(diffRequest(id: "req-3", scopeKind: "uncommitted"))
        await gateway.waitForDiffCallCount(3)
        await gateway.completeDiffCall(
            at: 2, result: SpacesDeviceWorkspaceDiffManifestChunkResult(manifestID: "test-manifest", scopeSignature: "sig-a2", files: []))
        await gateway.waitForSubscribeCallCount(2)

        // The FIRST A's held attempt fails, last, for the SAME scope the current subscription holds.
        await gateway.failHeldSubscribeCall(at: 0)
        await settle()

        // A subsequent same-scope-A diff must stay a no-op for the subscription: if the stale failure
        // had wrongly cleared `subscribedScope`, this would force an unnecessary third subscribe call.
        content.dispatch(diffRequest(id: "req-4", scopeKind: "uncommitted"))
        await gateway.waitForDiffCallCount(4)
        await gateway.completeDiffCall(
            at: 3, result: SpacesDeviceWorkspaceDiffManifestChunkResult(manifestID: "test-manifest", scopeSignature: "sig-a2", files: []))
        await settle()

        let subscribeCount = await gateway.subscribeCallCount()
        #expect(
            subscribeCount == 2, "the stale attempt's late failure must not clear the current subscription's scope and force a needless resubscribe")
    }

    // MARK: - Diff-signature frame dedupe

    /// Isolates the `spaces:diffSignature` dispatch scripts out of `evaluator`'s full recording
    /// (which also carries `workspaceDiff` reply scripts) — the two are told apart by which host
    /// event name they dispatch/resolve.
    private func diffSignatureScripts(_ evaluator: RecordingCodePaneScriptEvaluator) -> [String] {
        evaluator.evaluatedScripts.filter { $0.contains("spaces:diffSignature") }
    }

    @Test func aConnectFrameRepeatingTheJustFetchedDiffsSignatureIsSuppressed() async {
        let gateway = RecordingCodePaneDeviceGateway()
        let hosting = DeviceCodePaneHostingDouble(device: fakeDevice())
        let content = makeController(hosting: hosting, deviceGateway: gateway)
        content.activate(focus: false)
        let evaluator = RecordingCodePaneScriptEvaluator()
        content.scriptEvaluator = evaluator
        content.handleReady()  // simulate the web app's ready handshake so frames are eligible to forward

        content.dispatch(diffRequest(id: "req-1", scopeKind: "uncommitted"))
        await gateway.waitForDiffCallCount(1)
        await gateway.completeDiffCall(
            at: 0, result: SpacesDeviceWorkspaceDiffManifestChunkResult(manifestID: "test-manifest", scopeSignature: "sig-1", files: []))
        await gateway.waitForSubscribeCallCount(1)

        // The stream's connect-time frame repeats exactly the signature `performWorkspaceDiff` just
        // recorded as fetched — the web app already has this diff, so it must not be forwarded.
        await gateway.triggerFrame(at: 0, scopeSignature: "sig-1")
        await settle()

        #expect(diffSignatureScripts(evaluator).isEmpty, "a frame repeating the just-fetched diff's own signature must not be forwarded")
    }

    @Test func aFrameWithADifferentSignatureIsForwardedAndRecordedAsActedOn() async {
        let gateway = RecordingCodePaneDeviceGateway()
        let hosting = DeviceCodePaneHostingDouble(device: fakeDevice())
        let content = makeController(hosting: hosting, deviceGateway: gateway)
        content.activate(focus: false)
        let evaluator = RecordingCodePaneScriptEvaluator()
        content.scriptEvaluator = evaluator
        content.handleReady()

        content.dispatch(diffRequest(id: "req-1", scopeKind: "uncommitted"))
        await gateway.waitForDiffCallCount(1)
        await gateway.completeDiffCall(
            at: 0, result: SpacesDeviceWorkspaceDiffManifestChunkResult(manifestID: "test-manifest", scopeSignature: "sig-1", files: []))
        await gateway.waitForSubscribeCallCount(1)

        await gateway.triggerFrame(at: 0, scopeSignature: "sig-2")
        await waitUntil { !self.diffSignatureScripts(evaluator).isEmpty }

        #expect(diffSignatureScripts(evaluator).count == 1)
        #expect(diffSignatureScripts(evaluator)[0].contains("sig-2"))

        // Repeating the now-acted-on signature must in turn go quiet.
        await gateway.triggerFrame(at: 0, scopeSignature: "sig-2")
        await settle()
        #expect(diffSignatureScripts(evaluator).count == 1, "a repeat of the signature just forwarded must not forward again")
    }

    @Test func aReconnectsConnectFrameRepeatingTheLastForwardedSignatureStaysQuietButANewOneAfterItForwards() async {
        let gateway = RecordingCodePaneDeviceGateway()
        let hosting = DeviceCodePaneHostingDouble(device: fakeDevice())
        let content = makeController(hosting: hosting, deviceGateway: gateway)
        content.diffSignatureReconnectFloor = .milliseconds(20)
        content.diffSignatureReconnectCap = .milliseconds(20)
        content.activate(focus: false)
        let evaluator = RecordingCodePaneScriptEvaluator()
        content.scriptEvaluator = evaluator
        content.handleReady()

        content.dispatch(diffRequest(id: "req-1", scopeKind: "uncommitted"))
        await gateway.waitForDiffCallCount(1)
        await gateway.completeDiffCall(
            at: 0, result: SpacesDeviceWorkspaceDiffManifestChunkResult(manifestID: "test-manifest", scopeSignature: "sig-1", files: []))
        await gateway.waitForSubscribeCallCount(1)

        // A live update while still connected forwards and becomes the new "last acted on" signature.
        await gateway.triggerFrame(at: 0, scopeSignature: "sig-2")
        await waitUntil { !self.diffSignatureScripts(evaluator).isEmpty }
        #expect(diffSignatureScripts(evaluator).count == 1)

        // Disconnect; the backoff retry reopens the same scope. Its connect-time
        // frame repeats "sig-2" (nothing changed during the brief outage) — must stay suppressed.
        await gateway.triggerDisconnect(at: 0)
        await gateway.waitForSubscribeCallCount(2)
        await gateway.triggerFrame(at: 1, scopeSignature: "sig-2")
        await settle()
        #expect(
            diffSignatureScripts(evaluator).count == 1, "a reconnect's connect-time frame repeating the last-forwarded signature must stay suppressed"
        )

        // A real change discovered only after the outage must still forward.
        await gateway.triggerFrame(at: 1, scopeSignature: "sig-3")
        await waitUntil { self.diffSignatureScripts(evaluator).count == 2 }
        #expect(diffSignatureScripts(evaluator)[1].contains("sig-3"))
    }

    // MARK: - A diff completion after deactivate never resubscribes the stream

    /// `teardownWebView` bumps `latestDiffRequestToken`: without this, a `workspaceDiff` call
    /// still in flight when the pane hibernates would see its token unchanged on completion and
    /// reopen a daemon stream for a pane the user is no longer looking at.
    @Test func aDiffCompletionAfterDeactivateNeverResubscribesTheStream() async {
        let gateway = RecordingCodePaneDeviceGateway()
        let hosting = DeviceCodePaneHostingDouble(device: fakeDevice())
        let content = makeController(hosting: hosting, deviceGateway: gateway)
        content.activate(focus: false)
        content.scriptEvaluator = RecordingCodePaneScriptEvaluator()

        content.dispatch(diffRequest(id: "req-1", scopeKind: "uncommitted"))
        await gateway.waitForDiffCallCount(1)

        // Hibernate while the diff call is still gated (never completed yet).
        content.deactivate()

        await gateway.completeDiffCall(
            at: 0, result: SpacesDeviceWorkspaceDiffManifestChunkResult(manifestID: "test-manifest", scopeSignature: "sig-1", files: []))
        await settle()

        let subscribeCount = await gateway.subscribeCallCount()
        #expect(subscribeCount == 0, "a diff completion arriving after deactivate() must not open a subscription for a pane no longer visible")
    }

    // MARK: - Reconnect-with-backoff after a disconnect

    /// A disconnect must not leave the pane's live updates dead forever: with no user action at all,
    /// the retry loop itself resubscribes the same scope the dropped subscription had.
    @Test func disconnectSchedulesABackoffRetryThatResubscribesTheSameScope() async {
        let gateway = RecordingCodePaneDeviceGateway()
        let hosting = DeviceCodePaneHostingDouble(device: fakeDevice())
        let content = makeController(hosting: hosting, deviceGateway: gateway)
        content.diffSignatureReconnectFloor = .milliseconds(20)
        content.diffSignatureReconnectCap = .milliseconds(20)
        content.activate(focus: false)
        content.scriptEvaluator = RecordingCodePaneScriptEvaluator()

        content.dispatch(diffRequest(id: "req-1", scopeKind: "uncommitted"))
        await gateway.waitForDiffCallCount(1)
        await gateway.completeDiffCall(
            at: 0, result: SpacesDeviceWorkspaceDiffManifestChunkResult(manifestID: "test-manifest", scopeSignature: "sig-1", files: []))
        await gateway.waitForSubscribeCallCount(1)

        await gateway.triggerDisconnect(at: 0)

        // No further workspaceDiff dispatch here: only the backoff retry itself can produce this.
        await gateway.waitForSubscribeCallCount(2)

        let refName = await gateway.subscribedRefName(at: 1)
        #expect(refName == nil, "the retry must resubscribe the SAME scope (uncommitted, refName nil) the dropped subscription had")
    }

    @Test func aDisconnectBeforeSubscribeReturnsDiscardsTheDeadClientAndKeepsRetryLive() async {
        let gateway = RecordingCodePaneDeviceGateway()
        let hosting = DeviceCodePaneHostingDouble(device: fakeDevice())
        let content = makeController(hosting: hosting, deviceGateway: gateway)
        content.diffSignatureReconnectFloor = .milliseconds(20)
        content.diffSignatureReconnectCap = .milliseconds(20)
        content.activate(focus: false)
        content.scriptEvaluator = RecordingCodePaneScriptEvaluator()

        await gateway.holdNextSubscribeAttempts(1)
        content.dispatch(diffRequest(id: "req-1", scopeKind: "uncommitted"))
        await gateway.waitForDiffCallCount(1)
        await gateway.completeDiffCall(
            at: 0, result: SpacesDeviceWorkspaceDiffManifestChunkResult(manifestID: "test-manifest", scopeSignature: "sig-1", files: []))
        await gateway.waitForSubscribeAttemptCount(1)

        // The transport can die while the async subscribe operation is still waiting for its handle.
        // The returned handle must be stopped rather than installed as if it were live, and the
        // disconnect must still drive the ordinary bounded-backoff retry.
        await gateway.triggerHeldSubscribeDisconnect(at: 0)
        let deadHandle = await gateway.completeHeldSubscribeCall(at: 0)
        await gateway.waitForSubscribeCallCount(2)
        await settle()

        #expect(deadHandle.stopCount == 1, "a client that disconnected before subscribe returned must never be installed")
        #expect(await gateway.subscribeAttemptCount() == 2, "the pre-return disconnect must leave the retry loop live")
    }

    /// `deactivate()` is the hibernation seam: it must cancel a pending retry so a pane the user is no
    /// longer looking at never resubscribes behind its back.
    @Test func deactivatingDuringBackoffCancelsThePendingRetry() async {
        let gateway = RecordingCodePaneDeviceGateway()
        let hosting = DeviceCodePaneHostingDouble(device: fakeDevice())
        let content = makeController(hosting: hosting, deviceGateway: gateway)
        content.diffSignatureReconnectFloor = .milliseconds(150)
        content.diffSignatureReconnectCap = .milliseconds(150)
        content.activate(focus: false)
        content.scriptEvaluator = RecordingCodePaneScriptEvaluator()

        content.dispatch(diffRequest(id: "req-1", scopeKind: "uncommitted"))
        await gateway.waitForDiffCallCount(1)
        await gateway.completeDiffCall(
            at: 0, result: SpacesDeviceWorkspaceDiffManifestChunkResult(manifestID: "test-manifest", scopeSignature: "sig-1", files: []))
        await gateway.waitForSubscribeCallCount(1)

        await gateway.triggerDisconnect(at: 0)
        await settle(.milliseconds(50))  // let the disconnect handler run and schedule the retry's sleep

        content.deactivate()

        // Wait well past the 150ms backoff floor: if the retry weren't cancelled, it would have fired by now.
        await settle(.milliseconds(300))

        let attempts = await gateway.subscribeAttemptCount()
        #expect(attempts == 1, "hibernating during backoff must cancel the pending retry, so no second subscribe attempt occurs")
    }

    /// A user-triggered scope change mid-backoff must win cleanly: it resubscribes the new scope, and
    /// the stale retry for the old (now-superseded) scope must not fire late.
    @Test func aScopeChangeDuringBackoffSupersedesThePendingRetryForTheOldScope() async {
        let gateway = RecordingCodePaneDeviceGateway()
        let hosting = DeviceCodePaneHostingDouble(device: fakeDevice())
        let content = makeController(hosting: hosting, deviceGateway: gateway)
        content.diffSignatureReconnectFloor = .milliseconds(150)
        content.diffSignatureReconnectCap = .milliseconds(150)
        content.activate(focus: false)
        content.scriptEvaluator = RecordingCodePaneScriptEvaluator()

        content.dispatch(diffRequest(id: "req-1", scopeKind: "uncommitted"))
        await gateway.waitForDiffCallCount(1)
        await gateway.completeDiffCall(
            at: 0, result: SpacesDeviceWorkspaceDiffManifestChunkResult(manifestID: "test-manifest", scopeSignature: "sig-1", files: []))
        await gateway.waitForSubscribeCallCount(1)

        await gateway.triggerDisconnect(at: 0)
        await settle(.milliseconds(50))  // let the disconnect handler run and schedule the retry's sleep

        // A scope change arrives well before the 150ms backoff floor elapses.
        content.dispatch(diffRequest(id: "req-2", scopeKind: "ref", refName: "feature-branch"))
        await gateway.waitForDiffCallCount(2)
        await gateway.completeDiffCall(
            at: 1, result: SpacesDeviceWorkspaceDiffManifestChunkResult(manifestID: "test-manifest", scopeSignature: "sig-2", files: []))
        await gateway.waitForSubscribeCallCount(2)

        // Wait well past the original retry's 150ms floor to give a late, wrongly-surviving retry a
        // fair chance to (wrongly) fire before asserting it didn't.
        await settle(.milliseconds(300))

        let subscribeCount = await gateway.subscribeCallCount()
        #expect(subscribeCount == 2, "no late retry for the old scope may land on top of the new scope's subscription")
        let attempts = await gateway.subscribeAttemptCount()
        #expect(attempts == 2, "the stale retry for the superseded scope must never even attempt to subscribe")
        let refName = await gateway.subscribedRefName(at: 1)
        #expect(refName == "feature-branch", "the surviving subscription must be the new scope's")
    }

    /// Regression for the conditional dispatch-time generation bump: a same-scope
    /// refetch (the kind a `spaces:diffSignature` frame triggers via `refreshDiff`) against an
    /// already-subscribed, healthy stream must NOT bump `diffSignatureSubscriptionGeneration` —
    /// if it did, that stream's own `onDisconnect` closure (which captured the generation from
    /// when it opened) would find itself stale the moment a REAL disconnect fires afterward, and
    /// the pane's live updates would die with no reconnect. This pins the other half of the
    /// condition the scope-change test above doesn't exercise: the bump must be skippable, not
    /// just triggerable.
    @Test func aSameScopeRefetchDoesNotStaleTheLiveStreamsDisconnectHandler() async {
        let gateway = RecordingCodePaneDeviceGateway()
        let hosting = DeviceCodePaneHostingDouble(device: fakeDevice())
        let content = makeController(hosting: hosting, deviceGateway: gateway)
        content.diffSignatureReconnectFloor = .milliseconds(20)
        content.diffSignatureReconnectCap = .milliseconds(20)
        content.activate(focus: false)
        content.scriptEvaluator = RecordingCodePaneScriptEvaluator()

        content.dispatch(diffRequest(id: "req-1", scopeKind: "uncommitted"))
        await gateway.waitForDiffCallCount(1)
        await gateway.completeDiffCall(
            at: 0, result: SpacesDeviceWorkspaceDiffManifestChunkResult(manifestID: "test-manifest", scopeSignature: "sig-1", files: []))
        await gateway.waitForSubscribeCallCount(1)

        // A same-scope refetch, as `refreshDiff` issues on every `spaces:diffSignature` frame for
        // the scope already subscribed — `resubscribeDiffSignature`'s own `subscribedScope !=
        // .scope(refName)` guard already no-ops the resubscribe; this asserts the DISPATCH-time
        // bump this test is about also stays skipped, so no second subscribe call happens here.
        content.dispatch(diffRequest(id: "req-2", scopeKind: "uncommitted"))
        await gateway.waitForDiffCallCount(2)
        await gateway.completeDiffCall(
            at: 1, result: SpacesDeviceWorkspaceDiffManifestChunkResult(manifestID: "test-manifest", scopeSignature: "sig-1", files: []))
        await settle(.milliseconds(50))  // let the (would-be) resubscribe run if it were wrongly triggered
        #expect(await gateway.subscribeCallCount() == 1, "a same-scope refetch must not open a second subscription")

        // Now the original (still-only) subscription disconnects for real. If the refetch above had
        // wrongly bumped the generation, this disconnect's captured generation would be stale and
        // `handleDiffSignatureDisconnect` would silently drop it — no retry, no reconnect, ever.
        await gateway.triggerDisconnect(at: 0)
        await gateway.waitForSubscribeAttemptCount(2)

        let attempts = await gateway.subscribeAttemptCount()
        #expect(attempts == 2, "the disconnect must be honored and a reconnect attempt scheduled, not silently dropped")
    }

    /// A retry attempt that itself fails must not die silently: it schedules the next backoff step
    /// rather than leaving the pane stuck unsubscribed until the user happens to change scope.
    @Test func aFailedRetryAttemptSchedulesTheNextBackoffStep() async {
        let gateway = RecordingCodePaneDeviceGateway()
        let hosting = DeviceCodePaneHostingDouble(device: fakeDevice())
        let content = makeController(hosting: hosting, deviceGateway: gateway)
        content.diffSignatureReconnectFloor = .milliseconds(20)
        content.diffSignatureReconnectCap = .milliseconds(20)
        content.activate(focus: false)
        content.scriptEvaluator = RecordingCodePaneScriptEvaluator()

        content.dispatch(diffRequest(id: "req-1", scopeKind: "uncommitted"))
        await gateway.waitForDiffCallCount(1)
        await gateway.completeDiffCall(
            at: 0, result: SpacesDeviceWorkspaceDiffManifestChunkResult(manifestID: "test-manifest", scopeSignature: "sig-1", files: []))
        await gateway.waitForSubscribeCallCount(1)

        await gateway.failNextSubscribeAttempts(1)
        await gateway.triggerDisconnect(at: 0)

        // First retry attempt: fails (injected). It must still schedule a second retry rather than
        // giving up.
        await gateway.waitForSubscribeAttemptCount(2)
        // Second retry attempt: succeeds (no more injected failures).
        await gateway.waitForSubscribeCallCount(2)

        let attempts = await gateway.subscribeAttemptCount()
        #expect(attempts == 3, "3 attempts total: the first successful subscribe, the failed retry, and the retry after it")
        let subscribeCount = await gateway.subscribeCallCount()
        #expect(subscribeCount == 2, "only the two successful attempts open a subscription")
    }

    /// The device is nil by contract for exactly the window a daemon restart's
    /// disconnect fires retries into — the retry loop must keep rescheduling through that, not die on
    /// the first nil device it sees.
    @Test func deviceUnavailableDuringBackoffReschedulesInsteadOfAbandoningTheRetryLoop() async {
        let gateway = RecordingCodePaneDeviceGateway()
        let hosting = ToggleableCodePaneHostingDouble(device: fakeDevice(), unavailableForCalls: 2)
        let content = makeController(hosting: hosting, deviceGateway: gateway)
        content.diffSignatureReconnectFloor = .milliseconds(20)
        content.diffSignatureReconnectCap = .milliseconds(20)
        content.activate(focus: false)
        content.scriptEvaluator = RecordingCodePaneScriptEvaluator()

        content.dispatch(diffRequest(id: "req-1", scopeKind: "uncommitted"))
        await gateway.waitForDiffCallCount(1)
        await gateway.completeDiffCall(
            at: 0, result: SpacesDeviceWorkspaceDiffManifestChunkResult(manifestID: "test-manifest", scopeSignature: "sig-1", files: []))
        await gateway.waitForSubscribeCallCount(1)

        await gateway.triggerDisconnect(at: 0)

        // The device is nil for the first two retry attempts (as it would be while the daemon
        // restarts); the loop must keep rescheduling through both, then subscribe once it's available
        // again rather than abandoning the pane unsubscribed forever.
        await gateway.waitForSubscribeCallCount(2)

        let subscribeCount = await gateway.subscribeCallCount()
        #expect(subscribeCount == 2, "the retry loop must survive a nil device and eventually resubscribe once it's available again")
        #expect(hosting.codePaneDeviceCallCount >= 3, "at least the two nil lookups plus the one that finally succeeded must have happened")
    }

    /// A pane that hibernates while its retry loop is cycling through nil-device reschedules must stop
    /// dead, the same as it does mid-backoff for an ordinary disconnect retry (see
    /// `deactivatingDuringBackoffCancelsThePendingRetry` above) — the nil-device reschedule path must
    /// not be a second, ungated way for a stale retry to keep running past hibernation.
    @Test func hibernatingDuringNilDeviceRetriesStopsFurtherDeviceLookupsAndSubscribes() async {
        let gateway = RecordingCodePaneDeviceGateway()
        // Never recovers within this test's lifetime: every retry attempt sees a nil device.
        let hosting = ToggleableCodePaneHostingDouble(device: fakeDevice(), unavailableForCalls: 1000)
        let content = makeController(hosting: hosting, deviceGateway: gateway)
        content.diffSignatureReconnectFloor = .milliseconds(20)
        content.diffSignatureReconnectCap = .milliseconds(20)
        content.activate(focus: false)
        content.scriptEvaluator = RecordingCodePaneScriptEvaluator()

        content.dispatch(diffRequest(id: "req-1", scopeKind: "uncommitted"))
        await gateway.waitForDiffCallCount(1)
        await gateway.completeDiffCall(
            at: 0, result: SpacesDeviceWorkspaceDiffManifestChunkResult(manifestID: "test-manifest", scopeSignature: "sig-1", files: []))
        await gateway.waitForSubscribeCallCount(1)

        await gateway.triggerDisconnect(at: 0)
        // Let a couple of nil-device reschedule cycles happen before hibernating mid-loop.
        await settle(.milliseconds(100))
        let callCountBeforeHibernate = hosting.codePaneDeviceCallCount

        content.deactivate()
        await settle(.milliseconds(200))

        #expect(
            hosting.codePaneDeviceCallCount == callCountBeforeHibernate,
            "hibernating must stop the generation check before it ever reaches the device lookup again")
        let subscribeCount = await gateway.subscribeCallCount()
        #expect(subscribeCount == 1, "no recovery subscribe may land for a pane that already hibernated")
    }

    // MARK: - Failed scope change must not strand the old scope's live stream (P1 fix)
    //
    // `performWorkspaceDiff`'s dispatch-time generation bump used to leave `subscribedScope` and the
    // old stream installed but generation-stale when the NEW scope's fetch failed: a later return to
    // the old scope would find `subscribedScope` already equal to it, so both the bump's own condition
    // and `resubscribeDiffSignature`'s guard would skip, leaving the pane's live updates dead until
    // hibernation. The fix tears the old subscription down (`stop()`, nil the stream, clear
    // `subscribedScope` to `.none`) in the same breath as the generation bump, so a scope change is
    // atomic: there is never a window where a stale-but-still-installed stream can be found later.

    /// Pins the regression directly: navigate away from a live scope A to a scope B whose fetch fails,
    /// then return to A — a fresh subscription must open, not be skipped by a guard that (pre-fix)
    /// still thought A's superseded stream was current.
    @Test func aFailedScopeChangeDoesNotStrandTheOldScopesLiveStreamOnReturn() async {
        let gateway = RecordingCodePaneDeviceGateway()
        let hosting = DeviceCodePaneHostingDouble(device: fakeDevice())
        let content = makeController(hosting: hosting, deviceGateway: gateway)
        content.activate(focus: false)
        let evaluator = RecordingCodePaneScriptEvaluator()
        content.scriptEvaluator = evaluator
        content.handleReady()  // simulate the web app's ready handshake so frames are eligible to forward

        // Scope A live.
        content.dispatch(diffRequest(id: "req-1", scopeKind: "uncommitted"))
        await gateway.waitForDiffCallCount(1)
        await gateway.completeDiffCall(
            at: 0, result: SpacesDeviceWorkspaceDiffManifestChunkResult(manifestID: "test-manifest", scopeSignature: "sig-a1", files: []))
        await gateway.waitForSubscribeCallCount(1)

        // Navigate to scope B with a typo'd ref; its fetch fails with a durable error the web app's
        // own `refreshDiff` retry contract never automatically retries (`.invalidArgument`).
        content.dispatch(diffRequest(id: "req-2", scopeKind: "ref", refName: "typo-branch"))
        await gateway.waitForDiffCallCount(2)
        await gateway.failDiffCall(at: 1, error: SpacesDeviceClientError.requestRejected(message: "no such ref", code: .invalidArgument))

        // Return to scope A.
        content.dispatch(diffRequest(id: "req-3", scopeKind: "uncommitted"))
        await gateway.waitForDiffCallCount(3)
        await gateway.completeDiffCall(
            at: 2, result: SpacesDeviceWorkspaceDiffManifestChunkResult(manifestID: "test-manifest", scopeSignature: "sig-a2", files: []))
        await gateway.waitForSubscribeCallCount(2)

        let subscribeCount = await gateway.subscribeCallCount()
        #expect(subscribeCount == 2, "returning to A after B's failed fetch must open a FRESH subscription, not skip through a stale guard")

        // Prove the fresh subscription is actually live and forwarding, not just that a subscribe call
        // was made — mirrors `aFrameWithADifferentSignatureIsForwardedAndRecordedAsActedOn`'s check.
        await gateway.triggerFrame(at: 1, scopeSignature: "sig-a3")
        await waitUntil { !self.diffSignatureScripts(evaluator).isEmpty }
        #expect(diffSignatureScripts(evaluator).count == 1)
        #expect(diffSignatureScripts(evaluator)[0].contains("sig-a3"))
    }

    /// Proves the teardown is atomic with the generation bump, not merely inferred from a later
    /// resubscribe: A's stream handle is captured directly (via `holdNextSubscribeAttempts`, the same
    /// technique the stale-attempt tests above use) and its `stopCount` is checked immediately after
    /// dispatching B — BEFORE B's fetch even resolves — so this pins that the old stream is stopped at
    /// dispatch time, not merely as an eventual side effect of B's fetch failing.
    @Test func aScopeChangeStopsTheOldScopesStreamAtDispatchTimeRegardlessOfWhetherTheNewFetchSucceeds() async {
        let gateway = RecordingCodePaneDeviceGateway()
        let hosting = DeviceCodePaneHostingDouble(device: fakeDevice())
        let content = makeController(hosting: hosting, deviceGateway: gateway)
        content.activate(focus: false)
        content.scriptEvaluator = RecordingCodePaneScriptEvaluator()

        // Hold A's subscribe attempt so this test can capture its handle directly.
        await gateway.holdNextSubscribeAttempts(1)
        content.dispatch(diffRequest(id: "req-1", scopeKind: "uncommitted"))
        await gateway.waitForDiffCallCount(1)
        await gateway.completeDiffCall(
            at: 0, result: SpacesDeviceWorkspaceDiffManifestChunkResult(manifestID: "test-manifest", scopeSignature: "sig-a1", files: []))
        await gateway.waitForSubscribeAttemptCount(1)
        let handleA = await gateway.completeHeldSubscribeCall(at: 0)
        await gateway.waitForSubscribeCallCount(1)

        #expect(handleA.stopCount == 0, "the live A stream must not be stopped before anything invalidates it")

        // Navigate to scope B — do NOT resolve its fetch yet.
        content.dispatch(diffRequest(id: "req-2", scopeKind: "ref", refName: "typo-branch"))
        await gateway.waitForDiffCallCount(2)

        #expect(
            handleA.stopCount == 1,
            "the old A stream must be stopped at DISPATCH time (the generation bump site), before B's fetch has resolved at all")

        // Fail B's fetch for realism (matches the scenario the P1 report describes); the assertion
        // above already proved the teardown does not wait on this outcome.
        await gateway.failDiffCall(at: 1, error: SpacesDeviceClientError.requestRejected(message: "no such ref", code: .invalidArgument))
        await settle()

        #expect(handleA.stopCount == 1, "failing B's fetch must not stop A's already-stopped stream a second time")
    }

    /// Control: an ordinary same-scope refetch (the kind a `spaces:diffSignature` frame's `refreshDiff`
    /// triggers) must NOT trip the teardown this fix adds — the teardown rides the same
    /// `subscribedScope != .scope(refName)` condition the generation bump already used, which only
    /// trips for a genuine scope change. `aSameScopeRefetchDoesNotStaleTheLiveStreamsDisconnectHandler`
    /// above already pins that no second subscription opens on a same-scope refetch; this isolates the
    /// other half that test doesn't cover — that the live stream's handle isn't stopped either.
    @Test func aSameScopeRefetchDoesNotStopTheLiveStreamsHandle() async {
        let gateway = RecordingCodePaneDeviceGateway()
        let hosting = DeviceCodePaneHostingDouble(device: fakeDevice())
        let content = makeController(hosting: hosting, deviceGateway: gateway)
        content.activate(focus: false)
        content.scriptEvaluator = RecordingCodePaneScriptEvaluator()

        await gateway.holdNextSubscribeAttempts(1)
        content.dispatch(diffRequest(id: "req-1", scopeKind: "uncommitted"))
        await gateway.waitForDiffCallCount(1)
        await gateway.completeDiffCall(
            at: 0, result: SpacesDeviceWorkspaceDiffManifestChunkResult(manifestID: "test-manifest", scopeSignature: "sig-1", files: []))
        await gateway.waitForSubscribeAttemptCount(1)
        let handle = await gateway.completeHeldSubscribeCall(at: 0)
        await gateway.waitForSubscribeCallCount(1)

        content.dispatch(diffRequest(id: "req-2", scopeKind: "uncommitted"))
        await gateway.waitForDiffCallCount(2)
        await gateway.completeDiffCall(
            at: 1, result: SpacesDeviceWorkspaceDiffManifestChunkResult(manifestID: "test-manifest", scopeSignature: "sig-1", files: []))
        await settle()

        #expect(handle.stopCount == 0, "a same-scope refetch must not stop the live stream's handle")
        #expect(await gateway.subscribeCallCount() == 1, "a same-scope refetch must not open a second subscription")
    }

    // MARK: - "lastCommit" scope threading (committed-only diff)
    //
    // `DiffScope.lastCommit` and `.uncommitted` both resolve to a nil `refName` (see
    // `CodePaneBridge.refName(for:)`), so `lastCommit` must ride alongside `refName` as its own field on
    // `DiffSignatureScope`, not be inferred from it — otherwise the two scopes would be indistinguishable
    // to `resubscribeDiffSignature`'s equality guard and switching between them would never resubscribe.

    /// Pins that a `lastCommit` dispatch reaches both the `workspaceDiff` call and the subsequent
    /// `subscribeWorkspaceDiffSignature` call with `lastCommit: true` and a nil `refName`.
    @Test func lastCommitScopeThreadsLastCommitTrueToTheGatewayCallAndSubscription() async {
        let gateway = RecordingCodePaneDeviceGateway()
        let hosting = DeviceCodePaneHostingDouble(device: fakeDevice())
        let content = makeController(hosting: hosting, deviceGateway: gateway)
        content.activate(focus: false)
        content.scriptEvaluator = RecordingCodePaneScriptEvaluator()

        content.dispatch(diffRequest(id: "req-1", scopeKind: "lastCommit"))
        await gateway.waitForDiffCallCount(1)
        #expect(await gateway.diffCallLastCommit(at: 0), "a lastCommit-scoped dispatch must call workspaceDiff with lastCommit: true")

        await gateway.completeDiffCall(
            at: 0, result: SpacesDeviceWorkspaceDiffManifestChunkResult(manifestID: "test-manifest", scopeSignature: "sig-1", files: []))
        await gateway.waitForSubscribeCallCount(1)

        #expect(await gateway.subscribedRefName(at: 0) == nil, "lastCommit resolves to a nil refName, same as uncommitted")
        #expect(await gateway.subscribedLastCommit(at: 0), "the diff-signature subscription must also carry lastCommit: true")
    }

    /// Regression pin: `uncommitted` and `lastCommit` share a nil `refName`, so a naive scope-equality
    /// check keyed only on `refName` would treat switching between them as a same-scope refetch and
    /// never resubscribe. Asserts the opposite: it's treated as a genuine scope change.
    @Test func lastCommitScopeIsDistinctFromUncommittedDespiteBothHavingANilRefName() async {
        let gateway = RecordingCodePaneDeviceGateway()
        let hosting = DeviceCodePaneHostingDouble(device: fakeDevice())
        let content = makeController(hosting: hosting, deviceGateway: gateway)
        content.activate(focus: false)
        content.scriptEvaluator = RecordingCodePaneScriptEvaluator()

        content.dispatch(diffRequest(id: "req-1", scopeKind: "uncommitted"))
        await gateway.waitForDiffCallCount(1)
        await gateway.completeDiffCall(
            at: 0, result: SpacesDeviceWorkspaceDiffManifestChunkResult(manifestID: "test-manifest", scopeSignature: "sig-1", files: []))
        await gateway.waitForSubscribeCallCount(1)

        content.dispatch(diffRequest(id: "req-2", scopeKind: "lastCommit"))
        await gateway.waitForDiffCallCount(2)
        await gateway.completeDiffCall(
            at: 1, result: SpacesDeviceWorkspaceDiffManifestChunkResult(manifestID: "test-manifest", scopeSignature: "sig-2", files: []))
        await gateway.waitForSubscribeCallCount(2)

        #expect(await gateway.subscribeCallCount() == 2, "switching from uncommitted to lastCommit must open a fresh subscription")
        #expect(await gateway.subscribedLastCommit(at: 1), "the fresh subscription must be the lastCommit scope's")
    }

    // MARK: - performFileRead → resubscribeFileSignature wiring
    //
    // Mirrors the `performWorkspaceDiff` → `resubscribeDiffSignature` coverage above: a successful
    // `workspaceFileRead` (re)points the file-signature stream at the path just read, a stale (superseded)
    // completion must not retarget it, a disconnect schedules a bounded-backoff reconnect, and a forwarded
    // frame dedupes against the last value the web app is known to have (whether from a read or a frame).

    /// Isolates the `spaces:fileSignature` dispatch scripts out of `evaluator`'s full recording, the same
    /// way `diffSignatureScripts` isolates `spaces:diffSignature` ones.
    private func fileSignatureScripts(_ evaluator: RecordingCodePaneScriptEvaluator) -> [String] {
        evaluator.evaluatedScripts.filter { $0.contains("spaces:fileSignature") }
    }

    private func fileListSignatureScripts(_ evaluator: RecordingCodePaneScriptEvaluator) -> [String] {
        evaluator.evaluatedScripts.filter { $0.contains("spaces:fileListSignature") }
    }

    @Test func aSuccessfulFileReadResubscribesTheFileSignatureStreamAtThatPath() async {
        let gateway = RecordingCodePaneDeviceGateway()
        let hosting = DeviceCodePaneHostingDouble(device: fakeDevice())
        let content = makeController(hosting: hosting, deviceGateway: gateway)
        content.activate(focus: false)
        content.scriptEvaluator = RecordingCodePaneScriptEvaluator()

        content.dispatch(fileReadRequest(id: "req-1", path: "foo.ts"))
        await gateway.waitForFileReadCallCount(1)
        await gateway.completeFileReadCall(
            at: 0, result: SpacesDeviceWorkspaceFileReadResult(base64Data: "", sha256: "sha-1", size: 0, isBinaryGuess: false))

        await gateway.waitForFileSubscribeCallCount(1)
        let path = await gateway.subscribedFilePath(at: 0)
        #expect(path == "foo.ts")
    }

    @Test func anInlineDiffFileReadDoesNotRetargetTheEditorFileSignatureStream() async {
        let gateway = RecordingCodePaneDeviceGateway()
        let hosting = DeviceCodePaneHostingDouble(device: fakeDevice())
        let content = makeController(hosting: hosting, deviceGateway: gateway)
        content.activate(focus: false)

        content.dispatch(fileReadRequest(id: "req-1", path: "foo.ts"))
        await gateway.waitForFileReadCallCount(1)
        await gateway.completeFileReadCall(
            at: 0, result: SpacesDeviceWorkspaceFileReadResult(base64Data: "", sha256: "sha-a", size: 0, isBinaryGuess: false))
        await gateway.waitForFileSubscribeCallCount(1)

        content.dispatch(CodePaneBridge.Request(id: "req-2", method: "workspaceFileRead", params: ["path": "bar.ts", "purpose": "inlineDiff"]))
        await gateway.waitForFileReadCallCount(2)
        await gateway.completeFileReadCall(
            at: 1, result: SpacesDeviceWorkspaceFileReadResult(base64Data: "", sha256: "sha-b", size: 0, isBinaryGuess: false))
        await settle()

        #expect(await gateway.fileSubscribeCallCount() == 1, "an inline diff read must not replace the Editor's watcher")
        #expect(await gateway.subscribedFilePath(at: 0) == "foo.ts")
    }

    @Test func lateFileReadResponseDoesNotRetargetTheStreamToASupersededPath() async {
        let gateway = RecordingCodePaneDeviceGateway()
        let hosting = DeviceCodePaneHostingDouble(device: fakeDevice())
        let content = makeController(hosting: hosting, deviceGateway: gateway)
        content.activate(focus: false)
        content.scriptEvaluator = RecordingCodePaneScriptEvaluator()

        content.dispatch(fileReadRequest(id: "req-1", path: "foo.ts"))
        await gateway.waitForFileReadCallCount(1)
        content.dispatch(fileReadRequest(id: "req-2", path: "bar.ts"))
        await gateway.waitForFileReadCallCount(2)

        // Complete the SECOND (later) path first, then the FIRST (now-superseded) path last.
        await gateway.completeFileReadCall(
            at: 1, result: SpacesDeviceWorkspaceFileReadResult(base64Data: "", sha256: "sha-b", size: 0, isBinaryGuess: false))
        await gateway.waitForFileSubscribeCallCount(1)
        await gateway.completeFileReadCall(
            at: 0, result: SpacesDeviceWorkspaceFileReadResult(base64Data: "", sha256: "sha-a", size: 0, isBinaryGuess: false))
        await settle()

        let subscribeCount = await gateway.fileSubscribeCallCount()
        #expect(subscribeCount == 1, "only the second (still-current) path's completion should have triggered a resubscribe")
        let path = await gateway.subscribedFilePath(at: 0)
        #expect(path == "bar.ts", "the subscription must target the later path, not the superseded first one")
    }

    // The two tests below cover the "reread-of-the-still-open-file races a navigation" interleaving
    // Unlike `lateFileReadResponseDoesNotRetargetTheStreamToASupersededPath`,
    // above (two NAVIGATIONS, B then C — both bump the request token), here only ONE of the two
    // in-flight reads is a navigation; the other is a same-path reread of the file the pane already
    // has open (`EditorView.handleExternalChange`'s live-reload re-read, triggered by A's own
    // still-live file-signature stream while B's slower open is in flight). Before this fix, a single
    // `latestFileReadRequestToken` guard could not tell "a same-path reread happened to be dispatched
    // after the navigation" apart from "a second navigation superseded the first" — it always favored
    // whichever read was dispatched LAST, which is always the reread (the web app only re-reads the
    // path it's currently showing, so a reread can only ever be dispatched after whatever navigation
    // most recently changed `subscribedFilePath`) — stranding the file-signature stream on the stale
    // path regardless of completion order. `latestFileNavigationToken` fixes this by only letting
    // navigations compete for "latest wins"; a reread instead only checks it's still looking at the
    // currently-subscribed path.

    /// Interleaving (a) from the success-arm guard's doc comment: B's navigation resolves first (the
    /// reply reaches JS, which navigates the pane to B), then A's now-stale reread resolves last and
    /// must be skipped rather than stealing the subscription back to A — this is the exact ordering
    /// `restoreFileSignatureMonitoringAfterFailedOpen`'s doc comment traces
    /// as silently killing external-change monitoring for B under the old single-token guard.
    @Test func bsNavigationCompletingBeforeAsStaleRereadLeavesTheSubscriptionOnB() async {
        let gateway = RecordingCodePaneDeviceGateway()
        let hosting = DeviceCodePaneHostingDouble(device: fakeDevice())
        let content = makeController(hosting: hosting, deviceGateway: gateway)
        content.activate(focus: false)
        content.scriptEvaluator = RecordingCodePaneScriptEvaluator()

        // Open A ("foo.ts"): ends up subscribed to A.
        content.dispatch(fileReadRequest(id: "req-1", path: "foo.ts"))
        await gateway.waitForFileReadCallCount(1)
        await gateway.completeFileReadCall(
            at: 0, result: SpacesDeviceWorkspaceFileReadResult(base64Data: "", sha256: "sha-a1", size: 0, isBinaryGuess: false))
        await gateway.waitForFileSubscribeCallCount(1)
        #expect(await gateway.subscribedFilePath(at: 0) == "foo.ts")

        // Start opening B ("bar.ts") — its read is deliberately held, simulating a slow open.
        content.dispatch(fileReadRequest(id: "req-2", path: "bar.ts"))
        await gateway.waitForFileReadCallCount(2)

        // While B is still pending, A's still-live file-signature stream would trigger the web app to
        // re-read the file it currently shows (still A at this point) — dispatched with
        // `pathChanged == false` since `subscribedFilePath` is still "foo.ts".
        content.dispatch(fileReadRequest(id: "req-3", path: "foo.ts"))
        await gateway.waitForFileReadCallCount(3)

        // B's (the navigation's) underlying read resolves FIRST.
        await gateway.completeFileReadCall(
            at: 1, result: SpacesDeviceWorkspaceFileReadResult(base64Data: "", sha256: "sha-b", size: 0, isBinaryGuess: false))
        await gateway.waitForFileSubscribeCallCount(2)
        #expect(await gateway.subscribedFilePath(at: 1) == "bar.ts", "B's navigation must resubscribe the stream to bar.ts")

        // A's stale reread resolves last — it must be skipped (`subscribedFilePath` is now "bar.ts",
        // not the "foo.ts" it read), not steal the subscription back to A.
        await gateway.completeFileReadCall(
            at: 2, result: SpacesDeviceWorkspaceFileReadResult(base64Data: "", sha256: "sha-a2", size: 0, isBinaryGuess: false))
        await settle()

        #expect(await gateway.fileSubscribeCallCount() == 2, "A's stale reread must not install a third subscription")
        #expect(await gateway.subscribedFilePath(at: 1) == "bar.ts", "the subscription must still target B after A's stale reread completes")
    }

    /// Interleaving (b): A's reread resolves FIRST this time, while `subscribedFilePath` is still
    /// "foo.ts" (B hasn't navigated yet) — its guard passes, but the `resubscribeFileSignature` call it
    /// triggers is a no-op (already subscribed to "foo.ts"), so it must not disturb anything. B's
    /// navigation then resolves and resubscribes normally, exactly as if the reread had never happened.
    @Test func aStaleSamePathRereadCompletingBeforeTheNavigationIsANoOpRefresh() async {
        let gateway = RecordingCodePaneDeviceGateway()
        let hosting = DeviceCodePaneHostingDouble(device: fakeDevice())
        let content = makeController(hosting: hosting, deviceGateway: gateway)
        content.activate(focus: false)
        content.scriptEvaluator = RecordingCodePaneScriptEvaluator()

        content.dispatch(fileReadRequest(id: "req-1", path: "foo.ts"))
        await gateway.waitForFileReadCallCount(1)
        await gateway.completeFileReadCall(
            at: 0, result: SpacesDeviceWorkspaceFileReadResult(base64Data: "", sha256: "sha-a1", size: 0, isBinaryGuess: false))
        await gateway.waitForFileSubscribeCallCount(1)

        content.dispatch(fileReadRequest(id: "req-2", path: "bar.ts"))
        await gateway.waitForFileReadCallCount(2)
        content.dispatch(fileReadRequest(id: "req-3", path: "foo.ts"))
        await gateway.waitForFileReadCallCount(3)

        // A's reread resolves FIRST, while it's still the current/subscribed path.
        await gateway.completeFileReadCall(
            at: 2, result: SpacesDeviceWorkspaceFileReadResult(base64Data: "", sha256: "sha-a2", size: 0, isBinaryGuess: false))
        await settle()
        #expect(
            await gateway.fileSubscribeCallCount() == 1,
            "A's same-path reread, still current when it completed, must behave as a no-op baseline refresh, not a fresh subscribe")
        #expect(await gateway.subscribedFilePath(at: 0) == "foo.ts", "the existing subscription to A must be untouched")

        // B's navigation resolves after — it still resubscribes normally, unaffected by A's earlier
        // no-op refresh.
        await gateway.completeFileReadCall(
            at: 1, result: SpacesDeviceWorkspaceFileReadResult(base64Data: "", sha256: "sha-b", size: 0, isBinaryGuess: false))
        await gateway.waitForFileSubscribeCallCount(2)
        #expect(await gateway.subscribedFilePath(at: 1) == "bar.ts", "B's navigation must still resubscribe to bar.ts after A's no-op refresh")
    }

    @Test func disconnectOnTheFileSignatureStreamSchedulesABackoffRetryThatResubscribesTheSamePath() async {
        let gateway = RecordingCodePaneDeviceGateway()
        let hosting = DeviceCodePaneHostingDouble(device: fakeDevice())
        let content = makeController(hosting: hosting, deviceGateway: gateway)
        content.fileSignatureReconnectFloor = .milliseconds(20)
        content.fileSignatureReconnectCap = .milliseconds(20)
        content.activate(focus: false)
        content.scriptEvaluator = RecordingCodePaneScriptEvaluator()

        content.dispatch(fileReadRequest(id: "req-1", path: "foo.ts"))
        await gateway.waitForFileReadCallCount(1)
        await gateway.completeFileReadCall(
            at: 0, result: SpacesDeviceWorkspaceFileReadResult(base64Data: "", sha256: "sha-1", size: 0, isBinaryGuess: false))
        await gateway.waitForFileSubscribeCallCount(1)

        await gateway.triggerFileDisconnect(at: 0)
        await gateway.waitForFileSubscribeCallCount(2)

        let subscribeCount = await gateway.fileSubscribeCallCount()
        #expect(subscribeCount == 2, "a disconnect must schedule a backoff retry that resubscribes the same path")
        let path = await gateway.subscribedFilePath(at: 1)
        #expect(path == "foo.ts")
    }

    @Test func aConnectFrameRepeatingTheJustReadFilesSignatureIsSuppressed() async {
        let gateway = RecordingCodePaneDeviceGateway()
        let hosting = DeviceCodePaneHostingDouble(device: fakeDevice())
        let content = makeController(hosting: hosting, deviceGateway: gateway)
        content.activate(focus: false)
        let evaluator = RecordingCodePaneScriptEvaluator()
        content.scriptEvaluator = evaluator
        content.handleReady()

        content.dispatch(fileReadRequest(id: "req-1", path: "foo.ts"))
        await gateway.waitForFileReadCallCount(1)
        await gateway.completeFileReadCall(
            at: 0, result: SpacesDeviceWorkspaceFileReadResult(base64Data: "", sha256: "sha-1", size: 0, isBinaryGuess: false))
        await gateway.waitForFileSubscribeCallCount(1)

        // The stream's connect-time frame repeats exactly the (sha256, missing) pair `performFileRead`
        // just recorded as read — the web app already has this content, so it must not be forwarded.
        await gateway.triggerFileFrame(at: 0, path: "foo.ts", sha256: "sha-1", missing: false)
        await settle()

        #expect(fileSignatureScripts(evaluator).isEmpty, "a frame repeating the just-read file's own signature must not be forwarded")
    }

    @Test func aFrameWithADifferentFileSignatureIsForwardedAndRecordedAsActedOn() async {
        let gateway = RecordingCodePaneDeviceGateway()
        let hosting = DeviceCodePaneHostingDouble(device: fakeDevice())
        let content = makeController(hosting: hosting, deviceGateway: gateway)
        content.activate(focus: false)
        let evaluator = RecordingCodePaneScriptEvaluator()
        content.scriptEvaluator = evaluator
        content.handleReady()

        content.dispatch(fileReadRequest(id: "req-1", path: "foo.ts"))
        await gateway.waitForFileReadCallCount(1)
        await gateway.completeFileReadCall(
            at: 0, result: SpacesDeviceWorkspaceFileReadResult(base64Data: "", sha256: "sha-1", size: 0, isBinaryGuess: false))
        await gateway.waitForFileSubscribeCallCount(1)

        await gateway.triggerFileFrame(at: 0, path: "foo.ts", sha256: "sha-2", missing: false)
        await waitUntil { !self.fileSignatureScripts(evaluator).isEmpty }

        #expect(fileSignatureScripts(evaluator).count == 1)
        #expect(fileSignatureScripts(evaluator)[0].contains("sha-2"))

        // Repeating the now-acted-on signature must in turn go quiet.
        await gateway.triggerFileFrame(at: 0, path: "foo.ts", sha256: "sha-2", missing: false)
        await settle()
        #expect(fileSignatureScripts(evaluator).count == 1, "a repeat of the signature just forwarded must not forward again")
    }

    @Test func aMissingFileFrameIsForwardedWithNoSha256() async {
        let gateway = RecordingCodePaneDeviceGateway()
        let hosting = DeviceCodePaneHostingDouble(device: fakeDevice())
        let content = makeController(hosting: hosting, deviceGateway: gateway)
        content.activate(focus: false)
        let evaluator = RecordingCodePaneScriptEvaluator()
        content.scriptEvaluator = evaluator
        content.handleReady()

        content.dispatch(fileReadRequest(id: "req-1", path: "foo.ts"))
        await gateway.waitForFileReadCallCount(1)
        await gateway.completeFileReadCall(
            at: 0, result: SpacesDeviceWorkspaceFileReadResult(base64Data: "", sha256: "sha-1", size: 0, isBinaryGuess: false))
        await gateway.waitForFileSubscribeCallCount(1)

        // The file is deleted out from under the open editor: the daemon reports `missing: true` with no
        // `sha256` (see `SpacesDeviceWorkspaceFileSignatureFrame`'s doc comment).
        await gateway.triggerFileFrame(at: 0, path: "foo.ts", sha256: nil, missing: true)
        await waitUntil { !self.fileSignatureScripts(evaluator).isEmpty }

        #expect(fileSignatureScripts(evaluator).count == 1)
        #expect(fileSignatureScripts(evaluator)[0].contains("\"missing\":true"))
    }

    /// A frame delivered through a SUPERSEDED subscription's captured `onFrame` handler must not touch
    /// `lastActedFileSignatureValue` at all: `client.stop()` (called when retargeting from A to B) can't
    /// retract a frame already queued as a `Task { @MainActor in ... }` closure, so a stale "missing"
    /// frame left in flight from A's now-dead stream would otherwise poison the dedupe state with
    /// `(sha256: nil, missing: true)` — the SAME value every path's missing-frame carries — and suppress
    /// B's later REAL deletion frame as a spurious duplicate. Without the `fileSignatureSubscriptionGeneration`
    /// guard in `onFrame`, this test fails: B's deletion event never reaches the web app.
    @Test func aStaleFrameFromASupersededFileSubscriptionDoesNotPoisonDedupeForTheCurrentFile() async {
        let gateway = RecordingCodePaneDeviceGateway()
        let hosting = DeviceCodePaneHostingDouble(device: fakeDevice())
        let content = makeController(hosting: hosting, deviceGateway: gateway)
        content.activate(focus: false)
        let evaluator = RecordingCodePaneScriptEvaluator()
        content.scriptEvaluator = evaluator
        content.handleReady()

        // Open A ("foo.ts"): captures handler 0 (subscribe-call arrival index 0).
        content.dispatch(fileReadRequest(id: "req-1", path: "foo.ts"))
        await gateway.waitForFileReadCallCount(1)
        await gateway.completeFileReadCall(
            at: 0, result: SpacesDeviceWorkspaceFileReadResult(base64Data: "", sha256: "sha-a", size: 0, isBinaryGuess: false))
        await gateway.waitForFileSubscribeCallCount(1)

        // Open B ("bar.ts"): retargets — A's stream is stopped (but its captured handler 0 remains
        // callable directly, standing in for a frame already in flight when `stop()` was called) — and a
        // new subscription captures handler 1 (arrival index 1).
        content.dispatch(fileReadRequest(id: "req-2", path: "bar.ts"))
        await gateway.waitForFileReadCallCount(2)
        await gateway.completeFileReadCall(
            at: 1, result: SpacesDeviceWorkspaceFileReadResult(base64Data: "", sha256: "sha-b", size: 0, isBinaryGuess: false))
        await gateway.waitForFileSubscribeCallCount(2)

        // A's stale "missing" frame arrives late through the superseded handler 0. With the generation
        // guard in place this must be a complete no-op: no event dispatched, no dedupe state touched.
        await gateway.triggerFileFrame(at: 0, path: "foo.ts", sha256: nil, missing: true)
        await settle()
        #expect(fileSignatureScripts(evaluator).isEmpty, "a stale frame from a superseded subscription must not be forwarded")

        // B's REAL deletion frame arrives through the current handler 1. This must be forwarded — if
        // A's stale frame above had wrongly recorded `(nil, true)` into `lastActedFileSignatureValue`,
        // this identical-valued frame for B would be suppressed as a duplicate.
        await gateway.triggerFileFrame(at: 1, path: "bar.ts", sha256: nil, missing: true)
        await waitUntil { !self.fileSignatureScripts(evaluator).isEmpty }

        #expect(fileSignatureScripts(evaluator).count == 1, "B's real deletion frame must not be suppressed as a duplicate of A's stale frame")
        #expect(
            fileSignatureScripts(evaluator)[0].contains(#""path":"bar.ts""#),
            "the one forwarded event must be B's deletion, not a wrongly-forwarded stale event for A")
        #expect(fileSignatureScripts(evaluator)[0].contains("\"missing\":true"))
    }

    @Test func aFileReadCompletionAfterDeactivateNeverResubscribesTheFileSignatureStream() async {
        let gateway = RecordingCodePaneDeviceGateway()
        let hosting = DeviceCodePaneHostingDouble(device: fakeDevice())
        let content = makeController(hosting: hosting, deviceGateway: gateway)
        content.activate(focus: false)
        content.scriptEvaluator = RecordingCodePaneScriptEvaluator()

        content.dispatch(fileReadRequest(id: "req-1", path: "foo.ts"))
        await gateway.waitForFileReadCallCount(1)

        // Hibernate before the read completes.
        content.deactivate()
        await gateway.completeFileReadCall(
            at: 0, result: SpacesDeviceWorkspaceFileReadResult(base64Data: "", sha256: "sha-1", size: 0, isBinaryGuess: false))
        await settle()

        let subscribeCount = await gateway.fileSubscribeCallCount()
        #expect(subscribeCount == 0, "a workspaceFileRead completion after deactivate must never resubscribe the stream")
    }

    // MARK: - Restoring the previous file's monitoring after a failed open
    //
    // `performFileRead`'s dispatch-time generation bump only fires when the dispatched path differs from
    // what's currently subscribed — the same shape as `performWorkspaceDiff`'s scope-change bump. Unlike
    // diff (which accepts a disconnect-during-the-fetch-window edge, since the web app's own bounded-backoff
    // `refreshDiff` retry self-heals it — see the comment in `performWorkspaceDiff`), a failed open here must
    // proactively restore the previous path's monitoring: the editor has no equivalent retry loop, so
    // nothing else would ever re-arm it.

    /// Opening a second file while the first is still live and successfully monitored, then having that
    /// second open fail, must not strand the first file's monitoring — and the restored subscription must
    /// be reachable by the normal reconnect path afterward, not some inert leftover.
    @Test func aFailedFileOpenRestoresThePreviousPathsFileSignatureMonitoring() async {
        let gateway = RecordingCodePaneDeviceGateway()
        let hosting = DeviceCodePaneHostingDouble(device: fakeDevice())
        let content = makeController(hosting: hosting, deviceGateway: gateway)
        content.fileSignatureReconnectFloor = .milliseconds(20)
        content.fileSignatureReconnectCap = .milliseconds(20)
        content.activate(focus: false)
        content.scriptEvaluator = RecordingCodePaneScriptEvaluator()

        content.dispatch(fileReadRequest(id: "req-1", path: "foo.ts"))
        await gateway.waitForFileReadCallCount(1)
        await gateway.completeFileReadCall(
            at: 0, result: SpacesDeviceWorkspaceFileReadResult(base64Data: "", sha256: "sha-1", size: 0, isBinaryGuess: false))
        await gateway.waitForFileSubscribeCallCount(1)

        struct InjectedFileReadFailure: Error {}
        content.dispatch(fileReadRequest(id: "req-2", path: "bar.ts"))
        await gateway.waitForFileReadCallCount(2)
        await gateway.failFileReadCall(at: 1, error: InjectedFileReadFailure())

        await gateway.waitForFileSubscribeCallCount(2)
        let restoredPath = await gateway.subscribedFilePath(at: 1)
        #expect(restoredPath == "foo.ts", "the failed open must restore monitoring for the still-displayed previous file")

        // The restored subscription must be current-generation, not a stale leftover: a real disconnect on
        // it must still schedule the normal backoff reconnect, proving `handleFileSignatureDisconnect`
        // recognizes it rather than silently dropping it as belonging to an old, superseded generation.
        await gateway.triggerFileDisconnect(at: 1)
        await gateway.waitForFileSubscribeCallCount(3)

        let reconnectedPath = await gateway.subscribedFilePath(at: 2)
        #expect(reconnectedPath == "foo.ts", "the restored subscription must still be reachable by the normal reconnect path")
    }

    /// The stranding this guards is worse when the first file's stream had already disconnected and was
    /// sitting in a pending backoff retry: a failed second open must still bring it back with a fresh,
    /// deliberate resubscribe rather than leaving it to the stale (and now-superseded) pending retry, which
    /// this test proves never fires on top of the restore.
    @Test func aFailedFileOpenRestoresMonitoringForAPathThatWasMidBackoff() async {
        let gateway = RecordingCodePaneDeviceGateway()
        let hosting = DeviceCodePaneHostingDouble(device: fakeDevice())
        let content = makeController(hosting: hosting, deviceGateway: gateway)
        content.fileSignatureReconnectFloor = .milliseconds(150)
        content.fileSignatureReconnectCap = .milliseconds(150)
        content.activate(focus: false)
        content.scriptEvaluator = RecordingCodePaneScriptEvaluator()

        content.dispatch(fileReadRequest(id: "req-1", path: "foo.ts"))
        await gateway.waitForFileReadCallCount(1)
        await gateway.completeFileReadCall(
            at: 0, result: SpacesDeviceWorkspaceFileReadResult(base64Data: "", sha256: "sha-1", size: 0, isBinaryGuess: false))
        await gateway.waitForFileSubscribeCallCount(1)

        // Drop the first path's stream and let it enter its pending-retry backoff window, without waiting
        // for that retry to fire.
        await gateway.triggerFileDisconnect(at: 0)
        await settle(.milliseconds(50))  // let the disconnect handler run and schedule the retry's sleep

        struct InjectedFileReadFailure: Error {}
        content.dispatch(fileReadRequest(id: "req-2", path: "bar.ts"))
        await gateway.waitForFileReadCallCount(2)
        await gateway.failFileReadCall(at: 1, error: InjectedFileReadFailure())

        // A fresh, deliberate resubscribe for the first path must happen here rather than relying on the
        // still-pending (and now-superseded) backoff retry to eventually fire on its own.
        await gateway.waitForFileSubscribeCallCount(2)
        let restoredPath = await gateway.subscribedFilePath(at: 1)
        #expect(restoredPath == "foo.ts")

        // Wait well past the original 150ms backoff floor: the stale retry (still captured against the
        // now-superseded generation) must not also fire and produce a second, redundant subscribe.
        await settle(.milliseconds(300))
        let subscribeCount = await gateway.fileSubscribeCallCount()
        #expect(subscribeCount == 2, "the superseded backoff retry must not also resubscribe on top of the deliberate restore")
    }

    /// The restore must not reach backward past whoever currently owns the subscription state: if a THIRD
    /// path is opened (and succeeds) before the second path's failing open resolves, the failure belongs to
    /// an already-superseded generation and must not undo the third path's subscription.
    @Test func aStaleFailedOpenDoesNotRestoreOverANewerPathThatAlreadyTookOver() async {
        let gateway = RecordingCodePaneDeviceGateway()
        let hosting = DeviceCodePaneHostingDouble(device: fakeDevice())
        let content = makeController(hosting: hosting, deviceGateway: gateway)
        content.activate(focus: false)
        content.scriptEvaluator = RecordingCodePaneScriptEvaluator()

        content.dispatch(fileReadRequest(id: "req-1", path: "foo.ts"))
        await gateway.waitForFileReadCallCount(1)
        await gateway.completeFileReadCall(
            at: 0, result: SpacesDeviceWorkspaceFileReadResult(base64Data: "", sha256: "sha-1", size: 0, isBinaryGuess: false))
        await gateway.waitForFileSubscribeCallCount(1)

        // Open a second path and leave its read pending (it will fail later, after the third path below
        // has already taken over).
        content.dispatch(fileReadRequest(id: "req-2", path: "bar.ts"))
        await gateway.waitForFileReadCallCount(2)

        // A third path is opened and succeeds while the second path's read is still pending.
        struct InjectedFileReadFailure: Error {}
        content.dispatch(fileReadRequest(id: "req-3", path: "baz.ts"))
        await gateway.waitForFileReadCallCount(3)
        await gateway.completeFileReadCall(
            at: 2, result: SpacesDeviceWorkspaceFileReadResult(base64Data: "", sha256: "sha-3", size: 0, isBinaryGuess: false))
        await gateway.waitForFileSubscribeCallCount(2)

        // Now the second path's read fails. Its `restoreFileSignatureMonitoringAfterFailedOpen` call
        // captured the generation as of ITS OWN dispatch, which the third path's successful open has since
        // moved past — this failure must find itself stale and do nothing.
        await gateway.failFileReadCall(at: 1, error: InjectedFileReadFailure())
        await settle()

        let subscribeCount = await gateway.fileSubscribeCallCount()
        #expect(subscribeCount == 2, "a stale failed open must not resubscribe the first path over a newer path that already took over")
        let currentPath = await gateway.subscribedFilePath(at: 1)
        #expect(currentPath == "baz.ts", "the third (current) path must remain the one subscribed")
    }

    // MARK: - notFound rehydration read still installs a file-signature stream
    //
    // Hibernation teardown (`teardownWebView`) clears `lastActedFilePath`/`subscribedFilePath`
    // unconditionally, so a rehydration reconcile read (the web side's `restoreState` firing
    // `handleExternalChange`) always dispatches with nothing to restore. If that read's daemon answer
    // is the authoritative notFound (the file was deleted during hibernation), a stream must still be
    // installed for the requested path — otherwise the web side's deleted-file state has no live
    // signal to ever recover from.

    /// Simulates hibernation by deactivating (which tears down monitoring state) and reactivating, then
    /// dispatches the rehydration reconcile read for the same path that failed notFound.
    @Test func aNotFoundRehydrationReadAfterTeardownInstallsAFileSignatureSubscriptionForTheRequestedPath() async {
        let gateway = RecordingCodePaneDeviceGateway()
        let hosting = DeviceCodePaneHostingDouble(device: fakeDevice())
        let content = makeController(hosting: hosting, deviceGateway: gateway)
        content.activate(focus: false)
        content.scriptEvaluator = RecordingCodePaneScriptEvaluator()

        content.dispatch(fileReadRequest(id: "req-1", path: "foo.ts"))
        await gateway.waitForFileReadCallCount(1)
        await gateway.completeFileReadCall(
            at: 0, result: SpacesDeviceWorkspaceFileReadResult(base64Data: "", sha256: "sha-1", size: 0, isBinaryGuess: false))
        await gateway.waitForFileSubscribeCallCount(1)

        // Hibernate: teardown clears `lastActedFilePath`/`subscribedFilePath` unconditionally, so the
        // pane's very first read after rehydrating always finds nothing to restore.
        content.deactivate()
        content.activate(focus: false)
        content.scriptEvaluator = RecordingCodePaneScriptEvaluator()

        // The web side's `restoreState` reconcile read for the file, which was deleted while hibernating.
        content.dispatch(fileReadRequest(id: "req-2", path: "foo.ts"))
        await gateway.waitForFileReadCallCount(2)
        await gateway.failFileReadCall(at: 1, error: SpacesDeviceClientError.requestRejected(message: "foo.ts is gone", code: .notFound))

        await gateway.waitForFileSubscribeCallCount(2)
        let subscribedPath = await gateway.subscribedFilePath(at: 1)
        #expect(subscribedPath == "foo.ts", "a notFound rehydration read must still install a file-signature subscription for the requested path")
    }

    /// A transport-shaped failure (not the daemon's authoritative notFound) is not a durable answer
    /// about the path — the web side's own bounded-backoff retry owns recovering it, so the host must
    /// not install a subscription here.
    @Test func aTransportShapedRehydrationReadFailureDoesNotInstallAFileSignatureSubscription() async {
        let gateway = RecordingCodePaneDeviceGateway()
        let hosting = DeviceCodePaneHostingDouble(device: fakeDevice())
        let content = makeController(hosting: hosting, deviceGateway: gateway)
        content.activate(focus: false)
        content.scriptEvaluator = RecordingCodePaneScriptEvaluator()

        content.dispatch(fileReadRequest(id: "req-1", path: "foo.ts"))
        await gateway.waitForFileReadCallCount(1)
        await gateway.completeFileReadCall(
            at: 0, result: SpacesDeviceWorkspaceFileReadResult(base64Data: "", sha256: "sha-1", size: 0, isBinaryGuess: false))
        await gateway.waitForFileSubscribeCallCount(1)

        content.deactivate()
        content.activate(focus: false)
        content.scriptEvaluator = RecordingCodePaneScriptEvaluator()

        struct InjectedTransportFailure: Error {}
        content.dispatch(fileReadRequest(id: "req-2", path: "foo.ts"))
        await gateway.waitForFileReadCallCount(2)
        await gateway.failFileReadCall(at: 1, error: InjectedTransportFailure())
        await settle()

        let subscribeCount = await gateway.fileSubscribeCallCount()
        #expect(subscribeCount == 1, "a transport-shaped rehydration read failure must not install a subscription")
    }

    /// Mirrors `aNotFoundRehydrationReadAfterTeardownInstallsAFileSignatureSubscriptionForTheRequestedPath`
    /// exactly, but for the bridge's `.invalidArgument` code: the daemon's own `invalidArgument` (a path
    /// replaced by a non-regular file) and `payloadTooLarge` (a file that grew past 10 MiB during
    /// hibernation) both collapse into this bridge code (see `CodePaneBridge.bridgeErrorCode`), and both
    /// are — like `.notFound` — an authoritative per-file answer that the web side's typed-error retry
    /// contract never auto-retries, so a subscription must be installed here too.
    @Test func anInvalidArgumentRehydrationReadAfterTeardownInstallsAFileSignatureSubscriptionForTheRequestedPath() async {
        let gateway = RecordingCodePaneDeviceGateway()
        let hosting = DeviceCodePaneHostingDouble(device: fakeDevice())
        let content = makeController(hosting: hosting, deviceGateway: gateway)
        content.activate(focus: false)
        content.scriptEvaluator = RecordingCodePaneScriptEvaluator()

        content.dispatch(fileReadRequest(id: "req-1", path: "foo.ts"))
        await gateway.waitForFileReadCallCount(1)
        await gateway.completeFileReadCall(
            at: 0, result: SpacesDeviceWorkspaceFileReadResult(base64Data: "", sha256: "sha-1", size: 0, isBinaryGuess: false))
        await gateway.waitForFileSubscribeCallCount(1)

        // Hibernate: teardown clears `lastActedFilePath`/`subscribedFilePath` unconditionally, so the
        // pane's very first read after rehydrating always finds nothing to restore.
        content.deactivate()
        content.activate(focus: false)
        content.scriptEvaluator = RecordingCodePaneScriptEvaluator()

        // The web side's `restoreState` reconcile read for the file, which grew past 10 MiB (or was
        // replaced by a non-regular file) while hibernating — the daemon rejects the read outright.
        content.dispatch(fileReadRequest(id: "req-2", path: "foo.ts"))
        await gateway.waitForFileReadCallCount(2)
        await gateway.failFileReadCall(at: 1, error: SpacesDeviceClientError.requestRejected(message: "foo.ts is too large", code: .payloadTooLarge))

        await gateway.waitForFileSubscribeCallCount(2)
        let subscribedPath = await gateway.subscribedFilePath(at: 1)
        #expect(
            subscribedPath == "foo.ts",
            "an invalidArgument-bridged rehydration read must still install a file-signature subscription for the requested path")
    }

    /// Control for the `.invalidArgument` case above: a daemon-typed but transport-shaped code (the
    /// device/session/service not presently reachable — `SpacesDeviceErrorCode.serviceNotRunning`, which
    /// `CodePaneBridge.bridgeErrorCode` maps to the bridge's `.unavailable`) is not an authoritative
    /// answer about the file itself — the daemon may not have even examined the path — so it must stay
    /// excluded from the recovery guard, same as the untyped-error case
    /// `aTransportShapedRehydrationReadFailureDoesNotInstallAFileSignatureSubscription` already covers.
    @Test func anUnavailableRehydrationReadFailureDoesNotInstallAFileSignatureSubscription() async {
        let gateway = RecordingCodePaneDeviceGateway()
        let hosting = DeviceCodePaneHostingDouble(device: fakeDevice())
        let content = makeController(hosting: hosting, deviceGateway: gateway)
        content.activate(focus: false)
        content.scriptEvaluator = RecordingCodePaneScriptEvaluator()

        content.dispatch(fileReadRequest(id: "req-1", path: "foo.ts"))
        await gateway.waitForFileReadCallCount(1)
        await gateway.completeFileReadCall(
            at: 0, result: SpacesDeviceWorkspaceFileReadResult(base64Data: "", sha256: "sha-1", size: 0, isBinaryGuess: false))
        await gateway.waitForFileSubscribeCallCount(1)

        content.deactivate()
        content.activate(focus: false)
        content.scriptEvaluator = RecordingCodePaneScriptEvaluator()

        content.dispatch(fileReadRequest(id: "req-2", path: "foo.ts"))
        await gateway.waitForFileReadCallCount(2)
        await gateway.failFileReadCall(at: 1, error: SpacesDeviceClientError.requestRejected(message: "device unavailable", code: .serviceNotRunning))
        await settle()

        let subscribeCount = await gateway.fileSubscribeCallCount()
        #expect(subscribeCount == 1, "an unavailable-shaped rehydration read failure must not install a subscription")
    }

    /// A file already open and monitored in a visible (non-hibernating) pane whose disk copy is
    /// deleted re-reads the SAME path (the web side's `handleExternalChange` reacting to a live
    /// `spaces:fileSignature` push) — `pathChanged` is false for this dispatch, so the existing healthy
    /// stream must not be torn down and reopened.
    @Test func aLiveVisiblePaneDeletionNotFoundDoesNotChurnTheExistingStream() async {
        let gateway = RecordingCodePaneDeviceGateway()
        let hosting = DeviceCodePaneHostingDouble(device: fakeDevice())
        let content = makeController(hosting: hosting, deviceGateway: gateway)
        content.activate(focus: false)
        content.scriptEvaluator = RecordingCodePaneScriptEvaluator()

        content.dispatch(fileReadRequest(id: "req-1", path: "foo.ts"))
        await gateway.waitForFileReadCallCount(1)
        await gateway.completeFileReadCall(
            at: 0, result: SpacesDeviceWorkspaceFileReadResult(base64Data: "", sha256: "sha-1", size: 0, isBinaryGuess: false))
        await gateway.waitForFileSubscribeCallCount(1)

        content.dispatch(fileReadRequest(id: "req-2", path: "foo.ts"))
        await gateway.waitForFileReadCallCount(2)
        await gateway.failFileReadCall(at: 1, error: SpacesDeviceClientError.requestRejected(message: "foo.ts is gone", code: .notFound))
        await settle()

        let subscribeCount = await gateway.fileSubscribeCallCount()
        #expect(subscribeCount == 1, "a notFound re-read of the already-subscribed path must not resubscribe or churn the existing stream")
    }

    // MARK: - performFileList → resubscribeWorkspaceFileListSignature wiring

    @Test func aSuccessfulWorkspaceFileListSubscribesTheWorkspaceFileListSignatureStream() async {
        let gateway = RecordingCodePaneDeviceGateway()
        let hosting = DeviceCodePaneHostingDouble(device: fakeDevice())
        let content = makeController(hosting: hosting, deviceGateway: gateway)
        content.activate(focus: false)
        content.scriptEvaluator = RecordingCodePaneScriptEvaluator()

        await gateway.setFileListResult(.success(.init(paths: ["a.ts"], truncated: false)))
        content.dispatch(.init(id: "req-1", method: "workspaceFileList", params: [:]))
        await gateway.waitForFileListSignatureSubscribeCount(1)

        #expect(await gateway.fileListCalls == ["workspace-1"])
        #expect(await gateway.subscribedFileListSignatureCallCount() == 1)
    }

    @Test func aWorkspaceFileListCompletionFromABlankedPageLifeNeverSubscribesANewerPage() async {
        let gateway = RecordingCodePaneDeviceGateway()
        let hosting = DeviceCodePaneHostingDouble(device: fakeDevice())
        let content = makeController(hosting: hosting, deviceGateway: gateway)
        content.activate(focus: false)
        content.scriptEvaluator = RecordingCodePaneScriptEvaluator()

        await gateway.holdNextFileListCalls(1)
        content.dispatch(.init(id: "req-1", method: "workspaceFileList", params: [:]))
        await gateway.waitForFileListCallCount(1)

        content.deactivate()
        content.activate(focus: false)
        content.scriptEvaluator = RecordingCodePaneScriptEvaluator()

        await gateway.completeFileListCall(at: 0, result: .init(paths: ["a.ts"], truncated: false))
        await settle()

        #expect(
            await gateway.subscribedFileListSignatureCallCount() == 0,
            "a workspaceFileList completion from a torn-down page life must not enable monitoring or subscribe the replacement page")
    }

    @Test func aRepeatedWorkspaceFileListDoesNotResubscribeTheWorkspaceFileListSignatureStream() async {
        let gateway = RecordingCodePaneDeviceGateway()
        let hosting = DeviceCodePaneHostingDouble(device: fakeDevice())
        let content = makeController(hosting: hosting, deviceGateway: gateway)
        content.activate(focus: false)
        content.scriptEvaluator = RecordingCodePaneScriptEvaluator()

        await gateway.setFileListResult(.success(.init(paths: ["a.ts"], truncated: false)))
        content.dispatch(.init(id: "req-1", method: "workspaceFileList", params: [:]))
        await gateway.waitForFileListSignatureSubscribeCount(1)

        content.dispatch(.init(id: "req-2", method: "workspaceFileList", params: [:]))
        await settle()

        #expect(await gateway.subscribedFileListSignatureCallCount() == 1)
    }

    @Test func aPendingWorkspaceFileListSignatureSubscribeDoesNotStartADuplicateConnect() async {
        let gateway = RecordingCodePaneDeviceGateway()
        let hosting = DeviceCodePaneHostingDouble(device: fakeDevice())
        let content = makeController(hosting: hosting, deviceGateway: gateway)
        content.activate(focus: false)
        content.scriptEvaluator = RecordingCodePaneScriptEvaluator()

        await gateway.setFileListResult(.success(.init(paths: ["a.ts"], truncated: false)))
        await gateway.holdNextFileListSignatureSubscribeAttempts(1)
        content.dispatch(.init(id: "req-1", method: "workspaceFileList", params: [:]))
        await gateway.waitForFileListSignatureSubscribeAttemptCount(1)

        content.dispatch(.init(id: "req-2", method: "workspaceFileList", params: [:]))
        await settle()

        #expect(await gateway.fileListSignatureSubscribeAttemptCount() == 1)

        await gateway.completeHeldFileListSignatureSubscribeCall(at: 0)
        await gateway.waitForFileListSignatureSubscribeCount(1)
    }

    @Test func aDisconnectWhileWorkspaceFileListSignatureSubscribeIsPendingKeepsRetryAlive() async {
        let gateway = RecordingCodePaneDeviceGateway()
        let hosting = DeviceCodePaneHostingDouble(device: fakeDevice())
        let content = makeController(hosting: hosting, deviceGateway: gateway)
        content.fileListSignatureReconnectFloor = .milliseconds(20)
        content.fileListSignatureReconnectCap = .milliseconds(20)
        content.activate(focus: false)
        content.scriptEvaluator = RecordingCodePaneScriptEvaluator()

        await gateway.setFileListResult(.success(.init(paths: ["a.ts"], truncated: false)))
        await gateway.holdNextFileListSignatureSubscribeAttempts(1)
        content.dispatch(.init(id: "req-1", method: "workspaceFileList", params: [:]))
        await gateway.waitForFileListSignatureSubscribeAttemptCount(1)

        // The transport can disconnect before the async subscribe returns. Let the retry wake while
        // the original attempt is still pending; it must not consume the only retry by no-op'ing.
        await gateway.triggerPendingFileListSignatureDisconnect(at: 0)
        await settle(.milliseconds(60))
        #expect(await gateway.fileListSignatureSubscribeAttemptCount() == 1)

        _ = await gateway.completeHeldFileListSignatureSubscribeCall(at: 0)
        await gateway.waitForFileListSignatureSubscribeAttemptCount(2)
        #expect(await gateway.fileListSignatureSubscribeAttemptCount() == 2)
    }

    @Test func aConnectFrameRepeatingTheJustFetchedWorkspaceFileListSignatureIsSuppressed() async {
        let gateway = RecordingCodePaneDeviceGateway()
        let hosting = DeviceCodePaneHostingDouble(device: fakeDevice())
        let content = makeController(hosting: hosting, deviceGateway: gateway)
        content.activate(focus: false)
        let evaluator = RecordingCodePaneScriptEvaluator()
        content.scriptEvaluator = evaluator
        content.handleReady()

        await gateway.setFileListResult(.success(.init(paths: ["a.ts"], truncated: false)))
        content.dispatch(.init(id: "req-1", method: "workspaceFileList", params: [:]))
        await gateway.waitForFileListSignatureSubscribeCount(1)

        await gateway.triggerFileListSignatureFrame(
            at: 0, signature: SpacesDeviceWorkspaceFileListSignature.value(for: .init(paths: ["a.ts"], truncated: false)))
        await settle()

        #expect(fileListSignatureScripts(evaluator).isEmpty)
    }

    @Test func aChangedWorkspaceFileListSignatureRetriesUntilAWorkspaceFileListPullSucceeds() async {
        let gateway = RecordingCodePaneDeviceGateway()
        let hosting = DeviceCodePaneHostingDouble(device: fakeDevice())
        let content = makeController(hosting: hosting, deviceGateway: gateway)
        content.activate(focus: false)
        let evaluator = RecordingCodePaneScriptEvaluator()
        content.scriptEvaluator = evaluator
        content.handleReady()

        let baseline = SpacesDeviceWorkspaceFileListResult(paths: ["a.ts"], truncated: false)
        let updated = SpacesDeviceWorkspaceFileListResult(paths: ["b.ts"], truncated: false)
        let updatedSignature = SpacesDeviceWorkspaceFileListSignature.value(for: updated)

        await gateway.setFileListResult(.success(baseline))
        content.dispatch(.init(id: "req-1", method: "workspaceFileList", params: [:]))
        await gateway.waitForFileListSignatureSubscribeCount(1)

        await gateway.triggerFileListSignatureFrame(at: 0, signature: updatedSignature)
        await waitUntil { !self.fileListSignatureScripts(evaluator).isEmpty }

        #expect(fileListSignatureScripts(evaluator).count == 1)
        #expect(fileListSignatureScripts(evaluator)[0].contains(updatedSignature))

        await gateway.setFileListResult(.failure(SpacesDeviceClientError.requestRejected(message: "device unavailable", code: .serviceNotRunning)))
        content.dispatch(.init(id: "req-2", method: "workspaceFileList", params: [:]))
        await settle()

        await gateway.triggerFileListSignatureFrame(at: 0, signature: updatedSignature)
        await waitUntil { self.fileListSignatureScripts(evaluator).count == 2 }

        await gateway.setFileListResult(.success(updated))
        content.dispatch(.init(id: "req-3", method: "workspaceFileList", params: [:]))
        await settle()

        await gateway.triggerFileListSignatureFrame(at: 0, signature: updatedSignature)
        await settle()

        #expect(fileListSignatureScripts(evaluator).count == 2)
    }

    // MARK: - workspaceRefList dispatch (Compare dialog's ref search)
    //
    // Mirrors `workspaceFileList`'s dispatch shape exactly (see `CodePaneDeviceGateway.workspaceRefList`'s
    // doc comment): a plain record-and-answer round trip, with no staleness race for this test to pin.

    @Test func workspaceRefListRequestReachesTheGatewayAndDeliversItsReply() async {
        let gateway = RecordingCodePaneDeviceGateway()
        let hosting = DeviceCodePaneHostingDouble(device: fakeDevice())
        let content = makeController(hosting: hosting, deviceGateway: gateway)
        content.activate(focus: false)
        let evaluator = RecordingCodePaneScriptEvaluator()
        content.scriptEvaluator = evaluator

        await gateway.setRefListResult(
            .success(
                SpacesDeviceWorkspaceRefListResult(
                    branches: ["main"], branchesTruncated: false,
                    commits: [SpacesDeviceWorkspaceRefListCommit(sha: "abc123", subject: "Initial commit")], commitsTruncated: false)))

        content.dispatch(CodePaneBridge.Request(id: "req-1", method: "workspaceRefList", params: [:]))
        await waitUntil { evaluator.evaluatedScripts.contains { $0.contains("req-1") && $0.contains("abc123") } }

        #expect(await gateway.refListCalls == ["workspace-1"], "the request must reach the gateway with this pane's workspace id")
        #expect(evaluator.evaluatedScripts.contains { $0.contains("req-1") && $0.contains("abc123") }, "the gateway's result must be replied back")
    }

    @Test func workspaceRevisionFileReadUsesTheImmutableRevisionWithoutRetargetingLiveFileMonitoring() async {
        let gateway = RecordingCodePaneDeviceGateway()
        let hosting = DeviceCodePaneHostingDouble(device: fakeDevice())
        let content = makeController(hosting: hosting, deviceGateway: gateway)
        content.activate(focus: false)
        let evaluator = RecordingCodePaneScriptEvaluator()
        content.scriptEvaluator = evaluator
        let revision = String(repeating: "a", count: 40)

        content.dispatch(
            CodePaneBridge.Request(id: "req-1", method: "workspaceRevisionFileRead", params: ["path": "Sources/App.swift", "revision": revision]))
        await waitUntil { evaluator.evaluatedScripts.contains { $0.contains("req-1") && $0.contains("revision text") } }

        let calls = await gateway.revisionFileReadCalls
        #expect(calls.count == 1)
        #expect(calls[0].workspaceID == "workspace-1")
        #expect(calls[0].revision == revision)
        #expect(calls[0].relativePath == "Sources/App.swift")
        #expect(await gateway.fileSubscribeCallCount() == 0)
    }

    // MARK: - Complete workspace-state recovery

    @Test func completeWorkspaceStateRoundTripsThroughTeardownAndAReplacementController() async throws {
        let storage = MemoryCodePaneWorkspaceStateStorage()
        let state = completeWorkspaceState()
        let agent = CodePaneRunningAgent(id: "agent-1", label: "Claude", sessionID: "session-agent")
        let hosting = DeviceCodePaneHostingDouble(device: fakeDevice(), agents: [agent])
        let content = makeController(hosting: hosting, workspaceStateStore: storage)
        content.activate(focus: false)
        let evaluator = RecordingCodePaneScriptEvaluator()
        content.scriptEvaluator = evaluator
        evaluator.enqueueCollectResult(try workspaceStateJSON(state))

        content.deactivate()
        await waitUntil { (try? storage.stateJSON(workspaceID: "workspace-1")) != nil }

        // A replacement after app relaunch reads durable storage rather than this launch's cache.
        CodePaneWorkspaceStateCache.remove(storageKey: storage.workspaceStateStorageKey, workspaceID: "workspace-1")
        let replacement = makeController(hosting: hosting, workspaceStateStore: storage)
        replacement.activate(focus: false)
        let replacementEvaluator = RecordingCodePaneScriptEvaluator()
        replacement.scriptEvaluator = replacementEvaluator
        replacement.handleReady()

        await waitUntil { replacementEvaluator.evaluatedScripts.contains { $0.contains("spaces:init") } }
        let script = try #require(replacementEvaluator.evaluatedScripts.first { $0.contains("spaces:init") })
        #expect(try initWorkspaceState(in: script) == state)
    }

    @Test func anExplicitInitialDiffModeOverridesOnlyTheRecoveredMode() async throws {
        let storage = MemoryCodePaneWorkspaceStateStorage()
        let recovered = completeWorkspaceState()
        let document = CodePaneWorkspaceState(
            mode: .editor, scope: recovered.scope, diffLayout: recovered.diffLayout, diffSelectedPath: recovered.diffSelectedPath,
            diffTreeExpandedPaths: recovered.diffTreeExpandedPaths, diffTreeSelectedPath: recovered.diffTreeSelectedPath,
            fileTreeExpandedPaths: recovered.fileTreeExpandedPaths, fileTreeSelectedPath: recovered.fileTreeSelectedPath,
            editorSidebarMode: recovered.editorSidebarMode, editorRecentPaths: recovered.editorRecentPaths, diffScrollLine: recovered.diffScrollLine,
            diffScrollSide: recovered.diffScrollSide, diffFocusedPath: recovered.diffFocusedPath, diffFocusedLine: recovered.diffFocusedLine,
            diffFocusedSide: recovered.diffFocusedSide, editorScrollLine: recovered.editorScrollLine, editorFocusedLine: recovered.editorFocusedLine,
            editorState: recovered.editorState, diffEditorState: recovered.diffEditorState, pendingReviewComments: recovered.pendingReviewComments,
            selectedAgentSessionId: recovered.selectedAgentSessionId, pendingAgentLaunch: recovered.pendingAgentLaunch)
        try storage.setStateJSON(String(decoding: try JSONEncoder().encode(document), as: UTF8.self), workspaceID: "workspace-1")
        CodePaneWorkspaceStateCache.remove(storageKey: storage.workspaceStateStorageKey, workspaceID: "workspace-1")

        let content = CodePaneContentController(
            paneID: "pane-1", deviceID: "device-1", workspaceID: "workspace-1", initialMode: .diff, hosting: hostingDouble,
            workspaceStateStore: storage)
        content.activate(focus: false)
        let evaluator = RecordingCodePaneScriptEvaluator()
        content.scriptEvaluator = evaluator
        content.handleReady()

        await waitUntil { evaluator.evaluatedScripts.contains { $0.contains("spaces:init") } }
        let script = try #require(evaluator.evaluatedScripts.first { $0.contains("spaces:init") })
        let initial = try initWorkspaceState(in: script)
        #expect(initial.mode == "diff")
        #expect(initial.scope == recovered.scope)
        #expect(initial.diffLayout == recovered.diffLayout)
        #expect(initial.diffSelectedPath == recovered.diffSelectedPath)
        #expect(initial.diffTreeExpandedPaths == recovered.diffTreeExpandedPaths)
        #expect(initial.fileTreeExpandedPaths == recovered.fileTreeExpandedPaths)
        #expect(initial.editorSidebarMode == recovered.editorSidebarMode)
        #expect(initial.editorRecentPaths == recovered.editorRecentPaths)
        #expect(initial.diffScrollLine == recovered.diffScrollLine)
        #expect(initial.diffFocusedPath == recovered.diffFocusedPath)
        #expect(initial.editorState == recovered.editorState)
        #expect(initial.diffEditorState == recovered.diffEditorState)
        #expect(initial.pendingReviewComments == recovered.pendingReviewComments)
    }

    @Test func anExplicitInitialDiffModeSurvivesAnOutgoingWorkspaceStateHandoff() async throws {
        let storage = MemoryCodePaneWorkspaceStateStorage()
        let recovered = completeWorkspaceState()
        let first = makeController(workspaceStateStore: storage)
        first.activate(focus: false)
        let outgoingEvaluator = RecordingCodePaneScriptEvaluator()
        first.scriptEvaluator = outgoingEvaluator
        first.close()

        let replacement = CodePaneContentController(
            paneID: "pane-1", deviceID: "device-1", workspaceID: "workspace-1", initialMode: .diff, hosting: hostingDouble,
            workspaceStateStore: storage)
        replacement.activate(focus: false)
        let replacementEvaluator = RecordingCodePaneScriptEvaluator()
        replacement.scriptEvaluator = replacementEvaluator
        replacement.handleReady()
        #expect(!replacementEvaluator.evaluatedScripts.contains { $0.contains("spaces:init") })

        outgoingEvaluator.completeOldestPending(with: try workspaceStateJSON(recovered))
        await waitUntil { replacementEvaluator.evaluatedScripts.contains { $0.contains("spaces:init") } }

        let script = try #require(replacementEvaluator.evaluatedScripts.first { $0.contains("spaces:init") })
        let initial = try initWorkspaceState(in: script)
        #expect(initial.mode == "diff")
        #expect(initial.scope == recovered.scope)
        #expect(initial.diffLayout == recovered.diffLayout)
        #expect(initial.editorState == recovered.editorState)
        #expect(initial.diffEditorState == recovered.diffEditorState)
        #expect(initial.pendingReviewComments == recovered.pendingReviewComments)
    }

    @Test func aWorkspaceStateCollectorThatIsNotInstalledLeavesTheDurableSnapshotIntact() async throws {
        let storage = MemoryCodePaneWorkspaceStateStorage()
        let state = completeWorkspaceState()
        try storage.setStateJSON(
            String(
                decoding: try JSONEncoder().encode(
                    CodePaneWorkspaceState(
                        mode: .editor, scope: state.scope, diffLayout: state.diffLayout, diffSelectedPath: state.diffSelectedPath,
                        diffTreeExpandedPaths: state.diffTreeExpandedPaths, diffTreeSelectedPath: state.diffTreeSelectedPath,
                        fileTreeExpandedPaths: state.fileTreeExpandedPaths, fileTreeSelectedPath: state.fileTreeSelectedPath,
                        editorSidebarMode: state.editorSidebarMode, editorRecentPaths: state.editorRecentPaths, diffScrollLine: state.diffScrollLine,
                        diffScrollSide: state.diffScrollSide, diffFocusedPath: state.diffFocusedPath, diffFocusedLine: state.diffFocusedLine,
                        diffFocusedSide: state.diffFocusedSide, editorScrollLine: state.editorScrollLine, editorFocusedLine: state.editorFocusedLine,
                        editorState: state.editorState, diffEditorState: state.diffEditorState, pendingReviewComments: state.pendingReviewComments,
                        selectedAgentSessionId: state.selectedAgentSessionId, pendingAgentLaunch: state.pendingAgentLaunch)), as: UTF8.self),
            workspaceID: "workspace-1")
        CodePaneWorkspaceStateCache.remove(storageKey: storage.workspaceStateStorageKey, workspaceID: "workspace-1")

        let hosting = DeviceCodePaneHostingDouble(device: fakeDevice(), agents: [.init(id: "agent-1", label: "Claude", sessionID: "session-agent")])
        let content = makeController(hosting: hosting, workspaceStateStore: storage)
        content.activate(focus: false)
        let evaluator = RecordingCodePaneScriptEvaluator()
        content.scriptEvaluator = evaluator
        evaluator.enqueueCollectResult("__uninstalled__")
        content.deactivate()
        await Task.yield()

        let stored = try #require(try storage.stateJSON(workspaceID: "workspace-1"))
        let decoded = try JSONDecoder().decode(CodePaneWorkspaceState.self, from: Data(stored.utf8))
        #expect(decoded.bridgePayload == state)
    }

    @Test func aModeChangeWhileThePaneIsHibernatingPersistsForTheNextController() async throws {
        let storage = MemoryCodePaneWorkspaceStateStorage()
        let content = makeController(workspaceStateStore: storage)

        content.requestMode(.editor)
        await waitUntil { (try? storage.stateJSON(workspaceID: "workspace-1")) != nil }

        let stateJSON = try #require(try storage.stateJSON(workspaceID: "workspace-1"))
        let state = try JSONDecoder().decode(CodePaneWorkspaceState.self, from: Data(stateJSON.utf8))
        #expect(state.mode == "editor")
    }

    @Test func closeRetainsItsFinalWorkspaceStateCollectorUntilItAnswers() {
        let evaluator = RecordingCodePaneScriptEvaluator()
        weak var retainedByCollector: CodePaneContentController?
        do {
            let content = makeController()
            content.activate(focus: false)
            content.scriptEvaluator = evaluator
            content.close()
            retainedByCollector = content
        }

        #expect(retainedByCollector != nil, "closing must keep the native collector alive until it has read the page's final state")
        evaluator.completeOldestPending(with: "__none__")
        #expect(retainedByCollector == nil, "the collector retention must end exactly when its callback settles")
    }

    @Test func closeRetainsTheConcreteEvaluatorUntilItsFinalCollectionAnswers() {
        let coordinator = DeferredCodePaneScriptEvaluationCoordinator()
        weak var retainedEvaluator: DeferredCodePaneScriptEvaluator?

        do {
            let evaluator = DeferredCodePaneScriptEvaluator(coordinator: coordinator)
            retainedEvaluator = evaluator
            let content = makeController()
            content.activate(focus: false)
            content.scriptEvaluator = evaluator
            content.close()
        }

        #expect(retainedEvaluator != nil, "teardown must keep the concrete script evaluator alive until its callback answers")
        coordinator.complete(with: "__none__")
        #expect(retainedEvaluator == nil, "the concrete evaluator is released after the final collection settles")
    }

    @Test func authoritativeWorkspaceDeletionCannotLeaveAQueuedRecoveryWriteBehind() async {
        let writer = BlockingWorkspaceStateWriter()
        let storageKey = "deletion-fence-\(UUID().uuidString)"
        let persistence = CodePaneWorkspaceStatePersistence(
            label: "test", storageKey: storageKey, write: { value, workspaceID in writer.write(value, workspaceID: workspaceID) })
        let state = CodePaneWorkspaceState(mode: .diff, editorState: nil, pendingReviewComments: nil)

        persistence.enqueue(state, workspaceID: "workspace-1")
        let firstWriteStarted = await Task.detached { writer.waitForFirstWrite(timeout: .seconds(1)) }.value
        #expect(firstWriteStarted, "precondition: the first persistence write entered the shared deletion gate")
        persistence.enqueue(state, workspaceID: "workspace-1")
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(10)) { writer.releaseFirstWrite() }

        CodePaneWorkspaceStateCache.deleteStateForMissingWorkspaces(
            storageKey: storageKey, liveWorkspaceIDs: [], previousWorkspaceIDs: ["workspace-1"], persistedWorkspaceIDs: { [] },
            delete: { workspaceID in writer.delete(workspaceID: workspaceID) })
        persistence.drainForTermination()

        #expect(
            writer.value(workspaceID: "workspace-1") == nil,
            "the deletion fence must remove a write that was in flight and reject the queued successor")
    }

    @Test func closeRetainsTheControllerUntilOutstandingFileWritesSettle() async throws {
        let gateway = RecordingCodePaneDeviceGateway()
        let hosting = DeviceCodePaneHostingDouble(device: fakeDevice())
        let evaluator = RecordingCodePaneScriptEvaluator()
        weak var retainedByWrite: CodePaneContentController?

        do {
            let content = makeController(hosting: hosting, deviceGateway: gateway)
            content.activate(focus: false)
            content.scriptEvaluator = evaluator
            await gateway.holdNextFileWriteAttempts(1)
            content.dispatch(
                .init(
                    id: "save-before-close", method: "workspaceFileWrite",
                    params: ["path": "Sources/App.swift", "content": "let saved = 4", "options": ["purpose": "editor"]]))
            await gateway.waitForFileWriteCallCount(1)
            content.close()
            retainedByWrite = content
        }

        evaluator.completeOldestPending(with: "__none__")
        #expect(retainedByWrite != nil, "the close handoff must outlive a mutation that can refine its final snapshot")

        await gateway.completeHeldFileWriteCall(at: 0, result: .init(didWrite: true, sha256: "saved-sha"))
        await waitUntil { retainedByWrite == nil }
    }

    @Test func closePersistsTheStateCollectedAfterTeardown() async throws {
        let storage = MemoryCodePaneWorkspaceStateStorage()
        let state = completeWorkspaceState()
        let content = makeController(workspaceStateStore: storage)
        content.activate(focus: false)
        let evaluator = RecordingCodePaneScriptEvaluator()
        content.scriptEvaluator = evaluator

        content.close()
        evaluator.completeOldestPending(with: try workspaceStateJSON(state))
        await waitUntil { (try? storage.stateJSON(workspaceID: "workspace-1")) != nil }

        let stored = try #require(try storage.stateJSON(workspaceID: "workspace-1"))
        let recovered = try JSONDecoder().decode(CodePaneWorkspaceState.self, from: Data(stored.utf8))
        #expect(recovered.bridgePayload == state, "close must accept its own final collector rather than invalidating it")
    }

    @Test func terminationWaitsForTheFinalCollectionBeforeDrainingPersistence() async throws {
        let storage = MemoryCodePaneWorkspaceStateStorage()
        let state = completeWorkspaceState()
        let content = makeController(workspaceStateStore: storage)
        content.activate(focus: false)
        let evaluator = RecordingCodePaneScriptEvaluator()
        content.scriptEvaluator = evaluator
        var didFinishTerminationFence = false

        content.closeForTermination { didFinishTerminationFence = true }
        #expect(!didFinishTerminationFence, "the durable termination fence must wait for WebKit's final collection")
        evaluator.completeOldestPending(with: try workspaceStateJSON(state))

        #expect(didFinishTerminationFence, "persistence is drained only after the collected state has been enqueued")
        let stored = try #require(try storage.stateJSON(workspaceID: "workspace-1"))
        let recovered = try JSONDecoder().decode(CodePaneWorkspaceState.self, from: Data(stored.utf8))
        #expect(recovered.bridgePayload == state)
    }

    @Test func terminationFenceWaitsForACollectorFromAnAlreadyDetachedPane() async throws {
        let storage = MemoryCodePaneWorkspaceStateStorage()
        let state = completeWorkspaceState()
        let content = makeController(workspaceStateStore: storage)
        content.activate(focus: false)
        let evaluator = RecordingCodePaneScriptEvaluator()
        content.scriptEvaluator = evaluator

        // Retargeting removes this controller from PanelCoordinator before its asynchronous WebKit
        // collector settles. The app-wide termination fence must still include that collector.
        content.close()
        var didFinishTerminationFence = false
        CodePaneWorkspaceStatePersistence.finishTermination { didFinishTerminationFence = true }
        #expect(!didFinishTerminationFence)

        evaluator.completeOldestPending(with: try workspaceStateJSON(state))
        #expect(didFinishTerminationFence)
        let stored = try #require(try storage.stateJSON(workspaceID: "workspace-1"))
        let recovered = try JSONDecoder().decode(CodePaneWorkspaceState.self, from: Data(stored.utf8))
        #expect(recovered.bridgePayload == state)
    }

    @Test func returningToAWorkspaceWaitsForItsOutgoingCollectorBeforeRestoringState() async throws {
        let storage = MemoryCodePaneWorkspaceStateStorage()
        let state = completeWorkspaceState()
        let agent = CodePaneRunningAgent(id: "agent-1", label: "Claude", sessionID: "session-agent")
        let hosting = DeviceCodePaneHostingDouble(device: fakeDevice(), agents: [agent])
        let firstA = makeController(hosting: hosting, workspaceStateStore: storage)
        firstA.activate(focus: false)
        let outgoingEvaluator = RecordingCodePaneScriptEvaluator()
        firstA.scriptEvaluator = outgoingEvaluator
        firstA.close()

        // The global Editor retargets A → B without waiting. Returning to A must not initialize from
        // the pre-collection cache while A's previous page still owns its final snapshot.
        let b = CodePaneContentController(
            paneID: "pane-b", deviceID: "device-1", workspaceID: "workspace-2", initialMode: .diff, hosting: hosting, workspaceStateStore: storage)
        b.activate(focus: false)
        b.close()
        let returningA = makeController(hosting: hosting, workspaceStateStore: storage)
        returningA.activate(focus: false)
        let returningEvaluator = RecordingCodePaneScriptEvaluator()
        returningA.scriptEvaluator = returningEvaluator
        returningA.handleReady()

        #expect(!returningEvaluator.evaluatedScripts.contains { $0.contains("spaces:init") })
        outgoingEvaluator.completeOldestPending(with: try workspaceStateJSON(state))
        await waitUntil { returningEvaluator.evaluatedScripts.contains { $0.contains("spaces:init") } }

        let initScript = try #require(returningEvaluator.evaluatedScripts.first { $0.contains("spaces:init") })
        #expect(try initWorkspaceState(in: initScript) == state)
    }

    @Test func anUninstalledReturningPaneDoesNotDiscardAnOlderDirtyCollector() async throws {
        let storage = MemoryCodePaneWorkspaceStateStorage()
        let hosting = DeviceCodePaneHostingDouble(device: fakeDevice())
        let firstA = makeController(hosting: hosting, workspaceStateStore: storage)
        firstA.activate(focus: false)
        let firstAEvaluator = RecordingCodePaneScriptEvaluator()
        firstA.scriptEvaluator = firstAEvaluator
        firstA.close()

        // Model the global Editor's A → B → A → B retarget. Returning A is still waiting for
        // first A's collector when it is immediately replaced again, so its page has no state to
        // report. That empty handoff must not make first A's older, dirty collector ineligible.
        let firstB = CodePaneContentController(
            paneID: "pane-b-1", deviceID: "device-1", workspaceID: "workspace-2", initialMode: .diff, hosting: hosting, workspaceStateStore: storage)
        firstB.close()
        let returningA = makeController(hosting: hosting, workspaceStateStore: storage)
        returningA.activate(focus: false)
        let returningAEvaluator = RecordingCodePaneScriptEvaluator()
        returningA.scriptEvaluator = returningAEvaluator
        returningA.handleReady()
        #expect(!returningAEvaluator.evaluatedScripts.contains { $0.contains("spaces:init") })

        returningA.close()
        returningAEvaluator.completeOldestPending(with: "__uninstalled__")

        let finalState = CodePaneWorkspaceState(
            mode: .editor,
            editorState: .init(
                path: "Sources/App.swift", baseSHA256: "dirty-base", baseContent: "let value = 1", content: "let value = 2", dirty: true),
            pendingReviewComments: nil
        ).bridgePayload
        firstAEvaluator.completeOldestPending(with: try workspaceStateJSON(finalState))
        await waitUntil {
            guard let stored = try? storage.stateJSON(workspaceID: "workspace-1"),
                let recovered = try? JSONDecoder().decode(CodePaneWorkspaceState.self, from: Data(stored.utf8))
            else { return false }
            return recovered.bridgePayload.editorState?.content == "let value = 2"
        }

        let stored = try #require(try storage.stateJSON(workspaceID: "workspace-1"))
        let recovered = try JSONDecoder().decode(CodePaneWorkspaceState.self, from: Data(stored.utf8))
        #expect(recovered.bridgePayload.editorState?.content == "let value = 2")
        #expect(recovered.bridgePayload.editorState?.dirty == true)
    }

    @Test func returningToAWorkspaceWaitsForOutgoingWritesAndCommentMutationsBeforeRestoring() async throws {
        let storage = MemoryCodePaneWorkspaceStateStorage()
        let gateway = RecordingCodePaneDeviceGateway()
        let hosting = DeviceCodePaneHostingDouble(device: fakeDevice())
        let firstA = makeController(hosting: hosting, deviceGateway: gateway, workspaceStateStore: storage)
        firstA.activate(focus: false)
        let outgoingEvaluator = RecordingCodePaneScriptEvaluator()
        firstA.scriptEvaluator = outgoingEvaluator
        await gateway.holdNextFileWriteAttempts(1)
        await gateway.holdNextUpsertAttempts(1)

        firstA.dispatch(
            .init(
                id: "save-before-retarget", method: "workspaceFileWrite",
                params: ["path": "Sources/App.swift", "content": "let saved = 4", "options": ["baseSHA256": "diff-base", "purpose": "inlineDiff"]]))
        firstA.dispatch(
            .init(
                id: "comment-before-retarget", method: "reviewCommentUpsert",
                params: ["filePath": "Sources/App.swift", "side": "new", "lineNumber": 42, "lineText": "let edited = 2", "body": "Please keep this."])
        )
        await gateway.waitForFileWriteCallCount(1)
        await gateway.waitForUpsertCallCount(1)

        let collected = completeWorkspaceState()
        firstA.close()
        outgoingEvaluator.completeOldestPending(with: try workspaceStateJSON(collected))

        // A global Editor retarget may construct the replacement before either request returns. It
        // must not restore the pre-mutation snapshot while the outgoing pane still owns its final
        // recovery state.
        let b = CodePaneContentController(
            paneID: "pane-b", deviceID: "device-1", workspaceID: "workspace-2", initialMode: .diff, hosting: hosting, workspaceStateStore: storage)
        b.close()
        let returningA = makeController(hosting: hosting, deviceGateway: gateway, workspaceStateStore: storage)
        returningA.activate(focus: false)
        let returningEvaluator = RecordingCodePaneScriptEvaluator()
        returningA.scriptEvaluator = returningEvaluator
        returningA.handleReady()
        #expect(!returningEvaluator.evaluatedScripts.contains { $0.contains("spaces:init") })

        await gateway.completeHeldFileWriteCall(at: 0, result: .init(didWrite: true, sha256: "saved-sha"))
        #expect(!returningEvaluator.evaluatedScripts.contains { $0.contains("spaces:init") })

        await gateway.completeHeldUpsertCall(
            at: 0,
            result: .init(
                id: "comment-1", filePath: "Sources/App.swift", side: .new, lineNumber: 42, lineText: "let edited = 2", body: "Please keep this.",
                createdAt: "2026-01-01T00:00:00Z", revision: 0))
        await waitUntil { returningEvaluator.evaluatedScripts.contains { $0.contains("spaces:init") } }

        let restored = try #require(returningEvaluator.evaluatedScripts.first { $0.contains("spaces:init") })
        let state = try initWorkspaceState(in: restored)
        #expect(state.diffEditorState?.baseSHA256 == "saved-sha")
        #expect(state.pendingReviewComments?.isEmpty ?? true)
    }

    @Test func terminationWaitsForOutstandingWritesAndCommentMutationsAfterFinalCollection() async throws {
        let storage = MemoryCodePaneWorkspaceStateStorage()
        let gateway = RecordingCodePaneDeviceGateway()
        let hosting = DeviceCodePaneHostingDouble(device: fakeDevice())
        let content = makeController(hosting: hosting, deviceGateway: gateway, workspaceStateStore: storage)
        content.activate(focus: false)
        let evaluator = RecordingCodePaneScriptEvaluator()
        content.scriptEvaluator = evaluator
        await gateway.holdNextFileWriteAttempts(1)
        await gateway.holdNextUpsertAttempts(1)

        content.dispatch(
            .init(
                id: "save-before-termination", method: "workspaceFileWrite",
                params: ["path": "Sources/App.swift", "content": "let saved = 4", "options": ["baseSHA256": "diff-base", "purpose": "inlineDiff"]]))
        content.dispatch(
            .init(
                id: "comment-before-termination", method: "reviewCommentUpsert",
                params: ["filePath": "Sources/App.swift", "side": "new", "lineNumber": 42, "lineText": "let edited = 2", "body": "Please keep this."])
        )
        await gateway.waitForFileWriteCallCount(1)
        await gateway.waitForUpsertCallCount(1)

        var didFinishTerminationFence = false
        content.closeForTermination { didFinishTerminationFence = true }
        evaluator.completeOldestPending(with: try workspaceStateJSON(completeWorkspaceState()))
        #expect(!didFinishTerminationFence, "termination must wait for requests issued before the final collector")

        await gateway.completeHeldUpsertCall(
            at: 0,
            result: .init(
                id: "comment-1", filePath: "Sources/App.swift", side: .new, lineNumber: 42, lineText: "let edited = 2", body: "Please keep this.",
                createdAt: "2026-01-01T00:00:00Z", revision: 0))
        #expect(!didFinishTerminationFence, "a held file write must keep the termination fence closed")

        await gateway.completeHeldFileWriteCall(at: 0, result: .init(didWrite: true, sha256: "saved-sha"))
        await waitUntil { didFinishTerminationFence }
    }

    @Test func returningControllerStateWinsWhenItChangesBeforeTheOutgoingCollectorAnswers() async throws {
        let storage = MemoryCodePaneWorkspaceStateStorage()
        let hosting = DeviceCodePaneHostingDouble(device: fakeDevice())
        let firstA = makeController(hosting: hosting, workspaceStateStore: storage)
        firstA.activate(focus: false)
        let outgoingEvaluator = RecordingCodePaneScriptEvaluator()
        firstA.scriptEvaluator = outgoingEvaluator
        firstA.close()

        let returningA = makeController(hosting: hosting, workspaceStateStore: storage)
        // A navigation resolver can select the requested mode before the replacement page is ready.
        // That newer intent must not be overwritten when the outgoing collector eventually answers.
        returningA.requestMode(.editor)
        returningA.activate(focus: false)
        let returningEvaluator = RecordingCodePaneScriptEvaluator()
        returningA.scriptEvaluator = returningEvaluator
        returningA.handleReady()
        #expect(!returningEvaluator.evaluatedScripts.contains { $0.contains("spaces:init") })

        let staleOutgoing = CodePaneWorkspaceState(mode: .diff, editorState: nil, pendingReviewComments: nil).bridgePayload
        outgoingEvaluator.completeOldestPending(with: try workspaceStateJSON(staleOutgoing))
        await waitUntil { returningEvaluator.evaluatedScripts.contains { $0.contains("spaces:init") } }

        let initScript = try #require(returningEvaluator.evaluatedScripts.first { $0.contains("spaces:init") })
        #expect(try initWorkspaceState(in: initScript).mode == "editor")
    }

    @Test func aPreReadyModeRequestMergesWithTheFreshReturningCollectorsDirtyBuffer() async throws {
        let storage = MemoryCodePaneWorkspaceStateStorage()
        let hosting = DeviceCodePaneHostingDouble(device: fakeDevice())
        let stale = CodePaneWorkspaceState(
            mode: .diff,
            editorState: .init(
                path: "Sources/App.swift", baseSHA256: "stale-base", baseContent: "let value = 1", content: "stale draft", dirty: true),
            pendingReviewComments: nil
        ).bridgePayload
        try storage.setStateJSON(
            String(
                decoding: try JSONEncoder().encode(CodePaneWorkspaceState(mode: .diff, editorState: stale.editorState, pendingReviewComments: nil)),
                as: UTF8.self), workspaceID: "workspace-1")
        CodePaneWorkspaceStateCache.remove(storageKey: storage.workspaceStateStorageKey, workspaceID: "workspace-1")

        // Retargeting the singleton from A to B closes A but does not wait for A's WebKit
        // collector. Returning to A therefore starts from the stale cache while that collector is
        // still capable of handing off its newer dirty buffer.
        let firstA = makeController(hosting: hosting, workspaceStateStore: storage)
        firstA.activate(focus: false)
        let outgoingEvaluator = RecordingCodePaneScriptEvaluator()
        firstA.scriptEvaluator = outgoingEvaluator
        firstA.close()
        let b = CodePaneContentController(
            paneID: "pane-1", deviceID: "device-1", workspaceID: "workspace-2", initialMode: .diff, hosting: hosting, workspaceStateStore: storage)
        b.close()

        let returningA = makeController(hosting: hosting, workspaceStateStore: storage)
        returningA.requestMode(.editor)
        returningA.activate(focus: false)
        let returningEvaluator = RecordingCodePaneScriptEvaluator()
        returningA.scriptEvaluator = returningEvaluator
        returningA.handleReady()
        #expect(!returningEvaluator.evaluatedScripts.contains { $0.contains("spaces:init") })

        let fresh = CodePaneWorkspaceState(
            mode: .diff,
            editorState: .init(
                path: "Sources/App.swift", baseSHA256: "fresh-base", baseContent: "let value = 2", content: "fresher dirty draft", dirty: true),
            pendingReviewComments: nil
        ).bridgePayload
        outgoingEvaluator.completeOldestPending(with: try workspaceStateJSON(fresh))
        await waitUntil { returningEvaluator.evaluatedScripts.contains { $0.contains("spaces:init") } }

        let initScript = try #require(returningEvaluator.evaluatedScripts.first { $0.contains("spaces:init") })
        let restored = try initWorkspaceState(in: initScript)
        #expect(restored.mode == "editor")
        #expect(restored.editorState?.content == "fresher dirty draft")
        #expect(restored.editorState?.baseSHA256 == "fresh-base")
        let mergedCacheState = try #require(
            CodePaneWorkspaceStateCache.state(storageKey: storage.workspaceStateStorageKey, workspaceID: "workspace-1"))
        #expect(mergedCacheState.mode == "editor")
        #expect(mergedCacheState.editorState?.content == "fresher dirty draft")
    }

    @Test func aLateInlineDiffSaveAdoptsItsCommittedBaselineAfterTeardown() async throws {
        let storage = MemoryCodePaneWorkspaceStateStorage()
        let gateway = RecordingCodePaneDeviceGateway()
        let hosting = DeviceCodePaneHostingDouble(device: fakeDevice())
        let content = makeController(hosting: hosting, deviceGateway: gateway, workspaceStateStore: storage)
        content.activate(focus: false)
        let evaluator = RecordingCodePaneScriptEvaluator()
        content.scriptEvaluator = evaluator
        await gateway.holdNextFileWriteAttempts(1)

        content.dispatch(
            .init(
                id: "save-inline-diff", method: "workspaceFileWrite",
                params: ["path": "Sources/App.swift", "content": "let saved = 2", "options": ["baseSHA256": "old-sha", "purpose": "inlineDiff"]]))
        await gateway.waitForFileWriteCallCount(1)

        content.deactivate()
        let collected = CodePaneWorkspaceState(
            mode: .diff, editorState: nil,
            diffEditorState: .init(
                path: "Sources/App.swift", baseSHA256: "old-sha", baseContent: "let old = 1", comparisonOldContent: "let comparison = 0",
                content: "let saved = 2", dirty: true, conflict: false),
            pendingReviewComments: nil
        ).bridgePayload
        evaluator.completeOldestPending(with: try workspaceStateJSON(collected))
        await gateway.completeHeldFileWriteCall(at: 0, result: .init(didWrite: true, sha256: "saved-sha"))

        await waitUntil {
            guard let json = try? storage.stateJSON(workspaceID: "workspace-1") else { return false }
            return (try? JSONDecoder().decode(CodePaneWorkspaceState.self, from: Data(json.utf8)))?.diffEditorState?.baseSHA256 == "saved-sha"
        }
        let stored = try #require(try storage.stateJSON(workspaceID: "workspace-1"))
        let recovered = try JSONDecoder().decode(CodePaneWorkspaceState.self, from: Data(stored.utf8))
        #expect(recovered.diffEditorState?.baseSHA256 == "saved-sha")
        #expect(recovered.diffEditorState?.baseContent == "let saved = 2")
        #expect(recovered.diffEditorState?.comparisonOldContent == "let comparison = 0")
        #expect(recovered.diffEditorState?.dirty == false)
    }

    @Test func aLateRecreateSaveAdoptsTheSamePagesPostClickInlineEdit() async throws {
        let storage = MemoryCodePaneWorkspaceStateStorage()
        let gateway = RecordingCodePaneDeviceGateway()
        let hosting = DeviceCodePaneHostingDouble(device: fakeDevice())
        let content = makeController(hosting: hosting, deviceGateway: gateway, workspaceStateStore: storage)
        content.activate(focus: false)
        let evaluator = RecordingCodePaneScriptEvaluator()
        content.scriptEvaluator = evaluator
        await gateway.holdNextFileWriteAttempts(1)

        // No base SHA is the bridge's create/recreate convention. The user keeps typing before the
        // write returns, so recovery must retain that text while adopting the newly created baseline.
        content.dispatch(
            .init(
                id: "recreate-inline-diff", method: "workspaceFileWrite",
                params: ["path": "Sources/App.swift", "content": "let recreated = 2", "options": ["purpose": "inlineDiff"]]))
        await gateway.waitForFileWriteCallCount(1)
        content.deactivate()
        let collected = CodePaneWorkspaceState(
            mode: .diff, editorState: nil,
            diffEditorState: .init(
                path: "Sources/App.swift", baseSHA256: "deleted-file-sha", baseContent: "let old = 1", comparisonOldContent: nil, content: "let typed after = 3", dirty: true,
                conflict: false), pendingReviewComments: nil
        ).bridgePayload
        evaluator.completeOldestPending(with: try workspaceStateJSON(collected))
        await gateway.completeHeldFileWriteCall(at: 0, result: .init(didWrite: true, sha256: "recreated-sha"))

        await waitUntil {
            guard let json = try? storage.stateJSON(workspaceID: "workspace-1") else { return false }
            return (try? JSONDecoder().decode(CodePaneWorkspaceState.self, from: Data(json.utf8)))?.diffEditorState?.baseSHA256 == "recreated-sha"
        }
        let stored = try #require(try storage.stateJSON(workspaceID: "workspace-1"))
        let recovered = try JSONDecoder().decode(CodePaneWorkspaceState.self, from: Data(stored.utf8))
        #expect(recovered.diffEditorState?.baseSHA256 == "recreated-sha")
        #expect(recovered.diffEditorState?.baseContent == "let recreated = 2")
        #expect(recovered.diffEditorState?.content == "let typed after = 3")
        #expect(recovered.diffEditorState?.dirty == true)
    }

    @Test func persistenceCoalescesLargeSnapshotsWithoutBlockingTheMainActor() throws {
        let writer = RecordingWorkspaceStateWriter(blockFirstWrite: true)
        let persistence = CodePaneWorkspaceStatePersistence(
            label: "test.workspace-state.persistence", storageKey: "test-storage-key", write: { writer.write($0, workspaceID: $1) })
        let first = CodePaneWorkspaceState(mode: .diff, editorState: nil, pendingReviewComments: nil)
        persistence.enqueue(first, workspaceID: "workspace-1")
        writer.waitForFirstWrite()

        let latest = CodePaneWorkspaceState(
            mode: .editor,
            editorState: .init(
                path: "Sources/Large.swift", baseSHA256: "base", baseContent: String(repeating: "a", count: 4 * 1024 * 1024),
                content: String(repeating: "b", count: 4 * 1024 * 1024), dirty: true, conflict: false), pendingReviewComments: nil)
        let clock = ContinuousClock()
        let start = clock.now
        persistence.enqueue(CodePaneWorkspaceState(mode: .diff, editorState: nil, pendingReviewComments: nil), workspaceID: "workspace-1")
        persistence.enqueue(latest, workspaceID: "workspace-1")
        let elapsed = start.duration(to: clock.now)

        #expect(elapsed < .milliseconds(100), "enqueue must not encode or synchronously write the multi-megabyte snapshot on the main actor")
        writer.release()
        persistence.drainForTermination()

        let values = writer.recordedValues()
        #expect(values.count == 2, "the blocked initial write and only the latest queued complete document should reach storage")
        let recovered = try JSONDecoder().decode(CodePaneWorkspaceState.self, from: Data(try #require(values.last).utf8))
        #expect(recovered.codePaneMode == .editor, "the final enqueue must win over an intermediate snapshot")
        #expect(recovered.editorState?.content.utf8.count == 4 * 1024 * 1024)
    }

    // MARK: - Progressive diff chunks

    @Test func progressiveDiffChunkCancellationAndManifestReleaseReachTheGatewayWithTheOwningManifest() async throws {
        let gateway = RecordingCodePaneDeviceGateway()
        let hosting = DeviceCodePaneHostingDouble(device: fakeDevice())
        let content = makeController(hosting: hosting, deviceGateway: gateway)
        content.activate(focus: false)
        let evaluator = RecordingCodePaneScriptEvaluator()
        content.scriptEvaluator = evaluator

        content.dispatch(
            .init(
                id: "chunk", method: "workspaceDiffFileChunk",
                params: [
                    "scope": ["kind": "ref", "refName": "main"], "manifestID": "manifest-1", "relativePath": "Sources/App.swift", "byteOffset": 1024,
                    "transferID": "transfer-1",
                ]))
        content.dispatch(
            .init(
                id: "cancel", method: "workspaceDiffFileChunkCancel",
                params: [
                    "scope": ["kind": "ref", "refName": "main"], "manifestID": "manifest-1", "relativePath": "Sources/App.swift", "byteOffset": 1024,
                    "transferID": "transfer-1",
                ]))
        content.dispatch(
            .init(
                id: "release", method: "workspaceDiffManifestRelease",
                params: ["scope": ["kind": "ref", "refName": "main"], "manifestID": "manifest-1"]))

        await waitUntil {
            evaluator.evaluatedScripts.contains { $0.contains("chunk") } && evaluator.evaluatedScripts.contains { $0.contains("cancel") }
                && evaluator.evaluatedScripts.contains { $0.contains("release") }
        }
        let chunk = try #require(await gateway.diffChunkCalls.first)
        #expect(chunk.workspaceID == "workspace-1")
        #expect(chunk.refName == "main")
        #expect(!chunk.lastCommit)
        #expect(chunk.manifestID == "manifest-1")
        #expect(chunk.relativePath == "Sources/App.swift")
        #expect(chunk.byteOffset == 1024)
        #expect(chunk.transferID == "transfer-1")
        let cancellation = try #require(await gateway.diffChunkCancelCalls.first)
        #expect(cancellation.manifestID == "manifest-1")
        #expect(cancellation.transferID == "transfer-1")
        let release = try #require(await gateway.diffManifestReleaseCalls.first)
        #expect(release.workspaceID == "workspace-1")
        #expect(release.refName == "main")
        #expect(!release.lastCommit)
        #expect(release.manifestID == "manifest-1")
    }

    // MARK: - Start Agent lifecycle

    @Test func startAgentDoesNotPublishItsFastHookOverviewAsAssignableBeforeReadiness() async throws {
        let storage = MemoryCodePaneWorkspaceStateStorage()
        let gateway = RecordingCodePaneDeviceGateway()
        await gateway.setWorkspaceCommandStartResult(.success(startedCommandResponse()))
        let agent = CodePaneRunningAgent(id: "agent-start", label: "Claude", sessionID: "session-start")
        let hosting = DeviceCodePaneHostingDouble(device: fakeDevice())
        let content = makeController(hosting: hosting, deviceGateway: gateway, workspaceStateStore: storage)
        hosting.onInstallBackgroundCommandSession = {
            // Installing the terminal synchronously applies the daemon overview in the real host.
            // This models the hook registering before the start RPC's completion returns to WebKit.
            content.applyRunningAgents([agent])
        }
        content.activate(focus: false)
        let evaluator = RecordingCodePaneScriptEvaluator()
        content.scriptEvaluator = evaluator
        content.handleReady()

        content.dispatch(.init(id: "start-fast-hook", method: "startWorkspaceCommand", params: ["command": "claude"]))

        await waitUntil {
            guard let stored = try? storage.stateJSON(workspaceID: "workspace-1"),
                let state = try? JSONDecoder().decode(CodePaneWorkspaceState.self, from: Data(stored.utf8))
            else { return false }
            return state.pendingAgentLaunch?.sessionId == "session-start"
        }
        // The synchronous overview is intentionally filtered out while pending. The first
        // assignable-agent push must wait for the keyed readiness event, after WebKit has received
        // the start response and recorded the pending session itself.
        #expect(!evaluator.evaluatedScripts.contains { $0.contains("spaces:agents") && $0.contains("\"sessionId\":\"session-start\"") })
        let stored = try #require(try storage.stateJSON(workspaceID: "workspace-1"))
        let state = try JSONDecoder().decode(CodePaneWorkspaceState.self, from: Data(stored.utf8))
        #expect(state.pendingAgentLaunch?.sessionId == "session-start")
        #expect(state.pendingAgentLaunch?.status == "starting")
    }

    @Test func detectedStartedAgentIsRetainedForAReactivatedPage() async throws {
        let storage = MemoryCodePaneWorkspaceStateStorage()
        let gateway = RecordingCodePaneDeviceGateway()
        await gateway.setWorkspaceCommandStartResult(.success(startedCommandResponse()))
        let agent = CodePaneRunningAgent(id: "agent-start", label: "Claude", sessionID: "session-start")
        let hosting = DeviceCodePaneHostingDouble(device: fakeDevice())
        let content = makeController(hosting: hosting, deviceGateway: gateway, workspaceStateStore: storage)
        let clock = ControllableAgentStartClock(Date(timeIntervalSince1970: 0))
        content.agentStartReadinessTimeout = 10
        content.agentStartPollInterval = .milliseconds(1)
        content.agentStartNow = {
            let now = clock.now()
            clock.advance(by: AgentSpawnReadiness.inputReadinessConfirmation)
            return now
        }
        // This is the overview applied while the start response is installing its terminal. The
        // pending launch intentionally filters the new row, which seeds the controller's cache with
        // an empty assignable-agent set before the keyed readiness observer detects the same agent.
        hosting.onInstallBackgroundCommandSession = { content.applyRunningAgents([agent]) }
        content.activate(focus: false)
        let evaluator = RecordingCodePaneScriptEvaluator()
        content.scriptEvaluator = evaluator
        content.handleReady()
        await gateway.enqueueWorkspaceCommandStartSnapshot(
            .success(.init(state: .running, detectedKind: .claude, bracketedPasteActive: true, agent: agent)))
        await gateway.enqueueWorkspaceCommandStartSnapshot(
            .success(.init(state: .running, detectedKind: .claude, bracketedPasteActive: true, agent: agent)))

        content.dispatch(.init(id: "start-cache", method: "startWorkspaceCommand", params: ["command": "custom-agent --review"]))
        await waitUntil {
            evaluator.evaluatedScripts.contains {
                $0.contains("spaces:agentStartStatus") && $0.contains("\"sessionId\":\"session-start\"") && $0.contains("\"status\":\"detected\"")
            }
        }

        content.deactivate()
        evaluator.completeOldestPending(with: "__none__")
        content.activate(focus: false)
        let returningEvaluator = RecordingCodePaneScriptEvaluator()
        content.scriptEvaluator = returningEvaluator
        content.handleReady()
        await waitUntil { returningEvaluator.evaluatedScripts.contains { $0.contains("spaces:init") } }
        let restoredInit = try #require(returningEvaluator.evaluatedScripts.first { $0.contains("spaces:init") })
        #expect(restoredInit.contains("\"agents\":[{\"id\":\"agent-start\",\"label\":\"Claude\",\"sessionId\":\"session-start\"}]"))

        content.deactivate()
        returningEvaluator.completeOldestPending(with: "__none__")
    }

    @Test func startAgentInstallsItsBackgroundTerminalFromTheMutationPayloadWhenTheOverviewAlreadyDroppedTheSession() async throws {
        let gateway = RecordingCodePaneDeviceGateway()
        await gateway.setWorkspaceCommandStartResult(.success(startedCommandResponseWithoutOverviewSession()))
        let hosting = DeviceCodePaneHostingDouble(device: fakeDevice())
        let content = makeController(hosting: hosting, deviceGateway: gateway)
        content.activate(focus: false)
        content.scriptEvaluator = RecordingCodePaneScriptEvaluator()
        content.handleReady()

        content.dispatch(.init(id: "start-fast-exit", method: "startWorkspaceCommand", params: ["command": "custom-agent --review"]))

        await waitUntil { hosting.backgroundCommandOpenRequests.count == 1 }

        let request = try #require(hosting.backgroundCommandOpenRequests.first)
        #expect(request.sessionID == "session-start")
        #expect(request.workspaceID == "workspace-1")
        #expect(request.title == "shell-1")
        #expect(request.workingDirectory == "/tmp/workspace")
        #expect(request.shell == "/bin/zsh")
        #expect(request.command == "custom-agent --review")
        #expect(request.kind == .shell)
    }

    @Test func closeRetainsTheControllerUntilAnOutstandingStartAgentCommandSettles() async throws {
        let gateway = RecordingCodePaneDeviceGateway()
        let hosting = DeviceCodePaneHostingDouble(device: fakeDevice())
        let evaluator = RecordingCodePaneScriptEvaluator()
        weak var retainedByStart: CodePaneContentController?
        await gateway.holdNextWorkspaceCommandStartAttempts(1)

        do {
            let content = makeController(hosting: hosting, deviceGateway: gateway)
            content.activate(focus: false)
            content.scriptEvaluator = evaluator
            content.dispatch(.init(id: "start-before-close", method: "startWorkspaceCommand", params: ["command": "custom-agent --review"]))
            await gateway.waitForWorkspaceCommandStartCallCount(1)
            content.close()
            retainedByStart = content
        }

        evaluator.completeOldestPending(with: "__none__")
        #expect(retainedByStart != nil, "a start command that can create a background session must keep its close handoff alive")

        await gateway.completeHeldWorkspaceCommandStartCall(at: 0, result: startedCommandResponse())
        await waitUntil { hosting.backgroundCommandSessionIDs == ["session-start"] }
        await waitUntil { retainedByStart == nil }
    }

    @Test func returningToAWorkspaceWaitsForAnOutstandingStartAgentCommandBeforeRestoring() async throws {
        let storage = MemoryCodePaneWorkspaceStateStorage()
        let gateway = RecordingCodePaneDeviceGateway()
        let hosting = DeviceCodePaneHostingDouble(device: fakeDevice())
        await gateway.holdNextWorkspaceCommandStartAttempts(1)
        let firstA = makeController(hosting: hosting, deviceGateway: gateway, workspaceStateStore: storage)
        firstA.activate(focus: false)
        let outgoingEvaluator = RecordingCodePaneScriptEvaluator()
        firstA.scriptEvaluator = outgoingEvaluator
        firstA.dispatch(.init(id: "start-before-retarget", method: "startWorkspaceCommand", params: ["command": "custom-agent --review"]))
        await gateway.waitForWorkspaceCommandStartCallCount(1)
        firstA.close()
        outgoingEvaluator.completeOldestPending(with: "__none__")

        let returningA = makeController(hosting: hosting, deviceGateway: gateway, workspaceStateStore: storage)
        returningA.activate(focus: false)
        let returningEvaluator = RecordingCodePaneScriptEvaluator()
        returningA.scriptEvaluator = returningEvaluator
        returningA.handleReady()
        #expect(!returningEvaluator.evaluatedScripts.contains { $0.contains("spaces:init") })

        await gateway.completeHeldWorkspaceCommandStartCall(at: 0, result: startedCommandResponse())
        await waitUntil { returningEvaluator.evaluatedScripts.contains { $0.contains("spaces:init") } }
        let restored = try #require(returningEvaluator.evaluatedScripts.first { $0.contains("spaces:init") })
        let state = try initWorkspaceState(in: restored)
        #expect(state.pendingAgentLaunch?.sessionId == "session-start")
        #expect(state.pendingAgentLaunch?.command == "custom-agent --review")
        #expect(state.pendingAgentLaunch?.status == "starting")
        #expect(hosting.backgroundCommandSessionIDs == ["session-start"])
    }

    @Test func hibernatingBeforeAStartAgentReplyWaitsToRehydrateUntilTheLaunchIsPersisted() async throws {
        let storage = MemoryCodePaneWorkspaceStateStorage()
        let gateway = RecordingCodePaneDeviceGateway()
        let hosting = DeviceCodePaneHostingDouble(device: fakeDevice())
        let content = makeController(hosting: hosting, deviceGateway: gateway, workspaceStateStore: storage)
        let outgoingEvaluator = RecordingCodePaneScriptEvaluator()
        await gateway.holdNextWorkspaceCommandStartAttempts(1)
        content.activate(focus: false)
        content.scriptEvaluator = outgoingEvaluator
        content.dispatch(.init(id: "start-before-hibernate", method: "startWorkspaceCommand", params: ["command": "custom-agent --review"]))
        await gateway.waitForWorkspaceCommandStartCallCount(1)

        content.deactivate()
        outgoingEvaluator.completeOldestPending(with: "__none__")

        content.activate(focus: false)
        let returningEvaluator = RecordingCodePaneScriptEvaluator()
        content.scriptEvaluator = returningEvaluator
        content.handleReady()
        #expect(!returningEvaluator.evaluatedScripts.contains { $0.contains("spaces:init") })

        await gateway.completeHeldWorkspaceCommandStartCall(at: 0, result: startedCommandResponse())
        await waitUntil { returningEvaluator.evaluatedScripts.contains { $0.contains("spaces:init") } }
        let restored = try #require(returningEvaluator.evaluatedScripts.first { $0.contains("spaces:init") })
        let state = try initWorkspaceState(in: restored)
        #expect(state.pendingAgentLaunch?.sessionId == "session-start")
        #expect(state.pendingAgentLaunch?.status == "starting")

        content.deactivate()
        returningEvaluator.completeOldestPending(with: "__none__")
    }

    @Test func aStartAgentReplyWhileHibernatedPersistsWithoutCreatingAHiddenTracker() async throws {
        let storage = MemoryCodePaneWorkspaceStateStorage()
        let gateway = RecordingCodePaneDeviceGateway()
        let hosting = DeviceCodePaneHostingDouble(device: fakeDevice())
        let content = makeController(hosting: hosting, deviceGateway: gateway, workspaceStateStore: storage)
        let clock = ControllableAgentStartClock(Date(timeIntervalSince1970: 0))
        content.agentStartReadinessTimeout = 10
        content.agentStartPollInterval = .milliseconds(1)
        content.agentStartNow = {
            let now = clock.now()
            clock.advance(by: AgentSpawnReadiness.inputReadinessConfirmation)
            return now
        }
        let evaluator = RecordingCodePaneScriptEvaluator()
        await gateway.holdNextWorkspaceCommandStartAttempts(1)
        content.activate(focus: false)
        content.scriptEvaluator = evaluator
        content.handleReady()
        content.dispatch(.init(id: "start-while-hibernating", method: "startWorkspaceCommand", params: ["command": "custom-agent --review"]))
        await gateway.waitForWorkspaceCommandStartCallCount(1)

        content.deactivate()
        evaluator.completeOldestPending(with: "__none__")
        let readyAgent = CodePaneAgentStartSnapshot(
            state: .running, detectedKind: .claude, bracketedPasteActive: true,
            agent: .init(id: "agent-start", label: "Claude", sessionID: "session-start"))
        for _ in 0..<4 { await gateway.enqueueWorkspaceCommandStartSnapshot(.success(readyAgent)) }
        await gateway.completeHeldWorkspaceCommandStartCall(at: 0, result: startedCommandResponse())

        await waitUntil {
            guard let stateJSON = try? storage.stateJSON(workspaceID: "workspace-1"),
                let state = try? JSONDecoder().decode(CodePaneWorkspaceState.self, from: Data(stateJSON.utf8))
            else { return false }
            return state.pendingAgentLaunch?.status == "starting"
        }
        await settle(.milliseconds(25))
        let stored = try #require(try storage.stateJSON(workspaceID: "workspace-1"))
        let recovered = try JSONDecoder().decode(CodePaneWorkspaceState.self, from: Data(stored.utf8))
        #expect(recovered.selectedAgentSessionId == nil)
        #expect(recovered.pendingAgentLaunch?.sessionId == "session-start")
        #expect(recovered.pendingAgentLaunch?.status == "starting")
    }

    @Test func aStartAgentDetectedWhileItsEditorIsHibernatingRemainsAssignedAfterTheDeadline() async throws {
        let storage = MemoryCodePaneWorkspaceStateStorage()
        let agent = CodePaneRunningAgent(id: "agent-start", label: "Claude", sessionID: "session-start")
        let hosting = DeviceCodePaneHostingDouble(device: fakeDevice(), agents: [agent])
        let gateway = RecordingCodePaneDeviceGateway()
        await gateway.setWorkspaceCommandStartResult(.success(startedCommandResponse()))
        let content = makeController(hosting: hosting, deviceGateway: gateway, workspaceStateStore: storage)
        let clock = ControllableAgentStartClock(Date(timeIntervalSince1970: 0))
        content.agentStartReadinessTimeout = 10
        content.agentStartPollInterval = .seconds(60)
        content.agentStartNow = { clock.now() }
        content.activate(focus: false)
        let outgoingEvaluator = RecordingCodePaneScriptEvaluator()
        content.scriptEvaluator = outgoingEvaluator
        content.handleReady()
        content.dispatch(.init(id: "start-before-hibernate", method: "startWorkspaceCommand", params: ["command": "custom-agent --review"]))
        await waitUntil {
            outgoingEvaluator.evaluatedScripts.contains { $0.contains("start-before-hibernate") && $0.contains("\"status\":\"starting\"") }
        }

        // Hibernation deliberately stops the native observer. The durable command association and
        // original deadline survive while the hook registers in the background terminal.
        content.deactivate()
        outgoingEvaluator.completeOldestPending(with: "__none__")
        clock.advance(by: 20)

        content.activate(focus: false)
        let returningEvaluator = RecordingCodePaneScriptEvaluator()
        content.scriptEvaluator = returningEvaluator
        content.handleReady()
        await waitUntil { returningEvaluator.evaluatedScripts.contains { $0.contains("spaces:init") } }

        let readyAgent = CodePaneAgentStartSnapshot(state: .running, detectedKind: .claude, bracketedPasteActive: true, agent: agent)
        await gateway.enqueueWorkspaceCommandStartSnapshot(.success(readyAgent))
        content.dispatch(.init(id: "resume-after-hibernate", method: "resumeWorkspaceCommandTracking", params: ["sessionId": "session-start"]))

        await waitUntil {
            returningEvaluator.evaluatedScripts.contains {
                $0.contains("spaces:agentStartStatus") && $0.contains("\"sessionId\":\"session-start\"") && $0.contains("\"status\":\"detected\"")
            }
        }
        await waitUntil {
            guard let stateJSON = try? storage.stateJSON(workspaceID: "workspace-1"),
                let state = try? JSONDecoder().decode(CodePaneWorkspaceState.self, from: Data(stateJSON.utf8))
            else { return false }
            return state.selectedAgentSessionId == "session-start" && state.pendingAgentLaunch == nil
        }

        content.deactivate()
        returningEvaluator.completeOldestPending(with: "__none__")
    }

    @Test func aStartAgentDetectedAfterARetargetRemainsAssignedToItsExactSession() async throws {
        let storage = MemoryCodePaneWorkspaceStateStorage()
        let agent = CodePaneRunningAgent(id: "agent-start", label: "Claude", sessionID: "session-start")
        let hosting = DeviceCodePaneHostingDouble(device: fakeDevice(), agents: [agent])
        let gateway = RecordingCodePaneDeviceGateway()
        await gateway.setWorkspaceCommandStartResult(.success(startedCommandResponse()))
        let clock = ControllableAgentStartClock(Date(timeIntervalSince1970: 0))
        let outgoingEvaluator = RecordingCodePaneScriptEvaluator()

        do {
            let firstA = makeController(hosting: hosting, deviceGateway: gateway, workspaceStateStore: storage)
            firstA.agentStartReadinessTimeout = 10
            firstA.agentStartPollInterval = .seconds(60)
            firstA.agentStartNow = { clock.now() }
            firstA.activate(focus: false)
            firstA.scriptEvaluator = outgoingEvaluator
            firstA.handleReady()
            firstA.dispatch(.init(id: "start-before-retarget", method: "startWorkspaceCommand", params: ["command": "custom-agent --review"]))
            await waitUntil {
                outgoingEvaluator.evaluatedScripts.contains { $0.contains("start-before-retarget") && $0.contains("\"status\":\"starting\"") }
            }

            firstA.close()
        }
        outgoingEvaluator.completeOldestPending(with: "__none__")

        // The singleton Editor retargets through B. A's observer is gone, but its durable command
        // association can still be reconciled when the user returns after the original deadline.
        let b = CodePaneContentController(
            paneID: "pane-1", deviceID: "device-1", workspaceID: "workspace-2", initialMode: .diff, hosting: hosting, workspaceStateStore: storage)
        b.close()
        clock.advance(by: 20)

        let readyAgent = CodePaneAgentStartSnapshot(state: .running, detectedKind: .claude, bracketedPasteActive: true, agent: agent)
        await gateway.enqueueWorkspaceCommandStartSnapshot(.success(readyAgent))
        let returningA = makeController(hosting: hosting, deviceGateway: gateway, workspaceStateStore: storage)
        returningA.agentStartNow = { clock.now() }
        returningA.activate(focus: false)
        let returningEvaluator = RecordingCodePaneScriptEvaluator()
        returningA.scriptEvaluator = returningEvaluator
        returningA.handleReady()
        await waitUntil { returningEvaluator.evaluatedScripts.contains { $0.contains("spaces:init") } }
        returningA.dispatch(.init(id: "resume-after-retarget", method: "resumeWorkspaceCommandTracking", params: ["sessionId": "session-start"]))

        await waitUntil {
            returningEvaluator.evaluatedScripts.contains {
                $0.contains("spaces:agentStartStatus") && $0.contains("\"sessionId\":\"session-start\"") && $0.contains("\"status\":\"detected\"")
            }
        }
        await waitUntil {
            guard let stateJSON = try? storage.stateJSON(workspaceID: "workspace-1"),
                let state = try? JSONDecoder().decode(CodePaneWorkspaceState.self, from: Data(stateJSON.utf8))
            else { return false }
            return state.selectedAgentSessionId == "session-start" && state.pendingAgentLaunch == nil
        }
        returningA.close()
        returningEvaluator.completeOldestPending(with: "__none__")
    }

    @Test func startAgentInsertsItsTerminalInBackgroundThenReportsAnExitedCommand() async throws {
        let storage = MemoryCodePaneWorkspaceStateStorage()
        let gateway = RecordingCodePaneDeviceGateway()
        await gateway.setWorkspaceCommandStartResult(.success(startedCommandResponse()))
        await gateway.enqueueWorkspaceCommandStartSnapshot(
            .success(.init(state: .exited, detectedKind: nil, bracketedPasteActive: false, agent: nil)))
        let hosting = DeviceCodePaneHostingDouble(device: fakeDevice())
        let content = makeController(hosting: hosting, deviceGateway: gateway, workspaceStateStore: storage)
        content.activate(focus: false)
        let evaluator = RecordingCodePaneScriptEvaluator()
        content.scriptEvaluator = evaluator
        content.handleReady()

        content.dispatch(.init(id: "start", method: "startWorkspaceCommand", params: ["command": "custom-agent --review"]))

        await waitUntil {
            evaluator.evaluatedScripts.contains { $0.contains("start") && $0.contains("\"status\":\"starting\"") }
                && evaluator.evaluatedScripts.contains { $0.contains("spaces:agentStartStatus") && $0.contains("\"status\":\"exited\"") }
        }
        let startCall = try #require(await gateway.workspaceCommandStartCalls.first)
        #expect(startCall.workspaceID == "workspace-1")
        #expect(startCall.command == "custom-agent --review")
        #expect(hosting.backgroundCommandSessionIDs == ["session-start"])
        let stored = try #require(try storage.stateJSON(workspaceID: "workspace-1"))
        let recovered = try JSONDecoder().decode(CodePaneWorkspaceState.self, from: Data(stored.utf8))
        #expect(
            recovered.pendingAgentLaunch
                == .init(
                    sessionId: "session-start", command: "custom-agent --review", status: "failed",
                    message: "The command exited (exited) before an agent was detected.", deadlineEpochMilliseconds: nil))
    }

    @Test func aRestoredStartAgentCommandReportsDetectedOnlyForItsExactSession() async throws {
        let storage = MemoryCodePaneWorkspaceStateStorage()
        let state = completeWorkspaceState()
        let document = CodePaneWorkspaceState(
            mode: .editor, scope: state.scope, diffLayout: state.diffLayout, diffSelectedPath: state.diffSelectedPath,
            diffTreeExpandedPaths: state.diffTreeExpandedPaths, diffTreeSelectedPath: state.diffTreeSelectedPath,
            fileTreeExpandedPaths: state.fileTreeExpandedPaths, fileTreeSelectedPath: state.fileTreeSelectedPath,
            editorSidebarMode: state.editorSidebarMode, editorRecentPaths: state.editorRecentPaths, diffScrollLine: state.diffScrollLine,
            diffScrollSide: state.diffScrollSide, diffFocusedPath: state.diffFocusedPath, diffFocusedLine: state.diffFocusedLine,
            diffFocusedSide: state.diffFocusedSide, editorScrollLine: state.editorScrollLine, editorFocusedLine: state.editorFocusedLine,
            editorState: state.editorState, diffEditorState: state.diffEditorState, pendingReviewComments: state.pendingReviewComments,
            selectedAgentSessionId: nil,
            pendingAgentLaunch: .init(
                sessionId: "session-start", command: "custom-agent --review", status: "starting", message: nil,
                deadlineEpochMilliseconds: 9_999_999_999_999))
        try storage.setStateJSON(String(decoding: try JSONEncoder().encode(document), as: UTF8.self), workspaceID: "workspace-1")
        CodePaneWorkspaceStateCache.remove(storageKey: storage.workspaceStateStorageKey, workspaceID: "workspace-1")

        let gateway = RecordingCodePaneDeviceGateway()
        let readyAgent = CodePaneAgentStartSnapshot(
            state: .running, detectedKind: .claude, bracketedPasteActive: true,
            agent: .init(id: "agent-start", label: "Claude", sessionID: "session-start"))
        await gateway.enqueueWorkspaceCommandStartSnapshot(.success(readyAgent))
        await gateway.enqueueWorkspaceCommandStartSnapshot(.success(readyAgent))
        let hosting = DeviceCodePaneHostingDouble(device: fakeDevice())
        let content = makeController(hosting: hosting, deviceGateway: gateway, workspaceStateStore: storage)
        let clock = ControllableAgentStartClock(Date(timeIntervalSince1970: 1_000))
        content.agentStartNow = {
            let now = clock.now()
            clock.advance(by: AgentSpawnReadiness.inputReadinessConfirmation)
            return now
        }
        content.agentStartPollInterval = .milliseconds(1)
        content.activate(focus: false)
        let evaluator = RecordingCodePaneScriptEvaluator()
        content.scriptEvaluator = evaluator
        content.handleReady()

        content.dispatch(.init(id: "resume", method: "resumeWorkspaceCommandTracking", params: ["sessionId": "session-start"]))
        await waitUntil {
            evaluator.evaluatedScripts.contains { $0.contains("resume") && $0.contains("\"status\":\"starting\"") }
                && evaluator.evaluatedScripts.contains {
                    $0.contains("spaces:agentStartStatus") && $0.contains("\"sessionId\":\"session-start\"") && $0.contains("\"status\":\"detected\"")
                }
        }

        let stored = try #require(try storage.stateJSON(workspaceID: "workspace-1"))
        let recovered = try JSONDecoder().decode(CodePaneWorkspaceState.self, from: Data(stored.utf8))
        #expect(recovered.pendingAgentLaunch == nil)
        #expect(recovered.selectedAgentSessionId == "session-start")
    }

    @Test func aRestoredStartAgentCommandWaitsForStableReadinessBeforeReportingDetection() async throws {
        let storage = MemoryCodePaneWorkspaceStateStorage()
        let document = CodePaneWorkspaceState(
            mode: .diff, editorState: nil, pendingReviewComments: nil,
            pendingAgentLaunch: .init(
                sessionId: "session-start", command: "custom-agent --review", status: "starting", message: nil,
                deadlineEpochMilliseconds: 9_999_999_999_999))
        try storage.setStateJSON(String(decoding: try JSONEncoder().encode(document), as: UTF8.self), workspaceID: "workspace-1")
        CodePaneWorkspaceStateCache.remove(storageKey: storage.workspaceStateStorageKey, workspaceID: "workspace-1")

        let agent = CodePaneRunningAgent(id: "agent-start", label: "Claude", sessionID: "session-start")
        let readyAgent = CodePaneAgentStartSnapshot(state: .running, detectedKind: .claude, bracketedPasteActive: true, agent: agent)
        let gateway = RecordingCodePaneDeviceGateway()
        // The first sample verifies that the terminal still belongs to this workspace. The tracker
        // must independently establish stable readiness before it may use the same agent row.
        for _ in 0..<32 { await gateway.enqueueWorkspaceCommandStartSnapshot(.success(readyAgent)) }
        let hosting = DeviceCodePaneHostingDouble(device: fakeDevice())
        let content = makeController(hosting: hosting, deviceGateway: gateway, workspaceStateStore: storage)
        let clock = ControllableAgentStartClock(Date(timeIntervalSince1970: 1_000))
        content.agentStartNow = { clock.now() }
        content.agentStartPollInterval = .milliseconds(1)
        content.activate(focus: false)
        let evaluator = RecordingCodePaneScriptEvaluator()
        content.scriptEvaluator = evaluator
        content.handleReady()

        content.dispatch(.init(id: "resume-stable", method: "resumeWorkspaceCommandTracking", params: ["sessionId": "session-start"]))
        await waitUntil { evaluator.evaluatedScripts.contains { $0.contains("resume-stable") && $0.contains("\"status\":\"starting\"") } }
        await settle(.milliseconds(20))
        #expect(!evaluator.evaluatedScripts.contains { $0.contains("spaces:agentStartStatus") && $0.contains("\"status\":\"detected\"") })

        clock.advance(by: AgentSpawnReadiness.inputReadinessConfirmation)
        await waitUntil {
            evaluator.evaluatedScripts.contains {
                $0.contains("spaces:agentStartStatus") && $0.contains("\"sessionId\":\"session-start\"") && $0.contains("\"status\":\"detected\"")
            }
        }
    }

    @Test func aRestoredStartAgentCommandDoesNotReceiveAFreshReadinessDeadline() async throws {
        let storage = MemoryCodePaneWorkspaceStateStorage()
        let deadlineEpochMilliseconds: Int64 = 1_000
        let document = CodePaneWorkspaceState(
            mode: .diff, editorState: nil, pendingReviewComments: nil,
            pendingAgentLaunch: .init(
                sessionId: "session-start", command: "custom-agent --review", status: "starting", message: nil,
                deadlineEpochMilliseconds: deadlineEpochMilliseconds))
        try storage.setStateJSON(String(decoding: try JSONEncoder().encode(document), as: UTF8.self), workspaceID: "workspace-1")
        CodePaneWorkspaceStateCache.remove(storageKey: storage.workspaceStateStorageKey, workspaceID: "workspace-1")

        let gateway = RecordingCodePaneDeviceGateway()
        let running = CodePaneAgentStartSnapshot(state: .running, detectedKind: nil, bracketedPasteActive: false, agent: nil)
        await gateway.enqueueWorkspaceCommandStartSnapshot(.success(running))
        await gateway.enqueueWorkspaceCommandStartSnapshot(.success(running))
        let hosting = DeviceCodePaneHostingDouble(device: fakeDevice())
        let content = makeController(hosting: hosting, deviceGateway: gateway, workspaceStateStore: storage)
        content.agentStartReadinessTimeout = 300
        content.agentStartPollInterval = .milliseconds(1)
        content.agentStartNow = { Date(timeIntervalSince1970: 2) }
        content.activate(focus: false)
        let evaluator = RecordingCodePaneScriptEvaluator()
        content.scriptEvaluator = evaluator
        content.handleReady()

        content.dispatch(.init(id: "resume-expired", method: "resumeWorkspaceCommandTracking", params: ["sessionId": "session-start"]))
        await waitUntil(timeout: .milliseconds(100)) {
            evaluator.evaluatedScripts.contains { $0.contains("spaces:agentStartStatus") && $0.contains("\"status\":\"timedOut\"") }
        }

        // Persistence is enqueued to an async coalescing writer, so poll for the drained state
        // rather than reading storage once right after the script event fires.
        await waitUntil {
            guard let stored = try? storage.stateJSON(workspaceID: "workspace-1"),
                let recovered = try? JSONDecoder().decode(CodePaneWorkspaceState.self, from: Data(stored.utf8))
            else { return false }
            return recovered.pendingAgentLaunch?.status == "failed" && recovered.pendingAgentLaunch?.deadlineEpochMilliseconds == nil
        }
        let stored = try #require(try storage.stateJSON(workspaceID: "workspace-1"))
        let recovered = try JSONDecoder().decode(CodePaneWorkspaceState.self, from: Data(stored.utf8))
        #expect(recovered.pendingAgentLaunch?.status == "failed")
        #expect(recovered.pendingAgentLaunch?.deadlineEpochMilliseconds == nil)
    }

    @Test func startAgentReportsATimeoutAndKeepsTheTypedCommandForRetry() async throws {
        let storage = MemoryCodePaneWorkspaceStateStorage()
        let gateway = RecordingCodePaneDeviceGateway()
        await gateway.setWorkspaceCommandStartResult(.success(startedCommandResponse()))
        await gateway.enqueueWorkspaceCommandStartSnapshot(
            .success(.init(state: .running, detectedKind: nil, bracketedPasteActive: false, agent: nil)))
        let hosting = DeviceCodePaneHostingDouble(device: fakeDevice())
        let content = makeController(hosting: hosting, deviceGateway: gateway, workspaceStateStore: storage)
        content.agentStartReadinessTimeout = 0
        content.agentStartPollInterval = .milliseconds(1)
        content.activate(focus: false)
        let evaluator = RecordingCodePaneScriptEvaluator()
        content.scriptEvaluator = evaluator
        content.handleReady()

        content.dispatch(.init(id: "start", method: "startWorkspaceCommand", params: ["command": "custom-agent --review"]))
        await waitUntil { evaluator.evaluatedScripts.contains { $0.contains("spaces:agentStartStatus") && $0.contains("\"status\":\"timedOut\"") } }

        // Persistence is enqueued to an async coalescing writer, so poll for the drained state
        // rather than reading storage once right after the script event fires.
        await waitUntil {
            guard let stored = try? storage.stateJSON(workspaceID: "workspace-1"),
                let recovered = try? JSONDecoder().decode(CodePaneWorkspaceState.self, from: Data(stored.utf8))
            else { return false }
            return recovered.pendingAgentLaunch?.status == "failed"
        }
        let stored = try #require(try storage.stateJSON(workspaceID: "workspace-1"))
        let recovered = try JSONDecoder().decode(CodePaneWorkspaceState.self, from: Data(stored.utf8))
        #expect(recovered.pendingAgentLaunch?.command == "custom-agent --review")
        #expect(recovered.pendingAgentLaunch?.status == "failed")
    }

}
