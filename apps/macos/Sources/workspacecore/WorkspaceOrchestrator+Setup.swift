import Foundation
import spacesterminalcore
import systembridge

extension WorkspaceOrchestrator {
    func triggerDeferredWorkspaceSetupIfNeeded(workspaceID: String) throws {
        let setupState = try workspaceSetupState(workspaceID: workspaceID)
        guard setupState.status == .pending else { return }
        do { try runWorkspaceSetup(workspaceID: workspaceID) } catch let error as WorkspaceError {
            if case .invalidArgument(let message) = error, message == "Workspace setup is already in progress." { return }
            throw error
        }
    }

    public func workspaceSetupState(workspaceID: String) throws -> WorkspaceSetupState {
        _ = try resolveWorkspace(id: workspaceID)
        return try store.workspaceSetupState(workspaceID: workspaceID)
            ?? WorkspaceSetupState(status: .succeeded, errorMessage: nil, startedAt: nil, finishedAt: nil)
    }

    public func runWorkspaceSetup(workspaceID: String) throws {
        try withWorkspaceSetupLock(workspaceID: workspaceID) {
            let (project, workspace) = try resolveWorkspace(id: workspaceID)
            try runWorkspaceSetup(project: project, workspace: workspace)
        }
    }

    func workspaceSetupLogPath(workspaceID: String) throws -> String {
        let workspaceSetupDirectory = URL(fileURLWithPath: try runtimeDirectory(), isDirectory: true).appendingPathComponent(
            "workspace-setup", isDirectory: true
        ).appendingPathComponent(workspaceID, isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceSetupDirectory, withIntermediateDirectories: true)
        return workspaceSetupDirectory.appendingPathComponent("setup.log", isDirectory: false).path
    }

    func prepareWorkspaceSetupLog(workspaceID: String) throws -> String {
        let path = try workspaceSetupLogPath(workspaceID: workspaceID)
        _ = FileManager.default.createFile(atPath: path, contents: nil)
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        try handle.truncate(atOffset: 0)
        try handle.close()
        return path
    }

    func runWorkspaceSetupScript(_ script: String, cwd: String, logPath: String) throws -> WorkspaceSetupRunResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-lc", script]
        process.currentDirectoryURL = URL(fileURLWithPath: cwd, isDirectory: true)
        process.environment = Shell.currentProcessEnvironment()

        let logHandle = try FileHandle(forWritingTo: URL(fileURLWithPath: logPath))
        defer { try? logHandle.close() }
        process.standardOutput = logHandle
        process.standardError = logHandle
        try process.run()

        process.waitUntilExit()
        try? logHandle.synchronize()
        return WorkspaceSetupRunResult(exitCode: Int(process.terminationStatus), logPath: logPath)
    }

    func runWorkspaceSetup(project: ProjectRecord, workspace: WorkspaceRecord) throws {
        let assignedPorts = try store.workspacePortsAssigned(workspaceID: workspace.id)
        let runtimeManifest = workspaceRuntimeManifest(project: project, workspace: workspace, assignedPorts: assignedPorts)
        let setupScript = project.setupScript?.trimmingCharacters(in: .whitespacesAndNewlines)
        let startedAt = nowISO8601()
        let logPath = try prepareWorkspaceSetupLog(workspaceID: workspace.id)
        try store.setWorkspaceSetupState(
            workspaceID: workspace.id, status: .running, errorMessage: nil, startedAt: startedAt, finishedAt: nil, exitCode: nil, logPath: logPath)
        guard let setupScript, !setupScript.isEmpty else {
            try store.setWorkspaceSetupState(
                workspaceID: workspace.id, status: .succeeded, errorMessage: nil, startedAt: startedAt, finishedAt: nowISO8601(), exitCode: 0,
                logPath: logPath)
            return
        }
        let result: WorkspaceSetupRunResult
        do {
            let env = buildWorkspaceEnv(
                project: project, workspace: workspace, namedPorts: assignedPorts.map { (port: $0.port, name: $0.name) },
                runtimeManifest: runtimeManifest)
            result = try runWorkspaceSetupScript(applyEnvVars(setupScript, env: env), cwd: workspace.dir, logPath: logPath)
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            try store.setWorkspaceSetupState(
                workspaceID: workspace.id, status: .failed, errorMessage: message, startedAt: startedAt, finishedAt: nowISO8601(), exitCode: nil,
                logPath: logPath)
            throw error
        }
        guard result.exitCode == 0 else {
            let message = "Setup script exited with code \(result.exitCode)."
            try store.setWorkspaceSetupState(
                workspaceID: workspace.id, status: .failed, errorMessage: message, startedAt: startedAt, finishedAt: nowISO8601(),
                exitCode: result.exitCode, logPath: result.logPath)
            throw WorkspaceError.invalidArgument(message: "\(message) See log: \(result.logPath)")
        }
        try store.setWorkspaceSetupState(
            workspaceID: workspace.id, status: .succeeded, errorMessage: nil, startedAt: startedAt, finishedAt: nowISO8601(),
            exitCode: result.exitCode, logPath: result.logPath)
    }

    func waitForWorkspaceSetupToComplete(workspaceID: String) throws {
        let waitStartedAt = currentDate()
        while true {
            let setupState = try workspaceSetupState(workspaceID: workspaceID)
            switch setupState.status {
            case .succeeded: return
            case .failed:
                let detail = workspaceSetupFailureDetail(setupState)
                throw WorkspaceError.invalidArgument(message: "Workspace setup failed: \(detail)")
            case .pending, .running:
                if currentDate().timeIntervalSince(waitStartedAt) > 900 {
                    throw WorkspaceError.invalidArgument(
                        message:
                            "Timed out waiting for workspace setup to finish. Retry launch after setup completes or run `spaces workspace restart --workspace \(workspaceID)`."
                    )
                }
                Thread.sleep(forTimeInterval: 0.2)
            }
        }
    }

    func requireWorkspaceSetupSucceeded(workspaceID: String) throws {
        let setupState = try workspaceSetupState(workspaceID: workspaceID)
        guard setupState.status == .succeeded else { throw WorkspaceError.invalidArgument(message: workspaceSetupBlockedMessage(setupState)) }
    }

    func workspaceSetupBlockedMessage(_ state: WorkspaceSetupState) -> String {
        switch state.status {
        case .succeeded: return "Workspace setup has completed."
        case .pending: return "Workspace setup has not run. Run setup before launching workspace runtime."
        case .running: return "Workspace setup is still running. Wait for setup to finish before launching workspace runtime."
        case .failed: return "Workspace setup failed: \(workspaceSetupFailureDetail(state))"
        }
    }

    func workspaceSetupFailureDetail(_ state: WorkspaceSetupState) -> String {
        var parts: [String] = []
        if let message = state.errorMessage?.trimmingCharacters(in: .whitespacesAndNewlines), !message.isEmpty { parts.append(message) }
        if let exitCode = state.exitCode { parts.append("exit code \(exitCode)") }
        if let logPath = state.logPath?.trimmingCharacters(in: .whitespacesAndNewlines), !logPath.isEmpty { parts.append("log: \(logPath)") }
        return parts.isEmpty ? "unknown setup error" : parts.joined(separator: ", ")
    }

    func withWorkspaceSetupLock<T>(workspaceID: String, operation: () throws -> T) throws -> T {
        try workspaceSetupGate.withKey(
            workspaceID, busyError: { WorkspaceError.invalidArgument(message: "Workspace setup is already in progress.") }, operation: operation)
    }
}
