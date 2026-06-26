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

func makeWorkspaceRecord(id: String = UUID().uuidString, projectID: String, dir: String) -> WorkspaceRecord {
    WorkspaceRecord(
        id: id, projectID: projectID, dir: dir, dirname: nil, branch: nil, isDefault: false, isArchived: false, isRunning: false, lastLaunchedAt: nil)
}

final class MockTerminalFocusPulseController: TerminalFocusPulseControlling, @unchecked Sendable {
    var pulseCallCount = 0
    var pulsedWindowIDs: [Int] = []
    var pulseColors: [(r: Int, g: Int, b: Int)] = []

    func pulse(windowID: Int, color: (r: Int, g: Int, b: Int), yabai _: YabaiAdapter) {
        pulseCallCount += 1
        pulsedWindowIDs.append(windowID)
        pulseColors.append(color)
    }
}
