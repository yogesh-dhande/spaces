import AppKit
import Foundation
import XCTest
import spacesterminalcore
import systembridge
import workspacecore

func makeTempDirectory() throws -> URL {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    return base
}

extension XCTestCase {
    /// Points the profile environment at `databasePath` for the rest of this test, restoring the previous
    /// values in a teardown block so the override never leaks into later tests in the same process.
    ///
    /// Anything a test reaches — the workspace store's migration authorization, terminal-session
    /// persistence, runtime paths — resolves the active profile from `SPACES_DB_PATH`/`SPACES_RUNTIME_DIR`,
    /// so passing an explicit database path to one component is not isolation on its own.
    func bindSpacesProfileForTest(databasePath: String) {
        let runtimePath = URL(fileURLWithPath: databasePath).deletingLastPathComponent().appendingPathComponent("runtime", isDirectory: true).path
        let keys = [SpacesProfile.databasePathEnvironmentVariable, SpacesProfile.runtimeDirectoryEnvironmentVariable]
        let originalValues = keys.map { ($0, ProcessInfo.processInfo.environment[$0]) }
        addTeardownBlock { for (name, value) in originalValues { if let value { setenv(name, value, 1) } else { unsetenv(name) } } }
        setenv(SpacesProfile.databasePathEnvironmentVariable, databasePath, 1)
        setenv(SpacesProfile.runtimeDirectoryEnvironmentVariable, runtimePath, 1)
    }

    /// Binds the profile environment to a fresh throwaway profile for the rest of this test. Use it in
    /// `setUpWithError` so no code path a test reaches — including work its background queues finish
    /// later — can resolve the developer's profile.
    func useIsolatedSpacesProfile() throws {
        bindSpacesProfileForTest(databasePath: try makeTempDirectory().appendingPathComponent("spaces.db").path)
    }

    /// A store backed by a fresh temporary database, with the profile environment scoped to this test.
    func makeTemporaryStore() throws -> SQLiteStore {
        _ = installHermeticGitEnvironment
        let dir = try makeTempDirectory()
        let databasePath = dir.appendingPathComponent("spaces-test.db").path
        bindSpacesProfileForTest(databasePath: databasePath)
        return try SQLiteStore(path: databasePath)
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
            terminalTrackingID: sessionID, role: "terminal", orderIndex: 200, lastSeenAt: "now"))
}

/// Writes the `terminal_sessions` row that has to exist before any runtime state is persisted for a
/// session.
///
/// Production establishes it inside the session host: `startIfNeeded` writes the launch configuration as
/// its first persistence action, before the host's first runtime-state write, and every other per-session
/// table is keyed off that row. The real `builtInTerminalWindowOpener` writes nothing durable at all — it
/// posts an IPC notification asking the app to open a pane — so a fixture that uses the opener as a
/// stand-in for a live session host must seed the row the host would have written.
func seedTerminalSessionRow(
    sessionID: String, paths: TerminalSessionPaths, workspaceID: String = "workspace-1", createdAt: String = "2026-05-09T17:00:00Z"
) throws {
    try TerminalSessionPersistence.writeLaunchConfiguration(
        TerminalSessionLaunchConfiguration(
            sessionID: sessionID, title: sessionID, workingDirectory: "/tmp", shell: "/bin/zsh", command: nil, createdAt: createdAt,
            workspaceID: workspaceID, kind: .shell), paths: paths)
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
