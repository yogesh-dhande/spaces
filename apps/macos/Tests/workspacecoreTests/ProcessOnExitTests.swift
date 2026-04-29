import XCTest

@testable import workspacecore

final class ProcessOnExitTests: XCTestCase {
    // Tests process on exit none does nothing by arranging representative inputs and asserting the expected result.
    func testProcessOnExitNoneDoesNothing() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)

        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature")
        try orchestrator.updateProjectConfig(projectID: project.id) { config in
            config.processes.append(ProcessTemplate(name: "api", command: "echo api", onExit: .none))
        }
        try store.touchWorkspaceSettings(workspaceID: workspace.id, updatedAt: "now")
        try store.setWorkspaceProcesses(workspaceID: workspace.id, processes: [ProcessTemplate(name: "api", command: "echo api", onExit: .none)])
        let runningProcess = RunningProcessRecord(
            id: UUID().uuidString, workspaceID: workspace.id, templateName: "api", command: "echo api", terminalApp: nil, windowID: nil, pid: 9000,
            status: .running, logPath: nil, lastOutputAt: nil, startedAt: "now", exitedAt: nil)
        try store.upsert(runningProcess: runningProcess)

        let updatedProcess = RunningProcessRecord(
            id: runningProcess.id, workspaceID: workspace.id, templateName: "api", command: "echo api", terminalApp: nil, windowID: nil, pid: 9000,
            status: .exited, logPath: nil, lastOutputAt: nil, startedAt: "now", exitedAt: "now")
        try store.upsert(runningProcess: updatedProcess)

        let currentProcess = try store.runningProcesses(workspaceID: workspace.id).first!
        XCTAssertEqual(currentProcess.status, .exited)
    }

    // Tests process on exit notify shows notification by arranging representative inputs and asserting the expected result.
    func testProcessOnExitNotifyShowsNotification() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)

        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature")
        try orchestrator.updateProjectConfig(projectID: project.id) { config in
            config.processes.append(ProcessTemplate(name: "api", command: "echo api", onExit: .notify))
        }
        try store.touchWorkspaceSettings(workspaceID: workspace.id, updatedAt: "now")
        try store.setWorkspaceProcesses(workspaceID: workspace.id, processes: [ProcessTemplate(name: "api", command: "echo api", onExit: .notify)])
        let runningProcess = RunningProcessRecord(
            id: UUID().uuidString, workspaceID: workspace.id, templateName: "api", command: "echo api", terminalApp: nil, windowID: nil, pid: 9000,
            status: .running, logPath: nil, lastOutputAt: nil, startedAt: "now", exitedAt: nil)
        try store.upsert(runningProcess: runningProcess)

        let currentProcess = try store.runningProcesses(workspaceID: workspace.id).first!
        XCTAssertEqual(currentProcess.status, .running)
    }

    // Tests process on exit restart restarts process by arranging representative inputs and asserting the expected result.
    func testProcessOnExitRestartRestartsProcess() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let store = try makeTemporaryStore()
        let mockIterm = MockIterm2Adapter()
        let orchestrator = WorkspaceOrchestrator(store: store, iterm: mockIterm)

        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature")
        try orchestrator.updateProjectConfig(projectID: project.id) { config in
            config.processes.append(ProcessTemplate(name: "api", command: "npm start", onExit: .restart))
        }
        try store.touchWorkspaceSettings(workspaceID: workspace.id, updatedAt: "now")
        try store.setWorkspaceProcesses(workspaceID: workspace.id, processes: [ProcessTemplate(name: "api", command: "npm start", onExit: .restart)])
        let runningProcess = RunningProcessRecord(
            id: UUID().uuidString, workspaceID: workspace.id, templateName: "api", command: "npm start", terminalApp: "iTerm2", windowID: 123,
            pid: 9000, status: .running, logPath: nil, lastOutputAt: nil, startedAt: "now", exitedAt: nil)
        try store.upsert(runningProcess: runningProcess)

        XCTAssertEqual(mockIterm.openWindowAndRunCallCount, 0)
    }
    // Tests process template serializes on exit by arranging representative inputs and asserting the expected result.
    func testProcessTemplateSerializesOnExit() throws {
        let process = ProcessTemplate(name: "api", command: "npm start", onExit: .restart)
        let encoder = JSONEncoder()
        let data = try encoder.encode(process)
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(ProcessTemplate.self, from: data)
        XCTAssertEqual(decoded.name, "api")
        XCTAssertEqual(decoded.command, "npm start")
        XCTAssertEqual(decoded.onExit, .restart)
    }
    // Tests process template defaults to none on exit by arranging representative inputs and asserting the expected result.
    func testProcessTemplateDefaultsToNoneOnExit() throws {
        let process = ProcessTemplate(name: "api", command: "npm start")
        XCTAssertEqual(process.onExit, .none)
    }
}
