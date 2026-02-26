import AppKit
import Foundation
import appctl
import streamctl

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
    ProjectRecord(
        id: id, name: "Project", dir: dir, isGitRepo: false, defaultBranch: nil, setupScript: nil, stopScript: nil, ports: [], processes: [],
        statusChecks: [], browserSessions: [])
}

func makeWorkspaceRecord(id: String = UUID().uuidString, projectID: String, name: String, dir: String) -> WorkspaceRecord {
    WorkspaceRecord(
        id: id, projectID: projectID, name: name, dir: dir, dirname: nil, branch: nil, isDefault: false, isArchived: false, isRunning: false,
        lastLaunchedAt: nil)
}

// Mock iTerm2 adapter for testing that doesn't open actual terminal windows
class MockIterm2Adapter: Iterm2Adapter, @unchecked Sendable {
    var openWindowAndRunCallCount = 0
    var openTabInWindowAndRunCallCount = 0
    var runInWindowCallCount = 0
    var focusSessionOrTabCallCount = 0
    var lastCommand: String?
    var lastWindowID: Int?
    var openedTabWindowIDs: [Int] = []
    var lastFocusedSessionID: String?
    var lastFocusedTabIndex: Int?
    var nextWindowID: Int = 9999
    var nextSessionID: String? = "mock-session"
    var nextTabIndex: Int? = 1
    var focusSessionOrTabResult = true
    var closedSessionIDs: [String] = []
    var stubbedSessionIDs: Set<String> = []
    override func openWindowAndRun(command: String, background: Bool = false) throws -> ItermWindowInfo {
        openWindowAndRunCallCount += 1
        lastCommand = command
        let windowID = nextWindowID
        nextWindowID += 1
        // Don't actually open a terminal window - just return the window info
        return ItermWindowInfo(id: windowID, sessionID: nextSessionID, tabIndex: nextTabIndex)
    }

    override func openTabInWindowAndRun(windowID: Int, command: String, background: Bool = false) throws -> ItermWindowInfo {
        openTabInWindowAndRunCallCount += 1
        openedTabWindowIDs.append(windowID)
        lastCommand = command
        lastWindowID = windowID
        let tabIndex = (nextTabIndex ?? 1) + openTabInWindowAndRunCallCount
        let sessionID = nextSessionID.map { "\($0)-tab-\(openTabInWindowAndRunCallCount)" }
        return ItermWindowInfo(id: windowID, sessionID: sessionID, tabIndex: tabIndex)
    }
    override func runInWindow(id: Int, command: String) throws {
        runInWindowCallCount += 1
        lastCommand = command
        lastWindowID = id
    }
    override func isAvailable() -> Bool { return true }

    override func focusSessionOrTab(preferredSessionID: String?, tabIndex: Int?, windowID: Int?) throws -> Bool {
        focusSessionOrTabCallCount += 1
        lastFocusedSessionID = preferredSessionID
        lastFocusedTabIndex = tabIndex
        lastWindowID = windowID
        return focusSessionOrTabResult
    }

    override func closeSessionOrTab(preferredSessionID: String?, tabIndex: Int?, windowID: Int?) throws -> Bool {
        lastFocusedSessionID = preferredSessionID
        lastFocusedTabIndex = tabIndex
        lastWindowID = windowID
        if let sid = preferredSessionID { closedSessionIDs.append(sid) }
        return true
    }

    var pulseCallCount = 0
    var lastPulsedWindowID: Int?
    var lastPulseColor: (r: Int, g: Int, b: Int)?

    override func pulseBackground(windowID: Int, pulseColor: (r: Int, g: Int, b: Int)) throws {
        pulseCallCount += 1
        lastPulsedWindowID = windowID
        lastPulseColor = pulseColor
    }

    override func listSessionIDs() throws -> Set<String> { stubbedSessionIDs }
}
