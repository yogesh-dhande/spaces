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
/// To keep from-zero replay correct after a trim, a trim synthesizes a state-restoration PREAMBLE and
/// writes it at the head of the retained tail. The preamble is derived by replaying the pre-trim head
/// `[0..cut]` through a throwaway vt session and serializing its resulting persistent state
/// (`spaces_ghostty_vt_session_state_preamble`): the terminal modes, Kitty keyboard flags, and cursor
/// position, plus a repaint of the active screen's visible grid so cells the dropped head drew once
/// (e.g. a static TUI header) that the retained tail never redraws survive the trim. This is
/// inductively correct across successive trims: each trim's head replay `[0..cut]` itself starts from
/// the previous trim's preamble, so the serialized state always reflects the true accumulated state at
/// the cut. The retained tail is copied verbatim after the preamble, and its cut lands just before the
/// window's first ESC byte — a boundary that is parser-safe from any original parser state (see
/// `parserSafeCutOffset`) — falling back to a line boundary only in escape-free windows.
///
/// ## Three stages, only two of them on the engine actor
/// The head replay dominates the cost (~150 ms for a standard-policy trim), so a trim is split so that
/// only cheap work runs on the shared `TerminalEngineActor` that every session's PTY output, input,
/// control requests, and state broadcasts share. `TerminalTranscriptTrimCoordinator` drives the three
/// stages and serializes them per session:
///  1. `plan` (engine actor): decide whether to trim and snapshot the cut offset plus the transcript's
///     current end. Bounded reads only — the trigger check costs nothing and the parser-safe scan is
///     capped at `maxParserSafeCutScanBytes`.
///  2. `stage` (off the engine actor): replay the retained prefix `[0..cut]` to build the preamble and
///     copy the retained tail `[cut..snapshotEnd]` into the temp file. Appends keep landing on the OLD
///     inode throughout; because appends are strictly append-only, every byte below `snapshotEnd` is
///     immutable, so the staged snapshot is correct by construction no matter how much the session
///     writes meanwhile.
///  3. `commit` (engine actor): copy the append delta written since the snapshot, fsync, and rename the
///     temp file over `output.log`. Runs without suspending, so no append can interleave between
///     reading the delta and the rename.
///
/// A trim never mutates `output.log` in place. It writes preamble+tail to a sibling temp file
/// (`output.log.trim`), fsyncs it, then atomically `rename(2)`s it over `output.log`. A daemon crash or
/// a thrown write error therefore never leaves a half-rewritten transcript: either the original file is
/// fully intact (rename never ran) or the new bounded file is fully in place (rename committed). Because
/// the rename swaps in a fresh inode, the caller's previous append handle points at the unlinked old
/// inode and must be replaced. Rather than reopening the replaced file (a fallible call after the swap
/// has already committed), `commit` keeps the temp file's write handle OPEN across the rename —
/// POSIX `rename(2)` does not disturb open descriptors, so that handle keeps referencing the same inode,
/// now reachable as `output.log`, already positioned at the end of the written data — and returns it for
/// the caller to adopt. There is thus no fallible step after the swap commits.
enum TerminalTranscriptTrim {
    /// A `nil`/empty vt library, or a failure to build the preamble, aborts the trim (throws) rather
    /// than truncating without a preamble: an un-preambled from-zero replay would render the wrong
    /// state, and a vt install that cannot build a preamble cannot render the session anyway. The
    /// coordinator simply skips this round; the next append past the trigger re-evaluates.
    enum TrimError: Error {
        case vtSessionUnavailable
        case vtReplayFailed
        case preambleFailed
        /// The transcript is shorter at commit time than the end offset the staging stage snapshotted.
        /// The split relies on `output.log` being strictly append-only between `plan` and `commit`, so
        /// this is an invariant violation, not a race to tolerate: the staged tail would be stitched to
        /// bytes that no longer follow it. Thrown before the rename, so the original file survives.
        case transcriptShrankDuringStaging
        /// The atomic same-volume `rename(2)` of the fully-written temp file over `output.log` failed
        /// (carries `errno`). Thrown after the temp file is written but before the original is replaced,
        /// so the original transcript and the caller's append handle are untouched.
        case atomicReplaceFailed(errno: Int32)
    }

    /// What a trim will retain, decided on the engine actor from a single point-in-time view of the
    /// transcript. Both offsets are into the PRE-trim `output.log`.
    struct TrimPlan: Sendable {
        /// First retained byte: a parser-safe boundary (see `parserSafeCutOffset`).
        let cutOffset: UInt64
        /// The transcript's end when the plan was taken. Everything below it is immutable (appends are
        /// append-only), which is what makes the staging stage safe to run while appends continue.
        let snapshotEndOffset: UInt64
    }

    /// Preamble+tail written and fsynced into the sibling temp file, with its write handle still open at
    /// the end of that data, awaiting the delta copy and the rename on the engine actor.
    ///
    /// `@unchecked Sendable` because of the `FileHandle`: ownership moves from the staging task straight
    /// to the engine actor's commit and is never shared, so the handle has exactly one user at a time.
    struct StagedTrim: @unchecked Sendable {
        let tempPath: String
        let handle: FileHandle
        /// Bytes of preamble+tail already written to the temp file.
        let byteCount: UInt64
        let snapshotEndOffset: UInt64

        /// Drops an uncommitted staged trim: closes the temp handle and unlinks the temp file. The
        /// original `output.log` was never touched, so this restores the pre-trim world exactly.
        func discard() {
            try? handle.close()
            try? FileManager.default.removeItem(atPath: tempPath)
        }
    }

    /// The outcome of a committed trim: the transcript's new end offset and the write handle the caller
    /// must use for subsequent appends.
    ///
    /// A trim replaces `output.log` with a fresh inode, so the caller's previous handle points at the
    /// now-unlinked old inode and must be discarded. `writeHandle` is the temp file's handle, kept open
    /// across the rename and positioned at the new end.
    struct TrimResult {
        let endOffset: UInt64
        let writeHandle: FileHandle
    }

    /// Upper bound on the forward scan used to find a parser-safe cut. The scan prefers the offset just
    /// before the window's first ESC byte (parser-safe from any state); only when the window holds no ESC
    /// at all does it fall back to the offset just past the first newline (see `parserSafeCutOffset`), and
    /// only when the window has neither an ESC nor a newline does the trim DEFER to a later append rather
    /// than cut at an unsafe boundary. A megabyte is far larger than any realistic escape sequence or
    /// terminal line, so an ESC-free, LF-free scan window is already the adversarial case (an oversized
    /// single-sequence payload); this bound just caps how far the scan looks before conceding to the
    /// newline fallback or, failing that, deferring.
    static let maxParserSafeCutScanBytes: UInt64 = 1 << 20

    private static let replayChunkBytes = 256 * 1024
    private static let newlineScanBlockBytes = 64 * 1024

    /// Stage 1, on the engine actor. Returns the plan for a trim of `output.log`, or `nil` when there is
    /// nothing to do: the transcript is still under `triggerBytes`, or the forward scan found no
    /// parser-safe cut and the trim must DEFER to a later append. `retainedBytes` must be `<
    /// triggerBytes`. Reads nothing beyond the bounded scan window and never touches the transcript.
    static func plan(outputPath: String, currentEndOffset: UInt64, triggerBytes: UInt64, retainedBytes: UInt64) throws -> TrimPlan? {
        guard currentEndOffset > triggerBytes else { return nil }
        let nominalStart = currentEndOffset - retainedBytes

        let readHandle = try FileHandle(forReadingFrom: URL(fileURLWithPath: outputPath))
        defer { try? readHandle.close() }

        // A scan window with no ESC and no newline has no parser-safe cut: every candidate lands
        // mid-sequence/mid-codepoint and the preamble (terminal *state*, not parser state) cannot rescue
        // it. Defer the trim to a later append — the nominal cut slides forward as the file grows, so the
        // trim lands once the oversized run's terminator ESC or the next newline enters the window (see
        // `parserSafeCutOffset`).
        guard let cutOffset = try parserSafeCutOffset(readHandle: readHandle, nominalStart: nominalStart, endOffset: currentEndOffset) else {
            return nil
        }
        return TrimPlan(cutOffset: cutOffset, snapshotEndOffset: currentEndOffset)
    }

    /// Stage 2, OFF the engine actor. Builds the state preamble from the pre-trim head and stages
    /// preamble+tail into the sibling temp file, fsynced and left open at its end.
    ///
    /// Reads only bytes below `plan.snapshotEndOffset`, which the session can no longer change: appends
    /// are strictly append-only, so the snapshotted prefix is immutable and this stage is safe to run
    /// concurrently with them. It also never touches `output.log` itself, so a failure here — or an
    /// abandoned staging whose `StagedTrim` is `discard`ed — leaves the transcript and the session's
    /// append handle exactly as they were.
    static func stage(outputPath: String, plan: TrimPlan, columns: Int, rows: Int) throws -> StagedTrim {
        let preamble = try statePreamble(outputPath: outputPath, cutOffset: plan.cutOffset, columns: columns, rows: rows)

        let readHandle = try FileHandle(forReadingFrom: URL(fileURLWithPath: outputPath))
        defer { try? readHandle.close() }
        try readHandle.seek(toOffset: plan.cutOffset)
        let tail = try readHandle.read(upToCount: Int(plan.snapshotEndOffset - plan.cutOffset)) ?? Data()

        // Stage preamble+tail into a sibling temp file. The temp path is a fixed sibling (not a unique
        // name), created/truncated fresh each time so a stale leftover from a crashed earlier attempt is
        // simply overwritten; no leftover-scan recovery is needed. A fixed name is unambiguous because
        // the coordinator allows only one trim in flight per session. It sits in the SAME directory as
        // output.log so the eventual rename is a same-volume operation (atomic on APFS and ext4).
        let tempPath = outputPath + ".trim"
        _ = FileManager.default.createFile(atPath: tempPath, contents: nil)
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: tempPath))
        // Write preamble+tail and fsync, but do NOT close: the handle stays open through the commit's
        // rename so it can be adopted as the caller's new append handle without a fallible reopen
        // afterwards. Fsyncing the bulk here keeps the engine-actor commit's own fsync down to the
        // (small) append delta.
        do {
            try handle.write(contentsOf: preamble)
            try handle.write(contentsOf: tail)
            try handle.synchronize()
        } catch {
            // Pre-rename write/fsync failure: discard the temp file. output.log and the session's handle
            // are untouched, so the next append past the trigger simply retries.
            try? handle.close()
            try? FileManager.default.removeItem(atPath: tempPath)
            throw error
        }
        return StagedTrim(
            tempPath: tempPath, handle: handle, byteCount: UInt64(preamble.count + tail.count), snapshotEndOffset: plan.snapshotEndOffset)
    }

    /// Stage 3, back on the engine actor. Copies the bytes appended since the staging snapshot onto the
    /// staged tail, fsyncs, and atomically renames the temp file over `output.log`.
    ///
    /// The delta copy belongs on the engine actor precisely because the engine is the only place where
    /// "the transcript ends at `currentEndOffset`" can be read and acted on without an append slipping in
    /// between: this runs to completion without suspending, so the rename publishes a file that ends
    /// exactly where the caller believes it does.
    ///
    /// Failure-safe with no post-commit failure path: it either throws with `output.log` and the caller's
    /// append handle untouched (the temp file discarded), or returns with the swap fully committed. On
    /// success the rename unlinks the old inode the caller's previous handle points at; the returned
    /// `endOffset` is COMPUTED from the bytes written, not queried, so nothing fallible runs once the swap
    /// commits. The caller MUST adopt `TrimResult.writeHandle` and discard its old one.
    static func commit(_ staged: StagedTrim, outputPath: String, currentEndOffset: UInt64) throws -> TrimResult {
        guard currentEndOffset >= staged.snapshotEndOffset else {
            staged.discard()
            throw TrimError.transcriptShrankDuringStaging
        }

        var committedByteCount = staged.byteCount
        do {
            let deltaByteCount = currentEndOffset - staged.snapshotEndOffset
            if deltaByteCount > 0 {
                let readHandle = try FileHandle(forReadingFrom: URL(fileURLWithPath: outputPath))
                defer { try? readHandle.close() }
                try readHandle.seek(toOffset: staged.snapshotEndOffset)
                let delta = try readHandle.read(upToCount: Int(deltaByteCount)) ?? Data()
                try staged.handle.write(contentsOf: delta)
                committedByteCount += UInt64(delta.count)
            }
            // fsync before the rename guarantees the data is durable before the directory entry flips, so
            // a crash can never surface a renamed-but-truncated file.
            try staged.handle.synchronize()
        } catch {
            staged.discard()
            throw error
        }

        // Atomic same-volume rename. POSIX rename(2) atomically replaces the destination; readers see
        // either the old or the new file, never a partial one. Chosen over FileManager.replaceItemAt
        // because it is the simplest call that is truly atomic on both APFS (macOS) and ext4 (Linux) and
        // is identical on both platforms via Darwin/Glibc. The still-open handle survives the rename
        // untouched: rename moves the directory entry, not the open descriptor.
        let renamed = staged.tempPath.withCString { tempC in outputPath.withCString { outC in rename(tempC, outC) } }
        guard renamed == 0 else {
            // The swap never happened. Close and remove the temp file; the caller's old handle still points
            // at the intact output.log, so its append position stays valid and semantics are unchanged.
            let renameErrno = errno
            staged.discard()
            throw TrimError.atomicReplaceFailed(errno: renameErrno)
        }

        // The rename committed: the staged handle now references the renamed inode (output.log), its
        // offset at the end of preamble+tail+delta.
        return TrimResult(endOffset: committedByteCount, writeHandle: staged.handle)
    }

    /// Scans forward from `nominalStart` for a parser-safe cut and returns it, or `nil` to signal the
    /// caller to DEFER the trim. Bounded by `maxParserSafeCutScanBytes`.
    ///
    /// The cut must land on a boundary that is parser-safe from EVERY possible original parser state, or
    /// the retained tail starts mid-sequence and the from-zero replay (which begins in ground state after
    /// the preamble) renders those bytes as garbage — the preamble serializes terminal *state*, not
    /// mid-sequence *parser* state. The offset immediately before the window's first ESC (0x1B) byte is
    /// such a boundary by construction, so it is PREFERRED whenever the window holds any ESC: ESC is
    /// always < 0x80 so it can never sit inside a UTF-8 continuation byte, and if the parser was mid-string
    /// (OSC/DCS/APC) when it reached that ESC, the ESC is the start of that string's `ESC \` ST terminator
    /// — which in ground-state replay is a harmless no-op, after which the stream is clean. The head
    /// ending just before that ESC at worst leaves an unterminated sequence dangling in the throwaway
    /// preamble replay, which is simply never applied there — also harmless.
    ///
    /// Line alignment is NOT preferred, because a cut just past a newline is only parser-safe when that
    /// newline was processed in ground state: an LF inside an OSC string is swallowed (Ghostty's parser
    /// exits `osc_string` only on BEL/ESC/CAN/SUB), and likewise inside DCS passthrough, so a cut just
    /// past such an LF starts the retained tail mid-payload and the from-zero replay renders the payload
    /// bytes as visible text. Whether a given LF sat in ground state is unknowable without replaying, so
    /// the past-newline offset is used ONLY as a fallback for windows that contain no ESC at all — i.e.
    /// plain-text regions, where an open OSC/DCS would have to span the entire scan window without its
    /// terminator. Line alignment is thereby sacrificed for ESC-bearing windows: the retained tail may
    /// start mid-line (e.g. right at an SGR). That is cosmetic — the suffix consumers (`terminalTail`,
    /// ended-pane replay) are end-relative and already tolerate partial leading content, and from-zero
    /// replay correctness does not depend on line alignment.
    ///
    /// When the window contains neither an ESC nor a newline — a single sequence or plain-text run longer
    /// than the scan bound, e.g. a multi-megabyte DCS/OSC payload (sixel, iTerm2 inline image, OSC 52) or
    /// an LF-free UTF-8 text run — every candidate cut lands mid-sequence or mid-codepoint, so no
    /// preamble could rescue it. This returns `nil` and the caller leaves the transcript untrimmed for
    /// this append rather than cutting blind. Deferral is self-limiting: `nominalStart`
    /// (`endOffset - retainedBytes`) advances with every append, so the scan window slides forward and
    /// the trim lands as soon as the run's terminating ESC or the next newline enters view — a finite
    /// oversized payload defers the trim by roughly its own length, no more. An endless single-sequence
    /// stream would grow the transcript without bound, which is accepted: the alternative (cutting
    /// mid-sequence) corrupts the from-zero replay instead of merely deferring the bound. The newline
    /// fallback carries a matching residual acceptance: an OSC/DCS whose payload contains a newline but
    /// spans the entire scan window without its terminator would let an ESC-free window's newline cut land
    /// mid-payload — the same pathological >1 MiB single-sequence class already accepted under deferral.
    /// A second residual shares that acceptance: a window that BEGINS inside an OSC whose payload holds a
    /// raw newline before a bare-BEL (or CAN/SUB) terminator contains no ESC at all, so the newline cut
    /// lands inside the payload even though the sequence terminates within the window. No byte-level scan
    /// can close this — BEL ends an OSC but is inert data inside DCS passthrough, so terminator ordering
    /// proves nothing without parser state; the sound fix (validating the cut against parser ground state
    /// during the preamble replay, deferring otherwise) is tracked in issue #225.
    ///
    /// Single pass: the first newline offset is remembered while scanning for the first ESC rather than
    /// re-reading the window to find it separately.
    private static func parserSafeCutOffset(readHandle: FileHandle, nominalStart: UInt64, endOffset: UInt64) throws -> UInt64? {
        let scanLimit = min(nominalStart + maxParserSafeCutScanBytes, endOffset)
        try readHandle.seek(toOffset: nominalStart)
        var scanned = nominalStart
        var firstNewlineOffset: UInt64?
        while scanned < scanLimit {
            let toRead = Int(min(UInt64(newlineScanBlockBytes), scanLimit - scanned))
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
    /// queries) and serializing its persistent terminal state. This is the expensive part of a trim and
    /// is why staging runs off the engine actor; the throwaway session owns its own dlopen'd symbols and
    /// terminal, sharing nothing with the live session's renderer.
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
