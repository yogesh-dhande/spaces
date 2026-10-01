import Dispatch
import Foundation

#if os(Linux)
    import Glibc
#elseif os(macOS)
    import Darwin
#endif

extension AgentHookCodexAppServer {
    /// Starts the real `codex app-server`, the launcher every production read and write uses.
    static func launchProcess(executablePath: String, codexHome: URL) throws -> any AgentHookCodexAppServerTransport {
        #if os(macOS) || os(Linux)
            try AgentHookCodexAppServerProcess.launch(
                executablePath: executablePath, arguments: ["app-server"],
                environment: AgentHookCodexCLI.environment(executablePath: executablePath, codexHome: codexHome))
        #else
            throw Failure.launch("Codex hooks are managed only by a macOS or Linux daemon")
        #endif
    }
}

#if os(macOS) || os(Linux)
    /// A child process spoken to over its stdio, one line at a time, with a deadline on every wait.
    ///
    /// Its input is one end of a socket pair rather than a pipe, because a write to a server that already
    /// exited (a Codex too old to know `app-server` exits before reading anything) must fail with `EPIPE`
    /// rather than raise `SIGPIPE`, and only a socket can say so per write on Linux (`MSG_NOSIGNAL`;
    /// Darwin sets `SO_NOSIGPIPE` on the socket). stdout and stderr are separate pipes so a log line on
    /// stderr can never land inside a reply on stdout, and only the start of stderr is kept, which is
    /// where a failing server says why.
    ///
    /// The child runs in its own process group (`AgentHookSubprocess.spawn`), so ending it also ends the
    /// native binary a version-manager `codex` launcher runs underneath itself.
    final class AgentHookCodexAppServerProcess: AgentHookCodexAppServerTransport {
        private static let maximumBufferedOutputBytes = 8 * 1_048_576
        private static let maximumKeptErrorBytes = 4096

        private let processID: pid_t
        private var input: Int32
        private var output: Int32
        private var errorOutput: Int32
        private var outputBuffer = Data()
        private var errorBuffer = Data()
        private var waitStatus: Int32?
        /// Set once a background reap owns the process, after which its pid may be reused and is never
        /// signaled or waited on here again.
        private var reapHandedOff = false
        private var outputReachedEOF = false
        private var isClosed = false

        private init(processID: pid_t, input: Int32, output: Int32, errorOutput: Int32) {
            self.processID = processID
            self.input = input
            self.output = output
            self.errorOutput = errorOutput
        }

        static func launch(executablePath: String, arguments: [String], environment: [String: String]) throws -> AgentHookCodexAppServerProcess {
            var inputPair: [Int32] = [-1, -1]
            var outputPipe: [Int32] = [-1, -1]
            var errorPipe: [Int32] = [-1, -1]
            var opened: [Int32] = []
            func fail(_ message: String) -> AgentHookCodexAppServer.Failure {
                for descriptor in opened { closeDescriptor(descriptor) }
                return .launch(message)
            }

            // Every end is close-on-exec from the start where the platform allows it: another thread of the
            // daemon spawning a terminal must not inherit them, and an inherited input end would keep the
            // server from ever seeing the end of its input.
            #if os(Linux)
                let socketType = Int32(SOCK_STREAM.rawValue) | Int32(SOCK_CLOEXEC.rawValue)
                guard socketpair(AF_UNIX, socketType, 0, &inputPair) == 0 else { throw fail("socketpair failed (errno \(errno))") }
                opened += inputPair
                guard outputPipe.withUnsafeMutableBufferPointer({ spaces_pipe2($0.baseAddress, O_CLOEXEC) }) == 0 else {
                    throw fail("pipe failed (errno \(errno))")
                }
                opened += outputPipe
                guard errorPipe.withUnsafeMutableBufferPointer({ spaces_pipe2($0.baseAddress, O_CLOEXEC) }) == 0 else {
                    throw fail("pipe failed (errno \(errno))")
                }
                opened += errorPipe
            #else
                guard socketpair(AF_UNIX, SOCK_STREAM, 0, &inputPair) == 0 else { throw fail("socketpair failed (errno \(errno))") }
                opened += inputPair
                guard pipe(&outputPipe) == 0 else { throw fail("pipe failed (errno \(errno))") }
                opened += outputPipe
                guard pipe(&errorPipe) == 0 else { throw fail("pipe failed (errno \(errno))") }
                opened += errorPipe
                guard opened.allSatisfy(setCloseOnExec) else { throw fail("failed to configure the server's stdio (errno \(errno))") }
            #endif
            // The parent's ends are nonblocking, since every wait on them is a `poll` with a deadline.
            let parentEnds = [inputPair[0], outputPipe[0], errorPipe[0]]
            guard parentEnds.allSatisfy(setNonblocking), suppressSIGPIPE(inputPair[0]) else {
                throw fail("failed to configure the server's stdio (errno \(errno))")
            }

            let processID: pid_t
            do {
                processID = try AgentHookSubprocess.spawn(
                    executablePath: executablePath, arguments: arguments, environment: environment,
                    standardStreams: .init(input: inputPair[1], output: outputPipe[1], error: errorPipe[1]), parentDescriptors: parentEnds)
            } catch { throw fail(error.localizedDescription) }
            closeDescriptor(inputPair[1])
            closeDescriptor(outputPipe[1])
            closeDescriptor(errorPipe[1])
            return AgentHookCodexAppServerProcess(processID: processID, input: inputPair[0], output: outputPipe[0], errorOutput: errorPipe[0])
        }

        deinit { close() }

        func send(_ line: Data, deadline: UInt64) throws {
            var bytes = [UInt8](line)
            bytes.append(0x0A)
            var offset = 0
            while offset < bytes.count {
                let written = bytes.withUnsafeBytes { buffer in sendBytes(input, buffer.baseAddress! + offset, buffer.count - offset) }
                if written > 0 {
                    offset += written
                    continue
                }
                switch errno {
                case EINTR: continue
                case EAGAIN, EWOULDBLOCK:
                    guard AgentHookSubprocess.monotonicNow() < deadline else { throw terminatedForTimeout() }
                    pollOnce([pollfd(fd: input, events: Int16(POLLOUT), revents: 0)], until: deadline)
                default:
                    // The server closed its input: it has exited, or is exiting, and its stderr says why.
                    throw exitFailure()
                }
            }
        }

        func receiveLine(deadline: UInt64) throws -> Data {
            while true {
                if let newline = outputBuffer.firstIndex(of: 0x0A) {
                    let line = Data(outputBuffer[outputBuffer.startIndex..<newline])
                    outputBuffer.removeSubrange(outputBuffer.startIndex...newline)
                    return line
                }
                // Draining follows the reap in `pollOnce`, so everything the server wrote before it exited
                // is already buffered by the time its exit is acted on here.
                if outputReachedEOF || waitStatus != nil { throw exitFailure() }
                guard AgentHookSubprocess.monotonicNow() < deadline else { throw terminatedForTimeout() }
                pollOnce(
                    [pollfd(fd: output, events: Int16(POLLIN), revents: 0), pollfd(fd: errorOutput, events: Int16(POLLIN), revents: 0)],
                    until: deadline)
                try drainOutput()
                drainErrorOutput()
            }
        }

        func close() {
            guard !isClosed else { return }
            isClosed = true
            // End of input is the server's cue to finish; one that ignores it is stopped.
            closeDescriptor(input)
            input = -1
            if !awaitExit(seconds: 1) { terminate() }
            closeDescriptor(output)
            closeDescriptor(errorOutput)
            output = -1
            errorOutput = -1
        }

        // MARK: - Internals

        private func drainOutput() throws {
            var buffer = [UInt8](repeating: 0, count: 65_536)
            while true {
                let count = read(output, &buffer, buffer.count)
                if count > 0 {
                    outputBuffer.append(buffer, count: count)
                    // A reply is a few kilobytes; a server streaming that much without a newline is not
                    // sending one.
                    guard outputBuffer.count <= Self.maximumBufferedOutputBytes else {
                        terminate()
                        throw AgentHookCodexAppServer.Failure.unreadable(method: "its output")
                    }
                    continue
                }
                if count == 0 { outputReachedEOF = true }
                if count < 0, errno == EINTR { continue }
                return
            }
        }

        private func drainErrorOutput() {
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = read(errorOutput, &buffer, buffer.count)
                if count > 0 {
                    let room = Self.maximumKeptErrorBytes - errorBuffer.count
                    if room > 0 { errorBuffer.append(buffer, count: min(count, room)) }
                    continue
                }
                if count < 0, errno == EINTR { continue }
                return
            }
        }

        /// One bounded wait for any of `descriptors`, then a check on whether the server exited.
        private func pollOnce(_ descriptors: [pollfd], until deadline: UInt64) {
            var descriptors = descriptors
            let now = AgentHookSubprocess.monotonicNow()
            let remainingMilliseconds = deadline > now ? (deadline - now + 999_999) / 1_000_000 : 0
            // Capped so a server that exits while a helper it started still holds its output open is
            // noticed between polls rather than at the deadline.
            _ = poll(&descriptors, nfds_t(descriptors.count), Int32(min(remainingMilliseconds, 100)))
            if waitStatus == nil, !reapHandedOff { waitStatus = try? AgentHookSubprocess.reap(processID) }
        }

        /// The failure for a server that stopped answering by ending: its exit status once it is reaped,
        /// and the first line of what it wrote to stderr.
        private func exitFailure() -> AgentHookCodexAppServer.Failure {
            if !awaitExit(seconds: 1) { terminate() }
            drainErrorOutput()
            let detail = AgentHookCodexAppServer.summary(String(decoding: errorBuffer, as: UTF8.self))
            return .exited(status: waitStatus.map(AgentHookSubprocess.terminationStatus) ?? -1, detail: detail)
        }

        private func terminatedForTimeout() -> AgentHookCodexAppServer.Failure {
            terminate()
            return .timedOut
        }

        /// Waits up to `seconds` for the server to exit on its own, draining stderr meanwhile so a chatty
        /// exit cannot stall on a full pipe.
        private func awaitExit(seconds: TimeInterval) -> Bool {
            let deadline = AgentHookSubprocess.monotonicDeadline(after: seconds)
            while waitStatus == nil, !reapHandedOff {
                waitStatus = try? AgentHookSubprocess.reap(processID)
                guard waitStatus == nil, AgentHookSubprocess.monotonicNow() < deadline else { break }
                var descriptors = [pollfd(fd: errorOutput, events: Int16(POLLIN), revents: 0)]
                _ = poll(&descriptors, 1, 10)
                drainErrorOutput()
            }
            return waitStatus != nil
        }

        /// Stops the server's whole process group, escalating to `SIGKILL`, and leaves a reap behind if it
        /// still has not exited. The descendant snapshot is taken first, because a launcher's child is
        /// reparented once the launcher dies and cannot be found from it afterwards.
        private func terminate() {
            guard waitStatus == nil, !reapHandedOff else { return }
            let processIDs = AgentHookProcessTree.processIDs(rootProcessID: processID)
            for signal in [SIGTERM, SIGKILL] {
                _ = kill(-processID, signal)
                for descendant in processIDs.reversed() { _ = kill(descendant, signal) }
                if awaitExit(seconds: 1) { return }
            }
            reapHandedOff = true
            AgentHookSubprocess.reapEventually(processID)
        }

        private static func setCloseOnExec(_ descriptor: Int32) -> Bool {
            let flags = fcntl(descriptor, F_GETFD)
            return flags >= 0 && fcntl(descriptor, F_SETFD, flags | FD_CLOEXEC) == 0
        }

        private static func setNonblocking(_ descriptor: Int32) -> Bool {
            let flags = fcntl(descriptor, F_GETFL)
            return flags >= 0 && fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0
        }

        private static func suppressSIGPIPE(_ descriptor: Int32) -> Bool {
            #if os(macOS)
                var yes: Int32 = 1
                return setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size)) == 0
            #else
                return true  // Linux suppresses it per write instead (`sendBytes`).
            #endif
        }
    }

    // The two calls below are named at file scope because the transport's own `send(_:deadline:)` and
    // `close()` shadow the C functions inside the class.

    private func closeDescriptor(_ descriptor: Int32) {
        guard descriptor >= 0 else { return }
        #if os(Linux)
            _ = Glibc.close(descriptor)
        #else
            _ = Darwin.close(descriptor)
        #endif
    }

    private func sendBytes(_ descriptor: Int32, _ bytes: UnsafeRawPointer, _ count: Int) -> Int {
        #if os(Linux)
            Glibc.send(descriptor, bytes, count, Int32(MSG_NOSIGNAL))
        #else
            Darwin.send(descriptor, bytes, count, 0)
        #endif
    }
#endif
