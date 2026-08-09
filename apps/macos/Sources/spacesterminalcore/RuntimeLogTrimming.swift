import Foundation

/// Bounds append-only diagnostic log files that nothing else ever rotates: launchd's
/// StandardOutPath/StandardErrorPath redirects for `spacesd` (opened O_APPEND for the life of the
/// daemon process) and `TerminalPerformance`'s perf.log. Both grow without limit otherwise (issue
/// #469): a daemon that has run for a couple of weeks was observed with a multi-megabyte stderr log.
public enum RuntimeLogTrimming {
    /// A file is left untouched until it exceeds this size, so a normal, actively-small log is never
    /// rewritten on a routine startup.
    public static let maximumSizeBeforeTrimBytes = 5 * 1024 * 1024
    /// Size kept after a trim: enough recent history to debug what the process was doing right before
    /// startup without letting the file stay large.
    public static let retainedSizeAfterTrimBytes = 1 * 1024 * 1024

    /// Rewrites `path` in place to its last `retainedSizeAfterTrimBytes`, cut forward to the first
    /// newline in the kept tail so the result starts on a line boundary. No-ops when the file is
    /// missing, unreadable, or already at or under `maximumSizeBeforeTrimBytes`.
    ///
    /// Rewrites through the SAME path (truncate + write), never a temp-file-and-rename: a writer that
    /// holds an O_APPEND descriptor open across this call (launchd, or an in-process appender like
    /// `TerminalPerformance`) always seeks to the file's current end before each write. A rename would
    /// replace the inode the path points at, leaving that descriptor writing into an unlinked file
    /// nobody reads again. Truncating the existing inode in place keeps the descriptor and the path
    /// pointing at the same file, so the writer's next append lands right after the new, shorter end.
    public static func trimIfOversized(path: String, fileManager: FileManager = .default) {
        guard let attributes = try? fileManager.attributesOfItem(atPath: path), let size = attributes[.size] as? Int,
            size > maximumSizeBeforeTrimBytes
        else { return }

        let fileURL = URL(fileURLWithPath: path)
        guard let readHandle = try? FileHandle(forReadingFrom: fileURL) else { return }
        var tail: Data
        do {
            try readHandle.seek(toOffset: UInt64(size - retainedSizeAfterTrimBytes))
            tail = try readHandle.readToEnd() ?? Data()
            try readHandle.close()
        } catch {
            try? readHandle.close()
            return
        }
        if let newlineIndex = tail.firstIndex(of: UInt8(ascii: "\n")) { tail.removeSubrange(tail.startIndex...newlineIndex) }

        guard let writeHandle = try? FileHandle(forWritingTo: fileURL) else { return }
        defer { try? writeHandle.close() }
        try? writeHandle.truncate(atOffset: 0)
        try? writeHandle.write(contentsOf: tail)
    }
}
