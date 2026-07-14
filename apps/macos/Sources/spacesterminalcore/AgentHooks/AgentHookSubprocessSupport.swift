import Dispatch
import Foundation

#if os(Linux)
    import Glibc
#elseif os(macOS)
    import Darwin
#endif

#if os(macOS) || os(Linux)
    /// Stops descendants before their parent so a wrapper cannot leave a child holding an output
    /// pipe open. The initial snapshot is retained through SIGKILL because children are reparented
    /// as their ancestors exit and can no longer be rediscovered from the original root.
    enum AgentHookProcessTree {
        static func terminate(rootProcessID: pid_t, completion: DispatchSemaphore) {
            let processIDs = [rootProcessID] + descendantProcessIDs(of: rootProcessID)
            for processID in processIDs.reversed() { kill(processID, SIGTERM) }
            let rootTerminated = completion.wait(timeout: .now() + 1) == .success
            for processID in processIDs.reversed() where processExists(processID) { kill(processID, SIGKILL) }
            if !rootTerminated { _ = completion.wait(timeout: .now() + 1) }
        }

        private static func descendantProcessIDs(of rootProcessID: pid_t) -> [pid_t] {
            var result: [pid_t] = []
            var pending = [rootProcessID]
            var seen = Set<pid_t>()
            while let parent = pending.popLast() {
                for child in directChildProcessIDs(of: parent) where seen.insert(child).inserted {
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

        private static func processExists(_ processID: pid_t) -> Bool {
            errno = 0
            return kill(processID, 0) == 0 || errno != ESRCH
        }
    }

    final class AgentHookPipeOutputBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()

        func append(_ chunk: Data) {
            lock.lock()
            data.append(chunk)
            lock.unlock()
        }

        func snapshot() -> Data {
            lock.lock()
            defer { lock.unlock() }
            return data
        }
    }
#endif
