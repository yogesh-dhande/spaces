import XCTest

@testable import spacesterminalcore

final class TerminalSessionModelTests: XCTestCase {
    func testTerminalSessionSupportsTmuxFreeOwnerModel() {
        let session = TerminalSession(
            workspaceID: "workspace-1", kind: .process, title: "api", workingDirectory: "/tmp/project", command: "npm run api", shell: nil,
            ownerClientID: "client-1", state: .running, createdAt: "2026-05-08T00:00:00Z", updatedAt: "2026-05-08T00:00:00Z")

        XCTAssertEqual(session.workspaceID, "workspace-1")
        XCTAssertEqual(session.kind, .process)
        XCTAssertEqual(session.ownerClientID, "client-1")
        XCTAssertEqual(session.state, .running)
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
            createdAt: "2026-05-08T00:00:00Z")
        try TerminalSessionPersistence.writeLaunchConfiguration(metadata, paths: sessionPaths)

        let sessions = try TerminalSessionPersistence.listKnownSessions()

        XCTAssertEqual(sessions, [metadata])
    }

    func testLaunchConfigurationDefaultsLegacyMetadataToGhosttyEmbedded() throws {
        let json = """
            {
              "sessionID": "session-legacy",
              "title": "legacy",
              "workingDirectory": "/tmp/work",
              "shell": "/bin/zsh",
              "command": "cat",
              "createdAt": "2026-05-08T00:00:00Z"
            }
            """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(TerminalSessionLaunchConfiguration.self, from: json)

        XCTAssertEqual(decoded.backend, .ghosttyEmbedded)
        XCTAssertEqual(decoded.sessionID, "session-legacy")
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
    }

    func testAttachAndDetachClientPersistsActiveOwner() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let originalOverride = ProcessInfo.processInfo.environment["SPACES_DB_PATH"]
        setenv("SPACES_DB_PATH", root.appendingPathComponent("spaces.db").path, 1)
        defer { if let originalOverride { setenv("SPACES_DB_PATH", originalOverride, 1) } else { unsetenv("SPACES_DB_PATH") } }

        let sessionID = "session-attach"
        let sessionPaths = try TerminalSessionPaths.forSession(id: sessionID)
        let client = TerminalClient(
            id: "client-1", kind: .localWindow, identity: TerminalClientIdentity(label: "Spaces window"), connectedAt: "2026-05-08T00:00:00Z")

        try TerminalSessionPersistence.attachClient(
            sessionID: sessionID, client: client, mode: .owner, paths: sessionPaths, attachedAt: "2026-05-08T00:00:01Z")

        var snapshot = try TerminalSessionPersistence.readAttachmentSnapshot(paths: sessionPaths)
        XCTAssertEqual(snapshot.clients, [client])
        XCTAssertEqual(snapshot.attachments.count, 1)
        XCTAssertEqual(snapshot.attachments.first?.mode, .owner)
        XCTAssertEqual(try TerminalSessionPersistence.activeAttachments(paths: sessionPaths).count, 1)

        try TerminalSessionPersistence.detachClient(id: client.id, paths: sessionPaths, detachedAt: "2026-05-08T00:00:02Z")

        snapshot = try TerminalSessionPersistence.readAttachmentSnapshot(paths: sessionPaths)
        XCTAssertEqual(snapshot.clients.first?.disconnectedAt, "2026-05-08T00:00:02Z")
        XCTAssertEqual(snapshot.attachments.first?.detachedAt, "2026-05-08T00:00:02Z")
        XCTAssertTrue(try TerminalSessionPersistence.activeAttachments(paths: sessionPaths).isEmpty)
    }

    func testTransferOwnershipDemotesOldOwnerToViewer() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let originalOverride = ProcessInfo.processInfo.environment["SPACES_DB_PATH"]
        setenv("SPACES_DB_PATH", root.appendingPathComponent("spaces.db").path, 1)
        defer { if let originalOverride { setenv("SPACES_DB_PATH", originalOverride, 1) } else { unsetenv("SPACES_DB_PATH") } }

        let sessionID = "session-transfer"
        let sessionPaths = try TerminalSessionPaths.forSession(id: sessionID)
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
    }

    func testSessionSocketPathUsesShortSharedSocketsDirectory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let originalOverride = ProcessInfo.processInfo.environment["SPACES_DB_PATH"]
        setenv("SPACES_DB_PATH", root.appendingPathComponent("spaces.db").path, 1)
        defer { if let originalOverride { setenv("SPACES_DB_PATH", originalOverride, 1) } else { unsetenv("SPACES_DB_PATH") } }

        let paths = try TerminalSessionPaths.forSession(id: "7399141B-E18F-429C-AD87-1FA6191DC9FE")

        XCTAssertTrue(paths.controlSocketPath.contains("/tmp/spaces-terminal-sockets/"))
        XCTAssertFalse(paths.controlSocketPath.contains("/terminal/sessions/7399141B-E18F-429C-AD87-1FA6191DC9FE/"))
        XCTAssertLessThan(paths.controlSocketPath.utf8.count, 104)
    }

    func testWindowFramePersistsPerAttachmentMode() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = TerminalSessionPaths(rootDirectory: root.path)
        let ownerFrame = TerminalSessionWindowFrame(x: 100, y: 120, width: 980, height: 640)
        let viewerFrame = TerminalSessionWindowFrame(x: 160, y: 180, width: 720, height: 480)

        try TerminalSessionPersistence.writeWindowFrame(ownerFrame, mode: .owner, paths: paths)
        try TerminalSessionPersistence.writeWindowFrame(viewerFrame, mode: .viewer, paths: paths)

        XCTAssertEqual(try TerminalSessionPersistence.readWindowFrame(mode: .owner, paths: paths), ownerFrame)
        XCTAssertEqual(try TerminalSessionPersistence.readWindowFrame(mode: .viewer, paths: paths), viewerFrame)
    }
}
