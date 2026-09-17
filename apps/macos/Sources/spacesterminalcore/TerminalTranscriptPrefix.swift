import Foundation
import ghosttyvtshim

/// Cutting a session's `output.log` so the bytes after the cut replay to the right screen.
///
/// Two consumers need exactly this, for the same reason: the head-trim that bounds a live transcript
/// (`TerminalTranscriptTrim`) and the `terminalTranscript` Device API command, which serves a client a
/// suffix of a transcript too large to send whole. In both cases the bytes handed on start somewhere in
/// the middle of the file, and both correctness problems are the same. The cut must land where the VT
/// parser can pick up (`parserSafeCutOffset`), and the terminal state the dropped head established
/// (modes, Kitty flags, scrolling region, charsets, cursor position, and the visible grid the head painted
/// once) must be restored ahead of it (`statePreamble`), or the replay renders a wrong screen rather than
/// a merely shorter one.
public enum TerminalTranscriptPrefix {
    public enum PrefixError: Error, Equatable {
        /// No vt session could be created, so no preamble can be built.
        case vtSessionUnavailable
        /// The head replay that the preamble is derived from failed mid-stream.
        case vtReplayFailed
        /// The vt session refused to serialize its state.
        case preambleFailed
    }

    /// Upper bound on the forward scan used to find a parser-safe cut. The scan prefers the offset just
    /// before the window's first ESC byte (parser-safe from any state); only when the window holds no ESC
    /// at all does it fall back to the offset just past the first newline (see `parserSafeCutOffset`), and
    /// only when the window has neither an ESC nor a newline does it report no safe cut at all. A megabyte
    /// is far larger than any realistic escape sequence or terminal line, so an ESC-free, LF-free scan
    /// window is already the adversarial case (an oversized single-sequence payload); this bound just caps
    /// how far the scan looks before conceding to the newline fallback or, failing that, to nothing.
    public static let maxParserSafeCutScanBytes: UInt64 = 1 << 20

    private static let replayChunkBytes = 256 * 1024
    private static let scanBlockBytes = 64 * 1024

    /// Scans forward from `nominalStart` for a parser-safe cut and returns it, or `nil` when the bounded
    /// window holds none. Bounded by `maxParserSafeCutScanBytes`.
    ///
    /// The cut must land on a boundary that is parser-safe from EVERY possible original parser state, or
    /// the retained tail starts mid-sequence and a replay (which begins in ground state after the
    /// preamble) renders those bytes as garbage: the preamble serializes terminal *state*, not
    /// mid-sequence *parser* state. The offset immediately before the window's first ESC (0x1B) byte is
    /// such a boundary by construction, so it is PREFERRED whenever the window holds any ESC: ESC is
    /// always < 0x80 so it can never sit inside a UTF-8 continuation byte, and if the parser was mid-string
    /// (OSC/DCS/APC) when it reached that ESC, the ESC is the start of that string's `ESC \` ST terminator,
    /// which in ground-state replay is a harmless no-op, after which the stream is clean. The head
    /// ending just before that ESC at worst leaves an unterminated sequence dangling in the throwaway
    /// preamble replay, which is simply never applied there (also harmless).
    ///
    /// Line alignment is NOT preferred, because a cut just past a newline is only parser-safe when that
    /// newline was processed in ground state: an LF inside an OSC string is swallowed (Ghostty's parser
    /// exits `osc_string` only on BEL/ESC/CAN/SUB), and likewise inside DCS passthrough, so a cut just
    /// past such an LF starts the retained tail mid-payload and the replay renders the payload bytes as
    /// visible text. Whether a given LF sat in ground state is unknowable without replaying, so the
    /// past-newline offset is used ONLY as a fallback for windows that contain no ESC at all (i.e.
    /// plain-text regions, where an open OSC/DCS would have to span the entire scan window without its
    /// terminator). Line alignment is thereby sacrificed for ESC-bearing windows: the retained tail may
    /// start mid-line (e.g. right at an SGR). That is cosmetic: the preamble ahead of it establishes the
    /// state, and a mid-line start costs at most the oldest partial line.
    ///
    /// When the window contains neither an ESC nor a newline (a single sequence or plain-text run longer
    /// than the scan bound, e.g. a multi-megabyte DCS/OSC payload (sixel, iTerm2 inline image, OSC 52) or
    /// an LF-free UTF-8 text run), every candidate cut lands mid-sequence or mid-codepoint, so no
    /// preamble could rescue it. This returns `nil`; what to do then is the caller's decision (the trim
    /// defers to a later append, the transcript command cuts at the nominal start and lets the parser
    /// resynchronize). A residual the byte scan cannot close: a window that BEGINS inside an OSC whose
    /// payload holds a raw newline before a bare-BEL (or CAN/SUB) terminator contains no ESC at all, so
    /// the newline cut lands inside the payload even though the sequence terminates within the window.
    /// BEL ends an OSC but is inert data inside DCS passthrough, so terminator ordering proves nothing
    /// without parser state; the sound fix (validating the cut against parser ground state during the
    /// preamble replay) is tracked in issue #225.
    ///
    /// Single pass: the first newline offset is remembered while scanning for the first ESC rather than
    /// re-reading the window to find it separately.
    public static func parserSafeCutOffset(readHandle: FileHandle, nominalStart: UInt64, endOffset: UInt64) throws -> UInt64? {
        let scanLimit = min(nominalStart + maxParserSafeCutScanBytes, endOffset)
        try readHandle.seek(toOffset: nominalStart)
        var scanned = nominalStart
        var firstNewlineOffset: UInt64?
        while scanned < scanLimit {
            let toRead = Int(min(UInt64(scanBlockBytes), scanLimit - scanned))
            let chunk = try readHandle.read(upToCount: toRead) ?? Data()
            if chunk.isEmpty { break }
            if let escIndex = chunk.firstIndex(of: 0x1B) { return scanned + UInt64(chunk.distance(from: chunk.startIndex, to: escIndex)) }
            if firstNewlineOffset == nil, let newlineIndex = chunk.firstIndex(of: 0x0A) {
                firstNewlineOffset = scanned + UInt64(chunk.distance(from: chunk.startIndex, to: newlineIndex)) + 1
            }
            scanned += UInt64(chunk.count)
        }
        return firstNewlineOffset
    }

    /// Builds the state preamble by streaming `[0..cutOffset]` through a throwaway vt session (created
    /// at the session's grid with flat scrollback, since scrollback content is irrelevant to the state
    /// queries, and it is what bounds the formatting the shim runs to read the state the terminal
    /// exposes no getter for) and serializing its persistent terminal state. This is the expensive part
    /// of both callers (about 55 ms for a 20 MB head on an M-series Mac) and is why neither runs it on a
    /// shared actor or queue; the throwaway session owns its own dlopen'd symbols and terminal, sharing
    /// nothing with the live session's renderer.
    ///
    /// The replay starts at offset 0 because that is where a full state preamble begins: a fresh
    /// transcript's blank terminal, or the head preamble a previous trim wrote. That is what makes
    /// successive trims, and a transcript read of an already-trimmed file, inductively correct.
    ///
    /// The head is read through the caller's own open handle rather than by reopening the transcript's
    /// path: a trim replaces `output.log` with a fresh inode, so a reopen between the caller's tail read
    /// and this replay would build the preamble from a different file than the tail it prefixes. The
    /// handle is left wherever the replay stopped reading, so callers seek before reading through it
    /// again.
    public static func statePreamble(readHandle: FileHandle, cutOffset: UInt64, columns: Int, rows: Int) throws -> Data {
        guard let session = spaces_ghostty_vt_session_new(UInt16(clamping: max(columns, 1)), UInt16(clamping: max(rows, 1)), 0, nil) else {
            throw PrefixError.vtSessionUnavailable
        }
        defer { spaces_ghostty_vt_session_free(session) }

        try readHandle.seek(toOffset: 0)
        var remaining = cutOffset
        while remaining > 0 {
            let toRead = Int(min(UInt64(replayChunkBytes), remaining))
            let chunk = try readHandle.read(upToCount: toRead) ?? Data()
            if chunk.isEmpty { break }
            remaining -= UInt64(chunk.count)
            let replayed = chunk.withUnsafeBytes { rawBuffer in
                spaces_ghostty_vt_session_write(session, rawBuffer.bindMemory(to: UInt8.self).baseAddress, rawBuffer.count)
            }
            guard replayed else { throw PrefixError.vtReplayFailed }
        }

        var outputPointer: UnsafeMutablePointer<CChar>?
        var outputLength = 0
        guard spaces_ghostty_vt_session_state_preamble(session, &outputPointer, &outputLength), let outputPointer else {
            throw PrefixError.preambleFailed
        }
        defer { spaces_ghostty_vt_free_buffer(outputPointer) }
        return Data(bytes: outputPointer, count: outputLength)
    }
}
