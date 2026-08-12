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
        defer { if let originalOverride { setenv("SPACES_DB_PATH", originalOverride, 1) } else { unsetenv("SPACES_DB_PATH") } }

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
        // A workspace-less session (e.g. an automation run) carries no workspace id; decoding must accept
        // its absence and yield nil rather than failing.
        let json = """
            {
              "sessionID": "session-automation",
              "title": "automation",
              "workingDirectory": "/tmp/work",
              "shell": "/bin/zsh",
              "command": "cat",
              "createdAt": "2026-05-08T00:00:00Z",
              "kind": "automation",
              "automationRunID": "run-1"
            }
            """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(TerminalSessionLaunchConfiguration.self, from: json)

        XCTAssertNil(decoded.workspaceID)
        XCTAssertEqual(decoded.kind, .automation)
        XCTAssertEqual(decoded.automationRunID, "run-1")
    }

    func testAutomationSessionRoundTripsThroughPersistence() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let originalOverride = ProcessInfo.processInfo.environment["SPACES_DB_PATH"]
        setenv("SPACES_DB_PATH", root.appendingPathComponent("spaces.db").path, 1)
        defer { if let originalOverride { setenv("SPACES_DB_PATH", originalOverride, 1) } else { unsetenv("SPACES_DB_PATH") } }

        let sessionID = "session-automation-roundtrip"
        let paths = try TerminalSessionPaths.forSession(id: sessionID)
        // A workspace-less automation session: no workspace id, kind .automation, attributed to its run.
        let configuration = TerminalSessionLaunchConfiguration(
            sessionID: sessionID, title: "nightly backup", workingDirectory: "/tmp/work", shell: "/bin/zsh", command: "backup.sh",
            createdAt: "2026-05-08T00:00:00Z", workspaceID: nil, kind: .automation, automationRunID: "run-42")

        try TerminalSessionPersistence.writeLaunchConfiguration(configuration, paths: paths)

        let read = try TerminalSessionPersistence.readLaunchConfiguration(paths: paths)
        XCTAssertEqual(read, configuration)
        XCTAssertNil(read.workspaceID)
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
                    createdAt: "2026-05-08T00:00:00Z", workspaceID: nil, kind: .automation, automationRunID: "run-42"), paths: paths)
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
        defer { if let originalOverride { setenv("SPACES_DB_PATH", originalOverride, 1) } else { unsetenv("SPACES_DB_PATH") } }

        let sessionID = "session-attach"
        let sessionPaths = try TerminalSessionPaths.forSession(id: sessionID)
        try writeLaunchConfiguration(sessionID: sessionID, paths: sessionPaths)
        let client = TerminalClient(
            id: "client-1", kind: .localWindow, identity: TerminalClientIdentity(label: "Spaces window"), connectedAt: "2026-05-08T00:00:00Z")

        try TerminalSessionPersistence.attachClient(
            sessionID: sessionID, client: client, mode: .owner, paths: sessionPaths, attachedAt: "2026-05-08T00:00:01Z")

        var snapshot = try TerminalSessionPersistence.readAttachmentSnapshot(paths: sessionPaths)
        // The snapshot reports the lease the attach seeded, so liveness can be judged off-device.
        XCTAssertEqual(
            snapshot.clients,
            [
                TerminalClient(
                    id: "client-1", kind: .localWindow, identity: client.identity, connectedAt: client.connectedAt,
                    leaseRefreshedAt: "2026-05-08T00:00:01Z")
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

    func testLiveAttachmentsIgnoreLeaseExpiredRemoteViewer() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let originalOverride = ProcessInfo.processInfo.environment["SPACES_DB_PATH"]
        setenv("SPACES_DB_PATH", root.appendingPathComponent("spaces.db").path, 1)
        defer { if let originalOverride { setenv("SPACES_DB_PATH", originalOverride, 1) } else { unsetenv("SPACES_DB_PATH") } }

        let sessionID = "session-stale-remote"
        let sessionPaths = try TerminalSessionPaths.forSession(id: sessionID)
        try writeLaunchConfiguration(sessionID: sessionID, paths: sessionPaths)
        let remoteClient = TerminalClient(
            id: "remote-client", kind: .remoteViewer, identity: TerminalClientIdentity(label: "iPhone"), connectedAt: "2026-05-08T00:00:00Z")

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
        defer { if let originalOverride { setenv("SPACES_DB_PATH", originalOverride, 1) } else { unsetenv("SPACES_DB_PATH") } }

        let sessionID = "session-targeted-remote"
        let sessionPaths = try TerminalSessionPaths.forSession(id: sessionID)
        try writeLaunchConfiguration(sessionID: sessionID, paths: sessionPaths)
        let remoteClient = TerminalClient(
            id: "remote-client", kind: .remoteViewer, identity: TerminalClientIdentity(label: "iPhone"), connectedAt: "2026-05-08T00:00:00Z")
        let staleRemoteClient = TerminalClient(
            id: "stale-remote-client", kind: .remoteViewer, identity: TerminalClientIdentity(label: "iPad"), connectedAt: "2026-05-08T00:00:00Z")

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

    /// The off-device cleanup path judges liveness from a wire snapshot (no DB), so the
    /// snapshot helper must apply the same lease rule: an expired remote viewer that never
    /// sent a detach is not live, a freshly leased remote viewer is, and a local window —
    /// which carries no lease — is always live while attached.
    func testSnapshotLiveAttachmentsApplyLeaseRuleOffDevice() {
        let now = ISO8601DateFormatter().date(from: "2026-05-08T00:01:01Z")!
        func snapshot(kind: TerminalClientKind, leaseRefreshedAt: String?, detachedAt: String? = nil) -> TerminalSessionAttachmentSnapshot {
            let client = TerminalClient(
                id: "client", kind: kind, identity: TerminalClientIdentity(label: "device"), connectedAt: "2026-05-08T00:00:00Z",
                leaseRefreshedAt: leaseRefreshedAt)
            let attachment = TerminalAttachment(
                sessionID: "session", clientID: "client", mode: kind == .localWindow ? .owner : .viewer, attachedAt: "2026-05-08T00:00:00Z",
                detachedAt: detachedAt)
            return TerminalSessionAttachmentSnapshot(clients: [client], attachments: [attachment])
        }

        XCTAssertTrue(snapshot(kind: .remoteViewer, leaseRefreshedAt: "2026-05-08T00:00:00Z").liveAttachments(now: now).isEmpty)
        XCTAssertEqual(snapshot(kind: .remoteViewer, leaseRefreshedAt: "2026-05-08T00:00:45Z").liveAttachments(now: now).map(\.clientID), ["client"])
        XCTAssertEqual(snapshot(kind: .localWindow, leaseRefreshedAt: nil).liveAttachments(now: now).map(\.clientID), ["client"])
        XCTAssertTrue(
            snapshot(kind: .remoteViewer, leaseRefreshedAt: "2026-05-08T00:00:45Z", detachedAt: "2026-05-08T00:00:50Z").liveAttachments(now: now)
                .isEmpty)
    }

    func testTransferOwnershipKeepsOldOwnerAttachedAsViewer() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let originalOverride = ProcessInfo.processInfo.environment["SPACES_DB_PATH"]
        setenv("SPACES_DB_PATH", root.appendingPathComponent("spaces.db").path, 1)
        defer { if let originalOverride { setenv("SPACES_DB_PATH", originalOverride, 1) } else { unsetenv("SPACES_DB_PATH") } }

        let sessionID = "session-transfer"
        let sessionPaths = try TerminalSessionPaths.forSession(id: sessionID)
        try writeLaunchConfiguration(sessionID: sessionID, paths: sessionPaths)
        let owner = TerminalClient(
            id: "client-owner", kind: .localWindow, identity: TerminalClientIdentity(label: "Owner"), connectedAt: "2026-05-08T00:00:00Z")
        let viewer = TerminalClient(
            id: "client-viewer", kind: .localWindow, identity: TerminalClientIdentity(label: "Viewer"), connectedAt: "2026-05-08T00:00:00Z")

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
        defer { if let originalOverride { setenv("SPACES_DB_PATH", originalOverride, 1) } else { unsetenv("SPACES_DB_PATH") } }

        let sessionID = "session-concurrent-owner"
        let sessionPaths = try TerminalSessionPaths.forSession(id: sessionID)
        try writeLaunchConfiguration(sessionID: sessionID, paths: sessionPaths)
        let errors = LockedErrors()

        DispatchQueue.concurrentPerform(iterations: 16) { index in
            let timestamp = String(format: "2026-05-08T00:00:%02dZ", index)
            let client = TerminalClient(
                id: "client-\(index)", kind: .remoteViewer, identity: TerminalClientIdentity(label: "Client \(index)"), connectedAt: timestamp)
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
        defer { if let originalOverride { setenv("SPACES_DB_PATH", originalOverride, 1) } else { unsetenv("SPACES_DB_PATH") } }

        let paths = try TerminalSessionPaths.forSession(id: "7399141B-E18F-429C-AD87-1FA6191DC9FE")

        XCTAssertTrue(paths.controlSocketPath.contains("/tmp/spaces-sockets-\(getuid())/"))
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
            sessionID: sessionID, reason: TerminalRemoteSessionStateReason.terminated, emittedAt: "2026-05-08T00:00:05Z", sessionStateRevision: 12,
            sessionStateFlags: 3, screenStateRevision: 12, runtimeState: runtimeState, attachmentSnapshot: TerminalSessionAttachmentSnapshot(),
            title: "final-target", workingDirectory: root.path, outputByteCount: nil, renderUpdate: Data([1, 2, 3]))

        try TerminalSessionPersistence.writeRemoteSessionState(payload, paths: paths)

        XCTAssertEqual(try TerminalSessionPersistence.readRemoteSessionState(paths: paths), payload)
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
            sessionID: sessionID, reason: TerminalRemoteSessionStateReason.terminated, emittedAt: "2026-05-08T00:00:05Z", sessionStateRevision: 1,
            sessionStateFlags: nil, screenStateRevision: 1, runtimeState: nil, attachmentSnapshot: nil, title: sessionID,
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
        let owner = TerminalClient(
            id: "owner", kind: .localWindow, identity: TerminalClientIdentity(label: "Owner"), connectedAt: "2026-05-08T00:00:00Z")
        let viewer = TerminalClient(
            id: "viewer", kind: .remoteViewer, identity: TerminalClientIdentity(label: "Viewer"), connectedAt: "2026-05-08T00:00:00Z")
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
