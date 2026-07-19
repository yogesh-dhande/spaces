import Foundation

/// Bounds a live session's durable `output.log` transcript so a long-running session stops growing
/// without bound, while preserving the newest bytes every transcript consumer needs.
///
/// Every consumer of `output.log` reads an end-relative suffix, never an absolute offset into the file:
/// `TerminalOutputTail` (CLI/tail rendering) and `terminalTranscript` (ended-pane scrollback replay)
/// seek back from the end and cap at `TerminalScrollbackBudget.defaultMaxBytes`, and daemon handoff
/// resume captures its replay offset as the current file size at handoff time. Dropping bytes from the
/// HEAD of the file therefore preserves every consumer's full budget of history; only scrollback older
/// than any consumer could render is discarded. A trim landing mid-line/mid-escape-sequence is tolerated
/// by the vt replay (the partial leading sequence is discarded), so no line-boundary alignment is needed
/// here.
public enum TerminalTranscriptTrim {
    /// Head-truncates `output.log` in place when it exceeds
    /// `TerminalScrollbackBudget.liveTranscriptTrimTriggerBytes`, keeping the newest
    /// `TerminalScrollbackBudget.liveTranscriptRetainedBytes`. Returns the transcript's new end offset,
    /// unchanged when no trim was needed.
    ///
    /// `writeHandle` is the session core's sole append handle for the transcript (the session core runs on
    /// its main actor, so there is one writer). A transient read handle reads the retained tail, which is
    /// then rewritten to the file head and the file truncated; the write handle is left positioned at the
    /// new end so appends continue seamlessly. Readers open their own handles and read an end-relative
    /// window, so a concurrent read during the rare rewrite at worst returns a slightly shorter tail once.
    @discardableResult
    public static func trimIfNeeded(outputPath: String, writeHandle: FileHandle, currentEndOffset: UInt64) throws -> UInt64 {
        try trimIfNeeded(
            outputPath: outputPath, writeHandle: writeHandle, currentEndOffset: currentEndOffset,
            triggerBytes: UInt64(TerminalScrollbackBudget.liveTranscriptTrimTriggerBytes),
            retainedBytes: UInt64(TerminalScrollbackBudget.liveTranscriptRetainedBytes))
    }

    /// Testable core with explicit bounds. `retainedBytes` must be `< triggerBytes`.
    @discardableResult
    static func trimIfNeeded(outputPath: String, writeHandle: FileHandle, currentEndOffset: UInt64, triggerBytes: UInt64, retainedBytes: UInt64) throws
        -> UInt64
    {
        guard currentEndOffset > triggerBytes else { return currentEndOffset }
        let startOffset = currentEndOffset - retainedBytes
        let readHandle = try FileHandle(forReadingFrom: URL(fileURLWithPath: outputPath))
        defer { try? readHandle.close() }
        try readHandle.seek(toOffset: startOffset)
        let tail = try readHandle.read(upToCount: Int(retainedBytes)) ?? Data()
        try writeHandle.seek(toOffset: 0)
        try writeHandle.write(contentsOf: tail)
        try writeHandle.truncate(atOffset: UInt64(tail.count))
        try writeHandle.seekToEnd()
        return UInt64(tail.count)
    }
}
