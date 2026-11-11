import Foundation

/// The bytes a replacement shell's session starts from: the lost shell's transcript, a terminal-mode
/// reset, and the separator line. They are written to the new session's `output.log` and replayed into its
/// surface, so the file keeps replaying to the live screen.
public enum TerminalLostShellSeed {
    /// Undoes whatever the lost shell's program left switched on, so the new prompt behaves like a fresh
    /// terminal's. RIS is deliberately not used: it clears the screen and scrollback, which is the history
    /// being kept. Each reset is a mode a full-screen program or shell integration commonly sets and never
    /// restores when the process dies:
    /// - leaves the alternate screen only when the transcript ended inside it, by the mode that entered it
    ///   (`?1049l` restores the saved cursor, which on the main screen would move it to wherever an
    ///   unrelated save left it);
    /// - stops mouse tracking, focus events, bracketed paste, synchronized output and in-band size reports;
    /// - sets Kitty keyboard flags to zero;
    /// - shows the cursor, resets application cursor keys, insert mode and the keypad, turns autowrap on;
    /// - resets the scroll region and left/right margins, bracketed by DECSC/DECRC because both home the
    ///   cursor;
    /// - resets SGR attributes and the G0/G1 charsets after that restore, since DECRC would bring the old
    ///   ones back.
    ///
    /// Origin mode is left alone: resetting it homes the cursor and DECRC would restore the old value
    /// anyway, and with the full-screen scroll region it behaves exactly like absolute addressing.
    static func modeReset(after transcript: Data) -> Data {
        let escape = "\u{1B}"
        var sequences: [String] = []
        if let alternateMode = alternateScreenMode(in: transcript) { sequences.append("\(escape)[?\(alternateMode)l") }
        sequences += [1000, 1002, 1003, 1004, 1005, 1006, 1015, 1016, 2004, 2026, 2048, 1].map { "\(escape)[?\($0)l" }
        sequences += [
            "\(escape)[?7h", "\(escape)[?25h", "\(escape)[=0;1u", "\(escape)[4l", "\(escape)>", "\(escape)7", "\(escape)[?69l", "\(escape)[r",
            "\(escape)8", "\(escape)[0m", "\(escape)(B", "\(escape))B", "\u{0F}",
        ]
        return Data(sequences.joined().utf8)
    }

    /// The alternate-screen mode (47, 1047 or 1049) the transcript last switched on and never switched
    /// off, or nil when it ended on the main screen. Mode lists such as `CSI ? 1049 ; 2004 h` count.
    static func alternateScreenMode(in transcript: Data) -> Int? {
        let alternateModes: Set<Int> = [47, 1047, 1049]
        let bytes = [UInt8](transcript)
        var current: Int?
        var index = 0
        while index + 2 < bytes.count {
            // CSI ? Pm ; ... (h | l)
            guard bytes[index] == 0x1B, bytes[index + 1] == UInt8(ascii: "["), bytes[index + 2] == UInt8(ascii: "?") else {
                index += 1
                continue
            }
            var cursor = index + 3
            var parameters: [Int] = []
            var number = 0
            var hasDigits = false
            while cursor < bytes.count {
                let byte = bytes[cursor]
                if byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9") {
                    number = min(number * 10 + Int(byte - UInt8(ascii: "0")), 1_000_000)
                    hasDigits = true
                } else if byte == UInt8(ascii: ";") {
                    if hasDigits { parameters.append(number) }
                    number = 0
                    hasDigits = false
                } else {
                    break
                }
                cursor += 1
            }
            if hasDigits { parameters.append(number) }
            if cursor < bytes.count, bytes[cursor] == UInt8(ascii: "h") || bytes[cursor] == UInt8(ascii: "l") {
                let isSet = bytes[cursor] == UInt8(ascii: "h")
                for parameter in parameters where alternateModes.contains(parameter) { current = isSet ? parameter : nil }
            }
            index = max(cursor, index + 1)
        }
        return current
    }

    /// What follows the old transcript: the mode reset, then the separator on a line of its own, then a
    /// fresh line for the new prompt. The separator is faint so it reads as a divider and not as output.
    static func closing(after transcript: Data, separator: String) -> Data {
        var data = modeReset(after: transcript)
        data.append(Data("\r\n\u{1B}[2m\(separator)\u{1B}[0m\r\n".utf8))
        return data
    }

    /// Reads the lost shell's `output.log` and returns the full seed.
    ///
    /// A transcript larger than `retainedBytes` is cut where the VT parser can resume and prefixed with the
    /// state the dropped head established, the same cut a live transcript trim makes, so the seed replays to
    /// the screen the whole file would have. A window with no parser-safe boundary is cut at its nominal
    /// start and the parser resynchronizes, which costs at most one garbled leading line.
    ///
    /// `columns` and `rows` size the throwaway session the preamble is derived from.
    public static func build(
        transcriptPath: String, columns: Int, rows: Int, separator: String,
        retainedBytes: UInt64 = UInt64(TerminalScrollbackBudget.liveTranscriptRetainedBytes)
    ) throws -> Data {
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: transcriptPath))
        defer { try? handle.close() }
        let endOffset = try handle.seekToEnd()
        var seed = Data()
        if endOffset <= retainedBytes {
            try handle.seek(toOffset: 0)
            seed = try handle.readToEnd() ?? Data()
        } else {
            let nominalStart = endOffset - retainedBytes
            let cutOffset =
                try TerminalTranscriptPrefix.parserSafeCutOffset(readHandle: handle, nominalStart: nominalStart, endOffset: endOffset) ?? nominalStart
            seed = try TerminalTranscriptPrefix.statePreamble(readHandle: handle, cutOffset: cutOffset, columns: columns, rows: rows)
            try handle.seek(toOffset: cutOffset)
            seed.append(try handle.readToEnd() ?? Data())
        }
        seed.append(closing(after: seed, separator: separator))
        return seed
    }
}
