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

    // MARK: - Editor-state / mode hibernation snapshot (round-5)

    // No "/" in the path: JSONEncoder escapes forward slashes as "\/" in the emitted JS, which would
    // make a plain substring match brittle for no benefit these tests need.
    private func fakeEditorState(path: String = "foo.ts", dirty: Bool = true) -> CodePaneBridge.EditorState {
        CodePaneBridge.EditorState(path: path, baseSHA256: "sha-abc", content: "let x = 1;", dirty: dirty)
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

        content.close()
        content.activate(focus: false)
        let evaluator = RecordingCodePaneScriptEvaluator()
        content.scriptEvaluator = evaluator
        content.handleReady()

        #expect(
            evaluator.evaluatedScripts.contains { $0.contains(#""initialMode":"diff""#) },
            "close() must reset the live mode back to initialMode, not carry a toggled mode forward")
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

        evaluator.completeOldestPending(with: #"{"path":"foo.ts","baseSHA256":"sha-abc","content":"let x = 1;","dirty":true}"#)

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
        firstEvaluator.completeOldestPending(with: #"{"path":"foo.ts","baseSHA256":"sha-abc","content":"let x = 1;","dirty":true}"#)

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

    /// A `null` flush result (no file open on the flushed page) is authoritative for its own
    /// generation, exactly like any other flush answer — it must clear a stale prior snapshot rather
    /// than leaving it in place, since the collect script reads the editor's live state directly.
    @Test func aNullFlushResultClearsAnExistingSnapshotForItsOwnGeneration() {
        let content = makeController()
        content.activate(focus: false)
        content.handleEditorStateChanged(fakeEditorState(), senderWebView: liveWebView(content))

        let evaluator = RecordingCodePaneScriptEvaluator()
        content.scriptEvaluator = evaluator

        content.deactivate() // flush reads the same generation's page, now reporting no open file

        evaluator.completeOldestPending(with: nil)

        content.activate(focus: false)
        let nextEvaluator = RecordingCodePaneScriptEvaluator()
        content.scriptEvaluator = nextEvaluator
        content.handleReady()

        #expect(
            !nextEvaluator.evaluatedScripts.contains { $0.contains("editorState") },
            "a null flush from the same generation as the last push is authoritative and must clear the stored snapshot")
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
        evaluator.completeOldestPending(with: #"{"path":"foo.ts","baseSHA256":"sha-abc","content":"let x = 1;","dirty":true}"#)

        content.activate(focus: false)
        let nextEvaluator = RecordingCodePaneScriptEvaluator()
        content.scriptEvaluator = nextEvaluator
        content.handleReady()

        #expect(
            !nextEvaluator.evaluatedScripts.contains { $0.contains(#""path":"foo.ts""#) },
            "close() must permanently discard the snapshot even if a flush it kicked off answers afterward")
    }
}
