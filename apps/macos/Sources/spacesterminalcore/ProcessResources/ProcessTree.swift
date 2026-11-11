import Foundation

#if os(Linux)
    import Glibc
#elseif os(macOS)
    import Darwin
#endif

/// Enumerates a process and the descendants still attached to it.
public enum ProcessTree {
    /// `rootProcessID` followed by its descendants. A process that detaches (a daemonized server) is
    /// reparented away from the tree and is not listed.
    public static func processIDs(rootProcessID: pid_t) -> [pid_t] { [rootProcessID] + descendantProcessIDs(of: rootProcessID) }

    /// Like `processIDs(rootProcessID:)`, but leaves out every descendant for which `excludesSubtree`
    /// is true, together with everything beneath it. The root itself is always listed.
    public static func processIDs(rootProcessID: pid_t, excludingSubtreesWhere excludesSubtree: (pid_t) -> Bool) -> [pid_t] {
        [rootProcessID] + descendantProcessIDs(of: rootProcessID, excludingSubtreesWhere: excludesSubtree)
    }

    private static func descendantProcessIDs(of rootProcessID: pid_t, excludingSubtreesWhere excludesSubtree: (pid_t) -> Bool = { _ in false })
        -> [pid_t]
    {
        var result: [pid_t] = []
        var pending = [rootProcessID]
        var seen = Set<pid_t>()
        while let parent = pending.popLast() {
            for child in directChildProcessIDs(of: parent) where seen.insert(child).inserted && !excludesSubtree(child) {
                result.append(child)
                pending.append(child)
            }
        }
        return result
    }

    private static func directChildProcessIDs(of parent: pid_t) -> [pid_t] {
        #if os(macOS)
            var capacity = 32
            while capacity <= 4096 {
                var processIDs = [pid_t](repeating: 0, count: capacity)
                let bufferSize = Int32(processIDs.count * MemoryLayout<pid_t>.stride)
                let childCount = proc_listchildpids(parent, &processIDs, bufferSize)
                guard childCount > 0 else { return [] }
                if childCount < capacity { return Array(processIDs.prefix(Int(childCount))).filter { $0 > 0 } }
                capacity *= 2
            }
            return []
        #else
            let taskDirectory = URL(fileURLWithPath: "/proc/\(parent)/task", isDirectory: true)
            let taskURLs = (try? FileManager.default.contentsOfDirectory(at: taskDirectory, includingPropertiesForKeys: nil)) ?? []
            return taskURLs.flatMap { taskURL -> [pid_t] in
                let childrenURL = taskURL.appendingPathComponent("children")
                guard let contents = try? String(contentsOf: childrenURL, encoding: .utf8) else { return [] }
                return contents.split(whereSeparator: \.isWhitespace).compactMap { pid_t(String($0)) }
            }
        #endif
    }
}
