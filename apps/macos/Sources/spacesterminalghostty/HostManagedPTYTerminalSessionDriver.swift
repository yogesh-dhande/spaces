import Darwin
import Foundation
import spacesterminalcore

final class HostManagedPTYTerminalSessionDriver: @unchecked Sendable {
    private let launchConfiguration: TerminalSessionLaunchConfiguration
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

    init(launchConfiguration: TerminalSessionLaunchConfiguration) {
        self.launchConfiguration = launchConfiguration
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
        guard let executable = strdup(command.executable) else { throw POSIXError(.ENOMEM) }
        var arguments = command.arguments.map { strdup($0) } + [nil]
        defer {
            free(executable)
            for argument in arguments { if let argument { free(argument) } }
        }

        let pid = forkpty(&master, nil, nil, &windowSize)
        guard pid >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        if pid == 0 {
            if !launchConfiguration.workingDirectory.isEmpty { _ = chdir(launchConfiguration.workingDirectory) }
            setenv("TERM", "xterm-256color", 1)
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
            let processGroupID = getpgid(pid)
            if processGroupID == pid { kill(-processGroupID, SIGHUP) }
            kill(pid, SIGHUP)
        }
        if fd >= 0 { close(fd) }
        if let pid { reapWhenTerminated(childPID: pid) }
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
        return ioctl(fd, TIOCSWINSZ, &windowSize) == 0
    }

    func childPID() -> Int32? {
        lock.lock()
        let pid = childPIDValue
        lock.unlock()
        guard let pid, pid > 0 else { return nil }
        let status = kill(pid, 0)
        guard status == 0 || errno == EPERM else { return nil }
        return pid
    }

    func foregroundPID() -> Int32? {
        lock.lock()
        let fd = masterFD
        lock.unlock()
        guard fd >= 0 else { return nil }
        var foregroundProcessGroup: Int32 = 0
        guard ioctl(fd, TIOCGPGRP, &foregroundProcessGroup) == 0, foregroundProcessGroup > 0 else { return nil }
        let status = kill(foregroundProcessGroup, 0)
        guard status == 0 || errno == EPERM else { return nil }
        return foregroundProcessGroup
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

    private func reapWhenTerminated(childPID: Int32) {
        Task.detached(priority: .utility) {
            var status: Int32 = 0
            while waitpid(childPID, &status, 0) == -1, errno == EINTR {}
        }
    }

    static func readLoopOwnsDescriptor(currentFD: Int32, currentGeneration: UInt64, readFD: Int32, readGeneration: UInt64) -> Bool {
        currentFD == readFD && currentGeneration == readGeneration
    }

    static func execCommand(for launchConfiguration: TerminalSessionLaunchConfiguration) -> (executable: String, arguments: [String]) {
        let shell = launchConfiguration.shell.isEmpty ? "/bin/zsh" : launchConfiguration.shell
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
}
