import Foundation

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

/// Bounds a live session's durable `output.log` transcript so a long-running session stops growing
/// without bound, while keeping the file self-contained for a from-zero replay.
///
/// `TerminalOutputTail` (CLI/tail rendering) seeks back from the end and renders an end-relative window,
/// tolerating a partial leading sequence. Daemon handoff resume, however, rebuilds the renderer by
/// replaying the file from offset 0 (`recreateVTRenderer`), so it depends on the file's HEAD carrying
/// every state-establishing sequence (alt-screen enter, mouse reporting, bracketed paste, DECCKM, Kitty
/// keyboard flags, cursor position). A naive head-truncation would drop those sequences and replay to
/// the wrong terminal state.
///
/// To keep from-zero replay correct after a trim, a trim synthesizes a state-restoration PREAMBLE and
/// writes it at the head of the retained tail. The preamble is derived by replaying the pre-trim head
/// `[0..cut]` through a throwaway vt session and serializing its resulting persistent state
/// (`spaces_ghostty_vt_session_state_preamble`): the terminal modes, Kitty keyboard flags, scrolling
/// region, charset designations, and cursor position, plus a repaint of the active screen's visible grid
/// so cells the dropped head drew once (e.g. a static TUI header) that the retained tail never redraws
/// survive the trim. The region and the charsets are what let the retained tail's own bytes be
/// interpreted the way the dropped head established: a TUI that set a scrolling region once and then only
/// feeds lines into it would otherwise scroll the whole screen on replay. This is
/// inductively correct across successive trims: each trim's head replay `[0..cut]` itself starts from
/// the previous trim's preamble, so the serialized state always reflects the true accumulated state at
/// the cut. The retained tail is copied verbatim after the preamble, and its cut lands just before the
/// window's first ESC byte, a boundary that is parser-safe from any original parser state (see
/// `TerminalTranscriptPrefix.parserSafeCutOffset`), falling back to a line boundary only in escape-free
/// windows. The cut and the preamble are shared with the `terminalTranscript` command, which serves a
/// client a suffix of the same file and has the same two problems (see `TerminalTranscriptPrefix`).
///
/// ## Three stages, only two of them on the engine actor
/// The head replay dominates the cost (~150 ms for a standard-policy trim), so a trim is split so that
/// only cheap work runs on the shared `TerminalEngineActor` that every session's PTY output, input,
/// control requests, and state broadcasts share. `TerminalTranscriptTrimCoordinator` drives the three
/// stages and serializes them per session:
///  1. `plan` (engine actor): decide whether to trim and snapshot the cut offset plus the transcript's
///     current end. Bounded reads only — the trigger check costs nothing and the parser-safe scan is
///     capped at `TerminalTranscriptPrefix.maxParserSafeCutScanBytes`.
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
    /// A failure to build the preamble (`TerminalTranscriptPrefix.PrefixError`) aborts the trim (throws)
    /// rather than truncating without a preamble: an un-preambled from-zero replay would render the wrong
    /// state, and a vt install that cannot build a preamble cannot render the session anyway. The
    /// coordinator simply skips this round; the next append past the trigger re-evaluates.
    enum TrimError: Error {
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
        /// First retained byte: a parser-safe boundary (see `TerminalTranscriptPrefix.parserSafeCutOffset`).
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

    private static let replayChunkBytes = 256 * 1024

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
        // `TerminalTranscriptPrefix.parserSafeCutOffset`).
        guard
            let cutOffset = try TerminalTranscriptPrefix.parserSafeCutOffset(
                readHandle: readHandle, nominalStart: nominalStart, endOffset: currentEndOffset)
        else { return nil }
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
        // One handle for both halves: the preamble replays the head through it and the tail is read from
        // it straight afterwards, so preamble and tail are provably the same file.
        let readHandle = try FileHandle(forReadingFrom: URL(fileURLWithPath: outputPath))
        defer { try? readHandle.close() }
        let preamble = try TerminalTranscriptPrefix.statePreamble(readHandle: readHandle, cutOffset: plan.cutOffset, columns: columns, rows: rows)
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
    ///
    /// The delta copy's duration scales with the delta, which is ACCEPTED: the transcript is fed only by
    /// the session's own PTY capture (single-digit MB/s), so the bytes appendable during one staging pass
    /// are physically small, and even a seconds-long staging stall yields a delta whose on-engine copy
    /// costs about what ONE legacy inline trim cost every time. Copying it off-actor instead would need a
    /// multi-round catch-up (or an abandon-and-replan cycle that can livelock under sustained overload)
    /// for a case that only materializes when the machine is already degenerate.
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
                // read(upToCount:) may legally short-read, and a partial delta must never be renamed in:
                // the missing bytes would exist only on the unlinked old inode. Loop until the full delta
                // is copied and treat premature EOF as a failed commit. Chunked, so a large delta never
                // materializes as one allocation on the engine actor.
                var remaining = deltaByteCount
                while remaining > 0 {
                    let toRead = Int(min(remaining, UInt64(replayChunkBytes)))
                    guard let chunk = try readHandle.read(upToCount: toRead), !chunk.isEmpty else { throw TrimError.transcriptShrankDuringStaging }
                    try staged.handle.write(contentsOf: chunk)
                    committedByteCount += UInt64(chunk.count)
                    remaining -= UInt64(chunk.count)
                }
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
}
