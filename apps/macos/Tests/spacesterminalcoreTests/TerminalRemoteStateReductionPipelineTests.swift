import Foundation
import XCTest
import spacesterminalcore

/// The pipeline's contract: every payload submitted, from whichever entry point, is *reduced* exactly
/// once and in submission order, so the render-update delta chain the reducer maintains sees the same
/// series it saw when the reduction ran inline on the main actor. *Application* is latest-frame-wins:
/// a run of consecutive screen-content payloads collapses to its newest member, while a payload that
/// carries something other than screen content is a barrier that keeps its place and is always applied.
final class TerminalRemoteStateReductionPipelineTests: XCTestCase {
    /// What a test observes about one applied payload. `renderText` and `dropReason` together pin the
    /// state of the delta chain: a payload reduced against the wrong baseline drops instead of
    /// rendering.
    private struct AppliedOutput: Equatable {
        let emittedAt: String
        let reason: String
        let renderText: String?
        let frameText: String?
        let dropReason: String?
        let didRequestResync: Bool
        let requestsResync: Bool
        let coalescedAwayCount: Int
        let didReduce: Bool
    }

    private final class OutputCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var outputs: [AppliedOutput] = []

        func record(_ output: AppliedOutput) {
            lock.lock()
            outputs.append(output)
            lock.unlock()
        }

        var recorded: [AppliedOutput] {
            lock.lock()
            defer { lock.unlock() }
            return outputs
        }
    }

    /// Counts payloads as they reach the apply mailbox, via the pipeline's `didSubmitForTesting` hook.
    /// It is what lets a test know every payload it submitted has been handed to the mailbox — and so
    /// is safe to release the main thread it is deliberately holding — without waiting on the main actor
    /// itself. `shouldUseFrame` is not a safe signal for this: it runs *during* reduction, before the
    /// output it gates is constructed and handed to the mailbox, so counting there can see the last
    /// payload as "reduced" while its `mailbox.submit` has not run yet, letting the release race a drain
    /// that started one payload short.
    private final class SubmitProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        func recordSubmission() {
            lock.lock()
            count += 1
            lock.unlock()
        }

        var submissions: Int {
            lock.lock()
            defer { lock.unlock() }
            return count
        }
    }

    /// Stands in for the session host: the pipeline's apply closure holds it weakly, exactly as the
    /// host does, so releasing it must stop applications rather than resurrect a torn-down owner.
    private final class ApplyTarget: @unchecked Sendable {
        let collector: OutputCollector
        let applyDelay: TimeInterval

        init(collector: OutputCollector, applyDelay: TimeInterval = 0) {
            self.collector = collector
            self.applyDelay = applyDelay
        }

        func apply(_ output: TerminalRemoteStateReductionOutput) {
            if applyDelay > 0 { Thread.sleep(forTimeInterval: applyDelay) }
            collector.record(Self.appliedOutput(for: output))
        }

        static func appliedOutput(for output: TerminalRemoteStateReductionOutput) -> AppliedOutput {
            AppliedOutput(
                emittedAt: output.incomingPayload.emittedAt, reason: output.incomingPayload.reason,
                renderText: output.reduction?.storedPayload.renderText, frameText: output.reduction?.frameToApply.map(frameText),
                dropReason: output.reduction?.dropReason, didRequestResync: output.reduction?.didRequestResync ?? false,
                requestsResync: output.requestsResync, coalescedAwayCount: output.coalescedAwayCount, didReduce: output.reduction != nil)
        }

        /// The frame's first row, which is the only one the fixtures vary.
        private static func frameText(_ frame: GhosttyRenderFrame) -> String {
            let firstRow = GhosttyTerminalSnapshotGrid.fullPlainText(for: frame.snapshot).split(separator: "\n", omittingEmptySubsequences: false)
                .first
            return String(firstRow ?? "").trimmingCharacters(in: .whitespaces)
        }
    }

    /// The payloads a live session delivers: one full frame, then deltas chained off it, with a direct
    /// `.state` fetch (another full frame) and a clipboard write interleaved. Reducing this series in
    /// submission order is the only way every delta lands on the baseline it was built against.
    private func streamingSeries(sessionID: String, frameCount: Int, fetchIndex: Int, clipboardIndex: Int) throws -> [(
        payload: GhosttyRemoteSessionStatePayload, isDirectFetch: Bool
    )] {
        var frames: [GhosttyRenderFrame] = []
        for index in 0..<frameCount {
            frames.append(GhosttyRenderFrame(sessionRevision: UInt64(index + 1), ownerEpoch: 4, snapshot: snapshot(text: "frame-\(index)")))
        }
        var series: [(payload: GhosttyRemoteSessionStatePayload, isDirectFetch: Bool)] = []
        for index in 0..<frameCount {
            if index == clipboardIndex { series.append((clipboardPayload(sessionID: sessionID, sequence: series.count), false)) }
            if index == fetchIndex {
                // The direct fetch re-seeds the chain at the frame the stream just reached; the delta
                // submitted next is built against that same frame, so both orders of the two are
                // individually valid and only the submitted order keeps every later delta applying.
                series.append(
                    (
                        payload(
                            sessionID: sessionID, sequence: series.count, reason: TerminalRemoteSessionStateReason.stateChange,
                            update: .full(frames[index - 1])), true
                    ))
            }
            let update: GhosttyRenderUpdate =
                index == 0
                ? .full(frames[0])
                : GhosttyRenderUpdateFactory.makeUpdate(target: frames[index], baseline: GhosttyRenderUpdateBaseline(frame: frames[index - 1]))
            series.append(
                (payload(sessionID: sessionID, sequence: series.count, reason: TerminalRemoteSessionStateReason.output, update: update), false))
        }
        return series
    }

    /// The same series, reduced synchronously by a reducer this test owns: the behavior the pipeline
    /// has to reproduce exactly.
    private func synchronousOutputs(for series: [(payload: GhosttyRemoteSessionStatePayload, isDirectFetch: Bool)]) -> [AppliedOutput] {
        var reducer = TerminalRemoteStateReducer()
        var previousPayload: GhosttyRemoteSessionStatePayload?
        return series.map { entry in
            guard entry.payload.reason != TerminalRemoteSessionStateReason.clipboardWrite else {
                return ApplyTarget.appliedOutput(for: TerminalRemoteStateReductionOutput(incomingPayload: entry.payload, reduction: nil, reduceMS: 0))
            }
            let reduction = reducer.reduce(incomingPayload: entry.payload, previousPayload: previousPayload, requestResyncOnApplyFailure: true)
            previousPayload = reduction.storedPayload
            return ApplyTarget.appliedOutput(
                for: TerminalRemoteStateReductionOutput(incomingPayload: entry.payload, reduction: reduction, reduceMS: 0))
        }
    }

    /// Every payload reduces, in submission order, whichever entry point submitted it. Submissions are
    /// paced one apply at a time so nothing can be coalesced and each reduction is observed on its own:
    /// the burst behavior is covered by the coalescing tests below.
    func testPipelineReducesEveryPayloadInSubmissionOrderAcrossBothEntryPoints() async throws {
        let series = try streamingSeries(sessionID: "pipeline-order", frameCount: 24, fetchIndex: 9, clipboardIndex: 5)
        let expected = synchronousOutputs(for: series)
        XCTAssertTrue(expected.allSatisfy { $0.dropReason == nil }, "the reference series must reduce cleanly in order")

        let collector = OutputCollector()
        let target = ApplyTarget(collector: collector)
        let pipeline = TerminalRemoteStateReductionPipeline(
            shouldUseFrame: { _, _ in true }, apply: { [weak target] output in target?.apply(output) })

        // The subscription's payloads arrive on the stream's own thread and the direct fetch's on the
        // main actor; FIFO has to hold across both, so the test submits from both.
        let streamQueue = DispatchQueue(label: "spaces.test.remote-state-stream")
        for (index, entry) in series.enumerated() {
            if entry.isDirectFetch {
                await MainActor.run { pipeline.submit(entry.payload) }
            } else {
                streamQueue.sync { pipeline.submit(entry.payload) }
            }
            try await waitUntil("payload \(index) applied") { collector.recorded.count == index + 1 }
        }

        XCTAssertEqual(collector.recorded, expected)
        XCTAssertEqual(collector.recorded.filter { !$0.didReduce }.map(\.reason), [TerminalRemoteSessionStateReason.clipboardWrite])
        XCTAssertTrue(collector.recorded.allSatisfy { $0.coalescedAwayCount == 0 })
    }

    /// A burst of frames the main actor could not keep up with collapses to one apply carrying the
    /// newest frame. The newest frame is only correct if every delta in the burst still reduced in
    /// order against the baseline it was built against, so this pins the reduce/apply split as a whole.
    func testBurstOfFramesCollapsesToOneApplyCarryingTheNewestFrame() async throws {
        let series = try streamingSeries(sessionID: "pipeline-burst", frameCount: 40, fetchIndex: 400, clipboardIndex: 400)
        let collector = OutputCollector()
        let target = ApplyTarget(collector: collector)
        let probe = SubmitProbe()
        let pipeline = TerminalRemoteStateReductionPipeline(
            shouldUseFrame: { _, _ in true }, apply: { [weak target] output in target?.apply(output) },
            didSubmitForTesting: { probe.recordSubmission() })

        let release = blockMainThread()
        for entry in series { pipeline.submit(entry.payload) }
        try await waitUntil("every payload submitted to the mailbox") { probe.submissions == series.count }
        XCTAssertEqual(collector.recorded.count, 0, "an apply ran while the main actor was held")
        release.signal()

        try await waitUntil("the burst applied") { !collector.recorded.isEmpty }
        try await settle()
        XCTAssertEqual(collector.recorded.count, 1)
        XCTAssertEqual(collector.recorded.first?.frameText, "frame-39")
        XCTAssertEqual(collector.recorded.first?.dropReason, nil)
        XCTAssertEqual(collector.recorded.first?.coalescedAwayCount, series.count - 1)
    }

    /// A clipboard write is a barrier: its side effect is a pasteboard write whose position among the
    /// state around it matters, so the runs on either side of it collapse independently and it is
    /// applied between them.
    func testClipboardWriteSurvivesBetweenCoalescedRuns() async throws {
        let series = try streamingSeries(sessionID: "pipeline-clipboard", frameCount: 10, fetchIndex: 400, clipboardIndex: 5)
        let collector = OutputCollector()
        let target = ApplyTarget(collector: collector)
        let probe = SubmitProbe()
        let pipeline = TerminalRemoteStateReductionPipeline(
            shouldUseFrame: { _, _ in true }, apply: { [weak target] output in target?.apply(output) },
            didSubmitForTesting: { probe.recordSubmission() })

        let release = blockMainThread()
        for entry in series { pipeline.submit(entry.payload) }
        try await waitUntil("every payload submitted to the mailbox") { probe.submissions == series.count }
        release.signal()

        try await waitUntil("the whole series applied") { collector.recorded.count == 3 }
        try await settle()
        XCTAssertEqual(
            collector.recorded.map(\.reason),
            [TerminalRemoteSessionStateReason.output, TerminalRemoteSessionStateReason.clipboardWrite, TerminalRemoteSessionStateReason.output])
        XCTAssertEqual(collector.recorded.map(\.frameText), ["frame-4", nil, "frame-9"])
        XCTAssertEqual(collector.recorded.map(\.coalescedAwayCount), [4, 0, 4])
    }

    /// A delta that cannot apply asks for a resync. That request is a one-shot the session needs even
    /// when the payload carrying it is superseded before it reaches the screen, so it rides onto the
    /// output that replaced it — but only when that replacement carries its own frame:
    /// `ApplyMailbox.mayCollapse` never lets the frameless, failed delta absorb the full frame ahead of
    /// it (`alpha`), so `alpha` stays queued on its own and is applied first. The full frame behind it
    /// (`charl`) *does* collapse the failed delta away, since `charl` carries its own frame and so loses
    /// nothing by replacing it, and it inherits the failed delta's resync request in the process.
    func testResyncRequestFromACoalescedOutputStillArrives() async throws {
        let sessionID = "pipeline-coalesced-resync"
        let first = GhosttyRenderFrame(sessionRevision: 1, ownerEpoch: 4, snapshot: snapshot(text: "alpha"))
        let second = GhosttyRenderFrame(sessionRevision: 2, ownerEpoch: 4, snapshot: snapshot(text: "bravo"))
        let third = GhosttyRenderFrame(sessionRevision: 3, ownerEpoch: 4, snapshot: snapshot(text: "charl"))
        let secondToThird = GhosttyRenderUpdateFactory.makeUpdate(target: third, baseline: GhosttyRenderUpdateBaseline(frame: second))
        XCTAssertEqual(secondToThird.kind, .delta)
        let payloads = [
            payload(sessionID: sessionID, sequence: 0, reason: TerminalRemoteSessionStateReason.output, update: .full(first)),
            // Its base is revision 2, which the baseline is not: the reducer drops it and asks for a resync.
            payload(sessionID: sessionID, sequence: 1, reason: TerminalRemoteSessionStateReason.output, update: secondToThird),
            payload(sessionID: sessionID, sequence: 2, reason: TerminalRemoteSessionStateReason.output, update: .full(third)),
        ]

        let collector = OutputCollector()
        let target = ApplyTarget(collector: collector)
        let probe = SubmitProbe()
        let pipeline = TerminalRemoteStateReductionPipeline(
            shouldUseFrame: { _, _ in true }, apply: { [weak target] output in target?.apply(output) },
            didSubmitForTesting: { probe.recordSubmission() })

        let release = blockMainThread()
        for payload in payloads { pipeline.submit(payload) }
        try await waitUntil("every payload submitted to the mailbox") { probe.submissions == payloads.count }
        release.signal()

        try await waitUntil("both surviving entries applied") { collector.recorded.count == 2 }
        try await settle()
        XCTAssertEqual(collector.recorded.count, 2, "the leading full frame must survive; the frameless failed delta cannot coalesce it away")
        XCTAssertEqual(collector.recorded.map(\.frameText), ["alpha", "charl"])
        XCTAssertEqual(collector.recorded.map(\.didRequestResync), [false, false], "both surviving full frames reduced cleanly on their own")
        XCTAssertEqual(
            collector.recorded.map(\.requestsResync), [false, true], "the coalesced-away delta's resync request must still ride onto its replacement")
        XCTAssertEqual(collector.recorded.map(\.coalescedAwayCount), [0, 1])
    }

    /// Coalescing must never let a frameless output silently absorb a pending frame-carrying one.
    /// `input` never carries a render update at all (`TerminalRemoteSessionStatePolicy.shouldIncludeScreenState`
    /// excludes screen state for it), yet its reason still routes to `.spacesTerminalOutputDidChange`
    /// alone, the same as `output`, so it is coalescible-on-apply by reason. Collapsing purely on reason
    /// would fold this frameless payload into the full frame ahead of it and inherit the *newer*
    /// (frameless) reduction, discarding the frame with no resync requested to make up for it — the
    /// pane would stay one frame stale until unrelated later traffic happened to resync it.
    /// `ApplyMailbox.mayCollapse` exists to refuse exactly this collapse.
    func testFramelessCoalescibleOutputCannotAbsorbAPendingFrame() async throws {
        let sessionID = "pipeline-frame-safety"
        let frame = GhosttyRenderFrame(sessionRevision: 1, ownerEpoch: 4, snapshot: snapshot(text: "keep-me"))
        let framePayload = payload(sessionID: sessionID, sequence: 0, reason: TerminalRemoteSessionStateReason.output, update: .full(frame))
        let framelessPayload = inputPayload(sessionID: sessionID, sequence: 1)

        let collector = OutputCollector()
        let target = ApplyTarget(collector: collector)
        let probe = SubmitProbe()
        let pipeline = TerminalRemoteStateReductionPipeline(
            shouldUseFrame: { _, _ in true }, apply: { [weak target] output in target?.apply(output) },
            didSubmitForTesting: { probe.recordSubmission() })

        // Both submissions land in the mailbox while the main thread is held, which is exactly the
        // situation `ApplyMailbox.submit` collapses runs in: without the frame check, the frameless
        // second entry would replace the first before either is ever applied.
        let release = blockMainThread()
        pipeline.submit(framePayload)
        pipeline.submit(framelessPayload)
        try await waitUntil("both payloads submitted to the mailbox") { probe.submissions == 2 }
        release.signal()

        try await waitUntil("both payloads applied") { collector.recorded.count == 2 }
        try await settle()
        XCTAssertEqual(collector.recorded.count, 2, "the frame-carrying output must not be coalesced away by the frameless one that followed it")
        XCTAssertEqual(collector.recorded.map(\.reason), [TerminalRemoteSessionStateReason.output, TerminalRemoteSessionStateReason.input])
        XCTAssertEqual(collector.recorded.map(\.frameText), ["keep-me", nil], "the pending frame must survive; it would be nil today")
        XCTAssertEqual(collector.recorded.map(\.coalescedAwayCount), [0, 0])
    }

    /// A delta that cannot apply resets the baseline inside the reducer. The reset belongs to its place
    /// in the series: the payloads after it must see the cleared baseline, and the full frame that
    /// follows must re-seed it, all without any of them overtaking the others. Submissions are paced so
    /// each reduction is applied on its own instead of being coalesced away.
    func testBaselineResetFromAFailedDeltaLandsInOrder() async throws {
        let first = GhosttyRenderFrame(sessionRevision: 1, ownerEpoch: 4, snapshot: snapshot(text: "alpha"))
        let second = GhosttyRenderFrame(sessionRevision: 2, ownerEpoch: 4, snapshot: snapshot(text: "bravo"))
        let third = GhosttyRenderFrame(sessionRevision: 3, ownerEpoch: 4, snapshot: snapshot(text: "charl"))
        let firstToSecond = GhosttyRenderUpdateFactory.makeUpdate(target: second, baseline: GhosttyRenderUpdateBaseline(frame: first))
        let secondToThird = GhosttyRenderUpdateFactory.makeUpdate(target: third, baseline: GhosttyRenderUpdateBaseline(frame: second))
        XCTAssertEqual(firstToSecond.kind, .delta)
        XCTAssertEqual(secondToThird.kind, .delta)

        let sessionID = "pipeline-baseline-reset"
        let series: [(payload: GhosttyRemoteSessionStatePayload, isDirectFetch: Bool)] = [
            // A full frame seeds the baseline at revision 1.
            (payload(sessionID: sessionID, sequence: 0, reason: TerminalRemoteSessionStateReason.output, update: .full(first)), false),
            // A delta whose base is revision 2 cannot apply to it: the reducer clears the baseline and
            // asks for a resync.
            (payload(sessionID: sessionID, sequence: 1, reason: TerminalRemoteSessionStateReason.output, update: secondToThird), false),
            // The next delta finds no baseline at all, which is only true if the reset landed first.
            (payload(sessionID: sessionID, sequence: 2, reason: TerminalRemoteSessionStateReason.output, update: firstToSecond), false),
            // A fetched full frame re-seeds the chain.
            (payload(sessionID: sessionID, sequence: 3, reason: TerminalRemoteSessionStateReason.stateChange, update: .full(third)), true),
        ]

        let collector = OutputCollector()
        let target = ApplyTarget(collector: collector)
        let pipeline = TerminalRemoteStateReductionPipeline(
            shouldUseFrame: { _, _ in true }, apply: { [weak target] output in target?.apply(output) })
        for (index, entry) in series.enumerated() {
            pipeline.submit(entry.payload)
            try await waitUntil("payload \(index) applied") { collector.recorded.count == index + 1 }
        }

        XCTAssertEqual(collector.recorded, synchronousOutputs(for: series))
        XCTAssertEqual(collector.recorded.map(\.dropReason), [nil, "base_revision_mismatch", "missing_baseline", nil])
        XCTAssertEqual(collector.recorded.map(\.didRequestResync), [false, true, true, false])
        XCTAssertEqual(collector.recorded.map(\.frameText), ["alpha", nil, nil, "charl"])
    }

    /// Teardown: the pipeline goes away with its owner. Whatever was still queued is dropped rather
    /// than reduced for an owner that no longer exists, and nothing is applied to the released target.
    ///
    /// Built from `session_metadata` payloads deliberately, not the usual streaming series: those are
    /// screen-content reasons that coalesce on apply, so a 200-payload burst of them collapses to at
    /// most a handful of applies regardless of teardown — `appliedAfterRelease < series.count` would
    /// pass trivially on coalescing alone and prove nothing about release actually stopping the drain.
    /// `session_metadata` is a barrier reason (see `sessionMetadataPayload`): every payload queues its
    /// own apply, so the count below can only stay small because release cut the drain off mid-queue.
    func testReleasingThePipelineStopsApplyingQueuedPayloads() async throws {
        let series = (0..<200).map { sessionMetadataPayload(sessionID: "pipeline-teardown", sequence: $0) }
        let collector = OutputCollector()
        let firstApply = expectation(description: "first payload applied")
        firstApply.assertForOverFulfill = false
        var target: ApplyTarget? = ApplyTarget(collector: collector, applyDelay: 0.002)
        weak var weakTarget = target
        var pipeline: TerminalRemoteStateReductionPipeline? = TerminalRemoteStateReductionPipeline(
            shouldUseFrame: { _, _ in true },
            apply: { [weak target] output in
                target?.apply(output)
                firstApply.fulfill()
            })
        weak var weakPipeline = pipeline

        for payload in series { pipeline?.submit(payload) }
        await fulfillment(of: [firstApply], timeout: 20)

        pipeline = nil
        target = nil
        try await Task.sleep(for: .milliseconds(300))
        let appliedAfterRelease = collector.recorded.count
        try await Task.sleep(for: .milliseconds(300))

        XCTAssertEqual(collector.recorded.count, appliedAfterRelease, "the pipeline applied a payload after its owner was released")
        XCTAssertLessThan(appliedAfterRelease, series.count, "the pipeline drained its queue instead of stopping with its owner")
        XCTAssertNil(weakPipeline, "the consumer task outlived the pipeline")
        XCTAssertNil(weakTarget, "the pipeline held its apply target strongly")
    }

    // MARK: - Test control

    /// Occupies the main actor until the returned semaphore is signalled. The mailbox drains on the
    /// main actor, so holding it is what makes a burst deterministic: every payload the reduce loop
    /// finishes meanwhile lands in the mailbox and coalesces there, with no apply able to interleave.
    private func blockMainThread() -> DispatchSemaphore {
        let release = DispatchSemaphore(value: 0)
        let blocked = DispatchSemaphore(value: 0)
        DispatchQueue.main.async {
            blocked.signal()
            release.wait()
        }
        blocked.wait()
        return release
    }

    private func waitUntil(_ description: String, timeout: TimeInterval = 20, _ condition: @Sendable () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() >= deadline {
                XCTFail("timed out waiting for \(description)")
                return
            }
            try await Task.sleep(for: .milliseconds(2))
        }
    }

    /// Long enough for a drain that had more to do to have done it, so a count assertion means the
    /// pipeline stopped there rather than merely not having got there yet.
    private func settle() async throws { try await Task.sleep(for: .milliseconds(200)) }

    // MARK: - Payload construction

    private func payload(sessionID: String, sequence: Int, reason: String, update: GhosttyRenderUpdate) -> GhosttyRemoteSessionStatePayload {
        GhosttyRemoteSessionStatePayload(
            sessionID: sessionID, reason: reason, emittedAt: emittedAt(sequence), sessionStateRevision: UInt64(sequence + 1), sessionStateFlags: 1,
            screenStateRevision: UInt64(sequence + 1), runtimeState: nil, attachmentSnapshot: nil, title: "live", workingDirectory: "/tmp/live",
            outputByteCount: nil, renderUpdate: try? GhosttyRenderUpdateBinaryCodec.encode(update))
    }

    private func clipboardPayload(sessionID: String, sequence: Int) -> GhosttyRemoteSessionStatePayload {
        GhosttyRemoteSessionStatePayload(
            sessionID: sessionID, reason: TerminalRemoteSessionStateReason.clipboardWrite, emittedAt: emittedAt(sequence), sessionStateRevision: nil,
            sessionStateFlags: nil, screenStateRevision: nil, runtimeState: nil, attachmentSnapshot: nil, title: "live",
            workingDirectory: "/tmp/live", outputByteCount: nil,
            clipboardWrite: TerminalClipboardWritePayload(targetClientID: "mac-owner", text: "copied"))
    }

    /// A `session_metadata` payload: a barrier reason (its routed notification is
    /// `.spacesTerminalSessionMetadataDidChange` alone, never `.spacesTerminalOutputDidChange`, so
    /// `isCoalescibleOnApply` is false), carrying no render update. A series built from these never
    /// coalesces on apply, which is the point where a test needs every submitted payload to actually
    /// queue an apply instead of being absorbed into a neighbor's.
    private func sessionMetadataPayload(sessionID: String, sequence: Int) -> GhosttyRemoteSessionStatePayload {
        GhosttyRemoteSessionStatePayload(
            sessionID: sessionID, reason: TerminalRemoteSessionStateReason.sessionMetadata, emittedAt: emittedAt(sequence),
            sessionStateRevision: UInt64(sequence + 1), sessionStateFlags: 1, screenStateRevision: nil, runtimeState: nil, attachmentSnapshot: nil,
            title: "live-\(sequence)", workingDirectory: "/tmp/live", outputByteCount: nil)
    }

    /// An `input` payload: coalescible-on-apply by reason (see `TerminalRemoteSessionStateNotificationRouting`)
    /// but never carrying a render update — `TerminalRemoteSessionStatePolicy.shouldIncludeScreenState`
    /// excludes screen state for this reason, so a daemon never attaches one.
    private func inputPayload(sessionID: String, sequence: Int) -> GhosttyRemoteSessionStatePayload {
        GhosttyRemoteSessionStatePayload(
            sessionID: sessionID, reason: TerminalRemoteSessionStateReason.input, emittedAt: emittedAt(sequence),
            sessionStateRevision: UInt64(sequence + 1), sessionStateFlags: 1, screenStateRevision: nil, runtimeState: nil, attachmentSnapshot: nil,
            title: "live", workingDirectory: "/tmp/live", outputByteCount: nil)
    }

    private func emittedAt(_ sequence: Int) -> String { String(format: "2026-05-20T00:%02d:%02dZ", sequence / 60, sequence % 60) }

    /// A grid wide enough that a delta and a materialized full frame differ in cost the way they do in
    /// a real session, and tall enough that a row-scoped delta leaves most of it untouched.
    private func snapshot(text: String) -> GhosttyTerminalSnapshot {
        let columns = 80
        let rows = 24
        var cells: [GhosttyTerminalSnapshot.Cell] = []
        cells.reserveCapacity(columns * rows)
        for row in 0..<rows {
            let rowText = row == 0 ? text : "row-\(row)"
            let padded = rowText.padding(toLength: columns, withPad: " ", startingAt: 0)
            for scalar in padded.unicodeScalars {
                cells.append(GhosttyTerminalSnapshot.Cell(codepoint: scalar.value, foregroundRGB: 0xFFFFFF, backgroundRGB: 0x000000, flags: 0))
            }
        }
        return GhosttyTerminalSnapshot(
            columns: columns, rows: rows, cursorColumn: 0, cursorRow: 0, cursorVisible: false, defaultForegroundRGB: 0xFFFFFF,
            defaultBackgroundRGB: 0x000000, cells: cells)
    }
}
