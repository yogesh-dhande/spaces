import Foundation
import Testing

@testable import spacesterminalcore

/// The full-vs-delta policy both session hosts run. Pinned here once, so the macOS host and the Linux
/// headless core cannot drift apart on what forces a self-contained frame. Written in Swift Testing and
/// listed in `run_linux_tests.sh` so the Linux lane pins the same policy the macOS lane does.
struct GhosttyRenderUpdateProducerTests {
    @Test func onlyResyncReasonsForceAFullStreamFrame() {
        let producer = GhosttyRenderUpdateProducer()
        let forcedFullReasons = Set(
            TerminalRemoteSessionStateReason.allCases.filter {
                producer.forcedFullReason(for: $0, exportMode: .streamDeltaAllowed) != nil
            })

        #expect(forcedFullReasons == [.initial, .resize, .terminated])
        #expect(producer.forcedFullReason(for: .initial, exportMode: .streamDeltaAllowed) == "initial_baseline")
        #expect(producer.forcedFullReason(for: .resize, exportMode: .streamDeltaAllowed) == "resize_self_contained")
        #expect(producer.forcedFullReason(for: .terminated, exportMode: .streamDeltaAllowed) == "explicit_resync")
        #expect(producer.forcedFullReason(for: nil, exportMode: .streamDeltaAllowed) == nil)
    }

    @Test func everyOneShotReadIsSelfContained() {
        let producer = GhosttyRenderUpdateProducer()
        for reason in TerminalRemoteSessionStateReason.allCases where reason != .initial && reason != .resize && reason != .terminated {
            #expect(
                producer.forcedFullReason(for: reason, exportMode: .selfContained) == "self_contained_state_export",
                "a one-shot read of \(reason.rawValue) has no stream baseline to diff against")
        }
    }

    @Test func aPendingSubscriberBaselineResetForcesAFullFrameOnEveryReasonButScroll() {
        var producer = GhosttyRenderUpdateProducer()
        producer.armSubscriberBaselineReset()

        #expect(producer.forcedFullReason(for: .output, exportMode: .streamDeltaAllowed) == "subscriber_baseline_reset")
        #expect(producer.forcedFullReason(for: .stateChange, exportMode: .streamDeltaAllowed) == "subscriber_baseline_reset")
        #expect(producer.forcedFullReason(for: .scroll, exportMode: .streamDeltaAllowed) == nil)
    }

    /// The arm is a promise to a subscriber holding no baseline, and only a full frame keeps it. A scroll
    /// delta in between reaches that subscriber as something it can only drop, so the promise must survive
    /// it and be spent on the next frame that actually stands alone.
    @Test func theSubscriberBaselinePromiseSurvivesAScrollAndIsSpentOnTheFullFrameItDelivers() {
        var producer = GhosttyRenderUpdateProducer()
        _ = producer.makeUpdate(for: frame(lines: ["one"], revision: 1), reason: .initial, exportMode: .streamDeltaAllowed)
        producer.armSubscriberBaselineReset()

        let scrollUpdate = producer.makeUpdate(for: frame(lines: ["two"], revision: 2), reason: .scroll, exportMode: .streamDeltaAllowed)
        #expect(scrollUpdate.kind == .delta)

        let outputUpdate = producer.makeUpdate(for: frame(lines: ["six"], revision: 3), reason: .output, exportMode: .streamDeltaAllowed)
        #expect(outputUpdate.kind == .full)
        #expect(outputUpdate.fallbackReason == "subscriber_baseline_reset")

        let nextUpdate = producer.makeUpdate(for: frame(lines: ["ten"], revision: 4), reason: .output, exportMode: .streamDeltaAllowed)
        #expect(nextUpdate.kind == .delta)
    }

    /// A frame the baseline already describes is still a delta, an empty one. Forcing a full grid here is
    /// what made every no-op scroll step and every local-echo resync cost a whole viewport.
    @Test func aFrameMatchingTheBaselineShipsAnEmptyDeltaRatherThanAFullGrid() {
        var producer = GhosttyRenderUpdateProducer()
        _ = producer.makeUpdate(for: frame(lines: ["one"], revision: 1), reason: .initial, exportMode: .streamDeltaAllowed)

        let unchanged = frame(lines: ["one"], revision: 1)
        let update = producer.makeUpdate(for: unchanged, reason: .scroll, exportMode: .streamDeltaAllowed)
        #expect(update.kind == .delta)
        #expect(update.changedCellCount == 0)
    }

    /// A one-shot read must not move the stream's baseline: nobody applied the frame it returned.
    @Test func onlyAStreamExportAdvancesTheBaseline() {
        var producer = GhosttyRenderUpdateProducer()
        _ = producer.makeUpdate(for: frame(lines: ["one"], revision: 1), reason: .initial, exportMode: .streamDeltaAllowed)
        _ = producer.makeUpdate(for: frame(lines: ["two"], revision: 2), reason: .output, exportMode: .selfContained)

        #expect(producer.baseline?.sessionRevision == 1)
        let update = producer.makeUpdate(for: frame(lines: ["two"], revision: 2), reason: .output, exportMode: .streamDeltaAllowed)
        #expect(update.kind == .delta)
        #expect(update.baseRevision == 1)
        #expect(producer.baseline?.sessionRevision == 2)
    }

    /// A one-shot read drains Ghostty's pending scroll rects and cannot ship them (it forces a full frame,
    /// and a full frame carries none), so the next stream delta must still report that movement.
    @Test func aOneShotReadCarriesItsDrainedScrollRectsIntoTheNextStreamDelta() {
        var producer = GhosttyRenderUpdateProducer()
        _ = producer.makeUpdate(for: frame(lines: ["one", "two"], revision: 1), reason: .initial, exportMode: .streamDeltaAllowed)
        let rect = GhosttyRenderScrollRectOperation(rowStart: 0, rowCount: 2, columnStart: 0, columnCount: 3, deltaRows: 1, deltaColumns: 0)
        _ = producer.makeUpdate(
            for: frame(lines: ["one", "two"], revision: 1), reason: .output, nativeScrollRects: [rect], exportMode: .selfContained)

        let update = producer.makeUpdate(for: frame(lines: ["xxx", "one"], revision: 2), reason: .output, exportMode: .streamDeltaAllowed)
        #expect(update.delta?.scrollRects == [rect])
    }

    private func frame(lines: [String], revision: UInt64, ownerEpoch: UInt64 = 1) -> GhosttyRenderFrame {
        GhosttyRenderFrame(sessionRevision: revision, ownerEpoch: ownerEpoch, snapshot: makeSnapshot(lines: lines))
    }

    private func makeSnapshot(lines: [String]) -> GhosttyTerminalSnapshot {
        let columns = lines.map(\.count).max() ?? 1
        let padded = lines.map { $0 + String(repeating: " ", count: columns - $0.count) }
        let cells = padded.flatMap { line in
            line.unicodeScalars.map {
                GhosttyTerminalSnapshot.Cell(codepoint: $0.value, foregroundRGB: 0xFFFFFF, backgroundRGB: 0, flags: 0)
            }
        }
        return GhosttyTerminalSnapshot(
            columns: columns, rows: padded.count, cursorColumn: 0, cursorRow: 0, cursorVisible: false, defaultForegroundRGB: 0xFFFFFF,
            defaultBackgroundRGB: 0, cells: cells)
    }
}
