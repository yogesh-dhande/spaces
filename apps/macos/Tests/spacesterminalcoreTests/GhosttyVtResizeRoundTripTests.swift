import Foundation
import Testing
import ghosttyvtshim

@testable import spacesterminalcore

/// A remote pane that shrinks to a few rows and is restored before the program draws again must show
/// the screen the program last drew (#468).
///
/// libghostty-vt reflows a rows shrink that pushes the cursor's row into scrollback by resetting the
/// cursor to the top, and growing back adds blank rows instead of pulling the scrollback home, so an
/// inline TUI that is reflowed down and back keeps only its footer rows. The daemon avoids the loss by
/// never reflowing to a transient grid: `TerminalResizeCoalescer` applies only the last size requested
/// within its window.
///
/// The stream is an inline TUI: ordinary lines scroll into history, and a live region at the bottom is
/// repainted in place with cursor-up, erase-line and rewrite inside synchronized output, after which the
/// cursor parks on the input row, above the region's last row. Nothing in the stream addresses rows
/// absolutely, so the live region sits wherever the cursor was when the repaint started.
///
/// The daemon side drives libghostty-vt and `GhosttyRenderUpdateProducer` in the order
/// `GhosttyLinuxHeadlessSessionCore` does (that type builds only on Linux): every output turn writes the
/// bytes, bumps the screen revision and exports a stream update; resize requests go through the
/// coalescer, and each size it settles on reflows the live session in place, drops the baseline and
/// exports a full `.resize` frame. The client side decodes the wire bytes and applies them with
/// `GhosttyRenderUpdateApplier`, as a mirror does.
@Suite struct GhosttyVtResizeRoundTripTests {
    private static let columns: UInt16 = 132
    private static let rows: UInt16 = 59

    @Test func aShrinkRestoredWithinTheCoalesceWindowKeepsTheInlineLiveRegionWhereItWasDrawn() throws {
        let daemon = try HeadlessDaemonStandIn(columns: Self.columns, rows: Self.rows)
        var client: GhosttyRenderUpdateBaseline?

        client = try apply(daemon.output(Self.history, reason: .initial), to: client)
        for turn in Self.liveRegionTurns { client = try apply(daemon.output(turn, reason: .output), to: client) }

        let drawn = try #require(client).snapshot
        let replayed = try Self.freshReplay(of: Self.history + Self.liveRegionTurns.joined())
        #expect(visibleRows(drawn) == visibleRows(replayed), "the streamed mirror shows what a fresh replay of the transcript shows")
        #expect(drawn.cursorRow == Self.inputRow)

        #expect(daemon.requestResize(columns: Int(Self.columns), rows: 2) == .armTimer)
        #expect(daemon.requestResize(columns: Int(Self.columns), rows: Int(Self.rows)) == .coalesced)
        #expect(try daemon.settleResize() == nil, "a burst that ends on the current grid reflows nothing and sends no frame")

        let live = try daemon.liveSnapshot()
        #expect(visibleRows(live) == visibleRows(drawn), "the daemon's screen is exactly what the program drew")
        #expect(live.cursorRow == drawn.cursorRow, "the cursor stays on the input row the program parked it on")
    }

    @Test func anAppliedResizeLeavesTheMirrorHoldingTheDaemonsLiveScreen() throws {
        let daemon = try HeadlessDaemonStandIn(columns: Self.columns, rows: Self.rows)
        var client: GhosttyRenderUpdateBaseline?

        client = try apply(daemon.output(Self.history, reason: .initial), to: client)
        for turn in Self.liveRegionTurns { client = try apply(daemon.output(turn, reason: .output), to: client) }

        #expect(daemon.requestResize(columns: 100, rows: 40) == .armTimer)
        client = try apply(try #require(try daemon.settleResize()), to: client)

        let mirrored = try #require(client).snapshot
        #expect(mirrored.columns == 100 && mirrored.rows == 40)
        #expect(visibleRows(mirrored) == visibleRows(try daemon.liveSnapshot()), "the mirror holds exactly the daemon's live screen")
    }

    // MARK: - Stream

    private static let history = (0..<120).map { "history line \($0)\r\n" }.joined()

    /// The live region's rows, top to bottom. The input row is the fourth.
    private static func liveRegion(activity: String) -> [String] {
        [
            activity, "", String(repeating: "-", count: 40), "> ", String(repeating: "-", count: 40), "status: bypass permissions on",
            "tabs: one two three",
        ]
    }

    /// The row the cursor parks on: the input row of a region that ends one row above the bottom.
    private static let inputRow = Int(rows) - 5

    /// One output turn per repaint. The first draws the region below the history and parks the cursor;
    /// each later one moves to the region's top, rewrites it (optionally printing transcript lines above
    /// it first, which scrolls the screen), and parks the cursor again.
    private static let liveRegionTurns: [String] = {
        let park = "\u{1B}[2C\u{1B}[4A"
        func repaint(_ activity: String, above: [String] = []) -> String {
            "\u{1B}[?2026h\u{1B}[4B\r\u{1B}[7A" + (above + liveRegion(activity: activity)).map { $0 + "\u{1B}[K\r\n" }.joined() + park
                + "\u{1B}[?2026l"
        }
        return [
            (0..<3).map { "> conversation line \($0)\r\n" }.joined() + liveRegion(activity: "thinking 0").map { $0 + "\r\n" }.joined() + park,
            repaint("thinking 1"), repaint("thinking 2", above: (0..<3).map { "answer line \($0)" }), repaint("done"),
        ]
    }()

    // MARK: - Helpers

    private func apply(_ wire: Data, to baseline: GhosttyRenderUpdateBaseline?) throws -> GhosttyRenderUpdateBaseline {
        try GhosttyRenderUpdateApplier.apply(try GhosttyRenderUpdateBinaryCodec.decode(wire), to: baseline)
    }

    /// The screen as `row|text` for every non-blank row, so a failure prints the picture a user sees.
    private func visibleRows(_ snapshot: GhosttyTerminalSnapshot) -> [String] {
        (0..<snapshot.rows).compactMap { row in
            var scalars = String.UnicodeScalarView()
            for cell in snapshot.cells[(row * snapshot.columns)..<((row + 1) * snapshot.columns)] {
                scalars.append(cell.codepoint == 0 ? " " : (Unicode.Scalar(cell.codepoint) ?? " "))
            }
            let text = String(String(scalars).reversed().drop(while: \.isWhitespace).reversed())
            return text.isEmpty ? nil : "\(row)|\(text)"
        }
    }

    /// What `spaces terminal tail` shows: the transcript replayed into a fresh session at the grid.
    private static func freshReplay(of transcript: String) throws -> GhosttyTerminalSnapshot {
        let replay = try HeadlessDaemonStandIn(columns: columns, rows: rows)
        _ = try replay.output(transcript, reason: .initial)
        return try replay.liveSnapshot()
    }
}

/// libghostty-vt plus the render-update producer, stepped the way `GhosttyLinuxHeadlessSessionCore`
/// steps them in `handleOutput`, `resize` and `renderFrame`.
private final class HeadlessDaemonStandIn {
    private let session: OpaquePointer
    private var producer = GhosttyRenderUpdateProducer()
    private var screenStateRevision: UInt64 = 0
    private var coalescer = TerminalResizeCoalescer()
    private var size: TerminalResizeCoalescer.Size

    init(columns: UInt16, rows: UInt16) throws {
        session = try #require(spaces_ghostty_vt_session_new(columns, rows, TerminalScrollbackBudget.defaultMaxBytes, nil))
        size = .init(columns: Int(columns), rows: Int(rows))
    }

    deinit { spaces_ghostty_vt_session_free(session) }

    func output(_ text: String, reason: TerminalRemoteSessionStateReason) throws -> Data {
        let bytes = Data(text.utf8)
        let written = bytes.withUnsafeBytes { spaces_ghostty_vt_session_write(session, $0.bindMemory(to: UInt8.self).baseAddress, $0.count) }
        #expect(written)
        screenStateRevision &+= 1
        return try export(reason: reason)
    }

    func requestResize(columns: Int, rows: Int) -> TerminalResizeCoalescer.Outcome {
        coalescer.request(.init(columns: columns, rows: rows), current: size)
    }

    /// The window's timer firing: the frame for the grid the session reflowed to, or nil when it did not.
    func settleResize() throws -> Data? {
        guard let settled = coalescer.settle(current: size) else { return nil }
        #expect(spaces_ghostty_vt_session_resize(session, UInt16(settled.columns), UInt16(settled.rows)))
        size = settled
        producer.resetBaselineAndForceNextFull()
        screenStateRevision &+= 1
        return try export(reason: .resize)
    }

    func liveSnapshot() throws -> GhosttyTerminalSnapshot { try capture().snapshot }

    private func export(reason: TerminalRemoteSessionStateReason) throws -> Data {
        let frame = try capture()
        let (rects, overflowed) = takeScrollRects()
        let update = producer.makeUpdate(
            for: frame, reason: reason, nativeScrollRects: rects, nativeScrollRectsOverflowed: overflowed, exportMode: .streamDeltaAllowed)
        return try GhosttyRenderUpdateBinaryCodec.encode(update)
    }

    private func capture() throws -> GhosttyRenderFrame {
        var raw = SpacesGhosttyVtSnapshot()
        try #require(spaces_ghostty_vt_session_copy_snapshot(session, &raw))
        defer { spaces_ghostty_vt_snapshot_free(&raw) }
        var scrollbar = SpacesGhosttyVtScrollbar()
        let hasScrollbar = spaces_ghostty_vt_session_scrollbar(session, &scrollbar)
        let snapshot = GhosttyVtSessionBridge.snapshot(
            from: raw, mouseReportingActive: false, alternateScreenActive: GhosttyVtSessionBridge.alternateScreenActive(session: session),
            scrollbarTotal: hasScrollbar ? UInt32(clamping: scrollbar.total) : 0,
            scrollbarOffset: hasScrollbar ? UInt32(clamping: scrollbar.offset) : 0)
        return GhosttyRenderFrame(sessionRevision: screenStateRevision, ownerEpoch: 1, snapshot: snapshot)
    }

    private func takeScrollRects() -> ([GhosttyRenderScrollRectOperation], Bool) {
        let capacity = 64
        var buffer = [SpacesGhosttyVtScrollRect](repeating: SpacesGhosttyVtScrollRect(), count: capacity)
        var overflowed = false
        let count = buffer.withUnsafeMutableBufferPointer {
            spaces_ghostty_vt_session_take_scroll_rects(session, $0.baseAddress, capacity, &overflowed)
        }
        let rects = buffer[0..<count].map {
            GhosttyRenderScrollRectOperation(
                rowStart: Int($0.row_start), rowCount: Int($0.row_count), columnStart: Int($0.column_start), columnCount: Int($0.column_count),
                deltaRows: Int($0.delta_rows), deltaColumns: Int($0.delta_columns))
        }
        return (rects, overflowed)
    }
}
