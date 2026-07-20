import Foundation
import ghosttyvtshim

/// Bounds a live session's durable `output.log` transcript so a long-running session stops growing
/// without bound, while keeping the file self-contained for a from-zero replay.
///
/// The suffix consumers of `output.log` are state-naive by design: `TerminalOutputTail` (CLI/tail
/// rendering) and the ended-pane scrollback replay both seek back from the end and render an
/// end-relative window, tolerating a partial leading sequence. Daemon handoff resume, however,
/// rebuilds the renderer by replaying the file from offset 0 (`recreateVTRenderer`), so it depends on
/// the file's HEAD carrying every state-establishing sequence (alt-screen enter, mouse reporting,
/// bracketed paste, DECCKM, Kitty keyboard flags, cursor position). A naive head-truncation would drop
/// those sequences and replay to the wrong terminal state.
///
/// To keep from-zero replay correct after a trim, `trimIfNeeded` synthesizes a state-restoration
/// PREAMBLE and writes it at the head of the retained tail. The preamble is derived by replaying the
/// pre-trim head `[0..cut]` through a throwaway vt session and serializing its resulting persistent
/// state (`spaces_ghostty_vt_session_state_preamble`): the terminal modes, Kitty keyboard flags, and
/// cursor position, plus a repaint of the active screen's visible grid so cells the dropped head drew
/// once (e.g. a static TUI header) that the retained tail never redraws survive the trim. This is
/// inductively correct across successive
/// trims: each trim's head replay `[0..cut]` itself starts from the previous trim's preamble, so the
/// serialized state always reflects the true accumulated state at the cut. The retained tail is copied
/// verbatim after the preamble, and its cut is newline-aligned so replay begins on a line boundary.
public enum TerminalTranscriptTrim {
    /// A `nil`/empty vt library, or a failure to build the preamble, aborts the trim (throws) rather
    /// than truncating without a preamble: an un-preambled from-zero replay would render the wrong
    /// state, and a vt install that cannot build a preamble cannot render the session anyway. The
    /// callers' `catch { return false }` simply skips this round; the next append retries.
    enum TrimError: Error {
        case vtSessionUnavailable
        case vtReplayFailed
        case preambleFailed
    }

    /// Upper bound on the forward newline scan used to align the cut to a line boundary. This is a
    /// bounded scan, not a fallback path: if no newline appears within this many bytes of the nominal
    /// offset, the cut falls back to the nominal offset (a mid-line cut, which the preamble + vt
    /// replay still tolerate). A megabyte is far larger than any realistic single terminal line, so
    /// the fallback effectively never engages outside adversarial newline-free spans.
    static let maxNewlineAlignScanBytes: UInt64 = 1 << 20

    private static let replayChunkBytes = 256 * 1024
    private static let newlineScanBlockBytes = 64 * 1024

    /// Bounds `output.log` in place when it exceeds
    /// `TerminalScrollbackBudget.liveTranscriptTrimTriggerBytes`, keeping the newest
    /// `TerminalScrollbackBudget.liveTranscriptRetainedBytes` behind a state preamble. Returns the
    /// transcript's new end offset, unchanged when no trim was needed. `columns`/`rows` are the
    /// session's current terminal size, used to build the preamble at the same grid the session
    /// replays at.
    @discardableResult
    public static func trimIfNeeded(outputPath: String, writeHandle: FileHandle, currentEndOffset: UInt64, columns: Int, rows: Int) throws -> UInt64 {
        try trimIfNeeded(
            outputPath: outputPath, writeHandle: writeHandle, currentEndOffset: currentEndOffset, columns: columns, rows: rows,
            triggerBytes: UInt64(TerminalScrollbackBudget.liveTranscriptTrimTriggerBytes),
            retainedBytes: UInt64(TerminalScrollbackBudget.liveTranscriptRetainedBytes))
    }

    /// Testable core with explicit bounds. `retainedBytes` must be `< triggerBytes`.
    ///
    /// `writeHandle` is the session core's sole append handle for the transcript (the session core runs
    /// on its main actor, so there is one writer). Transient read handles read the pre-trim head (to
    /// build the preamble) and the retained tail; the file is then rewritten as preamble + tail and
    /// truncated, and the write handle is left positioned at the new end so appends continue seamlessly.
    /// Readers open their own handles and read an end-relative window, so a concurrent read during the
    /// rare rewrite at worst returns a slightly shorter tail once.
    @discardableResult
    static func trimIfNeeded(
        outputPath: String, writeHandle: FileHandle, currentEndOffset: UInt64, columns: Int, rows: Int, triggerBytes: UInt64, retainedBytes: UInt64
    ) throws -> UInt64 {
        guard currentEndOffset > triggerBytes else { return currentEndOffset }
        let nominalStart = currentEndOffset - retainedBytes

        let readHandle = try FileHandle(forReadingFrom: URL(fileURLWithPath: outputPath))
        defer { try? readHandle.close() }

        let cutOffset = try newlineAlignedCutOffset(readHandle: readHandle, nominalStart: nominalStart, endOffset: currentEndOffset)
        let preamble = try statePreamble(outputPath: outputPath, cutOffset: cutOffset, columns: columns, rows: rows)

        try readHandle.seek(toOffset: cutOffset)
        let tail = try readHandle.read(upToCount: Int(currentEndOffset - cutOffset)) ?? Data()

        try writeHandle.seek(toOffset: 0)
        try writeHandle.write(contentsOf: preamble)
        try writeHandle.write(contentsOf: tail)
        let newEndOffset = UInt64(preamble.count + tail.count)
        try writeHandle.truncate(atOffset: newEndOffset)
        try writeHandle.seekToEnd()
        return newEndOffset
    }

    /// Scans forward from `nominalStart` for the next newline and returns the offset just past it, so
    /// the retained tail begins on a line boundary. Bounded by `maxNewlineAlignScanBytes`; if no
    /// newline is found within the bound (or before end of file), returns `nominalStart`.
    private static func newlineAlignedCutOffset(readHandle: FileHandle, nominalStart: UInt64, endOffset: UInt64) throws -> UInt64 {
        let scanLimit = min(nominalStart + maxNewlineAlignScanBytes, endOffset)
        try readHandle.seek(toOffset: nominalStart)
        var scanned = nominalStart
        while scanned < scanLimit {
            let toRead = Int(min(UInt64(newlineScanBlockBytes), scanLimit - scanned))
            let chunk = try readHandle.read(upToCount: toRead) ?? Data()
            if chunk.isEmpty { break }
            if let newlineIndex = chunk.firstIndex(of: 0x0A) {
                return scanned + UInt64(chunk.distance(from: chunk.startIndex, to: newlineIndex)) + 1
            }
            scanned += UInt64(chunk.count)
        }
        return nominalStart
    }

    /// Builds the state preamble by streaming `[0..cutOffset]` through a throwaway vt session (created
    /// at the session's grid with flat scrollback, since scrollback content is irrelevant to the state
    /// queries) and serializing its persistent terminal state.
    private static func statePreamble(outputPath: String, cutOffset: UInt64, columns: Int, rows: Int) throws -> Data {
        guard let session = spaces_ghostty_vt_session_new(UInt16(clamping: max(columns, 1)), UInt16(clamping: max(rows, 1)), 0, nil) else {
            throw TrimError.vtSessionUnavailable
        }
        defer { spaces_ghostty_vt_session_free(session) }

        let replayHandle = try FileHandle(forReadingFrom: URL(fileURLWithPath: outputPath))
        defer { try? replayHandle.close() }
        try replayHandle.seek(toOffset: 0)
        var remaining = cutOffset
        while remaining > 0 {
            let toRead = Int(min(UInt64(replayChunkBytes), remaining))
            let chunk = try replayHandle.read(upToCount: toRead) ?? Data()
            if chunk.isEmpty { break }
            remaining -= UInt64(chunk.count)
            let replayed = chunk.withUnsafeBytes { rawBuffer in
                spaces_ghostty_vt_session_write(session, rawBuffer.bindMemory(to: UInt8.self).baseAddress, rawBuffer.count)
            }
            guard replayed else { throw TrimError.vtReplayFailed }
        }

        var outputPointer: UnsafeMutablePointer<CChar>?
        var outputLength = 0
        guard spaces_ghostty_vt_session_state_preamble(session, &outputPointer, &outputLength), let outputPointer else {
            throw TrimError.preambleFailed
        }
        defer { spaces_ghostty_vt_free_buffer(outputPointer) }
        return Data(bytes: outputPointer, count: outputLength)
    }
}
