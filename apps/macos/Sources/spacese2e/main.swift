import AppKit
import ApplicationServices
import ArgumentParser
import Carbon
import Dispatch
import Foundation
import Network
import spacesmobilebridge
import spacesmobilecore
import spacesterminalcore
import systembridge
import workspacecore

/// Small manual-testing helper that exposes fixture seeding and state-dump
/// commands without expanding the user-facing `spaces` CLI surface.
struct SpacesE2ECommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "spacese2e", abstract: "Manual real-system test helpers for Spaces.",
        subcommands: [
            SeedFixtureCommand.self, CleanupFixturesCommand.self, CreateWorkspaceCommand.self, LookupWorkspaceCommand.self,
            ShowMainWindowCommand.self, HideMainWindowCommand.self, ShowWindowIssueModalCommand.self, SelectWorkspaceDetailCommand.self,
            OpenWorkspaceTerminalCommand.self, RunWorkspaceProcessCommand.self, StopWorkspaceProcessCommand.self, RestartWorkspaceProcessCommand.self,
            LaunchWorkspaceAgentCommand.self, DumpWorkspaceCommand.self, FocusableWindowNamesCommand.self, ArchiveWorkspaceCommand.self,
            StopWorkspaceCommand.self, StopFixturesCommand.self, SetWorkspaceBrowserSessionURLsCommand.self, SetWorkspaceAgentLaunchersCommand.self,
            ClearWorkspaceAgentWindowsCommand.self, SetWorkspaceStopScriptCommand.self, AddWorkspaceProcessCommand.self,
            RemoveWorkspaceProcessCommand.self, FocusWorkspaceWindowCommand.self, FocusWorkspaceWindowIndexCommand.self,
            CycleWorkspaceWindowCommand.self, FocusWorkspaceProcessCommand.self, RecoverWorkspaceProcessCommand.self,
            CloseWorkspaceProcessWindowCommand.self, SurfaceSnapshotCommand.self, CloseTerminalSessionWindowCommand.self,
            FocusTerminalSessionWindowCommand.self, DumpTerminalSessionWindowStateCommand.self, StartTerminalSessionCommand.self,
            StartWorkspaceTerminalSessionCommand.self, TerminateTerminalSessionCommand.self, TerminalServiceStateCommand.self,
            TerminalServiceControlCommand.self, UpsertComputeHostCommand.self, ListComputeHostsCommand.self, DeleteComputeHostCommand.self,
            PlanWorkspaceRuntimeCommand.self, RemoteComputeHostSmokeCommand.self, OpenMobilePairingWindowCommand.self, RecordScreenCommand.self,
            ProfileShowCommand.self, ProfileAppOwnerCommand.self, ProfileDesktopControlOwnerCommand.self, ProfileWaitForDesktopControlCommand.self,
            MobileStatusCommand.self, MobileServeCommand.self, MobileRequestCommand.self, ScrollApplicationWindowCommand.self,
            TypeApplicationWindowCommand.self, DragApplicationWindowCommand.self,
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

private struct StartWorkspaceTerminalSessionCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "start-workspace-terminal-session")

    @Option(name: .long) var workspaceDir: String
    @Option(name: .long) var command: String?
    @Option(name: .long) var title: String?

    /// Creates a workspace-owned Spaces terminal session without opening a Mac
    /// window. The production orchestrator resolves the workspace's effective
    /// compute host, so the helper exercises the same local or remote daemon
    /// routing as app and mobile entry points.
    func run() throws {
        let orchestrator = try makeOrchestrator()
        let normalizedWorkspaceDir = normalizePath(workspaceDir)
        guard let workspace = try orchestrator.store.workspace(dir: normalizedWorkspaceDir) else {
            throw ValidationError("Workspace not found at: \(normalizedWorkspaceDir)")
        }
        let session = try orchestrator.createWorkspaceTerminalSession(workspaceID: workspace.id, title: title, command: command)
        try emitJSON(session)
    }
}

private struct TerminateTerminalSessionCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "terminate-terminal-session")

    @Argument(help: "Terminal session ID.") var sessionID: String

    func run() throws {
        let trimmedSessionID = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSessionID.isEmpty else { throw ValidationError("Missing terminal session ID.") }
        if try makeOrchestrator().stopAdHocBuiltInTerminalSession(sessionID: trimmedSessionID) {
            try emitJSON(TerminatedTerminalSessionPayload(sessionID: trimmedSessionID, terminated: true))
            return
        }
        try TerminalService.terminateSession(id: trimmedSessionID)
        try emitJSON(TerminatedTerminalSessionPayload(sessionID: trimmedSessionID, terminated: true))
    }
}

private struct TerminalServiceStateCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "terminal-service-state")

    @Option(name: .long) var sessionID: String

    func run() throws {
        let response = try sendTerminalServiceRequestForSession(sessionID: sessionID, request: TerminalServiceRequest(command: "state"))
        try emitJSON(response)
    }
}

private struct TerminalServiceControlCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "terminal-service-control")

    @Option(name: .long) var sessionID: String
    @Option(name: .long) var command: String
    @Option(name: .long) var text: String?
    @Option(name: .long) var key: String?
    @Option(name: .long) var clientID: String?
    @Option(name: .long) var clientKind: String?
    @Option(name: .long) var clientLabel: String?
    @Option(name: .long) var clientDeviceName: String?
    @Option(name: .long) var clientNetworkAddress: String?
    @Option(name: .long) var attachmentMode: String?
    @Option(name: .long) var scrollHorizontal: Double?
    @Option(name: .long) var scrollVertical: Double?
    @Option(name: .long) var scrollMods: Int32?
    @Flag(name: .long) var directControl = false
    @Flag(name: .long) var appendNewline = false

    func run() throws {
        let trimmedCommand = try required(command, label: "command")
        let trimmedSessionID = try required(sessionID, label: "session-id")
        let normalizedClientID = normalizedOptional(clientID)
        let client = try terminalClientFromOptions(clientID: normalizedClientID)
        let parsedAttachmentMode = try terminalAttachmentModeFromOption(attachmentMode)
        let controlRequest = TerminalControlRequest(
            command: trimmedCommand, text: text, key: key, clientID: normalizedClientID, client: client, attachmentMode: parsedAttachmentMode,
            columns: nil, rows: nil, ownerEpoch: nil, resizeSerial: nil, scrollHorizontal: scrollHorizontal, scrollVertical: scrollVertical,
            scrollMods: scrollMods, appendNewline: appendNewline)
        if directControl {
            let paths = try TerminalSessionPaths.forSession(id: trimmedSessionID)
            let response = try TerminalControlClient.send(request: controlRequest, socketPath: paths.controlSocketPath)
            try emitJSON(response)
            return
        }
        let response = try sendTerminalServiceRequestForSession(
            sessionID: trimmedSessionID, request: TerminalServiceRequest(command: "control", controlRequest: controlRequest))
        try emitJSON(response.controlResponse ?? TerminalControlResponse(ok: response.ok, message: response.message))
    }

    private func terminalClientFromOptions(clientID: String?) throws -> TerminalClient? {
        let provided = [clientKind, clientLabel, clientDeviceName, clientNetworkAddress].contains { normalizedOptional($0) != nil }
        guard provided else { return nil }
        guard let clientID else { throw ValidationError("Missing client-id for client payload.") }
        guard let clientKindValue = normalizedOptional(clientKind) else { throw ValidationError("Missing client-kind for client payload.") }
        guard let kind = TerminalClientKind(rawValue: clientKindValue) else { throw ValidationError("Unsupported client-kind '\(clientKindValue)'.") }
        guard let label = normalizedOptional(clientLabel) else { throw ValidationError("Missing client-label for client payload.") }
        return TerminalClient(
            id: clientID, kind: kind,
            identity: TerminalClientIdentity(
                label: label, deviceName: normalizedOptional(clientDeviceName), networkAddress: normalizedOptional(clientNetworkAddress)),
            connectedAt: nowISO8601())
    }

    private func terminalAttachmentModeFromOption(_ value: String?) throws -> TerminalAttachmentMode? {
        guard let value = normalizedOptional(value) else { return nil }
        guard let mode = TerminalAttachmentMode(rawValue: value) else { throw ValidationError("Unsupported attachment-mode '\(value)'.") }
        return mode
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
                certificateFingerprint: link.certificateFingerprint, expiresAt: ISO8601DateFormatter().string(from: window.expiresAt),
                message: response.message))
    }
}

private struct ProfileShowCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "profile-show", abstract: "Show resolved Spaces profile paths for harnesses.")

    @Flag(name: .long, help: "Emit shell exports for SPACES_DB_PATH and SPACES_RUNTIME_DIR.") var shell = false
    @Flag(name: .long, help: "Emit JSON instead of text.") var json = false

    func run() throws {
        let profile = try SpacesProfile.current()
        let payload = ProfilePayload(profile: profile)
        if shell {
            print("export \(SpacesProfile.databasePathEnvironmentVariable)=\(profileShellQuoted(profile.databasePath))")
            print("export \(SpacesProfile.runtimeDirectoryEnvironmentVariable)=\(profileShellQuoted(profile.runtimeDirectory))")
            return
        }
        if json {
            try emitJSON(payload)
            return
        }

        print("source\t\(profile.source.rawValue)")
        print("profile-root\t\(profile.rootDirectory)")
        print("database-path\t\(profile.databasePath)")
        print("runtime-dir\t\(profile.runtimeDirectory)")
        print("ipc-object\t\(profile.ipcNotificationObject)")
        if let worktreeRoot = payload.worktreeRoot { print("worktree-root\t\(worktreeRoot)") }
        if let branch = payload.branchName { print("branch\t\(branch)") }
    }
}

private struct ProfileAppOwnerCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "profile-app-owner", abstract: "Show the running Spaces app owner for this profile.")

    @Flag(name: .long, help: "Emit JSON instead of text.") var json = false

    func run() throws {
        let profile = try SpacesProfile.current()
        let owner = try SpacesLeaseCoordinator.currentProfileAppOwner(profile: profile)
        let payload = LeaseStatePayload(available: owner == nil, profileRoot: profile.rootDirectory, owner: owner)
        if json {
            try emitJSON(payload)
            return
        }

        guard let owner else {
            print("No running Spaces app owns profile \(profile.rootDirectory).")
            return
        }
        print("pid=\(owner.pid)\texecutable=\(owner.executablePath)\tprofile-root=\(owner.profileRoot ?? profile.rootDirectory)")
    }
}

private struct ProfileDesktopControlOwnerCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "profile-desktop-control-owner", abstract: "Show which Spaces instance owns desktop-global control.")

    @Flag(name: .long, help: "Emit JSON instead of text.") var json = false

    func run() throws {
        let owner = try SpacesLeaseCoordinator.currentDesktopControlOwner()
        let payload = LeaseStatePayload(available: owner == nil, profileRoot: owner?.profileRoot, owner: owner)
        if json {
            try emitJSON(payload)
            return
        }

        guard let owner else {
            print("Desktop control is available.")
            return
        }
        print("pid=\(owner.pid)\texecutable=\(owner.executablePath)\tprofile-root=\(owner.profileRoot ?? "unknown")")
    }
}

private struct ProfileWaitForDesktopControlCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "profile-wait-for-desktop-control", abstract: "Wait until no Spaces instance owns desktop-global control.")

    @Option(name: .long, help: "Wait timeout in seconds. Defaults to SPACES_REAL_SYSTEM_WAIT_TIMEOUT_SECONDS or 600.") var timeoutSeconds: Double?

    func run() throws {
        let envTimeoutSeconds = Double(ProcessInfo.processInfo.environment["SPACES_REAL_SYSTEM_WAIT_TIMEOUT_SECONDS"] ?? "")
        let effectiveTimeoutSeconds = timeoutSeconds ?? envTimeoutSeconds ?? 600
        if let owner = try SpacesLeaseCoordinator.currentDesktopControlOwner() { deliverDesktopControlBusyNotification(owner: owner) }
        let available = try SpacesLeaseCoordinator.waitForDesktopControlAvailability(timeoutSeconds: effectiveTimeoutSeconds) { line in print(line) }
        if available {
            print("Desktop control is available.")
            return
        }

        let owner = try SpacesLeaseCoordinator.currentDesktopControlOwner()
        let detail =
            owner.map { "Owner pid=\($0.pid) executable=\($0.executablePath) profile=\($0.profileRoot ?? "unknown")." }
            ?? "Owner metadata is no longer available."
        let message = "Desktop control remained busy for \(Int(effectiveTimeoutSeconds)) seconds. \(detail) Retry this workflow once the owner exits."
        FileHandle.standardError.write(Data("\(message)\n".utf8))
        throw ExitCode.failure
    }
}

private struct MobileStatusCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "mobile-status", abstract: "Show daemon mobile bridge status for harnesses.")

    func run() throws {
        let response = try SpacesMobileBridgeControlClient.statusEnsuringCurrentTerminalService()
        guard response.ok else { throw ValidationError(response.message) }
        guard let status = response.status else { throw ValidationError("Mobile bridge status response did not include address details.") }
        try emitJSON(status)
    }
}

private struct MobileServeCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "mobile-serve", abstract: "Run a standalone mobile bridge for harnesses.")

    @Option(name: .long, help: "TCP host to bind. Defaults to all IPv4 interfaces for iPhone and simulator access.") var host =
        SpacesMobileBridgeDefaults.host
    @Option(name: .long, help: "TCP port to bind. Defaults to the stable first-party mobile bridge port.") var port = SpacesMobileBridgeDefaults.port
    @Option(name: .long, help: "One-time pairing code accepted by the first-party iOS client. Defaults to a generated 8-digit code.") var pairingCode:
        String?
    @Option(name: .long, help: "Number of one-time pairing windows to emit in standalone harness mode.") var pairingWindowCount = 1

    func run() throws {
        guard pairingWindowCount > 0 else { throw ValidationError("--pairing-window-count must be greater than zero.") }
        let trimmedPairingCode = pairingCode?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedPairingCode =
            if let trimmedPairingCode, !trimmedPairingCode.isEmpty { trimmedPairingCode } else {
                SpacesMobilePairingCoordinator.generatePairingCode()
            }
        let transportKey = SpacesMobileBridgeSettings.generateTransportKey()
        let pairingWindowEmitter = MobileServePairingWindowEmitter(
            bindHost: host, totalWindowCount: pairingWindowCount, firstPairingCode: resolvedPairingCode)
        let server = try SpacesMobileBridgeServer(host: host, port: port, transportKey: transportKey) { _ in
            pairingWindowEmitter.openNextWindow(label: "Spaces mobile pairing window")
        }
        pairingWindowEmitter.server = server
        try server.start()
        pairingWindowEmitter.linkHost = mobileServePairingLinkHost(host: host)
        pairingWindowEmitter.openNextWindow(label: "Spaces mobile bridge ready")
        withExtendedLifetime(server) { dispatchMain() }
    }
}

private struct MobileRequestCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "mobile-request", abstract: "Send a TLS-PSK mobile bridge JSON request.")

    @Option(help: "Full spacesmobile:// pairing link. Supplies host, port, transport key, code, and nonce.") var pairingLink: String?
    @Option(help: "Mobile bridge host. Defaults to the pairing link host or 127.0.0.1.") var host: String?
    @Option(help: "Mobile bridge port. Defaults to the pairing link port.") var port: Int?
    @Option(help: "Base64url mobile bridge transport key. Defaults to the pairing link PSK.") var transportKey: String?
    @Option(help: "JSON bridge request. Reads stdin when omitted.") var requestJSON: String?
    @Flag(help: "Keep the connection open and print newline-delimited bridge messages.") var stream = false

    func run() throws {
        let link = try pairingLink.map { try SpacesMobilePairingLink.parse($0) }
        let resolvedHost = host ?? link?.host ?? "127.0.0.1"
        guard let resolvedPort = port ?? link?.port else { throw ValidationError("Provide --port or a pairing link.") }
        guard (1...65_535).contains(resolvedPort) else { throw ValidationError("Port must be between 1 and 65535.") }
        guard let resolvedTransportKey = transportKey ?? link?.transportKey else {
            throw ValidationError("Provide --transport-key or a pairing link.")
        }

        var requestData = try readRequestData()
        if let link { requestData = try requestDataByApplying(pairingLink: link, to: requestData) }

        let client = MobileBridgeRequestClient(host: resolvedHost, port: UInt16(resolvedPort), transportKey: resolvedTransportKey)
        if stream {
            try client.stream(requestData: requestData)
        } else {
            let responseData = try client.request(requestData: requestData)
            FileHandle.standardOutput.write(responseData)
            FileHandle.standardOutput.write(Data([0x0A]))
        }
    }

    private func readRequestData() throws -> Data {
        if let requestJSON { return Data(requestJSON.utf8) }
        let data = FileHandle.standardInput.readDataToEndOfFile()
        guard !data.isEmpty else { throw ValidationError("Provide --request-json or request JSON on stdin.") }
        return data
    }

    private func requestDataByApplying(pairingLink link: SpacesMobilePairingLink, to data: Data) throws -> Data {
        guard var payload = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ValidationError("Request JSON must be an object.")
        }
        if payload["command"] as? String == "pair" {
            payload["pairingCode"] = payload["pairingCode"] ?? link.code
            payload["pairingNonce"] = payload["pairingNonce"] ?? link.nonce
        }
        return try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
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

private struct UpsertComputeHostCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "upsert-compute-host")

    @Option(name: .long) var id: String
    @Option(name: .long) var name: String
    @Option(name: .long) var sshHost: String
    @Option(name: .long) var sshUser: String?
    @Option(name: .long) var sshPort: Int?
    @Option(name: .long) var workspaceRoot: String
    @Option(name: .long) var daemonHost: String
    @Option(name: .long) var daemonPort: Int
    @Option(name: .long) var certificateFingerprint: String

    func run() throws {
        let orchestrator = try makeOrchestrator()
        let hostID = try required(id, label: "id")
        let now = nowISO8601()
        let existing = try orchestrator.store.computeHost(id: hostID)
        let host = ComputeHostRecord(
            id: hostID, name: try required(name, label: "name"), sshHost: try required(sshHost, label: "ssh-host"),
            sshUser: normalizedOptional(sshUser), sshPort: try validOptionalPort(sshPort, label: "ssh-port"),
            workspaceRoot: normalizeRemoteRoot(try required(workspaceRoot, label: "workspace-root")),
            daemonEndpoint: SpacesDaemonEndpoint(
                host: try required(daemonHost, label: "daemon-host"), port: try validPort(daemonPort, label: "daemon-port"),
                certificateFingerprint: try required(certificateFingerprint, label: "certificate-fingerprint")),
            createdAt: existing?.createdAt ?? now, updatedAt: now)
        try orchestrator.upsertComputeHost(host)
        try emitJSON(computeHostPayload(host))
    }
}

private struct ListComputeHostsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list-compute-hosts")

    func run() throws {
        let orchestrator = try makeOrchestrator()
        try emitJSON(ComputeHostListPayload(hosts: try orchestrator.listComputeHosts().map(computeHostPayload)))
    }
}

private struct DeleteComputeHostCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "delete-compute-host")

    @Option(name: .long) var id: String

    func run() throws {
        let orchestrator = try makeOrchestrator()
        let result = try orchestrator.deleteComputeHost(id: try required(id, label: "id"))
        try emitJSON(deleteComputeHostPayload(result))
    }
}

private struct PlanWorkspaceRuntimeCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "plan-workspace-runtime")

    @Option(name: .long) var workspaceDir: String

    func run() throws {
        let orchestrator = try makeOrchestrator()
        let normalizedWorkspaceDir = normalizePath(workspaceDir)
        guard let workspace = try orchestrator.store.workspace(dir: normalizedWorkspaceDir) else {
            throw ValidationError("Workspace not found at: \(normalizedWorkspaceDir)")
        }
        let plan = try orchestrator.workspaceRuntimePlan(workspaceID: workspace.id)
        try emitJSON(
            WorkspaceRuntimePlanPayload(
                projectID: plan.project.id, workspace: workspaceSummaryPayload(plan.workspace),
                selection: computeHostSelectionPayload(plan.selection), daemonTarget: daemonTargetPayload(plan.daemonTarget), manifest: plan.manifest,
                remoteSSHURI: plan.remoteSSHURI))
    }
}

private struct RemoteComputeHostSmokeCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "remote-compute-host-smoke")

    @Option(name: .long) var projectDir: String
    @Option(name: .long) var hostID: String
    @Option(name: .long) var sshHost: String
    @Option(name: .long) var name: String?
    @Option(name: .long) var sshUser: String?
    @Option(name: .long) var sshPort: Int?
    @Option(name: .long) var workspaceRoot: String = ComputeHostDraftBuilder.defaultWorkspaceRoot
    @Option(name: .long) var daemonHost: String?
    @Option(name: .long) var daemonPort: Int = ComputeHostDraftBuilder.defaultDaemonPort
    @Option(name: .long) var authToken: String?
    @Option(name: .long) var timeoutSeconds: Double = 45

    func run() throws {
        let orchestrator = try makeOrchestrator()
        let normalizedProjectDir = normalizePath(projectDir)
        let project = try orchestrator.project(dir: normalizedProjectDir) ?? orchestrator.addProject(dir: normalizedProjectDir)
        guard let workspace = try orchestrator.store.workspace(dir: project.dir) else {
            throw ValidationError("Default workspace not found for project: \(project.dir)")
        }

        let host = try initialHost(orchestrator: orchestrator)
        let explicitToken = normalizedOptional(authToken)
        let token = explicitToken ?? ComputeHostCredentialStore.generateAuthToken()
        let outcome = try ComputeHostBootstrapper().startSpacesDaemon(
            host: host, authToken: token, timeout: timeoutSeconds, cleanExistingProfile: true)
        let readyHost = host.updatedForBootstrap(outcome)
        let status = try ping(host: readyHost, authToken: token)
        try orchestrator.upsertComputeHost(readyHost)
        if explicitToken == nil {
            try ComputeHostCredentialStore.saveAuthToken(token, hostID: readyHost.id)
        } else {
            fputs("spacese2e: skipping Keychain token storage because --auth-token was supplied.\n", stderr)
        }
        guard let remoteBranch = workspace.branch ?? project.defaultBranch else {
            throw ValidationError("Default workspace branch not found for project: \(project.dir)")
        }
        let remoteWorkspace = try orchestrator.createWorkspaceOnHost(
            projectID: project.id, name: "\(workspace.title) on \(readyHost.name)", branch: remoteBranch, hostID: readyHost.id,
            targetBranch: workspace.targetBranch ?? project.defaultBranch, notes: workspace.notes, runSetupScript: false,
            allowRemoteBranchLookup: false, allowExistingBranchReuse: true)
        let runtimePlan = try orchestrator.workspaceRuntimePlan(workspaceID: remoteWorkspace.id)
        guard runtimePlan.selection.computeHostID == readyHost.id else {
            throw ValidationError("Workspace runtime plan did not resolve to compute host \(readyHost.id).")
        }
        guard runtimePlan.selection.isRemote else { throw ValidationError("Workspace runtime plan resolved to local Mac.") }

        let terminalSessionID = try orchestrator.openWorkspaceTerminal(workspaceID: remoteWorkspace.id)
        let stopOutcome = try orchestrator.stopWorkspace(workspaceID: remoteWorkspace.id)
        try emitJSON(
            RemoteComputeHostSmokePayload(
                host: computeHostPayload(readyHost), bootstrap: bootstrapOutcomePayload(outcome),
                status: RemoteComputeHostSmokeStatusPayload(ok: status.ok, message: status.message, servicePID: status.servicePID),
                projectID: project.id, workspace: workspaceSummaryPayload(remoteWorkspace),
                runtimePlan: WorkspaceRuntimePlanPayload(
                    projectID: runtimePlan.project.id, workspace: workspaceSummaryPayload(runtimePlan.workspace),
                    selection: computeHostSelectionPayload(runtimePlan.selection), daemonTarget: daemonTargetPayload(runtimePlan.daemonTarget),
                    manifest: runtimePlan.manifest, remoteSSHURI: runtimePlan.remoteSSHURI), terminalSessionID: terminalSessionID,
                stopOutcome: WorkspaceStopOutcomePayload(
                    skippedStopScriptBecauseWorkspaceDirectoryMissing: stopOutcome.skippedStopScriptBecauseWorkspaceDirectoryMissing)))
    }

    private func initialHost(orchestrator: WorkspaceOrchestrator) throws -> ComputeHostRecord {
        let id = try required(hostID, label: "host-id")
        let now = nowISO8601()
        let existing = try orchestrator.store.computeHost(id: id)
        let requiredSSHHost = try required(sshHost, label: "ssh-host")
        let endpointHost = normalizedOptional(daemonHost) ?? requiredSSHHost
        return ComputeHostRecord(
            id: id, name: normalizedOptional(name) ?? id, sshHost: requiredSSHHost, sshUser: normalizedOptional(sshUser),
            sshPort: try validOptionalPort(sshPort, label: "ssh-port"), workspaceRoot: normalizeRemoteRoot(workspaceRoot),
            daemonEndpoint: SpacesDaemonEndpoint(
                host: endpointHost, port: try validPort(daemonPort, label: "daemon-port"),
                certificateFingerprint: existing?.daemonEndpoint.certificateFingerprint ?? ""), createdAt: existing?.createdAt ?? now, updatedAt: now)
    }

    private func ping(host: ComputeHostRecord, authToken: String) throws -> TerminalServiceResponse {
        let response = try TerminalServiceClient.sendPinnedTLS(
            request: TerminalServiceRequest(command: "ping"), host: host.daemonEndpoint.host, port: host.daemonEndpoint.port, authToken: authToken,
            certificateFingerprint: host.daemonEndpoint.certificateFingerprint, timeout: 10)
        guard response.ok else { throw ValidationError("Remote spacesd ping failed: \(response.message)") }
        return response
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
        let frontendCommand = fixtureServiceCommand(
            executable: "/usr/bin/env",
            arguments: [
                "python3", "-m", "spaces_e2e_demo", "frontend", "--port", "$APP_PORT", "--site-dir", ".spaces-e2e-demo/site", "--backend-url",
                "http://127.0.0.1:$API_PORT",
            ])
        let backendCommand = fixtureServiceCommand(
            executable: "/usr/bin/env",
            arguments: ["python3", "-m", "spaces_e2e_demo", "backend", "--port", "$API_PORT", "--data-dir", ".spaces-e2e-demo/api"])
        let fixturePorts = [PortDefinition(name: "APP_PORT"), PortDefinition(name: "API_PORT")]
        let fixtureStopScript =
            #"bash -lc 'for port in "$APP_PORT" "$API_PORT"; do if [ -n "$port" ]; then pids=(); while IFS= read -r pid; do [ -n "$pid" ] && pids+=("$pid"); done < <(lsof -tiTCP:"$port" -sTCP:LISTEN 2>/dev/null || true); for pid in "${pids[@]}"; do kill "$pid" >/dev/null 2>&1 || true; done; sleep 0.5; for pid in "${pids[@]}"; do kill -0 "$pid" >/dev/null 2>&1 && kill -9 "$pid" >/dev/null 2>&1 || true; done; fi; done; printf "project-stop:%s\n" "${SPACES_WORKSPACE_DIR}" >> "${SPACES_E2E_EVENTS_LOG:-/tmp/spaces-e2e-events.log}"'"#
        let fixtureProcesses = [
            ProcessTemplate(name: "frontend", command: frontendCommand), ProcessTemplate(name: "backend", command: backendCommand),
        ]
        let fixtureBrowserSessions = [BrowserSession(name: "docs", url: docsURL), BrowserSession(name: "admin", url: adminURL)]
        let fixtureAgentLaunchers: [AgentLauncher] = []

        try orchestrator.updateProjectConfig(projectID: project.id) { config in
            config.ports = fixturePorts
            config.stopScript = fixtureStopScript
            config.processes = fixtureProcesses
            config.browserSessions = fixtureBrowserSessions
            config.agentLaunchers = fixtureAgentLaunchers
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
            try orchestrator.updateWorkspaceSettings(workspaceID: workspace.id) { settings in
                settings.stopScript = fixtureStopScript
                settings.ports = fixturePorts
                settings.processes = fixtureProcesses.map { ProcessTemplate(name: $0.name, command: $0.command, kind: $0.kind, onExit: $0.onExit) }
                settings.browserSessions = fixtureBrowserSessions
                settings.agentLaunchers = fixtureAgentLaunchers
            }
        }

        let payload = SeedFixturePayload(
            projectID: project.id,
            defaultWorkspace: try orchestrator.store.workspace(dir: project.dir).map {
                WorkspaceSummaryPayload(id: $0.id, title: $0.title, dir: $0.dir, isArchived: $0.isArchived, isRunning: $0.isRunning, notes: $0.notes)
            })
        try emitJSON(payload)
    }

    /// Resolves the executable up front because the seeded process command is
    /// launched by the GUI app, not by an interactive shell that necessarily
    /// inherits the user's PATH customizations.
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

    private func fixtureServiceCommand(executable: String, arguments: [String]) -> String {
        let joinedArguments = ([shellQuoted(executable)] + arguments.map(shellToken)).joined(separator: " ")
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
    @Option(name: .long) var host: String = ComputeHostRecord.localHostID
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
        let workspace = try orchestrator.createWorkspaceOnHost(
            projectID: project.id, name: title, branch: branch, hostID: host, targetBranch: targetBranch, directoryName: directoryName, notes: notes,
            runSetupScript: false, allowRemoteBranchLookup: false, allowExistingBranchReuse: existingBranch)
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
                    terminalTrackingID: $0.terminalTrackingID, terminalNativeID: $0.terminalNativeID, windowID: $0.windowID)
            },
            windows: try orchestrator.windows(workspaceID: workspace.id).map {
                WindowPayload(
                    name: $0.name, app: $0.app, role: $0.role, detail: $0.detail, targetURL: $0.targetURL, windowID: $0.windowID,
                    terminalTrackingID: $0.terminalTrackingID, terminalNativeID: $0.terminalNativeID)
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

private struct FocusWorkspaceWindowCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "focus-workspace-window")

    @Option(name: .long) var workspaceDir: String
    @Option(name: .long) var name: String

    func run() throws {
        let orchestrator = try makeOrchestrator()
        let normalizedWorkspaceDir = normalizePath(workspaceDir)
        guard let workspace = try orchestrator.store.workspace(dir: normalizedWorkspaceDir) else {
            throw ValidationError("Workspace not found at: \(normalizedWorkspaceDir)")
        }
        try orchestrator.focusWorkspaceWindow(workspaceID: workspace.id, name: name)
        try emitJSON(["workspaceID": workspace.id, "name": name])
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

private struct FocusTerminalSessionWindowCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "focus-terminal-session-window")

    @Option(name: .long) var sessionID: String
    @Option(name: .long) var requestID: String?

    func run() throws {
        let trimmedSessionID = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSessionID.isEmpty else { throw ValidationError("Missing terminal session id.") }
        let trimmedRequestID = requestID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveRequestID = if let trimmedRequestID, !trimmedRequestID.isEmpty { trimmedRequestID } else { UUID().uuidString }
        DistributedNotificationCenter.default().postNotificationName(
            IPCNotification.focusTerminalSessionWindow, object: try IPCNotification.currentObject(),
            userInfo: [
                IPCNotification.terminalSessionIDUserInfoKey: trimmedSessionID, IPCNotification.focusRequestIDUserInfoKey: effectiveRequestID,
            ], options: [.deliverImmediately])
        try emitJSON(["sessionID": trimmedSessionID, "requestID": effectiveRequestID])
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
            settings.processes.append(ProcessTemplate(name: trimmedName, command: trimmedCommand))
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
    let certificateFingerprint: String
    let expiresAt: String
    let message: String
}

private struct ComputeHostListPayload: Codable { let hosts: [ComputeHostPayload] }

private struct DeleteComputeHostPayload: Codable {
    let hostID: String
    let credentialTokenDeleted: Bool
}

private struct ComputeHostPayload: Codable {
    let id: String
    let name: String
    let kind: String
    let sshHost: String
    let sshUser: String?
    let sshPort: Int?
    let workspaceRoot: String
    let daemonHost: String
    let daemonPort: Int
    let certificateFingerprint: String
    let createdAt: String
    let updatedAt: String
}

private struct WorkspaceRuntimePlanPayload: Codable {
    let projectID: String
    let workspace: WorkspaceSummaryPayload
    let selection: ComputeHostSelectionPayload
    let daemonTarget: SpacesDaemonConnectionTargetPayload
    let manifest: WorkspaceRuntimeManifest
    let remoteSSHURI: String?
}

private struct RemoteComputeHostSmokePayload: Codable {
    let host: ComputeHostPayload
    let bootstrap: ComputeHostBootstrapOutcomePayload
    let status: RemoteComputeHostSmokeStatusPayload
    let projectID: String
    let workspace: WorkspaceSummaryPayload
    let runtimePlan: WorkspaceRuntimePlanPayload
    let terminalSessionID: String
    let stopOutcome: WorkspaceStopOutcomePayload
}

private struct ComputeHostBootstrapOutcomePayload: Codable {
    let certificateFingerprint: String
    let workspaceRoot: String
    let daemonHost: String
    let daemonPort: Int
    let processID: Int?
    let logPath: String
}

private struct RemoteComputeHostSmokeStatusPayload: Codable {
    let ok: Bool
    let message: String
    let servicePID: Int32?
}

private struct WorkspaceStopOutcomePayload: Codable { let skippedStopScriptBecauseWorkspaceDirectoryMissing: Bool }

private struct ComputeHostSelectionPayload: Codable {
    let location: String
    let computeHostID: String?
    let displayName: String
    let host: ComputeHostPayload?
}

private struct SpacesDaemonConnectionTargetPayload: Codable {
    let transport: String
    let computeHostID: String?
    let displayName: String
    let socketPath: String?
    let endpoint: SpacesDaemonEndpointPayload?
}

private struct SpacesDaemonEndpointPayload: Codable {
    let host: String
    let port: Int
    let certificateFingerprint: String
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

private struct ProfilePayload: Codable {
    let source: String
    let databasePath: String
    let profileRoot: String
    let runtimeDirectory: String
    let ipcObject: String
    let worktreeRoot: String?
    let branchName: String?

    init(profile: SpacesProfile) {
        source = profile.source.rawValue
        databasePath = profile.databasePath
        profileRoot = profile.rootDirectory
        runtimeDirectory = profile.runtimeDirectory
        ipcObject = profile.ipcNotificationObject
        worktreeRoot = profile.developmentContext?.worktreeRoot
        branchName = profile.developmentContext?.branchName
    }
}

private struct LeaseStatePayload: Codable {
    let available: Bool
    let profileRoot: String?
    let owner: SpacesProcessLeaseOwner?
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

private func workspaceSummaryPayload(_ workspace: WorkspaceRecord) -> WorkspaceSummaryPayload {
    WorkspaceSummaryPayload(
        id: workspace.id, title: workspace.title, dir: workspace.dir, isArchived: workspace.isArchived, isRunning: workspace.isRunning,
        notes: workspace.notes)
}

private func computeHostPayload(_ host: ComputeHostRecord) -> ComputeHostPayload {
    ComputeHostPayload(
        id: host.id, name: host.name, kind: host.kind.rawValue, sshHost: host.sshHost, sshUser: host.sshUser, sshPort: host.sshPort,
        workspaceRoot: host.workspaceRoot, daemonHost: host.daemonEndpoint.host, daemonPort: host.daemonEndpoint.port,
        certificateFingerprint: host.daemonEndpoint.certificateFingerprint, createdAt: host.createdAt, updatedAt: host.updatedAt)
}

private func deleteComputeHostPayload(_ result: ComputeHostDeletionResult) -> DeleteComputeHostPayload {
    DeleteComputeHostPayload(hostID: result.hostID, credentialTokenDeleted: result.credentialTokenDeleted)
}

private func bootstrapOutcomePayload(_ outcome: ComputeHostBootstrapOutcome) -> ComputeHostBootstrapOutcomePayload {
    ComputeHostBootstrapOutcomePayload(
        certificateFingerprint: outcome.certificateFingerprint, workspaceRoot: outcome.workspaceRoot, daemonHost: outcome.daemonHost,
        daemonPort: outcome.daemonPort, processID: outcome.processID, logPath: outcome.logPath)
}

private func computeHostSelectionPayload(_ selection: ComputeHostSelection) -> ComputeHostSelectionPayload {
    switch selection {
    case .local(let host):
        return ComputeHostSelectionPayload(location: "local", computeHostID: host.id, displayName: selection.displayName, host: nil)
    case .remote(let host):
        return ComputeHostSelectionPayload(
            location: "remote", computeHostID: host.id, displayName: selection.displayName, host: computeHostPayload(host))
    }
}

private func daemonTargetPayload(_ target: SpacesDaemonConnectionTarget) -> SpacesDaemonConnectionTargetPayload {
    SpacesDaemonConnectionTargetPayload(
        transport: target.transport.rawValue, computeHostID: target.computeHostID, displayName: target.displayName, socketPath: target.socketPath,
        endpoint: target.endpoint.map { SpacesDaemonEndpointPayload(host: $0.host, port: $0.port, certificateFingerprint: $0.certificateFingerprint) }
    )
}

extension ComputeHostRecord {
    fileprivate func updatedForBootstrap(_ outcome: ComputeHostBootstrapOutcome) -> ComputeHostRecord {
        ComputeHostRecord(
            id: id, name: name, kind: kind, sshHost: sshHost, sshUser: sshUser, sshPort: sshPort,
            workspaceRoot: outcome.workspaceRoot.isEmpty ? workspaceRoot : outcome.workspaceRoot,
            daemonEndpoint: SpacesDaemonEndpoint(
                host: outcome.daemonHost.isEmpty ? daemonEndpoint.host : outcome.daemonHost,
                port: outcome.daemonPort == 0 ? daemonEndpoint.port : outcome.daemonPort,
                certificateFingerprint: outcome.certificateFingerprint.isEmpty
                    ? daemonEndpoint.certificateFingerprint : outcome.certificateFingerprint), createdAt: createdAt, updatedAt: nowISO8601())
    }
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

private func sendTerminalServiceRequestForSession(sessionID rawSessionID: String, request: TerminalServiceRequest) throws -> TerminalServiceResponse {
    let sessionID = try required(rawSessionID, label: "session-id")
    let request = request.withSessionID(sessionID)
    let orchestrator = try makeOrchestrator()
    if let workspaceID = try orchestrator.workspaceIDForTerminalSession(sessionID) {
        let plan = try orchestrator.workspaceRuntimePlan(workspaceID: workspaceID)
        return try WorkspaceOrchestrator.sendTerminalServiceRequest(to: plan.daemonTarget, request: request)
    }
    let target = SpacesDaemonConnectionTarget(
        transport: .localUnixSocket, computeHostID: nil, displayName: "local Mac", socketPath: try TerminalServicePaths.socketPath())
    return try WorkspaceOrchestrator.sendTerminalServiceRequest(to: target, request: request)
}

extension TerminalServiceRequest {
    fileprivate func withSessionID(_ sessionID: String) -> TerminalServiceRequest {
        TerminalServiceRequest(
            command: command, authToken: authToken, launchConfiguration: launchConfiguration, sessionID: sessionID, runtimeManifest: runtimeManifest,
            worktreeRefresh: worktreeRefresh, workspaceCommand: workspaceCommand, controlRequest: controlRequest, terminalLink: terminalLink,
            terminalLinkID: terminalLinkID, chunkOffset: chunkOffset, chunkLimit: chunkLimit, agentSignal: agentSignal,
            agentSignalEventIDs: agentSignalEventIDs)
    }
}

/// Normalizes filesystem paths before lookups so shell callers can pass either
/// relative or absolute values safely.
private func normalizePath(_ path: String) -> String { URL(fileURLWithPath: path).standardizedFileURL.path }

private func normalizeRemoteRoot(_ path: String) -> String {
    let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed == "/" { return "/" }
    if trimmed == "$HOME" || trimmed.hasPrefix("$HOME/") || trimmed == "~" || trimmed.hasPrefix("~/") { return trimmed }
    return "/" + trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
}

private func normalizedOptional(_ value: String?) -> String? {
    guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
    return value
}

private func required(_ value: String, label: String) throws -> String {
    guard let normalized = normalizedOptional(value) else { throw ValidationError("Missing \(label).") }
    return normalized
}

private func validPort(_ port: Int, label: String) throws -> Int {
    guard (1...65_535).contains(port) else { throw ValidationError("\(label) must be between 1 and 65535.") }
    return port
}

private func validOptionalPort(_ port: Int?, label: String) throws -> Int? {
    guard let port else { return nil }
    return try validPort(port, label: label)
}

private func nowISO8601() -> String { ISO8601DateFormatter().string(from: Date()) }

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

private final class MobileServePairingWindowEmitter: @unchecked Sendable {
    weak var server: SpacesMobileBridgeServer?
    var linkHost = SpacesMobileBridgeDefaults.loopbackHost

    private let lock = NSLock()
    private let bindHost: String
    private let totalWindowCount: Int
    private var emittedWindowCount = 0
    private var nextPairingCode: String?

    init(bindHost: String, totalWindowCount: Int, firstPairingCode: String) {
        self.bindHost = bindHost
        self.totalWindowCount = totalWindowCount
        nextPairingCode = firstPairingCode
    }

    func openNextWindow(label: String) {
        lock.lock()
        guard emittedWindowCount < totalWindowCount, let server else {
            lock.unlock()
            return
        }
        emittedWindowCount += 1
        let code = nextPairingCode ?? SpacesMobilePairingCoordinator.generatePairingCode()
        nextPairingCode = nil
        lock.unlock()

        let window = server.openPairingWindow(host: linkHost, name: "Spaces Standalone", code: code)
        print(
            "\(label)\thost=\(bindHost)\tport=\(server.listeningPort)\tpairing_link=\(window.linkString)\tpairing_code=\(window.code)\texpires_at=\(ISO8601DateFormatter().string(from: window.expiresAt))\tbundle=\(SpacesMobileFirstPartyPolicy.allowedBundleID)"
        )
        fflush(stdout)
    }
}

private final class MobileBridgeRequestClient: @unchecked Sendable {
    private let host: String
    private let port: UInt16
    private let transportKey: String

    init(host: String, port: UInt16, transportKey: String) {
        self.host = host
        self.port = port
        self.transportKey = transportKey
    }

    func request(requestData: Data) throws -> Data {
        let connection = try makeConnection()
        defer { connection.cancel() }
        try waitUntilReady(connection)
        try send(requestData: requestData, connection: connection)
        return try receiveSingleResponse(from: connection)
    }

    func stream(requestData: Data) throws -> Never {
        let connection = try makeConnection()
        try waitUntilReady(connection)
        try send(requestData: requestData, connection: connection)
        receiveStream(from: connection, buffered: Data())
        dispatchMain()
    }

    private func makeConnection() throws -> NWConnection {
        let endpointPort = NWEndpoint.Port(rawValue: port)!
        return NWConnection(
            host: NWEndpoint.Host(host), port: endpointPort,
            using: try SpacesMobileBridgeTransport.parameters(transportKey: transportKey, role: .client))
    }

    private func waitUntilReady(_ connection: NWConnection) throws {
        let queue = DispatchQueue(label: "spaces.e2e.mobile.request")
        let semaphore = DispatchSemaphore(value: 0)
        let box = MobileBridgeRequestResultBox()
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready: semaphore.signal()
            case .failed(let error):
                box.setError(error)
                semaphore.signal()
            default: break
            }
        }
        connection.start(queue: queue)
        guard semaphore.wait(timeout: .now() + 10) == .success else {
            throw MobileBridgeRequestError.timeout("Timed out connecting to the mobile bridge.")
        }
        if let error = box.error() { throw error }
    }

    private func send(requestData: Data, connection: NWConnection) throws {
        var payload = requestData
        payload.append(0x0A)
        let semaphore = DispatchSemaphore(value: 0)
        let box = MobileBridgeRequestResultBox()
        connection.send(
            content: payload,
            completion: .contentProcessed { error in
                if let error { box.setError(error) }
                semaphore.signal()
            })
        guard semaphore.wait(timeout: .now() + 10) == .success else {
            throw MobileBridgeRequestError.timeout("Timed out sending the mobile bridge request.")
        }
        if let error = box.error() { throw error }
    }

    private func receiveSingleResponse(from connection: NWConnection) throws -> Data {
        let semaphore = DispatchSemaphore(value: 0)
        let box = MobileBridgeRequestResultBox()
        receiveSingleResponse(from: connection, buffered: Data(), box: box, semaphore: semaphore)
        guard semaphore.wait(timeout: .now() + 10) == .success else {
            throw MobileBridgeRequestError.timeout("Timed out waiting for the mobile bridge response.")
        }
        if let error = box.error() { throw error }
        return box.responseData()
    }

    private func receiveSingleResponse(
        from connection: NWConnection, buffered data: Data, box: MobileBridgeRequestResultBox, semaphore: DispatchSemaphore
    ) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { content, _, isComplete, error in
            if let error {
                box.setError(error)
                semaphore.signal()
                return
            }
            var nextData = data
            if let content { nextData.append(content) }
            if let newlineIndex = nextData.firstIndex(of: 0x0A) {
                box.setResponseData(Data(nextData.prefix(upTo: newlineIndex)))
                semaphore.signal()
                return
            }
            if isComplete {
                box.setResponseData(nextData)
                semaphore.signal()
                return
            }
            self.receiveSingleResponse(from: connection, buffered: nextData, box: box, semaphore: semaphore)
        }
    }

    private func receiveStream(from connection: NWConnection, buffered data: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { content, _, isComplete, error in
            if let error {
                fputs("\(error)\n", stderr)
                exit(1)
            }
            var nextData = data
            if let content { nextData.append(content) }
            while let newlineIndex = nextData.firstIndex(of: 0x0A) {
                let line = Data(nextData.prefix(upTo: newlineIndex))
                FileHandle.standardOutput.write(line)
                FileHandle.standardOutput.write(Data([0x0A]))
                fflush(stdout)
                nextData.removeSubrange(...newlineIndex)
            }
            if isComplete { exit(0) }
            self.receiveStream(from: connection, buffered: nextData)
        }
    }
}

private enum MobileBridgeRequestError: LocalizedError {
    case timeout(String)

    var errorDescription: String? {
        switch self {
        case .timeout(let message): message
        }
    }
}

private final class MobileBridgeRequestResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storedError: Error?
    private var storedResponseData = Data()

    func setError(_ error: Error) {
        lock.lock()
        storedError = error
        lock.unlock()
    }

    func error() -> Error? {
        lock.lock()
        let error = storedError
        lock.unlock()
        return error
    }

    func setResponseData(_ data: Data) {
        lock.lock()
        storedResponseData = data
        lock.unlock()
    }

    func responseData() -> Data {
        lock.lock()
        let data = storedResponseData
        lock.unlock()
        return data
    }
}

private func mobileServePairingLinkHost(host: String) -> String { SpacesMobileBridgeNetworkInterfaces.pairingLinkHost(boundHost: host) }

private func profileShellQuoted(_ value: String) -> String {
    let escaped = value.replacingOccurrences(of: "'", with: #"'\"'\"'"#)
    return "'\(escaped)'"
}

func deliverDesktopControlBusyNotification(owner: SpacesProcessLeaseOwner) {
    do { _ = try Shell.runAndCapture(["osascript", "-e", desktopControlBusyNotificationScript(owner: owner)]) } catch {
        fputs("spaces: Failed to send desktop control notification: \(error.localizedDescription)\n", stderr)
    }
}

func desktopControlBusyNotificationScript(owner: SpacesProcessLeaseOwner) -> String {
    let ownerName = URL(fileURLWithPath: owner.executablePath).lastPathComponent
    let profileName = owner.profileRoot.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "unknown-profile"
    let title = "Close Spaces When You're Done"
    let subtitle = "A real-system Spaces workflow is waiting"
    let body = "Desktop control is owned by \(ownerName) (pid \(owner.pid), profile \(profileName)). Quit that instance so the harness can continue."
    return """
        display notification \(appleScriptStringLiteral(body)) with title \(appleScriptStringLiteral(title)) subtitle \(appleScriptStringLiteral(subtitle))
        """
}

private func appleScriptStringLiteral(_ value: String) -> String {
    let escaped = value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(
        of: "\r", with: " "
    ).replacingOccurrences(of: "\n", with: " ")
    return "\"\(escaped)\""
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

SpacesE2ECommand.main()
