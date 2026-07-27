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
    struct HandoffWriteResult: Sendable {
        let bytesWritten: Int
        let errorCode: Int32?

        static func success(byteCount: Int) -> Self { Self(bytesWritten: byteCount, errorCode: nil) }
        static func failure(bytesWritten: Int, errorCode: Int32) -> Self { Self(bytesWritten: bytesWritten, errorCode: errorCode) }
    }

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
    private let handoffWriteAction: @Sendable (Int32, Data) -> HandoffWriteResult
    private let lock = NSLock()
    private var masterFD: Int32 = -1
    private var masterFDGeneration: UInt64 = 0
    /// The PTY leader this driver forked (or adopted across a handoff) and has NOT yet collected. Only a
    /// successful `waitpid` proves the process is gone, so `reap` is the single place this is cleared —
    /// never the read loop, whose EOF says nothing about the process (see `finishAfterReadLoop`).
    private var childPIDValue: Int32?
    private var outputHandler: (@Sendable (Data) -> Void)?
    /// Handler calls selected before a handoff sink swap execute outside `lock` and
    /// may block in Ghostty processing. Quiesce awaits these calls before closing the
    /// transcript so their resulting output cannot arrive after the handoff boundary.
    private var handlerDeliveriesInFlight = 0
    private var handlerDeliveryWaiters: [CheckedContinuation<Void, Never>] = []
    private var onSessionClosed: (@TerminalEngineActor () -> Void)?
    private var cellSize: (columns: Int, rows: Int) = (80, 24)
    /// The SESSION is over: input is refused and a handoff snapshot returns nil. Set by `terminate()` and by
    /// the read loop reaching EOF. It says nothing about the child — see `childPIDValue`.
    private var closed = false
    /// An escalation task owns ending and collecting the leader. Whoever sets this — `terminate()`, or the
    /// read loop when its own reap comes up empty — is the only party that may `waitpid` or signal the child
    /// from then on, so the two can never race a double reap (and a signal to a reused pid).
    private var escalationOwnsLeader = false
    /// Set once the PTY read loop has exited — its `read()` returned (every descriptor on the slave has
    /// been closed) and `finishAfterReadLoop` has closed the master fd. This is one of the two conditions
    /// the termination escalation requires before it stops signaling; reaping the leader is the other, and
    /// neither implies the other (see `escalationWaitForTeardown`). Only touched under `lock`.
    private var readLoopFinished = false
    /// Where the read loop delivers PTY bytes. The exec-in-place handoff walks this
    /// through `.handler` → `.buffer` → `.file` so that not one byte is lost,
    /// duplicated, or reordered across the transition: reads are serialized on
    /// `readQueue`, and every delivery routes through `dispatchOutput` under `lock`,
    /// so a sink swap made under the same lock is atomic with respect to delivery.
    private enum OutputSink {
        /// Normal delivery: invoke `outputHandler` (the only steady state).
        case handler
        /// Handoff buffering: reads append to `handoffBuffer` while the daemon drains
        /// queued work and closes the durable output handle, until the file writer
        /// takes over in `finishHandoffOutputBuffering`.
        case buffer
        /// Handoff direct-write: reads are written straight to the append-only output
        /// file (with `O_CLOEXEC`) until `execv` destroys this image.
        case file(fd: Int32)
    }
    private var outputSink: OutputSink = .handler
    /// Bytes read while the sink is `.buffer`, flushed to the file the moment
    /// `finishHandoffOutputBuffering` opens it. Only touched under `lock`.
    private var handoffBuffer = Data()
    /// First direct-writer failure. Once set, subsequent PTY bytes stay buffered and
    /// the daemon must refuse exec so the current image can restore normal delivery.
    private var handoffWriteErrorCode: Int32?
    private static let inheritedEnvironmentKeysRemovedForExec: Set<String> = [
        "INVOCATION_ID", "JOURNAL_STREAM", "LISTEN_FDS", "LISTEN_PID", "MAINPID", "NOTIFY_SOCKET", "SPACES_DEVICE_API_HOST", "SPACES_DEVICE_API_PORT",
        "WATCHDOG_PID", "WATCHDOG_USEC",
    ]

    init(
        launchConfiguration: TerminalSessionLaunchConfiguration, terminationEscalationIntervals: TerminationEscalationIntervals = .default,
        handoffWriteAction: (@Sendable (Int32, Data) -> HandoffWriteResult)? = nil
    ) {
        self.launchConfiguration = launchConfiguration
        self.terminationEscalationIntervals = terminationEscalationIntervals
        self.handoffWriteAction = handoffWriteAction ?? Self.writeAll
        readQueue = DispatchQueue(label: "spaces.terminal.host-managed-pty.read.\(launchConfiguration.sessionID)")
        writeQueue = DispatchQueue(label: "spaces.terminal.host-managed-pty.write.\(launchConfiguration.sessionID)")
    }

    func setOutputHandler(_ handler: (@Sendable (Data) -> Void)?) {
        lock.lock()
        outputHandler = handler
        lock.unlock()
    }

    func setSessionClosedHandler(_ handler: (@TerminalEngineActor () -> Void)?) {
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

    /// Resume side of the exec-in-place handoff: adopt a PTY master fd and its child
    /// pid that this process already owns (the fd survived `execv` with `FD_CLOEXEC`
    /// cleared; the child stays our child, so `waitpid`/exit statuses keep working).
    /// No `forkpty`, no new child, and no `termios`/`TIOCSWINSZ`: the kernel PTY
    /// object kept its window size across exec, and the session core re-asserts the
    /// grid separately during resume. After this returns the driver behaves exactly
    /// like a forked one — input via `sendRawBytes`, resize via `resizeCellGrid`,
    /// `terminate()` escalation, reap-on-exit, and the closed handler all apply.
    func adopt(masterFD: Int32, childPID: Int32) {
        lock.lock()
        // Adoption is only valid on a driver in its never-started state; reusing the
        // fd-generation discipline keeps a would-be stale read loop from ever acting
        // on this descriptor.
        precondition(self.masterFD < 0 && childPIDValue == nil && !closed, "adopt requires a driver in its never-started state")
        masterFDGeneration &+= 1
        let fdGeneration = masterFDGeneration
        self.masterFD = masterFD
        childPIDValue = childPID
        closed = false
        lock.unlock()
        startReadLoop(fd: masterFD, childPID: childPID, fdGeneration: fdGeneration)
    }

    /// The live PTY master fd and child pid to carry across the handoff, or nil when
    /// there is nothing to hand off — the session never started, already closed, or
    /// its child was already reaped. Callers clear `FD_CLOEXEC` on the returned fd
    /// (via `DaemonHandoffStore.prepareDescriptorForHandoff`) before `execv`.
    func handoffDescriptorSnapshot() -> (masterFD: Int32, childPID: Int32)? {
        lock.lock()
        defer { lock.unlock() }
        guard !closed, masterFD >= 0, let pid = childPIDValue else { return nil }
        return (masterFD, pid)
    }

    /// First handoff step: swap output delivery from the handler to an in-memory
    /// buffer so PTY bytes keep being drained (the read loop must never block) while
    /// the daemon quiesces and closes the durable output handle. Nothing is lost —
    /// buffered bytes are flushed by `finishHandoffOutputBuffering`.
    func beginHandoffOutputBuffering() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            handoffWriteErrorCode = nil
            outputSink = .buffer
            guard handlerDeliveriesInFlight > 0 else {
                lock.unlock()
                continuation.resume()
                return
            }
            handlerDeliveryWaiters.append(continuation)
            lock.unlock()
        }
    }

    /// Second handoff step: open `path` for append and take over delivery. Opens with
    /// a raw `open(2)` (not `FileHandle`) so `O_CLOEXEC` is set at open time and the
    /// fd vanishes at `execv` without renumbering anything. Flushes the accumulated
    /// buffer with a full-write loop, then installs a direct-to-fd writer so every
    /// subsequent read lands in the file synchronously and in order until exec.
    /// Crash-clean: if the open fails the throw leaves in-memory buffering active; if
    /// the flush write fails the buffer is restored and buffering stays active.
    func finishHandoffOutputBuffering(appendingTo path: String) throws {
        let fd = open(path, O_WRONLY | O_APPEND | O_CLOEXEC)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }

        lock.lock()
        let pending = handoffBuffer
        handoffBuffer = Data()
        let result = handoffWriteAction(fd, pending)
        guard result.errorCode == nil, result.bytesWritten == pending.count else {
            // No delivery can run under the lock. Preserve only the unwritten suffix:
            // a short write's prefix is already durable and replaying it would duplicate output.
            handoffBuffer = Data(pending.dropFirst(min(max(result.bytesWritten, 0), pending.count)))
            lock.unlock()
            close(fd)
            throw POSIXError(POSIXErrorCode(rawValue: result.errorCode ?? EIO) ?? .EIO)
        }
        outputSink = .file(fd: fd)
        lock.unlock()
    }

    /// Holds the sink lock from the final persistence check through `operation`.
    /// PTY reads therefore cannot begin another direct write between validation and
    /// `execv`; a returned exec unwinds the lock and takes the normal fallback path.
    func withValidatedHandoffOutputForExec<T>(_ operation: () throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        if let handoffWriteErrorCode { throw POSIXError(POSIXErrorCode(rawValue: handoffWriteErrorCode) ?? .EIO) }
        guard case .file(let fd) = outputSink else { throw POSIXError(.EIO) }
        guard fsync(fd) == 0 else {
            let code = errno
            handoffWriteErrorCode = code
            outputSink = .buffer
            close(fd)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        return try operation()
    }

    /// First failed-handoff fallback step: atomically stop direct transcript appends and
    /// return to buffering. The core can then replay the already-persisted handoff range
    /// into its renderer and position its normal transcript handle without either action
    /// racing another append from this driver.
    func pauseHandoffOutputForFallback() {
        lock.lock()
        if case .file(let fd) = outputSink { close(fd) }
        outputSink = .buffer
        lock.unlock()
    }

    /// Final failed-handoff fallback step: reinstate normal handler delivery and replay
    /// bytes accumulated after the direct writer was stopped. The core must first replay
    /// the persisted handoff range into its renderer and reopen its normal output handle;
    /// these pending bytes then take the ordinary render-and-persist path exactly once.
    func endHandoffOutputBuffering() {
        lock.lock()
        if case .file(let fd) = outputSink { close(fd) }
        let pending = handoffBuffer
        let handler = outputHandler
        handoffBuffer = Data()

        // Deliver the older buffered batch before exposing `.handler`. Holding the sink
        // lock briefly backpressures the PTY read loop, so a concurrently read byte cannot
        // overtake this batch and continuous output cannot keep fallback in a drain loop.
        if !pending.isEmpty { handler?(pending) }
        handoffWriteErrorCode = nil
        outputSink = .handler
        lock.unlock()
    }

    /// Tears the session down WITHOUT ever blocking the calling actor.
    ///
    /// terminate() now runs on the terminal ENGINE executor. `close(master)` blocks in the kernel until
    /// the PTY reader unblocks, and `waitpid` blocks until the child dies — doing either here would
    /// freeze the very engine this migration exists to protect. (In the pre-actor architecture the same
    /// blocking `close(master)` landed only on the main actor and was accepted as won't-fix; that
    /// acceptance does NOT carry over now that the blocking would land on the engine executor.)
    ///
    /// So terminate() does only synchronous bookkeeping (mark `closed` for the observable contract —
    /// input refused, a handoff snapshot returns nil — and `escalationOwnsLeader`) plus the graceful SIGHUP,
    /// then hands the rest off:
    /// - The master fd's read-loop ownership (`masterFD`/`masterFDGeneration`) is left INTACT. The read
    ///   loop closes the fd from `finishAfterReadLoop` the moment `read()` returns (once the slave is fully
    ///   closed) — a close with no pending read, so it never blocks.
    /// - `escalateUntilLeaderIsCollected` runs the TERM→KILL escalation on a detached task; its SIGKILL of
    ///   the child process group forces the child dead — and thus the read to return — if SIGHUP is ignored,
    ///   and it owns the `waitpid`.
    ///
    /// A session already `closed` returns here having done nothing, which is correct rather than a gap: the
    /// only way to be closed is that `terminate()` already ran or the read loop hit EOF, and both hand the
    /// leader to the escalation, so the child always has an owner without this call adding a second one.
    ///
    /// Handoff invariant: `handoffDescriptorSnapshot`/`quiesceForHandoff` never coincide with terminate()
    /// (the daemon hands a session off OR terminates it, never both), and both gate on `closed` under
    /// `lock`, so a snapshot can never observe a half-terminated descriptor.
    func terminate() {
        let pid: Int32?
        lock.lock()
        guard !closed else {
            lock.unlock()
            return
        }
        closed = true
        escalationOwnsLeader = true
        pid = childPIDValue
        lock.unlock()

        guard let pid else { return }
        let resolvedProcessGroupID = getpgid(pid)
        let shouldSignalProcessGroup = Self.shouldSignalProcessGroup(
            childPID: pid, processGroupID: resolvedProcessGroupID, currentProcessGroupID: getpgrp())
        if ProcessInfo.processInfo.environment["DEBUG"] == "1" {
            Self.writeStandardError(
                "spaces: pty_terminate pid=\(pid) group=\(resolvedProcessGroupID) current_group=\(getpgrp()) signal_group=\(shouldSignalProcessGroup ? 1 : 0)\n"
            )
        }
        Self.signalTerminatedPTYProcess(
            childPID: pid, processGroupID: resolvedProcessGroupID, signal: SIGHUP, signalProcessGroup: shouldSignalProcessGroup)
        escalateUntilLeaderIsCollected(childPID: pid, processGroupID: resolvedProcessGroupID)
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

    /// Suspends until every byte handed to `sendRawBytes` has been written to the PTY master. `writeQueue`
    /// is serial, so a trailing async barrier resolves only after all prior write blocks complete. Used by
    /// handoff quiesce so an `execv` cannot drop input still buffered in the write queue.
    func drainPendingWrites() async { await withCheckedContinuation { continuation in writeQueue.async { continuation.resume() } } }

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
        // After terminate() the master fd is still open (the read loop closes it when read() returns),
        // but the session is `closed`, so refuse further input writes rather than write to a dying PTY.
        let fd = closed ? -1 : masterFD
        lock.unlock()
        return fd
    }

    private func startReadLoop(fd: Int32, childPID: Int32, fdGeneration: UInt64) {
        // `guard let self` keeps the driver alive for the read loop's lifetime, so the deferred fd close
        // in `finishAfterReadLoop` always runs even after `terminate()` releases the owning driver — the
        // escalation in `escalateUntilLeaderIsCollected` guarantees the loop ends (SIGKILL → read returns),
        // so this is a bounded lifetime, not a leak.
        readQueue.async { [weak self] in
            guard let self else { return }
            var buffer = [UInt8](repeating: 0, count: 8192)
            while true {
                let count = read(fd, &buffer, buffer.count)
                if count > 0 {
                    self.dispatchOutput(Data(buffer.prefix(count)))
                    continue
                }
                if count < 0, errno == EINTR { continue }
                break
            }
            self.finishAfterReadLoop(fd: fd, childPID: childPID, fdGeneration: fdGeneration)
        }
    }

    private func dispatchOutput(_ data: Data) {
        lock.lock()
        switch outputSink {
        case .handler:
            let handler = outputHandler
            if handler != nil { handlerDeliveriesInFlight += 1 }
            lock.unlock()
            guard let handler else { return }
            handler(data)

            let waiters: [CheckedContinuation<Void, Never>]
            lock.lock()
            handlerDeliveriesInFlight -= 1
            if handlerDeliveriesInFlight == 0 {
                waiters = handlerDeliveryWaiters
                handlerDeliveryWaiters.removeAll()
            } else {
                waiters = []
            }
            lock.unlock()
            for waiter in waiters { waiter.resume() }
        case .buffer:
            handoffBuffer.append(data)
            lock.unlock()
        case .file(let fd):
            // Write synchronously while holding the lock so the read loop cannot
            // interleave a later chunk ahead of this one and a concurrent sink swap
            // cannot slip in mid-write. Writes target a regular file, not a pipe, so
            // this does not block on a reader.
            let result = handoffWriteAction(fd, data)
            if result.errorCode != nil || result.bytesWritten != data.count {
                handoffBuffer.append(data.dropFirst(min(max(result.bytesWritten, 0), data.count)))
                handoffWriteErrorCode = result.errorCode ?? EIO
                outputSink = .buffer
                close(fd)
            }
            lock.unlock()
        }
    }

    /// The read loop ended, meaning `read()` on the master returned: every descriptor on the PTY slave is
    /// closed. That is a fact about DESCRIPTORS, not about the leader process, and conflating the two is
    /// what makes a session report a child gone while it is still running:
    ///
    /// - It ends the SESSION. Nothing can ever be read from or written to this terminal again, so the master
    ///   fd is released, `closed` is set, and the closed handler fires.
    /// - It does NOT mean the leader is gone. It may have exited (the ordinary case); it may be mid-exit,
    ///   because the kernel closes an exiting process's descriptors before marking it a zombie, so a
    ///   `waitpid` racing that transition truthfully reports "not exited yet"; or it may have closed its own
    ///   stdio and kept running, releasing the slave while very much alive.
    ///
    /// So the leader is only declared gone when `waitpid` collects it. If the immediate reap comes up empty
    /// the leader is handed to `escalateUntilLeaderIsCollected` — the single owner of ending and collecting
    /// it, the same one `terminate()` uses — which polls the mid-exit case out and signals the survivor dead.
    /// The driver forked this child, so it owns that: nothing else in the process reaps it, and a caller's
    /// later `terminate()` cannot, having returned at its `closed` guard.
    private func finishAfterReadLoop(fd: Int32, childPID: Int32, fdGeneration: UInt64) {
        var shouldNotify = false
        var shouldCloseFD = false
        var ownsLeaderTeardown = false
        lock.lock()
        if Self.readLoopOwnsDescriptor(currentFD: masterFD, currentGeneration: masterFDGeneration, readFD: fd, readGeneration: fdGeneration) {
            masterFD = -1
            masterFDGeneration &+= 1
            closed = true
            shouldNotify = true
            shouldCloseFD = true
            // Take the leader only if no escalation already owns it. When an explicit `terminate()` is
            // unwinding it owns the `waitpid` and the signals, so touching the child here would race a
            // double reap and a signal to a possibly-reused pid.
            ownsLeaderTeardown = !escalationOwnsLeader
            escalationOwnsLeader = true
        }
        let closeHandler = onSessionClosed
        lock.unlock()

        if shouldCloseFD {
            // The read has already returned, so the master fd has no pending reader; this close never blocks.
            close(fd)
        }
        // Publish read-loop exit AFTER the fd close so the termination escalation only stops once the fd is
        // actually gone (see `readLoopFinished`). The escalation polls this to know the slave was released.
        lock.lock()
        readLoopFinished = true
        lock.unlock()
        if ownsLeaderTeardown, !reap(childPID: childPID) {
            // Not collectable yet: the leader is either mid-exit or still running with its stdio closed. The
            // escalation polls the first case out and signals the second dead; it cannot tell them apart
            // from here, and does not need to.
            escalateUntilLeaderIsCollected(childPID: childPID, processGroupID: getpgid(childPID))
        }
        if shouldNotify { Task { @TerminalEngineActor in closeHandler?() } }
    }

    /// Non-blocking attempt to collect the PTY leader's exit status. Never waits, so callers can invoke
    /// it repeatedly. Returns whether the leader is gone for good: either this call collected it, or it
    /// is no longer a child of ours (`ECHILD` — an earlier call already collected it). A leader that
    /// exists but has not exited yet reports false, so a polling caller knows to keep trying.
    ///
    /// This is also the one place `childPIDValue` is cleared, because collecting the child is the one event
    /// that proves it is gone; every other signal (EOF on the master, a `kill` returning, `closed`) is
    /// consistent with a process that is still running.
    @discardableResult private func reap(childPID: Int32) -> Bool {
        var status: Int32 = 0
        var leaderIsGone = false
        while true {
            let collected = waitpid(childPID, &status, WNOHANG)
            if collected > 0 {
                leaderIsGone = true
                break
            }
            if collected == 0 { break }
            if errno == EINTR { continue }
            // Any error other than ECHILD is not recoverable by retrying, and reporting "not collected"
            // leaves the escalation running rather than declaring a teardown that did not happen.
            leaderIsGone = errno == ECHILD
            break
        }
        if leaderIsGone {
            lock.lock()
            if childPIDValue == childPID { childPIDValue = nil }
            lock.unlock()
        }
        return leaderIsGone
    }

    /// Drives the leader dead and collects it, on a detached task so no caller ever blocks on a `waitpid`.
    /// Entered from `terminate()` (which has already sent the graceful SIGHUP) and from the read loop when
    /// its own reap found the leader still uncollected; `escalationOwnsLeader` guarantees exactly one of
    /// them runs it for a given child.
    ///
    /// `self` is captured STRONGLY: this task is what owns the child's teardown, and the owning session core
    /// drops its driver reference as soon as a session reports closed — a weak capture would let the last
    /// reference go while the leader is still alive, abandoning both the signals and the reap. The capture is
    /// bounded by the three stage deadlines below, so it delays deallocation by seconds, never indefinitely.
    private func escalateUntilLeaderIsCollected(childPID: Int32, processGroupID: Int32) {
        let shouldSignalProcessGroup = Self.shouldSignalProcessGroup(
            childPID: childPID, processGroupID: processGroupID, currentProcessGroupID: getpgrp())
        let intervals = terminationEscalationIntervals
        Task.detached(priority: .utility) { [self] in
            // The first stage sends nothing: it is the grace window for a leader that is already on its way
            // out — the SIGHUP terminate() just sent, or the exit that ended the read loop. Escalate from
            // there to SIGTERM then SIGKILL, keying each stage on the full teardown — the read loop exited
            // AND the leader was collected — because either alone can hold while the other does not (see
            // `escalationWaitForTeardown`). Each stage signals the child's PROCESS GROUP so descendants
            // holding the slave die too.
            if self.escalationWaitForTeardown(reapingLeader: childPID, timeout: intervals.hupGrace) { return }
            Self.signalTerminatedPTYProcess(
                childPID: childPID, processGroupID: processGroupID, signal: SIGTERM, signalProcessGroup: shouldSignalProcessGroup)
            if self.escalationWaitForTeardown(reapingLeader: childPID, timeout: intervals.termGrace) { return }
            Self.signalTerminatedPTYProcess(
                childPID: childPID, processGroupID: processGroupID, signal: SIGKILL, signalProcessGroup: shouldSignalProcessGroup)
            _ = self.escalationWaitForTeardown(reapingLeader: childPID, timeout: intervals.killGrace)
            // A group SIGKILL releases the slave from every process still in the child's group, which unblocks
            // read(). We deliberately do NOT force-close the master as a further bound: the read loop owns the
            // fd's close (guarded by `masterFDGeneration`), and closing it from here would race that read/close
            // and risk operating on a reused fd number. The one unrecoverable case — a descendant that fully
            // detached into its own session (setsid) AND re-opened the controlling tty — is beyond a group
            // signal's reach; leaving read() blocked there is safer than an fd-reuse crash and is accepted.
        }
    }

    /// Polls until this session's teardown is complete within `timeout`, which takes BOTH:
    ///
    /// - the PTY read loop has exited — `read()` returned and `finishAfterReadLoop` closed the master fd,
    ///   setting `readLoopFinished`; and
    /// - the leader `childPID` has been collected by `waitpid`.
    ///
    /// Returns true once both hold, false to escalate to the next signal stage.
    ///
    /// A stage cannot key on either condition alone, because neither implies the other:
    ///
    /// - The read loop can stay blocked after the leader is gone. A backgrounded descendant (a `nohup`
    ///   job, say) inherits the PTY slave and holds it open, so `read()` never returns. Stopping on the
    ///   reap alone would leak the master fd and this driver, and the closed handler would never fire.
    /// - The leader can stay uncollected after the read loop exits, in two ways. A process that closes its
    ///   stdio and keeps running releases the slave while alive; and even an ordinary exit closes the
    ///   process's descriptors before the kernel marks it a zombie, so a `waitpid` racing that transition
    ///   truthfully reports "not exited yet". Stopping on the read loop alone would leave a live process or
    ///   a zombie with no later reaper: this escalation holds `escalationOwnsLeader` for its whole run, so a
    ///   stage that returns without collecting the leader is the last look anything takes at it.
    ///
    /// Requiring both makes each the other's backstop — whichever lags, the stage runs to its deadline and
    /// escalates, and the eventual SIGKILL of the process group ends both a slave-holding descendant and a
    /// leader that ignored the gentler signals.
    ///
    /// Because `escalationOwnsLeader` admits one escalation per child, these `waitpid` calls cannot
    /// double-reap.
    private func escalationWaitForTeardown(reapingLeader childPID: Int32, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        var leaderCollected = false
        while true {
            // Reap on every pass, not just once the read loop has exited, so a leader that dies while a
            // descendant still holds the slave does not sit as a zombie for the rest of the wait.
            if !leaderCollected { leaderCollected = reap(childPID: childPID) }
            lock.lock()
            let readLoopExited = readLoopFinished
            lock.unlock()
            if readLoopExited, leaderCollected { return true }
            if Date() >= deadline { return false }
            usleep(50_000)
        }
    }

    private static func signalTerminatedPTYProcess(childPID: Int32, processGroupID: Int32, signal: Int32, signalProcessGroup: Bool) {
        if signalProcessGroup { kill(-processGroupID, signal) }
        kill(childPID, signal)
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
        // A forked child also inherits the calling THREAD's signal mask, and the daemon starts sessions
        // on the terminal engine executor — a libdispatch worker thread, which blocks terminal signals so
        // they are delivered to the main thread instead. A PTY child that inherits SIGHUP/SIGTERM blocked
        // cannot be gracefully terminated: the signals stay pending and its shell's traps never run, so
        // `terminate()`'s HUP→TERM escalation is silently ineffective (only the final SIGKILL lands).
        // Reset the mask to empty so the child starts as if spawned from a normal terminal.
        var emptyMask = sigset_t()
        sigemptyset(&emptyMask)
        sigprocmask(SIG_SETMASK, &emptyMask, nil)
    }

    private static func writeStandardError(_ message: String) { FileHandle.standardError.write(Data(message.utf8)) }

    /// Full-write loop for the handoff file sink. The result identifies the durable
    /// prefix so a failed handoff can replay only the unwritten suffix without loss or duplication.
    private static func writeAll(fd: Int32, data: Data) -> HandoffWriteResult {
        guard !data.isEmpty else { return .success(byteCount: 0) }
        return data.withUnsafeBytes { rawBuffer -> HandoffWriteResult in
            guard let baseAddress = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return .failure(bytesWritten: 0, errorCode: EIO) }
            var sent = 0
            while sent < data.count {
                let written = write(fd, baseAddress.advanced(by: sent), data.count - sent)
                if written <= 0 {
                    if written < 0, errno == EINTR { continue }
                    return .failure(bytesWritten: sent, errorCode: written < 0 ? errno : EIO)
                }
                sent += written
            }
            return .success(byteCount: sent)
        }
    }

    private static func defaultShellPath() -> String {
        #if os(Linux)
            return "/bin/bash"
        #else
            return "/bin/zsh"
        #endif
    }
}
