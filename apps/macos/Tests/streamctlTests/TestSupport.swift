import Foundation
import AppKit
import streamctl
import appctl

func makeTempDirectory() throws -> URL {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    return base
}

func makeTemporaryStore() throws -> SQLiteStore {
    let dir = try makeTempDirectory()
    let dbURL = dir.appendingPathComponent("muxy-test.db")
    return try SQLiteStore(path: dbURL.path)
}

func makeProjectRecord(id: String = UUID().uuidString, dir: String) -> ProjectRecord {
    ProjectRecord(id: id, name: "Project", dir: dir, isGitRepo: false, defaultBranch: nil,
                  setupScript: nil, stopScript: nil, ports: [], processes: [], statusChecks: [], browserSessions: [])
}

func makeWorkspaceRecord(id: String = UUID().uuidString, projectID: String, name: String, dir: String) -> WorkspaceRecord {
    WorkspaceRecord(
        id: id, projectID: projectID, name: name, dir: dir, dirname: nil, branch: nil, isDefault: false, isArchived: false, isRunning: false,
        lastLaunchedAt: nil)
}

// Mock iTerm2 adapter for testing that doesn't open actual terminal windows
class MockIterm2Adapter: Iterm2Adapter {
    var openWindowAndRunCallCount = 0
    var runInWindowCallCount = 0
    var lastCommand: String?
    var lastWindowID: Int?
    var nextWindowID: Int = 9999
    
    override func openWindowAndRun(command: String) throws -> ItermWindowInfo {
        openWindowAndRunCallCount += 1
        lastCommand = command
        let windowID = nextWindowID
        nextWindowID += 1
        // Don't actually open a terminal window - just return the window info
        return ItermWindowInfo(id: windowID)
    }
    
    override func runInWindow(id: Int, command: String) throws {
        runInWindowCallCount += 1
        lastCommand = command
        lastWindowID = id
    }
    
    override func isAvailable() -> Bool {
        return true
    }
}

