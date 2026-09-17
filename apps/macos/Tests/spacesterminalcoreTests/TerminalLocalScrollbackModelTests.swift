import Foundation
import XCTest

@testable import spacesterminalcore

final class TerminalLocalScrollbackModelTests: XCTestCase {
    private func theme(background: ThemeColor = ThemeColor(0, 0, 0), foreground: ThemeColor = ThemeColor(255, 255, 255)) -> GhosttyThemeExport {
        GhosttyThemeExport(
            background: background, foreground: foreground, cursorColor: ThemeColor(200, 200, 200), cursorText: ThemeColor(0, 0, 0),
            selectionBackground: ThemeColor(50, 50, 50), selectionForeground: ThemeColor(255, 255, 255),
            palette: (0..<16).map { ThemeColor($0 * 8, $0 * 8, $0 * 8) })
    }

    /// Transcript of numbered CRLF-terminated lines ("row-001", "row-002", …) over the given range, so a
    /// small grid pushes the earlier lines into scrollback and every row is identifiable on screen.
    private func numberedTranscript(_ range: ClosedRange<Int>) -> Data {
        Data((range.map { String(format: "row-%03d", $0) }.joined(separator: "\r\n") + "\r\n").utf8)
    }

    /// The rows as the production row layout renders them, with each row's padding trimmed: that layout
    /// keeps the spaces up to a row's last visible cell, the cursor's own column included, and a
    /// comparison of two screens here is about their content rather than about where the cursor sat.
    private func plainText(_ snapshot: GhosttyTerminalSnapshot) -> String {
        GhosttyTerminalSnapshotLayout.plainText(for: snapshot).split(separator: "\n", omittingEmptySubsequences: false).map {
            $0.trimmingCharacters(in: .whitespaces)
        }.joined(separator: "\n")
    }

    /// The offsets default to a replay holding the whole file; a capped suffix of a longer file passes a
    /// start offset above zero and an end offset beyond its own byte count.
    private func makeModel(
        columns: Int = 10, rows: Int = 3, theme: GhosttyThemeExport? = nil, transcript: Data, startByteOffset: UInt64 = 0,
        endByteOffset: UInt64? = nil, requestedByteCount: Int? = nil, fileIdentity: UInt64? = nil, runIdentity: String? = nil
    ) throws -> TerminalLocalScrollbackModel {
        try XCTUnwrap(
            TerminalLocalScrollbackModel(
                columns: columns, rows: rows, theme: theme ?? self.theme(), appearance: .dark, transcript: transcript,
                transcriptStartByteOffset: startByteOffset, transcriptEndByteOffset: endByteOffset ?? (startByteOffset + UInt64(transcript.count)),
                requestedByteCount: requestedByteCount ?? transcript.count, transcriptFileIdentity: fileIdentity, runIdentity: runIdentity))
    }

    /// A page that is a capped suffix of a longer transcript: its bytes start well into the file, which is
    /// the only shape that can have a deeper page to read.
    private func makeCappedSuffixModel(columns: Int = 10, rows: Int = 3, transcript: Data) throws -> TerminalLocalScrollbackModel {
        try makeModel(
            columns: columns, rows: rows, transcript: transcript, startByteOffset: UInt64(transcript.count) * 3,
            endByteOffset: UInt64(transcript.count) * 4, requestedByteCount: transcript.count)
    }

    func testReplayStartsAtTheNewestRowsAndScrollsIntoHistory() throws {
        let model = try makeModel(transcript: numberedTranscript(1...60))

        XCTAssertTrue(plainText(model.currentSnapshot()).contains("row-060"))
        XCTAssertEqual(model.rowsFromBottom, 0)

        let scrolled = try XCTUnwrap(model.scroll(deltaRows: -20).snapshot)
        XCTAssertFalse(plainText(scrolled).contains("row-060"))
        XCTAssertEqual(model.rowsFromBottom, 20)
    }

    func testScrollClampsAtTheOldestAndNewestRows() throws {
        let model = try makeModel(transcript: numberedTranscript(1...60))

        _ = model.scroll(deltaRows: -1000)
        XCTAssertNil(model.scroll(deltaRows: -50).snapshot)
        XCTAssertTrue(model.isAtTop)
        XCTAssertTrue(plainText(model.currentSnapshot()).contains("row-001"))

        _ = model.scroll(deltaRows: 1000)
        XCTAssertNil(model.scroll(deltaRows: 50).snapshot)
        XCTAssertEqual(model.rowsFromBottom, 0)
        XCTAssertTrue(plainText(model.currentSnapshot()).contains("row-060"))
    }

    func testEmptyTranscriptBuildsWithoutContent() throws {
        let model = try makeModel(columns: 8, rows: 4, transcript: Data())
        XCTAssertNil(model.scroll(deltaRows: -5).snapshot)
        XCTAssertEqual(plainText(model.currentSnapshot()).trimmingCharacters(in: .whitespacesAndNewlines), "")
    }

    func testThemeDefaultForegroundAndBackgroundApplied() throws {
        let background = ThemeColor(1, 2, 3)
        let foreground = ThemeColor(4, 5, 6)
        let model = try makeModel(columns: 8, rows: 4, theme: theme(background: background, foreground: foreground), transcript: Data())

        let snapshot = model.currentSnapshot()
        XCTAssertEqual(snapshot.defaultBackgroundRGB, background.packedRGB)
        XCTAssertEqual(snapshot.defaultForegroundRGB, foreground.packedRGB)
    }

    /// Ghostty keeps the viewport pinned while output appends below it, so a replay the user has scrolled
    /// back into shows the same rows after new output arrives. This is what lets a continuation read land
    /// mid-gesture without the screen jumping.
    func testAppendKeepsTheScrolledViewportPinned() throws {
        let first = numberedTranscript(1...60)
        let model = try makeModel(transcript: first)
        let scrolled = try XCTUnwrap(model.scroll(deltaRows: -20).snapshot)
        let before = plainText(scrolled)

        let more = numberedTranscript(61...80)
        XCTAssertTrue(model.append(more, transcriptEndByteOffset: UInt64(first.count + more.count)))

        XCTAssertEqual(plainText(model.currentSnapshot()), before)
        XCTAssertEqual(model.transcriptEndByteOffset, UInt64(first.count + more.count))
    }

    func testAppendMovesTheBottomAwayFromTheScrolledViewport() throws {
        let first = numberedTranscript(1...60)
        let model = try makeModel(transcript: first)
        _ = model.scroll(deltaRows: -20)
        let rowsFromBottomBefore = model.rowsFromBottom

        let more = numberedTranscript(61...80)
        XCTAssertTrue(model.append(more, transcriptEndByteOffset: UInt64(first.count + more.count)))

        XCTAssertEqual(model.rowsFromBottom, rowsFromBottomBefore + 20)
    }

    /// A replay whose bytes reach back to the transcript's first byte has nothing deeper to read; one
    /// built from a suffix does, until the read that built it already asked for the daemon's whole budget.
    func testDeeperHistoryIsReportedFromWhereTheBytesStartAndWhatTheReadAskedFor() throws {
        let whole = try makeModel(transcript: numberedTranscript(1...60))
        XCTAssertTrue(whole.holdsWholeTranscript)
        XCTAssertFalse(whole.hasDeeperHistory)

        let suffix = try makeCappedSuffixModel(transcript: numberedTranscript(1...60))
        XCTAssertFalse(suffix.holdsWholeTranscript)
        XCTAssertTrue(suffix.hasDeeperHistory)

        // A suffix read at the daemon's whole budget comes back a different size than it asked for (it is
        // cut at a parser-safe boundary and carries a state preamble), so the size the read ASKED for is
        // what says the daemon has nothing more to serve. Paging off the returned size would refetch and
        // rebuild the same suffix on every upward gesture forever.
        let atBudget = try makeModel(
            transcript: numberedTranscript(1...60), startByteOffset: 4_000_000, endByteOffset: 9_000_000,
            requestedByteCount: TerminalScrollbackBudget.defaultMaxBytes)
        XCTAssertFalse(atBudget.holdsWholeTranscript)
        XCTAssertFalse(atBudget.hasDeeperHistory)
    }

    func testTopBoundaryWithDeeperHistoryIsThePagingTrigger() throws {
        let model = try makeCappedSuffixModel(transcript: numberedTranscript(1...60))
        _ = model.scroll(deltaRows: -1000)

        XCTAssertTrue(model.isAtTop)
        XCTAssertTrue(model.hasDeeperHistory)
        XCTAssertNil(model.scroll(deltaRows: -10).snapshot)
        XCTAssertTrue(plainText(model.currentSnapshot()).contains("row-001"))
    }

    /// A single pan or momentum event can ask for more rows than the replay has left above its viewport.
    /// The rows it could not apply are what the deeper page that event triggers carries forward: without
    /// them the gesture stops at the replay's oldest row, settles with no further event to page on, and
    /// the movement past the boundary is lost.
    func testAScrollThatRunsIntoTheOldestRowReportsTheRowsItCouldNotApply() throws {
        let model = try makeCappedSuffixModel(transcript: numberedTranscript(1...60))
        let rowsAboveTheViewport = model.scrollbar.offset
        XCTAssertGreaterThan(rowsAboveTheViewport, 25)

        let overshoot = model.scroll(deltaRows: -(rowsAboveTheViewport + 25))

        XCTAssertNotNil(overshoot.snapshot, "the replay moved as far as it could, so the screen has a frame to paint")
        XCTAssertTrue(model.isAtTop)
        XCTAssertEqual(overshoot.unappliedRows, -25, "the rows past the oldest row are reported, not swallowed")

        let atTheBoundary = model.scroll(deltaRows: -10)
        XCTAssertNil(atTheBoundary.snapshot, "a replay already at its oldest row does not move")
        XCTAssertEqual(atTheBoundary.unappliedRows, -10, "none of the delta could be applied")

        let backDown = model.scroll(deltaRows: 5)
        XCTAssertNotNil(backDown.snapshot)
        XCTAssertEqual(backDown.unappliedRows, 0, "a delta the replay can take entirely leaves nothing over")
    }

    /// A deeper page rebuilds the replay from more bytes, and the rebuilt replay is put back the same
    /// distance from the bottom, so the rows on screen do not move across the rebuild. This drives the
    /// rebuild the way the production callers do (the Mac host and the iOS model): capture
    /// `rowsFromBottom` from the replay being replaced, build a fresh replay from the deeper transcript
    /// through the normal init, then restore that distance with `scrollToRowsFromBottom`.
    func testRebuildingFromADeeperPageKeepsTheSameRowsOnScreen() throws {
        let shallow = try makeCappedSuffixModel(transcript: numberedTranscript(61...120))
        _ = shallow.scroll(deltaRows: -20)
        let shallowText = plainText(shallow.currentSnapshot())
        let rowsFromBottom = shallow.rowsFromBottom

        let deeper = numberedTranscript(1...120)
        let rebuilt = try makeModel(
            columns: shallow.columns, rows: shallow.rows, transcript: deeper, startByteOffset: 0, endByteOffset: UInt64(deeper.count),
            requestedByteCount: TerminalScrollbackBudget.defaultMaxBytes, fileIdentity: 7788)
        rebuilt.scrollToRowsFromBottom(rowsFromBottom)

        XCTAssertEqual(rebuilt.transcriptFileIdentity, 7788, "the rebuilt replay names the file the deeper page was read from")
        XCTAssertEqual(plainText(rebuilt.currentSnapshot()), shallowText)
        XCTAssertEqual(rebuilt.rowsFromBottom, rowsFromBottom)
        XCTAssertTrue(rebuilt.holdsWholeTranscript)
        XCTAssertFalse(rebuilt.hasDeeperHistory)
    }

    func testScrollingToADistanceFromTheBottomShowsTheSameRowsAsScrollingThere() throws {
        let scrolled = try makeModel(transcript: numberedTranscript(1...120))
        _ = scrolled.scroll(deltaRows: -37)

        let restored = try makeModel(transcript: numberedTranscript(1...120))
        XCTAssertNotNil(restored.scrollToRowsFromBottom(scrolled.rowsFromBottom))

        XCTAssertEqual(plainText(restored.currentSnapshot()), plainText(scrolled.currentSnapshot()))
        XCTAssertNil(restored.scrollToRowsFromBottom(restored.rowsFromBottom), "a viewport already there does not move")
    }

    /// The transcript file the replay's bytes came from, which the next continuation read sends back as
    /// proof its offset still names them. An append lands in that same file, so taking bytes in never
    /// changes it: only a rebuild, which is how a replay crosses a head-trim, names a different one.
    func testTheFileIdentityNamesTheTranscriptTheReplayWasBuiltFromAndSurvivesAnAppend() throws {
        let first = numberedTranscript(1...60)
        let model = try makeModel(transcript: first, fileIdentity: 4242)
        XCTAssertEqual(model.transcriptFileIdentity, 4242)

        let short = Data("tail\r\n".utf8)
        XCTAssertTrue(model.append(short, transcriptEndByteOffset: UInt64(first.count + short.count)))

        XCTAssertEqual(model.transcriptFileIdentity, 4242)
        XCTAssertEqual(model.transcriptEndByteOffset, UInt64(first.count + short.count))
    }

    func testTheInitialPageIsSmallerThanTheWholeTranscriptBudget() {
        XCTAssertEqual(TerminalScrollbackBudget.initialLocalScrollbackPageBytes, 1_000_000)
        XCTAssertLessThan(TerminalScrollbackBudget.initialLocalScrollbackPageBytes, TerminalScrollbackBudget.defaultMaxBytes)
    }
}
