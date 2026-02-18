import Testing
import Foundation
@testable import streamctl

@Suite("Status Check Tests")
struct StatusCheckTests {
    
    @Test("Status check command failure detection with docker commands")
    func testStatusCheckDetectsDockerContainerFailure() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let store = try makeTemporaryStore()
        
        // Use mock iTerm2 adapter to prevent actual terminal windows from opening
        let mockIterm = MockIterm2Adapter()
        let orchestrator = MuxyOrchestrator(store: store, iterm: mockIterm)

        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature")
        try store.touchWorkspaceSettings(workspaceID: workspace.id, updatedAt: "now")
        
        let mockScript = projectDir.appendingPathComponent("mock-docker-check.sh")
        try "#!/bin/bash\nexit 1".write(to: mockScript, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: mockScript.path)
        
        // Create a mock PID file to simulate the new PID after restart
        // The PID file is stored in ~/.muxy/runtime/<workspace-id>/
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        let runtimeRoot = homeDir.appendingPathComponent(".muxy").appendingPathComponent("runtime")
        let workspaceRuntime = runtimeRoot.appendingPathComponent(workspace.id, isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceRuntime, withIntermediateDirectories: true)
        let pidFileURL = workspaceRuntime.appendingPathComponent("web-server.pid")
        try "10001".write(to: pidFileURL, atomically: true, encoding: .utf8)
        
        try store.setWorkspaceStatusChecks(
            workspaceID: workspace.id,
            checks: [
                StatusCheckDefinition(
                    name: "docker-container-health",
                    process: "web-server",
                    command: mockScript.path,
                    interval: 10,
                    timeout: 5,
                    onFail: .restart
                ),
            ])
        
        let runningProcess = RunningProcessRecord(
            id: UUID().uuidString, workspaceID: workspace.id, templateName: "web-server", 
            command: "docker compose up -d", terminalApp: "iTerm2", windowID: 123, pid: 9000,
            status: .running, logPath: nil, lastOutputAt: nil, startedAt: "now", exitedAt: nil)
        try store.upsert(runningProcess: runningProcess)

        let results = try orchestrator.runStatusChecks(workspaceID: workspace.id)
        
        #expect(results.count == 1)
        #expect(results.first?.status == "red")
        #expect(results.first?.checkName == "docker-container-health")
        
        // Verify iTerm2 was called to run in existing window (not create new one)
        #expect(mockIterm.openWindowAndRunCallCount == 0)
        #expect(mockIterm.runInWindowCallCount == 1)
        #expect(mockIterm.lastWindowID == 123)
        
        // Verify process was restarted (status should be running)
        let currentProcesses = try store.runningProcesses(workspaceID: workspace.id)
        #expect(currentProcesses.count == 1)
        let currentProcess = currentProcesses.first!
        #expect(currentProcess.status == .running)
        #expect(currentProcess.windowID == 123) // Should have same window ID
    }
    
    @Test("Status check command success detection with docker commands")
    func testStatusCheckDetectsDockerContainerSuccess() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let store = try makeTemporaryStore()
        let orchestrator = MuxyOrchestrator(store: store)

        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature")
        try store.touchWorkspaceSettings(workspaceID: workspace.id, updatedAt: "now")
        
        let mockScript = projectDir.appendingPathComponent("mock-docker-check.sh")
        try "#!/bin/bash\necho 'pyfiddle_web_dev'".write(to: mockScript, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: mockScript.path)
        
        try store.setWorkspaceStatusChecks(
            workspaceID: workspace.id,
            checks: [
                StatusCheckDefinition(
                    name: "docker-container-health",
                    process: "web-server",
                    command: mockScript.path,
                    interval: 10,
                    timeout: 5,
                    onFail: .restart
                ),
            ])
        
        let runningProcess = RunningProcessRecord(
            id: UUID().uuidString, workspaceID: workspace.id, templateName: "web-server", 
            command: "docker compose up -d", terminalApp: "iTerm2", windowID: 123, pid: 9000,
            status: .running, logPath: nil, lastOutputAt: nil, startedAt: "now", exitedAt: nil)
        try store.upsert(runningProcess: runningProcess)

        let results = try orchestrator.runStatusChecks(workspaceID: workspace.id)
        
        #expect(results.count == 1)
        #expect(results.first?.status == "green")
        #expect(results.first?.checkName == "docker-container-health")
        
        let currentProcess = try store.runningProcesses(workspaceID: workspace.id).first!
        #expect(currentProcess.status == .running)
        #expect(currentProcess.pid == 9000)
    }
    
    @Test("Status check with incorrect docker command logic demonstrates the bug")
    func testStatusCheckWithIncorrectDockerCommandLogic() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let store = try makeTemporaryStore()
        let orchestrator = MuxyOrchestrator(store: store)

        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature")
        try store.touchWorkspaceSettings(workspaceID: workspace.id, updatedAt: "now")
        
        let mockScript = projectDir.appendingPathComponent("mock-broken-docker-check.sh")
        try "#!/bin/bash\n# Simulates 'docker ps | grep non-existent' behavior\n# Exits 0 but produces no output\nexit 0".write(to: mockScript, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: mockScript.path)
        
        try store.setWorkspaceStatusChecks(
            workspaceID: workspace.id,
            checks: [
                StatusCheckDefinition(
                    name: "incorrect-docker-check",
                    process: "web-server",
                    command: mockScript.path,
                    interval: 10,
                    timeout: 5,
                    onFail: .restart
                ),
            ])
        
        let runningProcess = RunningProcessRecord(
            id: UUID().uuidString, workspaceID: workspace.id, templateName: "web-server", 
            command: "docker compose up -d", terminalApp: "iTerm2", windowID: 123, pid: 9000,
            status: .running, logPath: nil, lastOutputAt: nil, startedAt: "now", exitedAt: nil)
        try store.upsert(runningProcess: runningProcess)

        let results = try orchestrator.runStatusChecks(workspaceID: workspace.id)
        
        #expect(results.count == 1)
        #expect(results.first?.status == "green") // This is the bug - should be red!
        #expect(results.first?.checkName == "incorrect-docker-check")
        
        let currentProcess = try store.runningProcesses(workspaceID: workspace.id).first!
        #expect(currentProcess.status == .running)
        #expect(currentProcess.pid == 9000)
    }

    @Test("Status-check restart handles missing tracked PID using runtime PID file")
    func testStatusCheckRestartHandlesMissingTrackedPIDUsingRuntimePIDFile() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let runtimeDir = root.appendingPathComponent("runtime", isDirectory: true)
        try FileManager.default.createDirectory(at: runtimeDir, withIntermediateDirectories: true)
        setenv("MUXY_RUNTIME_DIR", runtimeDir.path, 1)
        defer { unsetenv("MUXY_RUNTIME_DIR") }

        let store = try makeTemporaryStore()
        let mockIterm = MockIterm2Adapter()
        let orchestrator = MuxyOrchestrator(store: store, iterm: mockIterm)
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature")
        try store.touchWorkspaceSettings(workspaceID: workspace.id, updatedAt: "now")

        let failingCheck = projectDir.appendingPathComponent("failing-check.sh")
        try "#!/bin/bash\nexit 1".write(to: failingCheck, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: failingCheck.path)

        try store.setWorkspaceStatusChecks(
            workspaceID: workspace.id,
            checks: [
                StatusCheckDefinition(
                    name: "docker-container-health",
                    process: "web-server",
                    command: failingCheck.path,
                    interval: 10,
                    timeout: 5,
                    onFail: .restart
                ),
            ])
        
        let workspaceRuntime = runtimeDir.appendingPathComponent(workspace.id, isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceRuntime, withIntermediateDirectories: true)
        let pidFileURL = workspaceRuntime.appendingPathComponent("web-server.pid")
        try "98765".write(to: pidFileURL, atomically: true, encoding: .utf8)

        let runningProcess = RunningProcessRecord(
            id: UUID().uuidString, workspaceID: workspace.id, templateName: "web-server",
            command: "docker compose up --build", terminalApp: "iTerm2", windowID: 123, pid: nil,
            status: .running, logPath: nil, lastOutputAt: nil, startedAt: "now", exitedAt: nil)
        try store.upsert(runningProcess: runningProcess)

        let results = try orchestrator.runStatusChecks(workspaceID: workspace.id)
        #expect(results.count == 1)
        #expect(results.first?.status == "red")
        #expect(mockIterm.runInWindowCallCount == 1)
        let currentProcesses = try store.runningProcesses(workspaceID: workspace.id)
        #expect(currentProcesses.count == 1)
        #expect(currentProcesses.first?.status == .running)
    }
}
