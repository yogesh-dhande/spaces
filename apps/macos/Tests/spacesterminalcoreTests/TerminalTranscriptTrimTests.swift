import Foundation
import XCTest
import ghosttyvtshim

@testable import spacesterminalcore

final class TerminalTranscriptTrimTests: XCTestCase {
    // MARK: - Fixtures

    private func makeTranscriptFile() throws -> (url: URL, handle: FileHandle) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        addTeardownBlock {
            try? handle.close()
            try? FileManager.default.removeItem(at: url)
        }
        return (url, handle)
    }

    /// DEC private modes probed across the suite. Emitted early in a transcript, they establish the
    /// terminal state a from-zero handoff replay must reconstruct after a trim.
    private static let decModePayload = Data("\u{1B}[?1049h\u{1B}[?2004h\u{1B}[?1006h\u{1B}[?1h".utf8)
    private static let sgrReset = Data("\u{1B}[0m".utf8)

    // MARK: - Replay/query helpers (fresh shim session, from offset 0)

    private func replaySession(_ data: Data, columns: UInt16 = 80, rows: UInt16 = 24) throws -> OpaquePointer {
        let session = try XCTUnwrap(spaces_ghostty_vt_session_new(columns, rows, 0, nil))
        let replayed = data.withUnsafeBytes { spaces_ghostty_vt_session_write(session, $0.bindMemory(to: UInt8.self).baseAddress, $0.count) }
        XCTAssertTrue(replayed)
        return session
    }

    private func modeIsSet(_ session: OpaquePointer, _ value: UInt16, ansi: Bool = false) -> Bool {
        var isSet = false
        XCTAssertTrue(spaces_ghostty_vt_session_mode_is_set(session, value, ansi, &isSet), "mode \(value) query failed")
        return isSet
    }

    private func kittyKeyboardFlags(_ session: OpaquePointer) -> UInt8 {
        var flags: UInt8 = 0
        XCTAssertTrue(spaces_ghostty_vt_session_kitty_keyboard_flags(session, &flags), "kitty flags query failed")
        return flags
    }

    private func renderPlain(_ data: Data, columns: Int = 80, rows: Int = 24) throws -> String {
        var pointer: UnsafeMutablePointer<CChar>?
        var length = 0
        let succeeded = data.withUnsafeBytes {
            spaces_ghostty_vt_render_plain($0.bindMemory(to: UInt8.self).baseAddress, $0.count, UInt16(columns), UInt16(rows), 0, &pointer, &length)
        }
        XCTAssertTrue(succeeded)
        let pointer2 = try XCTUnwrap(pointer)
        defer { spaces_ghostty_vt_free_buffer(pointer2) }
        return String(decoding: UnsafeRawBufferPointer(UnsafeBufferPointer(start: pointer2, count: length)), as: UTF8.self)
    }

    /// Splits a trimmed transcript into (preamble, tail). The preamble ends with a final SGR reset
    /// `ESC [ 0 m`; the grid repaint inside the preamble also emits interior `ESC [ 0 m` sequences, so
    /// the LAST reset marks the boundary. The retained filler used in these tests contains no `ESC [ 0 m`
    /// of its own (line filler has no escapes; the counter-update filler uses only CUP), so a backwards
    /// search lands on the preamble's closing reset.
    private func splitPreambleAndTail(_ trimmed: Data) throws -> (preamble: Data, tail: Data) {
        let resetRange = try XCTUnwrap(
            trimmed.range(of: Self.sgrReset, options: .backwards), "trimmed transcript must contain a preamble SGR reset")
        return (Data(trimmed[..<resetRange.upperBound]), Data(trimmed[resetRange.upperBound...]))
    }

    private func lineFiller(prefix: String, minBytes: Int, startIndex: Int = 0) -> (data: Data, lastIndex: Int) {
        var data = Data()
        var index = startIndex
        while data.count < minBytes {
            data.append(Data("\(prefix) \(String(format: "%06d", index))\n".utf8))
            index += 1
        }
        return (data, index - 1)
    }

    // MARK: - No-op / basic bounding

    func testTrimIsANoOpBelowTrigger() throws {
        let (url, handle) = try makeTranscriptFile()
        let payload = Data(repeating: 0x61, count: 500)
        try handle.write(contentsOf: payload)

        let newEnd = try TerminalTranscriptTrim.trimIfNeeded(
            outputPath: url.path, writeHandle: handle, currentEndOffset: 500, columns: 80, rows: 24, triggerBytes: 1000, retainedBytes: 400)

        XCTAssertEqual(newEnd, 500)
        XCTAssertEqual(try Data(contentsOf: url), payload, "Transcript below the trigger must be left untouched.")
    }

    func testTrimKeepsNewestContentBehindPreamble() throws {
        let (url, handle) = try makeTranscriptFile()
        let filler = lineFiller(prefix: "SEQ", minBytes: 6000)
        try handle.write(contentsOf: filler.data)

        let newEnd = try TerminalTranscriptTrim.trimIfNeeded(
            outputPath: url.path, writeHandle: handle, currentEndOffset: UInt64(filler.data.count), columns: 80, rows: 24,
            triggerBytes: 4000, retainedBytes: 2000)

        let onDisk = try Data(contentsOf: url)
        XCTAssertEqual(onDisk.count, Int(newEnd))
        XCTAssertEqual(onDisk.first, 0x1B, "A trimmed transcript must begin with the state preamble, not raw retained bytes.")
        let (_, tail) = try splitPreambleAndTail(onDisk)
        let tailText = String(decoding: tail, as: UTF8.self)
        XCTAssertTrue(tailText.contains("SEQ \(String(format: "%06d", filler.lastIndex))"), "Newest line must survive the trim.")
        XCTAssertFalse(tailText.contains("SEQ 000000"), "Oldest lines must be dropped by the trim.")
    }

    func testAppendsContinueAtNewEndAfterTrim() throws {
        let (url, handle) = try makeTranscriptFile()
        let filler = lineFiller(prefix: "SEQ", minBytes: 6000)
        try handle.write(contentsOf: filler.data)

        let newEnd = try TerminalTranscriptTrim.trimIfNeeded(
            outputPath: url.path, writeHandle: handle, currentEndOffset: UInt64(filler.data.count), columns: 80, rows: 24,
            triggerBytes: 4000, retainedBytes: 2000)
        // The write handle must be positioned at the new end so appends do not overwrite retained bytes.
        let appended = Data("APPENDED\n".utf8)
        try handle.write(contentsOf: appended)

        let onDisk = try Data(contentsOf: url)
        XCTAssertEqual(onDisk.count, Int(newEnd) + appended.count)
        XCTAssertEqual(onDisk.suffix(appended.count), appended)
    }

    func testTrimmedTranscriptStillReplaysNewestLinesThroughTail() throws {
        // A suffix consumer (state-naive) must still render the newest scrollback after a trim.
        let (url, handle) = try makeTranscriptFile()
        let filler = lineFiller(prefix: "SEQ", minBytes: 6000)
        try handle.write(contentsOf: filler.data)

        _ = try TerminalTranscriptTrim.trimIfNeeded(
            outputPath: url.path, writeHandle: handle, currentEndOffset: UInt64(filler.data.count), columns: 80, rows: 24,
            triggerBytes: 4000, retainedBytes: 2000)

        let tail = try TerminalOutputTail.tail(path: url.path, lineCount: 3)
        XCTAssertTrue(tail.contains("SEQ \(String(format: "%06d", filler.lastIndex))"), "Newest line must survive the trim: \(tail)")
    }

    func testConfiguredBoundKeepsFullScrollbackBudget() {
        XCTAssertGreaterThan(TerminalScrollbackBudget.liveTranscriptRetainedBytes, TerminalScrollbackBudget.defaultMaxBytes)
        XCTAssertGreaterThan(
            TerminalScrollbackBudget.liveTranscriptTrimTriggerBytes, TerminalScrollbackBudget.liveTranscriptRetainedBytes)
    }

    // MARK: - State preservation (the P1a fix)

    func testStatePreservedAcrossTrimForFromZeroReplay() throws {
        let (url, handle) = try makeTranscriptFile()
        var payload = Self.decModePayload
        payload.append(Data("start of session\n".utf8))
        payload.append(lineFiller(prefix: "filler", minBytes: 6000).data)
        try handle.write(contentsOf: payload)

        _ = try TerminalTranscriptTrim.trimIfNeeded(
            outputPath: url.path, writeHandle: handle, currentEndOffset: UInt64(payload.count), columns: 80, rows: 24,
            triggerBytes: 4000, retainedBytes: 2000)

        let trimmed = try Data(contentsOf: url)

        // The fix: replaying the trimmed file from offset 0 restores the early modes via the preamble.
        let restored = try replaySession(trimmed)
        defer { spaces_ghostty_vt_session_free(restored) }
        XCTAssertTrue(modeIsSet(restored, 1049), "alt screen must survive trim+replay")
        XCTAssertTrue(modeIsSet(restored, 2004), "bracketed paste must survive trim+replay")
        XCTAssertTrue(modeIsSet(restored, 1006), "SGR mouse must survive trim+replay")
        XCTAssertTrue(modeIsSet(restored, 1), "DECCKM must survive trim+replay")

        // Without the preamble (i.e. the old head-truncation semantics), the retained tail alone loses
        // every early mode — proving the preamble is what carries the state, not the retained bytes.
        let (_, tail) = try splitPreambleAndTail(trimmed)
        let tailOnly = try replaySession(tail)
        defer { spaces_ghostty_vt_session_free(tailOnly) }
        XCTAssertFalse(modeIsSet(tailOnly, 1049), "alt screen must be absent from the retained tail")
        XCTAssertFalse(modeIsSet(tailOnly, 2004), "bracketed paste must be absent from the retained tail")
        XCTAssertFalse(modeIsSet(tailOnly, 1006), "SGR mouse must be absent from the retained tail")
        XCTAssertFalse(modeIsSet(tailOnly, 1), "DECCKM must be absent from the retained tail")
    }

    func testKittyKeyboardFlagsSurviveTrim() throws {
        let (url, handle) = try makeTranscriptFile()
        var payload = Data("\u{1B}[=5;1u".utf8)  // set Kitty keyboard flags (disambiguate | report-alternates)
        payload.append(Data("session start\n".utf8))
        payload.append(lineFiller(prefix: "filler", minBytes: 6000).data)
        try handle.write(contentsOf: payload)

        _ = try TerminalTranscriptTrim.trimIfNeeded(
            outputPath: url.path, writeHandle: handle, currentEndOffset: UInt64(payload.count), columns: 80, rows: 24,
            triggerBytes: 4000, retainedBytes: 2000)

        let restored = try replaySession(try Data(contentsOf: url))
        defer { spaces_ghostty_vt_session_free(restored) }
        XCTAssertEqual(kittyKeyboardFlags(restored), 5, "Kitty keyboard flags must survive trim+replay")
    }

    func testFromZeroReplayScreenEquivalence() throws {
        let (url, handle) = try makeTranscriptFile()
        var payload = Self.decModePayload
        payload.append(lineFiller(prefix: "LINE", minBytes: 8000).data)
        try handle.write(contentsOf: payload)
        let original = payload

        _ = try TerminalTranscriptTrim.trimIfNeeded(
            outputPath: url.path, writeHandle: handle, currentEndOffset: UInt64(payload.count), columns: 80, rows: 24,
            triggerBytes: 4000, retainedBytes: 2000)
        let trimmed = try Data(contentsOf: url)

        let originalFrame = try renderPlain(original)
        let trimmedFrame = try renderPlain(trimmed)
        XCTAssertFalse(trimmedFrame.isEmpty)
        XCTAssertEqual(
            trimmedFrame, originalFrame, "From-zero replay of the trimmed transcript must yield the same visible frame as the untrimmed original.")
    }

    // MARK: - Grid repaint (cells the retained tail never redraws)

    /// A static header drawn once at row 1 (before the cut) followed only by cursor-positioned updates
    /// to another row must survive the trim: the preamble's grid repaint carries the header, since the
    /// retained tail never redraws it. Uses box-drawing (`══`) and a wide CJK cell (`漢`) to exercise the
    /// multi-byte UTF-8 and wide-cell/spacer paths of the repaint.
    ///
    /// Fails against a preamble that only restores modes/cursor (no grid repaint): the from-zero replay
    /// of the trimmed transcript starts from a blank grid, so the header row is never redrawn and is lost.
    func testGridRepaintRestoresStaticHeaderNeverRedrawnByTail() throws {
        let (url, handle) = try makeTranscriptFile()

        // Header painted once at row 1. No trailing newline, so it never scrolls.
        let header = "══ 漢 BUILD WATCHER ══"
        var payload = Data("\u{1B}[1;1H\(header)".utf8)

        // Cursor-positioned counter updates confined to row 5 (fixed width, each followed by a LF that
        // moves to the blank row 6 without scrolling). No update ever touches the header row, and the
        // record boundaries are newline-aligned so the retained tail starts cleanly on a record.
        var index = 0
        var records = Data()
        while records.count < 6000 {
            records.append(Data("\u{1B}[5;1H\(String(format: "%06d", index))\n".utf8))
            index += 1
        }
        let lastCounter = String(format: "%06d", index - 1)
        payload.append(records)
        try handle.write(contentsOf: payload)
        let original = payload

        _ = try TerminalTranscriptTrim.trimIfNeeded(
            outputPath: url.path, writeHandle: handle, currentEndOffset: UInt64(payload.count), columns: 80, rows: 24,
            triggerBytes: 4000, retainedBytes: 2000)
        let trimmed = try Data(contentsOf: url)

        // The header lives only in the dropped head; the retained tail must not carry it (it is the grid
        // repaint in the preamble that restores it, not the retained bytes).
        let (_, tail) = try splitPreambleAndTail(trimmed)
        XCTAssertFalse(String(decoding: tail, as: UTF8.self).contains("BUILD WATCHER"), "The retained tail must not redraw the header.")

        // From-zero replay of the trimmed transcript must show the header (via the grid repaint) and the
        // newest counter, and must match the untrimmed from-zero frame exactly.
        let trimmedFrame = try renderPlain(trimmed)
        XCTAssertTrue(trimmedFrame.contains("BUILD WATCHER"), "The static header must survive the trim via the grid repaint: \(trimmedFrame)")
        XCTAssertTrue(trimmedFrame.contains("漢"), "The wide CJK header cell must survive the trim: \(trimmedFrame)")
        XCTAssertTrue(trimmedFrame.contains(lastCounter), "The newest counter must survive the trim: \(trimmedFrame)")

        let originalFrame = try renderPlain(original)
        XCTAssertFalse(trimmedFrame.isEmpty)
        XCTAssertEqual(
            trimmedFrame, originalFrame,
            "From-zero replay of the trimmed transcript must yield the same visible frame as the untrimmed original.")
    }

    // MARK: - Newline alignment

    func testCutIsNewlineAlignedWhenNewlineNearNominalOffset() throws {
        let (url, handle) = try makeTranscriptFile()
        let filler = lineFiller(prefix: "SEQ", minBytes: 6000)
        try handle.write(contentsOf: filler.data)
        let retainedBytes: UInt64 = 2000

        _ = try TerminalTranscriptTrim.trimIfNeeded(
            outputPath: url.path, writeHandle: handle, currentEndOffset: UInt64(filler.data.count), columns: 80, rows: 24,
            triggerBytes: 4000, retainedBytes: retainedBytes)

        let (_, tail) = try splitPreambleAndTail(try Data(contentsOf: url))
        XCTAssertTrue(String(decoding: tail, as: UTF8.self).hasPrefix("SEQ "), "Retained tail must start at a line boundary.")
        // Forward alignment moves the cut past the next newline, so fewer than `retainedBytes` are kept.
        XCTAssertLessThan(tail.count, Int(retainedBytes), "Newline alignment should drop the partial leading line.")
    }

    func testCutFallsBackToNominalOffsetWithoutNewlineWithinBound() throws {
        // A retained region larger than the 1MB forward-scan bound with neither a newline nor an ESC byte
        // (an all-'X' span) forces the nominal (unaligned) offset — the last-resort fallback for a window
        // with no parser-safe boundary at all. The bounded scan must not run past its limit hunting for one.
        let (url, handle) = try makeTranscriptFile()
        let retainedBytes = TerminalTranscriptTrim.maxNewlineAlignScanBytes + 100_000  // > 1 MiB newline-free retained span
        var payload = Data()
        payload.append(lineFiller(prefix: "HEADER", minBytes: 400_000).data)
        let newlineFreeStart = payload.count
        payload.append(Data(repeating: 0x58, count: Int(retainedBytes) + 200_000))  // 'X' * (>retained), no newlines
        let triggerBytes = retainedBytes + 300_000
        XCTAssertGreaterThan(UInt64(payload.count), triggerBytes)
        XCTAssertLessThan(UInt64(newlineFreeStart), UInt64(payload.count) - retainedBytes, "Nominal cut must land inside the newline-free span.")
        try handle.write(contentsOf: payload)

        _ = try TerminalTranscriptTrim.trimIfNeeded(
            outputPath: url.path, writeHandle: handle, currentEndOffset: UInt64(payload.count), columns: 80, rows: 24,
            triggerBytes: triggerBytes, retainedBytes: retainedBytes)

        let (_, tail) = try splitPreambleAndTail(try Data(contentsOf: url))
        XCTAssertEqual(UInt64(tail.count), retainedBytes, "Fallback must keep exactly the nominal retained span (cut = nominal offset).")
        XCTAssertTrue(tail.allSatisfy { $0 == 0x58 }, "Retained tail must be the newline-free span.")
    }

    // An LF-free megabyte span is realistic for alt-screen TUIs (the exact sessions that trim): repeated
    // cursor positioning with no trailing newline. Cutting at the arbitrary nominal offset would land
    // mid-CSI-sequence, and a from-zero replay of the retained tail would then start parsing mid-sequence
    // and render garbage. ESC (0x1B) is always the start of a new escape sequence and can never sit inside
    // a UTF-8 continuation byte (those are all >= 0x80), so cutting immediately before the first ESC in the
    // scan window is always a clean parser boundary.
    //
    // Fails against a nominal-offset fallback: the retained tail then begins mid-CSI-sequence, not at 0x1B.
    func testCutFallsBackToFirstEscByteWhenNoNewlineWithinBound() throws {
        let (url, handle) = try makeTranscriptFile()
        // The `+ 100_007` (vs. a round number) is deliberate: it makes the nominal offset land a few bytes
        // into a record rather than coincidentally on a record's leading ESC, so this test cannot pass by
        // accident against the old nominal-offset fallback.
        let retainedBytes = TerminalTranscriptTrim.maxNewlineAlignScanBytes + 100_007  // > 1 MiB newline-free retained span
        var payload = Data()
        payload.append(lineFiller(prefix: "HEADER", minBytes: 400_000).data)

        // Repeated CUP + text with no trailing LF anywhere: an alt-screen TUI redrawing a fixed line in
        // place. ESC recurs every few bytes, so the scan window is dense with clean cut points.
        var index = 0
        var controlHeavy = Data()
        while controlHeavy.count < Int(retainedBytes) + 200_000 {
            controlHeavy.append(Data("\u{1B}[5;1Hline \(index)".utf8))
            index += 1
        }
        payload.append(controlHeavy)
        let triggerBytes = retainedBytes + 300_000
        XCTAssertGreaterThan(UInt64(payload.count), triggerBytes)
        try handle.write(contentsOf: payload)

        _ = try TerminalTranscriptTrim.trimIfNeeded(
            outputPath: url.path, writeHandle: handle, currentEndOffset: UInt64(payload.count), columns: 80, rows: 24,
            triggerBytes: triggerBytes, retainedBytes: retainedBytes)

        let (_, tail) = try splitPreambleAndTail(try Data(contentsOf: url))
        XCTAssertEqual(tail.first, 0x1B, "Without a newline in the scan window, the cut must land just before the first ESC, not mid-sequence.")
    }

    // MARK: - Induction across successive trims

    func testStateSurvivesSuccessiveTrims() throws {
        let (url, handle) = try makeTranscriptFile()
        var payload = Self.decModePayload
        payload.append(lineFiller(prefix: "FIRST", minBytes: 8000).data)
        try handle.write(contentsOf: payload)

        var endOffset = try TerminalTranscriptTrim.trimIfNeeded(
            outputPath: url.path, writeHandle: handle, currentEndOffset: UInt64(payload.count), columns: 80, rows: 24,
            triggerBytes: 4000, retainedBytes: 2000)

        // Append more filler to cross the trigger again, then trim a second time. The second trim's
        // head replay [0..cut] starts from the FIRST trim's preamble, so state must remain correct.
        let more = lineFiller(prefix: "SECOND", minBytes: 4000).data
        try handle.write(contentsOf: more)
        endOffset = try TerminalTranscriptTrim.trimIfNeeded(
            outputPath: url.path, writeHandle: handle, currentEndOffset: endOffset + UInt64(more.count), columns: 80, rows: 24,
            triggerBytes: 4000, retainedBytes: 2000)
        _ = endOffset

        let restored = try replaySession(try Data(contentsOf: url))
        defer { spaces_ghostty_vt_session_free(restored) }
        XCTAssertTrue(modeIsSet(restored, 1049), "alt screen must survive two successive trims")
        XCTAssertTrue(modeIsSet(restored, 2004), "bracketed paste must survive two successive trims")
        XCTAssertTrue(modeIsSet(restored, 1006), "SGR mouse must survive two successive trims")
        XCTAssertTrue(modeIsSet(restored, 1), "DECCKM must survive two successive trims")
        XCTAssertTrue(String(decoding: try Data(contentsOf: url), as: UTF8.self).contains("SECOND"), "Newest content must survive the second trim.")
    }
}
