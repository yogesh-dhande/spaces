import AppKit
import Carbon
import Foundation
import GhosttyKit
import SQLite3
import XCTest
import spacesterminalcore

@testable import spacesterminalghostty

final class GhosttyEmbeddedSessionHostTests: XCTestCase {
    private var originalDatabasePath: String?
    private var originalRuntimeDirectory: String?
    private var databaseRoot: URL?

    override func setUpWithError() throws {
        try super.setUpWithError()
        originalDatabasePath = ProcessInfo.processInfo.environment["SPACES_DB_PATH"]
        originalRuntimeDirectory = ProcessInfo.processInfo.environment["SPACES_RUNTIME_DIR"]
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        databaseRoot = root
        setenv("SPACES_DB_PATH", root.appendingPathComponent("spaces.db").path, 1)
        setenv("SPACES_RUNTIME_DIR", root.appendingPathComponent("runtime", isDirectory: true).path, 1)
    }

    override func tearDownWithError() throws {
        if let originalDatabasePath { setenv("SPACES_DB_PATH", originalDatabasePath, 1) } else { unsetenv("SPACES_DB_PATH") }
        if let originalRuntimeDirectory { setenv("SPACES_RUNTIME_DIR", originalRuntimeDirectory, 1) } else { unsetenv("SPACES_RUNTIME_DIR") }
        if let databaseRoot { try? FileManager.default.removeItem(at: databaseRoot) }
        databaseRoot = nil
        originalDatabasePath = nil
        originalRuntimeDirectory = nil
        try super.tearDownWithError()
    }

    /// Carries a non-Sendable engine-actor reference (a session host/core/driver) across an `await`
    /// gap in a nonisolated test body. The object is only ever touched while isolated to
    /// `TerminalEngineActor` (inside `run`/`runSynchronously`), so moving the bare reference here —
    /// exactly as `TerminalEngineMainBlockedRegressionTests.CoreBox` does — is sound even though the
    /// wrapped type itself isn't `Sendable`.
    private final class Box<Value>: @unchecked Sendable {
        let value: Value
        init(_ value: Value) { self.value = value }
    }

    /// Lock-guarded mutable cell for state a test mutates from nonisolated code while an engine-actor
    /// callback (e.g. a snapshot-capture stub installed for the duration of a test) reads it back on
    /// the engine actor. Mirrors `TranscriptBuffer` below, generalized to an arbitrary payload.
    private final class MutableBox<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: Value
        init(_ value: Value) { storage = value }
        var value: Value {
            get {
                lock.lock()
                defer { lock.unlock() }
                return storage
            }
            set {
                lock.lock()
                defer { lock.unlock() }
                storage = newValue
            }
        }
    }

    private final class TranscriptBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()

        func append(_ chunk: Data) {
            lock.lock()
            defer { lock.unlock() }
            data.append(chunk)
        }

        func string() -> String {
            lock.lock()
            defer { lock.unlock() }
            return String(data: data, encoding: .utf8) ?? ""
        }
    }

    /// Thread-safe collector for `GhosttyRemoteSessionStateStreamClient`'s `@MainActor @Sendable`
    /// delivery closure, invoked while these tests run on `@TerminalEngineActor`. `snapshot` hands
    /// back a plain array copy so the rest of a test can keep reading it with ordinary `Array` APIs.
    private final class RemoteSessionStatePayloadCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var payloads: [GhosttyRemoteSessionStatePayload] = []

        func append(_ payload: GhosttyRemoteSessionStatePayload) {
            lock.lock()
            defer { lock.unlock() }
            payloads.append(payload)
        }

        func removeAll() {
            lock.lock()
            defer { lock.unlock() }
            payloads.removeAll()
        }

        var snapshot: [GhosttyRemoteSessionStatePayload] {
            lock.lock()
            defer { lock.unlock() }
            return payloads
        }
    }

    /// Nonisolated poller: the polling loop itself must stay off the engine actor so its
    /// `Task.sleep` suspensions don't hold the engine's queue while the condition it is waiting
    /// on needs to run there. Each poll hops onto the engine synchronously just to evaluate the
    /// (engine-isolated) condition.
    private func waitUntil(
        timeout: TimeInterval = 10, pollInterval: TimeInterval = 0.05, file: StaticString = #filePath, line: UInt = #line,
        _ condition: @escaping @TerminalEngineActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if TerminalEngineActor.runSynchronously({ condition() }) { return }
            try? await Task.sleep(for: .seconds(pollInterval))
        }

        XCTFail("Timed out waiting for condition.", file: file, line: line)
        throw NSError(domain: "GhosttyEmbeddedSessionHostTests", code: 1)
    }

    private func waitForForegroundPID(
        in sessionDriver: GhosttyEmbeddedTerminalSessionDriver, timeout: TimeInterval = 10, file: StaticString = #filePath, line: UInt = #line
    ) async throws -> Int32 {
        // The condition closure below is re-sent to the engine actor on every poll, so the result
        // must live behind a Sendable box rather than a captured `var` (a bare `var` capture used
        // by a closure invoked more than once trips Swift 6's "sending risks data races" check).
        let foregroundPIDBox = MutableBox<Int32?>(nil)
        try await waitUntil(timeout: timeout, file: file, line: line) {
            foregroundPIDBox.value = sessionDriver.foregroundPID()
            return foregroundPIDBox.value != nil
        }
        return try XCTUnwrap(foregroundPIDBox.value, file: file, line: line)
    }

    private static func processIsAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    func testHostManagedPTYLaunchesInteractiveShellAsLoginShell() {
        let command = HostManagedPTYTerminalSessionDriver.execCommand(
            for: TerminalSessionLaunchConfiguration(
                sessionID: "exec-shell", backend: .ghosttyEmbedded, title: "shell", workingDirectory: "/tmp", shell: "/bin/zsh", command: nil,
                createdAt: "2026-05-29T00:00:00Z", workspaceID: "workspace-1", kind: .shell))

        XCTAssertEqual(command.executable, "/bin/zsh")
        XCTAssertEqual(command.arguments, ["-zsh"])
    }

    func testHostManagedPTYRunsCommandsThroughLoginShell() {
        let command = HostManagedPTYTerminalSessionDriver.execCommand(
            for: TerminalSessionLaunchConfiguration(
                sessionID: "exec-command", backend: .ghosttyEmbedded, title: "shell", workingDirectory: "/tmp", shell: "/bin/zsh",
                command: "echo 'hello'", createdAt: "2026-05-29T00:00:00Z", workspaceID: "workspace-1", kind: .shell))

        XCTAssertEqual(command.executable, "/bin/zsh")
        XCTAssertEqual(command.arguments, ["zsh", "-l", "-c", "echo 'hello'"])
    }

    func testHostManagedPTYExportsGhosttyTerminfoEnvironment() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let resourcesRoot = root.appendingPathComponent("Resources", isDirectory: true)
        let ghosttyResources = resourcesRoot.appendingPathComponent("ghostty", isDirectory: true)
        let terminfoResources = resourcesRoot.appendingPathComponent("terminfo", isDirectory: true)
        try FileManager.default.createDirectory(at: ghosttyResources, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: terminfoResources, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let resourcesOverrideKey = GhosttyEmbeddedLocator.resourcesEnvironmentVariable
        let originalResourcesOverride = ProcessInfo.processInfo.environment[resourcesOverrideKey]
        setenv(resourcesOverrideKey, ghosttyResources.path, 1)
        defer {
            if let originalResourcesOverride { setenv(resourcesOverrideKey, originalResourcesOverride, 1) } else { unsetenv(resourcesOverrideKey) }
        }

        let transcript = TranscriptBuffer()
        let driver = HostManagedPTYTerminalSessionDriver(
            launchConfiguration: TerminalSessionLaunchConfiguration(
                sessionID: "terminfo-environment-\(UUID().uuidString)", backend: .ghosttyEmbedded, title: "terminfo-environment",
                workingDirectory: root.path, shell: "/bin/zsh",
                command: "printf 'TERM=%s\\nTERMINFO=%s\\n__SPACES_ENV_END__\\n' \"$TERM\" \"$TERMINFO\"", createdAt: "2026-07-13T00:00:00Z",
                workspaceID: "workspace-1", kind: .shell))
        driver.setOutputHandler { transcript.append($0) }
        defer { driver.terminate() }

        try driver.startIfNeeded()
        try await waitUntil { transcript.string().contains("__SPACES_ENV_END__") }

        XCTAssertTrue(transcript.string().contains("TERM=xterm-ghostty"))
        XCTAssertTrue(transcript.string().contains("TERMINFO=\(terminfoResources.path)"))
    }

    func testHostManagedPTYForegroundPIDTracksInteractiveForegroundJob() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let pidPath = root.appendingPathComponent("foreground.pid")
        let scriptPath = root.appendingPathComponent("foreground-job.sh")
        try """
        #!/bin/sh
        printf '%s\n' "$$" > "\(pidPath.path)"
        sleep 5
        """.write(to: scriptPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath.path)

        let driver = HostManagedPTYTerminalSessionDriver(
            launchConfiguration: TerminalSessionLaunchConfiguration(
                sessionID: "foreground-job-\(UUID().uuidString)", backend: .ghosttyEmbedded, title: "foreground-job", workingDirectory: root.path,
                shell: "/bin/zsh", command: nil, createdAt: "2026-06-06T00:00:00Z", workspaceID: "workspace-1", kind: .shell))
        defer { driver.terminate() }

        try driver.startIfNeeded()
        let shellPID = try XCTUnwrap(driver.childPID())
        driver.sendRawBytes(Data("\(scriptPath.path)\n".utf8))

        try await waitUntil { FileManager.default.fileExists(atPath: pidPath.path) }
        let foregroundPIDText = try String(contentsOf: pidPath, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let foregroundPID = try XCTUnwrap(Int32(foregroundPIDText))
        try await waitUntil { driver.foregroundPID() == foregroundPID }

        XCTAssertNotEqual(foregroundPID, shellPID)
        XCTAssertEqual(driver.foregroundPID(), foregroundPID)
    }

    func testHostManagedPTYResetsIgnoredInterruptSignalBeforeExec() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let markerPath = root.appendingPathComponent("interrupt-marker")
        let scriptPath = root.appendingPathComponent("interrupt-target.sh")
        try """
        #!/bin/sh
        printf 'ready\\n' > "\(markerPath.path)"
        sleep 20
        printf 'survived\\n' >> "\(markerPath.path)"
        """.write(to: scriptPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath.path)

        // Simulate a daemon launched from a background/noninteractive shell where
        // SIGINT can be inherited as ignored by child terminal sessions.
        let previousInterruptHandler = signal(SIGINT, SIG_IGN)
        defer { _ = signal(SIGINT, previousInterruptHandler) }

        let driver = HostManagedPTYTerminalSessionDriver(
            launchConfiguration: TerminalSessionLaunchConfiguration(
                sessionID: "interrupt-signal-\(UUID().uuidString)", backend: .ghosttyEmbedded, title: "interrupt", workingDirectory: root.path,
                shell: "/bin/zsh", command: scriptPath.path, createdAt: "2026-06-06T00:00:00Z", workspaceID: "workspace-1", kind: .shell))
        defer { driver.terminate() }

        try driver.startIfNeeded()
        try await waitUntil { FileManager.default.fileExists(atPath: markerPath.path) }
        driver.sendRawBytes(Data([0x03]))
        try await waitUntil(timeout: 5) { driver.childPID() == nil }

        let markerText = try String(contentsOf: markerPath, encoding: .utf8)
        XCTAssertTrue(markerText.contains("ready"))
        // If the child inherited ignored SIGINT, sleep completes and writes this.
        XCTAssertFalse(markerText.contains("survived"))
    }

    func testHostManagedPTYTerminateEscalatesWhenHUPIsIgnored() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let markerPath = root.appendingPathComponent("termination-marker")
        let scriptPath = root.appendingPathComponent("ignore-hup-target.sh")
        try """
        #!/bin/sh
        trap 'printf "hup\\n" >> "\(markerPath.path)"' HUP
        trap 'printf "term\\n" >> "\(markerPath.path)"; exit 0' TERM
        printf 'ready\\n' > "\(markerPath.path)"
        while :; do sleep 1; done
        """.write(to: scriptPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath.path)

        let driver = HostManagedPTYTerminalSessionDriver(
            launchConfiguration: TerminalSessionLaunchConfiguration(
                sessionID: "terminate-escalates-\(UUID().uuidString)", backend: .ghosttyEmbedded, title: "terminate-escalates",
                workingDirectory: root.path, shell: "/bin/zsh", command: "exec \(scriptPath.path)", createdAt: "2026-06-19T00:00:00Z",
                workspaceID: "workspace-1", kind: .shell), terminationEscalationIntervals: .init(hupGrace: 0.05, termGrace: 2.0, killGrace: 2.0))

        try driver.startIfNeeded()
        try await waitUntil { FileManager.default.fileExists(atPath: markerPath.path) }
        let childPID = try XCTUnwrap(driver.childPID())

        driver.terminate()

        try await waitUntil(timeout: 5) {
            guard let markerText = try? String(contentsOf: markerPath, encoding: .utf8) else { return false }
            return markerText.contains("term")
        }
        try await waitUntil(timeout: 5) { !Self.processIsAlive(childPID) }

        let markerText = try String(contentsOf: markerPath, encoding: .utf8)
        XCTAssertTrue(markerText.contains("hup"))
        XCTAssertTrue(markerText.contains("term"))
    }

    func testHostManagedPTYForegroundPIDFallsBackToLiveChildPID() {
        let currentPID = getpid()

        XCTAssertEqual(HostManagedPTYTerminalSessionDriver.resolvedForegroundPID(foregroundProcessGroup: nil, childPID: currentPID), currentPID)
        XCTAssertEqual(HostManagedPTYTerminalSessionDriver.resolvedForegroundPID(foregroundProcessGroup: Int32.max, childPID: currentPID), currentPID)
        XCTAssertEqual(HostManagedPTYTerminalSessionDriver.resolvedForegroundPID(foregroundProcessGroup: currentPID, childPID: nil), currentPID)
    }

    func testHostManagedPTYDoesNotGroupSignalCurrentProcessGroup() {
        XCTAssertFalse(HostManagedPTYTerminalSessionDriver.shouldSignalProcessGroup(childPID: 42, processGroupID: 42, currentProcessGroupID: 42))
        XCTAssertFalse(HostManagedPTYTerminalSessionDriver.shouldSignalProcessGroup(childPID: 42, processGroupID: 41, currentProcessGroupID: 1))
        XCTAssertTrue(HostManagedPTYTerminalSessionDriver.shouldSignalProcessGroup(childPID: 42, processGroupID: 42, currentProcessGroupID: 1))
    }

    func testHostManagedPTYRemovesDaemonEnvironmentBeforeExec() {
        XCTAssertTrue(HostManagedPTYTerminalSessionDriver.shouldRemoveInheritedEnvironmentKey("INVOCATION_ID"))
        XCTAssertTrue(HostManagedPTYTerminalSessionDriver.shouldRemoveInheritedEnvironmentKey("JOURNAL_STREAM"))
        XCTAssertTrue(HostManagedPTYTerminalSessionDriver.shouldRemoveInheritedEnvironmentKey("NOTIFY_SOCKET"))
        XCTAssertTrue(HostManagedPTYTerminalSessionDriver.shouldRemoveInheritedEnvironmentKey("SPACES_DEVICE_API_PORT"))
        XCTAssertFalse(HostManagedPTYTerminalSessionDriver.shouldRemoveInheritedEnvironmentKey("SPACES_DB_PATH"))
        XCTAssertFalse(HostManagedPTYTerminalSessionDriver.shouldRemoveInheritedEnvironmentKey("PATH"))
    }

    func testHostManagedPTYStripsGhosttyCommandPrefixesBeforeShellExecution() {
        let direct = HostManagedPTYTerminalSessionDriver.execCommand(
            for: TerminalSessionLaunchConfiguration(
                sessionID: "exec-direct", backend: .ghosttyEmbedded, title: "shell", workingDirectory: "/tmp", shell: "/bin/zsh",
                command: "direct:/bin/cat", createdAt: "2026-05-29T00:00:00Z", workspaceID: "workspace-1", kind: .shell))
        let shell = HostManagedPTYTerminalSessionDriver.execCommand(
            for: TerminalSessionLaunchConfiguration(
                sessionID: "exec-shell-prefix", backend: .ghosttyEmbedded, title: "shell", workingDirectory: "/tmp", shell: "/bin/zsh",
                command: "shell:printf hello", createdAt: "2026-05-29T00:00:00Z", workspaceID: "workspace-1", kind: .shell))

        XCTAssertEqual(direct.arguments, ["zsh", "-l", "-c", "/bin/cat"])
        XCTAssertEqual(shell.arguments, ["zsh", "-l", "-c", "printf hello"])
    }

    func testHostManagedPTYReadLoopDescriptorOwnershipRequiresMatchingGeneration() {
        XCTAssertTrue(HostManagedPTYTerminalSessionDriver.readLoopOwnsDescriptor(currentFD: 12, currentGeneration: 4, readFD: 12, readGeneration: 4))
        XCTAssertFalse(HostManagedPTYTerminalSessionDriver.readLoopOwnsDescriptor(currentFD: 12, currentGeneration: 5, readFD: 12, readGeneration: 4))
        XCTAssertFalse(HostManagedPTYTerminalSessionDriver.readLoopOwnsDescriptor(currentFD: 13, currentGeneration: 4, readFD: 12, readGeneration: 4))
    }

    func testScreenStateChangeRequestsLiveSurfaceRefresh() async throws {
        try await TerminalEngineActor.run {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }

            let paths = TerminalSessionPaths(rootDirectory: root.path)
            try paths.ensureDirectories()
            var refreshRequestCount = 0
            let core = GhosttyEmbeddedSessionCore(
                launchConfiguration: TerminalSessionLaunchConfiguration(
                    sessionID: "screen-refresh-\(UUID().uuidString)", backend: .ghosttyEmbedded, title: "shell", workingDirectory: "/tmp",
                    shell: "/bin/zsh", command: nil, createdAt: "2026-05-29T00:00:00Z", workspaceID: "workspace-1", kind: .shell), paths: paths,
                requestSurfaceRefreshAction: { refreshRequestCount += 1 })

            core.applySessionStateChange(.init(flags: [.screen], revision: 1, title: nil, workingDirectory: nil))

            XCTAssertEqual(refreshRequestCount, 1)

        }
    }

    func testScreenStateChangeBuildsUnexportedLocalOwnerFrame() async throws {
        try await TerminalEngineActor.run {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }

            let paths = TerminalSessionPaths(rootDirectory: root.path)
            try paths.ensureDirectories()
            let launchConfiguration = TerminalSessionLaunchConfiguration(
                sessionID: "session-screen-state-change-\(UUID().uuidString)", backend: .ghosttyEmbedded, title: "shell", workingDirectory: "/tmp",
                shell: "/bin/zsh", command: nil, createdAt: "2026-06-02T00:00:00Z", workspaceID: "workspace-1", kind: .shell)
            let host = GhosttyEmbeddedSessionHost(launchConfiguration: launchConfiguration, paths: paths)
            defer { host.terminate() }
            GhosttyTerminalSnapshotCapture.sessionCaptureHandlerForTesting = { _ in Self.snapshot(text: "state changed") }
            defer { GhosttyTerminalSnapshotCapture.sessionCaptureHandlerForTesting = nil }

            let localOwner = TerminalClient(
                id: "local-window", kind: .localWindow, identity: TerminalClientIdentity(label: "Spaces window"), connectedAt: "2026-06-02T00:00:00Z")
            try host.startIfNeeded()

            try host.attach(client: localOwner, mode: .owner, into: nil)
            let initialPayload = try XCTUnwrap(host.debugCurrentRemoteSessionState(reason: TerminalRemoteSessionStateReason.initial))
            let baseline = try Self.renderBaseline(from: initialPayload, baseline: nil)

            let screenRevision: UInt64 = UInt64.max / 2
            host.applySessionStateChange(.init(flags: [.screen], revision: screenRevision, title: nil, workingDirectory: nil))

            let payload = try XCTUnwrap(host.debugCurrentRemoteSessionState(reason: TerminalRemoteSessionStateReason.stateChange))
            XCTAssertEqual(payload.reason, TerminalRemoteSessionStateReason.stateChange)
            XCTAssertEqual(payload.screenStateRevision, screenRevision)
            XCTAssertNotNil(payload.renderUpdate)
            let update = try XCTUnwrap(payload.decodedRenderUpdate)
            XCTAssertEqual(update.kind, .full)
            XCTAssertEqual(update.fallbackReason, "self_contained_state_export")
            let applied = try Self.renderBaseline(from: payload, baseline: baseline)
            XCTAssertEqual(GhosttyTerminalSnapshotLayout.plainText(for: applied.snapshot), "state changed")

        }
    }

    func testScreenStateChangeBroadcastsRemoteOwnerFrame() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = TerminalSessionPaths(rootDirectory: root.path)
        try paths.ensureDirectories()
        let launchConfiguration = TerminalSessionLaunchConfiguration(
            sessionID: "session-remote-screen-state-change-\(UUID().uuidString)", backend: .ghosttyEmbedded, title: "shell", workingDirectory: "/tmp",
            shell: "/bin/zsh", command: nil, createdAt: "2026-06-02T00:00:00Z", workspaceID: "workspace-1", kind: .shell)
        let snapshotTextBox = MutableBox("mobile frame 0")
        GhosttyTerminalSnapshotCapture.sessionCaptureHandlerForTesting = { _ in Self.snapshot(text: snapshotTextBox.value) }
        defer { GhosttyTerminalSnapshotCapture.sessionCaptureHandlerForTesting = nil }

        let hostBox = try await TerminalEngineActor.run { () -> Box<GhosttyEmbeddedSessionHost> in
            let host = GhosttyEmbeddedSessionHost(launchConfiguration: launchConfiguration, paths: paths)
            let remoteOwner = TerminalClient(
                id: "remote-ipad", kind: .remoteViewer, identity: TerminalClientIdentity(label: "iPad", deviceName: "iPad"),
                connectedAt: "2026-06-02T00:00:00Z")
            try host.attach(client: remoteOwner, mode: .owner, into: nil)
            return Box(host)
        }
        let host = hostBox.value
        defer { TerminalEngineActor.runSynchronously { host.terminate() } }

        let receivedPayloads = RemoteSessionStatePayloadCollector()
        let client = GhosttyRemoteSessionStateStreamClient(socketPath: paths.subscriptionSocketPath) { payload in receivedPayloads.append(payload) }
        try client.start()
        defer { client.stop() }
        try await waitUntil(timeout: 2) { receivedPayloads.snapshot.contains { $0.reason == TerminalRemoteSessionStateReason.initial && $0.renderUpdate != nil } }
        let initialPayload = try XCTUnwrap(receivedPayloads.snapshot.last { $0.reason == TerminalRemoteSessionStateReason.initial && $0.renderUpdate != nil })
        let initialUpdate = try XCTUnwrap(initialPayload.decodedRenderUpdate)
        XCTAssertEqual(initialUpdate.kind, .full)
        var baseline: GhosttyRenderUpdateBaseline?
        for payload in receivedPayloads.snapshot where payload.renderUpdate != nil { baseline = try Self.renderBaseline(from: payload, baseline: baseline) }
        let resolvedBaseline = try XCTUnwrap(baseline)
        receivedPayloads.removeAll()

        snapshotTextBox.value = "mobile frame 1"
        let screenRevision: UInt64 = UInt64.max / 2
        try await TerminalEngineActor.run {
            host.applySessionStateChange(.init(flags: [.screen], revision: screenRevision, title: nil, workingDirectory: nil))
        }

        try await waitUntil(timeout: 2) {
            receivedPayloads.snapshot.contains {
                $0.reason == TerminalRemoteSessionStateReason.stateChange && $0.screenStateRevision == screenRevision && $0.renderUpdate != nil
            }
        }
        let payloadIndex = try XCTUnwrap(
            receivedPayloads.snapshot.firstIndex { $0.reason == TerminalRemoteSessionStateReason.stateChange && $0.screenStateRevision == screenRevision })
        var stateChangeBaseline = resolvedBaseline
        for payload in receivedPayloads.snapshot[..<payloadIndex] where payload.renderUpdate != nil {
            stateChangeBaseline = try Self.renderBaseline(from: payload, baseline: stateChangeBaseline)
        }
        let payload = receivedPayloads.snapshot[payloadIndex]
        let update = try XCTUnwrap(payload.decodedRenderUpdate)
        XCTAssertEqual(update.kind, .delta)
        XCTAssertNil(update.fallbackReason)
        XCTAssertGreaterThan(update.changedCellCount, 0)
        XCTAssertLessThan(update.changedCellCount, stateChangeBaseline.snapshot.columns * stateChangeBaseline.snapshot.rows)
        let applied = try Self.renderBaseline(from: payload, baseline: stateChangeBaseline)
        XCTAssertEqual(GhosttyTerminalSnapshotLayout.plainText(for: applied.snapshot), "mobile frame 1")
    }

    func testSubscriberWithoutInitialRenderBaselineReceivesFullNextStateChange() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = TerminalSessionPaths(rootDirectory: root.path)
        try paths.ensureDirectories()
        let launchConfiguration = TerminalSessionLaunchConfiguration(
            sessionID: "session-blank-initial-subscriber-\(UUID().uuidString)", backend: .ghosttyEmbedded, title: "shell", workingDirectory: "/tmp",
            shell: "/bin/zsh", command: nil, createdAt: "2026-06-04T00:00:00Z", workspaceID: "workspace-1", kind: .shell)
        try TerminalSessionPersistence.writeLaunchConfiguration(launchConfiguration, paths: paths)

        let capturedSnapshotBox = MutableBox<GhosttyTerminalSnapshot?>(Self.snapshot(text: "previous baseline"))
        GhosttyTerminalSnapshotCapture.sessionCaptureHandlerForTesting = { _ in capturedSnapshotBox.value }
        defer { GhosttyTerminalSnapshotCapture.sessionCaptureHandlerForTesting = nil }

        let remoteOwner = TerminalClient(
            id: "remote-ipad", kind: .remoteViewer, identity: TerminalClientIdentity(label: "iPad", deviceName: "iPad"),
            connectedAt: "2026-06-04T00:00:00Z")
        try TerminalSessionPersistence.attachClient(
            sessionID: launchConfiguration.sessionID, client: remoteOwner, mode: .owner, paths: paths, attachedAt: "2026-06-04T00:00:00Z")

        let hostBox = try await TerminalEngineActor.run { () -> Box<GhosttyEmbeddedSessionHost> in
            let host = GhosttyEmbeddedSessionHost(launchConfiguration: launchConfiguration, paths: paths)
            let previousPayload = try XCTUnwrap(host.debugCurrentRemoteSessionState(reason: TerminalRemoteSessionStateReason.initial))
            XCTAssertNotNil(previousPayload.renderUpdate)
            return Box(host)
        }
        let host = hostBox.value
        defer { TerminalEngineActor.runSynchronously { host.terminate() } }

        capturedSnapshotBox.value = nil
        let receivedPayloads = RemoteSessionStatePayloadCollector()
        try await TerminalEngineActor.run { try host.debugStartStateStreamServerForTesting() }
        defer { TerminalEngineActor.runSynchronously { host.debugStopStateStreamServerForTesting() } }
        let client = GhosttyRemoteSessionStateStreamClient(socketPath: paths.subscriptionSocketPath) { payload in receivedPayloads.append(payload) }
        try client.start()
        defer { client.stop() }

        try await waitUntil(timeout: 2) { receivedPayloads.snapshot.contains { $0.reason == TerminalRemoteSessionStateReason.initial } }
        let initialPayload = try XCTUnwrap(receivedPayloads.snapshot.last { $0.reason == TerminalRemoteSessionStateReason.initial })
        XCTAssertNil(initialPayload.renderUpdate)
        receivedPayloads.removeAll()

        capturedSnapshotBox.value = Self.snapshot(text: "visible after blank")
        let screenRevision: UInt64 = UInt64.max / 2
        try await TerminalEngineActor.run {
            host.applySessionStateChange(.init(flags: [.screen], revision: screenRevision, title: nil, workingDirectory: nil))
        }

        try await waitUntil(timeout: 2) {
            receivedPayloads.snapshot.contains {
                $0.reason == TerminalRemoteSessionStateReason.stateChange && $0.screenStateRevision == screenRevision && $0.renderUpdate != nil
            }
        }
        let payload = try XCTUnwrap(
            receivedPayloads.snapshot.first { $0.reason == TerminalRemoteSessionStateReason.stateChange && $0.screenStateRevision == screenRevision })
        let update = try XCTUnwrap(payload.decodedRenderUpdate)
        XCTAssertEqual(update.kind, .full)
        XCTAssertEqual(update.fallbackReason, "subscriber_baseline_reset")

        let applied = try Self.renderBaseline(from: payload, baseline: nil)
        XCTAssertEqual(GhosttyTerminalSnapshotLayout.plainText(for: applied.snapshot), "visible after blank")
    }

    func testResizeRenderUpdatesStaySelfContainedWhenCoalesced() async throws {
        try await TerminalEngineActor.run {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }

            let paths = TerminalSessionPaths(rootDirectory: root.path)
            try paths.ensureDirectories()
            let launchConfiguration = TerminalSessionLaunchConfiguration(
                sessionID: "session-resize-self-contained-\(UUID().uuidString)", backend: .ghosttyEmbedded, title: "shell", workingDirectory: "/tmp",
                shell: "/bin/zsh", command: nil, createdAt: "2026-06-03T00:00:00Z", workspaceID: "workspace-1", kind: .shell)
            try TerminalSessionPersistence.writeLaunchConfiguration(launchConfiguration, paths: paths)
            let host = GhosttyEmbeddedSessionHost(launchConfiguration: launchConfiguration, paths: paths)
            try TerminalSessionPersistence.writeLaunchConfiguration(launchConfiguration, paths: paths)
            let owner = TerminalClient(
                id: "local-window", kind: .localWindow, identity: TerminalClientIdentity(label: "Spaces window"), connectedAt: "2026-06-03T00:00:00Z")
            try TerminalSessionPersistence.attachClient(
                sessionID: launchConfiguration.sessionID, client: owner, mode: .owner, paths: paths, attachedAt: "2026-06-03T00:00:00Z")

            var snapshotText = "resize frame one"
            GhosttyTerminalSnapshotCapture.sessionCaptureHandlerForTesting = { _ in Self.snapshot(text: snapshotText) }
            defer { GhosttyTerminalSnapshotCapture.sessionCaptureHandlerForTesting = nil }

            host.applySessionStateChange(.init(flags: [.screen], revision: 1, title: nil, workingDirectory: nil))
            let initialPayload = try XCTUnwrap(host.debugCurrentRemoteSessionState(reason: TerminalRemoteSessionStateReason.initial))
            let initialBaseline = try Self.renderBaseline(from: initialPayload, baseline: nil)

            snapshotText = "resize frame two"
            host.applySessionStateChange(.init(flags: [.screen], revision: 2, title: nil, workingDirectory: nil))
            let firstResizePayload = try XCTUnwrap(host.debugCurrentRemoteSessionState(reason: TerminalRemoteSessionStateReason.resize))
            let firstResizeUpdate = try XCTUnwrap(firstResizePayload.decodedRenderUpdate)
            XCTAssertEqual(firstResizeUpdate.kind, .full)
            XCTAssertEqual(firstResizeUpdate.fallbackReason, "resize_self_contained")

            snapshotText = "resize frame six"
            host.applySessionStateChange(.init(flags: [.screen], revision: 3, title: nil, workingDirectory: nil))
            let secondResizePayload = try XCTUnwrap(host.debugCurrentRemoteSessionState(reason: TerminalRemoteSessionStateReason.resize))
            let secondResizeUpdate = try XCTUnwrap(secondResizePayload.decodedRenderUpdate)
            XCTAssertEqual(secondResizeUpdate.kind, .full)
            XCTAssertEqual(secondResizeUpdate.fallbackReason, "resize_self_contained")

            _ = try GhosttyRenderUpdateApplier.apply(secondResizeUpdate, to: initialBaseline)

        }
    }

    func testInputOutputRenderUpdateStaysExplicitResyncForOneShotExport() async throws {
        try await TerminalEngineActor.run {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }

            let paths = TerminalSessionPaths(rootDirectory: root.path)
            try paths.ensureDirectories()
            let launchConfiguration = TerminalSessionLaunchConfiguration(
                sessionID: "session-input-output-one-shot-\(UUID().uuidString)", backend: .ghosttyEmbedded, title: "shell", workingDirectory: "/tmp",
                shell: "/bin/zsh", command: nil, createdAt: "2026-06-03T00:00:00Z", workspaceID: "workspace-1", kind: .shell)
            try TerminalSessionPersistence.writeLaunchConfiguration(launchConfiguration, paths: paths)
            let host = GhosttyEmbeddedSessionHost(launchConfiguration: launchConfiguration, paths: paths)
            let owner = TerminalClient(
                id: "local-window", kind: .localWindow, identity: TerminalClientIdentity(label: "Spaces window"), connectedAt: "2026-06-03T00:00:00Z")
            try TerminalSessionPersistence.attachClient(
                sessionID: launchConfiguration.sessionID, client: owner, mode: .owner, paths: paths, attachedAt: "2026-06-03T00:00:00Z")

            GhosttyTerminalSnapshotCapture.sessionCaptureHandlerForTesting = { _ in Self.snapshot(text: "input output") }
            defer { GhosttyTerminalSnapshotCapture.sessionCaptureHandlerForTesting = nil }

            host.applySessionStateChange(.init(flags: [.screen], revision: 1, title: nil, workingDirectory: nil))
            let payload = try XCTUnwrap(host.debugCurrentRemoteSessionState(reason: TerminalRemoteSessionStateReason.inputOutput))
            let update = try XCTUnwrap(payload.decodedRenderUpdate)

            XCTAssertEqual(update.kind, .full)
            XCTAssertEqual(update.fallbackReason, "explicit_resync")

        }
    }

    func testInputStateDoesNotExportStaleRenderUpdate() async throws {
        try await TerminalEngineActor.run {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }

            let paths = TerminalSessionPaths(rootDirectory: root.path)
            try paths.ensureDirectories()
            let launchConfiguration = TerminalSessionLaunchConfiguration(
                sessionID: "session-input-no-render-\(UUID().uuidString)", backend: .ghosttyEmbedded, title: "shell", workingDirectory: "/tmp",
                shell: "/bin/zsh", command: nil, createdAt: "2026-06-03T00:00:00Z", workspaceID: "workspace-1", kind: .shell)
            try TerminalSessionPersistence.writeLaunchConfiguration(launchConfiguration, paths: paths)
            let host = GhosttyEmbeddedSessionHost(launchConfiguration: launchConfiguration, paths: paths)
            let owner = TerminalClient(
                id: "remote-owner", kind: .remoteViewer, identity: TerminalClientIdentity(label: "iPhone"), connectedAt: "2026-06-03T00:00:00Z")
            try TerminalSessionPersistence.attachClient(
                sessionID: launchConfiguration.sessionID, client: owner, mode: .owner, paths: paths, attachedAt: "2026-06-03T00:00:00Z")

            GhosttyTerminalSnapshotCapture.sessionCaptureHandlerForTesting = { _ in Self.snapshot(text: "before input") }
            defer { GhosttyTerminalSnapshotCapture.sessionCaptureHandlerForTesting = nil }

            host.applySessionStateChange(.init(flags: [.screen], revision: 1, title: nil, workingDirectory: nil))
            let initialPayload = try XCTUnwrap(host.debugCurrentRemoteSessionState(reason: TerminalRemoteSessionStateReason.initial))
            XCTAssertNotNil(initialPayload.renderUpdate)

            let inputPayload = try XCTUnwrap(host.debugCurrentRemoteSessionState(reason: TerminalRemoteSessionStateReason.input))
            XCTAssertNil(inputPayload.renderUpdate)
            XCTAssertNil(inputPayload.decodedRenderUpdate)

        }
    }

    func testScrollRenderUpdateAdvancesRevisionWithoutSessionStateChange() async throws {
        try await TerminalEngineActor.run {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }

            let paths = TerminalSessionPaths(rootDirectory: root.path)
            try paths.ensureDirectories()
            let launchConfiguration = TerminalSessionLaunchConfiguration(
                sessionID: "session-scroll-render-revision-\(UUID().uuidString)", backend: .ghosttyEmbedded, title: "shell", workingDirectory: "/tmp",
                shell: "/bin/zsh", command: nil, createdAt: "2026-06-03T00:00:00Z", workspaceID: "workspace-1", kind: .shell)
            try TerminalSessionPersistence.writeLaunchConfiguration(launchConfiguration, paths: paths)
            let host = GhosttyEmbeddedSessionHost(launchConfiguration: launchConfiguration, paths: paths)
            try TerminalSessionPersistence.writeLaunchConfiguration(launchConfiguration, paths: paths)
            let owner = TerminalClient(
                id: "local-window", kind: .localWindow, identity: TerminalClientIdentity(label: "Spaces window"), connectedAt: "2026-06-03T00:00:00Z")
            try TerminalSessionPersistence.attachClient(
                sessionID: launchConfiguration.sessionID, client: owner, mode: .owner, paths: paths, attachedAt: "2026-06-03T00:00:00Z")

            var snapshotText = "frame one"
            GhosttyTerminalSnapshotCapture.sessionCaptureHandlerForTesting = { _ in Self.snapshot(text: snapshotText) }
            defer { GhosttyTerminalSnapshotCapture.sessionCaptureHandlerForTesting = nil }

            host.applySessionStateChange(.init(flags: [.screen], revision: 1, title: nil, workingDirectory: nil))
            let initialPayload = try XCTUnwrap(host.debugCurrentRemoteSessionState(reason: TerminalRemoteSessionStateReason.initial))
            let initialBaseline = try Self.renderBaseline(from: initialPayload, baseline: nil)

            snapshotText = "frame two"
            let scrollPayload = try XCTUnwrap(host.debugCurrentRemoteSessionState(reason: TerminalRemoteSessionStateReason.scroll))
            let scrollUpdate = try XCTUnwrap(scrollPayload.decodedRenderUpdate)

            XCTAssertEqual(scrollPayload.screenStateRevision, 1)
            XCTAssertEqual(scrollUpdate.kind, .full)
            XCTAssertEqual(scrollUpdate.fallbackReason, "self_contained_state_export")
            XCTAssertNotEqual(scrollUpdate.targetRevision, scrollUpdate.baseRevision)

            let applied = try GhosttyRenderUpdateApplier.apply(scrollUpdate, to: initialBaseline)
            XCTAssertEqual(GhosttyTerminalSnapshotLayout.plainText(for: applied.snapshot), "frame two")

        }
    }

    func testRemoteScreenStateVisibleContentIgnoresBlankSnapshotsAndText() async {
        try await TerminalEngineActor.run {
            XCTAssertFalse(GhosttyEmbeddedSessionCore.remoteScreenStateHasVisibleContent(snapshot: Self.snapshot(text: "   \n  "), snapshotText: nil))
            XCTAssertFalse(GhosttyEmbeddedSessionCore.remoteScreenStateHasVisibleContent(snapshot: nil, snapshotText: " \n\t "))
            XCTAssertTrue(GhosttyEmbeddedSessionCore.remoteScreenStateHasVisibleContent(snapshot: Self.snapshot(text: "Codex"), snapshotText: nil))
            XCTAssertTrue(GhosttyEmbeddedSessionCore.remoteScreenStateHasVisibleContent(snapshot: nil, snapshotText: "OpenAI Codex"))

        }
    }

    func testTerminalInputTranslatorSuppressesFunctionKeyPrivateUseText() async {
        try await TerminalEngineActor.run {
            let event = try! XCTUnwrap(
                NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: "\u{F700}",
                    charactersIgnoringModifiers: "\u{F700}", isARepeat: false, keyCode: UInt16(kVK_UpArrow)))

            XCTAssertNil(GhosttyTerminalInputTranslator.ghosttyText(for: event))
            XCTAssertEqual(GhosttyTerminalInputTranslator.rawKeyFallbackSpecifier(for: event), "up")

        }
    }

    func testTerminalInputTranslatorMapsCommonNavigationAndFunctionFallbackKeys() async {
        try await TerminalEngineActor.run {
            let rightEvent = try! XCTUnwrap(
                NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: "\u{F703}",
                    charactersIgnoringModifiers: "\u{F703}", isARepeat: false, keyCode: UInt16(kVK_RightArrow)))
            let functionRightEvent = try! XCTUnwrap(
                NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: [.function], timestamp: 0, windowNumber: 0, context: nil, characters: "\u{F703}",
                    charactersIgnoringModifiers: "\u{F703}", isARepeat: false, keyCode: UInt16(kVK_RightArrow)))
            let numericFunctionRightEvent = try! XCTUnwrap(
                NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: [.numericPad, .function], timestamp: 0, windowNumber: 0, context: nil,
                    characters: "\u{F703}", charactersIgnoringModifiers: "\u{F703}", isARepeat: false, keyCode: UInt16(kVK_RightArrow)))
            let homeEvent = try! XCTUnwrap(
                NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: "\u{F729}",
                    charactersIgnoringModifiers: "\u{F729}", isARepeat: false, keyCode: UInt16(kVK_Home)))
            let pageDownEvent = try! XCTUnwrap(
                NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: "\u{F72D}",
                    charactersIgnoringModifiers: "\u{F72D}", isARepeat: false, keyCode: UInt16(kVK_PageDown)))
            let backtabEvent = try! XCTUnwrap(
                NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: [.shift], timestamp: 0, windowNumber: 0, context: nil, characters: "\u{19}",
                    charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: UInt16(kVK_Tab)))
            let f5Event = try! XCTUnwrap(
                NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: "\u{F708}",
                    charactersIgnoringModifiers: "\u{F708}", isARepeat: false, keyCode: UInt16(kVK_F5)))

            XCTAssertEqual(GhosttyTerminalInputTranslator.rawKeyFallbackSpecifier(for: rightEvent), "right")
            XCTAssertEqual(GhosttyTerminalInputTranslator.rawKeyFallbackSpecifier(for: functionRightEvent), "right")
            XCTAssertEqual(GhosttyTerminalInputTranslator.rawKeyFallbackSpecifier(for: numericFunctionRightEvent), "right")
            XCTAssertEqual(GhosttyTerminalInputTranslator.rawKeyFallbackSpecifier(for: homeEvent), "home")
            XCTAssertEqual(GhosttyTerminalInputTranslator.rawKeyFallbackSpecifier(for: pageDownEvent), "pagedown")
            XCTAssertEqual(GhosttyTerminalInputTranslator.rawKeyFallbackSpecifier(for: backtabEvent), "backtab")
            XCTAssertEqual(GhosttyTerminalInputTranslator.rawKeyFallbackSpecifier(for: f5Event), "f5")

        }
    }

    func testTerminalInputTranslatorMapsModifiedLineNavigationFallbacks() async {
        try await TerminalEngineActor.run {
            let commandLeftEvent = try! XCTUnwrap(
                NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 0, windowNumber: 0, context: nil, characters: "\u{F702}",
                    charactersIgnoringModifiers: "\u{F702}", isARepeat: false, keyCode: UInt16(kVK_LeftArrow)))
            let commandRightEvent = try! XCTUnwrap(
                NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 0, windowNumber: 0, context: nil, characters: "\u{F703}",
                    charactersIgnoringModifiers: "\u{F703}", isARepeat: false, keyCode: UInt16(kVK_RightArrow)))
            let optionLeftEvent = try! XCTUnwrap(
                NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: [.option], timestamp: 0, windowNumber: 0, context: nil, characters: "\u{F702}",
                    charactersIgnoringModifiers: "\u{F702}", isARepeat: false, keyCode: UInt16(kVK_LeftArrow)))
            let optionRightEvent = try! XCTUnwrap(
                NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: [.option], timestamp: 0, windowNumber: 0, context: nil, characters: "\u{F703}",
                    charactersIgnoringModifiers: "\u{F703}", isARepeat: false, keyCode: UInt16(kVK_RightArrow)))

            XCTAssertEqual(GhosttyTerminalInputTranslator.rawKeyFallbackSpecifier(for: commandLeftEvent), "cmd+left")
            XCTAssertEqual(GhosttyTerminalInputTranslator.rawKeyFallbackSpecifier(for: commandRightEvent), "cmd+right")
            XCTAssertEqual(GhosttyTerminalInputTranslator.rawKeyFallbackSpecifier(for: optionLeftEvent), "opt+left")
            XCTAssertEqual(GhosttyTerminalInputTranslator.rawKeyFallbackSpecifier(for: optionRightEvent), "opt+right")

        }
    }

    @MainActor func testMirrorTerminalViewMapsCommandKToHostClearAction() {
        let commandKEvent = try! XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 0, windowNumber: 0, context: nil, characters: "k",
                charactersIgnoringModifiers: "k", isARepeat: false, keyCode: UInt16(kVK_ANSI_K)))
        let commandDeleteEvent = try! XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 0, windowNumber: 0, context: nil, characters: "\u{7F}",
                charactersIgnoringModifiers: "\u{7F}", isARepeat: false, keyCode: UInt16(kVK_Delete)))
        let optionDeleteEvent = try! XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [.option], timestamp: 0, windowNumber: 0, context: nil, characters: "\u{7F}",
                charactersIgnoringModifiers: "\u{7F}", isARepeat: false, keyCode: UInt16(kVK_Delete)))

        XCTAssertEqual(GhosttyMirrorTerminalView.remoteKeySpecifier(for: commandKEvent), "cmd+k")
        XCTAssertEqual(GhosttyMirrorTerminalView.remoteKeySpecifier(for: commandDeleteEvent), "cmd+backspace")
        XCTAssertEqual(GhosttyMirrorTerminalView.remoteKeySpecifier(for: optionDeleteEvent), "opt+backspace")
    }

    func testTerminalInputTranslatorUsesPrintableTextForControlKeyEvents() async {
        try await TerminalEngineActor.run {
            let event = try! XCTUnwrap(
                NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: [.control], timestamp: 0, windowNumber: 0, context: nil, characters: "\u{1F}",
                    charactersIgnoringModifiers: "_", isARepeat: false, keyCode: UInt16(kVK_ANSI_U)))

            XCTAssertEqual(GhosttyTerminalInputTranslator.ghosttyText(for: event), "u")

        }
    }

    func testTerminalInputTranslatorDefersStandardWindowManagementShortcutsToSystem() async {
        try await TerminalEngineActor.run {
            XCTAssertTrue(GhosttyTerminalInputTranslator.shouldDeferToSystemShortcut(keyCode: UInt16(kVK_ANSI_W), modifierFlags: [.command]))
            XCTAssertTrue(GhosttyTerminalInputTranslator.shouldDeferToSystemShortcut(keyCode: UInt16(kVK_ANSI_M), modifierFlags: [.command]))
            XCTAssertTrue(
                GhosttyTerminalInputTranslator.shouldDeferToSystemShortcut(keyCode: UInt16(kVK_LeftArrow), modifierFlags: [.control, .function]))
            XCTAssertTrue(
                GhosttyTerminalInputTranslator.shouldDeferToSystemShortcut(keyCode: UInt16(kVK_RightArrow), modifierFlags: [.control, .function]))
            XCTAssertFalse(GhosttyTerminalInputTranslator.shouldDeferToSystemShortcut(keyCode: UInt16(kVK_ANSI_C), modifierFlags: [.command]))
            XCTAssertFalse(GhosttyTerminalInputTranslator.shouldDeferToSystemShortcut(keyCode: UInt16(kVK_UpArrow), modifierFlags: []))

        }
    }

    func testActionEventsUpdateEffectiveTitleAndWorkingDirectory() async throws {
        try await TerminalEngineActor.run {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }

            let launchConfiguration = TerminalSessionLaunchConfiguration(
                sessionID: "session-1", backend: .ghosttyEmbedded, title: "fallback-title", workingDirectory: "/tmp/original", shell: "/bin/zsh",
                command: "cat", createdAt: "2026-05-09T00:00:00Z", workspaceID: "workspace-1", kind: .shell)
            let host = GhosttyEmbeddedSessionHost(launchConfiguration: launchConfiguration, paths: .init(rootDirectory: root.path))

            XCTAssertEqual(host.effectiveTitle, "fallback-title")
            XCTAssertEqual(host.effectiveWorkingDirectory, "/tmp/original")

            host.applyActionEvent(.setTitle(" live-title "))
            host.applyActionEvent(.setWorkingDirectory(" /tmp/updated "))

            XCTAssertEqual(host.debugCurrentTitle, "live-title")
            XCTAssertEqual(host.debugCurrentWorkingDirectory, "/tmp/updated")
            XCTAssertEqual(host.effectiveTitle, "live-title")
            XCTAssertEqual(host.effectiveWorkingDirectory, "/tmp/updated")

        }
    }

    func testBlankActionValuesResetToLaunchConfigurationFallbacks() async throws {
        try await TerminalEngineActor.run {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }

            let launchConfiguration = TerminalSessionLaunchConfiguration(
                sessionID: "session-2", backend: .ghosttyEmbedded, title: "fallback-title", workingDirectory: "/tmp/original", shell: "/bin/zsh",
                command: nil, createdAt: "2026-05-09T00:00:00Z", workspaceID: "workspace-1", kind: .shell)
            let host = GhosttyEmbeddedSessionHost(launchConfiguration: launchConfiguration, paths: .init(rootDirectory: root.path))

            host.applyActionEvent(.setTitle("custom"))
            host.applyActionEvent(.setWorkingDirectory("/tmp/custom"))
            host.applyActionEvent(.setTitle("   "))
            host.applyActionEvent(.setWorkingDirectory("\n"))

            XCTAssertNil(host.debugCurrentTitle)
            XCTAssertNil(host.debugCurrentWorkingDirectory)
            XCTAssertEqual(host.effectiveTitle, "fallback-title")
            XCTAssertEqual(host.effectiveWorkingDirectory, "/tmp/original")

        }
    }

    func testSessionStateChangesUpdateEffectiveTitleAndWorkingDirectory() async throws {
        try await TerminalEngineActor.run {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }

            let launchConfiguration = TerminalSessionLaunchConfiguration(
                sessionID: "session-state-1", backend: .ghosttyEmbedded, title: "fallback-title", workingDirectory: "/tmp/original", shell: "/bin/zsh",
                command: "cat", createdAt: "2026-05-19T00:00:00Z", workspaceID: "workspace-1", kind: .shell)
            let host = GhosttyEmbeddedSessionHost(launchConfiguration: launchConfiguration, paths: .init(rootDirectory: root.path))

            host.applySessionStateChange(
                .init(flags: [.title, .workingDirectory], revision: 1, title: " live-title ", workingDirectory: " /tmp/updated "))

            XCTAssertEqual(host.debugCurrentTitle, "live-title")
            XCTAssertEqual(host.debugCurrentWorkingDirectory, "/tmp/updated")
            XCTAssertEqual(host.effectiveTitle, "live-title")
            XCTAssertEqual(host.effectiveWorkingDirectory, "/tmp/updated")

        }
    }

    func testBlankSessionStateValuesResetToLaunchConfigurationFallbacks() async throws {
        try await TerminalEngineActor.run {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }

            let launchConfiguration = TerminalSessionLaunchConfiguration(
                sessionID: "session-state-2", backend: .ghosttyEmbedded, title: "fallback-title", workingDirectory: "/tmp/original", shell: "/bin/zsh",
                command: nil, createdAt: "2026-05-19T00:00:00Z", workspaceID: "workspace-1", kind: .shell)
            let host = GhosttyEmbeddedSessionHost(launchConfiguration: launchConfiguration, paths: .init(rootDirectory: root.path))

            host.applySessionStateChange(.init(flags: [.title, .workingDirectory], revision: 1, title: "custom", workingDirectory: "/tmp/custom"))
            host.applySessionStateChange(.init(flags: [.title, .workingDirectory], revision: 2, title: "   ", workingDirectory: "\n"))

            XCTAssertNil(host.debugCurrentTitle)
            XCTAssertNil(host.debugCurrentWorkingDirectory)
            XCTAssertEqual(host.effectiveTitle, "fallback-title")
            XCTAssertEqual(host.effectiveWorkingDirectory, "/tmp/original")

        }
    }

    func testEmbeddedHostExposesDistinctRendererAdapter() async throws {
        try await TerminalEngineActor.run {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }

            let launchConfiguration = TerminalSessionLaunchConfiguration(
                sessionID: "session-renderer-adapter", backend: .ghosttyEmbedded, title: "shell", workingDirectory: "/tmp/original", shell: "/bin/zsh",
                command: nil, createdAt: "2026-05-18T00:00:00Z", workspaceID: "workspace-1", kind: .shell)
            let host = GhosttyEmbeddedSessionHost(launchConfiguration: launchConfiguration, paths: .init(rootDirectory: root.path))

            XCTAssertTrue((host.rendererHost as AnyObject) is GhosttyHeadlessRendererHost)
            XCTAssertFalse((host.rendererHost as AnyObject) === host)

        }
    }

    func testLocalOwnerAttachExportsLiveSessionSnapshotForMacBootstrap() async throws {
        try await TerminalEngineActor.run {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }

            let launchConfiguration = TerminalSessionLaunchConfiguration(
                sessionID: "session-local-owner-no-snapshot-\(UUID().uuidString)", backend: .ghosttyEmbedded, title: "shell",
                workingDirectory: FileManager.default.temporaryDirectory.path, shell: "/bin/sh", command: "cat", createdAt: "2026-05-23T00:00:00Z",
                workspaceID: "workspace-1", kind: .shell)
            let host = GhosttyEmbeddedSessionHost(launchConfiguration: launchConfiguration, paths: .init(rootDirectory: root.path))
            let ownerClient = TerminalClient(
                id: "local-window", kind: .localWindow, identity: .init(label: "Spaces window"), connectedAt: "2026-05-23T00:00:00Z")
            var sessionCaptureCount = 0
            GhosttyTerminalSnapshotCapture.sessionCaptureHandlerForTesting = { _ in
                sessionCaptureCount += 1
                return nil
            }
            defer {
                GhosttyTerminalSnapshotCapture.sessionCaptureHandlerForTesting = nil
                host.core.terminate()
            }

            try host.attach(client: ownerClient, mode: .owner, into: nil)

            XCTAssertGreaterThanOrEqual(sessionCaptureCount, 1)

        }
    }

    func testRemoteTakeoverFromLocalOwnerExportsLiveSessionSnapshotWithoutSurfaceRefresh() async throws {
        try await TerminalEngineActor.run {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }

            let paths = TerminalSessionPaths(rootDirectory: root.path)
            let launchConfiguration = TerminalSessionLaunchConfiguration(
                sessionID: "session-remote-takeover-no-snapshot-\(UUID().uuidString)", backend: .ghosttyEmbedded, title: "shell",
                workingDirectory: FileManager.default.temporaryDirectory.path, shell: "/bin/sh", command: "cat", createdAt: "2026-05-23T00:00:00Z",
                workspaceID: "workspace-1", kind: .shell)
            var surfaceRefreshCount = 0
            let host = GhosttyEmbeddedSessionHost(launchConfiguration: launchConfiguration, paths: paths) { surfaceRefreshCount += 1 }
            let localOwner = TerminalClient(
                id: "local-window", kind: .localWindow, identity: .init(label: "Spaces window"), connectedAt: "2026-05-23T00:00:00Z")
            let remoteOwner = TerminalClient(
                id: "remote-ipad", kind: .remoteViewer, identity: .init(label: "iPad", deviceName: "iPad"), connectedAt: "2026-05-23T00:00:01Z")
            var sessionCaptureCount = 0
            GhosttyTerminalSnapshotCapture.sessionCaptureHandlerForTesting = { _ in
                sessionCaptureCount += 1
                return Self.snapshot(text: "OpenAI Codex")
            }
            defer {
                GhosttyTerminalSnapshotCapture.sessionCaptureHandlerForTesting = nil
                host.core.terminate()
            }

            try host.attach(client: localOwner, mode: .owner, into: nil)
            let captureCountAfterLocalAttach = sessionCaptureCount
            let surfaceRefreshCountAfterLocalAttach = surfaceRefreshCount
            XCTAssertEqual(host.core.handleControlRequest(.init(command: "attach", client: remoteOwner, attachmentMode: .viewer)).ok, true)
            XCTAssertEqual(host.core.handleControlRequest(.init(command: "takeover", clientID: remoteOwner.id)).ok, true)

            XCTAssertGreaterThan(sessionCaptureCount, captureCountAfterLocalAttach)
            XCTAssertEqual(surfaceRefreshCount, surfaceRefreshCountAfterLocalAttach)

        }
    }

    func testRemoteOwnerReconnectInitialStateRefreshesLiveSessionSnapshot() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = TerminalSessionPaths(rootDirectory: root.path)
        try paths.ensureDirectories()
        let launchConfiguration = TerminalSessionLaunchConfiguration(
            sessionID: "session-remote-reconnect-\(UUID().uuidString)", backend: .ghosttyEmbedded, title: "shell",
            workingDirectory: FileManager.default.temporaryDirectory.path, shell: "/bin/sh", command: "cat", createdAt: "2026-05-24T00:00:00Z",
            workspaceID: "workspace-1", kind: .shell)
        let localOwner = TerminalClient(
            id: "local-window", kind: .localWindow, identity: .init(label: "Spaces window"), connectedAt: "2026-05-24T00:00:00Z")
        let remoteOwner = TerminalClient(
            id: "remote-ipad", kind: .remoteViewer, identity: .init(label: "iPad", deviceName: "iPad"), connectedAt: "2026-05-24T00:00:01Z")
        let sessionCaptureCountBox = MutableBox(0)
        GhosttyTerminalSnapshotCapture.sessionCaptureHandlerForTesting = { _ in
            sessionCaptureCountBox.value += 1
            return Self.snapshot(text: sessionCaptureCountBox.value == 1 ? "takeover bootstrap" : "fresh reconnect")
        }
        defer { GhosttyTerminalSnapshotCapture.sessionCaptureHandlerForTesting = nil }

        let hostBox = try await TerminalEngineActor.run { () -> Box<GhosttyEmbeddedSessionHost> in
            let host = GhosttyEmbeddedSessionHost(launchConfiguration: launchConfiguration, paths: paths)
            try host.attach(client: localOwner, mode: .owner, into: nil)
            XCTAssertEqual(host.core.handleControlRequest(.init(command: "attach", client: remoteOwner, attachmentMode: .viewer)).ok, true)
            XCTAssertEqual(host.core.handleControlRequest(.init(command: "takeover", clientID: remoteOwner.id)).ok, true)
            return Box(host)
        }
        let host = hostBox.value
        defer { TerminalEngineActor.runSynchronously { host.core.terminate() } }
        let captureCountBeforeReconnect = sessionCaptureCountBox.value

        let receivedPayloads = RemoteSessionStatePayloadCollector()
        let client = GhosttyRemoteSessionStateStreamClient(socketPath: paths.subscriptionSocketPath) { payload in receivedPayloads.append(payload) }
        try client.start()
        defer { client.stop() }

        try await waitUntil(timeout: 2) { !receivedPayloads.snapshot.isEmpty }
        let initialSnapshot = try XCTUnwrap(receivedPayloads.snapshot.first?.renderSnapshot)

        XCTAssertEqual(GhosttyTerminalSnapshotLayout.plainText(for: initialSnapshot), "fresh reconnect")
        XCTAssertNil(receivedPayloads.snapshot.first?.outputEndByteOffset)
        XCTAssertGreaterThan(sessionCaptureCountBox.value, captureCountBeforeReconnect)
    }

    func testIncomingOutputRequestsSurfaceRefreshImmediately() async throws {
        try await TerminalEngineActor.run {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }

            let paths = TerminalSessionPaths(rootDirectory: root.path)
            let launchConfiguration = TerminalSessionLaunchConfiguration(
                sessionID: "session-3", backend: .ghosttyEmbedded, title: "shell", workingDirectory: "/tmp/original", shell: "/bin/zsh", command: "zsh",
                createdAt: "2026-05-10T00:00:00Z", workspaceID: "workspace-1", kind: .shell)
            var refreshCount = 0
            var outputAtRefresh: String?
            let host = GhosttyEmbeddedSessionHost(
                launchConfiguration: launchConfiguration, paths: paths,
                requestSurfaceRefreshAction: {
                    refreshCount += 1
                    outputAtRefresh = try? String(contentsOfFile: paths.outputPath)
                })

            host.debugHandleIncomingOutput(Data("echo hello\n".utf8))

            XCTAssertEqual(refreshCount, 1)
            XCTAssertEqual(outputAtRefresh, "echo hello\n")
            let output = try String(contentsOfFile: paths.outputPath)
            XCTAssertEqual(output, "echo hello\n")

        }
    }

    func testInteractiveLocalOwnerOutputPublishesSnapshotWithoutDelayedInputOutputResync() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = TerminalSessionPaths(rootDirectory: root.path)
        try paths.ensureDirectories()
        let launchConfiguration = TerminalSessionLaunchConfiguration(
            sessionID: "session-interactive-input-output", backend: .ghosttyEmbedded, title: "shell", workingDirectory: "/tmp/original",
            shell: "/bin/zsh", command: "zsh", createdAt: "2026-05-28T00:00:00Z", workspaceID: "workspace-1", kind: .shell)
        GhosttyTerminalSnapshotCapture.sessionCaptureHandlerForTesting = { _ in Self.snapshot(text: "echo hello") }
        defer { GhosttyTerminalSnapshotCapture.sessionCaptureHandlerForTesting = nil }

        let hostBox = try await TerminalEngineActor.run { () -> Box<GhosttyEmbeddedSessionHost> in
            let host = GhosttyEmbeddedSessionHost(launchConfiguration: launchConfiguration, paths: paths)
            let localOwner = TerminalClient(
                id: "local-window", kind: .localWindow, identity: TerminalClientIdentity(label: "Spaces window"), connectedAt: "2026-05-28T00:00:00Z")
            try host.attach(client: localOwner, mode: .owner, into: nil)
            return Box(host)
        }
        let host = hostBox.value
        defer { TerminalEngineActor.runSynchronously { host.terminate() } }

        let receivedPayloads = RemoteSessionStatePayloadCollector()
        let client = GhosttyRemoteSessionStateStreamClient(socketPath: paths.subscriptionSocketPath) { payload in receivedPayloads.append(payload) }
        try client.start()
        defer { client.stop() }
        try await waitUntil(timeout: 2) { receivedPayloads.snapshot.contains { $0.reason == TerminalRemoteSessionStateReason.initial } }
        receivedPayloads.removeAll()

        let output = Data("e".utf8)
        try await TerminalEngineActor.run {
            host.debugHandleOwnerInputActivity(byteCount: output.count)
            host.debugHandleIncomingOutput(output)
        }

        try await waitUntil(timeout: 2) {
            receivedPayloads.snapshot.contains { $0.reason == "output" && $0.outputByteCount == output.count && $0.renderUpdate != nil }
        }
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(receivedPayloads.snapshot.contains { $0.reason == "input_output" })
    }

    func testInteractiveLocalOwnerCommandOutputKeepsDelayedInputOutputResync() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = TerminalSessionPaths(rootDirectory: root.path)
        try paths.ensureDirectories()
        let launchConfiguration = TerminalSessionLaunchConfiguration(
            sessionID: "session-interactive-command-input-output", backend: .ghosttyEmbedded, title: "shell", workingDirectory: "/tmp/original",
            shell: "/bin/zsh", command: "zsh", createdAt: "2026-05-28T00:00:00Z", workspaceID: "workspace-1", kind: .shell)
        GhosttyTerminalSnapshotCapture.sessionCaptureHandlerForTesting = { _ in Self.snapshot(text: "echo hello") }
        defer { GhosttyTerminalSnapshotCapture.sessionCaptureHandlerForTesting = nil }

        let hostBox = try await TerminalEngineActor.run { () -> Box<GhosttyEmbeddedSessionHost> in
            let host = GhosttyEmbeddedSessionHost(launchConfiguration: launchConfiguration, paths: paths)
            let localOwner = TerminalClient(
                id: "local-window", kind: .localWindow, identity: TerminalClientIdentity(label: "Spaces window"), connectedAt: "2026-05-28T00:00:00Z")
            try host.attach(client: localOwner, mode: .owner, into: nil)
            return Box(host)
        }
        let host = hostBox.value
        defer { TerminalEngineActor.runSynchronously { host.terminate() } }

        let receivedPayloads = RemoteSessionStatePayloadCollector()
        let client = GhosttyRemoteSessionStateStreamClient(socketPath: paths.subscriptionSocketPath) { payload in receivedPayloads.append(payload) }
        try client.start()
        defer { client.stop() }
        try await waitUntil(timeout: 2) { receivedPayloads.snapshot.contains { $0.reason == TerminalRemoteSessionStateReason.initial } }
        receivedPayloads.removeAll()

        let output = Data("e".utf8)
        try await TerminalEngineActor.run {
            host.debugHandleOwnerInputActivity(byteCount: output.count)
            host.debugMarkLocalOwnerCommandInputOutputResyncPending()
            host.debugHandleIncomingOutput(output)
        }

        try await waitUntil(timeout: 2) {
            receivedPayloads.snapshot.contains { $0.reason == "output" && $0.outputByteCount == output.count && $0.renderUpdate != nil }
                && receivedPayloads.snapshot.contains { $0.reason == "input_output" && $0.renderUpdate != nil }
        }

        let outputIndex = try XCTUnwrap(receivedPayloads.snapshot.firstIndex { $0.reason == "output" && $0.outputByteCount == output.count })
        let inputOutputIndex = try XCTUnwrap(receivedPayloads.snapshot.firstIndex { $0.reason == "input_output" })
        XCTAssertLessThan(outputIndex, inputOutputIndex)
        let inputOutputUpdate = try XCTUnwrap(receivedPayloads.snapshot[inputOutputIndex].decodedRenderUpdate)
        XCTAssertEqual(inputOutputUpdate.kind, .full)
        XCTAssertEqual(inputOutputUpdate.fallbackReason, "explicit_resync")
        let inputOutputFrame = try XCTUnwrap(inputOutputUpdate.fullFrame)
        XCTAssertEqual(GhosttyTerminalSnapshotLayout.plainText(for: inputOutputFrame.snapshot), "echo hello")
    }

    func testBulkLocalOwnerOutputPublishesSnapshotBeforeInputOutputResync() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = TerminalSessionPaths(rootDirectory: root.path)
        try paths.ensureDirectories()
        let launchConfiguration = TerminalSessionLaunchConfiguration(
            sessionID: "session-input-output-resync", backend: .ghosttyEmbedded, title: "shell", workingDirectory: "/tmp/original", shell: "/bin/zsh",
            command: "zsh", createdAt: "2026-05-28T00:00:00Z", workspaceID: "workspace-1", kind: .shell)
        GhosttyTerminalSnapshotCapture.sessionCaptureHandlerForTesting = { _ in Self.snapshot(text: "echo hello") }
        defer { GhosttyTerminalSnapshotCapture.sessionCaptureHandlerForTesting = nil }

        let hostBox = try await TerminalEngineActor.run { () -> Box<GhosttyEmbeddedSessionHost> in
            let host = GhosttyEmbeddedSessionHost(launchConfiguration: launchConfiguration, paths: paths)
            let localOwner = TerminalClient(
                id: "local-window", kind: .localWindow, identity: TerminalClientIdentity(label: "Spaces window"), connectedAt: "2026-05-28T00:00:00Z")
            try host.attach(client: localOwner, mode: .owner, into: nil)
            return Box(host)
        }
        let host = hostBox.value
        defer { TerminalEngineActor.runSynchronously { host.terminate() } }

        let receivedPayloads = RemoteSessionStatePayloadCollector()
        let client = GhosttyRemoteSessionStateStreamClient(socketPath: paths.subscriptionSocketPath) { payload in receivedPayloads.append(payload) }
        try client.start()
        defer { client.stop() }
        try await waitUntil(timeout: 2) { receivedPayloads.snapshot.contains { $0.reason == TerminalRemoteSessionStateReason.initial } }
        var baseline = try Self.renderBaseline(from: try XCTUnwrap(receivedPayloads.snapshot.first), baseline: nil)
        receivedPayloads.removeAll()

        let output = Data("echo hello\n".utf8)
        try await TerminalEngineActor.run {
            host.debugHandleOwnerInputActivity(byteCount: 4096)
            host.debugHandleIncomingOutput(output)
        }

        try await waitUntil(timeout: 2) {
            receivedPayloads.snapshot.contains { $0.reason == "output" && $0.outputByteCount == output.count }
                && receivedPayloads.snapshot.contains { $0.reason == "input_output" }
        }

        let outputIndex = try XCTUnwrap(receivedPayloads.snapshot.firstIndex { $0.reason == "output" && $0.outputByteCount == output.count })
        let inputOutputIndex = try XCTUnwrap(receivedPayloads.snapshot.firstIndex { $0.reason == "input_output" })
        XCTAssertLessThan(outputIndex, inputOutputIndex)
        for payload in receivedPayloads.snapshot[..<outputIndex] where payload.renderUpdate != nil {
            baseline = try Self.renderBaseline(from: payload, baseline: baseline)
        }
        XCTAssertNotNil(receivedPayloads.snapshot[outputIndex].renderUpdate)
        baseline = try Self.renderBaseline(from: receivedPayloads.snapshot[outputIndex], baseline: baseline)
        XCTAssertEqual(GhosttyTerminalSnapshotLayout.plainText(for: baseline.snapshot), "echo hello")
        XCTAssertNotNil(receivedPayloads.snapshot[inputOutputIndex].renderUpdate)
        baseline = try Self.renderBaseline(from: receivedPayloads.snapshot[inputOutputIndex], baseline: baseline)
        XCTAssertEqual(GhosttyTerminalSnapshotLayout.plainText(for: baseline.snapshot), "echo hello")
    }

    func testStateExportFlushesBufferedOutputWithoutNestedOutputBroadcast() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = TerminalSessionPaths(rootDirectory: root.path)
        try paths.ensureDirectories()
        let launchConfiguration = TerminalSessionLaunchConfiguration(
            sessionID: "session-state-export-flush-\(UUID().uuidString)", backend: .ghosttyEmbedded, title: "shell",
            workingDirectory: "/tmp/original", shell: "/bin/zsh", command: "zsh", createdAt: "2026-06-04T00:00:00Z", workspaceID: "workspace-1",
            kind: .shell)
        let localOwner = TerminalClient(
            id: "local-window", kind: .localWindow, identity: TerminalClientIdentity(label: "Spaces window"), connectedAt: "2026-06-04T00:00:00Z")
        try TerminalSessionPersistence.writeLaunchConfiguration(launchConfiguration, paths: paths)
        try TerminalSessionPersistence.writeRuntimeState(
            TerminalSessionRuntimeState(
                sessionID: launchConfiguration.sessionID, backend: .ghosttyEmbedded, servicePID: 1, childPID: 2, state: .running,
                updatedAt: "2026-06-04T00:00:00Z", title: "shell", workingDirectory: "/tmp/original", columns: 80, rows: 24), paths: paths)
        try TerminalSessionPersistence.attachClient(
            sessionID: launchConfiguration.sessionID, client: localOwner, mode: .owner, paths: paths, attachedAt: "2026-06-04T00:00:00Z")

        let hostBox = try await TerminalEngineActor.run { () -> Box<GhosttyEmbeddedSessionHost> in
            let core = GhosttyEmbeddedSessionCore(launchConfiguration: launchConfiguration, paths: paths, requestSurfaceRefreshAction: {})
            let host = GhosttyEmbeddedSessionHost(core: core)
            try host.debugStartStateStreamServerForTesting()
            return Box(host)
        }
        let host = hostBox.value
        defer { TerminalEngineActor.runSynchronously { host.debugStopStateStreamServerForTesting() } }

        let receivedPayloads = RemoteSessionStatePayloadCollector()
        let client = GhosttyRemoteSessionStateStreamClient(socketPath: paths.subscriptionSocketPath) { payload in receivedPayloads.append(payload) }
        try client.start()
        defer { client.stop() }
        try await waitUntil(timeout: 2) { receivedPayloads.snapshot.contains { $0.reason == TerminalRemoteSessionStateReason.initial } }
        receivedPayloads.removeAll()

        let output = Data("queued output\n".utf8)
        try await TerminalEngineActor.run {
            host.debugBufferIncomingOutputForStateExport(output)
            host.debugBroadcastCurrentStateForTesting(reason: TerminalRemoteSessionStateReason.stateChange)
        }

        try await waitUntil(timeout: 2) { receivedPayloads.snapshot.contains { $0.reason == TerminalRemoteSessionStateReason.stateChange } }
        try? await Task.sleep(for: .milliseconds(50))

        XCTAssertFalse(receivedPayloads.snapshot.contains { $0.reason == TerminalRemoteSessionStateReason.output && $0.outputByteCount == output.count })
        XCTAssertTrue(try String(contentsOfFile: paths.outputPath).hasSuffix("queued output\n"))
    }

    func testIncomingOutputUsesRendererRefreshSchedulerByDefault() async throws {
        try await TerminalEngineActor.run {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }

            let launchConfiguration = TerminalSessionLaunchConfiguration(
                sessionID: "session-output-default-refresh", backend: .ghosttyEmbedded, title: "shell", workingDirectory: "/tmp/original",
                shell: "/bin/zsh", command: "zsh", createdAt: "2026-05-18T00:00:00Z", workspaceID: "workspace-1", kind: .shell)
            let host = GhosttyEmbeddedSessionHost(launchConfiguration: launchConfiguration, paths: .init(rootDirectory: root.path))

            XCTAssertEqual(host.debugSurfaceRefreshRequestCount, 0)

            host.debugHandleIncomingOutput(Data("prompt".utf8))

            XCTAssertEqual(host.debugSurfaceRefreshRequestCount, 1)

        }
    }

    func testRuntimeStateRemainsRunningWhenCachedChildPIDHasDied() async throws {
        try await TerminalEngineActor.run {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }

            let paths = TerminalSessionPaths(rootDirectory: root.path)
            try paths.ensureDirectories()
            let launchConfiguration = TerminalSessionLaunchConfiguration(
                sessionID: "session-4", backend: .ghosttyEmbedded, title: "shell", workingDirectory: "/tmp/original", shell: "/bin/zsh", command: "zsh",
                createdAt: "2026-05-10T00:00:00Z", workspaceID: "workspace-1", kind: .shell)
            let host = GhosttyEmbeddedSessionHost(launchConfiguration: launchConfiguration, paths: paths)

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", "exit 0"]
            try process.run()
            let childPID = process.processIdentifier
            process.waitUntilExit()

            host.debugSetLastKnownChildPID(childPID)
            host.debugPersistRuntimeState()

            let runtimeState = try TerminalSessionPersistence.readRuntimeState(paths: paths)
            XCTAssertEqual(runtimeState.state, .running)
            XCTAssertEqual(runtimeState.childPID, childPID)
            XCTAssertNil(runtimeState.exitedAt)

        }
    }

    func testRuntimeStatePersistsKnownForegroundAgentClassification() async throws {
        try await TerminalEngineActor.run {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }

            let paths = TerminalSessionPaths(rootDirectory: root.path)
            try paths.ensureDirectories()
            let launchConfiguration = TerminalSessionLaunchConfiguration(
                sessionID: "session-foreground-agent-\(UUID().uuidString)", backend: .ghosttyEmbedded, title: "shell", workingDirectory: "/tmp/original",
                shell: "/bin/zsh", command: "zsh", createdAt: "2026-05-10T00:00:00Z", workspaceID: "workspace-1", kind: .shell)
            let host = GhosttyEmbeddedSessionHost(launchConfiguration: launchConfiguration, paths: paths)
            let childPID: Int32 = 900
            let foregroundPID: Int32 = 42
            host.debugSetLastKnownChildPID(childPID)
            host.debugSetForegroundPIDForTesting(foregroundPID)
            host.debugSetForegroundProcessResolverForTesting { pid in
                TerminalForegroundProcessSnapshot(
                    pid: pid, executablePath: "/opt/homebrew/bin/codex", executableName: "codex", argv: ["codex", "--model", "gpt-5"])
            }

            host.debugPersistRuntimeState()

            let runtimeState = try TerminalSessionPersistence.readRuntimeState(paths: paths)
            XCTAssertEqual(runtimeState.childPID, childPID)
            XCTAssertEqual(runtimeState.foregroundPID, foregroundPID)
            XCTAssertEqual(runtimeState.foregroundDetectedAgentKind, .codex)
            XCTAssertEqual(runtimeState.foregroundDisplayLabel, "codex")
            XCTAssertEqual(runtimeState.foregroundDisplayCommand, "codex --model gpt-5")

        }
    }

    func testRuntimeStateClearsForegroundAgentClassificationForUnknownForegroundProcess() async throws {
        try await TerminalEngineActor.run {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }

            let paths = TerminalSessionPaths(rootDirectory: root.path)
            try paths.ensureDirectories()
            let launchConfiguration = TerminalSessionLaunchConfiguration(
                sessionID: "session-foreground-clear-\(UUID().uuidString)", backend: .ghosttyEmbedded, title: "shell", workingDirectory: "/tmp/original",
                shell: "/bin/zsh", command: "zsh", createdAt: "2026-05-10T00:00:00Z", workspaceID: "workspace-1", kind: .shell)
            let host = GhosttyEmbeddedSessionHost(launchConfiguration: launchConfiguration, paths: paths)
            let childPID: Int32 = 900
            host.debugSetLastKnownChildPID(childPID)
            host.debugSetForegroundPIDForTesting(42)
            host.debugSetForegroundProcessResolverForTesting { pid in
                TerminalForegroundProcessSnapshot(pid: pid, executablePath: "/opt/homebrew/bin/codex", argv: ["codex"])
            }
            host.debugPersistRuntimeState()

            host.debugSetForegroundPIDForTesting(43)
            host.debugSetForegroundProcessResolverForTesting { pid in
                TerminalForegroundProcessSnapshot(pid: pid, executablePath: "/bin/zsh", argv: ["zsh"])
            }
            host.debugPersistRuntimeState()

            let runtimeState = try TerminalSessionPersistence.readRuntimeState(paths: paths)
            XCTAssertEqual(runtimeState.childPID, childPID)
            XCTAssertEqual(runtimeState.foregroundPID, 43)
            XCTAssertEqual(runtimeState.foregroundExecutablePath, "/bin/zsh")
            XCTAssertEqual(runtimeState.foregroundExecutableName, "zsh")
            XCTAssertEqual(runtimeState.foregroundArgv, ["zsh"])
            XCTAssertNil(runtimeState.foregroundDetectedAgentKind)
            XCTAssertNil(runtimeState.foregroundDisplayLabel)
            XCTAssertNil(runtimeState.foregroundDisplayCommand)

        }
    }

    func testStartedRuntimeMarksExitedWhenKnownChildPIDHasDied() async throws {
        try await TerminalEngineActor.run {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }

            let paths = TerminalSessionPaths(rootDirectory: root.path)
            try paths.ensureDirectories()
            let launchConfiguration = TerminalSessionLaunchConfiguration(
                sessionID: "session-dead-child-\(UUID().uuidString)", backend: .ghosttyEmbedded, title: "shell", workingDirectory: "/tmp/original",
                shell: "/bin/zsh", command: "printf done", createdAt: "2026-05-10T00:00:00Z", workspaceID: "workspace-1", kind: .shell)
            let host = GhosttyEmbeddedSessionHost(launchConfiguration: launchConfiguration, paths: paths)

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", "exit 0"]
            try process.run()
            let childPID = process.processIdentifier
            process.waitUntilExit()

            host.debugSetLastKnownChildPID(childPID)
            host.debugMarkStartedForTesting()
            FileManager.default.createFile(atPath: paths.controlSocketPath, contents: Data())

            host.debugPersistRuntimeState()

            let runtimeState = try TerminalSessionPersistence.readRuntimeState(paths: paths)
            XCTAssertEqual(runtimeState.state, .exited)
            XCTAssertEqual(runtimeState.childPID, childPID)
            XCTAssertNotNil(runtimeState.exitedAt)
            XCTAssertFalse(FileManager.default.fileExists(atPath: paths.controlSocketPath))

        }
    }

    func testStartedRuntimeKeepsAttachedSessionRunningWhenCachedChildPIDHasDied() async throws {
        try await TerminalEngineActor.run {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }

            let paths = TerminalSessionPaths(rootDirectory: root.path)
            try paths.ensureDirectories()
            let launchConfiguration = TerminalSessionLaunchConfiguration(
                sessionID: "session-attached-dead-child-\(UUID().uuidString)", backend: .ghosttyEmbedded, title: "shell",
                workingDirectory: "/tmp/original", shell: "/bin/zsh", command: "zsh", createdAt: "2026-05-10T00:00:00Z", workspaceID: "workspace-1",
                kind: .shell)
            let host = GhosttyEmbeddedSessionHost(launchConfiguration: launchConfiguration, paths: paths)
            try TerminalSessionPersistence.writeLaunchConfiguration(launchConfiguration, paths: paths)

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", "exit 0"]
            try process.run()
            let childPID = process.processIdentifier
            process.waitUntilExit()

            let client = TerminalClient(
                id: "local-window", kind: .localWindow, identity: .init(label: "Spaces window"), connectedAt: "2026-05-10T00:00:01Z")
            try TerminalSessionPersistence.upsertClient(client, paths: paths)
            try TerminalSessionPersistence.attachClient(
                sessionID: launchConfiguration.sessionID, client: client, mode: .owner, paths: paths, attachedAt: "2026-05-10T00:00:01Z")
            host.debugSetLastKnownChildPID(childPID)
            host.debugMarkStartedForTesting()

            host.debugPersistRuntimeState()

            let runtimeState = try TerminalSessionPersistence.readRuntimeState(paths: paths)
            XCTAssertEqual(runtimeState.state, .running)
            XCTAssertEqual(runtimeState.childPID, childPID)
            XCTAssertNil(runtimeState.exitedAt)

        }
    }

    func testTerminateMarksRuntimeExited() async throws {
        try await TerminalEngineActor.run {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }

            let paths = TerminalSessionPaths(rootDirectory: root.path)
            try paths.ensureDirectories()
            let launchConfiguration = TerminalSessionLaunchConfiguration(
                sessionID: "session-5", backend: .ghosttyEmbedded, title: "shell", workingDirectory: "/tmp/original", shell: "/bin/zsh", command: "zsh",
                createdAt: "2026-05-10T00:00:00Z", workspaceID: "workspace-1", kind: .shell)
            let host = GhosttyEmbeddedSessionHost(launchConfiguration: launchConfiguration, paths: paths)

            host.terminate()
            // terminate() enqueues the exited-state write off the engine and no longer blocks on its commit
            // (finding B3); block on the persistence queue before reading the durable mirror.
            host.debugDrainPersistenceQueue()

            let runtimeState = try TerminalSessionPersistence.readRuntimeState(paths: paths)
            XCTAssertEqual(runtimeState.state, .exited)
            XCTAssertNotNil(runtimeState.exitedAt)

        }
    }

    func testDeferredRuntimeRefreshDoesNotMarkTerminatedSessionRunning() async throws {
        try await TerminalEngineActor.run {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }

            let paths = TerminalSessionPaths(rootDirectory: root.path)
            try paths.ensureDirectories()
            let launchConfiguration = TerminalSessionLaunchConfiguration(
                sessionID: "session-deferred-refresh-\(UUID().uuidString)", backend: .ghosttyEmbedded, title: "shell", workingDirectory: "/tmp/original",
                shell: "/bin/zsh", command: "zsh", createdAt: "2026-05-10T00:00:00Z", workspaceID: "workspace-1", kind: .shell)
            let host = GhosttyEmbeddedSessionHost(launchConfiguration: launchConfiguration, paths: paths)

            host.debugMarkStartedForTesting()
            host.debugPersistRuntimeState()
            host.terminate()
            host.debugPersistRuntimeState()

            let runtimeState = try TerminalSessionPersistence.readRuntimeState(paths: paths)
            XCTAssertEqual(runtimeState.state, .exited)
            XCTAssertNotNil(runtimeState.exitedAt)

        }
    }

    func testLateOutputAfterTerminateDoesNotRecreateOutputFile() async throws {
        try await TerminalEngineActor.run {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }

            let paths = TerminalSessionPaths(rootDirectory: root.path)
            try paths.ensureDirectories()
            let launchConfiguration = TerminalSessionLaunchConfiguration(
                sessionID: "session-late-output-\(UUID().uuidString)", backend: .ghosttyEmbedded, title: "shell", workingDirectory: "/tmp/original",
                shell: "/bin/zsh", command: "zsh", createdAt: "2026-06-11T00:00:00Z", workspaceID: "workspace-1", kind: .shell)
            let host = GhosttyEmbeddedSessionHost(launchConfiguration: launchConfiguration, paths: paths)

            host.debugHandleIncomingOutput(Data("before terminate\n".utf8))
            XCTAssertTrue(FileManager.default.fileExists(atPath: paths.outputPath))

            host.terminate()
            try? FileManager.default.removeItem(atPath: paths.outputPath)
            host.debugHandleIncomingOutput(Data("late output\n".utf8))

            XCTAssertFalse(FileManager.default.fileExists(atPath: paths.outputPath))

        }
    }

    func testStartIfNeededRefreshesExitedRuntimeStateForReusedSessionID() async throws {
        try await TerminalEngineActor.run {
            let availability = GhosttyEmbeddedLocator.resolve(currentDirectoryPath: FileManager.default.currentDirectoryPath)
            guard case .available = availability else { throw XCTSkip("Ghostty runtime resources are unavailable for embedded renderer testing.") }

            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }

            let paths = TerminalSessionPaths(rootDirectory: root.path)
            try paths.ensureDirectories()
            let launchConfiguration = TerminalSessionLaunchConfiguration(
                sessionID: "session-reused-runtime-\(UUID().uuidString)", backend: .ghosttyEmbedded, title: "reused-session",
                workingDirectory: FileManager.default.temporaryDirectory.path, shell: "/bin/sh", command: "cat", createdAt: "2026-06-05T00:00:00Z",
                workspaceID: "workspace-1", kind: .shell)
            try TerminalSessionPersistence.writeLaunchConfiguration(launchConfiguration, paths: paths)
            try TerminalSessionPersistence.writeRuntimeState(
                TerminalSessionRuntimeState(
                    sessionID: launchConfiguration.sessionID, backend: .ghosttyEmbedded, servicePID: 1, childPID: 2, state: .exited,
                    updatedAt: "2026-06-05T00:00:00Z", exitedAt: "2026-06-05T00:00:00Z", title: "reused-session",
                    workingDirectory: FileManager.default.temporaryDirectory.path, columns: 80, rows: 24), paths: paths)
            let host = GhosttyEmbeddedSessionHost(launchConfiguration: launchConfiguration, paths: paths)
            defer { host.terminate() }

            try host.startIfNeeded()

            let runtimeState = try TerminalSessionPersistence.readRuntimeState(paths: paths)
            XCTAssertEqual(runtimeState.state, .running)
            XCTAssertNil(runtimeState.exitedAt)
            XCTAssertEqual(runtimeState.sessionID, launchConfiguration.sessionID)

        }
    }

    func testSessionCloseMarksRuntimeExitedAndRemovesControlSocket() async throws {
        try await TerminalEngineActor.run {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }

            let paths = TerminalSessionPaths(rootDirectory: root.path)
            try paths.ensureDirectories()
            let launchConfiguration = TerminalSessionLaunchConfiguration(
                sessionID: "session-close-\(UUID().uuidString)", backend: .ghosttyEmbedded, title: "shell", workingDirectory: "/tmp/original",
                shell: "/bin/zsh", command: "printf done", createdAt: "2026-05-10T00:00:00Z", workspaceID: "workspace-1", kind: .shell)
            let host = GhosttyEmbeddedSessionHost(launchConfiguration: launchConfiguration, paths: paths)
            host.debugPersistRuntimeState()
            FileManager.default.createFile(atPath: paths.controlSocketPath, contents: Data())

            host.debugHandleSessionClosed()
            // terminate() enqueues the exited-state write off the engine and no longer blocks on its commit
            // (finding B3); block on the persistence queue before reading the durable mirror.
            host.debugDrainPersistenceQueue()

            let runtimeState = try TerminalSessionPersistence.readRuntimeState(paths: paths)
            XCTAssertEqual(runtimeState.state, .exited)
            XCTAssertNotNil(runtimeState.exitedAt)
            XCTAssertFalse(FileManager.default.fileExists(atPath: paths.controlSocketPath))

        }
    }

    func testSessionClosePersistsFinalRenderBeforeRendererTeardown() async throws {
        let availability = GhosttyEmbeddedLocator.resolve(currentDirectoryPath: FileManager.default.currentDirectoryPath)
        guard case .available = availability else { throw XCTSkip("Ghostty runtime resources are unavailable for embedded renderer testing.") }

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = TerminalSessionPaths(rootDirectory: root.path)
        try paths.ensureDirectories()
        let launchConfiguration = TerminalSessionLaunchConfiguration(
            sessionID: "session-final-render-\(UUID().uuidString)", backend: .ghosttyEmbedded, title: "final-render",
            workingDirectory: FileManager.default.temporaryDirectory.path, shell: "/bin/sh", command: "printf final-frame",
            createdAt: "2026-06-04T00:00:00Z", workspaceID: "workspace-1", kind: .shell)

        let hostBox = try await TerminalEngineActor.run { () -> Box<GhosttyEmbeddedSessionHost> in
            let host = GhosttyEmbeddedSessionHost(launchConfiguration: launchConfiguration, paths: paths)
            let owner = TerminalClient(
                id: "local-window", kind: .localWindow, identity: .init(label: "Spaces window"), connectedAt: "2026-06-04T00:00:00Z")
            try host.attach(client: owner, mode: .owner, into: nil)
            return Box(host)
        }
        let host = hostBox.value
        defer { TerminalEngineActor.runSynchronously { host.terminate() } }

        try await waitUntil(timeout: 5) {
            (try? TerminalSessionPersistence.readRemoteSessionState(paths: paths))?.reason == TerminalRemoteSessionStateReason.terminated
        }
        let finalPayload = try TerminalSessionPersistence.readRemoteSessionState(paths: paths)
        let runtimeState = try TerminalSessionPersistence.readRuntimeState(paths: paths)
        XCTAssertEqual(runtimeState.state, .exited)
        XCTAssertEqual(finalPayload.reason, TerminalRemoteSessionStateReason.terminated)
        XCTAssertTrue(finalPayload.renderText?.contains("final-frame") == true)
        // Finding 12 regression: terminate() detaches every client and must invalidate the cached
        // attachment snapshot, so the final persisted payload cannot advertise a still-active attachment
        // (owner) after all clients detached. Without the invalidation this served the stale pre-detach cache.
        let activeAttachments = finalPayload.attachmentSnapshot?.attachments.filter { $0.detachedAt == nil } ?? []
        XCTAssertTrue(activeAttachments.isEmpty, "terminated payload advertised active attachments after detach: \(activeAttachments)")
    }

    func testHeadlessDriverKeepsHostManagedSessionRunningWithoutWindowSurface() async throws {
        let availability = GhosttyEmbeddedLocator.resolve(currentDirectoryPath: FileManager.default.currentDirectoryPath)
        guard case .available = availability else { throw XCTSkip("Ghostty runtime resources are unavailable for embedded renderer testing.") }

        let transcript = TranscriptBuffer()
        let driverBox = try await TerminalEngineActor.run { () -> Box<GhosttyEmbeddedTerminalSessionDriver> in
            let sessionDriver = GhosttyEmbeddedTerminalSessionDriver(
                launchConfiguration: TerminalSessionLaunchConfiguration(
                    sessionID: "host-managed-\(UUID().uuidString)", backend: .ghosttyEmbedded, title: "host-managed",
                    workingDirectory: FileManager.default.temporaryDirectory.path, shell: "/bin/sh", command: "cat", createdAt: "2026-05-17T00:00:00Z",
                    workspaceID: "workspace-1", kind: .shell))
            sessionDriver.setOutputHandler { data in transcript.append(data) }
            try sessionDriver.startIfNeeded()
            return Box(sessionDriver)
        }
        let sessionDriver = driverBox.value
        defer { TerminalEngineActor.runSynchronously { sessionDriver.terminate() } }
        let originalPID = try XCTUnwrap(TerminalEngineActor.runSynchronously { sessionDriver.foregroundPID() })

        try await TerminalEngineActor.run { sessionDriver.sendRawBytes(Data("host managed one\n".utf8)) }
        try await waitUntil { transcript.string().contains("host managed one") }
        try await waitUntil {
            guard let snapshot = sessionDriver.snapshot() else { return false }
            return GhosttyTerminalSnapshotGrid.fullPlainText(for: snapshot).contains("host managed one")
        }
        XCTAssertEqual(try XCTUnwrap(TerminalEngineActor.runSynchronously { sessionDriver.foregroundPID() }), originalPID)

        try await TerminalEngineActor.run { sessionDriver.sendRawBytes(Data("host managed two\n".utf8)) }
        try await waitUntil { transcript.string().contains("host managed two") }
        try await waitUntil {
            guard let snapshot = sessionDriver.snapshot() else { return false }
            return GhosttyTerminalSnapshotGrid.fullPlainText(for: snapshot).contains("host managed two")
        }
    }

    func testLocalOwnerControlSendPublishesRenderUpdateWithoutAdditionalInput() async throws {
        let availability = GhosttyEmbeddedLocator.resolve(currentDirectoryPath: FileManager.default.currentDirectoryPath)
        guard case .available = availability else { throw XCTSkip("Ghostty runtime resources are unavailable for embedded renderer testing.") }

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = TerminalSessionPaths(rootDirectory: root.path)
        try paths.ensureDirectories()
        let readyMarker = "local owner render ready"
        let launchConfiguration = TerminalSessionLaunchConfiguration(
            sessionID: "local-owner-render-update-\(UUID().uuidString)", backend: .ghosttyEmbedded, title: "local-render",
            workingDirectory: FileManager.default.temporaryDirectory.path, shell: "/bin/sh", command: "stty -echo; printf '\(readyMarker)\\n'; cat",
            createdAt: "2026-06-09T00:00:00Z", workspaceID: "workspace-1", kind: .shell)
        let owner = TerminalClient(id: "local-owner", kind: .localWindow, identity: .init(label: "Mac"), connectedAt: "2026-06-09T00:00:00Z")

        let hostBox = try await TerminalEngineActor.run { () -> Box<GhosttyEmbeddedSessionHost> in
            let host = GhosttyEmbeddedSessionHost(launchConfiguration: launchConfiguration, paths: paths)
            try host.attach(client: owner, mode: .owner, into: nil)
            return Box(host)
        }
        let host = hostBox.value
        defer { TerminalEngineActor.runSynchronously { host.terminate() } }
        let receivedPayloads = RemoteSessionStatePayloadCollector()
        let client = GhosttyRemoteSessionStateStreamClient(socketPath: paths.subscriptionSocketPath) { payload in receivedPayloads.append(payload) }
        try client.start()
        defer { client.stop() }

        let cursor = RenderUpdateCursorBox()
        try await waitUntil(timeout: 5) { cursor.applyingUpdates(receivedPayloads.snapshot).contains(readyMarker) }

        let marker = "local owner render marker"
        XCTAssertTrue(TerminalEngineActor.runSynchronously { host.handleControlRequest(.init(command: "send", text: "\(marker)\n", clientID: owner.id)).ok })

        try await waitUntil(timeout: 5) { cursor.applyingUpdates(receivedPayloads.snapshot).contains(marker) }
    }

    func testHeadlessDriverClearScreenActionClearsVisibleOutput() async throws {
        let availability = GhosttyEmbeddedLocator.resolve(currentDirectoryPath: FileManager.default.currentDirectoryPath)
        guard case .available = availability else { throw XCTSkip("Ghostty runtime resources are unavailable for embedded renderer testing.") }

        let readyMarker = "host managed clear ready"
        let transcript = TranscriptBuffer()
        let driverBox = try await TerminalEngineActor.run { () -> Box<GhosttyEmbeddedTerminalSessionDriver> in
            let sessionDriver = GhosttyEmbeddedTerminalSessionDriver(
                launchConfiguration: TerminalSessionLaunchConfiguration(
                    sessionID: "host-managed-clear-\(UUID().uuidString)", backend: .ghosttyEmbedded, title: "host-managed-clear",
                    workingDirectory: FileManager.default.temporaryDirectory.path, shell: "/bin/sh",
                    command: "stty -echo; printf '\(readyMarker)\\n'; cat", createdAt: "2026-06-03T00:00:00Z", workspaceID: "workspace-1", kind: .shell))
            sessionDriver.setOutputHandler { data in transcript.append(data) }
            try sessionDriver.startIfNeeded()
            return Box(sessionDriver)
        }
        let sessionDriver = driverBox.value
        defer { TerminalEngineActor.runSynchronously { sessionDriver.terminate() } }

        try await waitUntil { transcript.string().contains(readyMarker) }
        let marker = "host managed clear marker"
        TerminalEngineActor.runSynchronously { sessionDriver.sendRawBytes(Data("\(marker)\n".utf8)) }
        try await waitUntil { transcript.string().contains(marker) }
        try await waitUntil {
            guard let snapshot = sessionDriver.snapshot() else { return false }
            return GhosttyTerminalSnapshotGrid.fullPlainText(for: snapshot).contains(marker)
        }

        XCTAssertTrue(TerminalEngineActor.runSynchronously { sessionDriver.clearScreenAndScrollback() })
        try await waitUntil {
            guard let snapshot = sessionDriver.snapshot() else { return false }
            return !GhosttyTerminalSnapshotGrid.fullPlainText(for: snapshot).contains(marker)
        }
    }

    func testHeadlessDriverExportsHostManagedSnapshotAfterOutputAndResize() async throws {
        let availability = GhosttyEmbeddedLocator.resolve(currentDirectoryPath: FileManager.default.currentDirectoryPath)
        guard case .available = availability else { throw XCTSkip("Ghostty runtime resources are unavailable for embedded renderer testing.") }

        let transcript = TranscriptBuffer()
        let driverBox = try await TerminalEngineActor.run { () -> Box<GhosttyEmbeddedTerminalSessionDriver> in
            let sessionDriver = GhosttyEmbeddedTerminalSessionDriver(
                launchConfiguration: TerminalSessionLaunchConfiguration(
                    sessionID: "host-managed-resize-\(UUID().uuidString)", backend: .ghosttyEmbedded, title: "owner",
                    workingDirectory: FileManager.default.temporaryDirectory.path, shell: "/bin/sh", command: "cat", createdAt: "2026-05-19T00:00:00Z",
                    workspaceID: "workspace-1", kind: .shell))
            sessionDriver.setOutputHandler { data in transcript.append(data) }
            try sessionDriver.startIfNeeded()
            return Box(sessionDriver)
        }
        let sessionDriver = driverBox.value
        defer { TerminalEngineActor.runSynchronously { sessionDriver.terminate() } }
        let childPID = try await waitForForegroundPID(in: sessionDriver)
        try await TerminalEngineActor.run {
            XCTAssertTrue(sessionDriver.resizeCellGrid(columns: 100, rows: 30))
            XCTAssertEqual(sessionDriver.surfaceCellSize()?.columns, 100)
            XCTAssertEqual(sessionDriver.surfaceCellSize()?.rows, 30)
            sessionDriver.sendRawBytes(Data("host managed resized\n".utf8))
        }
        try await waitUntil { transcript.string().contains("host managed resized") }
        TerminalEngineActor.runSynchronously { sessionDriver.requestSurfaceRefresh() }
        try await waitUntil {
            guard let snapshot = sessionDriver.snapshot() else { return false }
            return snapshot.columns == 100 && snapshot.rows == 30
                && GhosttyTerminalSnapshotGrid.fullPlainText(for: snapshot).contains("host managed resized")
        }
        XCTAssertEqual(try XCTUnwrap(TerminalEngineActor.runSynchronously { sessionDriver.foregroundPID() }), childPID)
    }

    func testHeadlessDriverExportsNativeScrollRectAfterAppendedOutputScrolls() async throws {
        let availability = GhosttyEmbeddedLocator.resolve(currentDirectoryPath: FileManager.default.currentDirectoryPath)
        guard case .available = availability else { throw XCTSkip("Ghostty runtime resources are unavailable for embedded renderer testing.") }

        let transcript = TranscriptBuffer()
        let driverBox = try await TerminalEngineActor.run { () -> Box<GhosttyEmbeddedTerminalSessionDriver> in
            let sessionDriver = GhosttyEmbeddedTerminalSessionDriver(
                launchConfiguration: TerminalSessionLaunchConfiguration(
                    sessionID: "host-managed-scrollrect-\(UUID().uuidString)", backend: .ghosttyEmbedded, title: "owner",
                    workingDirectory: FileManager.default.temporaryDirectory.path, shell: "/bin/sh",
                    command: "sleep 0.2; printf 'line1\\nline2\\nline3\\nline4\\nline5\\n'; sleep 1", createdAt: "2026-06-03T00:00:00Z",
                    workspaceID: "workspace-1", kind: .shell))
            sessionDriver.setOutputHandler { data in transcript.append(data) }
            try sessionDriver.startIfNeeded()
            XCTAssertTrue(sessionDriver.resizeCellGrid(columns: 20, rows: 4))
            _ = sessionDriver.renderStateSnapshot()
            return Box(sessionDriver)
        }
        let sessionDriver = driverBox.value
        defer { TerminalEngineActor.runSynchronously { sessionDriver.terminate() } }

        try await waitUntil { transcript.string().contains("line5") }
        let captured = try XCTUnwrap(TerminalEngineActor.runSynchronously { sessionDriver.renderStateSnapshot() })
        let scrollRect = try XCTUnwrap(captured.scrollRects.first)

        XCTAssertEqual(scrollRect.rowStart, 0)
        XCTAssertEqual(scrollRect.rowCount, 4)
        XCTAssertEqual(scrollRect.columnStart, 0)
        XCTAssertEqual(scrollRect.columnCount, 20)
        XCTAssertLessThan(scrollRect.deltaRows, 0)
        XCTAssertGreaterThan(scrollRect.deltaRows, -4)
        XCTAssertEqual(scrollRect.deltaColumns, 0)
    }

    func testApplyColorSchemeRethemesLiveHeadlessSessionBackground() async throws {
        let availability = GhosttyEmbeddedLocator.resolve(currentDirectoryPath: FileManager.default.currentDirectoryPath)
        guard case .available = availability else { throw XCTSkip("Ghostty runtime resources are unavailable for embedded renderer testing.") }

        let lightBackground = ActiveTheme.descriptor.terminal(for: .light).background.packedRGB
        let darkBackground = ActiveTheme.descriptor.terminal(for: .dark).background.packedRGB
        XCTAssertNotEqual(lightBackground, darkBackground, "Light and dark theme backgrounds must differ for this test to be meaningful.")

        let driverBox = try await TerminalEngineActor.run { () -> Box<GhosttyEmbeddedTerminalSessionDriver> in
            let sessionDriver = GhosttyEmbeddedTerminalSessionDriver(
                launchConfiguration: TerminalSessionLaunchConfiguration(
                    sessionID: "color-scheme-retheme-\(UUID().uuidString)", backend: .ghosttyEmbedded, title: "owner",
                    workingDirectory: FileManager.default.temporaryDirectory.path, shell: "/bin/sh", command: "sleep 5",
                    createdAt: "2026-07-07T00:00:00Z", workspaceID: "workspace-1", kind: .shell))
            try sessionDriver.startIfNeeded()
            XCTAssertTrue(sessionDriver.resizeCellGrid(columns: 20, rows: 4))
            return Box(sessionDriver)
        }
        let sessionDriver = driverBox.value
        defer { TerminalEngineActor.runSynchronously { sessionDriver.terminate() } }
        try await waitUntil { sessionDriver.renderStateSnapshot() != nil }

        // In the test process NSApp resolves to light, so the session starts on the light variant.
        let initial = try XCTUnwrap(TerminalEngineActor.runSynchronously { sessionDriver.renderStateSnapshot() })
        XCTAssertEqual(initial.snapshot.defaultBackgroundRGB, lightBackground)

        // Flip to dark: colors reach the surface on the io thread, so pump ticks while polling.
        TerminalEngineActor.runSynchronously { GhosttyEmbeddedAppService.shared.applyColorScheme(.dark) }
        try await waitUntil(timeout: 5) {
            sessionDriver.requestSurfaceRefresh()
            GhosttyEmbeddedAppService.shared.tick()
            return sessionDriver.renderStateSnapshot()?.snapshot.defaultBackgroundRGB == darkBackground
        }

        // Flip back to light and confirm the background returns.
        TerminalEngineActor.runSynchronously { GhosttyEmbeddedAppService.shared.applyColorScheme(.light) }
        try await waitUntil(timeout: 5) {
            sessionDriver.requestSurfaceRefresh()
            GhosttyEmbeddedAppService.shared.tick()
            return sessionDriver.renderStateSnapshot()?.snapshot.defaultBackgroundRGB == lightBackground
        }
    }

    func testControlAttachAppliesRequestedAppearanceToLiveSession() async throws {
        let availability = GhosttyEmbeddedLocator.resolve(currentDirectoryPath: FileManager.default.currentDirectoryPath)
        guard case .available = availability else { throw XCTSkip("Ghostty runtime resources are unavailable for embedded renderer testing.") }

        let lightBackground = ActiveTheme.descriptor.terminal(for: .light).background.packedRGB
        let darkBackground = ActiveTheme.descriptor.terminal(for: .dark).background.packedRGB
        XCTAssertNotEqual(lightBackground, darkBackground, "Light and dark theme backgrounds must differ for this test to be meaningful.")

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = TerminalSessionPaths(rootDirectory: root.path)

        let boxes = try await TerminalEngineActor.run { () -> (Box<GhosttyEmbeddedSessionHost>, Box<GhosttyHeadlessRendererHost>) in
            let host = GhosttyEmbeddedSessionHost(
                launchConfiguration: TerminalSessionLaunchConfiguration(
                    sessionID: "control-attach-appearance-\(UUID().uuidString)", backend: .ghosttyEmbedded, title: "owner",
                    workingDirectory: FileManager.default.temporaryDirectory.path, shell: "/bin/sh", command: "sleep 5",
                    createdAt: "2026-07-07T00:00:00Z", workspaceID: "workspace-1", kind: .shell), paths: paths)
            try host.startIfNeeded()
            // The app service is a process-wide singleton whose config references the theme files of
            // whichever test started it first; that test's teardown deletes them, so re-anchor the config
            // to this test's live profile before relying on ghostty_app_update_config re-reading them.
            try GhosttyEmbeddedAppService.shared.reloadThemeConfigurationForTesting()
            let rendererHost = try XCTUnwrap(host.rendererHost as? GhosttyHeadlessRendererHost)
            XCTAssertTrue(rendererHost.resizeCellGrid(columns: 20, rows: 4))
            return (Box(host), Box(rendererHost))
        }
        let host = boxes.0.value
        let rendererHost = boxes.1.value
        defer { TerminalEngineActor.runSynchronously { host.terminate() } }
        try await waitUntil { rendererHost.sessionRenderStateSnapshot() != nil }

        // The color scheme is a process-wide singleton; force light so this test starts from a known
        // baseline regardless of the order tests run in, then confirm the surface reaches it.
        TerminalEngineActor.runSynchronously { GhosttyEmbeddedAppService.shared.applyColorScheme(.light) }
        try await waitUntil(timeout: 5) {
            rendererHost.requestSurfaceRefresh()
            GhosttyEmbeddedAppService.shared.tick()
            return rendererHost.sessionRenderStateSnapshot()?.snapshot.defaultBackgroundRGB == lightBackground
        }

        // Attaching with a dark appearance must re-theme the live session even though the client only
        // conveys light/dark; colors reach the surface on the io thread, so pump ticks while polling.
        let client = TerminalClient(
            id: "remote-owner", kind: .remoteViewer, identity: TerminalClientIdentity(label: "iPhone", deviceName: "iPhone"),
            connectedAt: "2026-07-07T00:00:00Z")
        let response = TerminalEngineActor.runSynchronously {
            host.core.handleControlRequest(
                TerminalControlRequest(command: .attach(TerminalControlAttachPayload(client: client, attachmentMode: .owner, appearance: .dark))))
        }
        XCTAssertTrue(response.ok, response.message)

        try await waitUntil(timeout: 5) {
            rendererHost.requestSurfaceRefresh()
            GhosttyEmbeddedAppService.shared.tick()
            return rendererHost.sessionRenderStateSnapshot()?.snapshot.defaultBackgroundRGB == darkBackground
        }

        // Reset the shared app-service scheme so dark does not leak into later tests.
        TerminalEngineActor.runSynchronously { GhosttyEmbeddedAppService.shared.applyColorScheme(.light) }
    }

    func testControlSetAppearanceRethemesLiveSessionForViewerClient() async throws {
        let availability = GhosttyEmbeddedLocator.resolve(currentDirectoryPath: FileManager.default.currentDirectoryPath)
        guard case .available = availability else { throw XCTSkip("Ghostty runtime resources are unavailable for embedded renderer testing.") }

        let lightBackground = ActiveTheme.descriptor.terminal(for: .light).background.packedRGB
        let darkBackground = ActiveTheme.descriptor.terminal(for: .dark).background.packedRGB
        XCTAssertNotEqual(lightBackground, darkBackground, "Light and dark theme backgrounds must differ for this test to be meaningful.")

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = TerminalSessionPaths(rootDirectory: root.path)

        let boxes = try await TerminalEngineActor.run { () -> (Box<GhosttyEmbeddedSessionHost>, Box<GhosttyHeadlessRendererHost>) in
            let host = GhosttyEmbeddedSessionHost(
                launchConfiguration: TerminalSessionLaunchConfiguration(
                    sessionID: "control-set-appearance-\(UUID().uuidString)", backend: .ghosttyEmbedded, title: "owner",
                    workingDirectory: FileManager.default.temporaryDirectory.path, shell: "/bin/sh", command: "sleep 5",
                    createdAt: "2026-07-07T00:00:00Z", workspaceID: "workspace-1", kind: .shell), paths: paths)
            try host.startIfNeeded()
            // The app service is a process-wide singleton whose config references the theme files of
            // whichever test started it first; re-anchor the config to this test's live profile before
            // relying on ghostty_app_update_config re-reading them.
            try GhosttyEmbeddedAppService.shared.reloadThemeConfigurationForTesting()
            let rendererHost = try XCTUnwrap(host.rendererHost as? GhosttyHeadlessRendererHost)
            XCTAssertTrue(rendererHost.resizeCellGrid(columns: 20, rows: 4))
            return (Box(host), Box(rendererHost))
        }
        let host = boxes.0.value
        let rendererHost = boxes.1.value
        defer { TerminalEngineActor.runSynchronously { host.terminate() } }
        try await waitUntil { rendererHost.sessionRenderStateSnapshot() != nil }

        // Force light so this test starts from a known baseline regardless of the order tests run in.
        TerminalEngineActor.runSynchronously { GhosttyEmbeddedAppService.shared.applyColorScheme(.light) }
        try await waitUntil(timeout: 5) {
            rendererHost.requestSurfaceRefresh()
            GhosttyEmbeddedAppService.shared.tick()
            return rendererHost.sessionRenderStateSnapshot()?.snapshot.defaultBackgroundRGB == lightBackground
        }

        // A viewer that never took ownership can still flip the appearance: setAppearance is a
        // per-client view preference with last-writer-wins semantics, not an owner-gated mutation.
        let response = TerminalEngineActor.runSynchronously {
            host.core.handleControlRequest(
                TerminalControlRequest(
                    command: .setAppearance(TerminalControlSetAppearancePayload(clientID: "viewer-without-ownership", appearance: .dark))))
        }
        XCTAssertTrue(response.ok, response.message)

        // Colors reach the surface on the io thread, so pump ticks while polling.
        try await waitUntil(timeout: 5) {
            rendererHost.requestSurfaceRefresh()
            GhosttyEmbeddedAppService.shared.tick()
            return rendererHost.sessionRenderStateSnapshot()?.snapshot.defaultBackgroundRGB == darkBackground
        }

        // Reset the shared app-service scheme so dark does not leak into later tests.
        TerminalEngineActor.runSynchronously { GhosttyEmbeddedAppService.shared.applyColorScheme(.light) }
    }

    func testHeadlessDriverExportsNativeScrollRectAfterViewportScrollback() async throws {
        let availability = GhosttyEmbeddedLocator.resolve(currentDirectoryPath: FileManager.default.currentDirectoryPath)
        guard case .available = availability else { throw XCTSkip("Ghostty runtime resources are unavailable for embedded renderer testing.") }

        let transcript = TranscriptBuffer()
        let driverBox = try await TerminalEngineActor.run { () -> Box<GhosttyEmbeddedTerminalSessionDriver> in
            let sessionDriver = GhosttyEmbeddedTerminalSessionDriver(
                launchConfiguration: TerminalSessionLaunchConfiguration(
                    sessionID: "host-managed-scrollback-scrollrect-\(UUID().uuidString)", backend: .ghosttyEmbedded, title: "owner",
                    workingDirectory: FileManager.default.temporaryDirectory.path, shell: "/bin/sh",
                    command: "sleep 0.2; for i in 1 2 3 4 5 6 7 8; do printf \"line$i\\n\"; done; sleep 1", createdAt: "2026-06-03T00:00:00Z",
                    workspaceID: "workspace-1", kind: .shell))
            sessionDriver.setOutputHandler { data in transcript.append(data) }
            try sessionDriver.startIfNeeded()
            XCTAssertTrue(sessionDriver.resizeCellGrid(columns: 20, rows: 4))
            return Box(sessionDriver)
        }
        let sessionDriver = driverBox.value
        defer { TerminalEngineActor.runSynchronously { sessionDriver.terminate() } }

        try await waitUntil { transcript.string().contains("line8") }

        let captured = try await TerminalEngineActor.run { () -> GhosttyTerminalSnapshotCapture.CapturedSnapshot in
            _ = sessionDriver.renderStateSnapshot()
            XCTAssertTrue(sessionDriver.sendScroll(horizontal: 0, vertical: 1))
            return try XCTUnwrap(sessionDriver.renderStateSnapshot())
        }
        let scrollRect = try XCTUnwrap(captured.scrollRects.first)

        XCTAssertEqual(scrollRect.rowStart, 0)
        XCTAssertEqual(scrollRect.rowCount, 4)
        XCTAssertEqual(scrollRect.columnStart, 0)
        XCTAssertEqual(scrollRect.columnCount, 20)
        XCTAssertGreaterThan(scrollRect.deltaRows, 0)
        XCTAssertLessThan(scrollRect.deltaRows, 4)
        XCTAssertEqual(scrollRect.deltaColumns, 0)
    }

    func testHeadlessDriverExportsHostManagedSynchronizedOutput() async throws {
        let availability = GhosttyEmbeddedLocator.resolve(currentDirectoryPath: FileManager.default.currentDirectoryPath)
        guard case .available = availability else { throw XCTSkip("Ghostty runtime resources are unavailable for embedded renderer testing.") }

        let transcript = TranscriptBuffer()
        let driverBox = try await TerminalEngineActor.run { () -> Box<GhosttyEmbeddedTerminalSessionDriver> in
            let sessionDriver = GhosttyEmbeddedTerminalSessionDriver(
                launchConfiguration: TerminalSessionLaunchConfiguration(
                    sessionID: "host-managed-sync-\(UUID().uuidString)", backend: .ghosttyEmbedded, title: "owner",
                    workingDirectory: FileManager.default.temporaryDirectory.path, shell: "/bin/sh", command: "cat", createdAt: "2026-05-19T00:00:00Z",
                    workspaceID: "workspace-1", kind: .shell))
            sessionDriver.setOutputHandler { data in transcript.append(data) }
            try sessionDriver.startIfNeeded()
            return Box(sessionDriver)
        }
        let sessionDriver = driverBox.value
        defer { TerminalEngineActor.runSynchronously { sessionDriver.terminate() } }

        let marker = "OpenAI Codex synchronized marker"
        let output = "\u{1B}[?2026h\u{1B}[3;1H\u{1B}[J\u{1B}[4;1H\(marker)\u{1B}[?2026l"
        TerminalEngineActor.runSynchronously { sessionDriver.sendRawBytes(Data(output.utf8)) }
        try await waitUntil { transcript.string().contains(marker) }
        TerminalEngineActor.runSynchronously { sessionDriver.requestSurfaceRefresh() }
        try await waitUntil {
            guard let snapshot = sessionDriver.snapshot() else { return false }
            return GhosttyTerminalSnapshotGrid.fullPlainText(for: snapshot).contains(marker)
        }
    }

    func testHeadlessDriverExportsCodexStyleHostManagedFrame() async throws {
        let availability = GhosttyEmbeddedLocator.resolve(currentDirectoryPath: FileManager.default.currentDirectoryPath)
        guard case .available = availability else { throw XCTSkip("Ghostty runtime resources are unavailable for embedded renderer testing.") }

        let transcript = TranscriptBuffer()
        let driverBox = try await TerminalEngineActor.run { () -> Box<GhosttyEmbeddedTerminalSessionDriver> in
            let sessionDriver = GhosttyEmbeddedTerminalSessionDriver(
                launchConfiguration: TerminalSessionLaunchConfiguration(
                    sessionID: "host-managed-codex-\(UUID().uuidString)", backend: .ghosttyEmbedded, title: "owner",
                    workingDirectory: FileManager.default.temporaryDirectory.path, shell: "/bin/sh", command: "cat", createdAt: "2026-05-19T00:00:00Z",
                    workspaceID: "workspace-1", kind: .shell))
            sessionDriver.setOutputHandler { data in transcript.append(data) }
            try sessionDriver.startIfNeeded()
            return Box(sessionDriver)
        }
        let sessionDriver = driverBox.value
        defer { TerminalEngineActor.runSynchronously { sessionDriver.terminate() } }

        let marker = "OpenAI Codex"
        let output =
            "\u{1B}[?2004h\u{1B}[>4;0m\u{1B}[>7u\u{1B}[?1004h\u{1B}[6n\u{1B}]10;?\u{1B}\\\u{1B}]11;?\u{1B}\\\u{1B}[?u\u{1B}[c\u{1B}]0;project\u{7}"
            + "\u{1B}[?2026h\u{1B}[3;1H\u{1B}[J" + "\u{1B}[4;1H\u{1B}[2m\u{1B}[39;49m╭─────────────────────────────────────────────────────────╮"
            + "\u{1B}[5;1H│ >_ \u{1B}[22m\u{1B}[1m\(marker)\u{1B}[22m\u{1B}[2m (v0.135.0)                              │"
            + "\u{1B}[6;1H│                                                         │"
            + "\u{1B}[7;1H│ model:     \u{1B}[22mgpt-5.5 xhigh\u{1B}[2m   \u{1B}[22m\u{1B}[38;5;6;49m/model\u{1B}[2m\u{1B}[39;49m to change             │"
            + "\u{1B}[8;1H│ directory: \u{1B}[22m/private/…/spaces-mobile-demo/project\u{1B}[2m             │"
            + "\u{1B}[9;1H╰─────────────────────────────────────────────────────────╯"
            + "\u{1B}[11;1H  \u{1B}[1mTip:\u{1B}[22m Try the \u{1B}[1mCodex App\u{1B}[22m."
            + "\u{1B}[12;1H\u{1B}[1m›\u{1B}[22m \u{1B}[2mExplain this codebase" + "\u{1B}[13;1H  gpt-5.5 xhigh · /private/var/folders/project · main"
            + "\u{1B}[0m\u{1B}[0 q\u{1B}[?25h\u{1B}[12;3H\u{1B}[?2026l"
        TerminalEngineActor.runSynchronously { sessionDriver.sendRawBytes(Data(output.utf8)) }
        try await waitUntil { transcript.string().contains(marker) }
        try await TerminalEngineActor.run {
            XCTAssertTrue(sessionDriver.resizeCellGrid(columns: 119, rows: 41))
            sessionDriver.requestSurfaceRefresh()
        }
        try await waitUntil {
            guard let snapshot = sessionDriver.snapshot() else { return false }
            let text = GhosttyTerminalSnapshotGrid.fullPlainText(for: snapshot)
            return text.contains(marker) && text.contains("Explain this codebase")
        }
    }

    func testHostSnapshotUsesRenderableSurfaceForLiveOwnerState() async throws {
        let availability = GhosttyEmbeddedLocator.resolve(currentDirectoryPath: FileManager.default.currentDirectoryPath)
        guard case .available = availability else { throw XCTSkip("Ghostty runtime resources are unavailable for embedded renderer testing.") }

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = TerminalSessionPaths(rootDirectory: root.path)
        try paths.ensureDirectories()
        let launchConfiguration = TerminalSessionLaunchConfiguration(
            sessionID: "host-snapshot-\(UUID().uuidString)", backend: .ghosttyEmbedded, title: "owner",
            workingDirectory: FileManager.default.temporaryDirectory.path, shell: "/bin/sh", command: "cat", createdAt: "2026-05-21T00:00:00Z",
            workspaceID: "workspace-1", kind: .shell)

        // The daemon host's attach() ignores the container view entirely (window/view affinity
        // is an app-side concern); the renderer surface comes up headless.
        let hostBox = try await TerminalEngineActor.run { () -> Box<GhosttyEmbeddedSessionHost> in
            let host = GhosttyEmbeddedSessionHost(launchConfiguration: launchConfiguration, paths: paths)
            let ownerClient = TerminalClient(
                id: "owner-client", kind: .localWindow, identity: .init(label: "Spaces window"), connectedAt: "2026-05-21T00:00:00Z")
            try host.attach(client: ownerClient, mode: .owner, into: nil)
            return Box(host)
        }
        let host = hostBox.value
        defer { TerminalEngineActor.runSynchronously { host.terminate() } }
        try await waitUntil { host.rendererHost.hasRenderableSurface() }

        try await waitUntil {
            host.core.rendererHost.requestSurfaceRefresh()
            return host.snapshot() != nil
        }
    }

    func testHeadlessDriverScrollRequestsHostManagedSnapshotRefresh() async throws {
        try await TerminalEngineActor.run {
            let availability = GhosttyEmbeddedLocator.resolve(currentDirectoryPath: FileManager.default.currentDirectoryPath)
            guard case .available = availability else { throw XCTSkip("Ghostty runtime resources are unavailable for embedded renderer testing.") }

            let sessionDriver = GhosttyEmbeddedTerminalSessionDriver(
                launchConfiguration: TerminalSessionLaunchConfiguration(
                    sessionID: "host-managed-scroll-\(UUID().uuidString)", backend: .ghosttyEmbedded, title: "scroll",
                    workingDirectory: FileManager.default.temporaryDirectory.path, shell: "/bin/sh", command: "cat", createdAt: "2026-05-18T00:00:00Z",
                    workspaceID: "workspace-1", kind: .shell))
            defer { sessionDriver.terminate() }

            try sessionDriver.startIfNeeded()
            let baselineRefreshCount = sessionDriver.debugRefreshRequestCount

            XCTAssertTrue(sessionDriver.sendScroll(horizontal: 0, vertical: -48))
            XCTAssertEqual(sessionDriver.debugLastScrollMods, 0)

            XCTAssertGreaterThanOrEqual(
                sessionDriver.debugRefreshRequestCount, baselineRefreshCount + 1,
                "Scroll movement should schedule redraws so Ghostty can update the exported viewport.")

        }
    }

    func testHeadlessDriverForwardsPreciseScrollMods() async throws {
        try await TerminalEngineActor.run {
            let availability = GhosttyEmbeddedLocator.resolve(currentDirectoryPath: FileManager.default.currentDirectoryPath)
            guard case .available = availability else { throw XCTSkip("Ghostty runtime resources are unavailable for embedded renderer testing.") }

            let sessionDriver = GhosttyEmbeddedTerminalSessionDriver(
                launchConfiguration: TerminalSessionLaunchConfiguration(
                    sessionID: "host-managed-scroll-mods-\(UUID().uuidString)", backend: .ghosttyEmbedded, title: "scroll",
                    workingDirectory: FileManager.default.temporaryDirectory.path, shell: "/bin/sh", command: "cat", createdAt: "2026-05-18T00:00:00Z",
                    workspaceID: "workspace-1", kind: .shell))
            defer { sessionDriver.terminate() }

            try sessionDriver.startIfNeeded()

            XCTAssertTrue(sessionDriver.sendScroll(horizontal: 0, vertical: -48, scrollMods: 0b0000_0111))
            XCTAssertEqual(sessionDriver.debugLastScrollMods, 0b0000_0111)

        }
    }

    func testHeadlessDriverSendsScrollToMouseReportingApplicationAtPointerPosition() async throws {
        let availability = GhosttyEmbeddedLocator.resolve(currentDirectoryPath: FileManager.default.currentDirectoryPath)
        guard case .available = availability else { throw XCTSkip("Ghostty runtime resources are unavailable for embedded renderer testing.") }

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let scriptURL = root.appendingPathComponent("mouse_probe.py")
        let outputURL = root.appendingPathComponent("mouse_input.bin")
        try """
        import os
        import sys
        import termios
        import tty

        fd = sys.stdin.fileno()
        previous = termios.tcgetattr(fd)
        try:
            tty.setraw(fd)
            os.write(sys.stdout.fileno(), b"\\x1b[?1000h\\x1b[?1006hREADY\\r\\n")
            data = os.read(fd, 128)
            with open(sys.argv[1], "wb") as output:
                output.write(data)
        finally:
            termios.tcsetattr(fd, termios.TCSADRAIN, previous)
        """.write(to: scriptURL, atomically: true, encoding: .utf8)

        func shellQuoted(_ value: String) -> String { "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'" }
        let driverBox = try await TerminalEngineActor.run { () -> Box<GhosttyEmbeddedTerminalSessionDriver> in
            let sessionDriver = GhosttyEmbeddedTerminalSessionDriver(
                launchConfiguration: TerminalSessionLaunchConfiguration(
                    sessionID: "host-managed-mouse-scroll-\(UUID().uuidString)", backend: .ghosttyEmbedded, title: "mouse-scroll",
                    workingDirectory: root.path, shell: "/bin/zsh",
                    command: "/usr/bin/python3 \(shellQuoted(scriptURL.path)) \(shellQuoted(outputURL.path))", createdAt: "2026-07-16T00:00:00Z",
                    workspaceID: "workspace-1", kind: .shell))
            try sessionDriver.startIfNeeded()
            return Box(sessionDriver)
        }
        let sessionDriver = driverBox.value
        defer { TerminalEngineActor.runSynchronously { sessionDriver.terminate() } }

        try await waitUntil { sessionDriver.snapshotText()?.contains("READY") == true }
        let size = try XCTUnwrap(TerminalEngineActor.runSynchronously { sessionDriver.surfaceCellSize() })
        XCTAssertTrue(
            TerminalEngineActor.runSynchronously {
                sessionDriver.sendScroll(
                    horizontal: 0, vertical: 48, scrollMods: TerminalScrollModifiers.precisionMask, pointerPosition: .init(x: 0.5, y: 0.5))
            })
        try await waitUntil { FileManager.default.fileExists(atPath: outputURL.path) }

        let input = String(decoding: try Data(contentsOf: outputURL), as: UTF8.self)
        let expression = try NSRegularExpression(pattern: #"\u001B\[<(64|65);([0-9]+);([0-9]+)M"#)
        let range = NSRange(input.startIndex..<input.endIndex, in: input)
        let match = try XCTUnwrap(expression.firstMatch(in: input, range: range))
        let column = Int((input as NSString).substring(with: match.range(at: 2)))
        let row = Int((input as NSString).substring(with: match.range(at: 3)))
        XCTAssertTrue((1...size.columns).contains(try XCTUnwrap(column)))
        XCTAssertTrue((1...size.rows).contains(try XCTUnwrap(row)))
    }

    func testHeadlessDriverRefreshesMouseModifiersAtStationaryPointerBeforeScroll() async throws {
        let availability = GhosttyEmbeddedLocator.resolve(currentDirectoryPath: FileManager.default.currentDirectoryPath)
        guard case .available = availability else { throw XCTSkip("Ghostty runtime resources are unavailable for embedded renderer testing.") }

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let scriptURL = root.appendingPathComponent("mouse_modifier_probe.py")
        let outputURL = root.appendingPathComponent("mouse_input.bin")
        try """
        import os
        import select
        import sys
        import termios
        import tty

        def read_scroll_burst(fd):
            data = b""
            while True:
                ready, _, _ = select.select([fd], [], [], 1 if not data else 0.05)
                if not ready:
                    return data
                data += os.read(fd, 128)

        fd = sys.stdin.fileno()
        previous = termios.tcgetattr(fd)
        try:
            tty.setraw(fd)
            os.write(sys.stdout.fileno(), b"\\x1b[?1000h\\x1b[?1006hREADY\\r\\n")
            first = read_scroll_burst(fd)
            os.write(sys.stdout.fileno(), b"FIRST\\r\\n")
            second = read_scroll_burst(fd)
            with open(sys.argv[1], "wb") as output:
                output.write(first + b"\\n" + second)
        finally:
            termios.tcsetattr(fd, termios.TCSADRAIN, previous)
        """.write(to: scriptURL, atomically: true, encoding: .utf8)

        func shellQuoted(_ value: String) -> String { "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'" }
        let driverBox = try await TerminalEngineActor.run { () -> Box<GhosttyEmbeddedTerminalSessionDriver> in
            let sessionDriver = GhosttyEmbeddedTerminalSessionDriver(
                launchConfiguration: TerminalSessionLaunchConfiguration(
                    sessionID: "host-managed-mouse-mods-\(UUID().uuidString)", backend: .ghosttyEmbedded, title: "mouse-mods",
                    workingDirectory: root.path, shell: "/bin/zsh",
                    command: "/usr/bin/python3 \(shellQuoted(scriptURL.path)) \(shellQuoted(outputURL.path))", createdAt: "2026-07-16T00:00:00Z",
                    workspaceID: "workspace-1", kind: .shell))
            try sessionDriver.startIfNeeded()
            return Box(sessionDriver)
        }
        let sessionDriver = driverBox.value
        defer { TerminalEngineActor.runSynchronously { sessionDriver.terminate() } }

        try await waitUntil { sessionDriver.snapshotText()?.contains("READY") == true }
        let pointerPosition = TerminalScrollPointerPosition(x: 0.5, y: 0.5)

        XCTAssertTrue(
            TerminalEngineActor.runSynchronously {
                sessionDriver.sendScroll(horizontal: 0, vertical: 48, scrollMods: TerminalScrollModifiers.precisionMask, pointerPosition: pointerPosition)
            })
        try await waitUntil { sessionDriver.snapshotText()?.contains("FIRST") == true }
        XCTAssertTrue(
            TerminalEngineActor.runSynchronously {
                sessionDriver.sendScroll(
                    horizontal: 0, vertical: 48, scrollMods: TerminalScrollModifiers.precisionMask,
                    pointerPosition: .init(x: pointerPosition.x, y: pointerPosition.y, mods: GHOSTTY_MODS_CTRL.rawValue))
            })
        try await waitUntil { FileManager.default.fileExists(atPath: outputURL.path) }

        let reports = String(decoding: try Data(contentsOf: outputURL), as: UTF8.self).split(separator: "\n")
        XCTAssertEqual(reports.count, 2)
        let expression = try NSRegularExpression(pattern: #"\u001B\[<([0-9]+);[0-9]+;[0-9]+M"#)
        let buttonCodes = try reports.map { report in
            let input = String(report)
            let range = NSRange(input.startIndex..<input.endIndex, in: input)
            let match = try XCTUnwrap(expression.firstMatch(in: input, range: range))
            return try XCTUnwrap(Int((input as NSString).substring(with: match.range(at: 1))))
        }
        XCTAssertEqual(buttonCodes[1], buttonCodes[0] + 16)
    }

    func testControlAttachAndDetachRequestsUpdatePersistenceAndPostAttachmentChanges() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = TerminalSessionPaths(rootDirectory: root.path)
        try paths.ensureDirectories()
        let launchConfiguration = TerminalSessionLaunchConfiguration(
            sessionID: "session-6", backend: .ghosttyEmbedded, title: "shell", workingDirectory: "/tmp/original", shell: "/bin/zsh", command: "zsh",
            createdAt: "2026-05-17T00:00:00Z", workspaceID: "workspace-1", kind: .shell)
        let client = TerminalClient(
            id: "remote-client", kind: .remoteViewer, identity: .init(label: "iPhone", deviceName: "iPhone"), connectedAt: "2026-05-17T00:00:00Z")
        let attachmentNotifications = expectation(description: "attachment notifications")
        attachmentNotifications.expectedFulfillmentCount = 2
        let observer = NotificationCenter.default.addObserver(forName: .spacesTerminalAttachmentStateDidChange, object: nil, queue: .main) {
            notification in
            guard notification.userInfo?["sessionID"] as? String == "session-6" else { return }
            attachmentNotifications.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        try await TerminalEngineActor.run {
            let host = GhosttyEmbeddedSessionHost(launchConfiguration: launchConfiguration, paths: paths)
            try TerminalSessionPersistence.writeLaunchConfiguration(launchConfiguration, paths: paths)

            let attachResponse = host.handleControlRequest(.init(command: "attach", client: client, attachmentMode: .viewer))
            XCTAssertEqual(attachResponse, TerminalControlResponse(ok: true, message: "Attached viewer client."))
            XCTAssertEqual(try TerminalSessionPersistence.activeAttachments(paths: paths).map(\.clientID), [client.id])

            let detachResponse = host.handleControlRequest(.init(command: "detach", clientID: client.id))
            XCTAssertEqual(detachResponse, TerminalControlResponse(ok: true, message: "Detached terminal client."))
            XCTAssertTrue(try TerminalSessionPersistence.activeAttachments(paths: paths).isEmpty)
        }

        await fulfillment(of: [attachmentNotifications], timeout: 2)
    }

    func testDetachingRemoteOwnerTransfersOwnershipBackToActiveLocalWindow() async throws {
        try await TerminalEngineActor.run {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }

            let paths = TerminalSessionPaths(rootDirectory: root.path)
            try paths.ensureDirectories()
            let launchConfiguration = TerminalSessionLaunchConfiguration(
                sessionID: "session-owner-return", backend: .ghosttyEmbedded, title: "shell", workingDirectory: "/tmp/original", shell: "/bin/zsh",
                command: "zsh", createdAt: "2026-05-17T00:00:00Z", workspaceID: "workspace-1", kind: .shell)
            let host = GhosttyEmbeddedSessionHost(launchConfiguration: launchConfiguration, paths: paths)
            try TerminalSessionPersistence.writeLaunchConfiguration(launchConfiguration, paths: paths)
            let localClient = TerminalClient(
                id: "local-window", kind: .localWindow, identity: .init(label: "Spaces window"), connectedAt: "2026-05-17T00:00:00Z")
            let remoteClient = TerminalClient(
                id: "remote-ipad", kind: .remoteViewer, identity: .init(label: "iPad", deviceName: "iPad"), connectedAt: "2026-05-17T00:00:00Z")

            try TerminalSessionPersistence.attachClient(
                sessionID: launchConfiguration.sessionID, client: localClient, mode: .owner, paths: paths, attachedAt: "2026-05-17T00:00:00Z")
            XCTAssertEqual(host.handleControlRequest(.init(command: "attach", client: remoteClient, attachmentMode: .viewer)).ok, true)
            XCTAssertEqual(host.handleControlRequest(.init(command: "takeover", clientID: remoteClient.id)).ok, true)
            XCTAssertEqual(host.activeOwnerClientID(), remoteClient.id)

            let detachResponse = host.handleControlRequest(.init(command: "detach", clientID: remoteClient.id))
            XCTAssertEqual(detachResponse, TerminalControlResponse(ok: true, message: "Detached terminal client."))

            let activeAttachments = try TerminalSessionPersistence.activeAttachments(paths: paths)
            XCTAssertEqual(activeAttachments.first(where: { $0.mode == .owner })?.clientID, localClient.id)
            XCTAssertFalse(activeAttachments.contains { $0.clientID == remoteClient.id })

        }
    }

    func testControlRejectsStaleOwnerEpochRequestsFromActiveOwner() async throws {
        try await TerminalEngineActor.run {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }

            let paths = TerminalSessionPaths(rootDirectory: root.path)
            try paths.ensureDirectories()
            let launchConfiguration = TerminalSessionLaunchConfiguration(
                sessionID: "session-stale-owner-epoch", backend: .ghosttyEmbedded, title: "shell", workingDirectory: "/tmp/original", shell: "/bin/zsh",
                command: "zsh", createdAt: "2026-05-31T00:00:00Z", workspaceID: "workspace-1", kind: .shell)
            let host = GhosttyEmbeddedSessionHost(launchConfiguration: launchConfiguration, paths: paths)
            try TerminalSessionPersistence.writeLaunchConfiguration(launchConfiguration, paths: paths)
            let owner = TerminalClient(
                id: "remote-owner", kind: .remoteViewer, identity: .init(label: "iPhone", deviceName: "iPhone"), connectedAt: "2026-05-31T00:00:00Z")
            try TerminalSessionPersistence.attachClient(
                sessionID: launchConfiguration.sessionID, client: owner, mode: .owner, paths: paths, attachedAt: "2026-05-31T00:00:00Z")

            let response = host.handleControlRequest(.init(command: "send", text: "echo stale", clientID: owner.id, ownerEpoch: 1))

            XCTAssertFalse(response.ok)
            XCTAssertEqual(response.message, "Ignoring stale owner epoch 1; current owner epoch is 0.")

        }
    }

    func testControlScrollAcceptsZeroDeltaLifecyclePackets() async throws {
        try await TerminalEngineActor.run {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }

            let paths = TerminalSessionPaths(rootDirectory: root.path)
            try paths.ensureDirectories()
            let launchConfiguration = TerminalSessionLaunchConfiguration(
                sessionID: "session-zero-scroll-\(UUID().uuidString)", backend: .ghosttyEmbedded, title: "shell", workingDirectory: "/tmp",
                shell: "/bin/zsh", command: nil, createdAt: "2026-06-15T00:00:00Z", workspaceID: "workspace-1", kind: .shell)
            let host = GhosttyEmbeddedSessionHost(launchConfiguration: launchConfiguration, paths: paths)
            defer { host.terminate() }
            try TerminalSessionPersistence.writeLaunchConfiguration(launchConfiguration, paths: paths)
            let owner = TerminalClient(
                id: "remote-owner", kind: .remoteViewer, identity: .init(label: "iPhone", deviceName: "iPhone"), connectedAt: "2026-06-15T00:00:00Z")
            XCTAssertTrue(host.handleControlRequest(.init(command: "attach", client: owner, attachmentMode: .viewer)).ok)
            XCTAssertTrue(host.handleControlRequest(.init(command: "takeover", clientID: owner.id)).ok)

            let response = host.handleControlRequest(.init(command: "scroll", clientID: owner.id, scrollHorizontal: 0, scrollVertical: 0, scrollMods: 7))

            XCTAssertEqual(response, TerminalControlResponse(ok: true, message: "Ignored zero scroll delta."))

        }
    }

    func testControlScrollRejectsIncompletePointerPosition() async throws {
        try await TerminalEngineActor.run {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }

            let paths = TerminalSessionPaths(rootDirectory: root.path)
            try paths.ensureDirectories()
            let launchConfiguration = TerminalSessionLaunchConfiguration(
                sessionID: "session-invalid-scroll-pointer-\(UUID().uuidString)", backend: .ghosttyEmbedded, title: "shell", workingDirectory: "/tmp",
                shell: "/bin/zsh", command: nil, createdAt: "2026-07-16T00:00:00Z", workspaceID: "workspace-1", kind: .shell)
            let host = GhosttyEmbeddedSessionHost(launchConfiguration: launchConfiguration, paths: paths)
            defer { host.terminate() }
            try TerminalSessionPersistence.writeLaunchConfiguration(launchConfiguration, paths: paths)
            let owner = TerminalClient(
                id: "remote-owner", kind: .remoteViewer, identity: .init(label: "iPhone", deviceName: "iPhone"), connectedAt: "2026-07-16T00:00:00Z")
            XCTAssertTrue(host.handleControlRequest(.init(command: "attach", client: owner, attachmentMode: .viewer)).ok)
            XCTAssertTrue(host.handleControlRequest(.init(command: "takeover", clientID: owner.id)).ok)

            let response = host.handleControlRequest(.init(command: "scroll", clientID: owner.id, scrollVertical: 24, scrollPointerX: 0.5))

            XCTAssertEqual(
                response,
                TerminalControlResponse(ok: false, message: "Terminal scroll pointer coordinates must be provided together.", errorCode: .invalidArgument)
            )

        }
    }

    func testControlKeyCommandKClearsScreenThroughHostAction() async throws {
        let availability = GhosttyEmbeddedLocator.resolve(currentDirectoryPath: FileManager.default.currentDirectoryPath)
        guard case .available = availability else { throw XCTSkip("Ghostty runtime resources are unavailable for embedded renderer testing.") }

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = TerminalSessionPaths(rootDirectory: root.path)
        try paths.ensureDirectories()
        let readyMarker = "command k clear ready"
        let launchConfiguration = TerminalSessionLaunchConfiguration(
            sessionID: "session-command-k-clear-\(UUID().uuidString)", backend: .ghosttyEmbedded, title: "shell",
            workingDirectory: FileManager.default.temporaryDirectory.path, shell: "/bin/sh", command: "stty -echo; printf '\(readyMarker)\\n'; cat",
            createdAt: "2026-06-03T00:00:00Z", workspaceID: "workspace-1", kind: .shell)
        let owner = TerminalClient(
            id: "remote-owner", kind: .remoteViewer, identity: .init(label: "iPhone", deviceName: "iPhone"), connectedAt: "2026-06-03T00:00:00Z")

        let hostBox = try await TerminalEngineActor.run { () -> Box<GhosttyEmbeddedSessionHost> in
            let host = GhosttyEmbeddedSessionHost(launchConfiguration: launchConfiguration, paths: paths)
            try host.attach(client: owner, mode: .owner, into: nil)
            return Box(host)
        }
        let host = hostBox.value
        defer { TerminalEngineActor.runSynchronously { host.terminate() } }
        try await waitUntil {
            guard let snapshot = host.snapshot() else { return false }
            return GhosttyTerminalSnapshotGrid.fullPlainText(for: snapshot).contains(readyMarker)
        }

        let marker = "command k clear marker"
        XCTAssertTrue(TerminalEngineActor.runSynchronously { host.handleControlRequest(.init(command: "send", text: "\(marker)\n", clientID: owner.id)).ok })
        try await waitUntil {
            guard let snapshot = host.snapshot() else { return false }
            return GhosttyTerminalSnapshotGrid.fullPlainText(for: snapshot).contains(marker)
        }

        let response = TerminalEngineActor.runSynchronously { host.handleControlRequest(.init(command: "key", key: "cmd+k", clientID: owner.id)) }

        XCTAssertEqual(response, TerminalControlResponse(ok: true, message: "Cleared terminal screen and scrollback."))
        try await waitUntil {
            host.prepareRenderStateExport()
            guard let snapshot = host.snapshot() else { return false }
            return !GhosttyTerminalSnapshotGrid.fullPlainText(for: snapshot).contains(marker)
        }
    }

    func testControlRejectsInputFromDemotedOwner() async throws {
        try await TerminalEngineActor.run {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }

            let paths = TerminalSessionPaths(rootDirectory: root.path)
            try paths.ensureDirectories()
            let launchConfiguration = TerminalSessionLaunchConfiguration(
                sessionID: "session-demoted-owner", backend: .ghosttyEmbedded, title: "shell", workingDirectory: "/tmp/original", shell: "/bin/zsh",
                command: "zsh", createdAt: "2026-05-31T00:00:00Z", workspaceID: "workspace-1", kind: .shell)
            let host = GhosttyEmbeddedSessionHost(launchConfiguration: launchConfiguration, paths: paths)
            try TerminalSessionPersistence.writeLaunchConfiguration(launchConfiguration, paths: paths)
            let previousOwner = TerminalClient(
                id: "iphone-owner", kind: .remoteViewer, identity: .init(label: "iPhone", deviceName: "iPhone"), connectedAt: "2026-05-31T00:00:00Z")
            let nextOwner = TerminalClient(
                id: "ipad-owner", kind: .remoteViewer, identity: .init(label: "iPad", deviceName: "iPad"), connectedAt: "2026-05-31T00:00:01Z")
            try TerminalSessionPersistence.attachClient(
                sessionID: launchConfiguration.sessionID, client: previousOwner, mode: .owner, paths: paths, attachedAt: "2026-05-31T00:00:00Z")
            try TerminalSessionPersistence.attachClient(
                sessionID: launchConfiguration.sessionID, client: nextOwner, mode: .viewer, paths: paths, attachedAt: "2026-05-31T00:00:01Z")
            try TerminalSessionPersistence.transferOwnership(
                sessionID: launchConfiguration.sessionID, newOwnerClientID: nextOwner.id, paths: paths, transferredAt: "2026-05-31T00:00:02Z")

            let response = host.handleControlRequest(.init(command: "key", key: "enter", clientID: previousOwner.id))

            XCTAssertFalse(response.ok)
            XCTAssertEqual(response.message, "Only the active owner can key the terminal.")

        }
    }

    func testControlRejectsStaleResizeSerialFromActiveOwner() async throws {
        try await TerminalEngineActor.run {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }

            let paths = TerminalSessionPaths(rootDirectory: root.path)
            try paths.ensureDirectories()
            let launchConfiguration = TerminalSessionLaunchConfiguration(
                sessionID: "session-stale-resize", backend: .ghosttyEmbedded, title: "shell", workingDirectory: "/tmp/original", shell: "/bin/zsh",
                command: "zsh", createdAt: "2026-05-31T00:00:00Z", workspaceID: "workspace-1", kind: .shell)
            let host = GhosttyEmbeddedSessionHost(launchConfiguration: launchConfiguration, paths: paths)
            try TerminalSessionPersistence.writeLaunchConfiguration(launchConfiguration, paths: paths)
            host.core.debugSetLastKnownSurfaceSize(columns: 80, rows: 24)
            let owner = TerminalClient(
                id: "remote-owner", kind: .remoteViewer, identity: .init(label: "iPhone", deviceName: "iPhone"), connectedAt: "2026-05-31T00:00:00Z")
            try TerminalSessionPersistence.attachClient(
                sessionID: launchConfiguration.sessionID, client: owner, mode: .owner, paths: paths, attachedAt: "2026-05-31T00:00:00Z")

            let accepted = host.handleControlRequest(.init(command: "resize", clientID: owner.id, columns: 80, rows: 24, ownerEpoch: 0, resizeSerial: 2))
            let stale = host.handleControlRequest(.init(command: "resize", clientID: owner.id, columns: 80, rows: 24, ownerEpoch: 0, resizeSerial: 1))

            XCTAssertTrue(accepted.ok)
            XCTAssertFalse(stale.ok)
            XCTAssertEqual(stale.message, "Ignoring stale resize serial 1; latest accepted serial is 2.")

        }
    }

    func testControlAttachUsesServerTimeForRemoteLease() async throws {
        try await TerminalEngineActor.run {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }

            let paths = TerminalSessionPaths(rootDirectory: root.path)
            try paths.ensureDirectories()
            let launchConfiguration = TerminalSessionLaunchConfiguration(
                sessionID: "session-server-time", backend: .ghosttyEmbedded, title: "shell", workingDirectory: "/tmp/original", shell: "/bin/zsh",
                command: "zsh", createdAt: "2026-05-17T00:00:00Z", workspaceID: "workspace-1", kind: .shell)
            let host = GhosttyEmbeddedSessionHost(launchConfiguration: launchConfiguration, paths: paths)
            try TerminalSessionPersistence.writeLaunchConfiguration(launchConfiguration, paths: paths)
            let staleTimestampedClient = TerminalClient(
                id: "remote-client", kind: .remoteViewer, identity: .init(label: "iPhone", deviceName: "iPhone"), connectedAt: "2000-01-01T00:00:00Z")

            let attachResponse = host.handleControlRequest(.init(command: "attach", client: staleTimestampedClient, attachmentMode: .viewer))
            XCTAssertEqual(attachResponse, TerminalControlResponse(ok: true, message: "Attached viewer client."))
            XCTAssertEqual(try TerminalSessionPersistence.liveAttachments(paths: paths, now: Date()).map(\.clientID), [staleTimestampedClient.id])

            let snapshot = try TerminalSessionPersistence.readAttachmentSnapshot(paths: paths)
            XCTAssertNotEqual(snapshot.clients.first?.connectedAt, staleTimestampedClient.connectedAt)

        }
    }

    func testControlHeartbeatRefreshesOnlySpecifiedRemoteViewerLease() async throws {
        try await TerminalEngineActor.run {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }

            let paths = TerminalSessionPaths(rootDirectory: root.path)
            try paths.ensureDirectories()
            let launchConfiguration = TerminalSessionLaunchConfiguration(
                sessionID: "session-heartbeat", backend: .ghosttyEmbedded, title: "shell", workingDirectory: "/tmp/original", shell: "/bin/zsh",
                command: "zsh", createdAt: "2026-05-17T00:00:00Z", workspaceID: "workspace-1", kind: .shell)
            let host = GhosttyEmbeddedSessionHost(launchConfiguration: launchConfiguration, paths: paths)
            try TerminalSessionPersistence.writeLaunchConfiguration(launchConfiguration, paths: paths)
            let refreshedClient = TerminalClient(
                id: "remote-client", kind: .remoteViewer, identity: .init(label: "iPhone", deviceName: "iPhone"), connectedAt: "2026-05-17T00:00:00Z")
            let staleClient = TerminalClient(
                id: "stale-remote-client", kind: .remoteViewer, identity: .init(label: "iPad", deviceName: "iPad"), connectedAt: "2026-05-17T00:00:00Z")
            try TerminalSessionPersistence.attachClient(
                sessionID: "session-heartbeat", client: refreshedClient, mode: .viewer, paths: paths, attachedAt: "2026-05-17T00:00:00Z")
            try TerminalSessionPersistence.attachClient(
                sessionID: "session-heartbeat", client: staleClient, mode: .viewer, paths: paths, attachedAt: "2026-05-17T00:00:00Z")

            let response = host.handleControlRequest(.init(command: "heartbeat", clientID: refreshedClient.id))
            XCTAssertEqual(response, TerminalControlResponse(ok: true, message: "Refreshed terminal client lease."))
            // The lease write is coalesced off the engine; block until it commits before reading the mirror.
            host.debugDrainPersistenceQueue()

            let now = ISO8601DateFormatter().date(from: "2026-05-17T00:01:01Z")!
            XCTAssertEqual(try TerminalSessionPersistence.liveAttachments(paths: paths, now: now).map(\.clientID), [refreshedClient.id])
            XCTAssertEqual(try TerminalSessionPersistence.staleRemoteClientIDs(paths: paths, now: now), [staleClient.id])

        }
    }

    func testExpireStaleRemoteClientsDetachesLeaseExpiredViewerAndPostsAttachmentChange() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = TerminalSessionPaths(rootDirectory: root.path)
        try paths.ensureDirectories()
        let launchConfiguration = TerminalSessionLaunchConfiguration(
            sessionID: "session-7", backend: .ghosttyEmbedded, title: "shell", workingDirectory: "/tmp/original", shell: "/bin/zsh", command: "zsh",
            createdAt: "2026-05-17T00:00:00Z", workspaceID: "workspace-1", kind: .shell)
        let client = TerminalClient(
            id: "remote-client", kind: .remoteViewer, identity: .init(label: "iPhone", deviceName: "iPhone"), connectedAt: "2026-05-17T00:00:00Z")
        let attachmentNotifications = expectation(description: "attachment expiry notification")
        let observer = NotificationCenter.default.addObserver(forName: .spacesTerminalAttachmentStateDidChange, object: nil, queue: .main) {
            notification in
            guard notification.userInfo?["sessionID"] as? String == "session-7" else { return }
            attachmentNotifications.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        try await TerminalEngineActor.run {
            let host = GhosttyEmbeddedSessionHost(launchConfiguration: launchConfiguration, paths: paths)
            try TerminalSessionPersistence.writeLaunchConfiguration(launchConfiguration, paths: paths)
            try TerminalSessionPersistence.attachClient(
                sessionID: "session-7", client: client, mode: .viewer, paths: paths, attachedAt: "2026-05-17T00:00:00Z")

            let expiredAt = ISO8601DateFormatter().date(from: "2026-05-17T00:01:05Z")!
            XCTAssertEqual(host.expireStaleRemoteClientsIfNeeded(now: expiredAt), ["remote-client"])
            host.debugDrainPersistenceQueue()
            XCTAssertTrue(try TerminalSessionPersistence.activeAttachments(paths: paths).isEmpty)
        }

        await fulfillment(of: [attachmentNotifications], timeout: 2)
    }

    func testExpiringStaleRemoteOwnerTransfersOwnershipBackToActiveLocalWindow() async throws {
        try await TerminalEngineActor.run {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }

            let paths = TerminalSessionPaths(rootDirectory: root.path)
            try paths.ensureDirectories()
            let launchConfiguration = TerminalSessionLaunchConfiguration(
                sessionID: "session-owner-expiry", backend: .ghosttyEmbedded, title: "shell", workingDirectory: "/tmp/original", shell: "/bin/zsh",
                command: "zsh", createdAt: "2026-05-17T00:00:00Z", workspaceID: "workspace-1", kind: .shell)
            let host = GhosttyEmbeddedSessionHost(launchConfiguration: launchConfiguration, paths: paths)
            try TerminalSessionPersistence.writeLaunchConfiguration(launchConfiguration, paths: paths)
            let localClient = TerminalClient(
                id: "local-window", kind: .localWindow, identity: .init(label: "Spaces window"), connectedAt: "2026-05-17T00:00:00Z")
            let remoteClient = TerminalClient(
                id: "stale-remote-owner", kind: .remoteViewer, identity: .init(label: "iPad", deviceName: "iPad"), connectedAt: "2026-05-17T00:00:00Z")
            try TerminalSessionPersistence.attachClient(
                sessionID: launchConfiguration.sessionID, client: localClient, mode: .owner, paths: paths, attachedAt: "2026-05-17T00:00:00Z")
            try TerminalSessionPersistence.attachClient(
                sessionID: launchConfiguration.sessionID, client: remoteClient, mode: .viewer, paths: paths, attachedAt: "2026-05-17T00:00:00Z")
            try TerminalSessionPersistence.transferOwnership(
                sessionID: launchConfiguration.sessionID, newOwnerClientID: remoteClient.id, paths: paths, transferredAt: "2026-05-17T00:00:01Z")

            let expiredAt = ISO8601DateFormatter().date(from: "2026-05-17T00:01:05Z")!
            XCTAssertEqual(host.expireStaleRemoteClientsIfNeeded(now: expiredAt), [remoteClient.id])
            host.debugDrainPersistenceQueue()

            let activeAttachments = try TerminalSessionPersistence.activeAttachments(paths: paths)
            XCTAssertEqual(activeAttachments.first(where: { $0.mode == .owner })?.clientID, localClient.id)
            XCTAssertFalse(activeAttachments.contains { $0.clientID == remoteClient.id })

        }
    }

    func testDetachingViewerKeepsOwnerFocusState() {
        XCTAssertFalse(
            GhosttyEmbeddedSessionHost.shouldClearFocusAfterDetachingClient(detachedClientWasOwner: false, remainingOwnerClientID: "owner-client"))
        XCTAssertTrue(GhosttyEmbeddedSessionHost.shouldClearFocusAfterDetachingClient(detachedClientWasOwner: true, remainingOwnerClientID: nil))
        XCTAssertTrue(GhosttyEmbeddedSessionHost.shouldClearFocusAfterDetachingClient(detachedClientWasOwner: false, remainingOwnerClientID: nil))
    }

    /// Holds the shared database's write lock (`BEGIN IMMEDIATE`) from a background thread until released,
    /// standing in for an agent hook's `spaces agent signal` write burst. Raw SQLite3 so it contends the
    /// exact WAL write lock the terminal engine's coalesced durable writes take; `ROLLBACK` leaves the
    /// database untouched. WAL reads (stale-client liveness checks, attachment reads) stay unblocked.
    private final class CompetingWriteLockHolder: @unchecked Sendable {
        private let databasePath: String
        private let acquired = DispatchSemaphore(value: 0)
        private let releaseNow = DispatchSemaphore(value: 0)

        init(databasePath: String) { self.databasePath = databasePath }

        func startHolding(maxHoldSeconds: TimeInterval) {
            Thread.detachNewThread { [databasePath, acquired, releaseNow] in
                var handle: OpaquePointer?
                guard sqlite3_open(databasePath, &handle) == SQLITE_OK, let handle else {
                    acquired.signal()
                    return
                }
                defer { sqlite3_close(handle) }
                sqlite3_busy_timeout(handle, 5000)
                guard sqlite3_exec(handle, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else {
                    acquired.signal()
                    return
                }
                acquired.signal()
                _ = releaseNow.wait(timeout: .now() + maxHoldSeconds)
                _ = sqlite3_exec(handle, "ROLLBACK", nil, nil, nil)
            }
        }

        func waitUntilHolding() { acquired.wait() }
        func release() { releaseNow.signal() }
    }

    /// Finding B1: a client that just heartbeated must not be expired off a stale DB lease read while its
    /// coalesced durable lease touch is still blocked on the write lock. The heartbeat records the client's
    /// fresh lease in memory synchronously on the engine; expiry consults that in-memory heartbeat, not only
    /// the committed DB row. Before the fix the timer's expiry read the pre-touch DB lease and detached the
    /// freshly heartbeated owner.
    func testFreshHeartbeatSparesClientFromExpiryWhileDurableTouchIsBlocked() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = TerminalSessionPaths(rootDirectory: root.path)
        try paths.ensureDirectories()
        let launchConfiguration = TerminalSessionLaunchConfiguration(
            sessionID: "session-b1-heartbeat", backend: .ghosttyEmbedded, title: "shell", workingDirectory: "/tmp/original", shell: "/bin/zsh",
            command: "zsh", createdAt: "2026-05-17T00:00:00Z", workspaceID: "workspace-1", kind: .shell)
        // Attach with a very old lease so the committed DB row is stale at real-now.
        let staleClient = TerminalClient(
            id: "remote-heartbeat", kind: .remoteViewer, identity: .init(label: "iPhone", deviceName: "iPhone"),
            connectedAt: "2000-01-01T00:00:00Z")
        try TerminalSessionPersistence.writeLaunchConfiguration(launchConfiguration, paths: paths)
        try TerminalSessionPersistence.attachClient(
            sessionID: launchConfiguration.sessionID, client: staleClient, mode: .viewer, paths: paths, attachedAt: "2000-01-01T00:00:00Z")

        let lockHolder = CompetingWriteLockHolder(databasePath: try SpacesProfile.current().databasePath)
        lockHolder.startHolding(maxHoldSeconds: 10)
        lockHolder.waitUntilHolding()
        defer { lockHolder.release() }

        let expired = TerminalEngineActor.runSynchronously { () -> [String] in
            let host = GhosttyEmbeddedSessionHost(launchConfiguration: launchConfiguration, paths: paths)
            // Heartbeat records the fresh lease in memory; its coalesced durable touch now blocks on the lock.
            _ = host.handleControlRequest(.init(command: "heartbeat", clientID: staleClient.id))
            // Sanity: the committed DB lease is still stale (the touch has not landed).
            XCTAssertEqual(try? TerminalSessionPersistence.staleRemoteClientIDs(paths: paths, now: Date()), [staleClient.id])
            return host.expireStaleRemoteClientsIfNeeded(now: Date())
        }
        XCTAssertEqual(
            expired, [], "a client that just heartbeated must not be expired while its durable lease touch is blocked on the DB write lock")
    }

    /// Finding B1: once an expiry has been enqueued for a stale remote owner, later timer ticks must not
    /// re-enqueue the detach/ownership-transfer (or bump the owner epoch again) while that first decision's
    /// durable detach is still pending. The held write lock keeps the detach uncommitted across both ticks,
    /// so without the dedup guard the DB still shows the remote as the stale owner and the second tick
    /// duplicates the transfer.
    func testRepeatedExpiryTicksDoNotDuplicateOwnershipTransferBeforeDetachCommits() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = TerminalSessionPaths(rootDirectory: root.path)
        try paths.ensureDirectories()
        let launchConfiguration = TerminalSessionLaunchConfiguration(
            sessionID: "session-b1-dedup", backend: .ghosttyEmbedded, title: "shell", workingDirectory: "/tmp/original", shell: "/bin/zsh",
            command: "zsh", createdAt: "2026-05-17T00:00:00Z", workspaceID: "workspace-1", kind: .shell)
        let localClient = TerminalClient(
            id: "local-window", kind: .localWindow, identity: .init(label: "Spaces window"), connectedAt: "2000-01-01T00:00:00Z")
        let remoteClient = TerminalClient(
            id: "stale-remote-owner", kind: .remoteViewer, identity: .init(label: "iPad", deviceName: "iPad"), connectedAt: "2000-01-01T00:00:00Z")
        try TerminalSessionPersistence.writeLaunchConfiguration(launchConfiguration, paths: paths)
        try TerminalSessionPersistence.attachClient(
            sessionID: launchConfiguration.sessionID, client: localClient, mode: .owner, paths: paths, attachedAt: "2000-01-01T00:00:00Z")
        try TerminalSessionPersistence.attachClient(
            sessionID: launchConfiguration.sessionID, client: remoteClient, mode: .viewer, paths: paths, attachedAt: "2000-01-01T00:00:00Z")
        try TerminalSessionPersistence.transferOwnership(
            sessionID: launchConfiguration.sessionID, newOwnerClientID: remoteClient.id, paths: paths, transferredAt: "2000-01-01T00:00:01Z")

        let lockHolder = CompetingWriteLockHolder(databasePath: try SpacesProfile.current().databasePath)
        lockHolder.startHolding(maxHoldSeconds: 10)
        lockHolder.waitUntilHolding()
        defer { lockHolder.release() }

        let result = TerminalEngineActor.runSynchronously { () -> (first: [String], epochAfterFirst: UInt64, second: [String], epochAfterSecond: UInt64) in
            let host = GhosttyEmbeddedSessionHost(launchConfiguration: launchConfiguration, paths: paths)
            let now = Date()
            let first = host.expireStaleRemoteClientsIfNeeded(now: now)
            let epochAfterFirst = host.core.debugOwnerEpoch
            let second = host.expireStaleRemoteClientsIfNeeded(now: now)
            let epochAfterSecond = host.core.debugOwnerEpoch
            return (first, epochAfterFirst, second, epochAfterSecond)
        }
        XCTAssertEqual(result.first, [remoteClient.id], "the first tick must expire the stale remote owner")
        XCTAssertEqual(result.second, [], "the second tick must not re-expire a client whose detach/transfer is still pending")
        XCTAssertEqual(
            result.epochAfterSecond, result.epochAfterFirst, "a duplicate ownership transfer must not bump the owner epoch a second time")
    }

    /// Enforcement/advertisement coherence: a stale-client expiry promotes the transfer target to owner in the
    /// in-memory attachment cache and broadcasts that immediately, while the atomic `expireClients` write is
    /// only enqueued (here held off by a competing write lock, standing in for the up-to-5s busy-timeout window).
    /// Owner-gating must read the same cache, not the not-yet-committed durable mirror — otherwise the broadcast
    /// tells the promoted local client it owns the terminal while its control requests are `.ownershipRejected`
    /// off the stale DB owner, silently dropping keystrokes. This asserts the promoted client's epoch-carrying
    /// send is ACCEPTED before the transfer commits, and that the expired remote owner's send is now rejected.
    /// Pre-fix (enforcement reading the DB) the promoted send failed with `.ownershipRejected`.
    func testPromotedLocalClientControlAcceptedBeforeExpiryTransferCommits() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = TerminalSessionPaths(rootDirectory: root.path)
        try paths.ensureDirectories()
        let launchConfiguration = TerminalSessionLaunchConfiguration(
            sessionID: "session-promoted-coherence", backend: .ghosttyEmbedded, title: "shell", workingDirectory: "/tmp/original", shell: "/bin/zsh",
            command: "zsh", createdAt: "2026-05-17T00:00:00Z", workspaceID: "workspace-1", kind: .shell)
        let localClient = TerminalClient(
            id: "local-window", kind: .localWindow, identity: .init(label: "Spaces window"), connectedAt: "2000-01-01T00:00:00Z")
        let remoteClient = TerminalClient(
            id: "stale-remote-owner", kind: .remoteViewer, identity: .init(label: "iPad", deviceName: "iPad"), connectedAt: "2000-01-01T00:00:00Z")
        try TerminalSessionPersistence.writeLaunchConfiguration(launchConfiguration, paths: paths)
        try TerminalSessionPersistence.attachClient(
            sessionID: launchConfiguration.sessionID, client: localClient, mode: .owner, paths: paths, attachedAt: "2000-01-01T00:00:00Z")
        try TerminalSessionPersistence.attachClient(
            sessionID: launchConfiguration.sessionID, client: remoteClient, mode: .viewer, paths: paths, attachedAt: "2000-01-01T00:00:00Z")
        // Remote becomes the owner (local demoted to viewer); its 2000-era lease makes it a stale owner at real-now.
        try TerminalSessionPersistence.transferOwnership(
            sessionID: launchConfiguration.sessionID, newOwnerClientID: remoteClient.id, paths: paths, transferredAt: "2000-01-01T00:00:01Z")

        let lockHolder = CompetingWriteLockHolder(databasePath: try SpacesProfile.current().databasePath)
        lockHolder.startHolding(maxHoldSeconds: 10)
        lockHolder.waitUntilHolding()
        defer { lockHolder.release() }

        let outcome = TerminalEngineActor.runSynchronously {
            () -> (expired: [String], promoted: TerminalControlResponse, expiredOwner: TerminalControlResponse) in
            let host = GhosttyEmbeddedSessionHost(launchConfiguration: launchConfiguration, paths: paths)
            let expired = host.expireStaleRemoteClientsIfNeeded(now: Date())
            // The expiry advanced the owner epoch and promoted the local window client in the cache and broadcasts;
            // its atomic durable transfer is still blocked on the held write lock.
            let epoch = host.core.debugOwnerEpoch
            XCTAssertEqual(
                (try? TerminalSessionPersistence.activeAttachments(paths: paths))?.first(where: { $0.mode == .owner })?.clientID,
                remoteClient.id, "the durable ownership transfer must still be pending under the held write lock")
            let promoted = host.handleControlRequest(
                .init(command: "send", text: "echo promoted\n", clientID: localClient.id, ownerEpoch: epoch))
            let expiredOwner = host.handleControlRequest(
                .init(command: "send", text: "echo stale\n", clientID: remoteClient.id, ownerEpoch: epoch))
            return (expired, promoted, expiredOwner)
        }
        XCTAssertEqual(outcome.expired, [remoteClient.id], "the tick must expire the stale remote owner")
        XCTAssertTrue(
            outcome.promoted.ok,
            "the promoted local client's send must be accepted from the cache the broadcast advertises, not rejected off the uncommitted DB owner")
        XCTAssertFalse(outcome.expiredOwner.ok, "the expired remote owner is no longer the owner and its send must be rejected")
        XCTAssertEqual(outcome.expiredOwner.errorCode, .ownershipRejected)
    }

    /// R7-2 (heartbeat veto): a heartbeat accepted after a stale-client expiry has been decided must supersede
    /// that expiry, not be silently detached by it. The expiry's durable detach blocks on the held write lock;
    /// the client then heartbeats — accepted in memory (ok), but its own durable lease touch is queued FIFO
    /// behind the expiry, so the committed lease row the expiry compares against still looks stale. The engine
    /// bumps the client's heartbeat generation on accept; `expireClients` re-reads that generation INSIDE its
    /// write transaction (once it finally acquires the lock, after the heartbeat) and skips detaching the client.
    /// The client stays durably attached and the cache agrees. Pre-fix the expiry's lease CAS matched and
    /// detached the client with `.applied`, leaving an ACK'd-but-detached zombie.
    func testHeartbeatAfterExpiryDecisionVetoesDetachUnderWriteContention() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = TerminalSessionPaths(rootDirectory: root.path)
        try paths.ensureDirectories()
        let launchConfiguration = TerminalSessionLaunchConfiguration(
            sessionID: "session-r7-2-veto", backend: .ghosttyEmbedded, title: "shell", workingDirectory: "/tmp/original", shell: "/bin/zsh",
            command: "zsh", createdAt: "2026-05-17T00:00:00Z", workspaceID: "workspace-1", kind: .shell)
        try TerminalSessionPersistence.writeLaunchConfiguration(launchConfiguration, paths: paths)
        // A stale (2000-era lease) remote viewer so the committed DB row is a stale-expiry candidate at real-now.
        let staleClient = TerminalClient(
            id: "remote-heartbeat-veto", kind: .remoteViewer, identity: .init(label: "iPhone", deviceName: "iPhone"),
            connectedAt: "2000-01-01T00:00:00Z")
        try TerminalSessionPersistence.attachClient(
            sessionID: launchConfiguration.sessionID, client: staleClient, mode: .viewer, paths: paths, attachedAt: "2000-01-01T00:00:00Z")

        let lockHolder = CompetingWriteLockHolder(databasePath: try SpacesProfile.current().databasePath)
        lockHolder.startHolding(maxHoldSeconds: 10)
        lockHolder.waitUntilHolding()

        let hostBox = TerminalEngineActor.runSynchronously { () -> Box<GhosttyEmbeddedSessionHost> in
            let host = GhosttyEmbeddedSessionHost(launchConfiguration: launchConfiguration, paths: paths)
            // The tick decides to expire the stale viewer and enqueues the atomic detach, which now blocks on the
            // held write lock at BEGIN IMMEDIATE.
            let expired = host.expireStaleRemoteClientsIfNeeded(now: Date())
            XCTAssertEqual(expired, [staleClient.id], "the tick must decide to expire the stale viewer")
            // The client heartbeats after the decision: accepted in memory (bumping its generation) and ok, while
            // its durable lease touch queues FIFO behind the still-blocked expiry.
            let heartbeat = host.handleControlRequest(.init(command: "heartbeat", clientID: staleClient.id))
            XCTAssertTrue(heartbeat.ok, "a heartbeat for a client with a pending (veto-able) expiry must be accepted in memory")
            return Box(host)
        }

        // Release the lock: the parked expiry now acquires the write lock and re-reads the heartbeat generation
        // inside its transaction — seeing the post-decision bump, it skips detaching the client.
        lockHolder.release()
        await TerminalEngineActor.run { hostBox.value.debugDrainPersistenceQueue() }
        // Let the `.superseded` reconcile hop (enqueued from the persistence closure) run so it invalidates the
        // optimistically-mutated cache, which then reseeds from the still-attached durable rows.
        await TerminalEngineActor.run {}

        XCTAssertEqual(
            try TerminalSessionPersistence.activeAttachments(paths: paths).map(\.clientID), [staleClient.id],
            "the heartbeated client must NOT be detached by the superseded expiry — it stays durably attached")
        let cachedClientIDs = TerminalEngineActor.runSynchronously { () -> [String] in
            (hostBox.value.debugCurrentRemoteSessionState(reason: "test")?.attachmentSnapshot?.attachments ?? [])
                .filter { $0.detachedAt == nil }.map(\.clientID)
        }
        XCTAssertEqual(cachedClientIDs, [staleClient.id], "the in-memory cache must agree the heartbeated client is still attached")
    }

    /// Lost-update race: a queued stale-owner expiry must not overwrite a takeover that committed synchronously
    /// after the expiry decision. The tick decides to transfer ownership from the stale remote owner R to the
    /// local window A and optimistically promotes A in its cache, but its atomic `expireClients` write is only
    /// enqueued (parked here on the held persistence queue). Before it commits, remote viewer B takes over — a
    /// synchronous transfer that is ack'd ok, making B the durable owner. When the queued expiry finally runs it
    /// must SKIP the transfer (B is not one of the expired clients) and leave B the durable owner, only detaching
    /// the genuinely stale R. Pre-fix `expireClients` demoted every active owner but the target and promoted A
    /// unconditionally, durably stomping B's ack'd takeover — a permanent inversion that survived handoff.
    func testQueuedStaleOwnerExpiryDoesNotOverwriteSynchronousTakeover() async throws {
        try await TerminalEngineActor.run {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }

            let paths = TerminalSessionPaths(rootDirectory: root.path)
            try paths.ensureDirectories()
            let launchConfiguration = TerminalSessionLaunchConfiguration(
                sessionID: "session-takeover-race", backend: .ghosttyEmbedded, title: "shell", workingDirectory: "/tmp/original", shell: "/bin/zsh",
                command: "zsh", createdAt: "2026-05-17T00:00:00Z", workspaceID: "workspace-1", kind: .shell)
            let host = GhosttyEmbeddedSessionHost(launchConfiguration: launchConfiguration, paths: paths)
            try TerminalSessionPersistence.writeLaunchConfiguration(launchConfiguration, paths: paths)
            let localClient = TerminalClient(
                id: "local-window", kind: .localWindow, identity: .init(label: "Spaces window"), connectedAt: "2000-01-01T00:00:00Z")
            let staleRemoteOwner = TerminalClient(
                id: "stale-remote-owner", kind: .remoteViewer, identity: .init(label: "iPad", deviceName: "iPad"), connectedAt: "2000-01-01T00:00:00Z")
            // B attaches with a fresh lease so it is never itself a stale-expiry candidate.
            let takeoverClient = TerminalClient(
                id: "takeover-remote", kind: .remoteViewer, identity: .init(label: "iPhone", deviceName: "iPhone"),
                connectedAt: TerminalSessionTimestamp.string(from: Date()))
            try TerminalSessionPersistence.attachClient(
                sessionID: launchConfiguration.sessionID, client: localClient, mode: .owner, paths: paths, attachedAt: "2000-01-01T00:00:00Z")
            try TerminalSessionPersistence.attachClient(
                sessionID: launchConfiguration.sessionID, client: staleRemoteOwner, mode: .viewer, paths: paths, attachedAt: "2000-01-01T00:00:00Z")
            try TerminalSessionPersistence.attachClient(
                sessionID: launchConfiguration.sessionID, client: takeoverClient, mode: .viewer, paths: paths,
                attachedAt: TerminalSessionTimestamp.string(from: Date()))
            // The stale remote becomes the owner (2000-era lease makes it stale at real-now).
            try TerminalSessionPersistence.transferOwnership(
                sessionID: launchConfiguration.sessionID, newOwnerClientID: staleRemoteOwner.id, paths: paths, transferredAt: "2000-01-01T00:00:01Z")

            // Park the persistence queue so the tick's atomic expiry is enqueued but cannot commit yet.
            let gate = host.debugHoldPersistenceQueue()
            let expired = host.expireStaleRemoteClientsIfNeeded(now: Date())
            XCTAssertEqual(expired, [staleRemoteOwner.id], "the tick must decide to expire the stale remote owner (transferring to the local window)")

            // B takes over synchronously (not via the parked queue); its transfer commits and is ack'd ok.
            let takeover = host.handleControlRequest(.init(command: "takeover", clientID: takeoverClient.id))
            XCTAssertTrue(takeover.ok, "the takeover must be accepted before the queued expiry commits")
            XCTAssertEqual(
                (try TerminalSessionPersistence.activeAttachments(paths: paths)).first(where: { $0.mode == .owner })?.clientID, takeoverClient.id,
                "B's takeover is durably the owner before the expiry runs")

            // Release the queue: the parked expiry now commits against a world where B owns the session.
            gate.signal()
            host.debugDrainPersistenceQueue()

            let activeAttachments = try TerminalSessionPersistence.activeAttachments(paths: paths)
            XCTAssertEqual(
                activeAttachments.first(where: { $0.mode == .owner })?.clientID, takeoverClient.id,
                "the queued expiry must not overwrite B's ack'd takeover — B stays the durable owner")
            XCTAssertFalse(
                activeAttachments.contains { $0.clientID == staleRemoteOwner.id }, "the genuinely stale remote owner is still detached by the expiry")
            XCTAssertEqual(host.activeOwnerClientID(), takeoverClient.id, "the cache agrees B is the owner (no regression off the reseeded durable state)")
            XCTAssertTrue(host.isOwner(clientID: takeoverClient.id), "B is accepted as owner by enforcement")
            XCTAssertFalse(host.isOwner(clientID: localClient.id), "the local window A must not have been promoted by the superseded transfer")
        }
    }

    /// Lost-update race (resurrection): a queued stale-owner expiry that transfers ownership to a local window
    /// target A must not resurrect A as a durable owner if A detached in the window between the decision and the
    /// commit. The tick decides to transfer R → A and enqueues its atomic `expireClients` (parked here); A then
    /// detaches synchronously. When the expiry commits, the target has no active attachment, so the transfer is
    /// skipped and no owner row is created. Pre-fix `expireClients` INSERTed a brand-new active owner row for A —
    /// a ghost owner whose client row is disconnected — which pins the session open via `hasActiveAttachments`
    /// and blocks auto-close. After the fix no active durable attachment remains, so the session can auto-close.
    func testQueuedStaleOwnerExpiryDoesNotResurrectDetachedTransferTarget() async throws {
        try await TerminalEngineActor.run {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }

            let paths = TerminalSessionPaths(rootDirectory: root.path)
            try paths.ensureDirectories()
            let launchConfiguration = TerminalSessionLaunchConfiguration(
                sessionID: "session-resurrect-race", backend: .ghosttyEmbedded, title: "shell", workingDirectory: "/tmp/original", shell: "/bin/zsh",
                command: "zsh", createdAt: "2026-05-17T00:00:00Z", workspaceID: "workspace-1", kind: .shell)
            let host = GhosttyEmbeddedSessionHost(launchConfiguration: launchConfiguration, paths: paths)
            try TerminalSessionPersistence.writeLaunchConfiguration(launchConfiguration, paths: paths)
            let localClient = TerminalClient(
                id: "local-window", kind: .localWindow, identity: .init(label: "Spaces window"), connectedAt: "2000-01-01T00:00:00Z")
            let staleRemoteOwner = TerminalClient(
                id: "stale-remote-owner", kind: .remoteViewer, identity: .init(label: "iPad", deviceName: "iPad"), connectedAt: "2000-01-01T00:00:00Z")
            try TerminalSessionPersistence.attachClient(
                sessionID: launchConfiguration.sessionID, client: localClient, mode: .owner, paths: paths, attachedAt: "2000-01-01T00:00:00Z")
            try TerminalSessionPersistence.attachClient(
                sessionID: launchConfiguration.sessionID, client: staleRemoteOwner, mode: .viewer, paths: paths, attachedAt: "2000-01-01T00:00:00Z")
            try TerminalSessionPersistence.transferOwnership(
                sessionID: launchConfiguration.sessionID, newOwnerClientID: staleRemoteOwner.id, paths: paths, transferredAt: "2000-01-01T00:00:01Z")

            // Park the queue so the tick's atomic expiry (transfer target = the local window A) is enqueued but
            // cannot commit yet.
            let gate = host.debugHoldPersistenceQueue()
            let expired = host.expireStaleRemoteClientsIfNeeded(now: Date())
            XCTAssertEqual(expired, [staleRemoteOwner.id], "the tick must decide to expire the stale remote owner (transferring to the local window)")

            // The transfer target A detaches synchronously before the parked expiry commits.
            try host.detach(clientID: localClient.id)

            // Release the queue: the parked expiry now commits against a world where the target has detached.
            gate.signal()
            host.debugDrainPersistenceQueue()

            let activeAttachments = try TerminalSessionPersistence.activeAttachments(paths: paths)
            XCTAssertTrue(
                activeAttachments.isEmpty,
                "the detached transfer target must not be resurrected as a ghost owner — no active durable attachment remains, so the session can auto-close")
        }
    }

    /// Finding B4: a failed exited-state persist must retry, not leave the durable runtime row stuck at
    /// `.running` forever while the final payload says terminated. Termination cancels the runtime-state
    /// timer, so nothing else re-persists. Breaking the database makes terminate()'s exited write fail;
    /// restoring it lets the bounded retry land the exited state.
    func testFailedExitedRuntimeStateWriteRetriesUntilItLands() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = TerminalSessionPaths(rootDirectory: root.path)
        try paths.ensureDirectories()
        let launchConfiguration = TerminalSessionLaunchConfiguration(
            sessionID: "session-b4-retry", backend: .ghosttyEmbedded, title: "shell", workingDirectory: "/tmp/original", shell: "/bin/zsh",
            command: "zsh", createdAt: "2026-05-17T00:00:00Z", workspaceID: "workspace-1", kind: .shell)
        try TerminalSessionPersistence.writeLaunchConfiguration(launchConfiguration, paths: paths)
        let runningState = TerminalSessionRuntimeState(
            sessionID: launchConfiguration.sessionID, backend: .ghosttyEmbedded, servicePID: getpid(), childPID: nil, state: .running,
            updatedAt: TerminalSessionTimestamp.string(from: Date()), title: "shell", workingDirectory: "/tmp/original")
        try TerminalSessionPersistence.writeRuntimeState(runningState, paths: paths)
        XCTAssertEqual(try TerminalSessionPersistence.readRuntimeState(paths: paths).state, .running)

        let databasePath = try SpacesProfile.current().databasePath
        try Self.breakDatabase(at: databasePath)

        // terminate() enqueues the exited-state write; it fails against the broken database and schedules a
        // bounded retry. Keep the host alive so the retry (which no longer depends on the core) still has a
        // live core to update its markers, matching the common non-dropped path.
        let box = TerminalEngineActor.runSynchronously { () -> Box<GhosttyEmbeddedSessionHost> in
            let host = GhosttyEmbeddedSessionHost(launchConfiguration: launchConfiguration, paths: paths)
            host.terminate()
            return Box(host)
        }
        try Self.restoreDatabase(at: databasePath)

        let deadline = Date().addingTimeInterval(3)
        var landed = false
        while Date() < deadline {
            if (try? TerminalSessionPersistence.readRuntimeState(paths: paths))?.state == .exited {
                landed = true
                break
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(landed, "a failed exited-state write must retry and eventually mark the durable runtime row exited")
        _ = box
    }

    /// Fix 2 (FIFO fence): the exited runtime-state write retries IN PLACE and so keeps its slot on the serial
    /// persistence queue. The detach-all/payload/durable-end items `terminate()` enqueues after it therefore
    /// run only once it commits. The detach has no retry of its own, so it lands durably only if it waited
    /// behind the retrying exited write until the database recovered — a faithful proxy for the fence. Before
    /// the fix the failed exited write surrendered its FIFO slot via `asyncAfter`, so the detach ran
    /// immediately against the broken database and was lost while the (deferred) exited retry still landed.
    func testExitedRuntimeStateWriteHoldsFIFOFenceForLaterDetach() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = TerminalSessionPaths(rootDirectory: root.path)
        try paths.ensureDirectories()
        let launchConfiguration = TerminalSessionLaunchConfiguration(
            sessionID: "session-fence", backend: .ghosttyEmbedded, title: "shell", workingDirectory: "/tmp/original", shell: "/bin/zsh",
            command: "zsh", createdAt: "2026-05-17T00:00:00Z", workspaceID: "workspace-1", kind: .shell)
        try TerminalSessionPersistence.writeLaunchConfiguration(launchConfiguration, paths: paths)
        let client = TerminalClient(
            id: "remote-client", kind: .remoteViewer, identity: .init(label: "iPhone", deviceName: "iPhone"), connectedAt: "2026-05-17T00:00:00Z")
        try TerminalSessionPersistence.attachClient(
            sessionID: launchConfiguration.sessionID, client: client, mode: .viewer, paths: paths, attachedAt: "2026-05-17T00:00:00Z")
        let runningState = TerminalSessionRuntimeState(
            sessionID: launchConfiguration.sessionID, backend: .ghosttyEmbedded, servicePID: getpid(), childPID: nil, state: .running,
            updatedAt: TerminalSessionTimestamp.string(from: Date()), title: "shell", workingDirectory: "/tmp/original")
        try TerminalSessionPersistence.writeRuntimeState(runningState, paths: paths)
        XCTAssertFalse(try TerminalSessionPersistence.activeAttachments(paths: paths).isEmpty)

        let databasePath = try SpacesProfile.current().databasePath
        try Self.breakDatabase(at: databasePath)

        let box = TerminalEngineActor.runSynchronously { () -> Box<GhosttyEmbeddedSessionHost> in
            let host = GhosttyEmbeddedSessionHost(launchConfiguration: launchConfiguration, paths: paths)
            host.terminate()
            return Box(host)
        }
        // The exited write fails against the broken database and is now retrying in place, holding the queue.
        // Sleep long enough that the pre-fix design's immediate (broken) detach would already have run and been
        // lost, then restore the database while the retry is still holding the fence.
        try await Task.sleep(nanoseconds: 100_000_000)
        try Self.restoreDatabase(at: databasePath)

        await TerminalEngineActor.run { box.value.debugDrainPersistenceQueue() }
        XCTAssertEqual(
            try TerminalSessionPersistence.readRuntimeState(paths: paths).state, .exited,
            "the retried exited write must commit before the drain completes")
        XCTAssertTrue(
            try TerminalSessionPersistence.activeAttachments(paths: paths).isEmpty,
            "the detach enqueued after the exited write must run only after that write commits, so it lands post-recovery")
        _ = box
    }

    /// Fix 1: `drainPersistenceForShutdown` — the awaitable drain SpacesdMain runs after terminating a core in
    /// `shutdown()` and the nil-quiesce handoff branch — must not return until every write `terminate()`
    /// enqueued has committed, including an exited runtime-state write a competing transaction delayed. Without
    /// it, `exit(0)`/`execv` destroys the still-queued exited write and strands the durable row at `.running`
    /// (and, across `execv`, the unchanged pid makes `recoverStaleSessions` skip that `.running` row forever).
    func testDrainPersistenceForShutdownAwaitsDelayedExitedWrite() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = TerminalSessionPaths(rootDirectory: root.path)
        try paths.ensureDirectories()
        let launchConfiguration = TerminalSessionLaunchConfiguration(
            sessionID: "session-shutdown-drain", backend: .ghosttyEmbedded, title: "shell", workingDirectory: "/tmp/original", shell: "/bin/zsh",
            command: "zsh", createdAt: "2026-05-17T00:00:00Z", workspaceID: "workspace-1", kind: .shell)
        try TerminalSessionPersistence.writeLaunchConfiguration(launchConfiguration, paths: paths)
        let runningState = TerminalSessionRuntimeState(
            sessionID: launchConfiguration.sessionID, backend: .ghosttyEmbedded, servicePID: getpid(), childPID: nil, state: .running,
            updatedAt: TerminalSessionTimestamp.string(from: Date()), title: "shell", workingDirectory: "/tmp/original")
        try TerminalSessionPersistence.writeRuntimeState(runningState, paths: paths)
        XCTAssertEqual(try TerminalSessionPersistence.readRuntimeState(paths: paths).state, .running)

        let lockHolder = CompetingWriteLockHolder(databasePath: try SpacesProfile.current().databasePath)
        lockHolder.startHolding(maxHoldSeconds: 10)
        lockHolder.waitUntilHolding()

        let box = TerminalEngineActor.runSynchronously { () -> Box<GhosttyEmbeddedSessionHost> in
            let host = GhosttyEmbeddedSessionHost(launchConfiguration: launchConfiguration, paths: paths)
            host.terminate()
            return Box(host)
        }
        // Hold the competing transaction long enough for the enqueued exited write to be blocking on it, then
        // release so the write can commit. The drain must not return until it does.
        try await Task.sleep(nanoseconds: 200_000_000)
        lockHolder.release()

        await box.value.core.drainPersistenceForShutdown()
        XCTAssertEqual(
            try TerminalSessionPersistence.readRuntimeState(paths: paths).state, .exited,
            "drainPersistenceForShutdown must block until the competing-delayed exited write commits")
        _ = box
    }

    /// Fix 4: a stale-client expiry whose durable detach write fails must be retried on a later timer tick, not
    /// abandoned. The persistence queue is parked so the first tick's reads run against a healthy database and
    /// its detach is enqueued behind the park; breaking the database, then releasing the park, makes that
    /// detach fail. The failure hops back to the engine and un-marks the client in `expiredRemoteClientIDs`, so
    /// the next tick — after the database is restored — re-derives it from the still-stale DB row and
    /// re-enqueues the (idempotent) detach, which lands. Before the fix the client stayed stuck in
    /// `expiredRemoteClientIDs` and was skipped on every later tick forever.
    func testFailedStaleClientExpiryDetachRetriesOnLaterTick() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = TerminalSessionPaths(rootDirectory: root.path)
        try paths.ensureDirectories()
        let launchConfiguration = TerminalSessionLaunchConfiguration(
            sessionID: "session-expiry-retry", backend: .ghosttyEmbedded, title: "shell", workingDirectory: "/tmp/original", shell: "/bin/zsh",
            command: "zsh", createdAt: "2026-05-17T00:00:00Z", workspaceID: "workspace-1", kind: .shell)
        try TerminalSessionPersistence.writeLaunchConfiguration(launchConfiguration, paths: paths)
        let client = TerminalClient(
            id: "remote-client", kind: .remoteViewer, identity: .init(label: "iPad", deviceName: "iPad"), connectedAt: "2026-05-17T00:00:00Z")
        try TerminalSessionPersistence.attachClient(
            sessionID: launchConfiguration.sessionID, client: client, mode: .viewer, paths: paths, attachedAt: "2026-05-17T00:00:00Z")

        let expiredAt = ISO8601DateFormatter().date(from: "2026-05-17T00:01:05Z")!
        let databasePath = try SpacesProfile.current().databasePath
        let box = TerminalEngineActor.runSynchronously { () -> Box<GhosttyEmbeddedSessionHost> in
            Box(GhosttyEmbeddedSessionHost(launchConfiguration: launchConfiguration, paths: paths))
        }

        // Park the persistence queue so tick 1's detach waits behind it while we break the database.
        let gate = TerminalEngineActor.runSynchronously { box.value.debugHoldPersistenceQueue() }
        // Tick 1: reads run against the healthy database and enqueue the detach behind the park.
        let firstTickExpired = TerminalEngineActor.runSynchronously { box.value.expireStaleRemoteClientsIfNeeded(now: expiredAt) }
        XCTAssertEqual(firstTickExpired, [client.id], "the first tick must expire the stale client")

        try Self.breakDatabase(at: databasePath)
        gate.signal()
        // The detach now runs against the broken database, fails, and re-arms the expiry.
        TerminalEngineActor.runSynchronously { box.value.debugDrainPersistenceQueue() }
        try Self.restoreDatabase(at: databasePath)
        XCTAssertFalse(
            try TerminalSessionPersistence.activeAttachments(paths: paths).isEmpty,
            "the detach must have failed against the broken database, leaving the client attached")

        // Let the re-arm engine hop (enqueued during tick 1's drain) run before the second tick.
        await TerminalEngineActor.run {}

        // Tick 2: the client is still stale in the DB and no longer suppressed, so expiry re-enqueues the
        // detach, which now commits against the restored database.
        let secondTickExpired = TerminalEngineActor.runSynchronously { () -> [String] in
            let expired = box.value.expireStaleRemoteClientsIfNeeded(now: expiredAt)
            box.value.debugDrainPersistenceQueue()
            return expired
        }
        XCTAssertEqual(secondTickExpired, [client.id], "a failed expiry must be re-derived and re-enqueued on the next tick")
        XCTAssertTrue(
            try TerminalSessionPersistence.activeAttachments(paths: paths).isEmpty,
            "the re-enqueued detach must land the client detached")
        _ = box
    }

    /// The create path serves the post-start session summary from the live core's in-memory state, so a
    /// create can report the running session the moment `startIfNeeded()` returns — independent of when the
    /// first runtime-state write commits to SQLite through the per-core persistence queue. With that queue
    /// parked (the first runtime-state write never reaches disk), `inMemorySessionSummary()` still reports the
    /// running session with its id and launch fields. The negative check proves DB-independence: the durable
    /// runtime state is absent while the queue is parked, so the pre-fix disk poll (`readRuntimeState`) would
    /// have found nothing and, after its deadline, thrown — making a create report a ghost `ok:false` for a
    /// session that was live and running.
    func testInMemorySessionSummaryReportsRunningStateWithoutDBCommit() async throws {
        try await TerminalEngineActor.run {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let paths = TerminalSessionPaths(rootDirectory: root.path)
            try paths.ensureDirectories()
            let launchConfiguration = TerminalSessionLaunchConfiguration(
                sessionID: "session-in-memory-summary-\(UUID().uuidString)", backend: .ghosttyEmbedded, title: "shell", workingDirectory: "/tmp",
                shell: "/bin/zsh", command: nil, createdAt: "2026-06-02T00:00:00Z", workspaceID: "workspace-1", kind: .shell)
            let host = GhosttyEmbeddedSessionHost(launchConfiguration: launchConfiguration, paths: paths)
            defer { host.terminate() }

            // Park the persistence queue BEFORE start so the first runtime-state write — enqueued by
            // startIfNeeded's refreshRuntimeState(force:) — never commits to disk while we read the summary.
            let gate = host.debugHoldPersistenceQueue()
            defer { gate.signal() }

            try host.startIfNeeded()
            let summary = try XCTUnwrap(host.inMemorySessionSummary(), "a started core must produce an in-memory summary")

            XCTAssertEqual(summary.id, launchConfiguration.sessionID)
            XCTAssertEqual(summary.state, .running, "the in-memory summary must report the live running state")
            XCTAssertEqual(summary.title, "shell")
            // `workingDirectory` mirrors the live process cwd resolved during start (effectiveWorkingDirectory),
            // which legitimately differs from the launch directory once the shell process reports its own cwd;
            // assert only that it is populated.
            XCTAssertFalse(summary.workingDirectory.isEmpty)
            XCTAssertEqual(summary.backend, launchConfiguration.backend)
            XCTAssertEqual(summary.lifetimePolicy, launchConfiguration.lifetimePolicy)
            XCTAssertEqual(summary.controlSocketPath, paths.controlSocketPath)
            XCTAssertEqual(summary.outputPath, paths.outputPath)
            XCTAssertEqual(summary.launchConfiguration?.sessionID, launchConfiguration.sessionID)
            XCTAssertEqual(summary.runtimeState?.state, .running, "the summary must embed the in-memory runtime state")

            // Negative check: with the persistence queue parked, no runtime state has committed to disk, so
            // the pre-fix disk poll would have found nothing and timed out — proving the summary above is
            // served from memory, not the durable mirror.
            XCTAssertNil(
                try? TerminalSessionPersistence.readRuntimeState(paths: paths),
                "the durable runtime state must be absent while the queue is parked, proving the summary is DB-independent")
        }
    }

    /// R4-5: the broadcast that follows a stale-client expiry must advertise the post-expiry attachment state
    /// from the in-memory cache, not reseed the not-yet-committed pre-expiry rows from disk. The persistence
    /// queue is parked so the expiry's atomic detach/transfer stays uncommitted; the payload built right after
    /// the tick must already exclude the expired remote owner and show the local window as the owner. Before the
    /// fix `postAttachmentStateDidChange` invalidated the cache and the broadcast reseeded the dead owner from
    /// disk, so every payload advertised the expired client as the attached owner until the next attach/detach.
    func testStaleClientExpiryBroadcastReflectsPostExpiryOwnerBeforeDetachCommits() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = TerminalSessionPaths(rootDirectory: root.path)
        try paths.ensureDirectories()
        let launchConfiguration = TerminalSessionLaunchConfiguration(
            sessionID: "session-expiry-broadcast", backend: .ghosttyEmbedded, title: "shell", workingDirectory: "/tmp/original", shell: "/bin/zsh",
            command: "zsh", createdAt: "2026-05-17T00:00:00Z", workspaceID: "workspace-1", kind: .shell)
        try TerminalSessionPersistence.writeLaunchConfiguration(launchConfiguration, paths: paths)
        let localClient = TerminalClient(
            id: "local-window", kind: .localWindow, identity: .init(label: "Spaces window"), connectedAt: "2026-05-17T00:00:00Z")
        let remoteClient = TerminalClient(
            id: "stale-remote-owner", kind: .remoteViewer, identity: .init(label: "iPad", deviceName: "iPad"), connectedAt: "2026-05-17T00:00:00Z")
        try TerminalSessionPersistence.attachClient(
            sessionID: launchConfiguration.sessionID, client: localClient, mode: .viewer, paths: paths, attachedAt: "2026-05-17T00:00:00Z")
        try TerminalSessionPersistence.attachClient(
            sessionID: launchConfiguration.sessionID, client: remoteClient, mode: .viewer, paths: paths, attachedAt: "2026-05-17T00:00:00Z")
        try TerminalSessionPersistence.transferOwnership(
            sessionID: launchConfiguration.sessionID, newOwnerClientID: remoteClient.id, paths: paths, transferredAt: "2026-05-17T00:00:01Z")

        let expiredAt = ISO8601DateFormatter().date(from: "2026-05-17T00:01:05Z")!
        let box = TerminalEngineActor.runSynchronously { () -> Box<GhosttyEmbeddedSessionHost> in
            Box(GhosttyEmbeddedSessionHost(launchConfiguration: launchConfiguration, paths: paths))
        }
        // Park the persistence queue so the expiry's atomic detach/transfer never commits during the assertion.
        let gate = TerminalEngineActor.runSynchronously { box.value.debugHoldPersistenceQueue() }

        let (expired, payload) = TerminalEngineActor.runSynchronously { () -> ([String], GhosttyRemoteSessionStatePayload?) in
            let expired = box.value.expireStaleRemoteClientsIfNeeded(now: expiredAt)
            // WITHOUT draining: the atomic write is parked, still uncommitted. The payload must read the fresh
            // in-memory cache, not reseed the pre-expiry rows from disk.
            return (expired, box.value.debugCurrentRemoteSessionState(reason: "test"))
        }
        XCTAssertEqual(expired, [remoteClient.id], "the tick must expire the stale remote owner")
        // Sanity: the durable mirror is untouched (write parked), so the assertions below read pure in-memory state.
        XCTAssertEqual(
            try TerminalSessionPersistence.activeAttachments(paths: paths).first(where: { $0.mode == .owner })?.clientID, remoteClient.id,
            "the parked write must leave the durable owner unchanged so the payload's owner comes from the cache alone")
        let snapshot = try XCTUnwrap(payload?.attachmentSnapshot)
        XCTAssertEqual(
            snapshot.attachments.first(where: { $0.mode == .owner && $0.detachedAt == nil })?.clientID, localClient.id,
            "the payload built before the detach commits must show the transferred local owner, not the expired remote")
        XCTAssertFalse(
            snapshot.attachments.contains { $0.clientID == remoteClient.id && $0.detachedAt == nil },
            "the payload must not advertise the expired remote client as still attached")

        gate.signal()
        let drainedSnapshot = TerminalEngineActor.runSynchronously { () -> TerminalSessionAttachmentSnapshot? in
            box.value.debugDrainPersistenceQueue()
            return box.value.debugCurrentRemoteSessionState(reason: "test")?.attachmentSnapshot
        }
        let committed = try XCTUnwrap(drainedSnapshot)
        XCTAssertEqual(
            committed.attachments.first(where: { $0.mode == .owner && $0.detachedAt == nil })?.clientID, localClient.id,
            "after the write commits the payload must still show the transferred local owner")
        XCTAssertFalse(
            committed.attachments.contains { $0.clientID == remoteClient.id && $0.detachedAt == nil },
            "after the write commits the expired remote client must remain detached in the payload")
        // The durable mirror now matches the payload the engine advertised all along.
        XCTAssertEqual(
            try TerminalSessionPersistence.activeAttachments(paths: paths).first(where: { $0.mode == .owner })?.clientID, localClient.id)
        _ = box
    }

    /// R4-3: `expireClients` performs every detach and the ownership transfer inside ONE transaction, so a
    /// statement that fails after the detaches have run rolls the whole thing back — durable state is never
    /// left with the owner detached and no transfer applied. An unknown transfer target throws only after both
    /// detaches execute; the transaction must roll back so both clients remain attached and the owner unchanged.
    /// A subsequent valid call then commits every detach plus the transfer atomically. Before consolidating the
    /// detach and transfer into one transaction, a committed detach could survive a later failure, leaving
    /// durable state ownerless with no path to re-derive the transfer.
    func testExpireClientsRollsBackAllDetachesWhenOwnershipTransferFails() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = TerminalSessionPaths(rootDirectory: root.path)
        try paths.ensureDirectories()
        let launchConfiguration = TerminalSessionLaunchConfiguration(
            sessionID: "session-expire-atomic", backend: .ghosttyEmbedded, title: "shell", workingDirectory: "/tmp/original", shell: "/bin/zsh",
            command: "zsh", createdAt: "2026-05-17T00:00:00Z", workspaceID: "workspace-1", kind: .shell)
        try TerminalSessionPersistence.writeLaunchConfiguration(launchConfiguration, paths: paths)
        let localClient = TerminalClient(
            id: "local-window", kind: .localWindow, identity: .init(label: "Spaces window"), connectedAt: "2026-05-17T00:00:00Z")
        let ownerClient = TerminalClient(
            id: "stale-remote-owner", kind: .remoteViewer, identity: .init(label: "iPad", deviceName: "iPad"), connectedAt: "2026-05-17T00:00:00Z")
        let viewerClient = TerminalClient(
            id: "stale-remote-viewer", kind: .remoteViewer, identity: .init(label: "iPhone", deviceName: "iPhone"), connectedAt: "2026-05-17T00:00:00Z")
        try TerminalSessionPersistence.attachClient(
            sessionID: launchConfiguration.sessionID, client: localClient, mode: .viewer, paths: paths, attachedAt: "2026-05-17T00:00:00Z")
        try TerminalSessionPersistence.attachClient(
            sessionID: launchConfiguration.sessionID, client: viewerClient, mode: .viewer, paths: paths, attachedAt: "2026-05-17T00:00:00Z")
        try TerminalSessionPersistence.attachClient(
            sessionID: launchConfiguration.sessionID, client: ownerClient, mode: .owner, paths: paths, attachedAt: "2026-05-17T00:00:00Z")

        // The observed leases equal each client's attach time (attachClient seeds lease_refreshed_at from it),
        // so the per-client compare-and-set detaches match; this test exercises transaction atomicity, not the
        // supersession skips.
        let expiringOwner = TerminalSessionPersistence.StaleRemoteClient(clientID: ownerClient.id, leaseRefreshedAt: "2026-05-17T00:00:00Z")
        let expiringViewer = TerminalSessionPersistence.StaleRemoteClient(clientID: viewerClient.id, leaseRefreshedAt: "2026-05-17T00:00:00Z")

        // A fresh gate + empty snapshot: this test exercises transaction atomicity, not the heartbeat veto.
        let heartbeatGate = TerminalClientHeartbeatGenerationGate()

        // An unknown transfer target throws only after both detach UPDATEs have run inside the transaction.
        XCTAssertThrowsError(
            try TerminalSessionPersistence.expireClients(
                [expiringOwner, expiringViewer], transferOwnershipTo: "client-that-does-not-exist",
                sessionID: launchConfiguration.sessionID, paths: paths, detachedAt: "2026-05-17T00:01:05Z",
                heartbeatGate: heartbeatGate, observedHeartbeatGenerations: [:]))
        let afterFailure = try TerminalSessionPersistence.activeAttachments(paths: paths)
        XCTAssertTrue(
            afterFailure.contains { $0.clientID == ownerClient.id }, "the failed transfer must roll back the owner's detach — all-or-nothing")
        XCTAssertTrue(
            afterFailure.contains { $0.clientID == viewerClient.id }, "the failed transfer must roll back the viewer's detach — all-or-nothing")
        XCTAssertEqual(
            afterFailure.first(where: { $0.mode == .owner })?.clientID, ownerClient.id, "the owner must be unchanged after the rolled-back expiry")

        // A single valid call commits both detaches plus the ownership transfer atomically.
        let outcome = try TerminalSessionPersistence.expireClients(
            [expiringOwner, expiringViewer], transferOwnershipTo: localClient.id, sessionID: launchConfiguration.sessionID, paths: paths,
            detachedAt: "2026-05-17T00:01:06Z", heartbeatGate: heartbeatGate, observedHeartbeatGenerations: [:])
        XCTAssertEqual(outcome, .applied, "the valid call applied every detach and the transfer with no supersession")
        let afterSuccess = try TerminalSessionPersistence.activeAttachments(paths: paths)
        XCTAssertFalse(afterSuccess.contains { $0.clientID == ownerClient.id }, "the committed expiry must detach the stale owner")
        XCTAssertFalse(afterSuccess.contains { $0.clientID == viewerClient.id }, "the committed expiry must detach the stale viewer")
        XCTAssertEqual(
            afterSuccess.first(where: { $0.mode == .owner })?.clientID, localClient.id,
            "the committed expiry must transfer ownership to the local window")
    }

    /// R7-1 (transfer guard keys off the actual detach): a stale owner R that synchronously re-attached with a
    /// fresh lease keeps its active owner row (updated in place), so it remains the durable owner — and its
    /// per-client detach compare-and-set is skipped because the observed lease no longer matches. The ownership
    /// transfer must be skipped WITH it: the guard requires R's own detach to have landed in this transaction,
    /// not merely that R was in the input candidate list. Pre-fix the guard checked only membership in the
    /// candidate list, so it committed the transfer — demoting the re-attached owner R and promoting target A —
    /// while returning `.superseded`, a wrong transfer that survived the race.
    func testExpireClientsSkipsTransferWhenStaleOwnerReattachedWithFreshLease() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = TerminalSessionPaths(rootDirectory: root.path)
        try paths.ensureDirectories()
        let launchConfiguration = TerminalSessionLaunchConfiguration(
            sessionID: "session-r7-1-reattach", backend: .ghosttyEmbedded, title: "shell", workingDirectory: "/tmp/original", shell: "/bin/zsh",
            command: "zsh", createdAt: "2026-05-17T00:00:00Z", workspaceID: "workspace-1", kind: .shell)
        try TerminalSessionPersistence.writeLaunchConfiguration(launchConfiguration, paths: paths)
        let localViewer = TerminalClient(
            id: "local-window", kind: .localWindow, identity: .init(label: "Spaces window"), connectedAt: "2000-01-01T00:00:00Z")
        let remoteOwner = TerminalClient(
            id: "stale-remote-owner", kind: .remoteViewer, identity: .init(label: "iPad", deviceName: "iPad"), connectedAt: "2000-01-01T00:00:00Z")
        // Local window is a viewer; the remote attaches then takes ownership with a stale (2000-era) lease.
        try TerminalSessionPersistence.attachClient(
            sessionID: launchConfiguration.sessionID, client: localViewer, mode: .viewer, paths: paths, attachedAt: "2000-01-01T00:00:00Z")
        try TerminalSessionPersistence.attachClient(
            sessionID: launchConfiguration.sessionID, client: remoteOwner, mode: .viewer, paths: paths, attachedAt: "2000-01-01T00:00:00Z")
        try TerminalSessionPersistence.transferOwnership(
            sessionID: launchConfiguration.sessionID, newOwnerClientID: remoteOwner.id, paths: paths, transferredAt: "2000-01-01T00:00:01Z")

        // The expiry decision observed R's stale lease.
        let observedStaleOwner = TerminalSessionPersistence.StaleRemoteClient(
            clientID: remoteOwner.id, leaseRefreshedAt: "2000-01-01T00:00:00Z")

        // R synchronously re-attaches as owner with a FRESH lease: its active owner row is updated in place, so it
        // stays the durable owner, but its lease_refreshed_at now differs from the decision's observed lease.
        try TerminalSessionPersistence.attachClient(
            sessionID: launchConfiguration.sessionID, client: remoteOwner, mode: .owner, paths: paths, attachedAt: "2026-05-17T00:01:00Z")
        XCTAssertEqual(
            try TerminalSessionPersistence.activeAttachments(paths: paths).first(where: { $0.mode == .owner })?.clientID, remoteOwner.id,
            "sanity: R is still the durable owner after re-attaching with a fresh lease")

        let heartbeatGate = TerminalClientHeartbeatGenerationGate()
        let outcome = try TerminalSessionPersistence.expireClients(
            [observedStaleOwner], transferOwnershipTo: localViewer.id, sessionID: launchConfiguration.sessionID, paths: paths,
            detachedAt: "2026-05-17T00:01:05Z", heartbeatGate: heartbeatGate, observedHeartbeatGenerations: [:])
        XCTAssertEqual(outcome, .superseded, "the re-attached owner's detach CAS was skipped, so the decision is superseded")

        let after = try TerminalSessionPersistence.activeAttachments(paths: paths)
        XCTAssertEqual(
            after.first(where: { $0.mode == .owner })?.clientID, remoteOwner.id,
            "R must still be the durable owner — a skipped detach must not transfer ownership away from it")
        XCTAssertFalse(
            after.contains { $0.clientID == localViewer.id && $0.mode == .owner }, "the transfer target A must not have been promoted")
        XCTAssertTrue(after.contains { $0.clientID == remoteOwner.id }, "R must remain attached")
    }

    /// Replaces the SQLite database (and its WAL sidecars) with a directory so every write fails to open it,
    /// preserving the real files aside so `restoreDatabase` can bring the committed data back intact.
    private static func breakDatabase(at databasePath: String) throws {
        let fileManager = FileManager.default
        for suffix in ["", "-wal", "-shm"] {
            let path = databasePath + suffix
            if fileManager.fileExists(atPath: path) { try fileManager.moveItem(atPath: path, toPath: path + ".b4bak") }
        }
        try fileManager.createDirectory(atPath: databasePath, withIntermediateDirectories: false)
    }

    private static func restoreDatabase(at databasePath: String) throws {
        let fileManager = FileManager.default
        try? fileManager.removeItem(atPath: databasePath)
        for suffix in ["", "-wal", "-shm"] {
            let backup = databasePath + suffix + ".b4bak"
            if fileManager.fileExists(atPath: backup) { try fileManager.moveItem(atPath: backup, toPath: databasePath + suffix) }
        }
    }

    private static func renderBaseline(from payload: GhosttyRemoteSessionStatePayload, baseline: GhosttyRenderUpdateBaseline?) throws
        -> GhosttyRenderUpdateBaseline
    {
        let update = try XCTUnwrap(payload.decodedRenderUpdate)
        return try GhosttyRenderUpdateApplier.apply(update, to: baseline)
    }

    /// Mutable cursor over already-applied `GhosttyRenderUpdateBaseline` state, read and advanced by a
    /// `waitUntil` condition closure that is re-sent to the engine actor on every poll. A captured `var`
    /// there trips Swift 6's "sending risks data races" check even though the captured types are
    /// themselves `Sendable`, so the mutable state lives behind this lock-guarded box instead.
    private final class RenderUpdateCursorBox: @unchecked Sendable {
        private let lock = NSLock()
        private var nextPayloadIndex = 0
        private var baseline: GhosttyRenderUpdateBaseline?

        func applyingUpdates(_ payloads: [GhosttyRemoteSessionStatePayload]) -> String {
            lock.lock()
            defer { lock.unlock() }
            while nextPayloadIndex < payloads.count {
                let payload = payloads[nextPayloadIndex]
                nextPayloadIndex += 1
                guard let update = payload.decodedRenderUpdate else { continue }
                guard let nextBaseline = try? GhosttyRenderUpdateApplier.apply(update, to: baseline) else { continue }
                baseline = nextBaseline
            }
            guard let snapshot = baseline?.snapshot else { return "" }
            return GhosttyTerminalSnapshotLayout.plainText(for: snapshot)
        }
    }

    private static func snapshot(text: String) -> GhosttyTerminalSnapshot {
        let rows = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let columns = rows.map(\.count).max() ?? 0
        let paddedRows = rows.map { row in row.padding(toLength: columns, withPad: " ", startingAt: 0) }
        let cells = paddedRows.flatMap { row in
            row.unicodeScalars.map { scalar in
                GhosttyTerminalSnapshot.Cell(codepoint: scalar.value, foregroundRGB: 0xFFFFFF, backgroundRGB: 0x000000, flags: 0)
            }
        }
        return GhosttyTerminalSnapshot(
            columns: columns, rows: paddedRows.count, cursorColumn: 0, cursorRow: 0, cursorVisible: false, defaultForegroundRGB: 0xFFFFFF,
            defaultBackgroundRGB: 0x000000, cells: cells)
    }
}
