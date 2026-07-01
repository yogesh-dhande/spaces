import AppKit
import Foundation
import XCTest
import spacesterminalcore
import workspacecore

func makeTempDirectory() throws -> URL {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    return base
}

extension XCTestCase {
    /// A store backed by a fresh temporary database, with the profile environment scoped to this test.
    ///
    /// `SQLiteStore` is given the explicit path, but downstream code (terminal-session persistence, runtime
    /// paths) still resolves the active profile from `SPACES_DB_PATH`/`SPACES_RUNTIME_DIR`. Those are set
    /// here and restored in a teardown block so the override never leaks into later tests in the same
    /// process — previously they were set and never restored, which left a stale (deleted) profile path
    /// pinned for the rest of the run.
    func makeTemporaryStore() throws -> SQLiteStore {
        _ = installHermeticGitEnvironment
        let dir = try makeTempDirectory()
        let dbURL = dir.appendingPathComponent("spaces-test.db")
        let runtimeURL = dir.appendingPathComponent("runtime", isDirectory: true)
        let keys = [SpacesProfile.databasePathEnvironmentVariable, SpacesProfile.runtimeDirectoryEnvironmentVariable]
        let originalValues = keys.map { ($0, ProcessInfo.processInfo.environment[$0]) }
        addTeardownBlock { for (name, value) in originalValues { if let value { setenv(name, value, 1) } else { unsetenv(name) } } }
        setenv(SpacesProfile.databasePathEnvironmentVariable, dbURL.path, 1)
        setenv(SpacesProfile.runtimeDirectoryEnvironmentVariable, runtimeURL.path, 1)
        return try SQLiteStore(path: dbURL.path)
    }
}

func makeProjectRecord(id: String = UUID().uuidString, dir: String) -> ProjectRecord {
    ProjectRecord(
        id: id, name: "Project", dir: dir, isGitRepo: false, defaultBranch: nil, setupScript: nil, stopScript: nil, ports: [], processes: [],
        browserSessions: [])
}

func makeWorkspaceRecord(id: String = UUID().uuidString, projectID: String, dir: String, branch: String? = nil) -> WorkspaceRecord {
    WorkspaceRecord(
        id: id, projectID: projectID, dir: dir, dirname: nil, branch: branch, isDefault: false, isArchived: false, isRunning: false,
        lastLaunchedAt: nil)
}

/// Seeds the tracked terminal-session window that a live Spaces terminal session creates before any
/// agent hook fires. In the session-based model the agent correlates to this existing window (matched
/// by session id) instead of minting its own dedicated row, so the agent label is not auto-suffixed
/// against a window it just created for itself.
func seedTerminalSessionWindow(store: SQLiteStore, workspaceID: String, sessionID: String) throws {
    try store.upsert(
        window: WindowRecord(
            id: UUID().uuidString, workspaceID: workspaceID, app: TerminalHost.spaces.appName, name: sessionID, detail: nil, targetURL: nil,
            windowID: nil, terminalTrackingID: sessionID, terminalNativeID: sessionID, role: "terminal", orderIndex: 200, lastSeenAt: "now"))
}

/// Marks a built-in terminal session as live for window-reconciliation purposes. Window liveness is
/// session-based: a control socket must be present, an active owner attachment must exist, and the
/// service PID must be alive. Tests that exercise `refreshWorkspaceWindows` must establish those session
/// artifacts for the window to survive reconciliation. The session's runtime state (with a live
/// `servicePID`) must already be written by the caller.
func markBuiltInSessionLive(sessionID: String, attachedAt: String = "2026-06-06T00:00:00Z") throws {
    let paths = try TerminalSessionPaths.forSession(id: sessionID)
    try paths.ensureDirectories()
    _ = FileManager.default.createFile(atPath: paths.controlSocketPath, contents: Data())
    let client = TerminalClient(
        id: "owner-\(sessionID)", kind: .localWindow, identity: .init(label: "Spaces window", hostName: "mac", deviceName: "Owner Mac"),
        connectedAt: attachedAt)
    let attachment = TerminalAttachment(sessionID: sessionID, clientID: client.id, mode: .owner, attachedAt: attachedAt)
    try TerminalSessionPersistence.writeAttachmentSnapshot(
        TerminalSessionAttachmentSnapshot(clients: [client], attachments: [attachment]), paths: paths)
}
