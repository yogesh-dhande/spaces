import Foundation
import XCTest
import spacesterminalcore

/// The pipeline's contract: every payload submitted, from whichever entry point, is reduced exactly
/// once and applied in submission order, so the render-update delta chain the reducer maintains sees
/// the same series it saw when the reduction ran inline on the main actor.
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
                didReduce: output.reduction != nil)
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

    func testPipelineAppliesEveryPayloadInSubmissionOrderAcrossBothEntryPoints() async throws {
        let series = try streamingSeries(sessionID: "pipeline-order", frameCount: 24, fetchIndex: 9, clipboardIndex: 5)
        let expected = synchronousOutputs(for: series)
        XCTAssertTrue(expected.allSatisfy { $0.dropReason == nil }, "the reference series must reduce cleanly in order")

        let collector = OutputCollector()
        let target = ApplyTarget(collector: collector)
        let applied = expectation(description: "every payload applied")
        applied.expectedFulfillmentCount = series.count
        let pipeline = TerminalRemoteStateReductionPipeline(
            shouldUseFrame: { _, _ in true },
            apply: { [weak target] output in
                target?.apply(output)
                applied.fulfill()
            })

        // The subscription's payloads arrive on the stream's own thread and the direct fetch's on the
        // main actor; FIFO has to hold across both, so the test submits from both.
        let streamQueue = DispatchQueue(label: "spaces.test.remote-state-stream")
        for entry in series {
            if entry.isDirectFetch {
                await MainActor.run { pipeline.submit(entry.payload) }
            } else {
                streamQueue.sync { pipeline.submit(entry.payload) }
            }
        }

        await fulfillment(of: [applied], timeout: 20)
        XCTAssertEqual(collector.recorded, expected)
        XCTAssertEqual(collector.recorded.filter { !$0.didReduce }.map(\.reason), [TerminalRemoteSessionStateReason.clipboardWrite])
    }

    /// A delta that cannot apply resets the baseline inside the reducer. The reset belongs to its place
    /// in the series: the payloads after it must see the cleared baseline, and the full frame that
    /// follows must re-seed it, all without any of them overtaking the others.
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
        let applied = expectation(description: "every payload applied")
        applied.expectedFulfillmentCount = series.count
        let pipeline = TerminalRemoteStateReductionPipeline(
            shouldUseFrame: { _, _ in true },
            apply: { [weak target] output in
                target?.apply(output)
                applied.fulfill()
            })
        for entry in series { pipeline.submit(entry.payload) }
        await fulfillment(of: [applied], timeout: 20)

        XCTAssertEqual(collector.recorded, synchronousOutputs(for: series))
        XCTAssertEqual(collector.recorded.map(\.dropReason), [nil, "base_revision_mismatch", "missing_baseline", nil])
        XCTAssertEqual(collector.recorded.map(\.didRequestResync), [false, true, true, false])
        XCTAssertEqual(collector.recorded.map(\.frameText), ["alpha", nil, nil, "charl"])
    }

    /// Teardown: the pipeline goes away with its owner. Whatever was still queued is dropped rather
    /// than reduced for an owner that no longer exists, and nothing is applied to the released target.
    func testReleasingThePipelineStopsApplyingQueuedPayloads() async throws {
        let series = try streamingSeries(sessionID: "pipeline-teardown", frameCount: 200, fetchIndex: 400, clipboardIndex: 400)
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

        for entry in series { pipeline?.submit(entry.payload) }
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
