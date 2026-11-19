import Foundation

/// The scheduling class the index build runs under, so indexing never competes with the user's terminals.
public enum BackgroundPriority {
    /// Lowers the calling thread to the lowest CPU and disk priority. macOS marks the thread background
    /// (`PRIO_DARWIN_BG` also throttles its disk I/O); Linux sets nice 19, which applies to the calling
    /// thread only because Linux treats `setpriority(PRIO_PROCESS, 0, ...)` as per-thread.
    ///
    /// The daemon calls this on the dedicated thread that runs `AgentSessionIndex.refresh`.
    public static func lowerCurrentThread() {
        #if os(Linux)
            setpriority(__priority_which_t(PRIO_PROCESS.rawValue), 0, 19)
        #else
            setpriority(PRIO_DARWIN_THREAD, 0, PRIO_DARWIN_BG)
        #endif
    }
}
