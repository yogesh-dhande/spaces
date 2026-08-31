#if os(Linux)
    import Foundation
    import Glibc
    import Testing
    import spacesterminalcore

    @testable import spacesterminalghostty

    /// Verifies that a program's OSC 52 copy inside a Linux headless session reaches the client that
    /// owns the session — the machine the user is typing on — and nowhere else. The daemon writes no
    /// clipboard of its own: on a Linux host there is usually no one at the keyboard, and the copy is
    /// meaningless anywhere but on the owner's device.
    ///
    /// These drive real OSC 52 bytes through a real PTY child and read the payloads off the session's
    /// real subscription socket, so they exercise the whole path: PTY output -> vt session -> shim
    /// clipboard event -> owner resolution -> state-stream broadcast.
    ///
    /// Swift Testing and a nonisolated body for the same reasons as
    /// `GhosttyLinuxHeadlessSessionBellTests`; `.serialized` because each test mutates the
    /// process-wide SPACES_* environment and owns a real PTY child.
    @Suite(.serialized) final class GhosttyLinuxHeadlessSessionClipboardTests {
        private let originalDatabasePath: String?
        private let originalRuntimeDirectory: String?
        private let databaseRoot: URL

        /// Carries an engine-isolated reference back out to the nonisolated test body; the value is only
        /// ever *used* on the engine actor via a later bridge.
        private final class Box<Value>: @unchecked Sendable {
            let value: Value
            init(_ value: Value) { self.value = value }
        }

        /// A real subscriber on the session's state-stream socket. Payloads are read on a dedicated
        /// thread so the test can assert about broadcasts without depending on any actor being drained.
        private final class StateStreamSubscriber: @unchecked Sendable {
            private let lock = NSLock()
            private var payloads: [GhosttyRemoteSessionStatePayload] = []
            private var socketFD: Int32 = -1
            private var stopped = false

            func start(socketPath: String) throws {
                let fd = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
                guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                var address = sockaddr_un()
                address.sun_family = sa_family_t(AF_UNIX)
                let pathBytes = Array(socketPath.utf8)
                try withUnsafeMutableBytes(of: &address.sun_path) { raw in
                    guard pathBytes.count < raw.count else { throw POSIXError(.ENAMETOOLONG) }
                    raw.copyBytes(from: pathBytes)
                }
                let connected = withUnsafePointer(to: &address) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                        connect(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
                    }
                }
                guard connected == 0 else {
                    close(fd)
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                socketFD = fd
                let thread = Thread { [weak self] in self?.readLoop(fd) }
                thread.start()
            }

            func stop() {
                lock.lock()
                let fd = socketFD
                stopped = true
                socketFD = -1
                lock.unlock()
                guard fd >= 0 else { return }
                // Shut the socket down before closing so the reader thread's blocking `read` returns
                // instead of sitting on a descriptor the test has already released.
                shutdown(fd, Int32(SHUT_RDWR))
                close(fd)
            }

            /// Every clipboard write broadcast so far, in arrival order.
            func clipboardWrites() -> [TerminalClipboardWritePayload] {
                lock.lock()
                defer { lock.unlock() }
                return payloads.filter { $0.reasonKind == .clipboardWrite }.compactMap(\.clipboardWrite)
            }

            /// Reasons seen so far, so a test can settle on an unrelated broadcast before asserting that
            /// no clipboard write arrived.
            func reasons() -> [String] {
                lock.lock()
                defer { lock.unlock() }
                return payloads.map(\.reason)
            }

            private func readLoop(_ fd: Int32) {
                var pending = Data()
                var buffer = [UInt8](repeating: 0, count: 64 * 1024)
                while true {
                    let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
                    if count <= 0 { return }
                    pending.append(contentsOf: buffer[0..<count])
                    while let newlineIndex = pending.firstIndex(of: 0x0A) {
                        let line = pending[pending.startIndex..<newlineIndex]
                        pending = pending[pending.index(after: newlineIndex)...]
                        guard let payload = try? GhosttyRemoteSessionStateCodec.decodeLine(Data(line)) else { continue }
                        lock.lock()
                        if !stopped { payloads.append(payload) }
                        lock.unlock()
                    }
                }
            }
        }

        init() throws {
            originalDatabasePath = ProcessInfo.processInfo.environment["SPACES_DB_PATH"]
            originalRuntimeDirectory = ProcessInfo.processInfo.environment["SPACES_RUNTIME_DIR"]
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            databaseRoot = root
            setenv("SPACES_DB_PATH", root.appendingPathComponent("spaces.db").path, 1)
            setenv("SPACES_RUNTIME_DIR", root.appendingPathComponent("runtime", isDirectory: true).path, 1)
        }

        deinit {
            if let originalDatabasePath { setenv("SPACES_DB_PATH", originalDatabasePath, 1) } else { unsetenv("SPACES_DB_PATH") }
            if let originalRuntimeDirectory { setenv("SPACES_RUNTIME_DIR", originalRuntimeDirectory, 1) } else { unsetenv("SPACES_RUNTIME_DIR") }
            try? FileManager.default.removeItem(at: databaseRoot)
        }

        // MARK: - Fixtures

        private func makeTemporaryPaths() throws -> TerminalSessionPaths {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let paths = TerminalSessionPaths(rootDirectory: root.path)
            try paths.ensureDirectories()
            return paths
        }

        /// A shell that waits for the test's go-file before emitting `script`, so the test can attach an
        /// owner and subscribe before the OSC 52 is written. It then prints a settle marker and blocks on
        /// `cat` so the session stays live.
        private func makeConfiguration(named name: String, goFile: String, script: String) -> TerminalSessionLaunchConfiguration {
            TerminalSessionLaunchConfiguration(
                sessionID: "\(name)-\(UUID().uuidString)", backend: .ghosttyEmbedded, title: "clipboard-title",
                workingDirectory: FileManager.default.temporaryDirectory.path, shell: "/bin/sh",
                command: "stty -echo; while [ ! -f \(goFile) ]; do sleep 0.05; done; \(script); printf 'SETTLED\\n'; cat",
                createdAt: "2026-07-28T00:00:00Z", workspaceID: "workspace-clipboard", kind: .shell)
        }

        private func startCore(_ configuration: TerminalSessionLaunchConfiguration, paths: TerminalSessionPaths) async throws -> Box<
            GhosttyEmbeddedSessionCore
        > {
            try await TerminalEngineActor.run { () -> Box<GhosttyEmbeddedSessionCore> in
                let core = GhosttyEmbeddedSessionCore(launchConfiguration: configuration, paths: paths)
                try core.startIfNeeded()
                return Box(core)
            }
        }

        /// Attaches through the session's own control request, the only way a client ever reaches a
        /// session: the core resolves the clipboard's owner from the attachment state it holds in memory,
        /// so a client written straight into the database would be a client this session never saw.
        @discardableResult private func attachOwner(_ core: GhosttyEmbeddedSessionCore, clientID: String = "owner-client") -> String {
            TerminalEngineActor.runSynchronously { Self.attachOwner(core, clientID: clientID) }
            return clientID
        }

        @TerminalEngineActor private static func attachOwner(_ core: GhosttyEmbeddedSessionCore, clientID: String) {
            let client = TerminalClient(
                id: clientID, kind: .remoteViewer, identity: TerminalClientIdentity(label: "iPhone"), connectedAt: "2026-07-28T00:00:01Z")
            let response = core.handleControlRequest(TerminalControlRequest(command: "attach", client: client, attachmentMode: .owner))
            #expect(response.ok, "attaching the clipboard owner must succeed: \(response.message)")
        }

        private func releaseChild(_ goFile: String) { _ = FileManager.default.createFile(atPath: goFile, contents: nil) }

        private func waitForSettledTranscript(_ path: String, marker: String = "SETTLED", timeout: TimeInterval = 30) async throws {
            let deadline = Date().addingTimeInterval(timeout)
            func transcript() -> String { (try? String(contentsOfFile: path, encoding: .utf8)) ?? "" }
            while Date() < deadline {
                if transcript().contains(marker) { return }
                try? await Task.sleep(for: .milliseconds(30))
            }
            Issue.record("the transcript never carried the \(marker) marker")
        }

        private func waitFor(
            timeout: TimeInterval = 30, sourceLocation: SourceLocation = #_sourceLocation, _ condition: @escaping @Sendable () -> Bool
        ) async throws {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if condition() { return }
                try? await Task.sleep(for: .milliseconds(30))
            }
            #expect(condition(), "waitFor timed out", sourceLocation: sourceLocation)
        }

        /// `printf` for an OSC 52 write of `text` to the standard clipboard.
        private func osc52(_ text: String) -> String {
            let encoded = Data(text.utf8).base64EncodedString()
            return "printf '\\033]52;c;\(encoded)\\007'"
        }

        // MARK: - Tests

        /// The product behavior: a program copies, and the text lands on the machine the user is typing
        /// on — addressed to that client and to no other, so the observers that also receive the
        /// broadcast can drop it.
        @Test func aCopyIsForwardedToTheAttachedOwner() async throws {
            let paths = try makeTemporaryPaths()
            defer { try? FileManager.default.removeItem(atPath: paths.rootDirectory) }
            let goFile = paths.rootDirectory + "/go"

            let configuration = makeConfiguration(named: "clipboard-owner", goFile: goFile, script: osc52("copied from the terminal"))
            let core = try await startCore(configuration, paths: paths).value
            defer { TerminalEngineActor.runSynchronously { core.terminate() } }

            let ownerID = attachOwner(core)
            let subscriber = StateStreamSubscriber()
            try subscriber.start(socketPath: paths.subscriptionSocketPath)
            defer { subscriber.stop() }
            releaseChild(goFile)

            try await waitFor { !subscriber.clipboardWrites().isEmpty }
            try await waitForSettledTranscript(paths.outputPath)
            #expect(subscriber.clipboardWrites().count == 1)
            #expect(subscriber.clipboardWrites().first?.targetClientID == ownerID)
            #expect(subscriber.clipboardWrites().first?.text == "copied from the terminal")
        }

        /// Nobody is attached, so there is no machine to copy to. The write is dropped rather than held:
        /// a queued copy would paste into a session the user had already walked away from.
        @Test func aCopyWithNoOwnerIsDropped() async throws {
            let paths = try makeTemporaryPaths()
            defer { try? FileManager.default.removeItem(atPath: paths.rootDirectory) }
            let goFile = paths.rootDirectory + "/go"

            let configuration = makeConfiguration(named: "clipboard-no-owner", goFile: goFile, script: osc52("nobody is listening"))
            let core = try await startCore(configuration, paths: paths).value
            defer { TerminalEngineActor.runSynchronously { core.terminate() } }

            let subscriber = StateStreamSubscriber()
            try subscriber.start(socketPath: paths.subscriptionSocketPath)
            defer { subscriber.stop() }
            releaseChild(goFile)

            // Settle on output the core has definitely consumed, so "no clipboard write" cannot pass
            // simply because the escape sequence had not arrived yet.
            try await waitForSettledTranscript(paths.outputPath)
            try await waitFor { subscriber.reasons().contains(TerminalRemoteSessionStateReason.output.rawValue) }
            #expect(subscriber.clipboardWrites().isEmpty)
        }

        /// A program that empties the terminal's clipboard is asking for the user's clipboard to be
        /// emptied, so the clear travels as a write with empty text rather than being dropped — dropping
        /// it would leave behind exactly the content the program meant to remove.
        @Test func aClearForwardsAnEmptyWrite() async throws {
            let paths = try makeTemporaryPaths()
            defer { try? FileManager.default.removeItem(atPath: paths.rootDirectory) }
            let goFile = paths.rootDirectory + "/go"

            let configuration = makeConfiguration(named: "clipboard-clear", goFile: goFile, script: osc52(""))
            let core = try await startCore(configuration, paths: paths).value
            defer { TerminalEngineActor.runSynchronously { core.terminate() } }

            let ownerID = attachOwner(core)
            let subscriber = StateStreamSubscriber()
            try subscriber.start(socketPath: paths.subscriptionSocketPath)
            defer { subscriber.stop() }
            releaseChild(goFile)

            try await waitFor { !subscriber.clipboardWrites().isEmpty }
            #expect(subscriber.clipboardWrites().first?.targetClientID == ownerID)
            #expect(subscriber.clipboardWrites().first?.text == "")
        }

        /// A payload past the 1 MiB cap never reaches the owner's clipboard: it is refused before it can
        /// be forwarded, so nothing is broadcast and whatever the user had copied stays put. The session
        /// keeps streaming the output turn's frame either way.
        @Test func anOverCapCopyIsDropped() async throws {
            let paths = try makeTemporaryPaths()
            defer { try? FileManager.default.removeItem(atPath: paths.rootDirectory) }
            let goFile = paths.rootDirectory + "/go"

            // Base64 of 1 MiB + 1 bytes, produced in the shell so the escape sequence is written in one go.
            let script = "printf '\\033]52;c;'; head -c 1048577 /dev/zero | tr '\\0' 'a' | base64 | tr -d '\\n'; printf '\\007'"
            let configuration = makeConfiguration(named: "clipboard-over-cap", goFile: goFile, script: script)
            let core = try await startCore(configuration, paths: paths).value
            defer { TerminalEngineActor.runSynchronously { core.terminate() } }

            attachOwner(core)
            let subscriber = StateStreamSubscriber()
            try subscriber.start(socketPath: paths.subscriptionSocketPath)
            defer { subscriber.stop() }
            releaseChild(goFile)

            try await waitForSettledTranscript(paths.outputPath)
            try await waitFor { subscriber.reasons().contains(TerminalRemoteSessionStateReason.output.rawValue) }
            #expect(subscriber.clipboardWrites().isEmpty)
        }

        // MARK: - Handoff

        /// A daemon update rebuilds the session by replaying its transcript, which re-runs every OSC 52
        /// the scrollback ever carried. What the user must get out of that is a session that still
        /// copies for them afterwards, without the pre-update copy being pushed at them a second time:
        /// the replayed copy would overwrite whatever they have on their clipboard now.
        ///
        /// The replay's own silence is structural rather than asserted here — the state-stream server is
        /// only started at the END of the resume, after the rebuild and the handoff-window drain, so no
        /// subscriber can exist while those run (the rebuild replays with events disabled, and the
        /// suffix drain discards the clipboard writes it collects). What this test does pin is that a
        /// subscriber present from the moment the session is serving again sees exactly the live copy
        /// and nothing carried over from before the update.
        @Test func aResumedSessionForwardsLiveCopiesAndNotReplayedOnes() async throws {
            let paths = try makeTemporaryPaths()
            defer { try? FileManager.default.removeItem(atPath: paths.rootDirectory) }
            let goFile = paths.rootDirectory + "/go"

            let configuration = makeConfiguration(named: "clipboard-handoff", goFile: goFile, script: osc52("copied before the update"))
            let core = try await startCore(configuration, paths: paths).value
            attachOwner(core)
            releaseChild(goFile)
            try await waitForSettledTranscript(paths.outputPath)

            guard let record = try await core.quiesceForHandoff() else {
                Issue.record("quiesce produced no handoff record for a live session")
                return
            }
            TerminalEngineActor.runSynchronously { core.terminate() }
            // A real update never runs this: the pre-exec image execs, leaving its clients attached.
            // The test has to terminate the old core to release its PTY and vt session, and terminate
            // enqueues a detach of every client of the session — so the owner is re-established below,
            // once that queued write has landed, or the resumed session has nobody to forward to.
            try await waitFor { ((try? TerminalSessionPersistence.activeAttachments(paths: paths)) ?? []).isEmpty }

            let pty = try makeAdoptablePTY()
            let resumedCore = await makeResumedCore(configuration, paths: paths).value
            defer {
                // Close the slave FIRST so the adopted master's blocked read hits EOF, then terminate:
                // closing a PTY master out from under a still-blocked read hangs.
                tearDown(pty)
                TerminalEngineActor.runSynchronously { resumedCore.terminate() }
            }
            try await resumedCore.resumeFromHandoff(handoffRecord(from: record, adopting: pty))

            let ownerID = attachOwner(resumedCore)
            let subscriber = StateStreamSubscriber()
            try subscriber.start(socketPath: paths.subscriptionSocketPath)
            defer { subscriber.stop() }

            inject("\u{1b}]52;c;\(Data("copied after the update".utf8).base64EncodedString())\u{07}RESUMED\n", into: pty)
            try await waitFor { !subscriber.clipboardWrites().isEmpty }
            try await waitForSettledTranscript(paths.outputPath, marker: "RESUMED")
            #expect(subscriber.clipboardWrites().count == 1)
            #expect(subscriber.clipboardWrites().first?.targetClientID == ownerID)
            #expect(subscriber.clipboardWrites().first?.text == "copied after the update")
        }

        // MARK: - Handoff fixtures

        /// A test-owned PTY plus a live child pid, standing in for the master fd and child that survive
        /// `execv` for the resuming core to adopt.
        private struct AdoptablePTY {
            let master: Int32
            let slave: Int32
            let childPID: Int32
        }

        private func makeAdoptablePTY() throws -> AdoptablePTY {
            var master: Int32 = 0
            var slave: Int32 = 0
            #expect(openpty(&master, &slave, nil, nil, nil) == 0, "openpty failed")

            var childPID: pid_t = 0
            let path = "/bin/sh"
            let arguments = [path, "-c", "sleep 120"]
            var argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) } + [nil]
            defer { for argument in argv where argument != nil { free(argument) } }
            #expect(posix_spawn(&childPID, path, nil, nil, &argv, environ) == 0, "posix_spawn of the liveness child failed")

            return AdoptablePTY(master: master, slave: slave, childPID: childPID)
        }

        private func tearDown(_ pty: AdoptablePTY) {
            close(pty.slave)
            kill(pty.childPID, SIGKILL)
            var status: Int32 = 0
            waitpid(pty.childPID, &status, WNOHANG)
        }

        private func handoffRecord(from record: DaemonHandoffSessionRecord, adopting pty: AdoptablePTY) -> DaemonHandoffSessionRecord {
            DaemonHandoffSessionRecord(
                sessionID: record.sessionID, masterFD: pty.master, childPID: pty.childPID, columns: record.columns, rows: record.rows,
                ownerEpoch: record.ownerEpoch, screenStateRevision: record.screenStateRevision, appearance: record.appearance,
                transcriptOffsetAtQuiesce: record.transcriptOffsetAtQuiesce)
        }

        private func makeResumedCore(_ configuration: TerminalSessionLaunchConfiguration, paths: TerminalSessionPaths) async -> Box<
            GhosttyEmbeddedSessionCore
        > {
            await TerminalEngineActor.run { () -> Box<GhosttyEmbeddedSessionCore> in
                Box(GhosttyEmbeddedSessionCore(launchConfiguration: configuration, paths: paths))
            }
        }

        /// Injects live output on the resumed session's adopted PTY (written to the slave, read by the
        /// core from the master).
        private func inject(_ text: String, into pty: AdoptablePTY) {
            let bytes = Array(text.utf8)
            #expect(bytes.withUnsafeBufferPointer { write(pty.slave, $0.baseAddress, $0.count) } == bytes.count)
        }
    }
#endif
