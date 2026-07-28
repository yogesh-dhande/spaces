import Foundation
import XCTest
import ghosttyvtshim

@testable import spacesterminalcore

final class TerminalTranscriptTrimTests: XCTestCase {
    // MARK: - Fixtures

    /// Runs a whole trim — plan, staging, commit — as one synchronous call. In production those three
    /// stages straddle the engine actor (`TerminalTranscriptTrimCoordinator`), but the retained content,
    /// the preamble, and the atomic-replace contract are the same wherever each stage ran, so the content
    /// suite drives them directly. `currentEndOffset` is unchanged between plan and commit here, i.e. no
    /// append raced the trim; the coordinator suite covers the racing case.
    @discardableResult private func performTrim(
        outputPath: String, writeHandle: FileHandle, currentEndOffset: UInt64, columns: Int, rows: Int, triggerBytes: UInt64, retainedBytes: UInt64
    ) throws -> TerminalTranscriptTrim.TrimResult {
        guard
            let plan = try TerminalTranscriptTrim.plan(
                outputPath: outputPath, currentEndOffset: currentEndOffset, triggerBytes: triggerBytes, retainedBytes: retainedBytes)
        else { return TerminalTranscriptTrim.TrimResult(endOffset: currentEndOffset, writeHandle: writeHandle) }
        let staged = try TerminalTranscriptTrim.stage(outputPath: outputPath, plan: plan, columns: columns, rows: rows)
        return try TerminalTranscriptTrim.commit(staged, outputPath: outputPath, currentEndOffset: currentEndOffset)
    }

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
        let resetRange = try XCTUnwrap(trimmed.range(of: Self.sgrReset, options: .backwards), "trimmed transcript must contain a preamble SGR reset")
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

        let result = try performTrim(
            outputPath: url.path, writeHandle: handle, currentEndOffset: 500, columns: 80, rows: 24, triggerBytes: 1000, retainedBytes: 400)

        XCTAssertEqual(result.endOffset, 500)
        XCTAssertTrue(result.writeHandle === handle, "A no-op trim must return the caller's own handle unchanged.")
        XCTAssertEqual(try Data(contentsOf: url), payload, "Transcript below the trigger must be left untouched.")
    }

    func testTrimKeepsNewestContentBehindPreamble() throws {
        let (url, handle) = try makeTranscriptFile()
        let filler = lineFiller(prefix: "SEQ", minBytes: 6000)
        try handle.write(contentsOf: filler.data)

        let result = try performTrim(
            outputPath: url.path, writeHandle: handle, currentEndOffset: UInt64(filler.data.count), columns: 80, rows: 24, triggerBytes: 4000,
            retainedBytes: 2000)
        addTeardownBlock { [writeHandle = result.writeHandle] in try? writeHandle.close() }

        let onDisk = try Data(contentsOf: url)
        XCTAssertEqual(onDisk.count, Int(result.endOffset))
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

        let result = try performTrim(
            outputPath: url.path, writeHandle: handle, currentEndOffset: UInt64(filler.data.count), columns: 80, rows: 24, triggerBytes: 4000,
            retainedBytes: 2000)
        XCTAssertFalse(result.writeHandle === handle, "A trim must return a fresh handle on the replaced file, not the caller's old one.")
        addTeardownBlock { [writeHandle = result.writeHandle] in try? writeHandle.close() }
        // Appends must go through the RETURNED handle (the old one points at the unlinked pre-trim inode),
        // positioned at the new end so they do not overwrite retained bytes.
        let appended = Data("APPENDED\n".utf8)
        try result.writeHandle.write(contentsOf: appended)

        let onDisk = try Data(contentsOf: url)
        XCTAssertEqual(onDisk.count, Int(result.endOffset) + appended.count)
        XCTAssertEqual(onDisk.suffix(appended.count), appended)
    }

    func testTrimmedTranscriptStillReplaysNewestLinesThroughTail() throws {
        // A suffix consumer (state-naive) must still render the newest scrollback after a trim.
        let (url, handle) = try makeTranscriptFile()
        let filler = lineFiller(prefix: "SEQ", minBytes: 6000)
        try handle.write(contentsOf: filler.data)

        _ = try performTrim(
            outputPath: url.path, writeHandle: handle, currentEndOffset: UInt64(filler.data.count), columns: 80, rows: 24, triggerBytes: 4000,
            retainedBytes: 2000)

        let tail = try TerminalOutputTail.tail(path: url.path, lineCount: 3)
        XCTAssertTrue(tail.contains("SEQ \(String(format: "%06d", filler.lastIndex))"), "Newest line must survive the trim: \(tail)")
    }

    func testConfiguredBoundKeepsFullScrollbackBudget() {
        XCTAssertGreaterThan(TerminalScrollbackBudget.liveTranscriptRetainedBytes, TerminalScrollbackBudget.defaultMaxBytes)
        XCTAssertGreaterThan(TerminalScrollbackBudget.liveTranscriptTrimTriggerBytes, TerminalScrollbackBudget.liveTranscriptRetainedBytes)
    }

    // MARK: - State preservation (the P1a fix)

    func testStatePreservedAcrossTrimForFromZeroReplay() throws {
        let (url, handle) = try makeTranscriptFile()
        var payload = Self.decModePayload
        payload.append(Data("start of session\n".utf8))
        payload.append(lineFiller(prefix: "filler", minBytes: 6000).data)
        try handle.write(contentsOf: payload)

        _ = try performTrim(
            outputPath: url.path, writeHandle: handle, currentEndOffset: UInt64(payload.count), columns: 80, rows: 24, triggerBytes: 4000,
            retainedBytes: 2000)

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

        _ = try performTrim(
            outputPath: url.path, writeHandle: handle, currentEndOffset: UInt64(payload.count), columns: 80, rows: 24, triggerBytes: 4000,
            retainedBytes: 2000)

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

        _ = try performTrim(
            outputPath: url.path, writeHandle: handle, currentEndOffset: UInt64(payload.count), columns: 80, rows: 24, triggerBytes: 4000,
            retainedBytes: 2000)
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

        _ = try performTrim(
            outputPath: url.path, writeHandle: handle, currentEndOffset: UInt64(payload.count), columns: 80, rows: 24, triggerBytes: 4000,
            retainedBytes: 2000)
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
            trimmedFrame, originalFrame, "From-zero replay of the trimmed transcript must yield the same visible frame as the untrimmed original.")
    }

    // MARK: - Newline alignment

    /// The newline fallback: in an ESC-free window (plain text, the region where the newline cut is
    /// parser-safe — there is no open OSC/DCS to sit an LF inside), the cut lands just past the next
    /// newline so the retained tail begins on a line boundary.
    func testCutIsNewlineAlignedWhenNewlineNearNominalOffset() throws {
        let (url, handle) = try makeTranscriptFile()
        let filler = lineFiller(prefix: "SEQ", minBytes: 6000)
        try handle.write(contentsOf: filler.data)
        let retainedBytes: UInt64 = 2000

        _ = try performTrim(
            outputPath: url.path, writeHandle: handle, currentEndOffset: UInt64(filler.data.count), columns: 80, rows: 24, triggerBytes: 4000,
            retainedBytes: retainedBytes)

        let (_, tail) = try splitPreambleAndTail(try Data(contentsOf: url))
        XCTAssertTrue(String(decoding: tail, as: UTF8.self).hasPrefix("SEQ "), "Retained tail must start at a line boundary.")
        // Forward alignment moves the cut past the next newline, so fewer than `retainedBytes` are kept.
        XCTAssertLessThan(tail.count, Int(retainedBytes), "Newline alignment should drop the partial leading line.")
    }

    /// A retained region whose 1 MiB forward-scan window holds neither a newline nor an ESC (an oversized
    /// LF/ESC-free run — a multi-megabyte DCS/OSC payload, or a long plain-text run) has no parser-safe
    /// cut: every candidate lands mid-sequence/mid-codepoint, which a from-zero replay would render as
    /// garbage. The trim must DEFER rather than cut blind — returning the caller's own handle unchanged,
    /// the offset unchanged, `output.log` byte-identical, and no `.trim` temp staged.
    ///
    /// Red-first: the old code fell back to the nominal offset and trimmed at an arbitrary byte, so it
    /// returned a fresh handle over a rewritten file — these identity and byte-identical assertions fail
    /// against it.
    func testTrimDefersWhenScanWindowHasNoParserSafeBoundary() throws {
        let (url, handle) = try makeTranscriptFile()
        // retained > 1 MiB so the whole forward-scan window sits inside the run when the run ends the file.
        let retainedBytes = TerminalTranscriptTrim.maxParserSafeCutScanBytes + 100_000
        var payload = Data()
        payload.append(lineFiller(prefix: "HEADER", minBytes: 400_000).data)
        // A >1.5 MiB run of a single non-ESC, non-LF byte at the end of the file: the nominal cut lands
        // inside it and the entire 1 MiB scan window stays inside it, so the scan finds no boundary.
        payload.append(Data(repeating: 0x41, count: Int(retainedBytes) + 200_000))  // 'A' * (>retained), no LF, no ESC
        let triggerBytes = retainedBytes + 300_000
        XCTAssertGreaterThan(UInt64(payload.count), triggerBytes)
        try handle.write(contentsOf: payload)

        let result = try performTrim(
            outputPath: url.path, writeHandle: handle, currentEndOffset: UInt64(payload.count), columns: 80, rows: 24, triggerBytes: triggerBytes,
            retainedBytes: retainedBytes)

        XCTAssertTrue(result.writeHandle === handle, "A deferred trim must return the caller's own handle unchanged.")
        XCTAssertEqual(result.endOffset, UInt64(payload.count), "A deferred trim must leave the end offset unchanged.")
        XCTAssertEqual(try Data(contentsOf: url), payload, "A deferred trim must leave output.log byte-identical.")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path + ".trim"), "A deferred trim must stage no temp file.")
    }

    /// The deferral is self-limiting: the nominal cut advances with every append, so once enough ordinary
    /// (newline-terminated) content is appended past the oversized run, the sliding scan window reaches a
    /// newline and the trim lands, retaining a parser-safe, line-aligned tail.
    func testTrimDefersThenSucceedsOnceWindowSlidesPastTheRun() throws {
        let (url, handle) = try makeTranscriptFile()
        let retainedBytes = TerminalTranscriptTrim.maxParserSafeCutScanBytes + 100_000
        var payload = Data()
        payload.append(lineFiller(prefix: "HEADER", minBytes: 400_000).data)
        payload.append(Data(repeating: 0x41, count: Int(retainedBytes) + 200_000))  // oversized LF/ESC-free run
        let triggerBytes = retainedBytes + 300_000
        try handle.write(contentsOf: payload)

        // First trim: the scan window is entirely inside the run, so the trim defers (no-op, same handle).
        let deferred = try performTrim(
            outputPath: url.path, writeHandle: handle, currentEndOffset: UInt64(payload.count), columns: 80, rows: 24, triggerBytes: triggerBytes,
            retainedBytes: retainedBytes)
        XCTAssertTrue(deferred.writeHandle === handle, "The first trim must defer while the scan window is inside the run.")
        XCTAssertEqual(deferred.endOffset, UInt64(payload.count))

        // Append enough newline-terminated content that the nominal cut slides past the run's end into
        // ordinary lines, bringing a newline into the scan window.
        let tailLines = lineFiller(prefix: "TAIL", minBytes: Int(retainedBytes) + 400_000).data
        try deferred.writeHandle.write(contentsOf: tailLines)
        let newEndOffset = deferred.endOffset + UInt64(tailLines.count)

        let trimmed = try performTrim(
            outputPath: url.path, writeHandle: deferred.writeHandle, currentEndOffset: newEndOffset, columns: 80, rows: 24,
            triggerBytes: triggerBytes, retainedBytes: retainedBytes)
        addTeardownBlock { [writeHandle = trimmed.writeHandle] in try? writeHandle.close() }

        XCTAssertFalse(trimmed.writeHandle === handle, "Once the window slides past the run the trim must land, returning a fresh handle.")
        XCTAssertLessThan(trimmed.endOffset, newEndOffset, "The landed trim must shrink the transcript.")

        let onDisk = try Data(contentsOf: url)
        XCTAssertEqual(onDisk.count, Int(trimmed.endOffset), "The replaced file's size must equal the reported end offset.")
        let (_, tail) = try splitPreambleAndTail(onDisk)
        XCTAssertTrue(String(decoding: tail, as: UTF8.self).hasPrefix("TAIL "), "The landed trim must retain a line-aligned tail past the run.")
    }

    // ESC-first is the primary cut path: whenever the scan window holds any ESC, the cut lands just
    // before the window's first ESC — parser-safe from any state (ESC can never sit inside a UTF-8
    // continuation byte, and a mid-string ESC begins that string's ST terminator, harmless in ground-state
    // replay). An LF-free megabyte span is realistic for alt-screen TUIs (the exact sessions that trim):
    // repeated cursor positioning with no trailing newline. Here every candidate is dense with ESCs, so
    // the cut lands on one; cutting at the arbitrary nominal offset would instead land mid-CSI-sequence and
    // a from-zero replay of the retained tail would start parsing mid-sequence and render garbage.
    //
    // Fails against a nominal-offset fallback: the retained tail then begins mid-CSI-sequence, not at 0x1B.
    func testCutLandsBeforeFirstEscByteWhenWindowHasEsc() throws {
        let (url, handle) = try makeTranscriptFile()
        // The `+ 100_007` (vs. a round number) is deliberate: it makes the nominal offset land a few bytes
        // into a record rather than coincidentally on a record's leading ESC, so this test cannot pass by
        // accident against the old nominal-offset fallback.
        let retainedBytes = TerminalTranscriptTrim.maxParserSafeCutScanBytes + 100_007  // > 1 MiB newline-free retained span
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

        _ = try performTrim(
            outputPath: url.path, writeHandle: handle, currentEndOffset: UInt64(payload.count), columns: 80, rows: 24, triggerBytes: triggerBytes,
            retainedBytes: retainedBytes)

        let (_, tail) = try splitPreambleAndTail(try Data(contentsOf: url))
        XCTAssertEqual(tail.first, 0x1B, "With an ESC in the scan window, the cut must land just before the first ESC, not mid-sequence.")
    }

    /// Regression (P2): the nominal cut landing inside an OSC string whose payload carries raw LFs must
    /// NOT cut just past one of those embedded LFs. Ghostty's parser swallows LF inside `osc_string` (it
    /// exits only on BEL/ESC/CAN/SUB), so a cut just past an embedded payload LF starts the retained tail
    /// mid-payload; the from-zero replay begins in ground state after the preamble and renders the payload
    /// bytes as visible text. The parser-safe (ESC-first) cut instead lands just before the window's first
    /// ESC — here the OSC's `ESC \` (ST) terminator — so the tail begins on a clean parser boundary and the
    /// payload never surfaces.
    ///
    /// Red-first: against the newline-preferring cut the tail begins at a fresh payload line (not ESC) and
    /// the from-zero frame renders the payload marker as visible text.
    func testCutSkipsNewlineInsideOscPayloadAndLandsBeforeEsc() throws {
        let (url, handle) = try makeTranscriptFile()

        // Dropped head: ordinary lines.
        let header = lineFiller(prefix: "HEAD", minBytes: 6000).data

        // An OSC 5555 string whose multi-KB payload is packed with raw LFs and a distinctive marker,
        // closed by an ESC \ (ST) terminator. The parser stays in osc_string across every embedded LF.
        let oscPrefix = Data("\u{1B}]5555;".utf8)
        var oscPayload = Data()
        var lineIndex = 0
        while oscPayload.count < 4000 {
            oscPayload.append(Data("OSCPAYLOAD-\(String(format: "%04d", lineIndex))\n".utf8))
            lineIndex += 1
        }
        let stTerminator = Data("\u{1B}\\".utf8)

        // Newest content after the OSC, kept under one screen so it cannot scroll the leaked payload off a
        // pre-fix frame (which must expose the leak).
        let newest = Data("NEWEST alpha\nNEWEST bravo\nNEWEST charlie\n".utf8)

        var payload = Data()
        payload.append(header)
        let oscPayloadStart = payload.count + oscPrefix.count
        payload.append(oscPrefix)
        payload.append(oscPayload)
        payload.append(stTerminator)
        payload.append(newest)
        try handle.write(contentsOf: payload)

        // Position the nominal cut in the MIDDLE of the OSC payload — before an embedded LF and before the
        // ST — by choosing retainedBytes = endOffset - (payloadStart + payload/2).
        let nominalStart = UInt64(oscPayloadStart + oscPayload.count / 2)
        let retainedBytes = UInt64(payload.count) - nominalStart
        let triggerBytes = retainedBytes + 2000
        XCTAssertGreaterThan(UInt64(payload.count), triggerBytes)

        _ = try performTrim(
            outputPath: url.path, writeHandle: handle, currentEndOffset: UInt64(payload.count), columns: 80, rows: 24, triggerBytes: triggerBytes,
            retainedBytes: retainedBytes)
        let trimmed = try Data(contentsOf: url)

        let (_, tail) = try splitPreambleAndTail(trimmed)
        XCTAssertEqual(
            tail.first, 0x1B,
            "The cut must skip the LFs inside the OSC payload and land just before the ST's ESC, so the tail starts on a clean parser boundary.")
        XCTAssertFalse(String(decoding: tail, as: UTF8.self).hasPrefix("OSCPAYLOAD"), "The retained tail must not begin mid-OSC-payload.")

        // From-zero replay must not surface the OSC payload as visible text, and must still show the newest
        // content that follows the terminated OSC.
        let trimmedFrame = try renderPlain(trimmed)
        XCTAssertFalse(trimmedFrame.contains("OSCPAYLOAD"), "A from-zero replay must not render the OSC payload as visible text: \(trimmedFrame)")
        XCTAssertTrue(trimmedFrame.contains("NEWEST"), "The newest content after the OSC must survive the trim: \(trimmedFrame)")
    }

    // MARK: - Induction across successive trims

    func testStateSurvivesSuccessiveTrims() throws {
        let (url, handle) = try makeTranscriptFile()
        var payload = Self.decModePayload
        payload.append(lineFiller(prefix: "FIRST", minBytes: 8000).data)
        try handle.write(contentsOf: payload)

        var trim = try performTrim(
            outputPath: url.path, writeHandle: handle, currentEndOffset: UInt64(payload.count), columns: 80, rows: 24, triggerBytes: 4000,
            retainedBytes: 2000)

        // Append more filler to cross the trigger again, then trim a second time. The second trim's
        // head replay [0..cut] starts from the FIRST trim's preamble, so state must remain correct. All
        // appends and trims must flow through the adopted handle (each trim replaces the inode).
        let more = lineFiller(prefix: "SECOND", minBytes: 4000).data
        try trim.writeHandle.write(contentsOf: more)
        let endOffsetBeforeSecondTrim = trim.endOffset + UInt64(more.count)
        trim = try performTrim(
            outputPath: url.path, writeHandle: trim.writeHandle, currentEndOffset: endOffsetBeforeSecondTrim, columns: 80, rows: 24,
            triggerBytes: 4000, retainedBytes: 2000)
        addTeardownBlock { [writeHandle = trim.writeHandle] in try? writeHandle.close() }

        let restored = try replaySession(try Data(contentsOf: url))
        defer { spaces_ghostty_vt_session_free(restored) }
        XCTAssertTrue(modeIsSet(restored, 1049), "alt screen must survive two successive trims")
        XCTAssertTrue(modeIsSet(restored, 2004), "bracketed paste must survive two successive trims")
        XCTAssertTrue(modeIsSet(restored, 1006), "SGR mouse must survive two successive trims")
        XCTAssertTrue(modeIsSet(restored, 1), "DECCKM must survive two successive trims")
        XCTAssertTrue(String(decoding: try Data(contentsOf: url), as: UTF8.self).contains("SECOND"), "Newest content must survive the second trim.")
    }

    // MARK: - Failure safety (atomic replace)

    /// A trim that fails before the atomic rename must leave `output.log` byte-identical and the caller's
    /// ORIGINAL handle still valid at the original end. The failure is forced by making the transcript's
    /// directory read-only so the sibling temp file (`output.log.trim`) cannot be created — a
    /// deterministic seam that trips after the head/tail are read but before the rename. The pre-opened
    /// write handle keeps working because its descriptor was opened before the directory was locked, so
    /// this isolates "temp staging fails" from "the transcript is inaccessible".
    ///
    /// Red-first note: against the old in-place rewrite this seam would NOT throw — the old code created
    /// no temp file and wrote preamble+tail straight through the already-open descriptor, so a read-only
    /// directory left it free to rewrite the file. `XCTAssertThrowsError` plus the byte-identical
    /// assertion is exactly the atomic-replace contract the old code violated. (True crash-mid-rewrite
    /// injection is not practical in a unit test and is intentionally not attempted here.)
    func testFailedTrimLeavesOriginalIntactAndHandleUsable() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("output.log")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        addTeardownBlock {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
            try? handle.close()
            try? FileManager.default.removeItem(at: dir)
        }

        let filler = lineFiller(prefix: "SEQ", minBytes: 6000)
        try handle.write(contentsOf: filler.data)
        let before = try Data(contentsOf: url)

        // Lock the directory: the sibling temp file can no longer be created, so the trim throws before
        // it can rename anything over output.log.
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir.path)

        XCTAssertThrowsError(
            try performTrim(
                outputPath: url.path, writeHandle: handle, currentEndOffset: UInt64(filler.data.count), columns: 80, rows: 24, triggerBytes: 4000,
                retainedBytes: 2000), "A trim that cannot stage its temp file must throw, not rewrite output.log in place.")

        // The original transcript is byte-identical: the trim never touched it.
        XCTAssertEqual(try Data(contentsOf: url), before, "A failed trim must leave output.log byte-identical.")

        // Restore write access, then confirm the ORIGINAL handle still appends at the original end — the
        // trim never seeked or wrote it, so its position is exactly where the last append left it.
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        let appended = Data("AFTER-FAILURE\n".utf8)
        try handle.write(contentsOf: appended)
        let after = try Data(contentsOf: url)
        XCTAssertEqual(after.count, before.count + appended.count, "The original handle must append at the original end after a failed trim.")
        XCTAssertEqual(after.suffix(appended.count), appended)
        XCTAssertEqual(after.prefix(before.count), before, "A failed trim plus a later append must preserve every pre-existing byte.")
    }

    /// The successful-trim contract: appends through the RETURNED handle land immediately after the
    /// bounded content, and the on-disk file is exactly preamble+tail (no stale middle bytes from the
    /// pre-trim file, which the in-place rewrite risked leaving behind).
    func testSuccessfulTrimReplacesFileAndReturnedHandleAppendsAtEnd() throws {
        let (url, handle) = try makeTranscriptFile()
        let filler = lineFiller(prefix: "SEQ", minBytes: 6000)
        try handle.write(contentsOf: filler.data)

        let result = try performTrim(
            outputPath: url.path, writeHandle: handle, currentEndOffset: UInt64(filler.data.count), columns: 80, rows: 24, triggerBytes: 4000,
            retainedBytes: 2000)
        addTeardownBlock { [writeHandle = result.writeHandle] in try? writeHandle.close() }

        let trimmed = try Data(contentsOf: url)
        XCTAssertEqual(trimmed.count, Int(result.endOffset), "The replaced file's size must equal the reported end offset.")
        // The reported end offset is now COMPUTED (preamble.count + tail.count) rather than queried via
        // seekToEnd(), so pin it to both the on-disk file size and the adopted handle's actual write
        // position: all three must agree, or a subsequent append would land at the wrong offset.
        XCTAssertEqual(UInt64(trimmed.count), result.endOffset, "The computed end offset must equal the on-disk file size after the trim.")
        XCTAssertEqual(try result.writeHandle.offset(), result.endOffset, "The adopted handle must sit at the computed end offset, ready to append.")
        let (preamble, tail) = try splitPreambleAndTail(trimmed)
        XCTAssertEqual(trimmed, preamble + tail, "The replaced file must be exactly preamble+tail with no stale bytes from the pre-trim transcript.")

        let appended = Data("NEXT\n".utf8)
        try result.writeHandle.write(contentsOf: appended)
        let afterAppend = try Data(contentsOf: url)
        XCTAssertEqual(afterAppend, trimmed + appended, "An append through the returned handle must land exactly at the new end.")
    }

    /// The staged-then-committed split rests on `output.log` being strictly append-only while a trim
    /// stages — that is what makes the snapshotted prefix immutable and the delta copy complete. A
    /// transcript that is SHORTER at commit time violates that invariant, so the commit must refuse
    /// (leaving the original intact and the temp file discarded) rather than stitch the staged tail onto
    /// bytes that no longer follow it.
    func testCommitRefusesATranscriptThatShrankDuringStaging() throws {
        let (url, handle) = try makeTranscriptFile()
        let filler = lineFiller(prefix: "SEQ", minBytes: 6000)
        try handle.write(contentsOf: filler.data)

        let plan = try XCTUnwrap(
            TerminalTranscriptTrim.plan(outputPath: url.path, currentEndOffset: UInt64(filler.data.count), triggerBytes: 4000, retainedBytes: 2000))
        let staged = try TerminalTranscriptTrim.stage(outputPath: url.path, plan: plan, columns: 80, rows: 24)

        XCTAssertThrowsError(
            try TerminalTranscriptTrim.commit(staged, outputPath: url.path, currentEndOffset: plan.snapshotEndOffset - 1),
            "A commit against a shrunken transcript must refuse rather than publish a stitched file.")
        XCTAssertEqual(try Data(contentsOf: url), filler.data, "A refused commit must leave output.log byte-identical.")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path + ".trim"), "A refused commit must discard its temp file.")
    }
}
