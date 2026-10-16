import Foundation
import XCTest
import ghosttyvtshim

@testable import spacesterminalcore

final class TerminalLostShellSeedTests: XCTestCase {
    private let separator = "Shell ended when Spaces stopped unexpectedly \u{00B7} Oct 15, 9:24 PM \u{00B7} new shell below"

    private func writeTranscript(_ data: Data) throws -> String {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try data.write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url.path
    }

    /// A throwaway terminal that has been fed `data`, for asking which modes it ended up in.
    private final class ReplayedTerminal {
        private let session: OpaquePointer

        init(_ data: Data) throws {
            session = try XCTUnwrap(spaces_ghostty_vt_session_new(80, 24, 0, nil))
            XCTAssertTrue(data.withUnsafeBytes { spaces_ghostty_vt_session_write(session, $0.bindMemory(to: UInt8.self).baseAddress, $0.count) })
        }

        deinit { spaces_ghostty_vt_session_free(session) }

        func plainText() throws -> String {
            var pointer: UnsafeMutablePointer<CChar>?
            var length = 0
            XCTAssertTrue(spaces_ghostty_vt_session_format_plain(session, &pointer, &length))
            let buffer = try XCTUnwrap(pointer)
            defer { spaces_ghostty_vt_free_buffer(buffer) }
            return String(decoding: UnsafeRawBufferPointer(start: buffer, count: length), as: UTF8.self)
        }

        func modeIsSet(_ mode: UInt16) -> Bool {
            var isSet = false
            XCTAssertTrue(spaces_ghostty_vt_session_mode_is_set(session, mode, false, &isSet))
            return isSet
        }

        var kittyKeyboardFlags: UInt8 {
            var flags: UInt8 = 0xFF
            XCTAssertTrue(spaces_ghostty_vt_session_kitty_keyboard_flags(session, &flags))
            return flags
        }
    }

    func testSeedIsTheOldTranscriptThenTheClosingBlock() throws {
        let old = Data("old output\r\n$ ".utf8)
        let path = try writeTranscript(old)

        let seed = try TerminalLostShellSeed.build(transcriptPath: path, columns: 80, rows: 24, separator: separator)

        XCTAssertEqual(seed, old + TerminalLostShellSeed.closing(after: old, separator: separator))
    }

    func testClosingPutsTheFaintSeparatorOnItsOwnLineAfterTheModeReset() throws {
        let old = Data("output".utf8)
        let closing = String(decoding: TerminalLostShellSeed.closing(after: old, separator: separator), as: UTF8.self)

        XCTAssertTrue(closing.hasSuffix("\r\n\u{1B}[2m\(separator)\u{1B}[0m\r\n"))
        XCTAssertTrue(closing.hasPrefix(String(decoding: TerminalLostShellSeed.modeReset(after: old), as: UTF8.self)))
    }

    func testModeResetNeverClearsTheScreenOrScrollback() {
        let reset = String(decoding: TerminalLostShellSeed.modeReset(after: Data("\u{1B}[?1049h".utf8)), as: UTF8.self)

        // RIS (ESC c) and erase-display/scrollback (CSI 2J, CSI 3J) would destroy the history being kept.
        XCTAssertFalse(reset.contains("\u{1B}c"))
        XCTAssertFalse(reset.contains("\u{1B}[2J"))
        XCTAssertFalse(reset.contains("\u{1B}[3J"))
    }

    func testClosingLeavesTheOldLinesInPlaceAndPutsTheSeparatorBelowThem() throws {
        let old = Data("line one\r\nline two\r\nline three\r\n$ ".utf8)

        let screen = try ReplayedTerminal(old + TerminalLostShellSeed.closing(after: old, separator: separator)).plainText()

        let lines = screen.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        XCTAssertEqual(Array(lines.prefix(3)), ["line one", "line two", "line three"])
        XCTAssertEqual(lines[3].trimmingCharacters(in: CharacterSet.whitespaces), "$")
        XCTAssertEqual(lines[4], separator)
    }

    func testClosingAfterAFullScreenProgramReturnsToTheMainScreenUntouched() throws {
        let old = Data("main one\r\nmain two\r\n$ vim\r\n\u{1B}[?1049h\u{1B}[2J\u{1B}[HALT CONTENT".utf8)

        let screen = try ReplayedTerminal(old + TerminalLostShellSeed.closing(after: old, separator: separator)).plainText()

        XCTAssertFalse(screen.contains("ALT CONTENT"))
        let lines = screen.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        XCTAssertEqual(Array(lines.prefix(3)), ["main one", "main two", "$ vim"])
        XCTAssertTrue(lines.contains(separator))
    }

    func testAlternateScreenStateIsTheLastToggleInTheTranscript() {
        func endsInAlternate(_ text: String) -> Bool { TerminalLostShellSeed.alternateScreenMode(in: Data(text.utf8)) != nil }
        XCTAssertFalse(endsInAlternate("plain"))
        XCTAssertTrue(endsInAlternate("a\u{1B}[?1049h"))
        XCTAssertFalse(endsInAlternate("a\u{1B}[?1049h b \u{1B}[?1049l"))
        XCTAssertTrue(endsInAlternate("\u{1B}[?1049h\u{1B}[?1049l\u{1B}[?47h"))
        XCTAssertTrue(endsInAlternate("\u{1B}[?1047h"))
        XCTAssertFalse(endsInAlternate("\u{1B}[?1049h\u{1B}[?1047l"))
        XCTAssertTrue(endsInAlternate("\u{1B}[?25l\u{1B}[?1049;2004h"))
    }

    func testClosingTurnsOffWhatAFullScreenProgramLeftOn() throws {
        // A TUI that died without restoring the terminal: alternate screen, mouse tracking, bracketed
        // paste, application cursor keys, Kitty keyboard flags, hidden cursor, a scroll region.
        let leftovers = Data("\u{1B}[?1049h\u{1B}[?1000h\u{1B}[?1006h\u{1B}[?2004h\u{1B}[?1h\u{1B}[>31u\u{1B}[?25l\u{1B}[5;10r".utf8)
        let before = try ReplayedTerminal(leftovers)
        XCTAssertTrue(before.modeIsSet(2004))
        XCTAssertTrue(before.modeIsSet(1000))

        let after = try ReplayedTerminal(leftovers + TerminalLostShellSeed.closing(after: leftovers, separator: separator))

        for mode: UInt16 in [1049, 1000, 1006, 2004, 1] { XCTAssertFalse(after.modeIsSet(mode), "mode \(mode) is still set") }
        XCTAssertEqual(after.kittyKeyboardFlags, 0)
    }

    func testTranscriptLargerThanTheBudgetKeepsItsNewestBytesBehindAStatePreamble() throws {
        // Early bytes enable bracketed paste; the budget then drops them, so only the preamble can carry the mode.
        var old = Data("\u{1B}[?2004h".utf8)
        old.append(Data(repeating: UInt8(ascii: "x"), count: 4096))
        old.append(Data("\r\n\u{1B}[0mnewest line\r\n".utf8))
        let path = try writeTranscript(old)

        let seed = try TerminalLostShellSeed.build(transcriptPath: path, columns: 80, rows: 24, separator: separator, retainedBytes: 64)

        let closing = TerminalLostShellSeed.closing(after: old, separator: separator)
        let body = seed.dropLast(closing.count)
        XCTAssertTrue(String(decoding: body, as: UTF8.self).contains("newest line"))
        XCTAssertLessThan(body.count, old.count, "the dropped head must not be copied")
        XCTAssertTrue(seed.suffix(closing.count).elementsEqual(closing))
        // The preamble restores bracketed paste, then the closing block turns it back off.
        XCTAssertFalse(try ReplayedTerminal(seed).modeIsSet(2004))
        XCTAssertTrue(try ReplayedTerminal(Data(body)).modeIsSet(2004))
    }
}
