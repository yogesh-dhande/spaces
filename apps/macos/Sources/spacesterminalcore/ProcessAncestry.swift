import Foundation

#if os(macOS)
    import Darwin
#endif

/// Answers whether one process runs beneath another by walking parent pids.
///
/// The daemon uses it to tell whether a caller really runs inside a terminal: the terminal's shell has to
/// be an ancestor of the calling process. A process the shell started but that was reparented away
/// (a tmux server, a background agent server, an IDE opened from the terminal) is no longer a descendant.
public enum ProcessAncestry {
    /// The deepest chain followed before the answer is no. Real chains from a shell to a hook or MCP
    /// process are a handful of processes long; the bound only stops a corrupt or cyclic chain.
    public static let maximumDepth = 64

    /// Whether `ancestor` is `pid` itself or any of its ancestors. `parentPID` is injectable so the walk's
    /// bound and stop conditions are testable without building a deep real process tree.
    public static func isDescendant(_ pid: Int32, of ancestor: Int32, parentPID: (Int32) -> Int32? = ProcessAncestry.parentPID(of:)) -> Bool {
        guard pid > 0, ancestor > 1 else { return false }
        var current = pid
        for _ in 0..<maximumDepth {
            if current == ancestor { return true }
            // Pid 1 and 0 are the roots of every chain: nothing above them can be a terminal's shell.
            guard current > 1, let parent = parentPID(current), parent > 0 else { return false }
            current = parent
        }
        return false
    }

    /// The parent of `pid`, or nil when the process is gone or cannot be read.
    public static func parentPID(of pid: Int32) -> Int32? {
        #if os(macOS)
            var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
            var info = kinfo_proc()
            var size = MemoryLayout<kinfo_proc>.stride
            guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
            return info.kp_eproc.e_ppid
        #elseif os(Linux)
            guard let stat = try? String(contentsOfFile: "/proc/\(pid)/stat", encoding: .utf8) else { return nil }
            return parentPID(inProcStat: stat)
        #else
            return nil
        #endif
    }

    /// The parent pid in a `/proc/<pid>/stat` line (`pid (comm) state ppid ...`). The command name can
    /// contain spaces and parentheses, so the fields are counted from the last `)`, which closes it.
    static func parentPID(inProcStat stat: String) -> Int32? {
        guard let closing = stat.lastIndex(of: ")") else { return nil }
        let fields = stat[stat.index(after: closing)...].split(separator: " ", omittingEmptySubsequences: true)
        guard fields.count >= 2 else { return nil }
        return Int32(fields[1])
    }
}
