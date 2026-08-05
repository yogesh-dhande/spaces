import Foundation

/// Runs one session's durable-transcript head-trims, keeping the expensive part off the shared
/// `TerminalEngineActor` and allowing at most one trim in flight per session.
///
/// Trimming a standard-policy transcript costs ~150 ms, almost all of it in the head replay that builds
/// the state preamble (see `TerminalTranscriptTrim`). Run inline on the engine actor that every session
/// shares, that stalled EVERY session's PTY output, input, control requests, and state broadcasts, and it
/// recurred every scrollback-budget worth of output from any one chatty session. So the trim is split:
/// the engine actor only snapshots offsets (`plan`) and later copies the append delta and renames
/// (`commit`); the preamble replay and the retained-tail copy (`stage`) run on a detached task. Appends
/// continue on the original `output.log` inode the whole time and are picked up by the delta copy, so a
/// session keeps writing at full speed while its own trim is staging.
///
/// **One trim in flight per session.** A trigger that fires while this session's trim is staging is
/// dropped rather than queued: the next append past the trigger re-evaluates against a fresh end offset,
/// which is exactly what a queued trim would have had to do anyway. Sessions never block each other —
/// each owns its own coordinator and its own detached staging task.
///
/// Trim work is best-effort by design. A plan or staging failure (an unreadable transcript, a temp file
/// that cannot be staged, a vt library that cannot build a preamble) leaves `output.log` and the
/// session's append handle untouched, and the next append past the trigger simply tries again.
@TerminalEngineActor public final class TerminalTranscriptTrimCoordinator {
    /// Reads the transcript's current end offset on the engine actor at commit time, which is what the
    /// commit copies the append delta up to. Returns `nil` when the session no longer owns `output.log` —
    /// it terminated, or handed the file to the daemon-handoff writer — which abandons the staged trim and
    /// leaves the transcript exactly as it was.
    public typealias LiveTranscriptEndOffsetProvider = @TerminalEngineActor () -> UInt64?

    /// Adopts the post-trim append handle and end offset. The session's previous handle points at the
    /// unlinked pre-trim inode, so the session must store this one and close the old one.
    public typealias TrimmedTranscriptAdopter = @TerminalEngineActor (FileHandle, UInt64) -> Void

    private let outputPath: String
    private let triggerBytes: UInt64
    private let retainedBytes: UInt64
    private let liveTranscriptEndOffset: LiveTranscriptEndOffsetProvider
    private let adoptTrimmedTranscript: TrimmedTranscriptAdopter
    private var isTrimInFlight = false
    /// The most recently started trim, retained only so tests can await a trim deterministically rather
    /// than polling the file system.
    private var latestTrim: Task<Void, Never>?

    public convenience init(
        outputPath: String, liveTranscriptEndOffset: @escaping LiveTranscriptEndOffsetProvider,
        adoptTrimmedTranscript: @escaping TrimmedTranscriptAdopter
    ) {
        self.init(
            outputPath: outputPath, triggerBytes: UInt64(TerminalScrollbackBudget.liveTranscriptTrimTriggerBytes),
            retainedBytes: UInt64(TerminalScrollbackBudget.liveTranscriptRetainedBytes), liveTranscriptEndOffset: liveTranscriptEndOffset,
            adoptTrimmedTranscript: adoptTrimmedTranscript)
    }

    /// Testable initializer with explicit bounds. `retainedBytes` must be `< triggerBytes`.
    init(
        outputPath: String, triggerBytes: UInt64, retainedBytes: UInt64, liveTranscriptEndOffset: @escaping LiveTranscriptEndOffsetProvider,
        adoptTrimmedTranscript: @escaping TrimmedTranscriptAdopter
    ) {
        self.outputPath = outputPath
        self.triggerBytes = triggerBytes
        self.retainedBytes = retainedBytes
        self.liveTranscriptEndOffset = liveTranscriptEndOffset
        self.adoptTrimmedTranscript = adoptTrimmedTranscript
    }

    /// Called from the session's append path with the transcript's end offset after the append and the
    /// session's current grid (used to build the preamble at the size the session replays at). Returns
    /// immediately: when a trim is warranted it starts staging in the background and commits on a later
    /// engine-actor turn.
    public func trimIfNeeded(currentEndOffset: UInt64, columns: Int, rows: Int) {
        guard !isTrimInFlight else { return }
        guard
            let plan = try? TerminalTranscriptTrim.plan(
                outputPath: outputPath, currentEndOffset: currentEndOffset, triggerBytes: triggerBytes, retainedBytes: retainedBytes)
        else { return }

        isTrimInFlight = true
        let outputPath = self.outputPath
        // Detached, so the staging never inherits (and therefore never runs on) the engine actor.
        latestTrim = Task.detached(priority: .utility) { [self] in
            let staged = try? TerminalTranscriptTrim.stage(outputPath: outputPath, plan: plan, columns: columns, rows: rows)
            await commit(staged, columns: columns, rows: rows)
        }
    }

    /// Awaits the most recently started trim. Test-only determinism: production callers fire and forget.
    func awaitLatestTrim() async { await latestTrim?.value }

    /// Engine-actor tail of a trim. Runs without suspending from the moment it reads the transcript's end
    /// offset, so the delta it copies is exactly the bytes appended during staging and no append can land
    /// between that read and the rename.
    private func commit(_ staged: TerminalTranscriptTrim.StagedTrim?, columns: Int, rows: Int) {
        isTrimInFlight = false
        guard let staged else { return }
        guard let currentEndOffset = liveTranscriptEndOffset() else {
            staged.discard()
            return
        }
        guard let result = try? TerminalTranscriptTrim.commit(staged, outputPath: outputPath, currentEndOffset: currentEndOffset) else { return }
        adoptTrimmedTranscript(result.writeHandle, result.endOffset)
        // A burst can append more than the trigger/retained gap while staging runs, in which case the
        // adopted file is already past the trigger again — and if the burst then stops, no further append
        // would re-evaluate. Re-check with the adopted end (the trigger guard makes this free when the
        // file is bounded), reusing the grid this trim was planned at.
        trimIfNeeded(currentEndOffset: result.endOffset, columns: columns, rows: rows)
    }
}
