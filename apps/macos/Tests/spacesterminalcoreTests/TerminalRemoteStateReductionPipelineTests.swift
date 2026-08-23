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

    /// The ordering an out-of-band `.state` response has to survive: it is submitted while a newer stream
    /// frame is already queued ahead of it and still reducing off the main actor. Nothing at the request's
    /// completion can see that frame — it has not applied yet — so the staleness decision belongs here, at
    /// the head of the queue, where the baseline is authoritative. Both payloads are submitted before
    /// either is drained, which is exactly the window a completion-time comparison misses.
    func testOutOfBandResponseSubmittedBehindANewerStreamFrameIsRefusedInOrder() async throws {
        let sessionID = "pipeline-out-of-band-order"
        let collector = OutputCollector()
        let target = ApplyTarget(collector: collector)
        let pipeline = TerminalRemoteStateReductionPipeline(
            shouldUseFrame: { _, _ in true }, apply: { [weak target] output in target?.apply(output) })

        let older = GhosttyRenderFrame(sessionRevision: 1, ownerEpoch: 4, snapshot: snapshot(text: "frame-0"))
        let newer = GhosttyRenderFrame(sessionRevision: 2, ownerEpoch: 4, snapshot: snapshot(text: "frame-1"))
        // Seed the chain, then submit the newer stream frame and the older response back to back.
        pipeline.submit(payload(sessionID: sessionID, sequence: 0, reason: TerminalRemoteSessionStateReason.output, update: .full(older)))
        try await waitUntil("seed applied") { collector.recorded.count == 1 }

        pipeline.submit(payload(sessionID: sessionID, sequence: 1, reason: TerminalRemoteSessionStateReason.output, update: .full(newer)))
        pipeline.submit(
            payload(sessionID: sessionID, sequence: 2, reason: TerminalRemoteSessionStateReason.initial, update: .full(older)), isOutOfBand: true)

        try await waitUntil("both applied") { collector.recorded.count == 3 }
        let outputs = collector.recorded
        XCTAssertEqual(outputs[1].frameText, "frame-1")
        XCTAssertNil(outputs[2].frameText, "the response lost the race and must not repaint an older screen")
        // Only its render update is refused; this response is stamped later than the frame it lost to, so
        // its metadata is ordered on its own terms and lands.
        XCTAssertEqual(outputs[2].dropReason, "stale_out_of_band_frame")
        XCTAssertFalse(outputs[2].requestsResync, "the baseline is newer than the refused frame, so nothing is owed")
        XCTAssertEqual(outputs[2].renderText, outputs[1].renderText, "the stored state keeps the newer screen")
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

    /// The other leg of `ApplyMailbox.mayCollapse`'s frame check: a frameless run collapses onto itself
    /// exactly like a frame-carrying one. `input` never carries a render update
    /// (`TerminalRemoteSessionStatePolicy.shouldIncludeScreenState` excludes screen state for it), so
    /// `pending.reduction?.frameToApply == nil` holds on every entry, satisfying `mayCollapse`'s
    /// "the pending entry never carried one either" branch — nothing is lost by collapsing, unlike
    /// `testFramelessCoalescibleOutputCannotAbsorbAPendingFrame` where a frame-carrying entry sat ahead
    /// of the frameless one. This is the leg that keeps a pure input storm (rapid keystrokes with no
    /// accompanying screen content) from rebuilding an unbounded backlog the way a frame-losing collapse
    /// would have to be refused for.
    func testFramelessCoalescibleOutputCollapsesOntoAnotherFramelessOutput() async throws {
        let sessionID = "pipeline-frameless-collapse"
        let payloads = (0..<5).map { inputPayload(sessionID: sessionID, sequence: $0) }

        let collector = OutputCollector()
        let target = ApplyTarget(collector: collector)
        let probe = SubmitProbe()
        let pipeline = TerminalRemoteStateReductionPipeline(
            shouldUseFrame: { _, _ in true }, apply: { [weak target] output in target?.apply(output) },
            didSubmitForTesting: { probe.recordSubmission() })

        // All five land in the mailbox while the main thread is held, so nothing can apply until the
        // release below — exactly the burst a pure input storm produces when the main actor is busy.
        let release = blockMainThread()
        for payload in payloads { pipeline.submit(payload) }
        try await waitUntil("every payload submitted to the mailbox") { probe.submissions == payloads.count }
        release.signal()

        try await waitUntil("the burst applied") { !collector.recorded.isEmpty }
        try await settle()
        XCTAssertEqual(collector.recorded.count, 1, "a frameless run must collapse to a single apply")
        XCTAssertEqual(collector.recorded.first?.reason, TerminalRemoteSessionStateReason.input)
        XCTAssertEqual(collector.recorded.first?.frameText, nil)
        XCTAssertEqual(collector.recorded.first?.coalescedAwayCount, 4)
    }

    /// A collector for tests that need a coalesced apply's frame itself, scroll rects included:
    /// `AppliedOutput`'s `frameText` view only pins the screen text, which says nothing about how content
    /// moved to produce it.
    private final class RawOutputCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var outputs: [TerminalRemoteStateReductionOutput] = []

        func record(_ output: TerminalRemoteStateReductionOutput) {
            lock.lock()
            outputs.append(output)
            lock.unlock()
        }

        var recorded: [TerminalRemoteStateReductionOutput] {
            lock.lock()
            defer { lock.unlock() }
            return outputs
        }
    }

    /// Coalescing a run of deltas must not drop the rects of the frames it collapses away.
    /// `GhosttyMirrorTerminalView` accumulates its drag-carry buffer only from applied frames, so a
    /// coalesced-away frame's rects have nowhere else to reach it; if `inheritingEffects(ofCoalesced:)`
    /// only carried forward `coalescedAwayCount` and `inheritedResyncRequest` (as it used to), the
    /// surviving apply would silently under-report how far content moved, and a drag rebased against it
    /// would land on the wrong rows while `scrollRectsOverflowed` still claimed the carry was trustworthy.
    func testCoalescedFrameScrollRectsSurviveOnTheApplyThatReplacesThem() async throws {
        let sessionID = "pipeline-coalesced-scroll-rects"
        let alpha = GhosttyRenderFrame(sessionRevision: 1, ownerEpoch: 4, snapshot: snapshot(text: "alpha"))
        let bravo = GhosttyRenderFrame(sessionRevision: 2, ownerEpoch: 4, snapshot: snapshot(text: "bravo"))
        let charlie = GhosttyRenderFrame(sessionRevision: 3, ownerEpoch: 4, snapshot: snapshot(text: "charl"))

        // The skipped delta (alpha -> bravo) overflows; the surviving one (bravo -> charlie) does not.
        // The merged carry must still be poisoned: an OR, not whichever the surviving delta happened to say.
        let skippedRect = GhosttyRenderScrollRectOperation(rowStart: 0, rowCount: 5, columnStart: 0, columnCount: 80, deltaRows: 3, deltaColumns: 0)
        let survivingRect = GhosttyRenderScrollRectOperation(rowStart: 2, rowCount: 4, columnStart: 0, columnCount: 80, deltaRows: 2, deltaColumns: 0)
        let alphaToBravo = GhosttyRenderUpdateFactory.makeUpdate(
            target: bravo, baseline: GhosttyRenderUpdateBaseline(frame: alpha), nativeScrollRects: [skippedRect], nativeScrollRectsOverflowed: true)
        let bravoToCharlie = GhosttyRenderUpdateFactory.makeUpdate(
            target: charlie, baseline: GhosttyRenderUpdateBaseline(frame: bravo), nativeScrollRects: [survivingRect],
            nativeScrollRectsOverflowed: false)
        XCTAssertEqual(alphaToBravo.kind, .delta)
        XCTAssertEqual(bravoToCharlie.kind, .delta)

        let seedPayload = payload(sessionID: sessionID, sequence: 0, reason: TerminalRemoteSessionStateReason.output, update: .full(alpha))
        let firstDeltaPayload = payload(sessionID: sessionID, sequence: 1, reason: TerminalRemoteSessionStateReason.output, update: alphaToBravo)
        let secondDeltaPayload = payload(sessionID: sessionID, sequence: 2, reason: TerminalRemoteSessionStateReason.output, update: bravoToCharlie)

        let collector = RawOutputCollector()
        let probe = SubmitProbe()
        let pipeline = TerminalRemoteStateReductionPipeline(
            shouldUseFrame: { _, _ in true }, apply: { output in collector.record(output) }, didSubmitForTesting: { probe.recordSubmission() })

        // Seed the baseline on its own so the two deltas below are the only entries in the mailbox when
        // the main actor is held, which is what makes the second collapse onto the first deterministic.
        pipeline.submit(seedPayload)
        try await waitUntil("seed applied") { collector.recorded.count == 1 }

        let release = blockMainThread()
        pipeline.submit(firstDeltaPayload)
        pipeline.submit(secondDeltaPayload)
        try await waitUntil("both deltas submitted to the mailbox") { probe.submissions == 3 }
        release.signal()

        try await waitUntil("the coalesced delta applied") { collector.recorded.count == 2 }
        try await settle()
        XCTAssertEqual(collector.recorded.count, 2)

        let coalesced = collector.recorded[1]
        XCTAssertEqual(coalesced.coalescedAwayCount, 1, "the alpha->bravo delta must have been coalesced into the surviving apply")
        let mergedFrame = try XCTUnwrap(coalesced.reduction?.frameToApply)
        XCTAssertEqual(
            mergedFrame.scrollRects, [skippedRect, survivingRect],
            "the coalesced-away delta's rects must precede the surviving delta's own rects, oldest first")
        XCTAssertTrue(mergedFrame.scrollRectsOverflowed, "an overflow on either the skipped or surviving frame must poison the merged carry")
    }

    /// The rect merge above is what a stalled main actor grows: every extra collapse appends the
    /// skipped frame's rects onto the pending one's. Past `GhosttyRenderFrame.maxAccumulatedScrollRects`
    /// the merged carry stops pretending to be a complete history: the rects are dropped and the frame
    /// reports overflowed, the same cancelled-carry state the mirror's own buffer degrades to, so the
    /// mailbox holds a bounded amount no matter how long the stall lasts.
    func testCoalescedScrollRectMergePastTheCapDropsRectsAndReportsOverflow() async throws {
        let sessionID = "pipeline-coalesced-scroll-rect-cap"
        let alpha = GhosttyRenderFrame(sessionRevision: 1, ownerEpoch: 4, snapshot: snapshot(text: "alpha"))
        let bravo = GhosttyRenderFrame(sessionRevision: 2, ownerEpoch: 4, snapshot: snapshot(text: "bravo"))
        let charlie = GhosttyRenderFrame(sessionRevision: 3, ownerEpoch: 4, snapshot: snapshot(text: "charl"))

        let rect = GhosttyRenderScrollRectOperation(rowStart: 0, rowCount: 5, columnStart: 0, columnCount: 80, deltaRows: 3, deltaColumns: 0)
        let skippedRects = Array(repeating: rect, count: GhosttyRenderFrame.maxAccumulatedScrollRects)
        let alphaToBravo = GhosttyRenderUpdateFactory.makeUpdate(
            target: bravo, baseline: GhosttyRenderUpdateBaseline(frame: alpha), nativeScrollRects: skippedRects, nativeScrollRectsOverflowed: false)
        let bravoToCharlie = GhosttyRenderUpdateFactory.makeUpdate(
            target: charlie, baseline: GhosttyRenderUpdateBaseline(frame: bravo), nativeScrollRects: [rect], nativeScrollRectsOverflowed: false)
        XCTAssertEqual(alphaToBravo.kind, .delta)
        XCTAssertEqual(bravoToCharlie.kind, .delta)

        let seedPayload = payload(sessionID: sessionID, sequence: 0, reason: TerminalRemoteSessionStateReason.output, update: .full(alpha))
        let firstDeltaPayload = payload(sessionID: sessionID, sequence: 1, reason: TerminalRemoteSessionStateReason.output, update: alphaToBravo)
        let secondDeltaPayload = payload(sessionID: sessionID, sequence: 2, reason: TerminalRemoteSessionStateReason.output, update: bravoToCharlie)

        let collector = RawOutputCollector()
        let probe = SubmitProbe()
        let pipeline = TerminalRemoteStateReductionPipeline(
            shouldUseFrame: { _, _ in true }, apply: { output in collector.record(output) }, didSubmitForTesting: { probe.recordSubmission() })

        pipeline.submit(seedPayload)
        try await waitUntil("seed applied") { collector.recorded.count == 1 }

        let release = blockMainThread()
        pipeline.submit(firstDeltaPayload)
        pipeline.submit(secondDeltaPayload)
        try await waitUntil("both deltas submitted to the mailbox") { probe.submissions == 3 }
        release.signal()

        try await waitUntil("the coalesced delta applied") { collector.recorded.count == 2 }
        try await settle()

        let coalesced = collector.recorded[1]
        XCTAssertEqual(coalesced.coalescedAwayCount, 1, "the alpha->bravo delta must have been coalesced into the surviving apply")
        let mergedFrame = try XCTUnwrap(coalesced.reduction?.frameToApply)
        XCTAssertEqual(mergedFrame.scrollRects, [], "a merge past the cap keeps no rects; a truncated history would rebase drags to the wrong rows")
        XCTAssertTrue(mergedFrame.scrollRectsOverflowed, "a merge past the cap must report the cancelled carry")
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

    /// Teardown: the pipeline goes away with its owner, and application must not keep running against
    /// a released target. `ApplyMailbox.drain()` copies whatever is queued into one segment
    /// (`takeQueuedSegment`) before applying any of it, so release cannot cut a segment off mid-flight
    /// once `drain()` has captured it — what actually stops applies is the `[weak target]` capture
    /// below going nil: every remaining call in an already-captured segment still runs, but finds
    /// `target` nil and does nothing.
    ///
    /// Built from `session_metadata` payloads deliberately, not the usual streaming series: those are
    /// screen-content reasons that coalesce on apply, so a burst of them collapses to at most a handful
    /// of applies regardless of teardown, proving nothing about release. `session_metadata` is a
    /// barrier reason (see `sessionMetadataPayload`): every payload queues its own apply.
    ///
    /// The series is short and `applyDelay` deliberately large: reduction has no meaningful cost for
    /// this reason, so a burst can land in the mailbox as a single segment before the first drain even
    /// runs, and from then on `applyDelay` is the only thing pacing how many entries actually apply
    /// before this test releases the target. `drain()`'s loop over that segment is tight and
    /// synchronous, so the entry right after the one that fulfills `firstApply` almost always has its
    /// `target?` already evaluated as non-nil before this test's `await fulfillment` even resumes on
    /// its own thread — one further apply beyond the first is normal and this test waits for it to
    /// finish, rather than racing to sample the count before it lands. A short `applyDelay` (as this
    /// test used to use) shrinks that already-tight window further, so under scheduling jitter (worse
    /// under parallel test load) more than one extra entry could start before release ever lands, up to
    /// the whole segment in the worst case — which is what made this test flake; a delay measured in
    /// hundreds of milliseconds keeps that a non-issue on any machine this test plausibly runs on.
    func testReleasingThePipelineStopsApplyingQueuedPayloads() async throws {
        let applyDelay = 0.3
        let series = (0..<5).map { sessionMetadataPayload(sessionID: "pipeline-teardown", sequence: $0) }
        let collector = OutputCollector()
        let firstApply = expectation(description: "first payload applied")
        firstApply.assertForOverFulfill = false
        var target: ApplyTarget? = ApplyTarget(collector: collector, applyDelay: applyDelay)
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
        // Give the one apply that is almost certainly already in flight (see the doc comment above)
        // a full `applyDelay` of headroom to finish before sampling, so the sample below reflects a
        // settled count rather than racing an apply that simply had not returned yet.
        try await Task.sleep(for: .seconds(applyDelay * 3))
        let appliedAfterRelease = collector.recorded.count
        try await Task.sleep(for: .milliseconds(300))

        XCTAssertEqual(collector.recorded.count, appliedAfterRelease, "the pipeline applied a payload after its owner was released")
        XCTAssertLessThan(appliedAfterRelease, series.count, "an apply ran against a released target instead of finding it nil")
        XCTAssertNil(weakPipeline, "the consumer task outlived the pipeline")
        XCTAssertNil(weakTarget, "the pipeline held its apply target strongly")
    }

    // MARK: - Off-screen panes hold their screen updates

    /// A pane that is off screen applies no screen updates while it is there, and what it repaints from
    /// when it comes back is the session's CURRENT screen: the reduction never stopped, so the one
    /// output it held is a materialized full frame of the newest state, not the picture the pane left on.
    func testHeldScreenUpdatesApplyAsOneCurrentFrameWhenThePaneStopsHolding() async throws {
        let series = try streamingSeries(sessionID: "pipeline-held", frameCount: 30, fetchIndex: 400, clipboardIndex: 400)
        let collector = OutputCollector()
        let target = ApplyTarget(collector: collector)
        let probe = SubmitProbe()
        let pipeline = TerminalRemoteStateReductionPipeline(
            shouldUseFrame: { _, _ in true }, apply: { [weak target] output in target?.apply(output) },
            didSubmitForTesting: { probe.recordSubmission() })

        // The pane is on screen for the first frame: a pane holds nothing until it has something to show.
        pipeline.submit(series[0].payload)
        try await waitUntil("the displayed pane applied its first frame") { collector.recorded.count == 1 }

        pipeline.setHoldsScreenUpdates(true)
        for entry in series.dropFirst() { pipeline.submit(entry.payload) }
        try await waitUntil("every payload reduced") { probe.submissions == series.count }
        try await settle()
        XCTAssertEqual(collector.recorded.count, 1, "an off-screen pane applied a screen update")

        pipeline.setHoldsScreenUpdates(false)
        try await waitUntil("the pane repainted when it came back") { collector.recorded.count == 2 }
        try await settle()
        let outputs = collector.recorded
        XCTAssertEqual(outputs.count, 2, "the held run applied as more than one frame")
        XCTAssertEqual(outputs[1].frameText, "frame-\(series.count - 1)", "the pane repainted an older screen than the session's current one")
        XCTAssertEqual(outputs[1].coalescedAwayCount, series.count - 2, "the held run did not collapse into one apply")
        XCTAssertNil(outputs[1].dropReason, "every delta still reduced in order while the pane was off screen")
        XCTAssertFalse(outputs[1].requestsResync, "the chain stayed intact, so nothing had to be re-fetched from the device")
    }

    /// Everything that is not just a newer picture still applies as it arrives while the pane is off
    /// screen: that is what keeps an unselected tab's title, ownership, runtime state and ended state
    /// current. The screen it was holding applies with it, in order, and holding resumes afterwards.
    func testHeldPaneAppliesStateTransitionsAsTheyArrive() async throws {
        let sessionID = "pipeline-held-barrier"
        let series = try streamingSeries(sessionID: sessionID, frameCount: 6, fetchIndex: 400, clipboardIndex: 400)
        let collector = OutputCollector()
        let target = ApplyTarget(collector: collector)
        let probe = SubmitProbe()
        let pipeline = TerminalRemoteStateReductionPipeline(
            shouldUseFrame: { _, _ in true }, apply: { [weak target] output in target?.apply(output) },
            didSubmitForTesting: { probe.recordSubmission() })

        pipeline.submit(series[0].payload)
        try await waitUntil("the displayed pane applied its first frame") { collector.recorded.count == 1 }

        pipeline.setHoldsScreenUpdates(true)
        for entry in series.dropFirst(1).prefix(3) { pipeline.submit(entry.payload) }
        try await waitUntil("the screen updates reduced") { probe.submissions == 4 }
        try await settle()
        XCTAssertEqual(collector.recorded.count, 1)

        pipeline.submit(sessionMetadataPayload(sessionID: sessionID, sequence: series.count))
        try await waitUntil("the title change applied") { collector.recorded.count == 3 }
        try await settle()
        XCTAssertEqual(
            collector.recorded.map(\.reason),
            [TerminalRemoteSessionStateReason.output, TerminalRemoteSessionStateReason.output, TerminalRemoteSessionStateReason.sessionMetadata],
            "the held screen must apply before the transition that followed it, and both exactly once")
        XCTAssertEqual(collector.recorded[1].frameText, "frame-3", "the transition dragged in an older frame than the one being held")

        // The barrier's drain must not leave the pane applying at output cadence again.
        for entry in series.dropFirst(4) { pipeline.submit(entry.payload) }
        try await waitUntil("the rest of the series reduced") { probe.submissions == series.count + 1 }
        try await settle()
        XCTAssertEqual(collector.recorded.count, 3, "the pane resumed applying screen updates while still off screen")
    }

    /// A screen update whose delta could not reduce applies even while the pane is off screen: its
    /// resync request is the only thing that makes the device re-send a full frame, and holding it would
    /// leave every later delta failing against a baseline nothing repairs.
    func testHeldPaneAppliesAScreenUpdateThatRequestsAResync() async throws {
        let sessionID = "pipeline-held-resync"
        let collector = OutputCollector()
        let target = ApplyTarget(collector: collector)
        let pipeline = TerminalRemoteStateReductionPipeline(
            shouldUseFrame: { _, _ in true }, apply: { [weak target] output in target?.apply(output) })

        let frame = GhosttyRenderFrame(sessionRevision: 1, ownerEpoch: 4, snapshot: snapshot(text: "frame-0"))
        pipeline.submit(payload(sessionID: sessionID, sequence: 0, reason: TerminalRemoteSessionStateReason.output, update: .full(frame)))
        try await waitUntil("the displayed pane applied its first frame") { collector.recorded.count == 1 }

        pipeline.setHoldsScreenUpdates(true)
        pipeline.submit(corruptPayload(sessionID: sessionID, sequence: 1))
        try await waitUntil("the failed reduction applied") { collector.recorded.count == 2 }
        XCTAssertTrue(collector.recorded[1].requestsResync, "the off-screen pane swallowed the request that repairs its chain")
    }

    /// A remote owner (the phone, say) driving a session whose Mac pane is off screen alternates
    /// frameless `input` payloads with frame-carrying output. `ApplyMailbox.mayCollapse` on its own
    /// cannot fold a frameless output onto a frame-carrying entry, so every cycle would append one more
    /// materialized full frame to the held queue: unbounded while the pane stays away, and a redisplay
    /// that walks every stale frame instead of painting the current one. Holding folds the tail in both
    /// directions instead, since neither entry is going to be applied until the pane returns, so what
    /// waits is one entry carrying the newest frame and the merged effects of everything folded into it.
    func testAlternatingInputAndOutputHoldsAsOneEntryWhileThePaneIsOffScreen() async throws {
        let sessionID = "pipeline-held-input-cycles"
        let collector = OutputCollector()
        let target = ApplyTarget(collector: collector)
        let probe = SubmitProbe()
        let pipeline = TerminalRemoteStateReductionPipeline(
            shouldUseFrame: { _, _ in true }, apply: { [weak target] output in target?.apply(output) },
            didSubmitForTesting: { probe.recordSubmission() })

        let first = GhosttyRenderFrame(sessionRevision: 1, ownerEpoch: 4, snapshot: snapshot(text: "frame-0"))
        pipeline.submit(payload(sessionID: sessionID, sequence: 0, reason: TerminalRemoteSessionStateReason.output, update: .full(first)))
        try await waitUntil("the displayed pane applied its first frame") { collector.recorded.count == 1 }

        pipeline.setHoldsScreenUpdates(true)
        let cycles = 6
        var sequence = 1
        for cycle in 1...cycles {
            pipeline.submit(inputPayload(sessionID: sessionID, sequence: sequence))
            sequence += 1
            let frame = GhosttyRenderFrame(sessionRevision: UInt64(cycle + 1), ownerEpoch: 4, snapshot: snapshot(text: "frame-\(cycle)"))
            pipeline.submit(payload(sessionID: sessionID, sequence: sequence, reason: TerminalRemoteSessionStateReason.output, update: .full(frame)))
            sequence += 1
        }
        // A trailing keystroke, so the surviving entry is the frameless one: the fold has to keep the
        // newest frame under it rather than leaving the pane nothing to repaint from.
        pipeline.submit(inputPayload(sessionID: sessionID, sequence: sequence))
        sequence += 1
        let expectedSubmissions = sequence
        try await waitUntil("every payload reduced") { probe.submissions == expectedSubmissions }
        try await settle()
        XCTAssertEqual(collector.recorded.count, 1, "an off-screen pane applied a screen update")

        pipeline.setHoldsScreenUpdates(false)
        try await waitUntil("the pane repainted when it came back") { collector.recorded.count == 2 }
        try await settle()
        let outputs = collector.recorded
        XCTAssertEqual(outputs.count, 2, "the held input/output cycles applied as more than one entry")
        XCTAssertEqual(outputs[1].reason, TerminalRemoteSessionStateReason.input, "the newest held payload must survive the fold")
        XCTAssertEqual(outputs[1].frameText, "frame-\(cycles)", "the fold dropped the newest frame")
        XCTAssertEqual(outputs[1].coalescedAwayCount, cycles * 2, "the held cycles did not fold into a single entry")
        XCTAssertFalse(outputs[1].requestsResync, "the chain stayed intact, so nothing had to be re-fetched from the device")
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
    // MARK: - Accessor equivalence

    /// Everything a client reads off a reduced payload, as one comparable value.
    private struct PayloadReads: Equatable {
        let hasRenderUpdate: Bool
        let renderUpdate: Data?
        let decodedRenderUpdate: GhosttyRenderUpdate?
        let renderSnapshot: GhosttyTerminalSnapshot?
        let renderText: String?
        let renderOwnerEpoch: UInt64?

        init(_ payload: GhosttyRemoteSessionStatePayload) {
            hasRenderUpdate = payload.hasRenderUpdate
            renderUpdate = payload.renderUpdate
            decodedRenderUpdate = payload.decodedRenderUpdate
            renderSnapshot = payload.renderSnapshot
            renderText = payload.renderText
            renderOwnerEpoch = payload.renderOwnerEpoch
        }
    }

    private struct ReductionReads: Equatable {
        let payload: PayloadReads
        let storedPayload: PayloadReads
        let frameToApply: GhosttyRenderFrame?
        let dropReason: String?
        let didRequestResync: Bool

        init(_ reduction: TerminalRemoteStateReductionResult) {
            payload = PayloadReads(reduction.payload)
            storedPayload = PayloadReads(reduction.storedPayload)
            frameToApply = reduction.frameToApply
            dropReason = reduction.dropReason
            didRequestResync = reduction.didRequestResync
        }
    }

    /// The reduction the payload's render update carried as an eagerly re-encoded blob: apply the
    /// incoming update to the baseline, serialize the materialized full frame, and store *that* on the
    /// payload. This is the behavior the payload's lazily encoded body has to reproduce read for read,
    /// blob for blob, so it is spelled out here rather than trusted to the type under test.
    private struct EagerlyEncodingReducer {
        private var baseline: GhosttyRenderUpdateBaseline?

        mutating func reduce(incomingPayload: GhosttyRemoteSessionStatePayload, previousPayload: GhosttyRemoteSessionStatePayload?)
            -> TerminalRemoteStateReductionResult
        {
            let resolved = resolve(incomingPayload)
            var dropReason = resolved.dropReason
            if resolved.frame == nil, incomingPayload.renderUpdate != nil { dropReason = dropReason ?? "decode_failed" }
            return TerminalRemoteStateReductionResult(
                payload: resolved.payload, storedPayload: previousPayload?.merged(with: resolved.payload) ?? resolved.payload,
                decodedUpdate: resolved.decodedUpdate, frameToApply: resolved.frame, dropReason: dropReason,
                didRequestResync: resolved.dropReason != nil)
        }

        private mutating func resolve(_ payload: GhosttyRemoteSessionStatePayload) -> (
            payload: GhosttyRemoteSessionStatePayload, decodedUpdate: GhosttyRenderUpdate?, frame: GhosttyRenderFrame?, dropReason: String?
        ) {
            guard payload.renderUpdate != nil else { return (payload, nil, nil, nil) }
            guard let decodedUpdate = payload.decodedRenderUpdate else {
                return (payload.replacingRenderUpdate(nil), nil, nil, "render_update_decode_failed")
            }
            do {
                let applied = try GhosttyRenderUpdateApplier.apply(decodedUpdate, to: baseline)
                baseline = applied
                // Mirrors the reducer's split: the frame handed to the live apply keeps a delta's scroll
                // rects for the mirror's drag carry, while the frame stored (and here eagerly encoded)
                // on the payload is poisoned — a full frame encodes no rect fields on the wire, and a
                // replayed stored payload must poison a mirror's carry.
                let scrollRects: [GhosttyRenderScrollRectOperation]
                let scrollRectsOverflowed: Bool
                switch decodedUpdate.kind {
                case .delta:
                    scrollRects = decodedUpdate.delta?.scrollRects ?? []
                    scrollRectsOverflowed = decodedUpdate.delta?.scrollRectsOverflowed ?? true
                case .full, .resyncRequired:
                    scrollRects = []
                    scrollRectsOverflowed = true
                }
                let frame = GhosttyRenderFrame(
                    sessionRevision: applied.sessionRevision, ownerEpoch: applied.ownerEpoch, snapshot: applied.snapshot,
                    scrollRects: scrollRects, scrollRectsOverflowed: scrollRectsOverflowed)
                let storedFrame = GhosttyRenderFrame(sessionRevision: applied.sessionRevision, ownerEpoch: applied.ownerEpoch, snapshot: applied.snapshot)
                guard let encoded = try? GhosttyRenderUpdateBinaryCodec.encode(.full(storedFrame)) else {
                    return (payload.replacingRenderUpdate(nil), decodedUpdate, nil, nil)
                }
                return (payload.replacingRenderUpdate(encoded), decodedUpdate, frame, nil)
            } catch {
                baseline = nil
                return (payload.replacingRenderUpdate(nil), decodedUpdate, nil, TerminalRemoteStateReducer.renderUpdateDropReason(for: error))
            }
        }
    }

    private func eagerlyEncodedReads(for series: [(payload: GhosttyRemoteSessionStatePayload, isDirectFetch: Bool)]) -> [ReductionReads?] {
        var reducer = EagerlyEncodingReducer()
        var previousPayload: GhosttyRemoteSessionStatePayload?
        return series.map { entry in
            guard entry.payload.reason != TerminalRemoteSessionStateReason.clipboardWrite else { return nil }
            let reduction = reducer.reduce(incomingPayload: entry.payload, previousPayload: previousPayload)
            previousPayload = reduction.storedPayload
            return ReductionReads(reduction)
        }
    }

    private func reads(for series: [(payload: GhosttyRemoteSessionStatePayload, isDirectFetch: Bool)]) -> [ReductionReads?] {
        var reducer = TerminalRemoteStateReducer()
        var previousPayload: GhosttyRemoteSessionStatePayload?
        return series.map { entry in
            guard entry.payload.reason != TerminalRemoteSessionStateReason.clipboardWrite else { return nil }
            let reduction = reducer.reduce(incomingPayload: entry.payload, previousPayload: previousPayload, requestResyncOnApplyFailure: true)
            previousPayload = reduction.storedPayload
            return ReductionReads(reduction)
        }
    }

    /// A reduced payload reads the same whether its render update is a materialized value or the blob a
    /// re-encode produced, across a whole delta chain with a direct `.state` fetch and a clipboard write
    /// interleaved: same bytes, same decoded update, same grid, same text, same owner epoch.
    func testReducedPayloadReadsMatchTheEagerlyEncodedChain() throws {
        let series = try streamingSeries(sessionID: "accessor-equivalence", frameCount: 24, fetchIndex: 9, clipboardIndex: 5)

        let actual = reads(for: series)
        XCTAssertEqual(actual, eagerlyEncodedReads(for: series))
        XCTAssertTrue(
            actual.compactMap { $0 }.allSatisfy { $0.storedPayload.renderUpdate != nil },
            "every reduced payload in a clean chain must still yield wire bytes on demand")
    }

    /// The same equivalence where the chain breaks: a delta that cannot apply clears the render update
    /// on its own payload while the stored payload carries the last good screen forward, and the resync
    /// full frame re-seeds both. Those are the reads a resync round trip is decided on.
    func testReducedPayloadReadsMatchTheEagerlyEncodedChainAcrossAResync() throws {
        let first = GhosttyRenderFrame(sessionRevision: 1, ownerEpoch: 4, snapshot: snapshot(text: "alpha"))
        let second = GhosttyRenderFrame(sessionRevision: 2, ownerEpoch: 4, snapshot: snapshot(text: "bravo"))
        let third = GhosttyRenderFrame(sessionRevision: 3, ownerEpoch: 4, snapshot: snapshot(text: "charl"))
        let firstToSecond = GhosttyRenderUpdateFactory.makeUpdate(target: second, baseline: GhosttyRenderUpdateBaseline(frame: first))
        let secondToThird = GhosttyRenderUpdateFactory.makeUpdate(target: third, baseline: GhosttyRenderUpdateBaseline(frame: second))
        let fourth = GhosttyRenderFrame(sessionRevision: 4, ownerEpoch: 4, snapshot: snapshot(text: "delta"))
        let thirdToFourth = GhosttyRenderUpdateFactory.makeUpdate(target: fourth, baseline: GhosttyRenderUpdateBaseline(frame: third))

        let sessionID = "accessor-equivalence-resync"
        let series: [(payload: GhosttyRemoteSessionStatePayload, isDirectFetch: Bool)] = [
            (payload(sessionID: sessionID, sequence: 0, reason: TerminalRemoteSessionStateReason.output, update: .full(first)), false),
            (payload(sessionID: sessionID, sequence: 1, reason: TerminalRemoteSessionStateReason.output, update: secondToThird), false),
            (payload(sessionID: sessionID, sequence: 2, reason: TerminalRemoteSessionStateReason.output, update: firstToSecond), false),
            (corruptPayload(sessionID: sessionID, sequence: 3), false),
            (payload(sessionID: sessionID, sequence: 4, reason: TerminalRemoteSessionStateReason.stateChange, update: .full(third)), true),
            (payload(sessionID: sessionID, sequence: 5, reason: TerminalRemoteSessionStateReason.output, update: thirdToFourth), false),
        ]

        let actual = reads(for: series)
        XCTAssertEqual(actual, eagerlyEncodedReads(for: series))
        XCTAssertEqual(actual.map { $0?.dropReason }, [nil, "base_revision_mismatch", "missing_baseline", "render_update_decode_failed", nil, nil])
        // A payload whose update dropped carries no update of its own, while the stored payload keeps the
        // last screen that did apply, which is what a client renders until the resync lands.
        XCTAssertEqual(actual.map { $0?.payload.hasRenderUpdate }, [true, false, false, false, true, true])
        XCTAssertEqual(actual.map { $0?.storedPayload.renderText?.prefix(5) }, ["alpha", "alpha", "alpha", "alpha", "charl", "delta"])
    }

    /// A reduced payload is still a wire payload: serializing it produces the same JSON, under the same
    /// key, that a payload holding the blob produced, and the round trip reads back identically.
    func testReducedPayloadSerializesToTheSameWireBytes() throws {
        let series = try streamingSeries(sessionID: "accessor-wire", frameCount: 6, fetchIndex: 3, clipboardIndex: 400)
        var reducer = TerminalRemoteStateReducer()
        var previousPayload: GhosttyRemoteSessionStatePayload?
        for entry in series {
            let reduction = reducer.reduce(incomingPayload: entry.payload, previousPayload: previousPayload, requestResyncOnApplyFailure: true)
            previousPayload = reduction.storedPayload

            let line = try GhosttyRemoteSessionStateCodec.encodeLine(reduction.storedPayload)
            XCTAssertTrue(
                String(decoding: line, as: UTF8.self).contains("\"renderUpdate\":\""), "the wire shape names the render update under renderUpdate")
            let decoded = try GhosttyRemoteSessionStateCodec.decodeLine(line)
            XCTAssertEqual(PayloadReads(decoded), PayloadReads(reduction.storedPayload))
            XCTAssertEqual(decoded, reduction.storedPayload)
        }
    }

    // MARK: - Payload construction

    private func payload(sessionID: String, sequence: Int, reason: String, update: GhosttyRenderUpdate) -> GhosttyRemoteSessionStatePayload {
        GhosttyRemoteSessionStatePayload(
            sessionID: sessionID, reason: reason, emittedAt: emittedAt(sequence), sessionStateRevision: UInt64(sequence + 1), sessionStateFlags: 1,
            screenStateRevision: UInt64(sequence + 1), runtimeState: nil, attachmentSnapshot: nil, title: "live", workingDirectory: "/tmp/live",
            outputByteCount: nil, renderUpdate: try? GhosttyRenderUpdateBinaryCodec.encode(update))
    }

    private func corruptPayload(sessionID: String, sequence: Int) -> GhosttyRemoteSessionStatePayload {
        GhosttyRemoteSessionStatePayload(
            sessionID: sessionID, reason: TerminalRemoteSessionStateReason.output, emittedAt: emittedAt(sequence),
            sessionStateRevision: UInt64(sequence + 1), sessionStateFlags: 1, screenStateRevision: UInt64(sequence + 1), runtimeState: nil,
            attachmentSnapshot: nil, title: "live", workingDirectory: "/tmp/live", outputByteCount: nil, renderUpdate: Data([0x00, 0x01, 0x02, 0x03]))
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
