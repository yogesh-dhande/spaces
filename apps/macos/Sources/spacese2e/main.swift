import AppKit
import ApplicationServices
import ArgumentParser
import Carbon
import Dispatch
import Foundation
import spacesmobilebridge
import spacesmobilecore
import spacesterminalcore
import systembridge
import workspacecore

/// Small manual-testing helper that exposes fixture seeding and state-dump
/// commands without expanding the user-facing `spaces` CLI surface.
struct MXE2ECommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "spacese2e", abstract: "Manual real-system test helpers for Spaces.",
        subcommands: [
            SeedFixtureCommand.self, CleanupFixturesCommand.self, CreateWorkspaceCommand.self, LookupWorkspaceCommand.self,
            ShowMainWindowCommand.self, HideMainWindowCommand.self, ShowWindowIssueModalCommand.self, SelectWorkspaceDetailCommand.self,
            OpenWorkspaceTerminalCommand.self, RunWorkspaceProcessCommand.self, StopWorkspaceProcessCommand.self, RestartWorkspaceProcessCommand.self,
            LaunchWorkspaceAgentCommand.self, DumpWorkspaceCommand.self, FocusableWindowNamesCommand.self, ArchiveWorkspaceCommand.self,
            StopWorkspaceCommand.self, StopFixturesCommand.self, SetWorkspaceBrowserSessionURLsCommand.self, SetWorkspaceAgentLaunchersCommand.self,
            ClearWorkspaceAgentWindowsCommand.self, SetWorkspaceStopScriptCommand.self, AddWorkspaceProcessCommand.self,
            RemoveWorkspaceProcessCommand.self, FocusWorkspaceWindowIndexCommand.self, CycleWorkspaceWindowCommand.self,
            FocusWorkspaceProcessCommand.self, RecoverWorkspaceProcessCommand.self, CloseWorkspaceProcessWindowCommand.self,
            SurfaceSnapshotCommand.self, CloseTerminalSessionWindowCommand.self, DumpTerminalSessionWindowStateCommand.self,
            StartTerminalSessionCommand.self, TerminateTerminalSessionCommand.self, OpenMobilePairingWindowCommand.self, RecordScreenCommand.self,
            ScrollApplicationWindowCommand.self, TypeApplicationWindowCommand.self, DragApplicationWindowCommand.self,
        ])
}

private struct ShowMainWindowCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "show-main-window")

    func run() throws {
        DistributedNotificationCenter.default().postNotificationName(
            IPCNotification.showMainWindow, object: try IPCNotification.currentObject(), userInfo: nil, options: [.deliverImmediately])
        try emitJSON(["success": true])
    }
}

private struct HideMainWindowCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "hide-main-window")

    func run() throws {
        DistributedNotificationCenter.default().postNotificationName(
            IPCNotification.hideMainWindow, object: try IPCNotification.currentObject(), userInfo: nil, options: [.deliverImmediately])
        try emitJSON(["success": true])
    }
}

private struct ScrollApplicationWindowCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "scroll-application-window")

    @Option(name: .long) var executableName: String
    @Option(name: .long) var windowTitleContains: String?
    @Option(name: .long) var normalizedX = 0.5
    @Option(name: .long) var normalizedY = 0.5
    @Option(name: .long) var deltaY = -120
    @Option(name: .long) var repetitions = 1

    func run() throws {
        guard (0...1).contains(normalizedX), (0...1).contains(normalizedY) else {
            throw ValidationError("Normalized coordinates must be between 0 and 1.")
        }
        guard repetitions > 0 else { throw ValidationError("Repetitions must be greater than zero.") }
        let target = try targetApplicationWindow(executableName: executableName, windowTitleContains: windowTitleContains)

        target.application.activate(options: [])
        axPerformAction(target.window, action: kAXRaiseAction as String)
        Thread.sleep(forTimeInterval: 0.2)

        let point = CGPoint(x: target.frame.minX + target.frame.width * normalizedX, y: target.frame.minY + target.frame.height * normalizedY)
        let timing = try postScrollEvent(at: point, deltaY: deltaY, repetitions: repetitions)
        try emitJSON(
            ScrollApplicationWindowPayload(
                executableName: executableName, windowTitle: target.title, pointX: point.x, pointY: point.y, deltaY: deltaY, repetitions: repetitions,
                firstScrollEventUptimeNanoseconds: timing.firstScrollEventUptimeNanoseconds,
                lastScrollEventUptimeNanoseconds: timing.lastScrollEventUptimeNanoseconds, success: true))
    }
}

private struct TypeApplicationWindowCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "type-application-window")

    @Option(name: .long) var executableName: String
    @Option(name: .long) var windowTitleContains: String?
    @Option(name: .long) var normalizedX = 0.5
    @Option(name: .long) var normalizedY = 0.5
    @Option(name: .long) var text: String
    @Flag(name: .long) var appendNewline = false
    @Option(name: .long) var interKeyDelayMS = 5

    func run() throws {
        guard (0...1).contains(normalizedX), (0...1).contains(normalizedY) else {
            throw ValidationError("Normalized coordinates must be between 0 and 1.")
        }
        let inputText = appendNewline ? "\(text)\n" : text
        guard !inputText.isEmpty else { throw ValidationError("Missing text.") }
        let target = try targetApplicationWindow(executableName: executableName, windowTitleContains: windowTitleContains)

        target.application.activate(options: [])
        axPerformAction(target.window, action: kAXRaiseAction as String)
        Thread.sleep(forTimeInterval: 0.2)

        let point = CGPoint(x: target.frame.minX + target.frame.width * normalizedX, y: target.frame.minY + target.frame.height * normalizedY)
        try postMouseClick(at: point)
        Thread.sleep(forTimeInterval: 0.05)
        let timing = try postKeyboardText(inputText, interKeyDelayMS: interKeyDelayMS)
        try emitJSON(
            TypeApplicationWindowPayload(
                executableName: executableName, windowTitle: target.title, pointX: point.x, pointY: point.y, textByteCount: inputText.utf8.count,
                firstKeyDownUptimeNanoseconds: timing.firstKeyDownUptimeNanoseconds, lastKeyUpUptimeNanoseconds: timing.lastKeyUpUptimeNanoseconds,
                success: true))
    }
}

private struct DragApplicationWindowCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "drag-application-window")

    @Option(name: .long) var executableName: String
    @Option(name: .long) var windowTitleContains: String?
    @Option(name: .long) var startNormalizedX = 0.1
    @Option(name: .long) var startNormalizedY = 0.2
    @Option(name: .long) var endNormalizedX = 0.8
    @Option(name: .long) var endNormalizedY = 0.2
    @Option(name: .long) var durationMS = 250
    @Option(name: .long) var steps = 8

    func run() throws {
        guard (0...1).contains(startNormalizedX), (0...1).contains(startNormalizedY), (0...1).contains(endNormalizedX),
            (0...1).contains(endNormalizedY)
        else { throw ValidationError("Normalized coordinates must be between 0 and 1.") }
        guard durationMS >= 0 else { throw ValidationError("Duration must be non-negative.") }
        guard steps > 0 else { throw ValidationError("Steps must be greater than zero.") }
        let target = try targetApplicationWindow(executableName: executableName, windowTitleContains: windowTitleContains)

        target.application.activate(options: [])
        axPerformAction(target.window, action: kAXRaiseAction as String)
        Thread.sleep(forTimeInterval: 0.2)

        let startPoint = CGPoint(
            x: target.frame.minX + target.frame.width * startNormalizedX, y: target.frame.minY + target.frame.height * startNormalizedY)
        let endPoint = CGPoint(
            x: target.frame.minX + target.frame.width * endNormalizedX, y: target.frame.minY + target.frame.height * endNormalizedY)
        try postMouseDrag(from: startPoint, to: endPoint, durationMS: durationMS, steps: steps)
        try emitJSON(
            DragApplicationWindowPayload(
                executableName: executableName, windowTitle: target.title, startX: startPoint.x, startY: startPoint.y, endX: endPoint.x,
                endY: endPoint.y, success: true))
    }
}

private struct ShowWindowIssueModalCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "show-window-issue-modal")

    @Option(name: .long) var title: String
    @Option(name: .long) var detail: String

    func run() throws {
        DistributedNotificationCenter.default().postNotificationName(
            IPCNotification.showWindowIssueModal, object: try IPCNotification.currentObject(),
            userInfo: [IPCNotification.titleUserInfoKey: title, IPCNotification.detailUserInfoKey: detail], options: [.deliverImmediately])
        try emitJSON(["success": true])
    }
}

private struct SelectWorkspaceDetailCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "select-workspace-detail")

    @Option(name: .long) var workspaceDir: String

    /// Tells the running Spaces app to show one workspace detail pane by
    /// workspace id, avoiding brittle sidebar accessibility traversal in the
    /// manual desktop harness.
    func run() throws {
        let orchestrator = try makeOrchestrator()
        let normalizedWorkspaceDir = normalizePath(workspaceDir)
        guard let workspace = try orchestrator.store.workspace(dir: normalizedWorkspaceDir) else {
            throw ValidationError("Workspace not found at: \(normalizedWorkspaceDir)")
        }
        DistributedNotificationCenter.default().postNotificationName(
            IPCNotification.selectWorkspaceDetail, object: try IPCNotification.currentObject(),
            userInfo: [IPCNotification.workspaceIDUserInfoKey: workspace.id], options: [.deliverImmediately])
        try emitJSON(
            WorkspaceSummaryPayload(
                id: workspace.id, title: workspace.title, dir: workspace.dir, isArchived: workspace.isArchived, isRunning: workspace.isRunning,
                notes: workspace.notes))
    }
}

private struct OpenWorkspaceTerminalCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "open-workspace-terminal")

    @Option(name: .long) var workspaceDir: String

    /// Tells the running Spaces app to open one built-in terminal for a
    /// workspace through the same UI-side path used by the app itself, so the
    /// manual harness can profile launch responsiveness without scripting
    /// shortcuts or sidebar clicks.
    func run() throws {
        let orchestrator = try makeOrchestrator()
        let normalizedWorkspaceDir = normalizePath(workspaceDir)
        guard let workspace = try orchestrator.store.workspace(dir: normalizedWorkspaceDir) else {
            throw ValidationError("Workspace not found at: \(normalizedWorkspaceDir)")
        }
        DistributedNotificationCenter.default().postNotificationName(
            IPCNotification.openWorkspaceTerminal, object: try IPCNotification.currentObject(),
            userInfo: [IPCNotification.workspaceIDUserInfoKey: workspace.id], options: [.deliverImmediately])
        try emitJSON(
            WorkspaceSummaryPayload(
                id: workspace.id, title: workspace.title, dir: workspace.dir, isArchived: workspace.isArchived, isRunning: workspace.isRunning,
                notes: workspace.notes))
    }
}

private struct StartTerminalSessionCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "start-terminal-session")

    @Option(name: .long) var command: String?
    @Option(name: .long) var title: String?
    @Option(name: .long) var cwd: String?
    @Option(name: .long) var shell: String?

    /// Creates a built-in terminal session directly through TerminalService
    /// without opening a macOS window. The helper always uses a persistent
    /// lifetime so standalone mobile harnesses can attach later.
    func run() throws {
        let normalizedWorkingDirectory = normalizePath(cwd ?? FileManager.default.currentDirectoryPath)
        let resolvedShell = terminalShellPath(shell)
        let resolvedTitle = title ?? terminalDefaultTitle(command: command, cwd: normalizedWorkingDirectory)
        let launchConfiguration = TerminalSessionLaunchConfiguration(
            sessionID: UUID().uuidString, backend: .ghosttyEmbedded, lifetimePolicy: .persistent, title: resolvedTitle,
            workingDirectory: normalizedWorkingDirectory, shell: resolvedShell, command: command,
            createdAt: ISO8601DateFormatter().string(from: Date()))
        let session = try TerminalService.createSession(launchConfiguration)
        try emitJSON(session)
    }
}

private struct TerminateTerminalSessionCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "terminate-terminal-session")

    @Argument(help: "Terminal session ID.") var sessionID: String

    func run() throws {
        let trimmedSessionID = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSessionID.isEmpty else { throw ValidationError("Missing terminal session ID.") }
        try TerminalService.terminateSession(id: trimmedSessionID)
        try emitJSON(TerminatedTerminalSessionPayload(sessionID: trimmedSessionID, terminated: true))
    }
}

private struct OpenMobilePairingWindowCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "open-mobile-pairing-window")

    @Option(name: .long) var timeoutSeconds: Double = 5

    func run() throws {
        _ = try SpacesMobileBridgeControlClient.statusEnsuringCurrentTerminalService(timeout: timeoutSeconds)
        let response = try SpacesMobileBridgeControlClient.openPairingWindow(timeout: timeoutSeconds)
        guard response.ok else { throw ValidationError(response.message) }
        guard let status = response.status else { throw ValidationError("Mobile bridge response did not include address details.") }
        guard let window = response.pairingWindow else { throw ValidationError("Mobile bridge response did not include a pairing window.") }
        let link = try SpacesMobilePairingLink.parse(window.linkString)
        try emitJSON(
            MobilePairingWindowPayload(
                host: status.host, port: status.port, bonjourServiceName: status.bonjourServiceName, pairingLink: window.linkString,
                pairingCode: window.code, pairingNonce: window.nonce, transportKey: link.transportKey,
                expiresAt: ISO8601DateFormatter().string(from: window.expiresAt), message: response.message))
    }
}

private struct RunWorkspaceProcessCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "run-workspace-process")

    @Option(name: .long) var workspaceDir: String
    @Option(name: .long) var processName: String

    /// Tells the running Spaces app to launch one configured process through
    /// the same app-side path used by GUI recovery or focus actions.
    func run() throws {
        let orchestrator = try makeOrchestrator()
        let normalizedWorkspaceDir = normalizePath(workspaceDir)
        guard let workspace = try orchestrator.store.workspace(dir: normalizedWorkspaceDir) else {
            throw ValidationError("Workspace not found at: \(normalizedWorkspaceDir)")
        }
        let trimmedProcessName = processName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedProcessName.isEmpty else { throw ValidationError("Missing process name.") }
        DistributedNotificationCenter.default().postNotificationName(
            IPCNotification.runWorkspaceProcess, object: nil,
            userInfo: [IPCNotification.workspaceIDUserInfoKey: workspace.id, IPCNotification.workspaceTargetNameUserInfoKey: trimmedProcessName],
            options: [.deliverImmediately])
        try emitJSON(["workspaceID": workspace.id, "processName": trimmedProcessName])
    }
}

private struct StopWorkspaceProcessCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "stop-workspace-process")

    @Option(name: .long) var workspaceDir: String
    @Option(name: .long) var processName: String

    func run() throws {
        let orchestrator = try makeOrchestrator()
        let normalizedWorkspaceDir = normalizePath(workspaceDir)
        guard let workspace = try orchestrator.store.workspace(dir: normalizedWorkspaceDir) else {
            throw ValidationError("Workspace not found at: \(normalizedWorkspaceDir)")
        }
        let trimmedProcessName = processName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedProcessName.isEmpty else { throw ValidationError("Missing process name.") }
        DistributedNotificationCenter.default().postNotificationName(
            IPCNotification.stopWorkspaceProcess, object: nil,
            userInfo: [IPCNotification.workspaceIDUserInfoKey: workspace.id, IPCNotification.workspaceTargetNameUserInfoKey: trimmedProcessName],
            options: [.deliverImmediately])
        try emitJSON(["workspaceID": workspace.id, "processName": trimmedProcessName])
    }
}

private struct RestartWorkspaceProcessCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "restart-workspace-process")

    @Option(name: .long) var workspaceDir: String
    @Option(name: .long) var processName: String

    func run() throws {
        let orchestrator = try makeOrchestrator()
        let normalizedWorkspaceDir = normalizePath(workspaceDir)
        guard let workspace = try orchestrator.store.workspace(dir: normalizedWorkspaceDir) else {
            throw ValidationError("Workspace not found at: \(normalizedWorkspaceDir)")
        }
        let trimmedProcessName = processName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedProcessName.isEmpty else { throw ValidationError("Missing process name.") }
        DistributedNotificationCenter.default().postNotificationName(
            IPCNotification.restartWorkspaceProcess, object: nil,
            userInfo: [IPCNotification.workspaceIDUserInfoKey: workspace.id, IPCNotification.workspaceTargetNameUserInfoKey: trimmedProcessName],
            options: [.deliverImmediately])
        try emitJSON(["workspaceID": workspace.id, "processName": trimmedProcessName])
    }
}

private struct LaunchWorkspaceAgentCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "launch-workspace-agent")

    @Option(name: .long) var workspaceDir: String
    @Option(name: .long) var name: String

    /// Tells the running Spaces app to launch one configured coding agent
    /// through the same app-side path used by the GUI.
    func run() throws {
        let orchestrator = try makeOrchestrator()
        let normalizedWorkspaceDir = normalizePath(workspaceDir)
        guard let workspace = try orchestrator.store.workspace(dir: normalizedWorkspaceDir) else {
            throw ValidationError("Workspace not found at: \(normalizedWorkspaceDir)")
        }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { throw ValidationError("Missing coding agent name.") }
        DistributedNotificationCenter.default().postNotificationName(
            IPCNotification.launchWorkspaceAgent, object: nil,
            userInfo: [IPCNotification.workspaceIDUserInfoKey: workspace.id, IPCNotification.workspaceTargetNameUserInfoKey: trimmedName],
            options: [.deliverImmediately])
        try emitJSON(["workspaceID": workspace.id, "name": trimmedName])
    }
}

private struct CleanupFixturesCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "cleanup-fixtures")

    @Option(name: .long) var dirPrefix: String

    /// Removes prior manual-E2E fixture projects whose directories live under
    /// the supplied temp-root prefix, so repeated runs do not accumulate stale
    /// `repo` entries in the current Spaces database.
    func run() throws {
        let orchestrator = try makeOrchestrator()
        let normalizedPrefix = normalizePath(dirPrefix)
        var removedProjects: [String] = []

        for project in try orchestrator.store.projects() {
            let normalizedDir = normalizePath(project.dir)
            guard normalizedDir == normalizedPrefix || normalizedDir.hasPrefix(normalizedPrefix + "/") else { continue }
            try orchestrator.removeProject(dir: normalizedDir)
            removedProjects.append(normalizedDir)
        }

        try emitJSON(["removedProjects": removedProjects])
    }
}

private struct StopWorkspaceCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "stop-workspace")

    @Option(name: .long) var workspaceDir: String

    /// Stops one real workspace through the production lifecycle path so the
    /// manual harness can close tracked terminals/browser windows between
    /// phases without widening the public CLI.
    func run() throws {
        let orchestrator = try makeOrchestrator()
        let normalizedWorkspaceDir = normalizePath(workspaceDir)
        guard let workspace = try orchestrator.store.workspace(dir: normalizedWorkspaceDir) else {
            throw ValidationError("Workspace not found at: \(normalizedWorkspaceDir)")
        }
        _ = try orchestrator.stopWorkspace(workspaceID: workspace.id)
        guard let updated = try orchestrator.store.workspace(id: workspace.id) else {
            throw ValidationError("Workspace disappeared: \(workspace.id)")
        }
        try emitJSON(
            WorkspaceSummaryPayload(
                id: updated.id, title: updated.title, dir: updated.dir, isArchived: updated.isArchived, isRunning: updated.isRunning,
                notes: updated.notes))
    }
}

private struct StopFixturesCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "stop-fixtures")

    @Option(name: .long) var dirPrefix: String

    /// Stops every fixture workspace under the supplied temp-root prefix so the
    /// suite can reset runtime state and close tracked windows between runs.
    func run() throws {
        let orchestrator = try makeOrchestrator()
        let normalizedPrefix = normalizePath(dirPrefix)
        var stoppedWorkspaces: [String] = []

        for project in try orchestrator.store.projects() {
            let normalizedDir = normalizePath(project.dir)
            guard normalizedDir == normalizedPrefix || normalizedDir.hasPrefix(normalizedPrefix + "/") else { continue }
            for workspace in try orchestrator.store.workspaces(projectID: project.id, includeArchived: true) {
                _ = try? orchestrator.stopWorkspace(workspaceID: workspace.id)
                stoppedWorkspaces.append(workspace.dir)
            }
        }

        try emitJSON(["stoppedWorkspaces": stoppedWorkspaces])
    }
}

private struct SeedFixtureCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "seed-fixture")

    @Option(name: .long) var projectDir: String
    @Option(name: .long) var docsURL: String
    @Option(name: .long) var adminURL: String
    @Option(name: .long) var workspaceTitle: String?

    /// Registers a local git repo as a Spaces project and seeds deterministic
    /// browser/process defaults that the manual E2E script can assert against.
    func run() throws {
        let orchestrator = try makeOrchestrator()
        let normalizedProjectDir = normalizePath(projectDir)
        try materializeDemoFixtureIfNeeded(projectDir: normalizedProjectDir, variant: "beacon")
        let project = try orchestrator.project(dir: normalizedProjectDir) ?? orchestrator.addProject(dir: normalizedProjectDir)
        let pythonExecutable = try resolveExecutablePath(named: "python3")
        let frontendCommand = fixtureServiceCommand(
            pythonExecutable: pythonExecutable,
            arguments: [
                "-m", "spaces_e2e_demo", "frontend", "--port", "$APP_PORT", "--site-dir", ".spaces-e2e-demo/site", "--backend-url",
                "http://127.0.0.1:$API_PORT",
            ])
        let backendCommand = fixtureServiceCommand(
            pythonExecutable: pythonExecutable,
            arguments: ["-m", "spaces_e2e_demo", "backend", "--port", "$API_PORT", "--data-dir", ".spaces-e2e-demo/api"])

        try orchestrator.updateProjectConfig(projectID: project.id) { config in
            config.ports = [.init(name: "APP_PORT"), .init(name: "API_PORT")]
            config.stopScript =
                #"bash -lc 'for port in "$APP_PORT" "$API_PORT"; do if [ -n "$port" ]; then pids=(); while IFS= read -r pid; do [ -n "$pid" ] && pids+=("$pid"); done < <(lsof -tiTCP:"$port" -sTCP:LISTEN 2>/dev/null || true); for pid in "${pids[@]}"; do kill "$pid" >/dev/null 2>&1 || true; done; sleep 0.5; for pid in "${pids[@]}"; do kill -0 "$pid" >/dev/null 2>&1 && kill -9 "$pid" >/dev/null 2>&1 || true; done; fi; done; printf "project-stop:%s\n" "${SPACES_WORKSPACE_DIR}" >> "${SPACES_E2E_EVENTS_LOG:-/tmp/spaces-e2e-events.log}"'"#
            config.processes = [
                .init(name: "frontend", command: frontendCommand, executionMode: .shell),
                .init(name: "backend", command: backendCommand, executionMode: .shell),
            ]
            config.browserSessions = [.init(name: "docs", url: docsURL), .init(name: "admin", url: adminURL)]
            config.agentLaunchers = []
        }

        if let workspaceTitle {
            let trimmedWorkspaceTitle = workspaceTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedWorkspaceTitle.isEmpty, let workspace = try orchestrator.store.workspace(dir: project.dir) {
                try orchestrator.updateWorkspaceName(workspaceID: workspace.id, name: trimmedWorkspaceTitle)
            }
        }

        // The default workspace inherits project port definitions lazily, but
        // the manual shell harness needs the concrete reserved port numbers
        // immediately so it can start localhost fixture servers before launch.
        if let workspace = try orchestrator.store.workspace(dir: project.dir) {
            try orchestrator.updateWorkspaceSettings(workspaceID: workspace.id) { _ in }
        }

        let payload = SeedFixturePayload(
            projectID: project.id,
            defaultWorkspace: try orchestrator.store.workspace(dir: project.dir).map {
                WorkspaceSummaryPayload(id: $0.id, title: $0.title, dir: $0.dir, isArchived: $0.isArchived, isRunning: $0.isRunning, notes: $0.notes)
            })
        try emitJSON(payload)
    }

    /// Resolves the executable up front because the seeded process command is
    /// launched by the GUI app through tmux, not by an interactive shell that
    /// necessarily inherits the user's PATH customizations.
    private func resolveExecutablePath(named name: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = [name]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        let path = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0, let path, !path.isEmpty else { throw ValidationError("Required executable not found in PATH: \(name)") }
        return path
    }

    private func shellQuoted(_ raw: String) -> String { "'\(raw.replacingOccurrences(of: "'", with: "'\\''"))'" }

    private func shellToken(_ raw: String) -> String { raw.contains("$") ? raw : shellQuoted(raw) }

    private func fixtureServiceCommand(pythonExecutable: String, arguments: [String]) -> String {
        let joinedArguments = ([shellQuoted(pythonExecutable)] + arguments.map(shellToken)).joined(separator: " ")
        return "export PYTHONPATH=.spaces-e2e-demo/src; exec \(joinedArguments)"
    }

    private func materializeDemoFixtureIfNeeded(projectDir: String, variant: String) throws {
        let fileManager = FileManager.default
        let projectURL = URL(fileURLWithPath: projectDir, isDirectory: true)
        let demoRoot = projectURL.appendingPathComponent(".spaces-e2e-demo", isDirectory: true)
        let pyprojectURL = demoRoot.appendingPathComponent("pyproject.toml")
        let mainURL = demoRoot.appendingPathComponent("src/spaces_e2e_demo/__main__.py")
        let siteURL = demoRoot.appendingPathComponent("site", isDirectory: true)
        let apiURL = demoRoot.appendingPathComponent("api", isDirectory: true)
        if fileManager.fileExists(atPath: pyprojectURL.path), fileManager.fileExists(atPath: mainURL.path),
            fileManager.fileExists(atPath: siteURL.path), fileManager.fileExists(atPath: apiURL.path)
        {
            return
        }

        let fixtureRoot = try resolveDemoFixtureRoot()
        let templateRoot = fixtureRoot.appendingPathComponent("templates/\(variant)", isDirectory: true)
        let pyprojectSource = fixtureRoot.appendingPathComponent("pyproject.toml")
        let lockSource = fixtureRoot.appendingPathComponent("uv.lock")
        let srcSource = fixtureRoot.appendingPathComponent("src", isDirectory: true)
        let siteSource = templateRoot.appendingPathComponent("site", isDirectory: true)
        let apiSource = templateRoot.appendingPathComponent("api", isDirectory: true)

        guard fileManager.fileExists(atPath: pyprojectSource.path), fileManager.fileExists(atPath: srcSource.path),
            fileManager.fileExists(atPath: siteSource.path), fileManager.fileExists(atPath: apiSource.path)
        else { throw ValidationError("Demo fixture source is incomplete: \(fixtureRoot.path)") }

        if fileManager.fileExists(atPath: demoRoot.path) { try fileManager.removeItem(at: demoRoot) }
        try fileManager.createDirectory(at: demoRoot, withIntermediateDirectories: true)
        try fileManager.copyItem(at: pyprojectSource, to: pyprojectURL)
        if fileManager.fileExists(atPath: lockSource.path) {
            try fileManager.copyItem(at: lockSource, to: demoRoot.appendingPathComponent("uv.lock"))
        }
        try fileManager.copyItem(at: srcSource, to: demoRoot.appendingPathComponent("src", isDirectory: true))
        try fileManager.copyItem(at: siteSource, to: siteURL)
        try fileManager.copyItem(at: apiSource, to: apiURL)
    }

    private func resolveDemoFixtureRoot() throws -> URL {
        let fileManager = FileManager.default
        var candidates: [String] = []
        candidates.append(normalizePath("apps/macos/Tests/fixtures/e2e_demo"))
        if let spacesProjectDir = ProcessInfo.processInfo.environment["SPACES_PROJECT_DIR"]?.trimmingCharacters(in: .whitespacesAndNewlines),
            !spacesProjectDir.isEmpty
        {
            candidates.append(
                URL(fileURLWithPath: spacesProjectDir, isDirectory: true).appendingPathComponent(
                    "apps/macos/Tests/fixtures/e2e_demo", isDirectory: true
                ).path)
        }

        for candidate in candidates {
            let candidateURL = URL(fileURLWithPath: candidate, isDirectory: true)
            if fileManager.fileExists(atPath: candidateURL.appendingPathComponent("pyproject.toml").path) { return candidateURL }
        }

        throw ValidationError("Unable to locate apps/macos/Tests/fixtures/e2e_demo. Set SPACES_PROJECT_DIR to an original checkout if needed.")
    }
}

private struct LookupWorkspaceCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "lookup-workspace")

    @Option(name: .long) var projectDir: String
    @Option(name: .long) var title: String

    /// Resolves the workspace created by the GUI flow so the shell harness can
    /// pivot from user-visible titles to stable workspace directories and IDs.
    func run() throws {
        let orchestrator = try makeOrchestrator()
        guard let payload = try workspaceSummary(orchestrator: orchestrator, projectDir: projectDir, title: title) else {
            throw ValidationError("Workspace not found: \(title)")
        }
        try emitJSON(payload)
    }
}

private struct CreateWorkspaceCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "create-workspace")

    @Option(name: .long) var projectDir: String
    @Option(name: .long) var title: String
    @Option(name: .long) var branch: String
    @Option(name: .long) var targetBranch: String?
    @Option(name: .long) var directoryName: String?
    @Option(name: .long) var notes: String?
    @Flag(name: .long) var existingBranch = false

    /// Creates a real workspace record and worktree through the production
    /// orchestrator so the shell harness can validate add/remove flows without
    /// depending on fragile GUI-only form automation. `--existing-branch`
    /// mirrors the app's Existing branch flow for fixture-backed worktrees.
    func run() throws {
        let orchestrator = try makeOrchestrator()
        let normalizedProjectDir = normalizePath(projectDir)
        guard let project = try orchestrator.project(dir: normalizedProjectDir) else {
            throw ValidationError("Project not found: \(normalizedProjectDir)")
        }
        var workspace = try orchestrator.createWorkspace(
            projectID: project.id, name: title, branch: branch, targetBranch: targetBranch, directoryName: directoryName, runSetupScript: false,
            allowRemoteBranchLookup: false, allowExistingBranchReuse: existingBranch)
        if let notes {
            try orchestrator.updateWorkspaceNotes(workspaceID: workspace.id, notes: notes)
            workspace = try orchestrator.store.workspace(dir: workspace.dir) ?? workspace
        }
        try emitJSON(
            WorkspaceSummaryPayload(
                id: workspace.id, title: workspace.title, dir: workspace.dir, isArchived: workspace.isArchived, isRunning: workspace.isRunning,
                notes: workspace.notes))
    }
}

private struct DumpWorkspaceCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "dump-workspace")

    @Option(name: .long) var workspaceDir: String

    /// Dumps persisted workspace/runtime state as JSON so the manual E2E script
    /// can assert on the real database contents without reaching into SQLite
    /// directly.
    func run() throws {
        let orchestrator = try makeOrchestrator()
        let normalizedWorkspaceDir = normalizePath(workspaceDir)
        guard let workspace = try orchestrator.store.workspace(dir: normalizedWorkspaceDir) else {
            throw ValidationError("Workspace not found at: \(normalizedWorkspaceDir)")
        }
        let payload = WorkspaceDumpPayload(
            workspace: .init(
                id: workspace.id, title: workspace.title, dir: workspace.dir, isArchived: workspace.isArchived, isRunning: workspace.isRunning,
                notes: workspace.notes),
            settings: try orchestrator.workspaceSettings(workspaceID: workspace.id).map {
                WorkspaceSettingsPayload(
                    stopScript: $0.stopScript, ports: $0.ports.map(\.name), processes: $0.processes.map { .init(name: $0.name, command: $0.command) },
                    browserSessions: $0.browserSessions.map { .init(name: $0.name, url: $0.url) },
                    agentLaunchers: $0.agentLaunchers.map { .init(name: $0.name, command: $0.command) })
            },
            runningProcesses: try orchestrator.runningProcesses(workspaceID: workspace.id).map {
                RunningProcessPayload(
                    id: $0.id, name: $0.templateName, pid: try resolvedPID(for: $0), status: $0.status.rawValue, terminalApp: $0.terminalApp,
                    terminalTrackingID: $0.terminalTrackingID, terminalNativeID: $0.terminalNativeID, tmuxWindowID: $0.tmuxWindowID,
                    windowID: $0.windowID)
            },
            windows: try orchestrator.windows(workspaceID: workspace.id).map {
                WindowPayload(
                    name: $0.name, app: $0.app, role: $0.role, detail: $0.detail, targetURL: $0.targetURL, windowID: $0.windowID,
                    terminalTrackingID: $0.terminalTrackingID, terminalNativeID: $0.terminalNativeID, itermTabIndex: $0.itermTabIndex)
            },
            agentWindows: try orchestrator.agentWindows(workspaceID: workspace.id).map {
                AgentWindowPayload(
                    id: $0.id, label: $0.label, provider: $0.provider.rawValue, status: $0.status.rawValue, terminalTrackingID: $0.terminalTrackingID,
                    terminalNativeID: $0.terminalNativeID, windowID: $0.windowID, yabaiWindowID: $0.yabaiWindowID)
            })
        try emitJSON(payload)
    }

    private func resolvedPID(for process: RunningProcessRecord) throws -> Int? {
        if let pid = process.pid { return pid }
        guard process.terminalApp == TerminalHost.spaces.appName else { return nil }
        guard let sessionID = process.terminalTrackingID ?? process.terminalNativeID, !sessionID.isEmpty else { return nil }
        let paths = try TerminalSessionPaths.forSession(id: sessionID)
        return try TerminalSessionPersistence.readRuntimeState(paths: paths).childPID.map(Int.init)
    }
}

private struct FocusWorkspaceProcessCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "focus-workspace-process")

    @Option(name: .long) var workspaceDir: String
    @Option(name: .long) var processName: String
    @Option(name: .long) var requestID: String?

    func run() throws {
        let orchestrator = try makeOrchestrator()
        let normalizedWorkspaceDir = normalizePath(workspaceDir)
        guard let workspace = try orchestrator.store.workspace(dir: normalizedWorkspaceDir) else {
            throw ValidationError("Workspace not found at: \(normalizedWorkspaceDir)")
        }
        guard let process = try orchestrator.runningProcesses(workspaceID: workspace.id).first(where: { $0.templateName == processName }) else {
            throw ValidationError("Running process not found: \(processName)")
        }
        try orchestrator.focusWorkspaceProcess(workspaceID: workspace.id, processID: process.id, requestID: requestID)
        try emitJSON(["workspaceID": workspace.id, "processID": process.id, "processName": process.templateName, "requestID": requestID ?? ""])
    }
}

private struct FocusWorkspaceWindowIndexCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "focus-workspace-window-index")

    @Option(name: .long) var workspaceDir: String
    @Option(name: .long) var index: Int

    func run() throws {
        let orchestrator = try makeOrchestrator()
        let normalizedWorkspaceDir = normalizePath(workspaceDir)
        guard let workspace = try orchestrator.store.workspace(dir: normalizedWorkspaceDir) else {
            throw ValidationError("Workspace not found at: \(normalizedWorkspaceDir)")
        }
        try orchestrator.focusWorkspaceWindow(workspaceID: workspace.id, index: index)
        try emitJSON(["workspaceID": workspace.id, "index": String(index)])
    }
}

private struct CycleWorkspaceWindowCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "cycle-workspace-window")

    @Option(name: .long) var workspaceDir: String
    @Option(name: .long) var direction: String

    func run() throws {
        let orchestrator = try makeOrchestrator()
        let normalizedWorkspaceDir = normalizePath(workspaceDir)
        guard let workspace = try orchestrator.store.workspace(dir: normalizedWorkspaceDir) else {
            throw ValidationError("Workspace not found at: \(normalizedWorkspaceDir)")
        }
        switch direction {
        case "next", "previous":
            let requestID = UUID().uuidString
            DistributedNotificationCenter.default().postNotificationName(
                IPCNotification.cycleWorkspaceWindow, object: try IPCNotification.currentObject(),
                userInfo: [
                    IPCNotification.workspaceIDUserInfoKey: workspace.id, IPCNotification.cycleDirectionUserInfoKey: direction,
                    IPCNotification.focusRequestIDUserInfoKey: requestID,
                ], options: [.deliverImmediately])
        default: throw ValidationError("Unsupported direction: \(direction)")
        }
        try emitJSON(["workspaceID": workspace.id, "direction": direction])
    }
}

private struct RecoverWorkspaceProcessCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "recover-workspace-process")

    @Option(name: .long) var workspaceDir: String
    @Option(name: .long) var processName: String

    func run() throws {
        let orchestrator = try makeOrchestrator()
        let normalizedWorkspaceDir = normalizePath(workspaceDir)
        guard let workspace = try orchestrator.store.workspace(dir: normalizedWorkspaceDir) else {
            throw ValidationError("Workspace not found at: \(normalizedWorkspaceDir)")
        }
        try orchestrator.recoverMissingConfiguredProcess(workspaceID: workspace.id, processKey: processName)
        try emitJSON(["workspaceID": workspace.id, "processName": processName])
    }
}

private struct CloseWorkspaceProcessWindowCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "close-workspace-process-window")

    @Option(name: .long) var workspaceDir: String
    @Option(name: .long) var processName: String

    func run() throws {
        let orchestrator = try makeOrchestrator()
        let normalizedWorkspaceDir = normalizePath(workspaceDir)
        guard let workspace = try orchestrator.store.workspace(dir: normalizedWorkspaceDir) else {
            throw ValidationError("Workspace not found at: \(normalizedWorkspaceDir)")
        }
        guard let process = try orchestrator.runningProcesses(workspaceID: workspace.id).first(where: { $0.templateName == processName }) else {
            throw ValidationError("Running process not found: \(processName)")
        }
        guard let sessionID = process.terminalNativeID ?? process.terminalTrackingID, !sessionID.isEmpty else {
            throw ValidationError("Running process has no built-in terminal session: \(processName)")
        }
        DistributedNotificationCenter.default().postNotificationName(
            IPCNotification.closeTerminalSessionWindow, object: try IPCNotification.currentObject(),
            userInfo: [IPCNotification.terminalSessionIDUserInfoKey: sessionID], options: [.deliverImmediately])
        try emitJSON(["workspaceID": workspace.id, "processName": processName, "sessionID": sessionID])
    }
}

private struct CloseTerminalSessionWindowCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "close-terminal-session-window")

    @Option(name: .long) var sessionID: String

    func run() throws {
        let trimmedSessionID = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSessionID.isEmpty else { throw ValidationError("Missing terminal session id.") }
        DistributedNotificationCenter.default().postNotificationName(
            IPCNotification.closeTerminalSessionWindow, object: try IPCNotification.currentObject(),
            userInfo: [IPCNotification.terminalSessionIDUserInfoKey: trimmedSessionID], options: [.deliverImmediately])
        try emitJSON(["sessionID": trimmedSessionID])
    }
}

private struct DumpTerminalSessionWindowStateCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "dump-terminal-session-window-state")

    @Option(name: .long) var sessionID: String
    @Option(name: .long) var outputPath: String
    @Flag(name: .long) var viewer = false
    @Flag(name: .long) var anyMode = false

    func run() throws {
        let trimmedSessionID = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSessionID.isEmpty else { throw ValidationError("Missing terminal session id.") }
        let trimmedOutputPath = outputPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedOutputPath.isEmpty else { throw ValidationError("Missing output path.") }
        let attachmentMode: TerminalAttachmentMode? = anyMode ? nil : (viewer ? .viewer : .owner)
        var userInfo: [String: String] = [
            IPCNotification.terminalSessionIDUserInfoKey: trimmedSessionID, IPCNotification.outputPathUserInfoKey: trimmedOutputPath,
        ]
        if let attachmentMode { userInfo[IPCNotification.terminalAttachmentModeUserInfoKey] = attachmentMode.rawValue }
        DistributedNotificationCenter.default().postNotificationName(
            IPCNotification.dumpTerminalSessionWindowState, object: try IPCNotification.currentObject(), userInfo: userInfo,
            options: [.deliverImmediately])
        try emitJSON(["sessionID": trimmedSessionID, "mode": attachmentMode?.rawValue ?? "any", "outputPath": trimmedOutputPath])
    }
}

private struct SurfaceSnapshotCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "surface-snapshot")

    @Option(name: .long) var spacesPID: Int32?
    @Flag(name: .long) var includeYabaiFocusedWindow = false

    func run() throws {
        let frontmostApplication = NSWorkspace.shared.frontmostApplication
        let frontmostPID = frontmostApplication.map { Int($0.processIdentifier) }
        let focusedWindowID = includeYabaiFocusedWindow ? (try? YabaiAdapter().focusedWindow()?.id) : nil
        let spacesSurface = spacesPID.map { snapshotSpacesSurface(pid: $0, frontmostPID: frontmostPID) }
        try emitJSON(
            SurfaceSnapshotPayload(
                frontmostProcessID: frontmostPID, frontmostApplicationName: frontmostApplication?.localizedName,
                frontmostApplicationBundleID: frontmostApplication?.bundleIdentifier, yabaiFocusedWindowID: focusedWindowID ?? nil,
                spaces: spacesSurface))
    }
}

private struct SetWorkspaceAgentLaunchersCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "set-workspace-agent-launchers")

    @Option(name: .long) var workspaceDir: String
    @Option(name: .long) var name: String?
    @Option(name: .long) var command: String?
    @Flag(name: .long) var clear = false

    /// Replaces workspace coding-agent launchers through the production
    /// workspace-settings path so the manual harness can launch a mock agent
    /// without driving the nested settings UI.
    func run() throws {
        let orchestrator = try makeOrchestrator()
        let normalizedWorkspaceDir = normalizePath(workspaceDir)
        guard let workspace = try orchestrator.store.workspace(dir: normalizedWorkspaceDir) else {
            throw ValidationError("Workspace not found at: \(normalizedWorkspaceDir)")
        }
        if clear && (name != nil || command != nil) { throw ValidationError("--clear cannot be combined with --name or --command") }
        if !clear
            && (name?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
                || command?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false)
        {
            throw ValidationError("--name and --command are required unless --clear is used")
        }
        try orchestrator.updateWorkspaceSettings(workspaceID: workspace.id) { settings in
            if clear { settings.agentLaunchers = [] } else { settings.agentLaunchers = [AgentLauncher(name: name!, command: command!)] }
        }
        guard let updated = try orchestrator.workspaceSettings(workspaceID: workspace.id) else {
            throw ValidationError("Workspace settings missing at: \(normalizedWorkspaceDir)")
        }
        try emitJSON(
            WorkspaceSettingsPayload(
                stopScript: updated.stopScript, ports: updated.ports.map(\.name),
                processes: updated.processes.map { .init(name: $0.name, command: $0.command) },
                browserSessions: updated.browserSessions.map { .init(name: $0.name, url: $0.url) },
                agentLaunchers: updated.agentLaunchers.map { .init(name: $0.name, command: $0.command) }))
    }
}

private struct FocusableWindowNamesCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "focusable-window-names")

    @Option(name: .long) var workspaceDir: String

    /// Returns the current indexed focus order used by direct window shortcuts
    /// and CLI numeric focus paths so the shell harness can align its keyboard
    /// assertions with production ordering.
    func run() throws {
        let orchestrator = try makeOrchestrator()
        let normalizedWorkspaceDir = normalizePath(workspaceDir)
        guard let workspace = try orchestrator.store.workspace(dir: normalizedWorkspaceDir) else {
            throw ValidationError("Workspace not found at: \(normalizedWorkspaceDir)")
        }
        try emitJSON(["names": try orchestrator.workspaceFocusableWindowNames(workspaceID: workspace.id)])
    }
}

private struct ArchiveWorkspaceCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "archive-workspace")

    @Option(name: .long) var workspaceDir: String

    /// Archives one workspace through the production lifecycle path so the
    /// manual harness can fall back when the archive confirmation UI is flaky.
    func run() throws {
        let orchestrator = try makeOrchestrator()
        let normalizedWorkspaceDir = normalizePath(workspaceDir)
        guard let workspace = try orchestrator.store.workspace(dir: normalizedWorkspaceDir) else {
            throw ValidationError("Workspace not found at: \(normalizedWorkspaceDir)")
        }
        _ = try orchestrator.archiveWorkspace(workspaceID: workspace.id)
        guard let updated = try orchestrator.store.workspace(id: workspace.id) else {
            throw ValidationError("Workspace disappeared: \(workspace.id)")
        }
        try emitJSON(
            WorkspaceSummaryPayload(
                id: updated.id, title: updated.title, dir: updated.dir, isArchived: updated.isArchived, isRunning: updated.isRunning,
                notes: updated.notes))
    }
}

private struct ClearWorkspaceAgentWindowsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "clear-workspace-agent-windows")

    @Option(name: .long) var workspaceDir: String

    func run() throws {
        let orchestrator = try makeOrchestrator()
        let normalizedWorkspaceDir = normalizePath(workspaceDir)
        guard let workspace = try orchestrator.store.workspace(dir: normalizedWorkspaceDir) else {
            throw ValidationError("Workspace not found at: \(normalizedWorkspaceDir)")
        }
        try orchestrator.store.deleteAgentWindows(workspaceID: workspace.id)
        try emitJSON(["workspaceID": workspace.id, "cleared": "true"])
    }
}

private struct SetWorkspaceStopScriptCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "set-workspace-stop-script")

    @Option(name: .long) var workspaceDir: String
    @Option(name: .long) var stopScript: String

    /// Updates one workspace override through the production workspace-settings
    /// path so the shell harness can validate persisted override behavior
    /// without depending on nested text-editor accessibility.
    func run() throws {
        let orchestrator = try makeOrchestrator()
        let normalizedWorkspaceDir = normalizePath(workspaceDir)
        guard let workspace = try orchestrator.store.workspace(dir: normalizedWorkspaceDir) else {
            throw ValidationError("Workspace not found at: \(normalizedWorkspaceDir)")
        }
        try orchestrator.updateWorkspaceSettings(workspaceID: workspace.id) { settings in settings.stopScript = stopScript }
        guard let updated = try orchestrator.store.workspace(dir: normalizedWorkspaceDir) else {
            throw ValidationError("Workspace disappeared at: \(normalizedWorkspaceDir)")
        }
        try emitJSON(
            WorkspaceSummaryPayload(
                id: updated.id, title: updated.title, dir: updated.dir, isArchived: updated.isArchived, isRunning: updated.isRunning,
                notes: updated.notes))
    }
}

private struct SetWorkspaceBrowserSessionURLsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "set-workspace-browser-session-urls")

    @Option(name: .long) var workspaceDir: String
    @Option(name: .long) var docsURL: String
    @Option(name: .long) var adminURL: String

    /// Rewrites the standard manual-E2E browser session URLs for one workspace
    /// so concurrent fixture workspaces can be distinguished reliably in
    /// Chrome-window focus and cycling assertions.
    func run() throws {
        let orchestrator = try makeOrchestrator()
        let normalizedWorkspaceDir = normalizePath(workspaceDir)
        guard let workspace = try orchestrator.store.workspace(dir: normalizedWorkspaceDir) else {
            throw ValidationError("Workspace not found at: \(normalizedWorkspaceDir)")
        }
        try orchestrator.updateWorkspaceSettings(workspaceID: workspace.id) { settings in
            settings.browserSessions = settings.browserSessions.map { session in
                var updated = session
                switch session.name {
                case "docs": updated.url = docsURL
                case "admin": updated.url = adminURL
                default: break
                }
                return updated
            }
        }
        guard let updated = try orchestrator.store.workspace(dir: normalizedWorkspaceDir) else {
            throw ValidationError("Workspace disappeared at: \(normalizedWorkspaceDir)")
        }
        try emitJSON(
            WorkspaceSummaryPayload(
                id: updated.id, title: updated.title, dir: updated.dir, isArchived: updated.isArchived, isRunning: updated.isRunning,
                notes: updated.notes))
    }
}

private struct AddWorkspaceProcessCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "add-workspace-process")

    @Option(name: .long) var workspaceDir: String
    @Option(name: .long) var name: String
    @Option(name: .long) var command: String

    /// Appends one process template through the production workspace-settings
    /// path so the real-system harness can introduce additional runtime load
    /// without scripting the nested settings UI.
    func run() throws {
        let orchestrator = try makeOrchestrator()
        let normalizedWorkspaceDir = normalizePath(workspaceDir)
        guard let workspace = try orchestrator.store.workspace(dir: normalizedWorkspaceDir) else {
            throw ValidationError("Workspace not found at: \(normalizedWorkspaceDir)")
        }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedCommand = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { throw ValidationError("Missing process name.") }
        guard !trimmedCommand.isEmpty else { throw ValidationError("Missing process command.") }
        try orchestrator.updateWorkspaceSettings(workspaceID: workspace.id) { settings in
            settings.processes.removeAll { ($0.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines) == trimmedName }
            settings.processes.append(ProcessTemplate(name: trimmedName, command: trimmedCommand, executionMode: .shell))
        }
        guard let updated = try orchestrator.workspaceSettings(workspaceID: workspace.id) else {
            throw ValidationError("Workspace settings missing at: \(normalizedWorkspaceDir)")
        }
        try emitJSON(
            WorkspaceSettingsPayload(
                stopScript: updated.stopScript, ports: updated.ports.map(\.name),
                processes: updated.processes.map { .init(name: $0.name, command: $0.command) },
                browserSessions: updated.browserSessions.map { .init(name: $0.name, url: $0.url) },
                agentLaunchers: updated.agentLaunchers.map { .init(name: $0.name, command: $0.command) }))
    }
}

private struct RemoveWorkspaceProcessCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "remove-workspace-process")

    @Option(name: .long) var workspaceDir: String
    @Option(name: .long) var name: String

    func run() throws {
        let orchestrator = try makeOrchestrator()
        let normalizedWorkspaceDir = normalizePath(workspaceDir)
        guard let workspace = try orchestrator.store.workspace(dir: normalizedWorkspaceDir) else {
            throw ValidationError("Workspace not found at: \(normalizedWorkspaceDir)")
        }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { throw ValidationError("Missing process name.") }
        try orchestrator.updateWorkspaceSettings(workspaceID: workspace.id) { settings in
            settings.processes.removeAll { ($0.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines) == trimmedName }
        }
        guard let updated = try orchestrator.workspaceSettings(workspaceID: workspace.id) else {
            throw ValidationError("Workspace settings missing at: \(normalizedWorkspaceDir)")
        }
        try emitJSON(
            WorkspaceSettingsPayload(
                stopScript: updated.stopScript, ports: updated.ports.map(\.name),
                processes: updated.processes.map { .init(name: $0.name, command: $0.command) },
                browserSessions: updated.browserSessions.map { .init(name: $0.name, url: $0.url) },
                agentLaunchers: updated.agentLaunchers.map { .init(name: $0.name, command: $0.command) }))
    }
}

private struct SeedFixturePayload: Codable {
    let projectID: String
    let defaultWorkspace: WorkspaceSummaryPayload?
}

private struct WorkspaceDumpPayload: Codable {
    let workspace: WorkspaceSummaryPayload
    let settings: WorkspaceSettingsPayload?
    let runningProcesses: [RunningProcessPayload]
    let windows: [WindowPayload]
    let agentWindows: [AgentWindowPayload]
}

private struct TerminatedTerminalSessionPayload: Codable {
    let sessionID: String
    let terminated: Bool
}

private struct MobilePairingWindowPayload: Codable {
    let host: String
    let port: Int
    let bonjourServiceName: String
    let pairingLink: String
    let pairingCode: String
    let pairingNonce: String
    let transportKey: String
    let expiresAt: String
    let message: String
}

private struct WorkspaceSummaryPayload: Codable {
    let id: String
    let title: String
    let dir: String
    let isArchived: Bool
    let isRunning: Bool
    let notes: String?
}

private struct WorkspaceSettingsPayload: Codable {
    let stopScript: String?
    let ports: [String]
    let processes: [NamedCommandPayload]
    let browserSessions: [NamedURLPayload]
    let agentLaunchers: [NamedCommandPayload]
}

private struct NamedCommandPayload: Codable {
    let name: String?
    let command: String
}

private struct NamedURLPayload: Codable {
    let name: String?
    let url: String?
}

private struct RunningProcessPayload: Codable {
    let id: String
    let name: String
    let pid: Int?
    let status: String
    let terminalApp: String?
    let terminalTrackingID: String?
    let terminalNativeID: String?
    let tmuxWindowID: String?
    let windowID: Int?
}

private struct WindowPayload: Codable {
    let name: String?
    let app: String
    let role: String
    let detail: String?
    let targetURL: String?
    let windowID: Int?
    let terminalTrackingID: String?
    let terminalNativeID: String?
    let itermTabIndex: Int?
}

private struct AgentWindowPayload: Codable {
    let id: String
    let label: String?
    let provider: String
    let status: String
    let terminalTrackingID: String?
    let terminalNativeID: String?
    let windowID: Int?
    let yabaiWindowID: Int?
}

private struct SurfaceSnapshotPayload: Codable {
    let frontmostProcessID: Int?
    let frontmostApplicationName: String?
    let frontmostApplicationBundleID: String?
    let yabaiFocusedWindowID: Int?
    let spaces: SpacesSurfacePayload?
}

private struct SpacesSurfacePayload: Codable {
    let processID: Int
    let appVisible: Bool
    let frontWindowIdentifier: String?
    let frontWindowTitle: String?
    let frontWindowKind: String
    let mainWindowVisible: Bool
    let mainWindowFocused: Bool
    let commandPaletteVisible: Bool
    let commandPaletteFocused: Bool
    let modalVisible: Bool
}

private struct ScrollApplicationWindowPayload: Codable {
    let executableName: String
    let windowTitle: String?
    let pointX: CGFloat
    let pointY: CGFloat
    let deltaY: Int
    let repetitions: Int
    let firstScrollEventUptimeNanoseconds: UInt64
    let lastScrollEventUptimeNanoseconds: UInt64
    let success: Bool
}

private struct TypeApplicationWindowPayload: Codable {
    let executableName: String
    let windowTitle: String?
    let pointX: CGFloat
    let pointY: CGFloat
    let textByteCount: Int
    let firstKeyDownUptimeNanoseconds: UInt64
    let lastKeyUpUptimeNanoseconds: UInt64
    let success: Bool
}

private struct DragApplicationWindowPayload: Codable {
    let executableName: String
    let windowTitle: String?
    let startX: CGFloat
    let startY: CGFloat
    let endX: CGFloat
    let endY: CGFloat
    let success: Bool
}

private struct TargetApplicationWindow {
    let application: NSRunningApplication
    let window: AXUIElement
    let title: String?
    let frame: CGRect
}

private struct KeyboardTextTiming {
    let firstKeyDownUptimeNanoseconds: UInt64
    let lastKeyUpUptimeNanoseconds: UInt64
}

private struct KeyEventTiming {
    let downUptimeNanoseconds: UInt64
    let upUptimeNanoseconds: UInt64
}

private struct ScrollEventTiming {
    let firstScrollEventUptimeNanoseconds: UInt64
    let lastScrollEventUptimeNanoseconds: UInt64
}

/// Looks up one workspace by project directory and title, matching the GUI's
/// visible naming semantics rather than internal IDs.
private func workspaceSummary(orchestrator: WorkspaceOrchestrator, projectDir: String, title: String) throws -> WorkspaceSummaryPayload? {
    let normalizedProjectDir = normalizePath(projectDir)
    guard let project = try orchestrator.project(dir: normalizedProjectDir) else { return nil }
    guard let workspace = try orchestrator.listWorkspaces(projectID: project.id, includeArchived: true).first(where: { $0.title == title }) else {
        return nil
    }
    return WorkspaceSummaryPayload(
        id: workspace.id, title: workspace.title, dir: workspace.dir, isArchived: workspace.isArchived, isRunning: workspace.isRunning,
        notes: workspace.notes)
}

/// Shared JSON encoder for the shell harness.
private func emitJSON<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    FileHandle.standardOutput.write(try encoder.encode(value))
    FileHandle.standardOutput.write(Data("\n".utf8))
}

/// Builds the same real orchestrator used by the app and CLI so the manual E2E
/// helper exercises production storage and lifecycle code.
private func makeOrchestrator() throws -> WorkspaceOrchestrator { try WorkspaceOrchestrator(store: .init(path: DatabaseLocator.defaultPath())) }

/// Normalizes filesystem paths before lookups so shell callers can pass either
/// relative or absolute values safely.
private func normalizePath(_ path: String) -> String { URL(fileURLWithPath: path).standardizedFileURL.path }

private func terminalShellPath(_ explicitPath: String?) -> String {
    if let explicitPath = explicitPath?.trimmingCharacters(in: .whitespacesAndNewlines), !explicitPath.isEmpty { return explicitPath }
    if let configured = ProcessInfo.processInfo.environment["SHELL"]?.trimmingCharacters(in: .whitespacesAndNewlines), !configured.isEmpty {
        return configured
    }
    return "/bin/zsh"
}

private func terminalDefaultTitle(command: String?, cwd: String) -> String {
    if let command = command?.trimmingCharacters(in: .whitespacesAndNewlines), !command.isEmpty { return command }
    let name = URL(fileURLWithPath: cwd).lastPathComponent
    return name.isEmpty ? "Terminal" : name
}

private func snapshotSpacesSurface(pid: Int32, frontmostPID: Int?) -> SpacesSurfacePayload {
    let appElement = AXUIElementCreateApplication(pid)
    let windows = axElementArrayAttribute(appElement, attribute: kAXWindowsAttribute)
    let focusedWindow =
        axElementAttribute(appElement, attribute: kAXFocusedWindowAttribute) ?? axElementAttribute(appElement, attribute: kAXMainWindowAttribute)
    let appVisible = !(NSRunningApplication(processIdentifier: pid)?.isHidden ?? true)

    let frontWindowIdentifier = focusedWindow.flatMap { axStringAttribute($0, attribute: kAXIdentifierAttribute as String) }
    let frontWindowTitle = focusedWindow.flatMap { axStringAttribute($0, attribute: kAXTitleAttribute as String) }
    let frontWindowKind = classifySpacesWindow(focusedWindow)

    let mainWindow = windows.first { window in
        let identifier = axStringAttribute(window, attribute: kAXIdentifierAttribute as String)
        let title = axStringAttribute(window, attribute: kAXTitleAttribute as String)
        return identifier == "spaces-main-window" || title == "Spaces"
    }
    let paletteWindow = windows.first { window in axStringAttribute(window, attribute: kAXIdentifierAttribute as String) == "spaces-command-palette" }

    let mainWindowVisible = appVisible && mainWindow.map(isVisibleWindow) == true
    let commandPaletteVisible = appVisible && paletteWindow.map(isVisibleWindow) == true
    let mainWindowFocused = frontmostPID == Int(pid) && frontWindowKind == "main"
    let commandPaletteFocused = frontmostPID == Int(pid) && frontWindowKind == "palette"
    let modalVisible =
        appVisible
        && windows.contains { window in
            guard isVisibleWindow(window) else { return false }
            if axStringAttribute(window, attribute: kAXSubroleAttribute as String) == kAXDialogSubrole as String { return true }
            return !axElementArrayAttribute(window, attribute: "AXSheets").isEmpty
        }

    return SpacesSurfacePayload(
        processID: Int(pid), appVisible: appVisible, frontWindowIdentifier: frontWindowIdentifier, frontWindowTitle: frontWindowTitle,
        frontWindowKind: frontWindowKind, mainWindowVisible: mainWindowVisible, mainWindowFocused: mainWindowFocused,
        commandPaletteVisible: commandPaletteVisible, commandPaletteFocused: commandPaletteFocused, modalVisible: modalVisible)
}

private func classifySpacesWindow(_ window: AXUIElement?) -> String {
    guard let window else { return "none" }
    let identifier = axStringAttribute(window, attribute: kAXIdentifierAttribute as String) ?? ""
    let title = axStringAttribute(window, attribute: kAXTitleAttribute as String) ?? ""
    let subrole = axStringAttribute(window, attribute: kAXSubroleAttribute as String) ?? ""

    if subrole == kAXDialogSubrole as String { return "modal" }
    if identifier == "spaces-command-palette" { return "palette" }
    if identifier == "spaces-main-window" { return "main" }
    if identifier.hasPrefix("spaces-terminal:") { return title.hasSuffix(" (viewer)") ? "terminal_viewer" : "terminal_owner" }
    if title == "Spaces" { return "main" }
    if title.hasSuffix(" (viewer)") { return "terminal_viewer" }
    if !title.isEmpty { return "terminal_owner" }
    return "other"
}

private func isVisibleWindow(_ window: AXUIElement) -> Bool {
    if axBoolAttribute(window, attribute: kAXMinimizedAttribute) == true { return false }
    if axBoolAttribute(window, attribute: "AXVisible") == false { return false }
    return true
}

private func axAttributeValue(_ element: AXUIElement, attribute: String) -> CFTypeRef? {
    var value: CFTypeRef?
    let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
    guard result == .success else { return nil }
    return value
}

private func axElementAttribute(_ element: AXUIElement, attribute: String) -> AXUIElement? {
    axAttributeValue(element, attribute: attribute) as! AXUIElement?
}

private func axElementArrayAttribute(_ element: AXUIElement, attribute: String) -> [AXUIElement] {
    (axAttributeValue(element, attribute: attribute) as? [AXUIElement]) ?? []
}

@discardableResult private func axPerformAction(_ element: AXUIElement, action: String) -> Bool {
    AXUIElementPerformAction(element, action as CFString) == .success
}

private func axStringAttribute(_ element: AXUIElement, attribute: String) -> String? { axAttributeValue(element, attribute: attribute) as? String }

private func axBoolAttribute(_ element: AXUIElement, attribute: String) -> Bool? {
    (axAttributeValue(element, attribute: attribute) as? NSNumber)?.boolValue
}

private func axWindowFrame(_ element: AXUIElement) -> CGRect? {
    guard let position = axCGPointAttribute(element, attribute: kAXPositionAttribute as String),
        let size = axCGSizeAttribute(element, attribute: kAXSizeAttribute as String)
    else { return nil }
    return CGRect(origin: position, size: size)
}

private func axCGPointAttribute(_ element: AXUIElement, attribute: String) -> CGPoint? {
    guard let value = axAttributeValue(element, attribute: attribute) else { return nil }
    guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
    let axValue = unsafeDowncast(value, to: AXValue.self)
    guard AXValueGetType(axValue) == .cgPoint else { return nil }
    var point = CGPoint.zero
    guard AXValueGetValue(axValue, .cgPoint, &point) else { return nil }
    return point
}

private func axCGSizeAttribute(_ element: AXUIElement, attribute: String) -> CGSize? {
    guard let value = axAttributeValue(element, attribute: attribute) else { return nil }
    guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
    let axValue = unsafeDowncast(value, to: AXValue.self)
    guard AXValueGetType(axValue) == .cgSize else { return nil }
    var size = CGSize.zero
    guard AXValueGetValue(axValue, .cgSize, &size) else { return nil }
    return size
}

private func targetApplicationWindow(executableName: String, windowTitleContains: String?) throws -> TargetApplicationWindow {
    let executableName = executableName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !executableName.isEmpty else { throw ValidationError("Missing executable name.") }
    let titleFilter = windowTitleContains?.trimmingCharacters(in: .whitespacesAndNewlines)
    let applications = NSWorkspace.shared.runningApplications.filter { $0.executableURL?.lastPathComponent == executableName }
    guard !applications.isEmpty else { throw ValidationError("Application not running: executable-name \(executableName)") }
    for application in applications {
        let appElement = AXUIElementCreateApplication(application.processIdentifier)
        let windows = axElementArrayAttribute(appElement, attribute: kAXWindowsAttribute).filter(isVisibleWindow)
        let window =
            if let titleFilter, !titleFilter.isEmpty {
                windows.first {
                    guard let title = axStringAttribute($0, attribute: kAXTitleAttribute as String) else { return false }
                    return title.localizedStandardContains(titleFilter)
                }
            } else {
                axElementAttribute(appElement, attribute: kAXFocusedWindowAttribute) ?? axElementAttribute(
                    appElement, attribute: kAXMainWindowAttribute) ?? windows.first
            }
        guard let window else { continue }
        guard let frame = axWindowFrame(window) else { continue }
        return TargetApplicationWindow(
            application: application, window: window, title: axStringAttribute(window, attribute: kAXTitleAttribute as String), frame: frame)
    }
    throw ValidationError("No accessible window found for executable-name \(executableName)")
}

private func postMouseClick(at point: CGPoint) throws {
    guard let downEvent = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left),
        let upEvent = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)
    else { throw ValidationError("Unable to create mouse click event.") }
    downEvent.post(tap: .cghidEventTap)
    Thread.sleep(forTimeInterval: 0.02)
    upEvent.post(tap: .cghidEventTap)
}

private func postMouseDrag(from startPoint: CGPoint, to endPoint: CGPoint, durationMS: Int, steps: Int) throws {
    let source = CGEventSource(stateID: .hidSystemState)
    guard let downEvent = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: startPoint, mouseButton: .left),
        let upEvent = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: endPoint, mouseButton: .left)
    else { throw ValidationError("Unable to create mouse drag event.") }
    downEvent.post(tap: .cghidEventTap)
    let delay = steps > 0 ? Double(durationMS) / Double(steps) / 1000.0 : 0
    for step in 1...steps {
        let progress = CGFloat(step) / CGFloat(steps)
        let point = CGPoint(x: startPoint.x + (endPoint.x - startPoint.x) * progress, y: startPoint.y + (endPoint.y - startPoint.y) * progress)
        guard let dragEvent = CGEvent(mouseEventSource: source, mouseType: .leftMouseDragged, mouseCursorPosition: point, mouseButton: .left) else {
            throw ValidationError("Unable to create mouse drag event.")
        }
        dragEvent.post(tap: .cghidEventTap)
        if delay > 0 { Thread.sleep(forTimeInterval: delay) }
    }
    upEvent.post(tap: .cghidEventTap)
}

private func postKeyboardText(_ text: String, interKeyDelayMS: Int) throws -> KeyboardTextTiming {
    let source = CGEventSource(stateID: .hidSystemState)
    var firstKeyDownUptimeNanoseconds: UInt64?
    var lastKeyUpUptimeNanoseconds: UInt64?
    for unit in text.utf16 {
        let timing = if unit == 0x0A { try postVirtualKey(CGKeyCode(kVK_Return), source: source) } else { try postUnicodeKey(unit, source: source) }
        firstKeyDownUptimeNanoseconds = firstKeyDownUptimeNanoseconds ?? timing.downUptimeNanoseconds
        lastKeyUpUptimeNanoseconds = timing.upUptimeNanoseconds
        if interKeyDelayMS > 0 { Thread.sleep(forTimeInterval: Double(interKeyDelayMS) / 1000.0) }
    }
    guard let firstKeyDownUptimeNanoseconds, let lastKeyUpUptimeNanoseconds else { throw ValidationError("No keyboard events were posted.") }
    return KeyboardTextTiming(firstKeyDownUptimeNanoseconds: firstKeyDownUptimeNanoseconds, lastKeyUpUptimeNanoseconds: lastKeyUpUptimeNanoseconds)
}

private func postUnicodeKey(_ unit: UInt16, source: CGEventSource?) throws -> KeyEventTiming {
    var character = UniChar(unit)
    guard let downEvent = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
        let upEvent = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
    else { throw ValidationError("Unable to create keyboard event.") }
    downEvent.keyboardSetUnicodeString(stringLength: 1, unicodeString: &character)
    upEvent.keyboardSetUnicodeString(stringLength: 1, unicodeString: &character)
    let downUptimeNanoseconds = DispatchTime.now().uptimeNanoseconds
    downEvent.post(tap: .cghidEventTap)
    upEvent.post(tap: .cghidEventTap)
    return KeyEventTiming(downUptimeNanoseconds: downUptimeNanoseconds, upUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds)
}

private func postVirtualKey(_ keyCode: CGKeyCode, source: CGEventSource?) throws -> KeyEventTiming {
    guard let downEvent = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
        let upEvent = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
    else { throw ValidationError("Unable to create keyboard event.") }
    let downUptimeNanoseconds = DispatchTime.now().uptimeNanoseconds
    downEvent.post(tap: .cghidEventTap)
    upEvent.post(tap: .cghidEventTap)
    return KeyEventTiming(downUptimeNanoseconds: downUptimeNanoseconds, upUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds)
}

private func postScrollEvent(at point: CGPoint, deltaY: Int, repetitions: Int) throws -> ScrollEventTiming {
    guard let moveEvent = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left) else {
        throw ValidationError("Unable to create mouse move event.")
    }
    moveEvent.post(tap: .cghidEventTap)

    let phases: [NSEvent.Phase]
    if repetitions <= 1 { phases = [.began, .ended] } else { phases = [.began] + Array(repeating: .changed, count: repetitions - 1) + [.ended] }

    var firstScrollEventUptimeNanoseconds: UInt64?
    var lastScrollEventUptimeNanoseconds: UInt64?
    for phase in phases {
        let phaseDeltaY = phase == .ended ? 0 : deltaY
        guard let scrollEvent = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: Int32(phaseDeltaY), wheel2: 0, wheel3: 0)
        else { throw ValidationError("Unable to create scroll event.") }
        scrollEvent.location = point
        scrollEvent.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        scrollEvent.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase.rawValue))
        scrollEvent.setIntegerValueField(.scrollWheelEventMomentumPhase, value: 0)
        scrollEvent.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: Int64(phaseDeltaY))
        scrollEvent.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: Int64(phaseDeltaY))
        let scrollEventUptimeNanoseconds = DispatchTime.now().uptimeNanoseconds
        scrollEvent.post(tap: .cghidEventTap)
        firstScrollEventUptimeNanoseconds = firstScrollEventUptimeNanoseconds ?? scrollEventUptimeNanoseconds
        lastScrollEventUptimeNanoseconds = DispatchTime.now().uptimeNanoseconds
        Thread.sleep(forTimeInterval: 0.05)
    }
    guard let firstScrollEventUptimeNanoseconds, let lastScrollEventUptimeNanoseconds else { throw ValidationError("No scroll events were posted.") }
    return ScrollEventTiming(
        firstScrollEventUptimeNanoseconds: firstScrollEventUptimeNanoseconds, lastScrollEventUptimeNanoseconds: lastScrollEventUptimeNanoseconds)
}

MXE2ECommand.main()
