import Dispatch
import Foundation

#if os(Linux)
    import Glibc
#elseif os(macOS)
    import Darwin
#endif

#if os(Linux)
    // Swift's Glibc overlay does not expose these GNU extensions, but glibc exports both symbols.
    @_silgen_name("pipe2") private func spaces_pipe2(_ pipeDescriptors: UnsafeMutablePointer<Int32>?, _ flags: Int32) -> Int32
    @_silgen_name("posix_spawn_file_actions_addclosefrom_np") private func spaces_posixSpawnFileActionsAddCloseFrom(
        _ fileActions: UnsafeMutablePointer<posix_spawn_file_actions_t>?, _ firstFileDescriptor: Int32
    ) -> Int32
#endif

#if os(macOS) || os(Linux)
    enum AgentHookSubprocess {
        private static let maximumCapturedOutputBytes = 1_048_576
        private static let maximumReadsPerDrain = 16

        struct Result {
            let terminationStatus: Int32
            let output: Data
        }

        enum RunError: LocalizedError, Equatable {
            case launch(String)
            case timedOut

            var errorDescription: String? {
                switch self {
                case .launch(let detail): detail
                case .timedOut: "Codex feature command timed out"
                }
            }
        }

        /// Runs a command without Foundation's run-loop-backed `Process` monitor. Every wait,
        /// including termination and pipe draining, has a deadline so a wedged monitor or a child
        /// that inherits the output pipe cannot strand the Swift Testing host.
        static func run(executablePath: String, arguments: [String], environment: [String: String], timeoutSeconds: TimeInterval) throws -> Result {
            var outputPipe: [Int32] = [-1, -1]
            #if os(Linux)
                let pipeResult = outputPipe.withUnsafeMutableBufferPointer { spaces_pipe2($0.baseAddress, O_CLOEXEC) }
            #else
                let pipeResult = pipe(&outputPipe)
            #endif
            guard pipeResult == 0 else { throw RunError.launch("pipe failed (errno \(errno))") }
            let readFlags = fcntl(outputPipe[0], F_GETFL)
            #if os(macOS)
                // Darwin has no pipe2. Mark both ends close-on-exec immediately; only the read end
                // is nonblocking because the child must retain ordinary blocking stdout semantics.
                let readDescriptorFlags = fcntl(outputPipe[0], F_GETFD)
                let writeDescriptorFlags = fcntl(outputPipe[1], F_GETFD)
                let pipeConfigured =
                    readFlags >= 0 && readDescriptorFlags >= 0 && writeDescriptorFlags >= 0
                    && fcntl(outputPipe[0], F_SETFL, readFlags | O_NONBLOCK) == 0
                    && fcntl(outputPipe[0], F_SETFD, readDescriptorFlags | FD_CLOEXEC) == 0
                    && fcntl(outputPipe[1], F_SETFD, writeDescriptorFlags | FD_CLOEXEC) == 0
            #else
                let pipeConfigured = readFlags >= 0 && fcntl(outputPipe[0], F_SETFL, readFlags | O_NONBLOCK) == 0
            #endif
            guard pipeConfigured else {
                let code = errno
                close(outputPipe[0])
                close(outputPipe[1])
                throw RunError.launch("failed to configure output pipe (errno \(code))")
            }

            #if canImport(Darwin)
                var fileActions: posix_spawn_file_actions_t? = nil
                var attributes: posix_spawnattr_t? = nil
            #else
                var fileActions = posix_spawn_file_actions_t()
                var attributes = posix_spawnattr_t()
            #endif
            guard posix_spawn_file_actions_init(&fileActions) == 0 else {
                close(outputPipe[0])
                close(outputPipe[1])
                throw RunError.launch("posix_spawn_file_actions_init failed")
            }
            defer { posix_spawn_file_actions_destroy(&fileActions) }
            guard posix_spawnattr_init(&attributes) == 0 else {
                close(outputPipe[0])
                close(outputPipe[1])
                throw RunError.launch("posix_spawnattr_init failed")
            }
            defer { posix_spawnattr_destroy(&attributes) }

            var fileActionResults = [
                posix_spawn_file_actions_addopen(&fileActions, STDIN_FILENO, "/dev/null", O_RDONLY, 0),
                posix_spawn_file_actions_adddup2(&fileActions, outputPipe[1], STDOUT_FILENO),
                posix_spawn_file_actions_adddup2(&fileActions, outputPipe[1], STDERR_FILENO),
            ]
            #if os(Linux)
                // closefrom is a spawn action, so the child never has a window where unrelated
                // daemon listeners or session descriptors are visible after exec.
                fileActionResults.append(spaces_posixSpawnFileActionsAddCloseFrom(&fileActions, STDERR_FILENO + 1))
            #else
                fileActionResults.append(posix_spawn_file_actions_addclose(&fileActions, outputPipe[0]))
                fileActionResults.append(posix_spawn_file_actions_addclose(&fileActions, outputPipe[1]))
            #endif
            let fileActionResult = fileActionResults.first { $0 != 0 }

            var emptySignalMask = sigset_t()
            var defaultSignals = sigset_t()
            sigemptyset(&emptySignalMask)
            sigfillset(&defaultSignals)
            let attributeResult = posix_spawnattr_setpgroup(&attributes, 0)
            let signalMaskResult = posix_spawnattr_setsigmask(&attributes, &emptySignalMask)
            let signalDefaultResult = posix_spawnattr_setsigdefault(&attributes, &defaultSignals)
            var spawnFlags = Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF)
            #if os(macOS)
                // Darwin has no closefrom spawn action. This makes every descriptor not explicitly
                // referenced by the actions above close-on-exec in the spawned process.
                spawnFlags |= Int16(POSIX_SPAWN_CLOEXEC_DEFAULT)
            #endif
            let flagResult = posix_spawnattr_setflags(&attributes, spawnFlags)
            guard fileActionResult == nil, attributeResult == 0, signalMaskResult == 0, signalDefaultResult == 0, flagResult == 0 else {
                close(outputPipe[0])
                close(outputPipe[1])
                throw RunError.launch("failed to configure posix_spawn")
            }

            var cArguments: [UnsafeMutablePointer<CChar>?] = ([executablePath] + arguments).map { strdup($0) }
            cArguments.append(nil)
            defer { for case let argument? in cArguments { free(argument) } }
            var cEnvironment: [UnsafeMutablePointer<CChar>?] = environment.map { strdup("\($0.key)=\($0.value)") }
            cEnvironment.append(nil)
            defer { for case let entry? in cEnvironment { free(entry) } }

            var processID: pid_t = 0
            let spawnResult = posix_spawn(&processID, executablePath, &fileActions, &attributes, &cArguments, &cEnvironment)
            close(outputPipe[1])
            guard spawnResult == 0, processID > 0 else {
                close(outputPipe[0])
                throw RunError.launch("posix_spawn failed (errno \(spawnResult))")
            }
            defer { close(outputPipe[0]) }

            let deadline = monotonicDeadline(after: timeoutSeconds)
            var output = Data()
            var waitStatus: Int32?
            var outputReachedEOF = false
            do {
                while waitStatus == nil {
                    try drain(outputPipe[0], into: &output, reachedEOF: &outputReachedEOF)
                    if waitStatus == nil { waitStatus = try reap(processID) }
                    if waitStatus != nil {
                        // Once the launched command exits, drain bytes already buffered in the
                        // pipe and return its status. A daemonized helper may legitimately retain
                        // stdout, so waiting for EOF would turn a successful command into a timeout.
                        try drain(outputPipe[0], into: &output, reachedEOF: &outputReachedEOF)
                        break
                    }
                    guard monotonicNow() < deadline else { throw RunError.timedOut }
                    try waitForOutput(outputReachedEOF ? -1 : outputPipe[0], until: deadline)
                }
            } catch {
                if waitStatus == nil {
                    terminateAndDrain(processGroupID: processID, outputFD: outputPipe[0], waitStatus: &waitStatus, output: &output)
                }
                throw error
            }

            return Result(terminationStatus: terminationStatus(waitStatus!), output: output)
        }

        private static func drain(_ fileDescriptor: Int32, into output: inout Data, reachedEOF: inout Bool) throws {
            var buffer = [UInt8](repeating: 0, count: 4096)
            for _ in 0..<maximumReadsPerDrain {
                let count = read(fileDescriptor, &buffer, buffer.count)
                if count > 0 {
                    let remainingCapacity = max(0, maximumCapturedOutputBytes - output.count)
                    if remainingCapacity > 0 { output.append(buffer, count: min(count, remainingCapacity)) }
                    continue
                }
                if count == 0 {
                    reachedEOF = true
                    return
                }
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK { return }
                throw RunError.launch("read failed (errno \(errno))")
            }
        }

        private static func waitForOutput(_ fileDescriptor: Int32, until deadline: UInt64) throws {
            let now = monotonicNow()
            let remainingNanoseconds = deadline > now ? deadline - now : 0
            let remainingMilliseconds = max(1, min(20, Int((remainingNanoseconds + 999_999) / 1_000_000)))
            var descriptor = pollfd(fd: fileDescriptor, events: Int16(POLLIN), revents: 0)
            let result = poll(&descriptor, 1, Int32(remainingMilliseconds))
            if result < 0, errno != EINTR { throw RunError.launch("poll failed (errno \(errno))") }
        }

        private static func reap(_ processID: pid_t) throws -> Int32? {
            var status: Int32 = 0
            let result = waitpid(processID, &status, WNOHANG)
            if result == processID { return status }
            if result == 0 || (result < 0 && errno == EINTR) { return nil }
            if result < 0, errno == ECHILD { return 0 }
            throw RunError.launch("waitpid failed (errno \(errno))")
        }

        private static func terminateAndDrain(processGroupID: pid_t, outputFD: Int32, waitStatus: inout Int32?, output: inout Data) {
            // Retain the pre-termination descendant snapshot through SIGKILL. The process-group
            // signal catches ordinary helpers atomically; the snapshot also catches a helper that
            // created its own group or session after inheriting the output pipe.
            let processIDs = AgentHookProcessTree.processIDs(rootProcessID: processGroupID)
            for (signal, timeout): (Int32, TimeInterval) in [(SIGTERM, 1), (SIGKILL, 1)] {
                _ = kill(-processGroupID, signal)
                for processID in processIDs.reversed() { _ = kill(processID, signal) }
                let deadline = monotonicDeadline(after: timeout)
                var reachedEOF = false
                repeat {
                    try? drain(outputFD, into: &output, reachedEOF: &reachedEOF)
                    if waitStatus == nil { waitStatus = try? reap(processGroupID) }
                    if waitStatus != nil, reachedEOF {
                        let descendantSurvived = processIDs.dropFirst().contains { AgentHookProcessTree.processExists($0) }
                        if signal == SIGKILL || !descendantSurvived { return }
                        break
                    }
                    var descriptor = pollfd(fd: reachedEOF ? -1 : outputFD, events: Int16(POLLIN), revents: 0)
                    _ = poll(&descriptor, 1, 10)
                } while monotonicNow() < deadline
            }
            if waitStatus == nil { reapEventually(processGroupID) }
        }

        private static func reapEventually(_ processID: pid_t) {
            DispatchQueue.global(qos: .utility).async {
                var status: Int32 = 0
                while waitpid(processID, &status, 0) < 0, errno == EINTR {}
            }
        }

        private static func monotonicDeadline(after seconds: TimeInterval) -> UInt64 { monotonicNow() + UInt64(max(0, seconds) * 1_000_000_000) }

        private static func monotonicNow() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

        private static func terminationStatus(_ waitStatus: Int32) -> Int32 {
            let signal = waitStatus & 0x7f
            return signal == 0 ? (waitStatus >> 8) & 0xff : 128 + signal
        }
    }

    /// Stops descendants before their parent so a wrapper cannot leave a child holding an output
    /// pipe open. The initial snapshot is retained through SIGKILL because children are reparented
    /// as their ancestors exit and can no longer be rediscovered from the original root.
    enum AgentHookProcessTree {
        static func terminate(rootProcessID: pid_t, completion: DispatchSemaphore) {
            let processIDs = processIDs(rootProcessID: rootProcessID)
            for processID in processIDs.reversed() { kill(processID, SIGTERM) }
            let rootTerminated = completion.wait(timeout: .now() + 1) == .success
            for processID in processIDs.reversed() where processExists(processID) { kill(processID, SIGKILL) }
            if !rootTerminated { _ = completion.wait(timeout: .now() + 1) }
        }

        static func processIDs(rootProcessID: pid_t) -> [pid_t] { [rootProcessID] + descendantProcessIDs(of: rootProcessID) }

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

        static func processExists(_ processID: pid_t) -> Bool {
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
