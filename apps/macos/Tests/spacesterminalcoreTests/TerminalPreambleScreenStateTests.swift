import Foundation
import Testing
import ghosttyvtshim

@testable import spacesterminalcore

/// The contract of the state preamble (`spaces_ghostty_vt_session_state_preamble`): for a byte stream S cut
/// at offset c, a terminal fed `preamble(S[0..<c]) + S[c...]` must lay out everything after the cut exactly
/// like a terminal fed all of S. These tests cover the state a replay that starts inside a full-screen
/// program depends on: the primary screen the alternate screen covers (and the cursor its exit restores),
/// each screen's saved cursor (DECSC), and custom tab stops.
///
/// Every assertion compares a replay against the host terminal that saw the whole stream, never against
/// literal expected bytes, so they pin product behavior and not the preamble's encoding.
@Suite struct TerminalPreambleScreenStateTests {
    private static let columns: UInt16 = 40
    private static let rows: UInt16 = 12

    private struct Screen: Equatable {
        var rows: [String]
        var cursorColumn: Int
        var cursorRow: Int
    }

    private func makeSession() throws -> OpaquePointer { try #require(spaces_ghostty_vt_session_new(Self.columns, Self.rows, 0, nil)) }

    private func write(_ session: OpaquePointer, _ text: String) {
        let data = Data(text.utf8)
        let ok = data.withUnsafeBytes { spaces_ghostty_vt_session_write(session, $0.bindMemory(to: UInt8.self).baseAddress, $0.count) }
        #expect(ok)
    }

    private func write(_ session: OpaquePointer, _ data: Data) {
        let ok = data.withUnsafeBytes { spaces_ghostty_vt_session_write(session, $0.bindMemory(to: UInt8.self).baseAddress, $0.count) }
        #expect(ok)
    }

    private func preamble(_ session: OpaquePointer) throws -> Data {
        var pointer: UnsafeMutablePointer<CChar>?
        var length = 0
        #expect(spaces_ghostty_vt_session_state_preamble(session, &pointer, &length))
        let bytes = try #require(pointer)
        defer { spaces_ghostty_vt_free_buffer(bytes) }
        return bytes.withMemoryRebound(to: UInt8.self, capacity: length) { Data(bytes: $0, count: length) }
    }

    private func screen(_ session: OpaquePointer) throws -> Screen {
        var snapshot = SpacesGhosttyVtSnapshot()
        try #require(spaces_ghostty_vt_session_copy_snapshot(session, &snapshot))
        defer { spaces_ghostty_vt_snapshot_free(&snapshot) }
        let columns = Int(snapshot.columns)
        let rowCount = Int(snapshot.rows)
        let cells = try #require(snapshot.cells)
        var lines: [String] = []
        for row in 0..<rowCount {
            var line = ""
            for column in 0..<columns {
                let codepoint = cells[row * columns + column].codepoint
                line.unicodeScalars.append(codepoint == 0 ? UnicodeScalar(0x20)! : (UnicodeScalar(codepoint) ?? UnicodeScalar(0x20)!))
            }
            lines.append(line)
        }
        return Screen(rows: lines, cursorColumn: Int(snapshot.cursor_column), cursorRow: Int(snapshot.cursor_row))
    }

    /// Feeds `head + tail` to a host terminal, and `preamble(head) + tail` to a fresh terminal, and
    /// returns both resulting screens. `head` is what the daemon had seen at the cut.
    private func hostAndReplay(head: String, tail: String) throws -> (host: Screen, replay: Screen) {
        let host = try makeSession()
        defer { spaces_ghostty_vt_session_free(host) }
        write(host, head)

        let bytes = try preamble(host)
        write(host, tail)

        let replayed = try makeSession()
        defer { spaces_ghostty_vt_session_free(replayed) }
        write(replayed, bytes)
        write(replayed, tail)

        return (try screen(host), try screen(replayed))
    }

    private func expectReplayMatchesHost(head: String, tail: String, _ message: Comment? = nil) throws {
        let (host, replay) = try hostAndReplay(head: head, tail: tail)
        #expect(replay.rows == host.rows, message)
        #expect(replay.cursorColumn == host.cursorColumn && replay.cursorRow == host.cursorRow, message)
    }

    /// A shell session on the primary screen: several output lines and a prompt, cursor left mid-row.
    private let shellHistory = "line one\r\nline two\r\nline three\r\nline four\r\nline five\r\n$ ls -la"

    // MARK: - Alternate screen entry modes

    /// The replay starts inside a full-screen program. When the program exits, the primary screen it
    /// covered must be back, and rows printed after the exit must land where the host printed them. The
    /// seam is the first screenful after the exit: a primary screen that came back blank, or a cursor the
    /// exit failed to restore, shows up as wrong rows there until a screenful of new output covers it.
    @Test func exitFromAlternateScreenEnteredWith1049RestoresPrimaryScreenAndCursor() throws {
        let head = shellHistory + "\u{1B}[?1049h\u{1B}[H\u{1B}[2Jvim buffer\u{1B}[5;3Hstatus line\u{1B}[2;7H"
        let tail = "\u{1B}[?1049l\r\ntail 0\r\ntail 1\r\ntail 2"
        try expectReplayMatchesHost(head: head, tail: tail, "1049 exit must restore the primary grid and the cursor the entry saved")
    }

    @Test func exitFromAlternateScreenEnteredWith1049FollowedByManyLinesStaysAligned() throws {
        let head = shellHistory + "\u{1B}[?1049h\u{1B}[H\u{1B}[2Jvim buffer\u{1B}[2;7H"
        let tail = "\u{1B}[?1049l" + (0..<14).map { "\r\nrow \($0)" }.joined()
        try expectReplayMatchesHost(head: head, tail: tail)
    }

    /// The 1049 save carries the origin mode in force at entry. A program that turns DECOM on (with a
    /// region) inside the run leaves the live mode different from the saved one; the exit must still
    /// restore the saved one, so a CUP after it is absolute rather than region-relative.
    @Test func exitFrom1049RestoresTheOriginModeSavedAtEntryNotTheLiveOne() throws {
        let head = shellHistory + "\u{1B}[?1049h\u{1B}[H\u{1B}[2Jvim\u{1B}[3;10r\u{1B}[?6h"
        let tail = "\u{1B}[?1049l\u{1B}[1;1HAFTER"
        try expectReplayMatchesHost(head: head, tail: tail, "exit must restore DECOM as it was at entry")
    }

    @Test func exitFromAlternateScreenEnteredWith1047RestoresPrimaryScreen() throws {
        let head = shellHistory + "\u{1B}[?1047h\u{1B}[H\u{1B}[2Jhtop\u{1B}[5;3Hstatus line\u{1B}[2;7H"
        let tail = "\u{1B}[?1047l\r\ntail 0\r\ntail 1\r\ntail 2"
        try expectReplayMatchesHost(head: head, tail: tail, "1047 exit must restore the primary grid; the cursor follows the alternate screen's")
    }

    @Test func exitFromAlternateScreenEnteredWith47RestoresPrimaryScreen() throws {
        let head = shellHistory + "\u{1B}[?47h\u{1B}[H\u{1B}[2Jhtop\u{1B}[5;3Hstatus line\u{1B}[2;7H"
        let tail = "\u{1B}[?47l\r\ntail 0\r\ntail 1\r\ntail 2"
        try expectReplayMatchesHost(head: head, tail: tail)
    }

    /// The alternate screen keeps its own contents across a toggle under 47: re-entering shows what the
    /// program last drew there, so a replay that starts inside the run must carry the alternate grid.
    @Test func alternateScreenContentSurvivesAToggleAfterTheCut() throws {
        let head = shellHistory + "\u{1B}[?47h\u{1B}[H\u{1B}[2Jvim buffer\u{1B}[5;3Hstatus line"
        let tail = "\u{1B}[?47l\r\nback on primary\u{1B}[?47h"
        try expectReplayMatchesHost(head: head, tail: tail)
    }

    @Test func cutOutsideAnyAlternateScreenRunIsUnchanged() throws {
        let head = shellHistory + "\u{1B}[?1049h\u{1B}[H\u{1B}[2Jvim buffer\u{1B}[?1049l$ "
        let tail = "echo done\r\ndone"
        try expectReplayMatchesHost(head: head, tail: tail)
    }

    // MARK: - Saved cursor (DECSC)

    @Test func savedCursorOnThePrimaryScreenSurvivesTheCut() throws {
        let head = "\u{1B}[4;6H\u{1B}7\u{1B}[1;1Hheader"
        let tail = "\u{1B}[8;1Hlater\u{1B}8SAVED"
        try expectReplayMatchesHost(head: head, tail: tail, "DECRC after the cut must return to the cell DECSC saved before it")
    }

    @Test func savedCursorOnThePrimaryScreenSurvivesACutInsideAnAlternateScreenRun() throws {
        let head = shellHistory + "\u{1B}[3;9H\u{1B}7\u{1B}[?1047h\u{1B}[H\u{1B}[2Jhtop"
        let tail = "\u{1B}[?1047l\u{1B}8SAVED"
        try expectReplayMatchesHost(head: head, tail: tail)
    }

    @Test func savedCursorOnTheAlternateScreenSurvivesTheCut() throws {
        let head = shellHistory + "\u{1B}[?1049h\u{1B}[H\u{1B}[2Jvim\u{1B}[6;4H\u{1B}7\u{1B}[1;1H"
        let tail = "\u{1B}8SAVED"
        try expectReplayMatchesHost(head: head, tail: tail)
    }

    // MARK: - Tab stops

    @Test func customTabStopsSurviveTheCut() throws {
        // Clear every stop, then set stops at columns 5 and 12 (0-indexed 4 and 11).
        let head = "\u{1B}[3g\u{1B}[1;5H\u{1B}H\u{1B}[1;12H\u{1B}H\u{1B}[2;1H"
        let tail = "a\tb\tc\r\nd\te\tf"
        try expectReplayMatchesHost(head: head, tail: tail, "tabs after the cut must stop at the custom columns")
    }

    @Test func customTabStopsSurviveACutInsideAnAlternateScreenRun() throws {
        let head = "\u{1B}[3g\u{1B}[1;4H\u{1B}H\u{1B}[1;20H\u{1B}H\u{1B}[?1049h\u{1B}[H"
        let tail = "x\ty\tz\u{1B}[?1049l\r\nq\tr"
        try expectReplayMatchesHost(head: head, tail: tail)
    }

    @Test func defaultTabStopsStayDefault() throws { try expectReplayMatchesHost(head: "hello", tail: "\r\na\tb\tc") }
}
