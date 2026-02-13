import XCTest

@testable import streamctl

final class StoreTests: XCTestCase {
    func testWorkspaceCollectionsRoundTripAndReplacement() throws {
        let store = try makeTemporaryStore()
        let project = makeProjectRecord(dir: try makeTempDirectory().path)
        let workspace = makeWorkspaceRecord(projectID: project.id, name: "feature", dir: project.dir)
        try store.upsert(project: project)
        try store.upsert(workspace: workspace)

        try store.setWorkspacePorts(workspaceID: workspace.id, ports: [3000, 3001])
        XCTAssertEqual(try store.workspacePorts(workspaceID: workspace.id), [3000, 3001])
        try store.setWorkspacePorts(workspaceID: workspace.id, ports: [4000])
        XCTAssertEqual(try store.workspacePorts(workspaceID: workspace.id), [4000])

        let processes = [
            ProcessTemplate(name: "api", command: "npm run api"),
            ProcessTemplate(command: "npm run worker"),
        ]
        try store.setWorkspaceProcesses(workspaceID: workspace.id, processes: processes)
        let storedProcesses = try store.workspaceProcesses(workspaceID: workspace.id)
        XCTAssertEqual(storedProcesses.count, 2)
        XCTAssertEqual(storedProcesses[0].name, "api")
        XCTAssertEqual(storedProcesses[1].name, nil)

        let checks = [
            StatusCheckDefinition(
                name: "api health",
                process: "api",
                command: "curl -f http://localhost:$PORT0/health",
                interval: 10,
                timeout: 3,
                onExit: .notify
            ),
            StatusCheckDefinition(
                process: "worker",
                command: "echo ok",
                interval: 60,
                timeout: 5,
                onExit: .restart
            ),
        ]
        try store.setWorkspaceStatusChecks(workspaceID: workspace.id, checks: checks)
        let storedChecks = try store.workspaceStatusChecks(workspaceID: workspace.id)
        XCTAssertEqual(storedChecks.count, 2)
        XCTAssertEqual(storedChecks[0].onExit, .notify)
        XCTAssertEqual(storedChecks[1].onExit, .restart)

        try store.setWorkspaceBrowserSessions(
            workspaceID: workspace.id,
            sessions: [BrowserSession(url: "https://example.com"), BrowserSession()]
        )
        let sessions = try store.workspaceBrowserSessions(workspaceID: workspace.id)
        XCTAssertEqual(sessions.count, 2)
        XCTAssertEqual(sessions[0].url, "https://example.com")
        XCTAssertNil(sessions[1].url)

        XCTAssertFalse(try store.workspaceSettingsExists(workspaceID: workspace.id))
        try store.touchWorkspaceSettings(workspaceID: workspace.id, updatedAt: "now")
        XCTAssertTrue(try store.workspaceSettingsExists(workspaceID: workspace.id))
        XCTAssertNil(try store.workspaceStopScript(workspaceID: workspace.id))
        try store.setWorkspaceStopScript(workspaceID: workspace.id, stopScript: "echo stop")
        XCTAssertEqual(try store.workspaceStopScript(workspaceID: workspace.id), "echo stop")
        try store.setWorkspaceStopScript(workspaceID: workspace.id, stopScript: nil)
        XCTAssertNil(try store.workspaceStopScript(workspaceID: workspace.id))

        try store.releaseWorkspacePorts(workspaceID: workspace.id)
        XCTAssertTrue(try store.workspacePorts(workspaceID: workspace.id).isEmpty)
    }

    func testRunningProcessesStatusResultsAndWindowsRoundTrip() throws {
        let store = try makeTemporaryStore()
        let project = makeProjectRecord(dir: try makeTempDirectory().path)
        let workspace = makeWorkspaceRecord(projectID: project.id, name: "feature", dir: project.dir)
        try store.upsert(project: project)
        try store.upsert(workspace: workspace)

        let processID = UUID().uuidString
        try store.upsert(
            runningProcess: RunningProcessRecord(
                id: processID,
                workspaceID: workspace.id,
                templateName: "api",
                command: "npm run api",
                terminalApp: "iTerm2",
                windowID: 9001,
                pid: 1234,
                status: .running,
                logPath: "/tmp/api.log",
                lastOutputAt: "2026-01-01T00:00:00Z",
                startedAt: "2026-01-01T00:00:00Z",
                exitedAt: nil
            )
        )

        var processes = try store.runningProcesses(workspaceID: workspace.id)
        XCTAssertEqual(processes.count, 1)
        XCTAssertEqual(processes[0].status, .running)
        XCTAssertEqual(processes[0].windowID, 9001)

        try store.upsert(
            runningProcess: RunningProcessRecord(
                id: processID,
                workspaceID: workspace.id,
                templateName: "api",
                command: "npm run api",
                terminalApp: nil,
                windowID: nil,
                pid: nil,
                status: .exited,
                logPath: nil,
                lastOutputAt: nil,
                startedAt: "2026-01-01T00:00:00Z",
                exitedAt: "2026-01-01T00:01:00Z"
            )
        )
        processes = try store.runningProcesses(workspaceID: workspace.id)
        XCTAssertEqual(processes[0].status, .exited)
        XCTAssertNil(processes[0].windowID)

        try store.upsert(
            statusResult: StatusResult(
                processID: processID,
                checkName: "health",
                status: "green",
                message: "ok",
                lastRunAt: "2026-01-01T00:00:00Z"
            )
        )
        try store.upsert(
            statusResult: StatusResult(
                processID: processID,
                checkName: "health",
                status: "red",
                message: "failed",
                lastRunAt: "2026-01-01T00:02:00Z"
            )
        )
        let results = try store.statusResults(processID: processID)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].status, "red")
        XCTAssertEqual(results[0].message, "failed")

        let firstWindow = WindowRecord(
            id: UUID().uuidString,
            workspaceID: workspace.id,
            app: "Google Chrome",
            title: "Browser",
            windowID: 42,
            role: "browser",
            orderIndex: 0,
            lastSeenAt: "now"
        )
        let secondWindow = WindowRecord(
            id: UUID().uuidString,
            workspaceID: workspace.id,
            app: "iTerm2",
            title: "Terminal",
            windowID: 43,
            role: "terminal",
            orderIndex: 1,
            lastSeenAt: "now"
        )
        try store.upsert(window: firstWindow)
        try store.upsert(window: secondWindow)

        XCTAssertEqual(try store.workspaceID(windowID: 42), workspace.id)
        XCTAssertEqual(try store.windows(workspaceID: workspace.id).count, 2)
        try store.deleteWindow(id: firstWindow.id)
        XCTAssertEqual(try store.windows(workspaceID: workspace.id).count, 1)
        try store.deleteWindows(workspaceID: workspace.id)
        XCTAssertTrue(try store.windows(workspaceID: workspace.id).isEmpty)
    }

    func testDeleteWorkspaceRemovesDependentRows() throws {
        let store = try makeTemporaryStore()
        let project = makeProjectRecord(dir: try makeTempDirectory().path)
        let workspace = makeWorkspaceRecord(projectID: project.id, name: "feature", dir: project.dir)
        try store.upsert(project: project)
        try store.upsert(workspace: workspace)

        let processID = UUID().uuidString
        try store.touchWorkspaceSettings(workspaceID: workspace.id, updatedAt: "now")
        try store.setWorkspacePorts(workspaceID: workspace.id, ports: [3000])
        try store.setWorkspaceProcesses(workspaceID: workspace.id, processes: [ProcessTemplate(command: "echo one")])
        try store.setWorkspaceStatusChecks(
            workspaceID: workspace.id,
            checks: [StatusCheckDefinition(process: "one", command: "echo ok", interval: 10, timeout: 2)]
        )
        try store.setWorkspaceBrowserSessions(workspaceID: workspace.id, sessions: [BrowserSession(url: "https://example.com")])
        try store.upsert(
            runningProcess: RunningProcessRecord(
                id: processID,
                workspaceID: workspace.id,
                templateName: "one",
                command: "echo one",
                terminalApp: nil,
                windowID: nil,
                pid: nil,
                status: .running,
                logPath: nil,
                lastOutputAt: nil,
                startedAt: "now",
                exitedAt: nil
            )
        )
        try store.upsert(
            statusResult: StatusResult(
                processID: processID,
                checkName: "health",
                status: "green",
                message: nil,
                lastRunAt: "now"
            )
        )
        try store.upsert(
            window: WindowRecord(
                id: UUID().uuidString,
                workspaceID: workspace.id,
                app: "iTerm2",
                title: "term",
                windowID: 77,
                role: "terminal",
                orderIndex: 0,
                lastSeenAt: "now"
            )
        )

        try store.deleteWorkspace(id: workspace.id)

        XCTAssertNil(try store.workspace(id: workspace.id))
        XCTAssertTrue(try store.workspacePorts(workspaceID: workspace.id).isEmpty)
        XCTAssertTrue(try store.workspaceProcesses(workspaceID: workspace.id).isEmpty)
        XCTAssertTrue(try store.workspaceStatusChecks(workspaceID: workspace.id).isEmpty)
        XCTAssertTrue(try store.workspaceBrowserSessions(workspaceID: workspace.id).isEmpty)
        XCTAssertTrue(try store.runningProcesses(workspaceID: workspace.id).isEmpty)
        XCTAssertTrue(try store.statusResults(processID: processID).isEmpty)
        XCTAssertTrue(try store.windows(workspaceID: workspace.id).isEmpty)
    }

    func testDeleteProjectRemovesProjectWorkspacesAndDependents() throws {
        let store = try makeTemporaryStore()
        let project = makeProjectRecord(id: "project-1", dir: try makeTempDirectory().path)
        let workspace = makeWorkspaceRecord(projectID: project.id, name: "feature", dir: project.dir)
        try store.upsert(project: project)
        try store.upsert(workspace: workspace)
        try store.setWorkspacePorts(workspaceID: workspace.id, ports: [3000])
        try store.upsert(
            window: WindowRecord(
                id: UUID().uuidString,
                workspaceID: workspace.id,
                app: "Google Chrome",
                title: nil,
                windowID: 91,
                role: "browser",
                orderIndex: 0,
                lastSeenAt: "now"
            )
        )

        try store.deleteProject(id: project.id)

        XCTAssertNil(try store.project(id: project.id))
        XCTAssertTrue(try store.workspaces(projectID: project.id, includeArchived: true).isEmpty)
        XCTAssertTrue(try store.workspacePorts(workspaceID: workspace.id).isEmpty)
        XCTAssertNil(try store.workspaceID(windowID: 91))
    }

    func testWorkspaceAndSettingStateUpdatesPersist() throws {
        let store = try makeTemporaryStore()
        let project = makeProjectRecord(dir: try makeTempDirectory().path)
        let workspace = makeWorkspaceRecord(projectID: project.id, name: "feature", dir: project.dir)
        try store.upsert(project: project)
        try store.upsert(workspace: workspace)

        try store.updateWorkspaceRunning(id: workspace.id, isRunning: true, launchedAt: "2026-01-01T00:00:00Z")
        try store.updateWorkspaceArchived(id: workspace.id, isArchived: true)
        let updated = try store.workspace(id: workspace.id)
        XCTAssertEqual(updated?.isRunning, true)
        XCTAssertEqual(updated?.isArchived, true)
        XCTAssertEqual(updated?.lastLaunchedAt, "2026-01-01T00:00:00Z")

        XCTAssertNil(try store.setting(key: "key"))
        try store.setSetting(key: "key", value: "value")
        XCTAssertEqual(try store.setting(key: "key"), "value")
        try store.setSetting(key: "key", value: nil)
        XCTAssertNil(try store.setting(key: "key"))
    }

    func testProjectAndWorkspaceLookupAndOrdering() throws {
        let store = try makeTemporaryStore()
        let aDir = try makeTempDirectory().path
        let zDir = try makeTempDirectory().path
        let aProject = ProjectRecord(id: "a", name: "A Project", dir: aDir, isGitRepo: false, defaultBranch: nil)
        let zProject = ProjectRecord(id: "z", name: "Z Project", dir: zDir, isGitRepo: true, defaultBranch: "main")
        try store.upsert(project: zProject)
        try store.upsert(project: aProject)

        XCTAssertEqual(try store.project(id: "z")?.dir, zDir)
        XCTAssertEqual(try store.project(dir: aDir)?.name, "A Project")
        XCTAssertEqual(try store.projects().map(\.name), ["A Project", "Z Project"])

        let defaultWorkspace = WorkspaceRecord(
            id: "default",
            projectID: aProject.id,
            name: "default",
            dir: aDir,
            dirname: nil,
            branch: nil,
            isDefault: true,
            isArchived: false,
            isRunning: false,
            lastLaunchedAt: nil
        )
        let archivedWorkspace = WorkspaceRecord(
            id: "archived",
            projectID: aProject.id,
            name: "feature",
            dir: aDir,
            dirname: nil,
            branch: nil,
            isDefault: false,
            isArchived: true,
            isRunning: false,
            lastLaunchedAt: nil
        )
        try store.upsert(workspace: archivedWorkspace)
        try store.upsert(workspace: defaultWorkspace)

        XCTAssertEqual(try store.workspace(projectID: aProject.id, name: "feature")?.id, "archived")
        XCTAssertEqual(try store.workspaces(projectID: aProject.id, includeArchived: false).map(\.id), ["default"])
        XCTAssertEqual(Set(try store.workspaces(projectID: aProject.id, includeArchived: true).map(\.id)), Set(["default", "archived"]))
    }

    func testDeleteRunningProcessAndDeleteRunningProcesses() throws {
        let store = try makeTemporaryStore()
        let project = makeProjectRecord(dir: try makeTempDirectory().path)
        let workspace = makeWorkspaceRecord(projectID: project.id, name: "feature", dir: project.dir)
        try store.upsert(project: project)
        try store.upsert(workspace: workspace)

        let firstID = UUID().uuidString
        let secondID = UUID().uuidString
        try store.upsert(
            runningProcess: RunningProcessRecord(
                id: firstID,
                workspaceID: workspace.id,
                templateName: "first",
                command: "echo first",
                terminalApp: nil,
                windowID: nil,
                pid: nil,
                status: .running,
                logPath: nil,
                lastOutputAt: nil,
                startedAt: "now",
                exitedAt: nil
            )
        )
        try store.upsert(
            runningProcess: RunningProcessRecord(
                id: secondID,
                workspaceID: workspace.id,
                templateName: "second",
                command: "echo second",
                terminalApp: nil,
                windowID: nil,
                pid: nil,
                status: .running,
                logPath: nil,
                lastOutputAt: nil,
                startedAt: "now",
                exitedAt: nil
            )
        )
        try store.upsert(
            statusResult: StatusResult(
                processID: firstID,
                checkName: "first",
                status: "green",
                message: nil,
                lastRunAt: nil
            )
        )

        try store.deleteRunningProcess(id: firstID)
        XCTAssertTrue(try store.statusResults(processID: firstID).isEmpty)
        XCTAssertEqual(try store.runningProcesses(workspaceID: workspace.id).map(\.id), [secondID])

        try store.deleteRunningProcesses(workspaceID: workspace.id)
        XCTAssertTrue(try store.runningProcesses(workspaceID: workspace.id).isEmpty)
    }
}
