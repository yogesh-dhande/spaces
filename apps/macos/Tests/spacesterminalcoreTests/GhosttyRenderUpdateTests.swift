import XCTest

@testable import spacesterminalcore

final class GhosttyRenderUpdateTests: XCTestCase {
    func testFullRenderUpdateBinaryRoundTrips() throws {
        let snapshot = makeSnapshot(lines: ["hello", "world"])
        let frame = GhosttyRenderFrame(sessionRevision: 4, ownerEpoch: 9, snapshot: snapshot)
        let update = GhosttyRenderUpdate.full(frame)

        let decoded = try GhosttyRenderUpdateBinaryCodec.decode(try GhosttyRenderUpdateBinaryCodec.encode(update))

        XCTAssertEqual(decoded, update)
        XCTAssertEqual(decoded.fullFrame?.snapshot, snapshot)
    }

    func testCellRunDeltaRoundTripsAndApplies() throws {
        let previous = makeSnapshot(lines: ["hello"])
        let target = makeSnapshot(lines: ["hullo"])
        let frame = GhosttyRenderFrame(sessionRevision: 2, ownerEpoch: 1, snapshot: target)
        let baseline = GhosttyRenderUpdateBaseline(snapshot: previous, sessionRevision: 1, ownerEpoch: 1)
        let update = GhosttyRenderUpdateFactory.makeUpdate(target: frame, baseline: baseline, mode: .delta)

        let decoded = try GhosttyRenderUpdateBinaryCodec.decode(try GhosttyRenderUpdateBinaryCodec.encode(update))
        let applied = try GhosttyRenderUpdateApplier.apply(decoded, to: baseline)

        XCTAssertEqual(decoded.kind, .delta)
        XCTAssertEqual(decoded.delta?.replaceCellRuns.count, 1)
        XCTAssertEqual(decoded.delta?.changedCellCount, 1)
        XCTAssertEqual(applied.snapshot, target)
        XCTAssertEqual(applied.sessionRevision, 2)
    }

    func testAppendedOutputDeltaUsesScrollRectAndBottomRowReplacement() throws {
        let previous = makeSnapshot(lines: ["one ", "two ", "tre "])
        let target = makeSnapshot(lines: ["two ", "tre ", "for "])
        let frame = GhosttyRenderFrame(sessionRevision: 12, ownerEpoch: 5, snapshot: target)
        let baseline = GhosttyRenderUpdateBaseline(snapshot: previous, sessionRevision: 11, ownerEpoch: 5)

        let update = GhosttyRenderUpdateFactory.makeUpdate(target: frame, baseline: baseline, mode: .delta)
        let delta = try XCTUnwrap(update.delta)
        let scroll = try XCTUnwrap(delta.scrollRects.first)
        let applied = try GhosttyRenderUpdateApplier.apply(update, to: baseline)

        XCTAssertEqual(update.kind, .delta)
        XCTAssertEqual(delta.scrollRects.count, 1)
        XCTAssertEqual(scroll.rowStart, 0)
        XCTAssertEqual(scroll.rowCount, 3)
        XCTAssertEqual(scroll.columnStart, 0)
        XCTAssertEqual(scroll.columnCount, 4)
        XCTAssertEqual(scroll.deltaRows, -1)
        XCTAssertEqual(scroll.deltaColumns, 0)
        XCTAssertEqual(delta.replaceCellRuns.map(\.row), [2])
        XCTAssertEqual(applied.snapshot, target)
    }

    func testDeltaRejectsBaseRevisionMismatch() throws {
        let previous = makeSnapshot(lines: ["abc"])
        let target = makeSnapshot(lines: ["abd"])
        let frame = GhosttyRenderFrame(sessionRevision: 2, ownerEpoch: 1, snapshot: target)
        let baseline = GhosttyRenderUpdateBaseline(snapshot: previous, sessionRevision: 1, ownerEpoch: 1)
        let update = GhosttyRenderUpdateFactory.makeUpdate(target: frame, baseline: baseline, mode: .delta)
        let staleBaseline = GhosttyRenderUpdateBaseline(snapshot: previous, sessionRevision: 0, ownerEpoch: 1)

        XCTAssertThrowsError(try GhosttyRenderUpdateApplier.apply(update, to: staleBaseline)) { error in
            XCTAssertEqual(error as? GhosttyRenderUpdateApplyError, .baseRevisionMismatch(expected: 1, actual: 0))
        }
    }

    func testAutoFallsBackToFullWhenBaselineIsUnsafe() {
        let previous = makeSnapshot(lines: ["abc"])
        let target = makeSnapshot(lines: ["abc", "def"])
        let frame = GhosttyRenderFrame(sessionRevision: 2, ownerEpoch: 1, snapshot: target)
        let baseline = GhosttyRenderUpdateBaseline(snapshot: previous, sessionRevision: 1, ownerEpoch: 1)

        let update = GhosttyRenderUpdateFactory.makeUpdate(target: frame, baseline: baseline, mode: .auto)

        XCTAssertEqual(update.kind, .full)
        XCTAssertEqual(update.fallbackReason, "baseline_mismatch")
        XCTAssertEqual(update.fullFrame?.snapshot, target)
    }

    private func makeSnapshot(lines: [String]) -> GhosttyTerminalSnapshot {
        let columns = lines.map(\.count).max() ?? 1
        let rows = max(lines.count, 1)
        let paddedLines =
            lines.isEmpty ? [String(repeating: " ", count: columns)] : lines.map { $0.padding(toLength: columns, withPad: " ", startingAt: 0) }
        let cells = paddedLines.flatMap { line in
            line.unicodeScalars.map { GhosttyTerminalSnapshot.Cell(codepoint: $0.value, foregroundRGB: 0xEEEEEE, backgroundRGB: 0x101010, flags: 0) }
        }
        return GhosttyTerminalSnapshot(
            columns: columns, rows: rows, cursorColumn: 0, cursorRow: rows - 1, cursorVisible: false, defaultForegroundRGB: 0xEEEEEE,
            defaultBackgroundRGB: 0x101010, cells: cells)
    }
}
