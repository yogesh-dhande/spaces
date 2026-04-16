import Foundation
import Testing

@testable import streamctl

@Suite("Status Check Tests") struct StatusCheckTests {
    @Test("Status check command failure detection with docker commands")
    // Tests status check detects docker container failure by arranging representative inputs and asserting the expected result.
    func testStatusCheckDetectsDockerContainerFailure() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let runtimeDir = root.appendingPathComponent("runtime", isDirectory: true)
        try FileManager.default.createDirectory(at: runtimeDir, withIntermediateDirectories: true)
        try withEnv(name: "MUXY_RUNTIME_DIR", value: runtimeDir.path) {
            let store = try makeTemporaryStore()
            let mockIterm = MockIterm2Adapter()
            let mockTmux = MockTmuxAdapter()
            let orchestrator = MuxyOrchestrator(store: store, iterm: mockIterm, tmux: mockTmux)

            let project = try orchestrator.addProject(dir: projectDir.path)
            let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature")
            mockTmux.createSession(named: "muxy-\(workspace.id)")
            _ = mockTmux.addWindow(sessionName: "muxy-\(workspace.id)", id: "@1", name: "web-server", index: 0, isActive: true)
            try store.touchWorkspaceSettings(workspaceID: workspace.id, updatedAt: "now")
            let mockScript = projectDir.appendingPathComponent("mock-docker-check.sh")
            try "#!/bin/bash\nexit 1".write(to: mockScript, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: mockScript.path)
            let workspaceRuntime = runtimeDir.appendingPathComponent(workspace.id, isDirectory: true)
            try FileManager.default.createDirectory(at: workspaceRuntime, withIntermediateDirectories: true)
            let pidFileURL = workspaceRuntime.appendingPathComponent("web-server.pid")
            try "10001".write(to: pidFileURL, atomically: true, encoding: .utf8)
            try store.setWorkspaceStatusChecks(
                workspaceID: workspace.id,
                checks: [
                    StatusCheckDefinition(
                        name: "docker-container-health", process: "web-server", command: mockScript.path, interval: 10, timeout: 5,
                        onFail: .restart)
                ])
            try store.upsert(
                window: WindowRecord(
                    id: UUID().uuidString, workspaceID: workspace.id, app: "iTerm2", title: "web-server", windowID: 123,
                    itermSessionID: "workspace-session", tmuxWindowID: "@1", role: "terminal", orderIndex: 200, lastSeenAt: "now"))
            let runningProcess = RunningProcessRecord(
                id: UUID().uuidString, workspaceID: workspace.id, templateName: "web-server", command: "docker compose up -d",
                terminalApp: "iTerm2", windowID: 123, itermSessionID: "workspace-session", itermTabIndex: nil, tmuxWindowID: "@1", pid: 9000,
                status: .running, logPath: nil, lastOutputAt: nil, startedAt: "now", exitedAt: nil)
            try store.upsert(runningProcess: runningProcess)

            var results: [StatusResult] = []
            try withMockCommands(["yabai": Self.yabaiMockScript]) {
                try withEnv(
                    name: "YABAI_WINDOWS_JSON",
                    value: #"[{"id":123,"pid":11,"app":"iTerm2","title":"web-server","space":1,"display":1,"is-sticky":false,"is-hidden":false,"is-visible":true,"is-native-fullscreen":false}]"#
                ) {
                    results = try orchestrator.runStatusChecks(workspaceID: workspace.id)
                }
            }
            #expect(results.count == 1)
            #expect(results.first?.status == .failed)
            #expect(results.first?.checkName == "docker-container-health")
            #expect(mockIterm.openWindowAndRunCallCount == 0)
            #expect(mockTmux.respawnWindowCallCount == 1)
            #expect(mockTmux.respawnedWindowIDs == ["@1"])
            let currentProcesses = try store.runningProcesses(workspaceID: workspace.id)
            #expect(currentProcesses.count == 1)
            let currentProcess = currentProcesses.first!
            #expect(currentProcess.status == .running)
            #expect(currentProcess.windowID == 123)
            #expect(currentProcess.tmuxWindowID == "@1")
        }
    }
    @Test("Status check command success detection with docker commands")
    // Tests status check detects docker container success by arranging representative inputs and asserting the expected result.
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
                    name: "docker-container-health", process: "web-server", command: mockScript.path, interval: 10, timeout: 5, onFail: .restart)
            ])
        let runningProcess = RunningProcessRecord(
            id: UUID().uuidString, workspaceID: workspace.id, templateName: "web-server", command: "docker compose up -d", terminalApp: "iTerm2",
            windowID: 123, pid: 9000, status: .running, logPath: nil, lastOutputAt: nil, startedAt: "now", exitedAt: nil)
        try store.upsert(runningProcess: runningProcess)

        let results = try orchestrator.runStatusChecks(workspaceID: workspace.id)
        #expect(results.count == 1)
        #expect(results.first?.status == .passed)
        #expect(results.first?.checkName == "docker-container-health")
        let currentProcess = try store.runningProcesses(workspaceID: workspace.id).first!
        #expect(currentProcess.status == .running)
        #expect(currentProcess.pid == 9000)
    }
    @Test("Status check with incorrect docker command logic demonstrates the bug")
    // Tests status check with incorrect docker command logic by arranging representative inputs and asserting the expected result.
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
        try "#!/bin/bash\n# Simulates 'docker ps | grep non-existent' behavior\n# Exits 0 but produces no output\nexit 0".write(
            to: mockScript, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: mockScript.path)
        try store.setWorkspaceStatusChecks(
            workspaceID: workspace.id,
            checks: [
                StatusCheckDefinition(
                    name: "incorrect-docker-check", process: "web-server", command: mockScript.path, interval: 10, timeout: 5, onFail: .restart)
            ])
        let runningProcess = RunningProcessRecord(
            id: UUID().uuidString, workspaceID: workspace.id, templateName: "web-server", command: "docker compose up -d", terminalApp: "iTerm2",
            windowID: 123, pid: 9000, status: .running, logPath: nil, lastOutputAt: nil, startedAt: "now", exitedAt: nil)
        try store.upsert(runningProcess: runningProcess)

        let results = try orchestrator.runStatusChecks(workspaceID: workspace.id)
        #expect(results.count == 1)
        #expect(results.first?.status == .passed)  // This is the bug - should be red!
        #expect(results.first?.checkName == "incorrect-docker-check")
        let currentProcess = try store.runningProcesses(workspaceID: workspace.id).first!
        #expect(currentProcess.status == .running)
        #expect(currentProcess.pid == 9000)
    }

    @Test("Status-check restart handles missing tracked PID using runtime PID file")
    // Tests status check restart handles missing tracked pid using runtime pid file by arranging representative inputs and asserting the expected result.
    func testStatusCheckRestartHandlesMissingTrackedPIDUsingRuntimePIDFile() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let runtimeDir = root.appendingPathComponent("runtime", isDirectory: true)
        try FileManager.default.createDirectory(at: runtimeDir, withIntermediateDirectories: true)
        try withEnv(name: "MUXY_RUNTIME_DIR", value: runtimeDir.path) {
            let store = try makeTemporaryStore()
            let mockIterm = MockIterm2Adapter()
            let mockTmux = MockTmuxAdapter()
            let orchestrator = MuxyOrchestrator(store: store, iterm: mockIterm, tmux: mockTmux)
            let project = try orchestrator.addProject(dir: projectDir.path)
            let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature")
            mockTmux.createSession(named: "muxy-\(workspace.id)")
            _ = mockTmux.addWindow(sessionName: "muxy-\(workspace.id)", id: "@1", name: "web-server", index: 0, isActive: true)
            try store.touchWorkspaceSettings(workspaceID: workspace.id, updatedAt: "now")

            let failingCheck = projectDir.appendingPathComponent("failing-check.sh")
            try "#!/bin/bash\nexit 1".write(to: failingCheck, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: failingCheck.path)

            try store.setWorkspaceStatusChecks(
                workspaceID: workspace.id,
                checks: [
                    StatusCheckDefinition(
                        name: "docker-container-health", process: "web-server", command: failingCheck.path, interval: 10, timeout: 5,
                        onFail: .restart)
                ])
            let workspaceRuntime = runtimeDir.appendingPathComponent(workspace.id, isDirectory: true)
            try FileManager.default.createDirectory(at: workspaceRuntime, withIntermediateDirectories: true)
            let pidFileURL = workspaceRuntime.appendingPathComponent("web-server.pid")
            try "98765".write(to: pidFileURL, atomically: true, encoding: .utf8)

            let runningProcess = RunningProcessRecord(
                id: UUID().uuidString, workspaceID: workspace.id, templateName: "web-server", command: "docker compose up --build",
                terminalApp: "iTerm2", windowID: 123, itermSessionID: "workspace-session", itermTabIndex: nil, tmuxWindowID: "@1", pid: nil,
                status: .running, logPath: nil, lastOutputAt: nil, startedAt: "now", exitedAt: nil)
            try store.upsert(runningProcess: runningProcess)
            try store.upsert(
                window: WindowRecord(
                    id: UUID().uuidString, workspaceID: workspace.id, app: "iTerm2", title: "web-server", windowID: 123,
                    itermSessionID: "workspace-session", tmuxWindowID: "@1", role: "terminal", orderIndex: 200, lastSeenAt: "now"))

            var results: [StatusResult] = []
            try withMockCommands(["yabai": Self.yabaiMockScript]) {
                try withEnv(
                    name: "YABAI_WINDOWS_JSON",
                    value: #"[{"id":123,"pid":11,"app":"iTerm2","title":"web-server","space":1,"display":1,"is-sticky":false,"is-hidden":false,"is-visible":true,"is-native-fullscreen":false}]"#
                ) {
                    results = try orchestrator.runStatusChecks(workspaceID: workspace.id)
                }
            }
            #expect(results.count == 1)
            #expect(results.first?.status == .failed)
            #expect(mockIterm.openWindowAndRunCallCount == 0)
            #expect(mockTmux.respawnWindowCallCount == 1)
            let currentProcesses = try store.runningProcesses(workspaceID: workspace.id)
            #expect(currentProcesses.count == 1)
            #expect(currentProcesses.first?.status == .running)
            #expect(currentProcesses.first?.tmuxWindowID == "@1")
        }
    }

    private func withMockCommands(_ commands: [String: String], run: () throws -> Void) throws {
        let directory = try makeTempDirectory()
        for (name, script) in commands {
            let file = directory.appendingPathComponent(name)
            try script.write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        }

        sharedPathMutationLock.lock()
        defer { sharedPathMutationLock.unlock() }
        let originalPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let updatedPath = originalPath.isEmpty ? directory.path : "\(directory.path):\(originalPath)"
        setenv("PATH", updatedPath, 1)
        defer { setenv("PATH", originalPath, 1) }

        try run()
    }

    private func withEnv(name: String, value: String, run: () throws -> Void) throws {
        sharedEnvironmentMutationLock.lock()
        defer { sharedEnvironmentMutationLock.unlock() }
        let original = ProcessInfo.processInfo.environment[name]
        setenv(name, value, 1)
        defer {
            if let original {
                setenv(name, original, 1)
            } else {
                unsetenv(name)
            }
        }
        try run()
    }

    private static let yabaiMockScript = """
        #!/bin/bash
        args="$*"

        if [[ "$args" == *"query --windows"* ]]; then
          if [[ -n "${YABAI_WINDOWS_JSON:-}" ]]; then
            echo "$YABAI_WINDOWS_JSON"
          else
            echo "[]"
          fi
          exit 0
        fi

        if [[ "$args" == *"query --windows --window"* ]]; then
          echo '{"id":123,"pid":11,"app":"iTerm2","title":"web-server","space":1,"display":1,"is-sticky":false,"is-hidden":false,"is-visible":true,"is-native-fullscreen":false}'
          exit 0
        fi

        echo "unhandled command: $args" >&2
        exit 1
        """
}
