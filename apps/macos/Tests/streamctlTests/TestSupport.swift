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
    var focusedSessionIDs: [String?] = []
    var lastFocusedTabIndex: Int?
    var nextWindowID: Int = 9999
    var nextSessionID: String? = "mock-session"
    var nextTabIndex: Int? = 1
    var focusSessionOrTabResult = true
    var closedSessionIDs: [String] = []
    var closedWindowIDs: [Int] = []
    var stubbedSessionIDs: Set<String> = []
    var focusedSessionIDResult: String?
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
        focusedSessionIDs.append(preferredSessionID)
        lastFocusedTabIndex = tabIndex
        lastWindowID = windowID
        if focusSessionOrTabResult, let preferredSessionID, !preferredSessionID.isEmpty {
            focusedSessionIDResult = preferredSessionID
        }
        return focusSessionOrTabResult
    }

    override func closeSessionOrTab(preferredSessionID: String?, tabIndex: Int?, windowID: Int?) throws -> Bool {
        lastFocusedSessionID = preferredSessionID
        lastFocusedTabIndex = tabIndex
        lastWindowID = windowID
        if let sid = preferredSessionID { closedSessionIDs.append(sid) }
        return true
    }

    override func closeWindow(id: Int) throws {
        closedWindowIDs.append(id)
    }

    var pulseCallCount = 0
    var lastPulsedWindowID: Int?
    var lastPulseColor: (r: Int, g: Int, b: Int)?
    var managedPulseSupported = false
    var backgroundColorByWindowID: [Int: (r: Int, g: Int, b: Int)] = [:]
    var backgroundColorReadCount = 0
    var setBackgroundColorCallCount = 0
    var backgroundColorWrites: [(windowID: Int, color: (r: Int, g: Int, b: Int))] = []

    override func pulseBackground(windowID: Int, pulseColor: (r: Int, g: Int, b: Int)) throws {
        pulseCallCount += 1
        lastPulsedWindowID = windowID
        lastPulseColor = pulseColor
    }

    override func backgroundColor(windowID: Int) throws -> (r: Int, g: Int, b: Int)? {
        backgroundColorReadCount += 1
        guard managedPulseSupported else { return nil }
        return backgroundColorByWindowID[windowID]
    }

    override func setBackgroundColor(windowID: Int, color: (r: Int, g: Int, b: Int)) throws -> Bool {
        setBackgroundColorCallCount += 1
        backgroundColorWrites.append((windowID: windowID, color: color))
        backgroundColorByWindowID[windowID] = color
        return managedPulseSupported
    }

    override func listSessionIDs() throws -> Set<String> { stubbedSessionIDs }

    override func focusedSessionID(windowID: Int?) throws -> String? {
        lastWindowID = windowID
        return focusedSessionIDResult
    }
}

class MockTmuxAdapter: TmuxAdapter, @unchecked Sendable {
    var available = true
    var windowsBySession: [String: [TmuxWindowInfo]] = [:]
    var currentWindowIDBySession: [String: String] = [:]
    var createWindowCallCount = 0
    var lastCreatedWindow: TmuxWindowInfo?
    var lastCreatedWindowCommand: String?
    var renameWindowCallCount = 0
    var renamedWindowIDs: [String] = []
    var respawnWindowCallCount = 0
    var respawnedWindowIDs: [String] = []
    var respawnedCommandsByWindowID: [String: String] = [:]
    var remainOnExitByWindowID: [String: Bool] = [:]
    var selectWindowCallCount = 0
    var lastSelectedWindowID: String?
    var selectedWindowIDs: [String] = []
    var killedWindowIDs: [String] = []
    private var nextWindowSerial = 1

    func createSession(named sessionName: String) {
        if windowsBySession[sessionName] == nil { windowsBySession[sessionName] = [] }
    }

    @discardableResult
    func addWindow(sessionName: String, id: String? = nil, name: String, index: Int? = nil, isActive: Bool = false) -> TmuxWindowInfo {
        createSession(named: sessionName)
        let resolvedID = id ?? "@\(nextWindowSerial)"
        if id == nil { nextWindowSerial += 1 }
        let resolvedIndex = index ?? ((windowsBySession[sessionName]?.map(\.index).max() ?? -1) + 1)
        let window = TmuxWindowInfo(
            id: resolvedID, index: resolvedIndex, name: name, sessionName: sessionName,
            isActive: isActive || currentWindowIDBySession[sessionName] == nil)
        updateWindow(window)
        if window.isActive { currentWindowIDBySession[sessionName] = window.id }
        return window
    }

    override func isAvailable() -> Bool { available }

    override func hasSession(named sessionName: String) -> Bool { windowsBySession[sessionName] != nil }

    override func listWindows(sessionName: String) throws -> [TmuxWindowInfo] {
        let currentWindowID = currentWindowIDBySession[sessionName]
        return (windowsBySession[sessionName] ?? [])
            .sorted { $0.index < $1.index }
            .map { window in
                TmuxWindowInfo(
                    id: window.id, index: window.index, name: window.name, sessionName: window.sessionName,
                    isActive: currentWindowID == window.id)
            }
    }

    override func currentWindow(sessionName: String) throws -> TmuxWindowInfo? {
        let windows = try listWindows(sessionName: sessionName)
        if let currentWindowID = currentWindowIDBySession[sessionName] {
            return windows.first(where: { $0.id == currentWindowID })
        }
        return windows.first(where: \.isActive) ?? windows.first
    }

    override func currentWindow() throws -> TmuxWindowInfo? {
        for sessionName in windowsBySession.keys.sorted() {
            if let window = try currentWindow(sessionName: sessionName) { return window }
        }
        return nil
    }

    override func createWindow(sessionName: String, name: String, command: String? = nil, detached: Bool = true) throws -> TmuxWindowInfo {
        createWindowCallCount += 1
        lastCreatedWindowCommand = command
        let window = addWindow(sessionName: sessionName, name: name, isActive: !detached)
        lastCreatedWindow = window
        return window
    }

    override func renameWindow(windowID: String, name: String) throws {
        renameWindowCallCount += 1
        renamedWindowIDs.append(windowID)
        guard var window = window(for: windowID) else { return }
        window = TmuxWindowInfo(
            id: window.id, index: window.index, name: name, sessionName: window.sessionName, isActive: window.isActive)
        updateWindow(window)
    }

    override func respawnWindow(windowID: String, command: String) throws {
        respawnWindowCallCount += 1
        respawnedWindowIDs.append(windowID)
        respawnedCommandsByWindowID[windowID] = command
    }

    override func setRemainOnExit(windowID: String, enabled: Bool) throws {
        remainOnExitByWindowID[windowID] = enabled
    }

    override func selectWindow(windowID: String) throws -> Bool {
        selectWindowCallCount += 1
        lastSelectedWindowID = windowID
        selectedWindowIDs.append(windowID)
        guard let window = window(for: windowID) else { return false }
        currentWindowIDBySession[window.sessionName] = windowID
        return true
    }

    override func killWindow(windowID: String) throws {
        killedWindowIDs.append(windowID)
        guard let window = window(for: windowID) else { return }
        windowsBySession[window.sessionName]?.removeAll { $0.id == windowID }
        if currentWindowIDBySession[window.sessionName] == windowID {
            currentWindowIDBySession[window.sessionName] = windowsBySession[window.sessionName]?.sorted { $0.index < $1.index }.first?.id
        }
    }

    private func window(for windowID: String) -> TmuxWindowInfo? {
        for windows in windowsBySession.values {
            if let match = windows.first(where: { $0.id == windowID }) { return match }
        }
        return nil
    }

    private func updateWindow(_ updatedWindow: TmuxWindowInfo) {
        var windows = windowsBySession[updatedWindow.sessionName] ?? []
        if let index = windows.firstIndex(where: { $0.id == updatedWindow.id }) {
            windows[index] = updatedWindow
        } else {
            windows.append(updatedWindow)
        }
        windowsBySession[updatedWindow.sessionName] = windows.sorted { $0.index < $1.index }
    }
}
