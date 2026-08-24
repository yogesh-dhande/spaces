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
}

/// A `CodePaneHosting` double that resolves to a real (fake-populated) device, for the RPC-dispatch
/// tests below that need `performWorkspaceDiff` to reach the gateway seam instead of failing at the
/// device lookup.
@MainActor private final class DeviceCodePaneHostingDouble: CodePaneHosting {
    let device: SpacesPairedDeviceRecord
    init(device: SpacesPairedDeviceRecord) { self.device = device }
    func codePaneDevice(workspaceID: String) -> SpacesPairedDeviceRecord? { device }
    func codePaneWorkspaceInfo(workspaceID: String) -> (name: String, baseBranch: String?)? { (name: "workspace", baseBranch: nil) }
    func codePaneCurrentAppearance() -> ThemeAppearance { .dark }
    func codePaneRunningAgents(workspaceID: String) -> [CodePaneRunningAgent] { [] }
}

/// A `CodePaneHosting` double whose `codePaneDevice` lookup fails (returns `nil`) for a configurable
/// number of calls after the first, then succeeds — reproducing round-6 Fix 2's target scenario: the
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
}

/// Records every script it's asked to evaluate, standing in for the live `WKWebView` so a test can
/// observe exactly what a reply/pushed event would have sent without a real page running.
@MainActor private final class RecordingCodePaneScriptEvaluator: CodePaneScriptEvaluator {
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
        if !queuedResults.isEmpty {
            completion(queuedResults.removeFirst())
        } else {
            pendingCompletions.append((script, completion))
        }
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

/// Gates `workspaceDiff` on demand and records every `subscribeWorkspaceDiffSignature` call, so tests
/// can reproduce the races the round-1 fixes guard against: an in-flight diff completing after the
/// pane hibernates, two overlapping diffs completing out of order, and a stream disconnect racing a
/// newer resubscribe. An `actor` because these calls are exercised from the controller's own
/// unstructured `Task`s, concurrently with the test's assertions.
private actor RecordingCodePaneDeviceGateway: CodePaneDeviceGateway {
    // Keyed by a stable arrival index (assigned once, never reused) rather than raw array position:
    // `completeDiffCall` removes entries as they complete, so a test that completes an earlier call
    // before a later one arrives (Fix 4's disconnect tests do exactly this) would otherwise see
    // `pendingDiffCalls` shrink back toward zero instead of growing, and `at:` positions would drift
    // out from under still-pending calls once an earlier one is removed.
    private var pendingDiffCalls: [(arrivalIndex: Int, continuation: CheckedContinuation<SpacesDeviceWorkspaceDiffResult, Never>)] = []
    private var diffCallArrivalCount = 0
    private var diffArrivalWaiters: [CheckedContinuation<Void, Never>] = []
    private var subscribedRefNames: [String?] = []
    private var subscribedDisconnectHandlers: [@Sendable (Error?) -> Void] = []
    private var subscribedFrameHandlers: [@Sendable (SpacesDeviceWorkspaceDiffSignatureFrame) -> Void] = []
    private var subscribeArrivalWaiters: [CheckedContinuation<Void, Never>] = []
    private var subscribeFailuresRemaining = 0
    private var subscribeAttempts = 0
    private var subscribeAttemptWaiters: [CheckedContinuation<Void, Never>] = []
    /// Held `subscribeWorkspaceDiffSignature` calls (Fix 5's stale-generation tests): keyed by the same
    /// kind of stable arrival index `pendingDiffCalls` uses, so a test can let later attempts resolve
    /// (or fail) while an earlier one stays outstanding, then choose when the earlier one finally
    /// settles — reproducing an A→B→A scope sequence where the FIRST A's attempt resolves LAST.
    private var pendingSubscribeCalls:
        [(arrivalIndex: Int, refName: String?, onFrame: @Sendable (SpacesDeviceWorkspaceDiffSignatureFrame) -> Void,
            onDisconnect: @Sendable ((any Error)?) -> Void, continuation: CheckedContinuation<any CodePaneDiffSignatureStreamHandle, any Error>)] = []
    private var subscribeCallArrivalCount = 0
    /// `subscribeWorkspaceDiffSignature` calls to hold open (not resolve immediately) rather than
    /// answering right away, counted down on each arrival — mirrors `subscribeFailuresRemaining`'s
    /// shape but for "hold" instead of "fail".
    private var holdNextSubscribeAttempts = 0

    /// Thrown by `subscribeWorkspaceDiffSignature` while `subscribeFailuresRemaining > 0`, so a test
    /// can force `resubscribeDiffSignature`'s failure arm (Fix 2's backoff retry) deterministically
    /// instead of needing a real subscribe failure.
    private struct InjectedSubscribeFailure: Error {}

    func workspaceDiff(workspaceID: String, refName: String?, device: SpacesPairedDeviceRecord) async throws -> SpacesDeviceWorkspaceDiffResult {
        await withCheckedContinuation { (continuation: CheckedContinuation<SpacesDeviceWorkspaceDiffResult, Never>) in
            let arrivalIndex = diffCallArrivalCount
            diffCallArrivalCount += 1
            pendingDiffCalls.append((arrivalIndex, continuation))
            drainDiffArrivalWaiters()
        }
    }

    func subscribeWorkspaceDiffSignature(
        workspaceID: String, refName: String?, device: SpacesPairedDeviceRecord,
        onFrame: @escaping @Sendable (SpacesDeviceWorkspaceDiffSignatureFrame) -> Void,
        onDisconnect: @escaping @Sendable ((any Error)?) -> Void
    ) async throws -> any CodePaneDiffSignatureStreamHandle {
        subscribeAttempts += 1
        drainSubscribeAttemptWaiters()
        if holdNextSubscribeAttempts > 0 {
            holdNextSubscribeAttempts -= 1
            let arrivalIndex = subscribeCallArrivalCount
            subscribeCallArrivalCount += 1
            return try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<any CodePaneDiffSignatureStreamHandle, any Error>) in
                pendingSubscribeCalls.append((arrivalIndex, refName, onFrame, onDisconnect, continuation))
            }
        }
        if subscribeFailuresRemaining > 0 {
            subscribeFailuresRemaining -= 1
            throw InjectedSubscribeFailure()
        }
        subscribedRefNames.append(refName)
        subscribedDisconnectHandlers.append(onDisconnect)
        subscribedFrameHandlers.append(onFrame)
        drainSubscribeArrivalWaiters()
        return FakeDiffSignatureStreamHandle()
    }

    /// Makes the next `count` `subscribeWorkspaceDiffSignature` calls throw, so a test can exercise
    /// `resubscribeDiffSignature`'s failure arm (Fix 2's backoff retry) without a real failure.
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
        subscribedDisconnectHandlers.append(held.onDisconnect)
        subscribedFrameHandlers.append(held.onFrame)
        drainSubscribeArrivalWaiters()
        held.continuation.resume(returning: handle)
        return handle
    }

    /// Resolves the held `subscribeWorkspaceDiffSignature` call at `index` with a thrown failure instead
    /// of a success, so a test can drive the STALE-attempt-fails variant of the round-4 Fix 5 tests.
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

    /// Completes the `workspaceDiff` call at `index` (0-based, arrival order — stable even once an
    /// earlier or later call has already completed and been removed), leaving other pending calls
    /// untouched — this is what lets a test complete calls out of arrival order.
    func completeDiffCall(at index: Int, result: SpacesDeviceWorkspaceDiffResult) {
        guard let position = pendingDiffCalls.firstIndex(where: { $0.arrivalIndex == index }) else {
            preconditionFailure("no pending workspaceDiff call at arrival index \(index)")
        }
        pendingDiffCalls.remove(at: position).continuation.resume(returning: result)
    }

    func subscribedRefName(at index: Int) -> String? { subscribedRefNames[index] }

    func subscribeCallCount() -> Int { subscribedRefNames.count }

    /// Every `workspaceDiff` call that has arrived so far, successful or still pending — a direct
    /// (non-waiting) read, mirroring `subscribeCallCount()`'s shape, for a "this must never happen"
    /// test that settles a fixed duration and then checks the count stayed at zero.
    func diffCallCount() -> Int { diffCallArrivalCount }

    func triggerDisconnect(at index: Int) { subscribedDisconnectHandlers[index](nil) }

    /// Delivers a `spaces:diffSignature`-worthy frame on the subscription opened at `index` (0-based,
    /// subscribe-call arrival order), standing in for the daemon's `DeviceOverviewStreamServer`
    /// pushing a signature over the live stream (round-4 Fix 3's dedupe tests).
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

    private struct InjectedFileSubscribeFailure: Error {}

    func workspaceFileRead(workspaceID: String, relativePath: String, device: SpacesPairedDeviceRecord) async throws
        -> SpacesDeviceWorkspaceFileReadResult
    {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<SpacesDeviceWorkspaceFileReadResult, any Error>) in
            let arrivalIndex = fileReadCallArrivalCount
            fileReadCallArrivalCount += 1
            pendingFileReadCalls.append((arrivalIndex, continuation))
            drainFileReadArrivalWaiters()
        }
    }

    func subscribeWorkspaceFileSignature(
        workspaceID: String, relativePath: String, device: SpacesPairedDeviceRecord,
        onFrame: @escaping @Sendable (SpacesDeviceWorkspaceFileSignatureFrame) -> Void,
        onDisconnect: @escaping @Sendable ((any Error)?) -> Void
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
    /// round-16 Fix 1b: `workspaceReviewCommentUpsert` calls to hold open rather than answering right
    /// away, counted down on each arrival — mirrors `holdNextSubscribeAttempts`'s shape, simplified
    /// (no ref names/handlers to track) since nothing here needs arrival-order bookkeeping beyond a
    /// single held call at a time for the "resumes even after teardown" test.
    private var holdNextUpsertAttempts = 0
    private var pendingUpsertCalls: [(arrivalIndex: Int, continuation: CheckedContinuation<SpacesDeviceReviewComment, any Error>)] = []
    private var upsertCallArrivalCount = 0

    private(set) var reviewCommentDeleteCalls: [(workspaceID: String, id: String)] = []
    private var reviewCommentDeleteResult: Result<SpacesDeviceAPIResponse, any Error> = .success(SpacesDeviceAPIResponse(ok: true, message: "Deleted."))

    private(set) var reviewCommentsSendCalls: [(workspaceID: String, sessionID: String, text: String, comments: [SpacesDeviceReviewCommentSendEntry])] = []
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

    /// round-16 Fix 1b: makes the next `count` `workspaceReviewCommentUpsert` calls suspend instead of
    /// resolving immediately, so a test can observe the RPC still in flight (e.g. across a teardown)
    /// before completing it via `completeHeldUpsertCall`.
    func holdNextUpsertAttempts(_ count: Int) { holdNextUpsertAttempts = count }

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
        return try reviewCommentDeleteResult.get()
    }

    func workspaceReviewCommentsSend(
        workspaceID: String, sessionID: String, text: String, comments: [SpacesDeviceReviewCommentSendEntry], device: SpacesPairedDeviceRecord
    ) async throws -> SpacesDeviceAPIResponse {
        reviewCommentsSendCalls.append((workspaceID, sessionID, text, comments))
        return try reviewCommentsSendResult.get()
    }
}

/// Covers `CodePaneContentController`'s hibernation seam: `contentView` is a stable container that
/// survives the controller's whole lifetime, while the `WKWebView` itself is created by `activate()` and
/// torn down by `deactivate()` — the expensive resource a hidden tab must not keep alive.
@MainActor @Suite struct CodePaneContentControllerTests {
    // Held by the suite instance (Swift Testing gives each test its own), not created inline as a
    // call-site temporary: `CodePaneContentController.hosting` is `weak`, so a temporary with no
    // other strong reference would be deallocated the instant `init` returns.
    private let hostingDouble = EmptyCodePaneHostingDouble()

    private func makeController(
        hosting: (any CodePaneHosting)? = nil, deviceGateway: any CodePaneDeviceGateway = LiveCodePaneDeviceGateway()
    ) -> CodePaneContentController {
        CodePaneContentController(
            paneID: "pane-1", deviceID: "device-1", workspaceID: "workspace-1", initialMode: .diff, hosting: hosting ?? hostingDouble,
            deviceGateway: deviceGateway)
    }

    /// Polls `predicate` until it's true or `timeout` elapses, yielding between checks so the
    /// controller's own unstructured `Task`s (spawned from `dispatch`/`resubscribeDiffSignature`, with
    /// no handle the test can `await` directly) get a chance to run. Matches the pattern in
    /// `TerminalLinkOpenCoordinatorTests.waitUntil`.
    private func waitUntil(
        timeout: Duration = .seconds(5), sourceLocation: SourceLocation = #_sourceLocation, _ predicate: @MainActor () -> Bool
    ) async {
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

    private func diffRequest(id: String, scopeKind: String, refName: String? = nil) -> CodePaneBridge.Request {
        var scope: [String: Any] = ["kind": scopeKind]
        if let refName { scope["refName"] = refName }
        return CodePaneBridge.Request(id: id, method: "workspaceDiff", params: ["scope": scope])
    }

    private func fileReadRequest(id: String, path: String) -> CodePaneBridge.Request {
        CodePaneBridge.Request(id: id, method: "workspaceFileRead", params: ["path": path])
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

        content.close()

        #expect(content.contentView.subviews.isEmpty)
    }

    // MARK: - Resource bundle layout (Fix 1)

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

    // MARK: - Stale replies after hibernation (Fix 2)

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

        await gateway.completeDiffCall(at: 0, result: SpacesDeviceWorkspaceDiffResult(scopeSignature: "sig", files: []))
        await settle()

        // `staleEvaluator` does legitimately receive one script from `deactivate()` itself: the
        // teardown flush's collect script (round-6 Fix 1) — issued against whatever evaluator was live
        // the instant the page tore down, which is `staleEvaluator` here. What it must never receive
        // is the stale request's own reply.
        #expect(
            !staleEvaluator.evaluatedScripts.contains { $0.contains("req-1") },
            "the torn-down page's evaluator must never receive the stale reply")
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
        await gateway.completeDiffCall(at: 0, result: SpacesDeviceWorkspaceDiffResult(scopeSignature: "sig", files: []))

        await waitUntil { !evaluator.evaluatedScripts.isEmpty }

        #expect(
            evaluator.evaluatedScripts.contains { $0.contains("req-1") },
            "a reply for a request that's still current (no hibernation in between) must be evaluated")
    }

    // MARK: - Out-of-order diff completions don't retarget the stream (Fix 3)

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
        await gateway.completeDiffCall(at: 1, result: SpacesDeviceWorkspaceDiffResult(scopeSignature: "sig-b", files: []))
        await gateway.waitForSubscribeCallCount(1)
        await gateway.completeDiffCall(at: 0, result: SpacesDeviceWorkspaceDiffResult(scopeSignature: "sig-a", files: []))

        await waitUntil { evaluator.evaluatedScripts.count >= 2 }

        let subscribeCount = await gateway.subscribeCallCount()
        #expect(subscribeCount == 1, "only the second (still-current) scope's completion should have triggered a resubscribe")
        let refName = await gateway.subscribedRefName(at: 0)
        #expect(refName == "feature-branch", "the subscription must target the later scope, not the superseded first one")
    }

    // MARK: - Stream disconnect clears state without clobbering a newer subscription (Fix 4)

    @Test func disconnectClearsSubscribedScopeSoASameScopeDiffCanResubscribe() async {
        let gateway = RecordingCodePaneDeviceGateway()
        let hosting = DeviceCodePaneHostingDouble(device: fakeDevice())
        let content = makeController(hosting: hosting, deviceGateway: gateway)
        content.activate(focus: false)
        content.scriptEvaluator = RecordingCodePaneScriptEvaluator()

        content.dispatch(diffRequest(id: "req-1", scopeKind: "uncommitted"))
        await gateway.waitForDiffCallCount(1)
        await gateway.completeDiffCall(at: 0, result: SpacesDeviceWorkspaceDiffResult(scopeSignature: "sig-1", files: []))
        await gateway.waitForSubscribeCallCount(1)

        // Simulate a real disconnect (e.g. a daemon restart) on the current subscription.
        await gateway.triggerDisconnect(at: 0)
        await settle()

        // A second workspaceDiff for the SAME scope must resubscribe rather than stay skipped
        // forever by `resubscribeDiffSignature`'s same-scope no-op guard.
        content.dispatch(diffRequest(id: "req-2", scopeKind: "uncommitted"))
        await gateway.waitForDiffCallCount(2)
        await gateway.completeDiffCall(at: 1, result: SpacesDeviceWorkspaceDiffResult(scopeSignature: "sig-1", files: []))
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
        await gateway.completeDiffCall(at: 0, result: SpacesDeviceWorkspaceDiffResult(scopeSignature: "sig-1", files: []))
        await gateway.waitForSubscribeCallCount(1)

        // A scope change supersedes it with a second, different-scope subscription.
        content.dispatch(diffRequest(id: "req-2", scopeKind: "ref", refName: "feature-branch"))
        await gateway.waitForDiffCallCount(2)
        await gateway.completeDiffCall(at: 1, result: SpacesDeviceWorkspaceDiffResult(scopeSignature: "sig-2", files: []))
        await gateway.waitForSubscribeCallCount(2)

        // The FIRST (already-superseded) subscription's client disconnects late.
        await gateway.triggerDisconnect(at: 0)
        await settle()

        // A same-scope ("feature-branch") diff must not need to resubscribe: the stale disconnect
        // must not have cleared the newer (still-live) subscription's state.
        content.dispatch(diffRequest(id: "req-3", scopeKind: "ref", refName: "feature-branch"))
        await gateway.waitForDiffCallCount(3)
        await gateway.completeDiffCall(at: 2, result: SpacesDeviceWorkspaceDiffResult(scopeSignature: "sig-2", files: []))
        await settle()

        let count = await gateway.subscribeCallCount()
        #expect(count == 2, "the stale (already-superseded) subscription's disconnect must not force a third resubscribe for the still-current scope")
    }

    // MARK: - A stale subscription ATTEMPT (not just a stale disconnect) survives an A→B→A sequence (round-4 Fix 5)
    //
    // Fix 4 above (`staleDisconnectDoesNotClearANewerSubscriptionsState`) covers a stale DISCONNECT
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
        await gateway.completeDiffCall(at: 0, result: SpacesDeviceWorkspaceDiffResult(scopeSignature: "sig-a1", files: []))
        await gateway.waitForSubscribeAttemptCount(1) // the first A's subscribe attempt has arrived and is now held

        // B: a genuine scope change, subscribes and succeeds normally.
        content.dispatch(diffRequest(id: "req-2", scopeKind: "ref", refName: "feature-branch"))
        await gateway.waitForDiffCallCount(2)
        await gateway.completeDiffCall(at: 1, result: SpacesDeviceWorkspaceDiffResult(scopeSignature: "sig-b", files: []))
        await gateway.waitForSubscribeCallCount(1) // B's subscription opened

        // Second A: back on the SAME scope the still-outstanding first attempt targets; subscribes and
        // succeeds normally, becoming the CURRENT subscription.
        content.dispatch(diffRequest(id: "req-3", scopeKind: "uncommitted"))
        await gateway.waitForDiffCallCount(3)
        await gateway.completeDiffCall(at: 2, result: SpacesDeviceWorkspaceDiffResult(scopeSignature: "sig-a2", files: []))
        await gateway.waitForSubscribeCallCount(2) // second A's subscription opened (now current)

        // Finally, the FIRST A's held attempt resolves — LAST, and for the SAME scope the current
        // (second A) subscription already holds.
        let staleHandle = await gateway.completeHeldSubscribeCall(at: 0)
        await settle()

        #expect(staleHandle.stopCount == 1, "a stale attempt's client must be stopped, not bare-assigned over the current live client")

        // Prove the CURRENT (second A) subscription — not the stale attempt — is the one actually
        // live: trigger ITS disconnect (subscribedDisconnectHandlers index 1, recorded right after B's
        // at index 0) and confirm the reconnect logic reacts to it by resubscribing the same scope.
        await gateway.triggerDisconnect(at: 1)
        await gateway.waitForSubscribeCallCount(4) // B, second A, the stale attempt's belated success, and now this reconnect

        let refName = await gateway.subscribedRefName(at: 3)
        #expect(refName == nil, "the reconnect must retarget the current (second A) scope, proving it — not the stale attempt — was the live subscription")
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
        await gateway.completeDiffCall(at: 0, result: SpacesDeviceWorkspaceDiffResult(scopeSignature: "sig-a1", files: []))
        await gateway.waitForSubscribeAttemptCount(1)

        content.dispatch(diffRequest(id: "req-2", scopeKind: "ref", refName: "feature-branch"))
        await gateway.waitForDiffCallCount(2)
        await gateway.completeDiffCall(at: 1, result: SpacesDeviceWorkspaceDiffResult(scopeSignature: "sig-b", files: []))
        await gateway.waitForSubscribeCallCount(1)

        content.dispatch(diffRequest(id: "req-3", scopeKind: "uncommitted"))
        await gateway.waitForDiffCallCount(3)
        await gateway.completeDiffCall(at: 2, result: SpacesDeviceWorkspaceDiffResult(scopeSignature: "sig-a2", files: []))
        await gateway.waitForSubscribeCallCount(2)

        // The FIRST A's held attempt fails, last, for the SAME scope the current subscription holds.
        await gateway.failHeldSubscribeCall(at: 0)
        await settle()

        // A subsequent same-scope-A diff must stay a no-op for the subscription: if the stale failure
        // had wrongly cleared `subscribedScope`, this would force an unnecessary third subscribe call.
        content.dispatch(diffRequest(id: "req-4", scopeKind: "uncommitted"))
        await gateway.waitForDiffCallCount(4)
        await gateway.completeDiffCall(at: 3, result: SpacesDeviceWorkspaceDiffResult(scopeSignature: "sig-a2", files: []))
        await settle()

        let subscribeCount = await gateway.subscribeCallCount()
        #expect(
            subscribeCount == 2,
            "the stale attempt's late failure must not clear the current subscription's scope and force a needless resubscribe")
    }

    // MARK: - Diff-signature frame dedupe (round-4 Fix 3)

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
        content.handleReady() // simulate the web app's ready handshake so frames are eligible to forward

        content.dispatch(diffRequest(id: "req-1", scopeKind: "uncommitted"))
        await gateway.waitForDiffCallCount(1)
        await gateway.completeDiffCall(at: 0, result: SpacesDeviceWorkspaceDiffResult(scopeSignature: "sig-1", files: []))
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
        await gateway.completeDiffCall(at: 0, result: SpacesDeviceWorkspaceDiffResult(scopeSignature: "sig-1", files: []))
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
        await gateway.completeDiffCall(at: 0, result: SpacesDeviceWorkspaceDiffResult(scopeSignature: "sig-1", files: []))
        await gateway.waitForSubscribeCallCount(1)

        // A live update while still connected forwards and becomes the new "last acted on" signature.
        await gateway.triggerFrame(at: 0, scopeSignature: "sig-2")
        await waitUntil { !self.diffSignatureScripts(evaluator).isEmpty }
        #expect(diffSignatureScripts(evaluator).count == 1)

        // Disconnect; the backoff retry (round 3's Fix 2) reopens the same scope. Its connect-time
        // frame repeats "sig-2" (nothing changed during the brief outage) — must stay suppressed.
        await gateway.triggerDisconnect(at: 0)
        await gateway.waitForSubscribeCallCount(2)
        await gateway.triggerFrame(at: 1, scopeSignature: "sig-2")
        await settle()
        #expect(diffSignatureScripts(evaluator).count == 1, "a reconnect's connect-time frame repeating the last-forwarded signature must stay suppressed")

        // A real change discovered only after the outage must still forward.
        await gateway.triggerFrame(at: 1, scopeSignature: "sig-3")
        await waitUntil { self.diffSignatureScripts(evaluator).count == 2 }
        #expect(diffSignatureScripts(evaluator)[1].contains("sig-3"))
    }

    // MARK: - A diff completion after deactivate never resubscribes the stream (round-4 Fix 4)

    /// `teardownWebView` bumps `latestDiffRequestToken` (Fix 4): without this, a `workspaceDiff` call
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

        await gateway.completeDiffCall(at: 0, result: SpacesDeviceWorkspaceDiffResult(scopeSignature: "sig-1", files: []))
        await settle()

        let subscribeCount = await gateway.subscribeCallCount()
        #expect(subscribeCount == 0, "a diff completion arriving after deactivate() must not open a subscription for a pane no longer visible")
    }

    // MARK: - Reconnect-with-backoff after a disconnect (Fix 2, round 3)

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
        await gateway.completeDiffCall(at: 0, result: SpacesDeviceWorkspaceDiffResult(scopeSignature: "sig-1", files: []))
        await gateway.waitForSubscribeCallCount(1)

        await gateway.triggerDisconnect(at: 0)

        // No further workspaceDiff dispatch here: only the backoff retry itself can produce this.
        await gateway.waitForSubscribeCallCount(2)

        let refName = await gateway.subscribedRefName(at: 1)
        #expect(refName == nil, "the retry must resubscribe the SAME scope (uncommitted, refName nil) the dropped subscription had")
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
        await gateway.completeDiffCall(at: 0, result: SpacesDeviceWorkspaceDiffResult(scopeSignature: "sig-1", files: []))
        await gateway.waitForSubscribeCallCount(1)

        await gateway.triggerDisconnect(at: 0)
        await settle(.milliseconds(50)) // let the disconnect handler run and schedule the retry's sleep

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
        await gateway.completeDiffCall(at: 0, result: SpacesDeviceWorkspaceDiffResult(scopeSignature: "sig-1", files: []))
        await gateway.waitForSubscribeCallCount(1)

        await gateway.triggerDisconnect(at: 0)
        await settle(.milliseconds(50)) // let the disconnect handler run and schedule the retry's sleep

        // A scope change arrives well before the 150ms backoff floor elapses.
        content.dispatch(diffRequest(id: "req-2", scopeKind: "ref", refName: "feature-branch"))
        await gateway.waitForDiffCallCount(2)
        await gateway.completeDiffCall(at: 1, result: SpacesDeviceWorkspaceDiffResult(scopeSignature: "sig-2", files: []))
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

    /// Regression for round-7 Fix 2's conditional dispatch-time generation bump: a same-scope
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
        await gateway.completeDiffCall(at: 0, result: SpacesDeviceWorkspaceDiffResult(scopeSignature: "sig-1", files: []))
        await gateway.waitForSubscribeCallCount(1)

        // A same-scope refetch, as `refreshDiff` issues on every `spaces:diffSignature` frame for
        // the scope already subscribed — `resubscribeDiffSignature`'s own `subscribedScope !=
        // .scope(refName)` guard already no-ops the resubscribe; this asserts the DISPATCH-time
        // bump this test is about also stays skipped, so no second subscribe call happens here.
        content.dispatch(diffRequest(id: "req-2", scopeKind: "uncommitted"))
        await gateway.waitForDiffCallCount(2)
        await gateway.completeDiffCall(at: 1, result: SpacesDeviceWorkspaceDiffResult(scopeSignature: "sig-1", files: []))
        await settle(.milliseconds(50)) // let the (would-be) resubscribe run if it were wrongly triggered
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
        await gateway.completeDiffCall(at: 0, result: SpacesDeviceWorkspaceDiffResult(scopeSignature: "sig-1", files: []))
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

    /// Round-6 Fix 2: the device is nil by contract for exactly the window a daemon restart's
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
        await gateway.completeDiffCall(at: 0, result: SpacesDeviceWorkspaceDiffResult(scopeSignature: "sig-1", files: []))
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
        await gateway.completeDiffCall(at: 0, result: SpacesDeviceWorkspaceDiffResult(scopeSignature: "sig-1", files: []))
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

    // MARK: - performFileRead → resubscribeFileSignature wiring (Phase 5 Part A)
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

    @Test func aSuccessfulFileReadResubscribesTheFileSignatureStreamAtThatPath() async {
        let gateway = RecordingCodePaneDeviceGateway()
        let hosting = DeviceCodePaneHostingDouble(device: fakeDevice())
        let content = makeController(hosting: hosting, deviceGateway: gateway)
        content.activate(focus: false)
        content.scriptEvaluator = RecordingCodePaneScriptEvaluator()

        content.dispatch(fileReadRequest(id: "req-1", path: "foo.ts"))
        await gateway.waitForFileReadCallCount(1)
        await gateway.completeFileReadCall(at: 0, result: SpacesDeviceWorkspaceFileReadResult(base64Data: "", sha256: "sha-1", size: 0, isBinaryGuess: false))

        await gateway.waitForFileSubscribeCallCount(1)
        let path = await gateway.subscribedFilePath(at: 0)
        #expect(path == "foo.ts")
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
        await gateway.completeFileReadCall(at: 0, result: SpacesDeviceWorkspaceFileReadResult(base64Data: "", sha256: "sha-1", size: 0, isBinaryGuess: false))
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
        await gateway.completeFileReadCall(at: 0, result: SpacesDeviceWorkspaceFileReadResult(base64Data: "", sha256: "sha-1", size: 0, isBinaryGuess: false))
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
        await gateway.completeFileReadCall(at: 0, result: SpacesDeviceWorkspaceFileReadResult(base64Data: "", sha256: "sha-1", size: 0, isBinaryGuess: false))
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
        await gateway.completeFileReadCall(at: 0, result: SpacesDeviceWorkspaceFileReadResult(base64Data: "", sha256: "sha-1", size: 0, isBinaryGuess: false))
        await gateway.waitForFileSubscribeCallCount(1)

        // The file is deleted out from under the open editor: the daemon reports `missing: true` with no
        // `sha256` (see `SpacesDeviceWorkspaceFileSignatureFrame`'s doc comment).
        await gateway.triggerFileFrame(at: 0, path: "foo.ts", sha256: nil, missing: true)
        await waitUntil { !self.fileSignatureScripts(evaluator).isEmpty }

        #expect(fileSignatureScripts(evaluator).count == 1)
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
        await gateway.completeFileReadCall(at: 0, result: SpacesDeviceWorkspaceFileReadResult(base64Data: "", sha256: "sha-1", size: 0, isBinaryGuess: false))
        await settle()

        let subscribeCount = await gateway.fileSubscribeCallCount()
        #expect(subscribeCount == 0, "a workspaceFileRead completion after deactivate must never resubscribe the stream")
    }

    // MARK: - Restoring the previous file's monitoring after a failed open (Phase 5 review round-1 Fix 1)
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
        await gateway.completeFileReadCall(at: 0, result: SpacesDeviceWorkspaceFileReadResult(base64Data: "", sha256: "sha-1", size: 0, isBinaryGuess: false))
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
        await gateway.completeFileReadCall(at: 0, result: SpacesDeviceWorkspaceFileReadResult(base64Data: "", sha256: "sha-1", size: 0, isBinaryGuess: false))
        await gateway.waitForFileSubscribeCallCount(1)

        // Drop the first path's stream and let it enter its pending-retry backoff window, without waiting
        // for that retry to fire.
        await gateway.triggerFileDisconnect(at: 0)
        await settle(.milliseconds(50)) // let the disconnect handler run and schedule the retry's sleep

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
        await gateway.completeFileReadCall(at: 0, result: SpacesDeviceWorkspaceFileReadResult(base64Data: "", sha256: "sha-1", size: 0, isBinaryGuess: false))
        await gateway.waitForFileSubscribeCallCount(1)

        // Open a second path and leave its read pending (it will fail later, after the third path below
        // has already taken over).
        content.dispatch(fileReadRequest(id: "req-2", path: "bar.ts"))
        await gateway.waitForFileReadCallCount(2)

        // A third path is opened and succeeds while the second path's read is still pending.
        struct InjectedFileReadFailure: Error {}
        content.dispatch(fileReadRequest(id: "req-3", path: "baz.ts"))
        await gateway.waitForFileReadCallCount(3)
        await gateway.completeFileReadCall(at: 2, result: SpacesDeviceWorkspaceFileReadResult(base64Data: "", sha256: "sha-3", size: 0, isBinaryGuess: false))
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

    // MARK: - Editor-state / mode hibernation snapshot (round-5)

    // No "/" in the path: JSONEncoder escapes forward slashes as "\/" in the emitted JS, which would
    // make a plain substring match brittle for no benefit these tests need.
    private func fakeEditorState(path: String = "foo.ts", dirty: Bool = true, conflict: Bool = false) -> CodePaneBridge.EditorState {
        CodePaneBridge.EditorState(path: path, baseSHA256: "sha-abc", baseContent: "let x = 1;", content: "let x = 1;", dirty: dirty, conflict: conflict)
    }

    /// The live `WKWebView` `activate()` just installed — the "correct" `senderWebView` a push from
    /// the current page would actually carry.
    private func liveWebView(_ content: CodePaneContentController) -> WKWebView? {
        content.contentView.subviews.first { $0 is WKWebView } as? WKWebView
    }

    @Test func editorStateChangedPushIsStoredAndReturnedInTheNextInitPayload() {
        let content = makeController()
        content.activate(focus: false)
        let webView = liveWebView(content)
        let evaluator = RecordingCodePaneScriptEvaluator()
        content.scriptEvaluator = evaluator

        content.handleEditorStateChanged(fakeEditorState(), senderWebView: webView)
        content.handleReady()

        #expect(
            evaluator.evaluatedScripts.contains { $0.contains(#""path":"foo.ts""#) && $0.contains(#""dirty":true"#) },
            "the stored snapshot must be handed back through spaces:init's editorState field")
    }

    @Test func editorStateSurvivesDeactivateReactivateAndAppearsInTheNextInitPayload() {
        let content = makeController()
        content.activate(focus: false)
        content.handleEditorStateChanged(fakeEditorState(), senderWebView: liveWebView(content))

        // A recording double, answering synchronously, stands in for the real WKWebView here so the
        // teardown flush (round-6 Fix 1) settles within this synchronous test body — otherwise
        // `handleReady()` below would defer behind it forever (round-7 Fix 1) waiting on real WebKit's
        // async round trip, which nothing in this test pumps to completion.
        let teardownEvaluator = RecordingCodePaneScriptEvaluator()
        content.scriptEvaluator = teardownEvaluator
        teardownEvaluator.enqueueCollectResult(#"{"path":"foo.ts","baseSHA256":"sha-abc","baseContent":"let x = 1;","content":"let x = 1;","dirty":true}"#)
        // round-16 Fix 1a: teardownWebView() also flushes review-comment state now — this test isn't
        // about that surface, so answer its collect call with "nothing pending" to let both flushes
        // settle.
        teardownEvaluator.enqueueCollectResult("__none__")

        // Hibernate for real, like the round-2 stale-generation tests above.
        content.deactivate()
        content.activate(focus: false)
        let evaluator = RecordingCodePaneScriptEvaluator()
        content.scriptEvaluator = evaluator

        content.handleReady()

        #expect(
            evaluator.evaluatedScripts.contains { $0.contains(#""path":"foo.ts""#) },
            "the snapshot pushed before hibernation must still rehydrate through the next spaces:init")
    }

    @Test func aPushFromAStaleWebViewIsIgnored() {
        let content = makeController()
        content.activate(focus: false)
        let evaluator = RecordingCodePaneScriptEvaluator()
        content.scriptEvaluator = evaluator

        // Stands in for a torn-down page's own WKWebView instance still delivering a debounced push
        // after a reactivate has already installed a fresh one — see `handleEditorStateChanged`'s
        // doc comment for why identity, not `pageGeneration`, is the guard here.
        let staleWebView = WKWebView()
        content.handleEditorStateChanged(fakeEditorState(), senderWebView: staleWebView)
        content.handleReady()

        #expect(
            !evaluator.evaluatedScripts.contains { $0.contains(#""path":"foo.ts""#) },
            "a push whose senderWebView isn't the live page must not be stored")
    }

    @Test func closeClearsTheStoredEditorState() {
        let content = makeController()
        content.activate(focus: false)
        content.handleEditorStateChanged(fakeEditorState(), senderWebView: liveWebView(content))

        // See `editorStateSurvivesDeactivateReactivateAndAppearsInTheNextInitPayload` above for why a
        // synchronous double is needed here: without it, `handleReady()` below would defer behind the
        // teardown flush forever, which would make this test's negative assertion pass for the wrong
        // reason (no init sent at all, rather than an init correctly omitting the cleared state).
        let teardownEvaluator = RecordingCodePaneScriptEvaluator()
        content.scriptEvaluator = teardownEvaluator
        teardownEvaluator.enqueueCollectResult(#"{"path":"foo.ts","baseSHA256":"sha-abc","baseContent":"let x = 1;","content":"let x = 1;","dirty":true}"#)
        // round-16 Fix 1a: see the comment in `editorStateSurvivesDeactivateReactivateAndAppearsInTheNextInitPayload`.
        teardownEvaluator.enqueueCollectResult("__none__")

        content.close()
        content.activate(focus: false)
        let evaluator = RecordingCodePaneScriptEvaluator()
        content.scriptEvaluator = evaluator
        content.handleReady()

        #expect(
            !evaluator.evaluatedScripts.contains { $0.contains(#""path":"foo.ts""#) },
            "close() must discard the in-memory snapshot, not just hibernate it like deactivate()")
    }

    @Test func initPayloadOmitsEditorStateWhenThereIsNone() {
        let content = makeController()
        content.activate(focus: false)
        let evaluator = RecordingCodePaneScriptEvaluator()
        content.scriptEvaluator = evaluator

        content.handleReady()

        #expect(!evaluator.evaluatedScripts.contains { $0.contains("editorState") }, "a pane with no stored snapshot must not encode the editorState key at all")
    }

    @Test func modeChangedPushUpdatesCurrentModeAndSurvivesHibernation() {
        let content = makeController() // initialMode: .diff
        content.activate(focus: false)
        content.handleModeChanged(.editor, senderWebView: liveWebView(content))

        // See `editorStateSurvivesDeactivateReactivateAndAppearsInTheNextInitPayload` above for why a
        // synchronous double is needed here (no open file for this test, hence `nil`).
        let teardownEvaluator = RecordingCodePaneScriptEvaluator()
        content.scriptEvaluator = teardownEvaluator
        teardownEvaluator.enqueueCollectResult(nil)
        // round-16 Fix 1a: see the comment in `editorStateSurvivesDeactivateReactivateAndAppearsInTheNextInitPayload`.
        teardownEvaluator.enqueueCollectResult("__none__")

        content.deactivate()
        content.activate(focus: false)
        let evaluator = RecordingCodePaneScriptEvaluator()
        content.scriptEvaluator = evaluator
        content.handleReady()

        #expect(
            evaluator.evaluatedScripts.contains { $0.contains(#""initialMode":"editor""#) },
            "the live mode from before hibernation, not the original initialMode, must be what the next spaces:init reports")
    }

    @Test func aModeChangedPushFromAStaleWebViewIsIgnored() {
        let content = makeController() // initialMode: .diff
        content.activate(focus: false)
        let evaluator = RecordingCodePaneScriptEvaluator()
        content.scriptEvaluator = evaluator

        content.handleModeChanged(.editor, senderWebView: WKWebView())
        content.handleReady()

        #expect(
            evaluator.evaluatedScripts.contains { $0.contains(#""initialMode":"diff""#) },
            "a stale push must not move currentMode away from its actual last-known value")
    }

    @Test func closeResetsCurrentModeToInitialMode() {
        let content = makeController() // initialMode: .diff
        content.activate(focus: false)
        content.handleModeChanged(.editor, senderWebView: liveWebView(content))

        // See `editorStateSurvivesDeactivateReactivateAndAppearsInTheNextInitPayload` above for why a
        // synchronous double is needed here (no open file for this test, hence `nil`).
        let teardownEvaluator = RecordingCodePaneScriptEvaluator()
        content.scriptEvaluator = teardownEvaluator
        teardownEvaluator.enqueueCollectResult(nil)
        // round-16 Fix 1a: see the comment in `editorStateSurvivesDeactivateReactivateAndAppearsInTheNextInitPayload`.
        teardownEvaluator.enqueueCollectResult("__none__")

        content.close()
        content.activate(focus: false)
        let evaluator = RecordingCodePaneScriptEvaluator()
        content.scriptEvaluator = evaluator
        content.handleReady()

        #expect(
            evaluator.evaluatedScripts.contains { $0.contains(#""initialMode":"diff""#) },
            "close() must reset the live mode back to initialMode, not carry a toggled mode forward")
    }

    // MARK: - Sender-identity guard at the message-handler boundary (round-8 Fix 3)

    /// The wire body for an RPC request — the same shape `diffRequest(id:scopeKind:refName:)` builds
    /// as a `CodePaneBridge.Request`, but as the raw `[String: Any]` dictionary `handleScriptMessage`
    /// takes directly (mirroring `WKScriptMessage.body`), since that method — not `dispatch(_:)` — is
    /// what's under test here.
    private func diffRequestBody(id: String) -> [String: Any] {
        ["id": id, "method": "workspaceDiff", "params": ["scope": ["kind": "uncommitted"]]]
    }

    @Test func handleScriptMessageDropsAReadyFromAStaleWebView() {
        let content = makeController()
        content.activate(focus: false)
        let evaluator = RecordingCodePaneScriptEvaluator()
        content.scriptEvaluator = evaluator

        // Stands in for a torn-down page's own WKWebView instance still delivering its `ready`
        // message after a reactivate has already installed a fresh one — see
        // `handleScriptMessage`'s doc comment for why identity is the guard here.
        content.handleScriptMessage(name: "spacesBridge", body: ["method": "ready"], senderWebView: WKWebView())

        #expect(evaluator.evaluatedScripts.isEmpty, "a stale ready must never trigger spaces:init")
    }

    @Test func handleScriptMessageDropsAnEditorStateChangedPushFromAStaleWebView() {
        let content = makeController()
        content.activate(focus: false)
        let evaluator = RecordingCodePaneScriptEvaluator()
        content.scriptEvaluator = evaluator

        let body: [String: Any] = [
            "method": "editorStateChanged",
            "params": ["path": "foo.ts", "baseSHA256": "sha-abc", "baseContent": "let x = 1;", "content": "let x = 1;", "dirty": true],
        ]
        content.handleScriptMessage(name: "spacesBridge", body: body, senderWebView: WKWebView())
        content.handleReady()

        #expect(
            !evaluator.evaluatedScripts.contains { $0.contains(#""path":"foo.ts""#) },
            "a stale editor-state push must never be stored, matching handleEditorStateChanged's own guard")
    }

    @Test func handleScriptMessageDropsAnRPCRequestFromAStaleWebView() async {
        let gateway = RecordingCodePaneDeviceGateway()
        let hosting = DeviceCodePaneHostingDouble(device: fakeDevice())
        let content = makeController(hosting: hosting, deviceGateway: gateway)
        content.activate(focus: false)
        let evaluator = RecordingCodePaneScriptEvaluator()
        content.scriptEvaluator = evaluator

        content.handleScriptMessage(name: "spacesBridge", body: diffRequestBody(id: "req-1"), senderWebView: WKWebView())
        await settle()

        let callCount = await gateway.diffCallCount()
        #expect(callCount == 0, "a stale RPC must never reach the device gateway")
        #expect(evaluator.evaluatedScripts.isEmpty, "a stale RPC must never receive a reply either")
    }

    @Test func handleScriptMessageProcessesAllThreeKindsFromTheLiveWebView() async {
        let gateway = RecordingCodePaneDeviceGateway()
        let hosting = DeviceCodePaneHostingDouble(device: fakeDevice())
        let content = makeController(hosting: hosting, deviceGateway: gateway)
        content.activate(focus: false)
        let webView = liveWebView(content)
        let evaluator = RecordingCodePaneScriptEvaluator()
        content.scriptEvaluator = evaluator

        // An RPC request, from the live page: still reaches the device gateway.
        content.handleScriptMessage(name: "spacesBridge", body: diffRequestBody(id: "req-1"), senderWebView: webView)
        await gateway.waitForDiffCallCount(1)

        // An editor-state push, from the live page: gets stored, to be echoed back by the ready
        // below's spaces:init (same round trip `editorStateChangedPushIsStoredAndReturnedInTheNextInitPayload`
        // exercises, just routed through `handleScriptMessage` instead of `handleEditorStateChanged` directly).
        let editorBody: [String: Any] = [
            "method": "editorStateChanged",
            "params": ["path": "foo.ts", "baseSHA256": "sha-abc", "baseContent": "let x = 1;", "content": "let x = 1;", "dirty": true],
        ]
        content.handleScriptMessage(name: "spacesBridge", body: editorBody, senderWebView: webView)

        // ready, from the live page: triggers spaces:init, which must reflect the push above.
        content.handleScriptMessage(name: "spacesBridge", body: ["method": "ready"], senderWebView: webView)
        #expect(
            evaluator.evaluatedScripts.contains { $0.contains(#""path":"foo.ts""#) },
            "every kind of message from the live webView must still process normally")
    }

    // MARK: - Teardown editor-state flush (round-6 Fix 1)

    /// The teardown flush must reach the web app even when no debounced `editorStateChanged` push
    /// ever fired for this generation — this is exactly the race Fix 1 closes: a buffer edit still
    /// inside `scheduleEditorStatePush`'s trailing debounce window when the pane hibernates.
    @Test func teardownFlushDeliversTheWebAppsLiveSnapshotToTheNextInitPayload() {
        let content = makeController()
        content.activate(focus: false)
        let evaluator = RecordingCodePaneScriptEvaluator()
        content.scriptEvaluator = evaluator

        content.deactivate() // issues the flush's collect script against `evaluator`, left pending

        evaluator.completeOldestPending(with: #"{"path":"foo.ts","baseSHA256":"sha-abc","baseContent":"let x = 1;","content":"let x = 1;","dirty":true}"#)
        // round-16 Fix 1a: see the comment in `editorStateSurvivesDeactivateReactivateAndAppearsInTheNextInitPayload`.
        evaluator.completeOldestPending(with: "__none__")

        content.activate(focus: false)
        let nextEvaluator = RecordingCodePaneScriptEvaluator()
        content.scriptEvaluator = nextEvaluator
        content.handleReady()

        #expect(
            nextEvaluator.evaluatedScripts.contains { $0.contains(#""path":"foo.ts""#) && $0.contains(#""dirty":true"#) },
            "a flush captured at teardown must rehydrate through the next spaces:init, even with no editorStateChanged push for it")
    }

    /// A flush's answer can land after a fresh page has already installed and pushed its own state
    /// (a slow `evaluateJavaScript` round trip racing a fast reactivate); the stale, older-generation
    /// flush must lose to whatever the newer page already wrote.
    @Test func aDelayedFlushFromAnOldGenerationDoesNotClobberANewerPagesPush() {
        let content = makeController()
        content.activate(focus: false)
        let firstEvaluator = RecordingCodePaneScriptEvaluator()
        content.scriptEvaluator = firstEvaluator

        content.deactivate() // captures generation 1's flush, left pending (not yet answered)

        // A fresh page installs (generation 2) and pushes its own, different snapshot before the old
        // generation's flush ever answers.
        content.activate(focus: false)
        content.handleEditorStateChanged(fakeEditorState(path: "bar.ts"), senderWebView: liveWebView(content))

        // The stale flush from generation 1 answers late, with different content than the live push.
        firstEvaluator.completeOldestPending(with: #"{"path":"foo.ts","baseSHA256":"sha-abc","baseContent":"let x = 1;","content":"let x = 1;","dirty":true}"#)
        // round-16 Fix 1a: see the comment in `editorStateSurvivesDeactivateReactivateAndAppearsInTheNextInitPayload`.
        firstEvaluator.completeOldestPending(with: "__none__")

        let evaluator = RecordingCodePaneScriptEvaluator()
        content.scriptEvaluator = evaluator
        content.handleReady()

        #expect(
            evaluator.evaluatedScripts.contains { $0.contains(#""path":"bar.ts""#) },
            "the newer generation's own push must win over a stale flush answering late")
        #expect(
            !evaluator.evaluatedScripts.contains { $0.contains(#""path":"foo.ts""#) },
            "a flush from an already-superseded generation must not overwrite what a newer page already wrote")
    }

    /// An installed collector's own explicit "nothing open" answer (the `'__no_file__'` sentinel) is
    /// authoritative for its own generation, exactly like any other reported flush answer — it must
    /// clear a stale prior snapshot rather than leaving it in place, since the collect script reads the
    /// editor's live state directly.
    @Test func aNoFileSentinelFlushResultClearsAnExistingSnapshotForItsOwnGeneration() {
        let content = makeController()
        content.activate(focus: false)
        content.handleEditorStateChanged(fakeEditorState(), senderWebView: liveWebView(content))

        let evaluator = RecordingCodePaneScriptEvaluator()
        content.scriptEvaluator = evaluator

        content.deactivate() // flush reads the same generation's page, now reporting no open file

        evaluator.completeOldestPending(with: "__no_file__")
        // round-16 Fix 1a: see the comment in `editorStateSurvivesDeactivateReactivateAndAppearsInTheNextInitPayload`.
        evaluator.completeOldestPending(with: "__none__")

        content.activate(focus: false)
        let nextEvaluator = RecordingCodePaneScriptEvaluator()
        content.scriptEvaluator = nextEvaluator
        content.handleReady()

        #expect(
            !nextEvaluator.evaluatedScripts.contains { $0.contains("editorState") },
            "a '__no_file__' flush from the same generation as the last push is authoritative and must clear the stored snapshot")
    }

    /// A `.notReported` flush result — the page hadn't finished bootstrapping when it was torn down
    /// (the `'__uninstalled__'` sentinel), or the evaluate call itself failed (folds to `nil` — see
    /// `CodePaneScriptEvaluator`'s doc comment) — carries no information and must NOT clear a snapshot
    /// from a prior hibernation cycle (round-6 Fix 1: this is the exact race where a reactivate then a
    /// fast re-hibernate tears the page down again before its JS finishes bootstrapping). It must still
    /// count as "settled" for `outstandingTeardownFlushCount`/`deferredReadyGeneration` purposes, so a
    /// `handleReady()` deferred behind it still goes out once it lands, carrying the untouched snapshot.
    @Test func aNotReportedFlushResultLeavesAnExistingSnapshotUntouchedAndStillResumesADeferredReady() {
        let content = makeController()
        content.activate(focus: false)
        content.handleEditorStateChanged(fakeEditorState(), senderWebView: liveWebView(content))

        let staleEvaluator = RecordingCodePaneScriptEvaluator()
        content.scriptEvaluator = staleEvaluator

        content.deactivate() // flush captures the same generation as the push above, left pending

        content.activate(focus: false)
        let evaluator = RecordingCodePaneScriptEvaluator()
        content.scriptEvaluator = evaluator

        content.handleReady() // defers: the teardown flush above is still outstanding

        #expect(
            !evaluator.evaluatedScripts.contains { $0.contains("spaces:init") },
            "handleReady must defer while the flush from the torn-down page is still outstanding")

        // Either sentinel-shaped answer (or a nil evaluate failure) decodes to `.notReported` and must
        // leave the seeded snapshot alone; `__uninstalled__` is what the real collect script emits for
        // a page that hasn't bootstrapped far enough to define the collector global yet.
        staleEvaluator.completeOldestPending(with: "__uninstalled__")
        // round-16 Fix 1a: see the comment in `editorStateSurvivesDeactivateReactivateAndAppearsInTheNextInitPayload`.
        staleEvaluator.completeOldestPending(with: "__none__")

        #expect(
            evaluator.evaluatedScripts.contains { $0.contains("spaces:init") && $0.contains(#""path":"foo.ts""#) },
            "a .notReported flush must not clear the prior snapshot, and must still let the deferred handleReady proceed")
    }

    /// Same as above, but exercising the `nil` evaluate-failure path instead of the `'__uninstalled__'`
    /// sentinel — both decode to `.notReported` and must behave identically.
    @Test func aNilFlushResultLeavesAnExistingSnapshotUntouchedAndStillResumesADeferredReady() {
        let content = makeController()
        content.activate(focus: false)
        content.handleEditorStateChanged(fakeEditorState(), senderWebView: liveWebView(content))

        let staleEvaluator = RecordingCodePaneScriptEvaluator()
        content.scriptEvaluator = staleEvaluator

        content.deactivate() // flush captures the same generation as the push above, left pending

        content.activate(focus: false)
        let evaluator = RecordingCodePaneScriptEvaluator()
        content.scriptEvaluator = evaluator

        content.handleReady() // defers: the teardown flush above is still outstanding

        staleEvaluator.completeOldestPending(with: nil)
        // round-16 Fix 1a: see the comment in `editorStateSurvivesDeactivateReactivateAndAppearsInTheNextInitPayload`.
        staleEvaluator.completeOldestPending(with: "__none__")

        #expect(
            evaluator.evaluatedScripts.contains { $0.contains("spaces:init") && $0.contains(#""path":"foo.ts""#) },
            "a nil (evaluate-failure) flush result must not clear the prior snapshot, and must still let the deferred handleReady proceed")
    }

    /// `close()` discards the snapshot for good (see its doc comment); a flush it kicked off via
    /// `teardownWebView()` a moment earlier must not be able to resurrect what it just discarded if
    /// that flush's completion happens to land afterward.
    @Test func closeInvalidatesAFlushAlreadyInFlightSoItCannotResurrectTheDiscardedSnapshot() {
        let content = makeController()
        content.activate(focus: false)
        content.handleEditorStateChanged(fakeEditorState(), senderWebView: liveWebView(content))

        let evaluator = RecordingCodePaneScriptEvaluator()
        content.scriptEvaluator = evaluator

        content.close() // teardownWebView()'s flush captures its generation and is left pending, then close() discards editorState

        // The flush from before close() answers late, with the very state close() just discarded.
        evaluator.completeOldestPending(with: #"{"path":"foo.ts","baseSHA256":"sha-abc","baseContent":"let x = 1;","content":"let x = 1;","dirty":true}"#)
        // round-16 Fix 1a: see the comment in `editorStateSurvivesDeactivateReactivateAndAppearsInTheNextInitPayload`.
        evaluator.completeOldestPending(with: "__none__")

        content.activate(focus: false)
        let nextEvaluator = RecordingCodePaneScriptEvaluator()
        content.scriptEvaluator = nextEvaluator
        content.handleReady()

        #expect(
            !nextEvaluator.evaluatedScripts.contains { $0.contains(#""path":"foo.ts""#) },
            "close() must permanently discard the snapshot even if a flush it kicked off answers afterward")
    }

    // MARK: - handleReady defers behind an outstanding teardown flush (round-7 Fix 1)

    /// The race Fix 1 closes: a teardown flush (round-6 Fix 1) is still in flight when the replacement
    /// page's `ready` arrives. `handleReady()` must hold `spaces:init` back until the flush settles,
    /// rather than sending it with whatever stale `editorState` happened to be on hand — and once the
    /// flush does settle, the held `spaces:init` must reflect what it delivered.
    @Test func handleReadyDefersInitUntilAnOutstandingTeardownFlushSettlesThenSendsTheFlushedContent() {
        let content = makeController()
        content.activate(focus: false)
        let staleEvaluator = RecordingCodePaneScriptEvaluator()
        content.scriptEvaluator = staleEvaluator

        content.deactivate() // issues the flush's collect script against `staleEvaluator`, left pending

        content.activate(focus: false)
        let evaluator = RecordingCodePaneScriptEvaluator()
        content.scriptEvaluator = evaluator

        content.handleReady()

        #expect(
            !evaluator.evaluatedScripts.contains { $0.contains("spaces:init") },
            "handleReady must not send spaces:init while a flush from the torn-down page is still outstanding")

        staleEvaluator.completeOldestPending(with: #"{"path":"foo.ts","baseSHA256":"sha-abc","baseContent":"let x = 1;","content":"let x = 1;","dirty":true}"#)
        // round-16 Fix 1a: see the comment in `editorStateSurvivesDeactivateReactivateAndAppearsInTheNextInitPayload`.
        staleEvaluator.completeOldestPending(with: "__none__")

        #expect(
            evaluator.evaluatedScripts.contains { $0.contains("spaces:init") && $0.contains(#""path":"foo.ts""#) },
            "once the outstanding flush settles, the deferred handleReady must send spaces:init carrying the flushed (newer) content")
    }

    /// The page that deferred `handleReady()` can itself be torn down again before the flush it was
    /// waiting on ever answers (e.g. a fast second hibernation cycle). Once that flush finally settles,
    /// the deferred continuation must recognize its page is stale and send nothing for it — the current
    /// page gets its own `ready` → `handleReady()` call in due course instead.
    @Test func aDeferredReadyForAPageTornDownAgainBeforeItsFlushSettlesSendsNoStaleInit() {
        let content = makeController()

        content.activate(focus: false) // generation 1
        let evaluator1 = RecordingCodePaneScriptEvaluator()
        content.scriptEvaluator = evaluator1
        content.deactivate() // generation 1's flush starts against evaluator1, left pending

        content.activate(focus: false) // generation 2
        let evaluator2 = RecordingCodePaneScriptEvaluator()
        content.scriptEvaluator = evaluator2

        content.handleReady() // defers: generation 1's flush is still outstanding
        #expect(!evaluator2.evaluatedScripts.contains { $0.contains("spaces:init") }, "generation 2's ready must defer, not send")

        content.deactivate() // generation 2 tears down while still waiting; its OWN flush starts against evaluator2, left pending

        content.activate(focus: false) // generation 3
        let evaluator3 = RecordingCodePaneScriptEvaluator()
        content.scriptEvaluator = evaluator3

        // Generation 1's flush finally answers: one of two outstanding flushes settles, but generation
        // 2's flush is still outstanding, so nothing may fire yet.
        evaluator1.completeOldestPending(with: #"{"path":"foo.ts","baseSHA256":"sha-abc","baseContent":"let x = 1;","content":"let x = 1;","dirty":true}"#)
        // round-16 Fix 1a: each deactivate() now also starts a comment-state flush against the same
        // evaluator; resolve generation 1's before checking anything, so this assertion is really about
        // generation 2's flushes (not a leftover generation-1 comment flush) still being outstanding.
        evaluator1.completeOldestPending(with: "__none__")
        #expect(!evaluator3.evaluatedScripts.contains { $0.contains("spaces:init") }, "generation 2's own flush is still outstanding")

        // Generation 2's flush now answers too: the last outstanding flush settles, but the page the
        // deferred ready was waiting for (generation 2) is no longer current (generation 3 is) — this
        // must resolve to nothing, not a stale init for a page that's gone.
        evaluator2.completeOldestPending(with: #"{"path":"bar.ts","baseSHA256":"sha-abc","baseContent":"let y = 2;","content":"let y = 2;","dirty":true}"#)
        // round-16 Fix 1a: resolve generation 2's comment flush too — only once BOTH of generation 2's
        // flushes are settled does `outstandingTeardownFlushCount` reach zero and the deferred ready
        // actually re-check `generation == pageGeneration` (which fails, since generation 3 is current).
        evaluator2.completeOldestPending(with: "__none__")

        for evaluator in [evaluator1, evaluator2, evaluator3] {
            #expect(
                !evaluator.evaluatedScripts.contains { $0.contains("spaces:init") },
                "no spaces:init may go out for the now-stale generation 2 once its flush finally settles")
        }
    }

    // MARK: - Comment-draft teardown flush and rehydrate (round-16 Fix 1a/1b)

    @Test func teardownFlushStoresACommentSnapshotThatSurvivesRehydrate() {
        let content = makeController()
        content.activate(focus: false)
        let evaluator = RecordingCodePaneScriptEvaluator()
        content.scriptEvaluator = evaluator

        content.deactivate() // issues both flushes' collect scripts against `evaluator`, left pending

        evaluator.completeOldestPending(with: "__none__") // editor-state flush: nothing pending
        evaluator.completeOldestPending(
            with: #"[{"id":"c1","provisional":false,"filePath":"a.ts","side":"new","lineNumber":3,"lineText":"x","body":"hi"}]"#)

        content.activate(focus: false)
        let nextEvaluator = RecordingCodePaneScriptEvaluator()
        content.scriptEvaluator = nextEvaluator
        content.handleReady()

        #expect(
            nextEvaluator.evaluatedScripts.contains { $0.contains("pendingReviewComments") && $0.contains(#""id":"c1""#) },
            "a comment snapshot captured at teardown must rehydrate through the next spaces:init")
    }

    @Test func aNotReportedCommentFlushResultLeavesAnExistingSnapshotUntouched() {
        let content = makeController()
        content.activate(focus: false)
        let firstEvaluator = RecordingCodePaneScriptEvaluator()
        content.scriptEvaluator = firstEvaluator

        content.deactivate() // first teardown: seed a snapshot
        firstEvaluator.completeOldestPending(with: "__none__") // editor-state flush
        firstEvaluator.completeOldestPending(
            with: #"[{"id":"c1","provisional":false,"filePath":"a.ts","side":"new","lineNumber":3,"lineText":"x","body":"hi"}]"#)

        content.activate(focus: false)
        let secondEvaluator = RecordingCodePaneScriptEvaluator()
        content.scriptEvaluator = secondEvaluator

        content.deactivate() // second teardown: the page's comment surface never installed the collector
        secondEvaluator.completeOldestPending(with: "__none__") // editor-state flush
        secondEvaluator.completeOldestPending(with: "__uninstalled__") // comment-state flush: not reported

        content.activate(focus: false)
        let nextEvaluator = RecordingCodePaneScriptEvaluator()
        content.scriptEvaluator = nextEvaluator
        content.handleReady()

        #expect(
            nextEvaluator.evaluatedScripts.contains { $0.contains("pendingReviewComments") && $0.contains(#""id":"c1""#) },
            "a .notReported comment flush must not clear the prior snapshot")
    }

    @Test func aNoneSentinelCommentFlushClearsAnExistingSnapshot() {
        let content = makeController()
        content.activate(focus: false)
        let firstEvaluator = RecordingCodePaneScriptEvaluator()
        content.scriptEvaluator = firstEvaluator

        content.deactivate() // first teardown: seed a snapshot
        firstEvaluator.completeOldestPending(with: "__none__") // editor-state flush
        firstEvaluator.completeOldestPending(
            with: #"[{"id":"c1","provisional":false,"filePath":"a.ts","side":"new","lineNumber":3,"lineText":"x","body":"hi"}]"#)

        content.activate(focus: false)
        let secondEvaluator = RecordingCodePaneScriptEvaluator()
        content.scriptEvaluator = secondEvaluator

        content.deactivate() // second teardown: the draft was withdrawn, nothing pending anymore
        secondEvaluator.completeOldestPending(with: "__none__") // editor-state flush
        secondEvaluator.completeOldestPending(with: "__none__") // comment-state flush: nothing pending

        content.activate(focus: false)
        let nextEvaluator = RecordingCodePaneScriptEvaluator()
        content.scriptEvaluator = nextEvaluator
        content.handleReady()

        #expect(
            !nextEvaluator.evaluatedScripts.contains { $0.contains("pendingReviewComments") },
            "a '__none__' comment flush from a newer generation must clear the prior snapshot")
    }

    /// Mirrors `closeClearsTheStoredEditorState` above, for `pendingReviewCommentState` (round-16 Fix
    /// 1a's correction to `close()`, which originally cleared `editorState` but not its comment-state
    /// sibling): `close()` must discard the comment snapshot, not just hibernate it like `deactivate()`.
    @Test func closeClearsTheStoredReviewCommentState() {
        let content = makeController()
        content.activate(focus: false)
        let seedEvaluator = RecordingCodePaneScriptEvaluator()
        content.scriptEvaluator = seedEvaluator

        // No direct push exists for comment state (unlike `handleEditorStateChanged`), so seeding a
        // snapshot before `close()` goes through the normal teardown-flush path via `deactivate()`.
        content.deactivate()
        seedEvaluator.completeOldestPending(with: "__none__") // editor-state flush: nothing pending
        seedEvaluator.completeOldestPending(
            with: #"[{"id":"c1","provisional":false,"filePath":"a.ts","side":"new","lineNumber":3,"lineText":"x","body":"hi"}]"#)

        content.activate(focus: false)

        // See `closeClearsTheStoredEditorState` above for why a synchronous double is needed here:
        // without it, `handleReady()` below would defer behind the teardown flush forever, which would
        // make this test's negative assertion pass for the wrong reason (no init sent at all, rather
        // than an init correctly omitting the cleared state).
        let teardownEvaluator = RecordingCodePaneScriptEvaluator()
        content.scriptEvaluator = teardownEvaluator
        teardownEvaluator.enqueueCollectResult("__none__") // editor-state flush: nothing pending
        teardownEvaluator.enqueueCollectResult(
            #"[{"id":"c1","provisional":false,"filePath":"a.ts","side":"new","lineNumber":3,"lineText":"x","body":"hi"}]"#)

        content.close()
        content.activate(focus: false)
        let evaluator = RecordingCodePaneScriptEvaluator()
        content.scriptEvaluator = evaluator
        content.handleReady()

        #expect(
            !evaluator.evaluatedScripts.contains { $0.contains("pendingReviewComments") },
            "close() must discard the in-memory comment snapshot, not just hibernate it like deactivate()")
    }

    @Test func initPayloadOmitsPendingReviewCommentsKeyWhenNoSnapshotExists() {
        let content = makeController()
        content.activate(focus: false)
        let evaluator = RecordingCodePaneScriptEvaluator()
        content.scriptEvaluator = evaluator

        content.handleReady()

        #expect(
            evaluator.evaluatedScripts.contains { $0.contains("spaces:init") },
            "handleReady must send spaces:init immediately when no flush is outstanding")
        #expect(
            !evaluator.evaluatedScripts.contains { $0.contains("pendingReviewComments") },
            "with no teardown flush having ever captured anything, the init payload must omit the key entirely rather than send an empty array")
    }

    @Test func deferredReadyWaitsForBothTheEditorAndCommentTeardownFlushesBeforeFiring() {
        let content = makeController()
        content.activate(focus: false)
        let staleEvaluator = RecordingCodePaneScriptEvaluator()
        content.scriptEvaluator = staleEvaluator

        content.deactivate() // issues both flushes' collect scripts against `staleEvaluator`, left pending

        content.activate(focus: false)
        let evaluator = RecordingCodePaneScriptEvaluator()
        content.scriptEvaluator = evaluator

        content.handleReady() // defers: both teardown flushes above are still outstanding

        staleEvaluator.completeOldestPending(with: "__none__") // only the editor-state flush settles

        #expect(
            !evaluator.evaluatedScripts.contains { $0.contains("spaces:init") },
            "handleReady must stay deferred while the comment-state flush is still outstanding, even once the editor-state flush has settled")

        staleEvaluator.completeOldestPending(with: "__none__") // the comment-state flush now settles too

        #expect(
            evaluator.evaluatedScripts.contains { $0.contains("spaces:init") },
            "once both outstanding flushes settle, the deferred handleReady must proceed")
    }

    /// Round-16 Fix 1b's counter guards `ready` against an in-flight review-comment mutation RPC, not
    /// just a teardown flush — this exercises that seam end to end: the RPC is still in flight when the
    /// page tears down (its own teardown flushes settle immediately), and the deferred `ready` must
    /// still wait on the RPC specifically before it may proceed.
    @Test func aReadyDeferredBehindAnInFlightUpsertRPCResumesEvenAfterThePageWasTornDown() async {
        let gateway = RecordingCodePaneDeviceGateway()
        let hosting = DeviceCodePaneHostingDouble(device: fakeDevice())
        let content = makeController(hosting: hosting, deviceGateway: gateway)
        content.activate(focus: false)
        let evaluator = RecordingCodePaneScriptEvaluator()
        content.scriptEvaluator = evaluator

        await gateway.holdNextUpsertAttempts(1)
        content.dispatch(
            CodePaneBridge.Request(
                id: "req-1", method: "reviewCommentUpsert",
                params: ["filePath": "a.ts", "side": "new", "lineNumber": 1, "lineText": "x", "body": "hi"]))

        while await gateway.reviewCommentUpsertCalls.count < 1 {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(5))
        }

        content.deactivate() // teardown flushes settle immediately; the upsert RPC above stays outstanding
        evaluator.completeOldestPending(with: "__none__") // editor-state flush
        evaluator.completeOldestPending(with: "__none__") // comment-state flush

        content.activate(focus: false)
        let nextEvaluator = RecordingCodePaneScriptEvaluator()
        content.scriptEvaluator = nextEvaluator
        content.handleReady()

        #expect(
            !nextEvaluator.evaluatedScripts.contains { $0.contains("spaces:init") },
            "handleReady must stay deferred while the upsert RPC dispatched before teardown has not resolved")

        await gateway.completeHeldUpsertCall(
            at: 0,
            result: SpacesDeviceReviewComment(
                id: "c1", filePath: "a.ts", side: .new, lineNumber: 1, lineText: "x", body: "hi", createdAt: "2026-01-01T00:00:00Z",
                revision: 0))

        await waitUntil { nextEvaluator.evaluatedScripts.contains { $0.contains("spaces:init") } }
    }

    // MARK: - CREATE-success reconcile of a stale pendingReviewCommentState entry (round-11)
    //
    // These cover `reconcilePendingReviewCommentStateAfterCreate(comment:)`: a CREATE upsert
    // (`commentID == nil`) whose RPC is still in flight when hibernation snapshots the still-provisional
    // draft into `pendingReviewCommentState` must correct that snapshot once the CREATE resolves, rather
    // than let the replacement page's `spaces:init` replay a stale duplicate of the row the replacement
    // page's own `loadInitial()` already lists.

    /// Body-equal case: the snapshot's provisional entry has the same body the CREATE's response
    /// reports, so the reconcile must remove it outright — the listed server row already carries this
    /// exact text, so nothing needs replaying for it.
    @Test func aCreateThatMatchesAStaleProvisionalSnapshotEntryByBodyRemovesIt() async {
        let gateway = RecordingCodePaneDeviceGateway()
        let hosting = DeviceCodePaneHostingDouble(device: fakeDevice())
        let content = makeController(hosting: hosting, deviceGateway: gateway)
        content.activate(focus: false)
        let evaluator = RecordingCodePaneScriptEvaluator()
        content.scriptEvaluator = evaluator

        await gateway.holdNextUpsertAttempts(1)
        content.dispatch(
            CodePaneBridge.Request(
                id: "req-1", method: "reviewCommentUpsert",
                params: ["filePath": "a.ts", "side": "new", "lineNumber": 1, "lineText": "x", "body": "hi"]))

        while await gateway.reviewCommentUpsertCalls.count < 1 {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(5))
        }

        content.deactivate() // teardown flushes settle immediately; the upsert RPC above stays outstanding
        evaluator.completeOldestPending(with: "__none__") // editor-state flush
        evaluator.completeOldestPending(
            with: #"[{"id":"provisional-1","provisional":true,"filePath":"a.ts","side":"new","lineNumber":1,"lineText":"x","body":"hi"}]"#)

        content.activate(focus: false)
        let nextEvaluator = RecordingCodePaneScriptEvaluator()
        content.scriptEvaluator = nextEvaluator
        content.handleReady() // deferred: the upsert RPC dispatched before teardown has not resolved

        await gateway.completeHeldUpsertCall(
            at: 0,
            result: SpacesDeviceReviewComment(
                id: "c1", filePath: "a.ts", side: .new, lineNumber: 1, lineText: "x", body: "hi", createdAt: "2026-01-01T00:00:00Z",
                revision: 0))

        await waitUntil { nextEvaluator.evaluatedScripts.contains { $0.contains("spaces:init") } }

        #expect(
            !nextEvaluator.evaluatedScripts.contains { $0.contains(#""id":"provisional-1""#) },
            "a body-equal CREATE completion must remove the stale provisional snapshot entry rather than replay it alongside the new server row")
    }

    /// Body-differs case: the user kept typing after the CREATE's RPC was already in flight, so the
    /// snapshot entry's body has since diverged from what the CREATE just committed. The reconcile must
    /// keep the entry (so the newer local text still overlays the listed row) but convert it to
    /// non-provisional under the server-assigned id, leaving its own body and anchor fields untouched.
    @Test func aCreateThatMatchesAStaleProvisionalSnapshotEntryOnlyByAnchorRewritesItNonProvisional() async {
        let gateway = RecordingCodePaneDeviceGateway()
        let hosting = DeviceCodePaneHostingDouble(device: fakeDevice())
        let content = makeController(hosting: hosting, deviceGateway: gateway)
        content.activate(focus: false)
        let evaluator = RecordingCodePaneScriptEvaluator()
        content.scriptEvaluator = evaluator

        await gateway.holdNextUpsertAttempts(1)
        content.dispatch(
            CodePaneBridge.Request(
                id: "req-1", method: "reviewCommentUpsert",
                params: ["filePath": "a.ts", "side": "new", "lineNumber": 1, "lineText": "x", "body": "hi"]))

        while await gateway.reviewCommentUpsertCalls.count < 1 {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(5))
        }

        content.deactivate()
        evaluator.completeOldestPending(with: "__none__") // editor-state flush
        evaluator.completeOldestPending(
            with:
                #"[{"id":"provisional-1","provisional":true,"filePath":"a.ts","side":"new","lineNumber":1,"lineText":"x","body":"hi, typed more"}]"#
        )

        content.activate(focus: false)
        let nextEvaluator = RecordingCodePaneScriptEvaluator()
        content.scriptEvaluator = nextEvaluator
        content.handleReady()

        await gateway.completeHeldUpsertCall(
            at: 0,
            result: SpacesDeviceReviewComment(
                id: "c1", filePath: "a.ts", side: .new, lineNumber: 1, lineText: "x", body: "hi", createdAt: "2026-01-01T00:00:00Z",
                revision: 0))

        await waitUntil { nextEvaluator.evaluatedScripts.contains { $0.contains("spaces:init") } }

        let initScript = nextEvaluator.evaluatedScripts.first { $0.contains("pendingReviewComments") }
        #expect(initScript != nil, "the diverged entry must still be present in the init payload, just converted")
        #expect(initScript?.contains(#""id":"c1""#) ?? false, "the converted entry must carry the server-assigned id")
        #expect(initScript?.contains(#""provisional":false"#) ?? false, "the converted entry must no longer read as provisional")
        #expect(
            initScript?.contains(#""body":"hi, typed more""#) ?? false,
            "the converted entry must keep its own (newer) body, not the server's just-committed body")
    }

    /// Upsert FAILURE across hibernation: nothing committed server-side, so the stored snapshot must be
    /// left completely alone — the failure path runs no reconcile logic at all.
    @Test func aFailedCreateAcrossHibernationLeavesTheStaleSnapshotUntouched() async {
        let gateway = RecordingCodePaneDeviceGateway()
        let hosting = DeviceCodePaneHostingDouble(device: fakeDevice())
        let content = makeController(hosting: hosting, deviceGateway: gateway)
        content.activate(focus: false)
        let evaluator = RecordingCodePaneScriptEvaluator()
        content.scriptEvaluator = evaluator

        await gateway.holdNextUpsertAttempts(1)
        content.dispatch(
            CodePaneBridge.Request(
                id: "req-1", method: "reviewCommentUpsert",
                params: ["filePath": "a.ts", "side": "new", "lineNumber": 1, "lineText": "x", "body": "hi"]))

        while await gateway.reviewCommentUpsertCalls.count < 1 {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(5))
        }

        content.deactivate()
        evaluator.completeOldestPending(with: "__none__") // editor-state flush
        evaluator.completeOldestPending(
            with: #"[{"id":"provisional-1","provisional":true,"filePath":"a.ts","side":"new","lineNumber":1,"lineText":"x","body":"hi"}]"#)

        content.activate(focus: false)
        let nextEvaluator = RecordingCodePaneScriptEvaluator()
        content.scriptEvaluator = nextEvaluator
        content.handleReady()

        struct InjectedUpsertFailure: Error {}
        await gateway.failHeldUpsertCall(at: 0, error: InjectedUpsertFailure())

        await waitUntil { nextEvaluator.evaluatedScripts.contains { $0.contains("spaces:init") } }

        #expect(
            nextEvaluator.evaluatedScripts.contains { $0.contains(#""id":"provisional-1""#) && $0.contains(#""provisional":true"#) },
            "a failed CREATE must leave the stale provisional snapshot entry exactly as the teardown flush wrote it")
    }

    /// An UPDATE (`commentID` non-nil) completing across hibernation, success case: the reconcile
    /// mechanism applies only to CREATE successes, so an UPDATE's completion must leave any stored
    /// snapshot untouched even when its anchor and body match a stored entry exactly.
    @Test func anUpdateCompletionAcrossHibernationNeverReconciles() async {
        let gateway = RecordingCodePaneDeviceGateway()
        let hosting = DeviceCodePaneHostingDouble(device: fakeDevice())
        let content = makeController(hosting: hosting, deviceGateway: gateway)
        content.activate(focus: false)
        let evaluator = RecordingCodePaneScriptEvaluator()
        content.scriptEvaluator = evaluator

        await gateway.holdNextUpsertAttempts(1)
        content.dispatch(
            CodePaneBridge.Request(
                id: "req-1", method: "reviewCommentUpsert",
                params: ["id": "existing-id", "filePath": "a.ts", "side": "new", "lineNumber": 1, "lineText": "x", "body": "hi"]))

        while await gateway.reviewCommentUpsertCalls.count < 1 {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(5))
        }

        content.deactivate()
        evaluator.completeOldestPending(with: "__none__") // editor-state flush
        evaluator.completeOldestPending(
            with: #"[{"id":"provisional-1","provisional":true,"filePath":"a.ts","side":"new","lineNumber":1,"lineText":"x","body":"hi"}]"#)

        content.activate(focus: false)
        let nextEvaluator = RecordingCodePaneScriptEvaluator()
        content.scriptEvaluator = nextEvaluator
        content.handleReady()

        await gateway.completeHeldUpsertCall(
            at: 0,
            result: SpacesDeviceReviewComment(
                id: "existing-id", filePath: "a.ts", side: .new, lineNumber: 1, lineText: "x", body: "hi", createdAt: "2026-01-01T00:00:00Z",
                revision: 1))

        await waitUntil { nextEvaluator.evaluatedScripts.contains { $0.contains("spaces:init") } }

        #expect(
            nextEvaluator.evaluatedScripts.contains { $0.contains(#""id":"provisional-1""#) && $0.contains(#""provisional":true"#) },
            "an UPDATE completion must never reconcile pendingReviewCommentState, even when its anchor and body match a stored entry exactly")
    }
}
