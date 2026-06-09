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
        var deliveredNotifications: [(title: String, body: String, subtitle: String?)] = []
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(
            store: store,
            notificationDeliverer: { title, body, subtitle in deliveredNotifications.append((title: title, body: body, subtitle: subtitle)) })

        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature")
        try orchestrator.updateProjectConfig(projectID: project.id) { config in
            config.processes.append(ProcessTemplate(name: "api", command: "sleep 1", onExit: .notify))
        }
        try store.touchWorkspaceSettings(workspaceID: workspace.id, updatedAt: "now")
        try store.setWorkspaceProcesses(workspaceID: workspace.id, processes: [ProcessTemplate(name: "api", command: "sleep 1", onExit: .notify)])
        let runningProcess = RunningProcessRecord(
            id: UUID().uuidString, workspaceID: workspace.id, templateName: "api", command: "sleep 1", terminalApp: "Terminal", windowID: nil,
            terminalTrackingID: nil, terminalNativeID: nil, pid: 2_000_000, status: .running, logPath: nil, lastOutputAt: nil,
            startedAt: "2020-01-01T00:00:00Z", exitedAt: nil)
        try store.upsert(runningProcess: runningProcess)

        let didUpdate = try orchestrator.checkAndUpdateProcessStatuses()
        XCTAssertTrue(didUpdate)
        let currentProcess = try XCTUnwrap(store.runningProcesses(workspaceID: workspace.id).first)
        XCTAssertEqual(currentProcess.status, .exited)
        XCTAssertEqual(deliveredNotifications.count, 1)
        XCTAssertEqual(deliveredNotifications.first?.title, "Process Exited")
        XCTAssertEqual(deliveredNotifications.first?.body, "Process 'api' has exited")
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
