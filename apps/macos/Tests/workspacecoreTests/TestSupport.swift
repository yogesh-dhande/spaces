import AppKit
import Foundation
import systembridge
import workspacecore

func makeTempDirectory() throws -> URL {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    return base
}

func makeTemporaryStore() throws -> SQLiteStore {
    let dir = try makeTempDirectory()
    let dbURL = dir.appendingPathComponent("spaces-test.db")
    return try SQLiteStore(path: dbURL.path)
}

func makeProjectRecord(id: String = UUID().uuidString, dir: String) -> ProjectRecord {
    ProjectRecord(
        id: id, name: "Project", dir: dir, isGitRepo: false, defaultBranch: nil, setupScript: nil, stopScript: nil, ports: [], processes: [],
        browserSessions: [])
}

func makeWorkspaceRecord(id: String = UUID().uuidString, projectID: String, title: String, dir: String) -> WorkspaceRecord {
    WorkspaceRecord(
        id: id, projectID: projectID, title: title, dir: dir, dirname: nil, branch: nil, isDefault: false, isArchived: false, isRunning: false,
        lastLaunchedAt: nil)
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
