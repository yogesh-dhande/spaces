import Foundation
import spacesterminalcore

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

#if os(Linux)
    @_silgen_name("forkpty") private func spaces_forkpty(
        _ amaster: UnsafeMutablePointer<Int32>?, _ name: UnsafeMutablePointer<CChar>?, _ termp: UnsafePointer<termios>?,
        _ winp: UnsafePointer<winsize>?
    ) -> Int32
#endif

final class HostManagedPTYTerminalSessionDriver: @unchecked Sendable {
    /// Grace periods between escalating termination signals (SIGHUP already sent, then SIGTERM, then SIGKILL).
    /// Production uses generous waits; tests can shrink them so escalation paths exercise quickly.
    struct TerminationEscalationIntervals: Sendable {
        var hupGrace: TimeInterval
        var termGrace: TimeInterval
        var killGrace: TimeInterval

        static let `default` = TerminationEscalationIntervals(hupGrace: 0.5, termGrace: 2.0, killGrace: 2.0)
    }

    private let launchConfiguration: TerminalSessionLaunchConfiguration
    private let terminationEscalationIntervals: TerminationEscalationIntervals
    private let readQueue: DispatchQueue
    private let writeQueue: DispatchQueue
    private let lock = NSLock()
    private var masterFD: Int32 = -1
    private var masterFDGeneration: UInt64 = 0
    private var childPIDValue: Int32?
    private var outputHandler: (@Sendable (Data) -> Void)?
    private var onSessionClosed: (@MainActor () -> Void)?
    private var cellSize: (columns: Int, rows: Int) = (80, 24)
    private var closed = false
    private static let inheritedEnvironmentKeysRemovedForExec: Set<String> = [
        "INVOCATION_ID", "JOURNAL_STREAM", "LISTEN_FDS", "LISTEN_PID", "MAINPID", "NOTIFY_SOCKET", "SPACES_DEVICE_API_HOST", "SPACES_DEVICE_API_PORT",
        "WATCHDOG_PID", "WATCHDOG_USEC",
    ]

    init(launchConfiguration: TerminalSessionLaunchConfiguration, terminationEscalationIntervals: TerminationEscalationIntervals = .default) {
        self.launchConfiguration = launchConfiguration
        self.terminationEscalationIntervals = terminationEscalationIntervals
        readQueue = DispatchQueue(label: "spaces.terminal.host-managed-pty.read.\(launchConfiguration.sessionID)")
        writeQueue = DispatchQueue(label: "spaces.terminal.host-managed-pty.write.\(launchConfiguration.sessionID)")
    }

    func setOutputHandler(_ handler: (@Sendable (Data) -> Void)?) {
        lock.lock()
        outputHandler = handler
        lock.unlock()
    }

    func setSessionClosedHandler(_ handler: (@MainActor () -> Void)?) {
        lock.lock()
        onSessionClosed = handler
        lock.unlock()
    }

    func startIfNeeded() throws {
        lock.lock()
        let alreadyStarted = masterFD >= 0 || childPIDValue != nil
        lock.unlock()
        guard !alreadyStarted else { return }

        var master: Int32 = -1
        var windowSize = winsize(ws_row: UInt16(cellSize.rows), ws_col: UInt16(cellSize.columns), ws_xpixel: 0, ws_ypixel: 0)
        let command = Self.execCommand(for: launchConfiguration)
        #if os(macOS)
            let terminfoDirectoryPath = try Self.resolvedTerminfoDirectoryPath()
        #endif
        guard let executable = strdup(command.executable) else { throw POSIXError(.ENOMEM) }
        var arguments = command.arguments.map { strdup($0) } + [nil]
        defer {
            free(executable)
            for argument in arguments { if let argument { free(argument) } }
        }

        let pid = Self.forkPTY(master: &master, windowSize: &windowSize)
        guard pid >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        if pid == 0 {
            Self.resetSignalDispositionsForExec()
            Self.scrubInheritedEnvironmentForExec()
            Self.closeInheritedFileDescriptorsForExec()
            if !launchConfiguration.workingDirectory.isEmpty { _ = chdir(launchConfiguration.workingDirectory) }
            #if os(macOS)
                setenv("TERM", "xterm-ghostty", 1)
                setenv("TERMINFO", terminfoDirectoryPath, 1)
            #else
                setenv("TERM", "xterm-256color", 1)
            #endif
            setenv("COLORTERM", "truecolor", 1)
            execv(executable, &arguments)
            _exit(127)
        }

        lock.lock()
        masterFDGeneration &+= 1
        let fdGeneration = masterFDGeneration
        masterFD = master
        childPIDValue = pid
        closed = false
        lock.unlock()
        startReadLoop(fd: master, childPID: pid, fdGeneration: fdGeneration)
    }

    func terminate() {
        let fd: Int32
        let pid: Int32?
        var processGroupID: Int32?
        lock.lock()
        guard !closed else {
            lock.unlock()
            return
        }
        closed = true
        fd = masterFD
        masterFD = -1
        masterFDGeneration &+= 1
        pid = childPIDValue
        childPIDValue = nil
        lock.unlock()

        if let pid {
            let resolvedProcessGroupID = getpgid(pid)
            processGroupID = resolvedProcessGroupID
            let shouldSignalProcessGroup = Self.shouldSignalProcessGroup(
                childPID: pid, processGroupID: resolvedProcessGroupID, currentProcessGroupID: getpgrp())
            if ProcessInfo.processInfo.environment["DEBUG"] == "1" {
                Self.writeStandardError(
                    "spaces: pty_terminate pid=\(pid) group=\(resolvedProcessGroupID) current_group=\(getpgrp()) signal_group=\(shouldSignalProcessGroup ? 1 : 0)\n"
                )
            }
            Self.signalTerminatedPTYProcess(
                childPID: pid, processGroupID: resolvedProcessGroupID, signal: SIGHUP, signalProcessGroup: shouldSignalProcessGroup)
        }
        if fd >= 0 { close(fd) }
        if let pid, let processGroupID { reapWhenTerminated(childPID: pid, processGroupID: processGroupID) }
    }

    func sendRawBytes(_ data: Data) {
        guard !data.isEmpty else { return }
        let fd = currentMasterFD()
        guard fd >= 0 else { return }
        writeQueue.async {
            data.withUnsafeBytes { rawBuffer in
                guard let baseAddress = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return }
                var sent = 0
                while sent < data.count {
                    let written = write(fd, baseAddress.advanced(by: sent), data.count - sent)
                    if written <= 0 {
                        if errno == EINTR { continue }
                        break
                    }
                    sent += written
                }
            }
        }
    }

    @discardableResult func resizeCellGrid(columns: Int, rows: Int, pixelWidth: UInt32 = 0, pixelHeight: UInt32 = 0) -> Bool {
        let resolvedColumns = max(columns, 1)
        let resolvedRows = max(rows, 1)
        lock.lock()
        cellSize = (resolvedColumns, resolvedRows)
        let fd = masterFD
        lock.unlock()
        guard fd >= 0 else { return false }
        var windowSize = winsize(
            ws_row: UInt16(resolvedRows), ws_col: UInt16(resolvedColumns), ws_xpixel: UInt16(clamping: pixelWidth),
            ws_ypixel: UInt16(clamping: pixelHeight))
        return ioctl(fd, UInt(TIOCSWINSZ), &windowSize) == 0
    }

    func childPID() -> Int32? {
        lock.lock()
        let pid = childPIDValue
        lock.unlock()
        return Self.liveProcessID(pid)
    }

    func foregroundPID() -> Int32? {
        lock.lock()
        let fd = masterFD
        let childPID = childPIDValue
        lock.unlock()
        guard fd >= 0 else { return nil }
        var foregroundProcessGroup: Int32 = 0
        let foregroundProcessID = ioctl(fd, UInt(TIOCGPGRP), &foregroundProcessGroup) == 0 ? foregroundProcessGroup : nil
        return Self.resolvedForegroundPID(foregroundProcessGroup: foregroundProcessID, childPID: childPID)
    }

    static func resolvedForegroundPID(foregroundProcessGroup: Int32?, childPID: Int32?) -> Int32? {
        if let foregroundProcessID = liveProcessID(foregroundProcessGroup) { return foregroundProcessID }
        return liveProcessID(childPID)
    }

    static func shouldSignalProcessGroup(childPID: Int32, processGroupID: Int32, currentProcessGroupID: Int32) -> Bool {
        processGroupID > 0 && processGroupID == childPID && processGroupID != currentProcessGroupID
    }

    static func shouldRemoveInheritedEnvironmentKey(_ key: String) -> Bool { inheritedEnvironmentKeysRemovedForExec.contains(key) }

    private static func liveProcessID(_ pid: Int32?) -> Int32? {
        guard let pid, pid > 0 else { return nil }
        let status = kill(pid, 0)
        guard status == 0 || errno == EPERM else { return nil }
        return pid
    }

    func surfaceCellSize() -> (columns: Int, rows: Int) {
        lock.lock()
        let size = cellSize
        lock.unlock()
        return size
    }

    private func currentMasterFD() -> Int32 {
        lock.lock()
        let fd = masterFD
        lock.unlock()
        return fd
    }

    private func startReadLoop(fd: Int32, childPID: Int32, fdGeneration: UInt64) {
        readQueue.async { [weak self] in
            var buffer = [UInt8](repeating: 0, count: 8192)
            while true {
                let count = read(fd, &buffer, buffer.count)
                if count > 0 {
                    self?.dispatchOutput(Data(buffer.prefix(count)))
                    continue
                }
                if count < 0, errno == EINTR { continue }
                break
            }
            self?.finishAfterReadLoop(fd: fd, childPID: childPID, fdGeneration: fdGeneration)
        }
    }

    private func dispatchOutput(_ data: Data) {
        lock.lock()
        let handler = outputHandler
        lock.unlock()
        handler?(data)
    }

    private func finishAfterReadLoop(fd: Int32, childPID: Int32, fdGeneration: UInt64) {
        var shouldNotify = false
        var shouldCloseFD = false
        lock.lock()
        if Self.readLoopOwnsDescriptor(currentFD: masterFD, currentGeneration: masterFDGeneration, readFD: fd, readGeneration: fdGeneration) {
            masterFD = -1
            masterFDGeneration &+= 1
            childPIDValue = nil
            closed = true
            shouldNotify = true
            shouldCloseFD = true
        }
        let closeHandler = onSessionClosed
        lock.unlock()

        if shouldCloseFD {
            close(fd)
            reap(childPID: childPID)
        }
        if shouldNotify { Task { @MainActor in closeHandler?() } }
    }

    private func reap(childPID: Int32) {
        var status: Int32 = 0
        while waitpid(childPID, &status, WNOHANG) == -1, errno == EINTR {}
    }

    private func reapWhenTerminated(childPID: Int32, processGroupID: Int32) {
        let shouldSignalProcessGroup = Self.shouldSignalProcessGroup(
            childPID: childPID, processGroupID: processGroupID, currentProcessGroupID: getpgrp())
        let intervals = terminationEscalationIntervals
        Task.detached(priority: .utility) {
            if Self.waitForTerminatedChild(childPID, timeout: intervals.hupGrace) { return }
            Self.signalTerminatedPTYProcess(
                childPID: childPID, processGroupID: processGroupID, signal: SIGTERM, signalProcessGroup: shouldSignalProcessGroup)
            if Self.waitForTerminatedChild(childPID, timeout: intervals.termGrace) { return }
            Self.signalTerminatedPTYProcess(
                childPID: childPID, processGroupID: processGroupID, signal: SIGKILL, signalProcessGroup: shouldSignalProcessGroup)
            _ = Self.waitForTerminatedChild(childPID, timeout: intervals.killGrace)
        }
    }

    private static func signalTerminatedPTYProcess(childPID: Int32, processGroupID: Int32, signal: Int32, signalProcessGroup: Bool) {
        if signalProcessGroup { kill(-processGroupID, signal) }
        kill(childPID, signal)
    }

    private static func waitForTerminatedChild(_ childPID: Int32, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            var status: Int32 = 0
            let result = waitpid(childPID, &status, WNOHANG)
            if result == childPID { return true }
            if result == -1 {
                if errno == EINTR { continue }
                if errno == ECHILD { return true }
                return false
            }
            usleep(50_000)
        }
        return false
    }

    static func readLoopOwnsDescriptor(currentFD: Int32, currentGeneration: UInt64, readFD: Int32, readGeneration: UInt64) -> Bool {
        currentFD == readFD && currentGeneration == readGeneration
    }

    static func execCommand(for launchConfiguration: TerminalSessionLaunchConfiguration) -> (executable: String, arguments: [String]) {
        let shell = launchConfiguration.shell.isEmpty ? defaultShellPath() : launchConfiguration.shell
        let shellName = URL(fileURLWithPath: shell).lastPathComponent
        guard let command = launchConfiguration.command, !command.isEmpty else { return (shell, ["-\(shellName)"]) }

        let resolvedCommand: String
        if command.hasPrefix("direct:") {
            resolvedCommand = String(command.dropFirst("direct:".count)).trimmingCharacters(in: .whitespaces)
        } else if command.hasPrefix("shell:") {
            resolvedCommand = String(command.dropFirst("shell:".count)).trimmingCharacters(in: .whitespaces)
        } else {
            resolvedCommand = command
        }
        return (shell, [shellName, "-l", "-c", resolvedCommand])
    }

    #if os(macOS)
        private static func resolvedTerminfoDirectoryPath() throws -> String {
            switch GhosttyEmbeddedLocator.resolve(currentDirectoryPath: FileManager.default.currentDirectoryPath) {
            case .available(let paths): paths.terminfoDirectoryPath
            case .unavailable(let reason): throw GhosttyEmbeddedAppServiceError.configuration(reason)
            }
        }
    #endif

    private static func forkPTY(master: inout Int32, windowSize: inout winsize) -> Int32 {
        #if os(Linux)
            return spaces_forkpty(&master, nil, nil, &windowSize)
        #else
            return forkpty(&master, nil, nil, &windowSize)
        #endif
    }

    private static func closeInheritedFileDescriptorsForExec() {
        let rawLimit = sysconf(Int32(_SC_OPEN_MAX))
        let upperBound = rawLimit > 3 ? Int32(clamping: rawLimit) : 1024
        guard upperBound > 3 else { return }
        for fd in Int32(3)..<upperBound { _ = close(fd) }
    }

    private static func scrubInheritedEnvironmentForExec() {
        var keysToRemove = inheritedEnvironmentKeysRemovedForExec
        var cursor = environ
        while let entry = cursor.pointee {
            let line = String(cString: entry)
            if let separator = line.firstIndex(of: "=") {
                let key = String(line[..<separator])
                if shouldRemoveInheritedEnvironmentKey(key) { keysToRemove.insert(key) }
            }
            cursor = cursor.advanced(by: 1)
        }
        for key in keysToRemove { unsetenv(key) }
    }

    private static func resetSignalDispositionsForExec() {
        // Remote daemons may be launched by noninteractive shells or nohup, which can
        // leave terminal signals ignored. PTY children need defaults so VINTR/VSUSP
        // behave like a normal terminal without changing the daemon's handlers.
        for signalNumber in [SIGHUP, SIGINT, SIGQUIT, SIGTERM, SIGPIPE, SIGTSTP, SIGTTIN, SIGTTOU] { _ = signal(signalNumber, SIG_DFL) }
    }

    private static func writeStandardError(_ message: String) { FileHandle.standardError.write(Data(message.utf8)) }

    private static func defaultShellPath() -> String {
        #if os(Linux)
            return "/bin/bash"
        #else
            return "/bin/zsh"
        #endif
    }
}
