import Foundation
import ghosttyvtshim

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

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
///
/// A trim never mutates `output.log` in place. It writes preamble+tail to a sibling temp file
/// (`output.log.trim`), fsyncs it, then atomically `rename(2)`s it over `output.log`. A daemon crash or
/// a thrown write error therefore never leaves a half-rewritten transcript: either the original file is
/// fully intact (rename never ran) or the new bounded file is fully in place (rename committed). Because
/// the rename swaps in a fresh inode, the caller's previous append handle points at the unlinked old
/// inode and must be replaced — `trimIfNeeded` opens and returns a fresh handle for the caller to adopt.
public enum TerminalTranscriptTrim {
    /// A `nil`/empty vt library, or a failure to build the preamble, aborts the trim (throws) rather
    /// than truncating without a preamble: an un-preambled from-zero replay would render the wrong
    /// state, and a vt install that cannot build a preamble cannot render the session anyway. The
    /// callers' `catch { return false }` simply skips this round; the next append retries.
    enum TrimError: Error {
        case vtSessionUnavailable
        case vtReplayFailed
        case preambleFailed
        /// The atomic same-volume `rename(2)` of the fully-written temp file over `output.log` failed
        /// (carries `errno`). Thrown after the temp file is written but before the original is replaced,
        /// so the original transcript and the caller's append handle are untouched.
        case atomicReplaceFailed(errno: Int32)
    }

    /// The outcome of a (possibly no-op) trim: the transcript's new end offset and the write handle the
    /// caller must use for subsequent appends.
    ///
    /// A trim replaces `output.log` with a fresh inode (see `trimIfNeeded`), so the caller's previous
    /// handle points at the now-unlinked old inode and must be discarded. `writeHandle` is that fresh
    /// handle, positioned at the new end. When no trim is performed it is the caller's original handle,
    /// returned unchanged (identity-comparable with `===`), and `endOffset` is the unchanged end offset.
    public struct TrimResult {
        public let endOffset: UInt64
        public let writeHandle: FileHandle
    }

    /// Upper bound on the forward newline scan used to align the cut to a line boundary. This is a
    /// bounded scan, not a fallback path: if no newline appears within this many bytes of the nominal
    /// offset, the cut falls back to the offset just before the first ESC byte in the window (see
    /// `newlineAlignedCutOffset`), and only when the window has neither does it fall back to the nominal
    /// offset itself. A megabyte is far larger than any realistic single terminal line, so an LF-free scan
    /// window is already the adversarial case (a long alt-screen TUI redraw run); this bound just caps how
    /// far the scan looks before conceding to one of those fallbacks, it does not claim they never engage.
    static let maxNewlineAlignScanBytes: UInt64 = 1 << 20

    private static let replayChunkBytes = 256 * 1024
    private static let newlineScanBlockBytes = 64 * 1024

    /// Bounds `output.log` when it exceeds `TerminalScrollbackBudget.liveTranscriptTrimTriggerBytes`,
    /// keeping the newest `TerminalScrollbackBudget.liveTranscriptRetainedBytes` behind a state preamble.
    /// Returns the transcript's new end offset and the write handle to append through from now on (see
    /// `TrimResult`). When no trim was needed both are the caller's unchanged offset and handle.
    /// `columns`/`rows` are the session's current terminal size, used to build the preamble at the same
    /// grid the session replays at.
    @discardableResult
    public static func trimIfNeeded(outputPath: String, writeHandle: FileHandle, currentEndOffset: UInt64, columns: Int, rows: Int) throws
        -> TrimResult
    {
        try trimIfNeeded(
            outputPath: outputPath, writeHandle: writeHandle, currentEndOffset: currentEndOffset, columns: columns, rows: rows,
            triggerBytes: UInt64(TerminalScrollbackBudget.liveTranscriptTrimTriggerBytes),
            retainedBytes: UInt64(TerminalScrollbackBudget.liveTranscriptRetainedBytes))
    }

    /// Testable core with explicit bounds. `retainedBytes` must be `< triggerBytes`.
    ///
    /// The trim is failure-safe: it never mutates the live `output.log` in place. Transient read handles
    /// read the pre-trim head (to build the preamble) and the retained tail; preamble+tail is then
    /// written to a sibling temp file, fsynced, and atomically `rename(2)`d over `output.log`, replacing
    /// it with a fresh inode. On ANY error before the rename — a failed temp write (disk full), a preamble
    /// failure, or a crash — the original file and the caller's `writeHandle` are untouched, so the
    /// caller's catch-and-continue simply retries on the next append. The passed `writeHandle` is never
    /// seeked or written by this function, so the caller's append position stays valid on failure.
    ///
    /// On success the rename unlinks the old inode `writeHandle` still points at, so the caller MUST adopt
    /// the returned `TrimResult.writeHandle` (a fresh handle on the replaced file, positioned at the new
    /// end) and discard its old one. When no trim is performed the caller's original handle is returned
    /// unchanged.
    @discardableResult
    static func trimIfNeeded(
        outputPath: String, writeHandle: FileHandle, currentEndOffset: UInt64, columns: Int, rows: Int, triggerBytes: UInt64, retainedBytes: UInt64
    ) throws -> TrimResult {
        guard currentEndOffset > triggerBytes else { return TrimResult(endOffset: currentEndOffset, writeHandle: writeHandle) }
        let nominalStart = currentEndOffset - retainedBytes

        let readHandle = try FileHandle(forReadingFrom: URL(fileURLWithPath: outputPath))
        defer { try? readHandle.close() }

        let cutOffset = try newlineAlignedCutOffset(readHandle: readHandle, nominalStart: nominalStart, endOffset: currentEndOffset)
        let preamble = try statePreamble(outputPath: outputPath, cutOffset: cutOffset, columns: columns, rows: rows)

        try readHandle.seek(toOffset: cutOffset)
        let tail = try readHandle.read(upToCount: Int(currentEndOffset - cutOffset)) ?? Data()

        // Stage preamble+tail into a sibling temp file, then atomically rename it over output.log. The
        // temp path is a fixed sibling (not a unique name), created/truncated fresh each time so a stale
        // leftover from a crashed earlier attempt is simply overwritten; no leftover-scan recovery is
        // needed. It sits in the SAME directory as output.log so the rename is a same-volume operation
        // (atomic on APFS and ext4). fsync before the rename guarantees the data is durable before the
        // directory entry flips, so a crash can never surface a renamed-but-empty file.
        let tempPath = outputPath + ".trim"
        _ = FileManager.default.createFile(atPath: tempPath, contents: nil)
        let tempHandle = try FileHandle(forWritingTo: URL(fileURLWithPath: tempPath))
        do {
            try tempHandle.write(contentsOf: preamble)
            try tempHandle.write(contentsOf: tail)
            try tempHandle.synchronize()
            try tempHandle.close()
        } catch {
            try? tempHandle.close()
            throw error
        }

        // Atomic same-volume rename. POSIX rename(2) atomically replaces the destination; readers see
        // either the old or the new file, never a partial one. Chosen over FileManager.replaceItemAt
        // because it is the simplest call that is truly atomic on both APFS (macOS) and ext4 (Linux) and
        // is identical on both platforms via Darwin/Glibc.
        let renamed = tempPath.withCString { tempC in outputPath.withCString { outC in rename(tempC, outC) } }
        guard renamed == 0 else {
            let renameErrno = errno
            try? FileManager.default.removeItem(atPath: tempPath)
            throw TrimError.atomicReplaceFailed(errno: renameErrno)
        }

        // The old inode is now unlinked; open a fresh handle on the replaced file for the caller to adopt.
        let newHandle = try FileHandle(forWritingTo: URL(fileURLWithPath: outputPath))
        let newEndOffset = try newHandle.seekToEnd()
        return TrimResult(endOffset: newEndOffset, writeHandle: newHandle)
    }

    /// Scans forward from `nominalStart` for the next newline and returns the offset just past it, so the
    /// retained tail begins on a line boundary. Bounded by `maxNewlineAlignScanBytes`.
    ///
    /// A line boundary is preferred, but any cut must land on a parser-safe boundary or the retained tail
    /// starts mid-sequence and a from-zero replay renders those bytes as garbage (the preamble serializes
    /// terminal *state*, not mid-sequence *parser* state). If no newline turns up within the bound, the
    /// cut falls back to the offset immediately before the first ESC (0x1B) byte seen while scanning:
    /// ESC is always < 0x80, so it can never sit inside a UTF-8 continuation byte, and a tail beginning at
    /// ESC starts a clean escape sequence from the ground state. The head ending just before that ESC at
    /// worst leaves an unterminated escape/string sequence dangling in the throwaway preamble replay,
    /// which is simply never applied there — harmless. Only when the window contains neither a newline
    /// nor an ESC (essentially impossible for the control-heavy streams — alt-screen TUIs — that actually
    /// trigger this bounded-scan fallback) does the cut fall back to `nominalStart` itself, an arbitrary
    /// byte that the caller must otherwise avoid.
    ///
    /// Single pass: the first ESC offset is remembered while scanning for the newline rather than
    /// re-reading the window to find it separately.
    private static func newlineAlignedCutOffset(readHandle: FileHandle, nominalStart: UInt64, endOffset: UInt64) throws -> UInt64 {
        let scanLimit = min(nominalStart + maxNewlineAlignScanBytes, endOffset)
        try readHandle.seek(toOffset: nominalStart)
        var scanned = nominalStart
        var firstEscOffset: UInt64?
        while scanned < scanLimit {
            let toRead = Int(min(UInt64(newlineScanBlockBytes), scanLimit - scanned))
            let chunk = try readHandle.read(upToCount: toRead) ?? Data()
            if chunk.isEmpty { break }
            if let newlineIndex = chunk.firstIndex(of: 0x0A) {
                return scanned + UInt64(chunk.distance(from: chunk.startIndex, to: newlineIndex)) + 1
            }
            if firstEscOffset == nil, let escIndex = chunk.firstIndex(of: 0x1B) {
                firstEscOffset = scanned + UInt64(chunk.distance(from: chunk.startIndex, to: escIndex))
            }
            scanned += UInt64(chunk.count)
        }
        return firstEscOffset ?? nominalStart
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
