import XCTest

@testable import spacesterminalcore

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

final class TerminalSessionModelTests: XCTestCase {
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

    func testTerminalAttachmentSeparatesOwnerFromViewer() {
        let owner = TerminalAttachment(sessionID: "session-1", clientID: "client-owner", mode: .owner, attachedAt: "2026-05-08T00:00:00Z")
        let viewer = TerminalAttachment(sessionID: "session-1", clientID: "client-viewer", mode: .viewer, attachedAt: "2026-05-08T00:00:01Z")

        XCTAssertEqual(owner.mode, .owner)
        XCTAssertEqual(viewer.mode, .viewer)
        XCTAssertEqual(owner.sessionID, viewer.sessionID)
    }

    func testListKnownSessionsLoadsPersistedMetadata() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let originalOverride = ProcessInfo.processInfo.environment["SPACES_DB_PATH"]
        setenv("SPACES_DB_PATH", root.appendingPathComponent("spaces.db").path, 1)
        defer {
            if let originalOverride { setenv("SPACES_DB_PATH", originalOverride, 1) } else { unsetenv("SPACES_DB_PATH") }
            try? FileManager.default.removeItem(at: root)
        }

        let sessionPaths = try TerminalSessionPaths.forSession(id: "session-1")
        let metadata = TerminalSessionLaunchConfiguration(
            sessionID: "session-1", title: "session", workingDirectory: "/tmp/work", shell: "/bin/zsh", command: "cat",
            createdAt: "2026-05-08T00:00:00Z", workspaceID: "workspace-1", kind: .process)
        try TerminalSessionPersistence.writeLaunchConfiguration(metadata, paths: sessionPaths)

        let sessions = try TerminalSessionPersistence.listKnownSessions()

        XCTAssertEqual(sessions.map(\.launchConfiguration), [metadata])
        XCTAssertEqual(sessions.map(\.paths.rootDirectory), [sessionPaths.rootDirectory])
    }

    /// Sessions are listed with the root their own row stores, not one re-derived from the current
    /// profile, so a session whose root the profile does not derive stays readable through the listing.
    func testListKnownSessionsCarriesTheStoredRootDirectory() throws {
        let foreignRoot = try XCTUnwrap(databaseRoot).appendingPathComponent("elsewhere", isDirectory: true)
        let paths = TerminalSessionPaths(rootDirectory: foreignRoot.path)
        try writeLaunchConfiguration(sessionID: "session-elsewhere", paths: paths)

        let listed = try XCTUnwrap(try TerminalSessionPersistence.listKnownSessions().first)

        XCTAssertEqual(listed.paths.rootDirectory, foreignRoot.path)
        XCTAssertNoThrow(
            try TerminalSessionPersistence.readLaunchConfiguration(paths: listed.paths),
            "A listed session must be readable through the paths it was listed with.")
    }

    /// A runtime row must never outlive — or precede — its `terminal_sessions` row: a runtime row with no
    /// session row is invisible to every session-driven sweep, so nothing can repair or reclaim it.
    func testRuntimeStateWriteRequiresTheSessionRow() throws {
        let paths = try TerminalSessionPaths.forSession(id: "session-orphan-runtime")
        let runtimeState = TerminalSessionRuntimeState(
            sessionID: "session-orphan-runtime", servicePID: 123, childPID: nil, state: .running, updatedAt: "2026-05-08T00:00:00Z")

        XCTAssertThrowsError(try TerminalSessionPersistence.writeRuntimeState(runtimeState, paths: paths))
        XCTAssertThrowsError(try TerminalSessionPersistence.readRuntimeState(paths: paths))
    }

    func testLaunchConfigurationEncodesWorkspaceIDAndKind() throws {
        let configuration = TerminalSessionLaunchConfiguration(
            sessionID: "session-encoded", title: "api", workingDirectory: "/tmp/work", shell: "/bin/zsh", command: "npm run api",
            createdAt: "2026-05-08T00:00:00Z", workspaceID: "workspace-1", kind: .process)

        let data = try JSONEncoder().encode(configuration)
        let decoded = try JSONDecoder().decode(TerminalSessionLaunchConfiguration.self, from: data)

        XCTAssertEqual(decoded.workspaceID, "workspace-1")
        XCTAssertEqual(decoded.kind, .process)
    }

    func testLaunchConfigurationDefaultsLegacyMetadataToGhosttyEmbedded() throws {
        let json = """
            {
              "sessionID": "session-legacy",
              "title": "legacy",
              "workingDirectory": "/tmp/work",
              "shell": "/bin/zsh",
              "command": "cat",
              "createdAt": "2026-05-08T00:00:00Z",
              "workspaceID": "workspace-1"
            }
            """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(TerminalSessionLaunchConfiguration.self, from: json)

        XCTAssertEqual(decoded.backend, .ghosttyEmbedded)
        XCTAssertEqual(decoded.lifetimePolicy, .persistent)
        XCTAssertEqual(decoded.sessionID, "session-legacy")
        XCTAssertEqual(decoded.workspaceID, "workspace-1")
        XCTAssertEqual(decoded.kind, .shell)
    }

    func testLaunchConfigurationDecodesWithoutWorkspaceIDAsWorkspaceLess() throws {
        // Generic session persistence accepts a workspace-less shell and yields nil rather than failing.
        let json = """
            {
              "sessionID": "session-automation",
              "title": "automation",
              "workingDirectory": "/tmp/work",
              "shell": "/bin/zsh",
              "command": "cat",
              "createdAt": "2026-05-08T00:00:00Z",
              "kind": "shell"
            }
            """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(TerminalSessionLaunchConfiguration.self, from: json)

        XCTAssertNil(decoded.workspaceID)
        XCTAssertEqual(decoded.kind, .shell)
    }

    func testAutomationSessionRoundTripsThroughPersistence() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let originalOverride = ProcessInfo.processInfo.environment["SPACES_DB_PATH"]
        setenv("SPACES_DB_PATH", root.appendingPathComponent("spaces.db").path, 1)
        defer {
            if let originalOverride { setenv("SPACES_DB_PATH", originalOverride, 1) } else { unsetenv("SPACES_DB_PATH") }
            try? FileManager.default.removeItem(at: root)
        }

        let sessionID = "session-automation-roundtrip"
        let paths = try TerminalSessionPaths.forSession(id: sessionID)
        // Product automation sessions carry both their workspace and run attribution.
        let configuration = TerminalSessionLaunchConfiguration(
            sessionID: sessionID, title: "nightly backup", workingDirectory: "/tmp/work", shell: "/bin/zsh", command: "backup.sh",
            createdAt: "2026-05-08T00:00:00Z", workspaceID: "workspace-1", kind: .automation, automationRunID: "run-42")

        try TerminalSessionPersistence.writeLaunchConfiguration(configuration, paths: paths)

        let read = try TerminalSessionPersistence.readLaunchConfiguration(paths: paths)
        XCTAssertEqual(read, configuration)
        XCTAssertEqual(read.workspaceID, "workspace-1")
        XCTAssertEqual(read.kind, .automation)
        XCTAssertEqual(read.automationRunID, "run-42")
        // The same values survive the profile-wide listing query.
        XCTAssertEqual(try TerminalSessionPersistence.listKnownSessions().map(\.launchConfiguration), [configuration])
    }

    func testAutomationRunIDSurvivesBatchedRuntimeReads() throws {
        let runningID = "session-automation-running"
        let endedID = "session-automation-ended"
        for (sessionID, state) in [(runningID, TerminalSessionState.running), (endedID, .exited)] {
            let paths = try TerminalSessionPaths.forSession(id: sessionID)
            try TerminalSessionPersistence.writeLaunchConfiguration(
                TerminalSessionLaunchConfiguration(
                    sessionID: sessionID, title: "automation", workingDirectory: "/tmp/work", shell: "/bin/zsh", command: "backup.sh",
                    createdAt: "2026-05-08T00:00:00Z", workspaceID: "workspace-1", kind: .automation, automationRunID: "run-42"), paths: paths)
            try TerminalSessionPersistence.writeRuntimeState(
                TerminalSessionRuntimeState(
                    sessionID: sessionID, servicePID: 123, childPID: 456, state: state, updatedAt: "2026-05-08T00:00:01Z",
                    exitedAt: state == .exited ? "2026-05-08T00:00:01Z" : nil), paths: paths)
        }

        let running = try XCTUnwrap(try TerminalSessionPersistence.listInteractiveSessionRuntimeStates().first { $0.sessionID == runningID })
        let ended = try XCTUnwrap(try TerminalSessionPersistence.endedSessionRuntimes(sessionIDs: [endedID]).first)

        XCTAssertEqual(running.launchConfiguration.automationRunID, "run-42")
        XCTAssertEqual(ended.launchConfiguration.automationRunID, "run-42")
    }

    func testLaunchConfigurationPersistenceRoundTripsWorkspaceIDAndKind() throws {
        let sessionID = "session-metadata"
        let sessionPaths = try TerminalSessionPaths.forSession(id: sessionID)
        let configuration = TerminalSessionLaunchConfiguration(
            sessionID: sessionID, title: "agent", workingDirectory: "/tmp/work", shell: "/bin/zsh", command: "codex",
            createdAt: "2026-05-08T00:00:00Z", workspaceID: "workspace-1", kind: .agent)

        try TerminalSessionPersistence.writeLaunchConfiguration(configuration, paths: sessionPaths)

        XCTAssertEqual(try TerminalSessionPersistence.readLaunchConfiguration(paths: sessionPaths), configuration)
    }

    func testRuntimeStateDefaultsLegacyStateToGhosttyEmbedded() throws {
        let json = """
            {
              "sessionID": "session-legacy",
              "servicePID": 123,
              "childPID": 456,
              "state": "running",
              "updatedAt": "2026-05-08T00:00:00Z"
            }
            """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(TerminalSessionRuntimeState.self, from: json)

        XCTAssertEqual(decoded.backend, .ghosttyEmbedded)
        XCTAssertEqual(decoded.childPID, 456)
        XCTAssertNil(decoded.foregroundDetectedAgentKind)
        XCTAssertNil(decoded.foregroundDisplayCommand)
        XCTAssertNil(decoded.title)
        XCTAssertNil(decoded.workingDirectory)
    }

    func testRuntimeStatePersistenceRoundTripsForegroundMetadata() throws {
        let sessionID = "session-foreground-runtime"
        let paths = try TerminalSessionPaths.forSession(id: sessionID)
        try writeLaunchConfiguration(sessionID: sessionID, paths: paths)
        let runtimeState = TerminalSessionRuntimeState(
            sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: 123, childPID: 456, state: .running, updatedAt: "2026-05-08T00:00:00Z",
            title: "shell", workingDirectory: "/tmp/work", columns: 80, rows: 24, foregroundPID: 789,
            foregroundExecutablePath: "/opt/homebrew/bin/node", foregroundExecutableName: "node",
            foregroundArgv: ["node", "/opt/homebrew/lib/node_modules/@openai/codex/bin/codex.js", "--model", "gpt-5"],
            foregroundDetectedAgentKind: .codex, foregroundDisplayLabel: "Codex", foregroundDisplayCommand: "codex --model gpt-5")

        try TerminalSessionPersistence.writeRuntimeState(runtimeState, paths: paths)

        XCTAssertEqual(try TerminalSessionPersistence.readRuntimeState(paths: paths), runtimeState)
    }

    func testAttachAndDetachClientPersistsActiveOwner() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let originalOverride = ProcessInfo.processInfo.environment["SPACES_DB_PATH"]
        setenv("SPACES_DB_PATH", root.appendingPathComponent("spaces.db").path, 1)
        defer {
            if let originalOverride { setenv("SPACES_DB_PATH", originalOverride, 1) } else { unsetenv("SPACES_DB_PATH") }
            try? FileManager.default.removeItem(at: root)
        }

        let sessionID = "session-attach"
        let sessionPaths = try TerminalSessionPaths.forSession(id: sessionID)
        try writeLaunchConfiguration(sessionID: sessionID, paths: sessionPaths)
        let client = TerminalClient(
            id: "client-1", kind: .local, identity: TerminalClientIdentity(label: "Spaces window"), connectedAt: "2026-05-08T00:00:00Z")

        try TerminalSessionPersistence.attachClient(
            sessionID: sessionID, client: client, mode: .owner, paths: sessionPaths, attachedAt: "2026-05-08T00:00:01Z")

        var snapshot = try TerminalSessionPersistence.readAttachmentSnapshot(paths: sessionPaths)
        // The snapshot reports the lease the attach seeded, so liveness can be judged off-device.
        XCTAssertEqual(
            snapshot.clients,
            [
                TerminalClient(
                    id: "client-1", kind: .local, identity: client.identity, connectedAt: client.connectedAt, leaseRefreshedAt: "2026-05-08T00:00:01Z"
                )
            ])
        XCTAssertEqual(snapshot.attachments.count, 1)
        XCTAssertEqual(snapshot.attachments.first?.mode, .owner)
        XCTAssertEqual(try TerminalSessionPersistence.activeAttachments(paths: sessionPaths).count, 1)

        try TerminalSessionPersistence.detachClient(id: client.id, paths: sessionPaths, detachedAt: "2026-05-08T00:00:02Z")

        snapshot = try TerminalSessionPersistence.readAttachmentSnapshot(paths: sessionPaths)
        XCTAssertEqual(snapshot.clients.first?.disconnectedAt, "2026-05-08T00:00:02Z")
        XCTAssertEqual(snapshot.attachments.first?.detachedAt, "2026-05-08T00:00:02Z")
        XCTAssertTrue(try TerminalSessionPersistence.activeAttachments(paths: sessionPaths).isEmpty)
    }

    /// `clearAllClientsAndAttachments` is the daemon-start/handoff-resume safeguard against a ghost owner
    /// attachment: every `terminal_clients`/`terminal_attachments` row is wiped, on the theory that no
    /// client transport survives a process replacing itself. This test proves the two halves of that
    /// contract that matter for handoff specifically: the wipe reaches every session in the database (not
    /// just one root directory, unlike most of this file's other persistence calls), while the session
    /// records themselves — the launch configuration and runtime state a handoff exists to carry forward,
    /// standing in for the PTY/child-process survival a unit test cannot observe directly — are left
    /// completely untouched. A regression that scoped the delete to one session, or that accidentally
    /// touched `terminal_sessions`, would fail this test; a no-op stub for `clearAllClientsAndAttachments`
    /// would also fail it, since the clients/attachments would still read back non-empty.
    func testClearAllClientsAndAttachmentsWipesRowsButLeavesSessionsIntact() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let originalOverride = ProcessInfo.processInfo.environment["SPACES_DB_PATH"]
        setenv("SPACES_DB_PATH", root.appendingPathComponent("spaces.db").path, 1)
        defer {
            if let originalOverride { setenv("SPACES_DB_PATH", originalOverride, 1) } else { unsetenv("SPACES_DB_PATH") }
            try? FileManager.default.removeItem(at: root)
        }

        // Two distinct sessions, each with an attached owner, to prove the wipe is not scoped to a single
        // root directory the way most other persistence calls in this file are.
        let firstSessionID = "session-clear-1"
        let secondSessionID = "session-clear-2"
        let firstPaths = try TerminalSessionPaths.forSession(id: firstSessionID)
        let secondPaths = try TerminalSessionPaths.forSession(id: secondSessionID)
        try writeLaunchConfiguration(sessionID: firstSessionID, paths: firstPaths)
        try writeLaunchConfiguration(sessionID: secondSessionID, paths: secondPaths)

        let runtimeState = TerminalSessionRuntimeState(
            sessionID: firstSessionID, backend: .ghosttyEmbedded, servicePID: 4242, childPID: 4343, state: .running, updatedAt: "2026-05-08T00:00:00Z"
        )
        try TerminalSessionPersistence.writeRuntimeState(runtimeState, paths: firstPaths)

        let firstClient = TerminalClient(
            id: "client-clear-1", kind: .local, identity: TerminalClientIdentity(label: "Spaces window"), connectedAt: "2026-05-08T00:00:00Z")
        let secondClient = TerminalClient(
            id: "client-clear-2", kind: .remote, identity: TerminalClientIdentity(label: "Paired Mac"), connectedAt: "2026-05-08T00:00:00Z")
        try TerminalSessionPersistence.attachClient(
            sessionID: firstSessionID, client: firstClient, mode: .owner, paths: firstPaths, attachedAt: "2026-05-08T00:00:01Z")
        try TerminalSessionPersistence.attachClient(
            sessionID: secondSessionID, client: secondClient, mode: .owner, paths: secondPaths, attachedAt: "2026-05-08T00:00:01Z")

        XCTAssertEqual(try TerminalSessionPersistence.activeAttachments(paths: firstPaths).count, 1)
        XCTAssertEqual(try TerminalSessionPersistence.activeAttachments(paths: secondPaths).count, 1)

        try TerminalSessionPersistence.clearAllClientsAndAttachments()

        let firstSnapshot = try TerminalSessionPersistence.readAttachmentSnapshot(paths: firstPaths)
        let secondSnapshot = try TerminalSessionPersistence.readAttachmentSnapshot(paths: secondPaths)
        XCTAssertTrue(firstSnapshot.clients.isEmpty)
        XCTAssertTrue(firstSnapshot.attachments.isEmpty)
        XCTAssertTrue(secondSnapshot.clients.isEmpty)
        XCTAssertTrue(secondSnapshot.attachments.isEmpty)
        XCTAssertTrue(try TerminalSessionPersistence.activeAttachments(paths: firstPaths).isEmpty)
        XCTAssertTrue(try TerminalSessionPersistence.activeAttachments(paths: secondPaths).isEmpty)

        // The session records themselves — what a handoff resume rebuilds the PTY and pane state from —
        // are untouched by the clear.
        XCTAssertEqual(try TerminalSessionPersistence.readLaunchConfiguration(paths: firstPaths).sessionID, firstSessionID)
        XCTAssertEqual(try TerminalSessionPersistence.readLaunchConfiguration(paths: secondPaths).sessionID, secondSessionID)
        XCTAssertEqual(try TerminalSessionPersistence.readRuntimeState(paths: firstPaths), runtimeState)
    }

    func testLiveAttachmentsIgnoreLeaseExpiredRemoteViewer() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let originalOverride = ProcessInfo.processInfo.environment["SPACES_DB_PATH"]
        setenv("SPACES_DB_PATH", root.appendingPathComponent("spaces.db").path, 1)
        defer {
            if let originalOverride { setenv("SPACES_DB_PATH", originalOverride, 1) } else { unsetenv("SPACES_DB_PATH") }
            try? FileManager.default.removeItem(at: root)
        }

        let sessionID = "session-stale-remote"
        let sessionPaths = try TerminalSessionPaths.forSession(id: sessionID)
        try writeLaunchConfiguration(sessionID: sessionID, paths: sessionPaths)
        let remoteClient = TerminalClient(
            id: "remote-client", kind: .remote, identity: TerminalClientIdentity(label: "iPhone"), connectedAt: "2026-05-08T00:00:00Z")

        try TerminalSessionPersistence.attachClient(
            sessionID: sessionID, client: remoteClient, mode: .viewer, paths: sessionPaths, attachedAt: "2026-05-08T00:00:00Z")

        let now = ISO8601DateFormatter().date(from: "2026-05-08T00:01:01Z")!
        XCTAssertTrue(try TerminalSessionPersistence.liveAttachments(paths: sessionPaths, now: now).isEmpty)
        XCTAssertEqual(try TerminalSessionPersistence.staleRemoteClientIDs(paths: sessionPaths, now: now), ["remote-client"])
    }

    func testTouchClientKeepsOnlySpecifiedRemoteViewerLeaseAlive() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let originalOverride = ProcessInfo.processInfo.environment["SPACES_DB_PATH"]
        setenv("SPACES_DB_PATH", root.appendingPathComponent("spaces.db").path, 1)
        defer {
            if let originalOverride { setenv("SPACES_DB_PATH", originalOverride, 1) } else { unsetenv("SPACES_DB_PATH") }
            try? FileManager.default.removeItem(at: root)
        }

        let sessionID = "session-targeted-remote"
        let sessionPaths = try TerminalSessionPaths.forSession(id: sessionID)
        try writeLaunchConfiguration(sessionID: sessionID, paths: sessionPaths)
        let remoteClient = TerminalClient(
            id: "remote-client", kind: .remote, identity: TerminalClientIdentity(label: "iPhone"), connectedAt: "2026-05-08T00:00:00Z")
        let staleRemoteClient = TerminalClient(
            id: "stale-remote-client", kind: .remote, identity: TerminalClientIdentity(label: "iPad"), connectedAt: "2026-05-08T00:00:00Z")

        try TerminalSessionPersistence.attachClient(
            sessionID: sessionID, client: remoteClient, mode: .viewer, paths: sessionPaths, attachedAt: "2026-05-08T00:00:00Z")
        try TerminalSessionPersistence.attachClient(
            sessionID: sessionID, client: staleRemoteClient, mode: .viewer, paths: sessionPaths, attachedAt: "2026-05-08T00:00:00Z")
        try TerminalSessionPersistence.touchClient(id: remoteClient.id, paths: sessionPaths, touchedAt: "2026-05-08T00:00:45Z")

        let now = ISO8601DateFormatter().date(from: "2026-05-08T00:01:01Z")!
        XCTAssertEqual(try TerminalSessionPersistence.liveAttachments(paths: sessionPaths, now: now).map(\.clientID), [remoteClient.id])
        XCTAssertEqual(try TerminalSessionPersistence.staleRemoteClientIDs(paths: sessionPaths, now: now), [staleRemoteClient.id])
        let snapshot = try TerminalSessionPersistence.readAttachmentSnapshot(paths: sessionPaths)
        XCTAssertEqual(snapshot.clients.first(where: { $0.id == remoteClient.id })?.connectedAt, "2026-05-08T00:00:00Z")
        XCTAssertEqual(snapshot.clients.first(where: { $0.id == staleRemoteClient.id })?.connectedAt, "2026-05-08T00:00:00Z")
    }

    /// The off-device cleanup path judges liveness from a wire snapshot (no DB), so the snapshot helper
    /// must apply the same lease rule to every kind alike: an expired lease that never sent a detach is
    /// not live, a freshly leased one is, and no kind is exempt — a `.local` client with no lease at all
    /// (never attached with one seeded, and never touched) is not live either, exactly like a `.remote`
    /// one in the same state. A regression that reintroduces a `.local` exemption would make the third
    /// assertion below observe a live attachment where this asserts none.
    func testSnapshotLiveAttachmentsApplyLeaseRuleOffDevice() {
        let now = ISO8601DateFormatter().date(from: "2026-05-08T00:01:01Z")!
        func snapshot(kind: TerminalClientKind, leaseRefreshedAt: String?, detachedAt: String? = nil) -> TerminalSessionAttachmentSnapshot {
            let client = TerminalClient(
                id: "client", kind: kind, identity: TerminalClientIdentity(label: "device"), connectedAt: "2026-05-08T00:00:00Z",
                leaseRefreshedAt: leaseRefreshedAt)
            let attachment = TerminalAttachment(
                sessionID: "session", clientID: "client", mode: kind == .local ? .owner : .viewer, attachedAt: "2026-05-08T00:00:00Z",
                detachedAt: detachedAt)
            return TerminalSessionAttachmentSnapshot(clients: [client], attachments: [attachment])
        }

        XCTAssertTrue(snapshot(kind: .remote, leaseRefreshedAt: "2026-05-08T00:00:00Z").liveAttachments(now: now).isEmpty)
        XCTAssertEqual(snapshot(kind: .remote, leaseRefreshedAt: "2026-05-08T00:00:45Z").liveAttachments(now: now).map(\.clientID), ["client"])
        XCTAssertTrue(snapshot(kind: .local, leaseRefreshedAt: nil).liveAttachments(now: now).isEmpty)
        XCTAssertTrue(snapshot(kind: .local, leaseRefreshedAt: "2026-05-08T00:00:00Z").liveAttachments(now: now).isEmpty)
        XCTAssertEqual(snapshot(kind: .local, leaseRefreshedAt: "2026-05-08T00:00:45Z").liveAttachments(now: now).map(\.clientID), ["client"])
        XCTAssertTrue(
            snapshot(kind: .remote, leaseRefreshedAt: "2026-05-08T00:00:45Z", detachedAt: "2026-05-08T00:00:50Z").liveAttachments(now: now).isEmpty)
    }

    /// The regression this closes: a session hosted by one device whose owner is a `.local` pane on
    /// that same device must not stay ownerless-blocking forever just because the owning client stopped
    /// heartbeating. A pane that keeps refreshing its lease across a span far longer than a single
    /// expiry window stays live throughout — proving the fix does not merely shorten the window but
    /// actually judges `.local` clients by it, the same way `.remote` ones always were.
    func testIdleLocalOwnerStaysLiveAcrossRepeatedLeaseTouches() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let originalOverride = ProcessInfo.processInfo.environment["SPACES_DB_PATH"]
        setenv("SPACES_DB_PATH", root.appendingPathComponent("spaces.db").path, 1)
        defer {
            if let originalOverride { setenv("SPACES_DB_PATH", originalOverride, 1) } else { unsetenv("SPACES_DB_PATH") }
            try? FileManager.default.removeItem(at: root)
        }

        let sessionID = "session-idle-local-owner"
        let sessionPaths = try TerminalSessionPaths.forSession(id: sessionID)
        try writeLaunchConfiguration(sessionID: sessionID, paths: sessionPaths)
        let localOwner = TerminalClient(
            id: "local-owner", kind: .local, identity: TerminalClientIdentity(label: "Spaces window"), connectedAt: "2026-05-08T00:00:00Z")
        try TerminalSessionPersistence.attachClient(
            sessionID: sessionID, client: localOwner, mode: .owner, paths: sessionPaths, attachedAt: "2026-05-08T00:00:00Z")

        // Five heartbeats spaced 20s apart (the pane's own cadence — see
        // `TerminalPaneService.RemoteTerminalWindowClientStore.heartbeatInterval`) span 100s, comfortably
        // past the 60s `remoteClientLeaseInterval`. At every point along the way the owner must read as
        // live and never as a candidate for expiry.
        let start = ISO8601DateFormatter().date(from: "2026-05-08T00:00:00Z")!
        for tick in 1...5 {
            let touchedAt = start.addingTimeInterval(TimeInterval(tick) * 20)
            try TerminalSessionPersistence.touchClient(
                id: localOwner.id, paths: sessionPaths, touchedAt: ISO8601DateFormatter().string(from: touchedAt))
            XCTAssertEqual(
                try TerminalSessionPersistence.liveAttachments(paths: sessionPaths, now: touchedAt).map(\.clientID), [localOwner.id],
                "the idle owner must still be live right after heartbeat \(tick)")
            XCTAssertTrue(
                try TerminalSessionPersistence.staleRemoteClientIDs(paths: sessionPaths, now: touchedAt).isEmpty,
                "a heartbeating owner must never appear as a stale-expiry candidate")
        }

        // Contrast, and the control that stops this test from being tautological: the loop above proves the
        // owner stays live only because each tick refreshed the lease, so let the lease lapse instead. The
        // last touch landed at start+100s; asked about a moment a full expiry interval beyond that, the very
        // same attachment must read as gone. Without this, a `liveAttachments` that returned every attached
        // client unconditionally would satisfy every assertion above.
        let pastExpiry = start.addingTimeInterval(100 + TerminalSessionPersistence.remoteClientLeaseInterval + 1)
        XCTAssertTrue(
            try TerminalSessionPersistence.liveAttachments(paths: sessionPaths, now: pastExpiry).isEmpty,
            "an owner that stopped heartbeating must stop reading as live once its lease lapses")
        XCTAssertEqual(
            try TerminalSessionPersistence.staleRemoteClientIDs(paths: sessionPaths, now: pastExpiry), [localOwner.id],
            "and it must become a stale-expiry candidate, exactly as a remote client would")
    }

    func testTransferOwnershipKeepsOldOwnerAttachedAsViewer() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let originalOverride = ProcessInfo.processInfo.environment["SPACES_DB_PATH"]
        setenv("SPACES_DB_PATH", root.appendingPathComponent("spaces.db").path, 1)
        defer {
            if let originalOverride { setenv("SPACES_DB_PATH", originalOverride, 1) } else { unsetenv("SPACES_DB_PATH") }
            try? FileManager.default.removeItem(at: root)
        }

        let sessionID = "session-transfer"
        let sessionPaths = try TerminalSessionPaths.forSession(id: sessionID)
        try writeLaunchConfiguration(sessionID: sessionID, paths: sessionPaths)
        let owner = TerminalClient(
            id: "client-owner", kind: .local, identity: TerminalClientIdentity(label: "Owner"), connectedAt: "2026-05-08T00:00:00Z")
        let viewer = TerminalClient(
            id: "client-viewer", kind: .local, identity: TerminalClientIdentity(label: "Viewer"), connectedAt: "2026-05-08T00:00:00Z")

        try TerminalSessionPersistence.attachClient(
            sessionID: sessionID, client: owner, mode: .owner, paths: sessionPaths, attachedAt: "2026-05-08T00:00:01Z")
        try TerminalSessionPersistence.attachClient(
            sessionID: sessionID, client: viewer, mode: .viewer, paths: sessionPaths, attachedAt: "2026-05-08T00:00:02Z")

        try TerminalSessionPersistence.transferOwnership(
            sessionID: sessionID, newOwnerClientID: viewer.id, paths: sessionPaths, transferredAt: "2026-05-08T00:00:03Z")

        let active = try TerminalSessionPersistence.activeAttachments(paths: sessionPaths)
        XCTAssertEqual(active.count, 2)
        XCTAssertEqual(active.first(where: { $0.clientID == owner.id })?.mode, .viewer)
        XCTAssertEqual(active.first(where: { $0.clientID == viewer.id })?.mode, .owner)
        XCTAssertEqual(active.filter { $0.mode == .owner }.count, 1)
    }

    func testConcurrentOwnerAttachmentsKeepExactlyOneActiveOwner() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let originalOverride = ProcessInfo.processInfo.environment["SPACES_DB_PATH"]
        setenv("SPACES_DB_PATH", root.appendingPathComponent("spaces.db").path, 1)
        defer {
            if let originalOverride { setenv("SPACES_DB_PATH", originalOverride, 1) } else { unsetenv("SPACES_DB_PATH") }
            try? FileManager.default.removeItem(at: root)
        }

        let sessionID = "session-concurrent-owner"
        let sessionPaths = try TerminalSessionPaths.forSession(id: sessionID)
        try writeLaunchConfiguration(sessionID: sessionID, paths: sessionPaths)
        let errors = LockedErrors()

        DispatchQueue.concurrentPerform(iterations: 16) { index in
            let timestamp = String(format: "2026-05-08T00:00:%02dZ", index)
            let client = TerminalClient(
                id: "client-\(index)", kind: .remote, identity: TerminalClientIdentity(label: "Client \(index)"), connectedAt: timestamp)
            do {
                try TerminalSessionPersistence.attachClient(
                    sessionID: sessionID, client: client, mode: .owner, paths: sessionPaths, attachedAt: timestamp)
            } catch { errors.append(error) }
        }

        XCTAssertTrue(errors.values.isEmpty, "\(errors.values)")
        let activeOwners = try TerminalSessionPersistence.activeAttachments(paths: sessionPaths).filter { $0.mode == .owner }
        XCTAssertEqual(activeOwners.count, 1)
    }

    func testSessionSocketPathUsesShortSharedSocketsDirectory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let originalOverride = ProcessInfo.processInfo.environment["SPACES_DB_PATH"]
        setenv("SPACES_DB_PATH", root.appendingPathComponent("spaces.db").path, 1)
        defer {
            if let originalOverride { setenv("SPACES_DB_PATH", originalOverride, 1) } else { unsetenv("SPACES_DB_PATH") }
            try? FileManager.default.removeItem(at: root)
        }

        let paths = try TerminalSessionPaths.forSession(id: "7399141B-E18F-429C-AD87-1FA6191DC9FE")

        XCTAssertEqual(URL(fileURLWithPath: paths.controlSocketPath).deletingLastPathComponent().path, try SpacesSocketPaths.secureSocketRoot().path)
        XCTAssertTrue(paths.controlSocketPath.hasPrefix("/tmp/spaces-"))
        XCTAssertFalse(paths.controlSocketPath.contains("/terminal/sessions/7399141B-E18F-429C-AD87-1FA6191DC9FE/"))
        XCTAssertLessThan(paths.controlSocketPath.utf8.count, 104)
    }

    func testSessionPathsRejectUnsafeSessionIDs() throws {
        XCTAssertThrowsError(try TerminalSessionPaths.forSession(id: "../outside"))
        XCTAssertThrowsError(try TerminalSessionPaths.forSession(id: "nested/session"))
        XCTAssertThrowsError(try TerminalSessionPaths.forSession(id: " session "))
        XCTAssertThrowsError(try TerminalSessionPaths.forSession(id: "."))
    }

    func testRemoteSessionStatePersistsFinalPayload() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = TerminalSessionPaths(rootDirectory: root.path)
        let sessionID = "session-final-state"
        try writeLaunchConfiguration(sessionID: sessionID, paths: paths)
        let runtimeState = TerminalSessionRuntimeState(
            sessionID: sessionID, servicePID: 123, childPID: 456, state: .exited, updatedAt: "2026-05-08T00:00:05Z", exitedAt: "2026-05-08T00:00:05Z",
            title: "final-target", workingDirectory: root.path, columns: 80, rows: 24)
        try TerminalSessionPersistence.writeRuntimeState(runtimeState, paths: paths)
        let payload = GhosttyRemoteSessionStatePayload(
            sessionID: sessionID, reason: TerminalRemoteSessionStateReason.terminated.rawValue, emittedAt: "2026-05-08T00:00:05Z",
            sessionStateRevision: 12, sessionStateFlags: 3, screenStateRevision: 12, runtimeState: runtimeState,
            attachmentSnapshot: TerminalSessionAttachmentSnapshot(), title: "final-target", workingDirectory: root.path, outputByteCount: nil,
            renderUpdate: Data([1, 2, 3]))

        try TerminalSessionPersistence.writeRemoteSessionState(payload, paths: paths)

        XCTAssertEqual(try TerminalSessionPersistence.readRemoteSessionState(paths: paths), payload)
    }

    /// A final payload stored by a build that kept the session's whole attachment history is projected
    /// on the way out, so a retained ended session does not keep replaying those rows to every reader.
    func testStoredFinalPayloadIsProjectedToLiveRowsOnRead() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = TerminalSessionPaths(rootDirectory: root.path)
        let sessionID = "session-historical-clients"
        try writeLaunchConfiguration(sessionID: sessionID, paths: paths)
        let runtimeState = TerminalSessionRuntimeState(
            sessionID: sessionID, servicePID: 123, childPID: 456, state: .exited, updatedAt: "2026-05-08T00:00:05Z", exitedAt: "2026-05-08T00:00:05Z",
            title: "final-target", workingDirectory: root.path, columns: 80, rows: 24)
        try TerminalSessionPersistence.writeRuntimeState(runtimeState, paths: paths)
        let history = TerminalSessionAttachmentSnapshot(
            clients: (0..<20).map { index in
                TerminalClient(
                    id: "client-\(index)", kind: .remote, identity: TerminalClientIdentity(label: "iPhone"), connectedAt: "2026-05-08T00:00:00Z",
                    disconnectedAt: "2026-05-08T00:00:01Z")
            },
            attachments: (0..<20).map { index in
                TerminalAttachment(
                    id: "attachment-\(index)", sessionID: sessionID, clientID: "client-\(index)", mode: .viewer, attachedAt: "2026-05-08T00:00:00Z",
                    detachedAt: "2026-05-08T00:00:01Z")
            })
        let payload = GhosttyRemoteSessionStatePayload(
            sessionID: sessionID, reason: TerminalRemoteSessionStateReason.terminated.rawValue, emittedAt: "2026-05-08T00:00:05Z",
            sessionStateRevision: 12, sessionStateFlags: 3, screenStateRevision: 12, runtimeState: runtimeState, attachmentSnapshot: history,
            title: "final-target", workingDirectory: root.path, outputByteCount: nil, renderUpdate: Data([1, 2, 3]))

        try TerminalSessionPersistence.writeRemoteSessionState(payload, paths: paths)

        let read = try TerminalSessionPersistence.readRemoteSessionState(paths: paths)
        XCTAssertEqual(read.attachmentSnapshot?.clients.count, 0)
        XCTAssertEqual(read.attachmentSnapshot?.attachments.count, 0)
        XCTAssertEqual(read, payload.withLiveWireAttachmentProjection())
        XCTAssertEqual(read.renderUpdate, Data([1, 2, 3]))
        XCTAssertEqual(read.title, payload.title)
        XCTAssertEqual(read.sessionStateRevision, payload.sessionStateRevision)
    }

    /// Whether an ended pane can replay its final frame is answered from the stored flag, so a reader does
    /// not decode the whole payload to test one field. A payload carrying a full frame reports available;
    /// one without a replayable frame reports unavailable.
    func testFinalRenderAvailabilityIsReadableWithoutDecodingThePayload() throws {
        let withFrame = "session-with-frame"
        let withoutFrame = "session-without-frame"
        let framePaths = try TerminalSessionPaths.forSession(id: withFrame)
        let framelessPaths = try TerminalSessionPaths.forSession(id: withoutFrame)
        try writeLaunchConfiguration(sessionID: withFrame, paths: framePaths)
        try writeLaunchConfiguration(sessionID: withoutFrame, paths: framelessPaths)
        let snapshot = GhosttyTerminalSnapshot(
            columns: 2, rows: 1, cursorColumn: 0, cursorRow: 0, cursorVisible: false, defaultForegroundRGB: 0xEEEEEE, defaultBackgroundRGB: 0x101010,
            cells: [
                GhosttyTerminalSnapshot.Cell(codepoint: 0x68, foregroundRGB: 0xEEEEEE, backgroundRGB: 0x101010, flags: 0),
                GhosttyTerminalSnapshot.Cell(codepoint: 0x69, foregroundRGB: 0xEEEEEE, backgroundRGB: 0x101010, flags: 0),
            ])
        let renderUpdate = try GhosttyRenderUpdateBinaryCodec.encode(.full(GhosttyRenderFrame(sessionRevision: 1, ownerEpoch: 1, snapshot: snapshot)))

        try TerminalSessionPersistence.writeRemoteSessionState(payload(sessionID: withFrame, renderUpdate: renderUpdate), paths: framePaths)
        try TerminalSessionPersistence.writeRemoteSessionState(payload(sessionID: withoutFrame, renderUpdate: nil), paths: framelessPaths)

        XCTAssertTrue(try TerminalSessionPersistence.hasFinalRender(paths: framePaths))
        XCTAssertFalse(try TerminalSessionPersistence.hasFinalRender(paths: framelessPaths))
        XCTAssertEqual(try TerminalSessionPersistence.sessionIDsWithFinalRender(), [withFrame])
    }

    private func payload(sessionID: String, renderUpdate: Data?) -> GhosttyRemoteSessionStatePayload {
        GhosttyRemoteSessionStatePayload(
            sessionID: sessionID, reason: TerminalRemoteSessionStateReason.terminated.rawValue, emittedAt: "2026-05-08T00:00:05Z",
            sessionStateRevision: 1, sessionStateFlags: nil, screenStateRevision: 1, runtimeState: nil, attachmentSnapshot: nil, title: sessionID,
            workingDirectory: "/tmp/work", outputByteCount: nil, renderUpdate: renderUpdate)
    }

    func testPendingAgentSignalsCanBeAcknowledged() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = TerminalSessionPaths(rootDirectory: root.path)
        let sessionID = "session-agent-signal"
        try writeLaunchConfiguration(sessionID: sessionID, paths: paths)
        let event = TerminalServiceAgentSignalEvent(
            id: "event-1", sessionID: sessionID, workspaceID: "workspace-1", workspacePath: "/tmp/workspace", type: "blocked", provider: "spaces",
            label: "Mock Agent", terminalTrackingID: sessionID, environmentKeys: ["SPACES_WORKSPACE_ID", "SPACES_TERMINAL_TRACKING_ID"],
            createdAt: "2026-05-08T00:00:00Z")

        try TerminalSessionPersistence.appendPendingAgentSignal(event, paths: paths)

        XCTAssertEqual(try TerminalSessionPersistence.pendingAgentSignals(sessionID: sessionID, paths: paths), [event])

        try TerminalSessionPersistence.acknowledgeAgentSignals(
            ids: [event.id], sessionID: sessionID, paths: paths, acknowledgedAt: "2026-05-08T00:00:01Z")

        XCTAssertTrue(try TerminalSessionPersistence.pendingAgentSignals(sessionID: sessionID, paths: paths).isEmpty)
    }

    func testDetachActiveClientsMarksClientsDisconnectedAndAttachmentsDetached() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = TerminalSessionPaths(rootDirectory: root.path)
        let sessionID = "session-detach-all"
        try writeLaunchConfiguration(sessionID: sessionID, paths: paths)
        let owner = TerminalClient(id: "owner", kind: .local, identity: TerminalClientIdentity(label: "Owner"), connectedAt: "2026-05-08T00:00:00Z")
        let viewer = TerminalClient(
            id: "viewer", kind: .remote, identity: TerminalClientIdentity(label: "Viewer"), connectedAt: "2026-05-08T00:00:00Z")
        try TerminalSessionPersistence.attachClient(
            sessionID: sessionID, client: owner, mode: .owner, paths: paths, attachedAt: "2026-05-08T00:00:01Z")
        try TerminalSessionPersistence.attachClient(
            sessionID: sessionID, client: viewer, mode: .viewer, paths: paths, attachedAt: "2026-05-08T00:00:02Z")

        try TerminalSessionPersistence.detachActiveClients(paths: paths, detachedAt: "2026-05-08T00:00:03Z")

        let snapshot = try TerminalSessionPersistence.readAttachmentSnapshot(paths: paths)
        XCTAssertTrue(try TerminalSessionPersistence.activeAttachments(paths: paths).isEmpty)
        XCTAssertEqual(Set(snapshot.clients.compactMap(\.disconnectedAt)), ["2026-05-08T00:00:03Z"])
        XCTAssertEqual(Set(snapshot.attachments.compactMap(\.detachedAt)), ["2026-05-08T00:00:03Z"])
    }

    private func writeLaunchConfiguration(sessionID: String, paths: TerminalSessionPaths) throws {
        try TerminalSessionPersistence.writeLaunchConfiguration(
            TerminalSessionLaunchConfiguration(
                sessionID: sessionID, title: sessionID, workingDirectory: "/tmp/work", shell: "/bin/zsh", command: nil,
                createdAt: "2026-05-08T00:00:00Z", workspaceID: "workspace-1", kind: .shell), paths: paths)
    }
}

private final class LockedErrors: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [any Error] = []

    var values: [any Error] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ error: any Error) {
        lock.lock()
        storage.append(error)
        lock.unlock()
    }
}
