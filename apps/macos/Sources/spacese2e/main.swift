import AppKit
import ApplicationServices
import ArgumentParser
import Carbon
import Dispatch
import Foundation
import Network
import Security
import spacesclientcore
import spacesdeviceapi
import spacesdevicecore
import spacesterminalcore
import systembridge
import workspacecore

/// Small manual-testing helper that exposes fixture seeding and state-dump
/// commands without expanding the user-facing `spaces` CLI surface.
struct SpacesE2ECommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "spacese2e", abstract: "Manual real-system test helpers for Spaces.",
        subcommands: [
            E2ECommand.self, SeedFixtureCommand.self, CleanupFixturesCommand.self, CreateWorkspaceCommand.self, LookupWorkspaceCommand.self,
            ShowMainWindowCommand.self, HideMainWindowCommand.self, ShowWindowIssueModalCommand.self, SelectWorkspaceDetailCommand.self,
            OpenWorkspaceTerminalCommand.self, RunWorkspaceProcessCommand.self, StopWorkspaceProcessCommand.self, RestartWorkspaceProcessCommand.self,
            LaunchWorkspaceAgentCommand.self, DumpWorkspaceCommand.self, FocusableWindowNamesCommand.self, ArchiveWorkspaceCommand.self,
            HideWorkspaceCommand.self, StopWorkspaceCommand.self, StopFixturesCommand.self, SetWorkspaceBrowserSessionURLsCommand.self,
            SetWorkspaceAgentLaunchersCommand.self, ClearWorkspaceAgentWindowsCommand.self, SetWorkspaceStopScriptCommand.self,
            AddWorkspaceProcessCommand.self, RemoveWorkspaceProcessCommand.self, FocusWorkspaceWindowCommand.self, CycleWorkspaceWindowCommand.self,
            FocusWorkspaceProcessCommand.self, CloseWorkspaceProcessWindowCommand.self, SurfaceSnapshotCommand.self,
            CloseTerminalSessionWindowCommand.self, FocusTerminalSessionWindowCommand.self, DumpTerminalSessionWindowStateCommand.self,
            StartTerminalSessionCommand.self, TerminalSessionWindowShortcutCommand.self, StartWorkspaceTerminalSessionCommand.self,
            TerminateTerminalSessionCommand.self, TerminalServiceStateCommand.self, TerminalServiceControlCommand.self,
            PlanWorkspaceRuntimeCommand.self, OpenDevicePairingWindowCommand.self, PairRemoteDeviceCommand.self,
            OpenRemoteDevicePairingWindowCommand.self, RecordScreenCommand.self, ProfileShowCommand.self, ProfileAppOwnerCommand.self,
            MacClientInstallationIDCommand.self, ProfileSocketPathsCommand.self, ProfileDesktopControlOwnerCommand.self,
            ProfileWaitForDesktopControlCommand.self, MobileStatusCommand.self, MobileServeCommand.self, MobileRequestCommand.self,
            TerminalServiceTLSRequestCommand.self, TerminalServiceTLSSessionCommand.self, RenderUpdateTextCommand.self,
            ScrollApplicationWindowCommand.self, TypeApplicationWindowCommand.self, DragApplicationWindowCommand.self,
        ])
}

private struct ShowMainWindowCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "show-main-window")

    func run() throws {
        try IPCNotification.post(IPCNotification.showMainWindow)
        try emitJSON(["success": true])
    }
}

private struct HideMainWindowCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "hide-main-window")

    func run() throws {
        try IPCNotification.post(IPCNotification.hideMainWindow)
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
    @Option(name: .long) var outputPath: String?

    func run() throws {
        var userInfo = [IPCNotification.titleUserInfoKey: title, IPCNotification.detailUserInfoKey: detail]
        if let outputPath { userInfo[IPCNotification.outputPathUserInfoKey] = outputPath }
        try IPCNotification.post(IPCNotification.showWindowIssueModal, userInfo: userInfo)
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
        try IPCNotification.post(IPCNotification.selectWorkspaceDetail, userInfo: [IPCNotification.workspaceIDUserInfoKey: workspace.id])
        try emitJSON(
            WorkspaceSummaryPayload(
                id: workspace.id, name: workspace.displayName, dir: workspace.dir, isArchived: workspace.isArchived, isRunning: workspace.isRunning,
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
        try IPCNotification.post(IPCNotification.openWorkspaceTerminal, userInfo: [IPCNotification.workspaceIDUserInfoKey: workspace.id])
        try emitJSON(
            WorkspaceSummaryPayload(
                id: workspace.id, name: workspace.displayName, dir: workspace.dir, isArchived: workspace.isArchived, isRunning: workspace.isRunning,
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
    /// daemon, so the helper exercises the same local or paired-device routing
    /// as app and mobile entry points.
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
        let response = try sendTerminalServiceRequestForSession(
            sessionID: sessionID, request: TerminalServiceRequest(command: .state(.init(sessionID: sessionID))))
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
            sessionID: trimmedSessionID,
            request: TerminalServiceRequest(command: .control(.init(sessionID: trimmedSessionID, controlRequest: controlRequest))))
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

private struct OpenDevicePairingWindowCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "open-device-pairing-window")

    @Option(name: .long) var timeoutSeconds: Double = 5

    func run() throws {
        let response = try SpacesDeviceAPIControlClient.openPairingWindowEnsuringCurrentTerminalService(timeout: timeoutSeconds)
        guard response.ok else { throw ValidationError(response.message) }
        guard let status = response.status else { throw ValidationError("Device API response did not include address details.") }
        guard let window = response.pairingWindow else { throw ValidationError("Device API response did not include a pairing window.") }
        let link = try SpacesDevicePairingLink.parse(window.linkString)
        try emitJSON(
            DevicePairingWindowPayload(
                host: status.host, port: status.port, bonjourServiceName: status.bonjourServiceName, pairingLink: window.linkString,
                pairingCode: window.code, pairingNonce: window.nonce, transportKey: link.transportKey,
                certificateFingerprint: link.certificateFingerprint, expiresAt: ISO8601DateFormatter().string(from: window.expiresAt),
                message: response.message))
    }
}

private struct PairRemoteDeviceCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "pair-remote-device", abstract: "Pair this Mac client with a remote spacesd over SSH.")

    @Option(name: .long, help: "Remote SSH host.") var sshHost: String

    @Option(name: .long, help: "Remote SSH user. Defaults to ssh_config or the current user.") var sshUser: String?

    @Option(name: .long, help: "Remote SSH port. Defaults to ssh_config or port 22.") var sshPort: Int?

    func run() throws {
        let result = try SpacesDevicePairingClient.pairRemoteDevice(
            SpacesRemoteDevicePairingRequest(
                sshHost: sshHost, sshUser: normalizedOptional(sshUser), sshPort: sshPort,
                clientInstallationID: SpacesDevicePairingClient.localMacClientInstallationID(),
                clientBundleID: SpacesDeviceFirstPartyPolicy.macOSBundleID, clientDeviceName: Host.current().localizedName ?? "Mac",
                clientAppVersion: AppVersion.short, remoteArtifactPublicKey: AppVersion.remoteArtifactPublicKey))
        try emitJSON(RemoteDevicePairingPayload(deviceID: result.deviceID, name: result.name, host: result.host, port: result.port))
    }
}

private struct OpenRemoteDevicePairingWindowCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "open-remote-device-pairing-window", abstract: "Open a remote spacesd pairing window over SSH for harnesses.")

    @Option(name: .long, help: "Remote SSH host.") var sshHost: String

    @Option(name: .long, help: "Remote SSH user. Defaults to ssh_config or the current user.") var sshUser: String?

    @Option(name: .long, help: "Remote SSH port. Defaults to ssh_config or port 22.") var sshPort: Int?

    func run() throws {
        let device = SpacesPairedDeviceRecord(
            id: "remote-pairing-window", name: "Remote Device", platform: "remote", host: sshHost, port: SpacesDeviceAPIEndpointDefaults.port,
            certificateFingerprint: "", sshHost: sshHost, sshUser: normalizedOptional(sshUser), sshPort: sshPort, createdAt: nowISO8601(),
            updatedAt: nowISO8601())
        let result = try SpacesDevicePairingClient.openRemotePairingWindow(
            for: device, appVersion: AppVersion.short, remoteArtifactPublicKey: AppVersion.remoteArtifactPublicKey)
        let link = try SpacesDevicePairingLink.parse(result.linkString)
        try emitJSON(
            RemoteDevicePairingWindowPayload(
                name: result.name, host: result.host, port: result.port, pairingLink: result.linkString, transportKey: link.transportKey,
                certificateFingerprint: link.certificateFingerprint, expiresAt: result.expiresAt))
    }
}

private struct ProfileShowCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "profile-show", abstract: "Show resolved Spaces profile paths for harnesses.")

    @Flag(name: .long, help: "Emit shell exports for the repo-local Spaces profile.") var shell = false
    @Flag(name: .long, help: "Emit JSON instead of text.") var json = false

    func run() throws {
        let profile = try SpacesProfile.current()
        let payload = ProfilePayload(profile: profile)
        if shell {
            print("export \(SpacesProfile.databasePathEnvironmentVariable)=\(profileShellQuoted(profile.databasePath))")
            print("export \(SpacesProfile.runtimeDirectoryEnvironmentVariable)=\(profileShellQuoted(profile.runtimeDirectory))")
            print("export \(SpacesDeviceAPIDefaults.portEnvironmentVariable)=0")
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

private struct MacClientInstallationIDCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mac-client-installation-id", abstract: "Show this profile's macOS Device API client installation id.")

    func run() throws { print(SpacesDevicePairingClient.localMacClientInstallationID()) }
}

private struct ProfileSocketPathsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "profile-socket-paths", abstract: "Show resolved Spaces terminal socket paths for harnesses.")

    @Option(name: .long, help: "Include paths for a terminal session ID.") var sessionID: String?

    func run() throws {
        let profile = try SpacesProfile.current()
        try emitJSON(ProfileSocketPathsPayload(profile: profile, sessionID: sessionID))
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
    static let configuration = CommandConfiguration(commandName: "mobile-status", abstract: "Show daemon Device API status for harnesses.")

    func run() throws {
        let response = try SpacesDeviceAPIControlClient.statusEnsuringCurrentTerminalService()
        guard response.ok else { throw ValidationError(response.message) }
        guard let status = response.status else { throw ValidationError("Device API status response did not include address details.") }
        try emitJSON(status)
    }
}

private struct MobileServeCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "mobile-serve", abstract: "Run a standalone Device API server for harnesses.")

    @Option(name: .long, help: "TCP host to bind. Defaults to all IPv4 interfaces for iPhone and simulator access.") var host =
        SpacesDeviceAPIDefaults.host
    @Option(name: .long, help: "TCP port to bind. Defaults to the stable first-party Device API port.") var port = SpacesDeviceAPIDefaults.port
    @Option(name: .long, help: "One-time pairing code accepted by the first-party iOS client. Defaults to a generated 8-digit code.") var pairingCode:
        String?
    @Option(name: .long, help: "Number of one-time pairing windows to emit in standalone harness mode.") var pairingWindowCount = 1

    func run() throws {
        guard pairingWindowCount > 0 else { throw ValidationError("--pairing-window-count must be greater than zero.") }
        let trimmedPairingCode = pairingCode?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedPairingCode =
            if let trimmedPairingCode, !trimmedPairingCode.isEmpty { trimmedPairingCode } else {
                SpacesDevicePairingCoordinator.generatePairingCode()
            }
        let transportKey = SpacesDeviceAPISettings.generateTransportKey()
        let pairingWindowEmitter = MobileServePairingWindowEmitter(
            bindHost: host, totalWindowCount: pairingWindowCount, firstPairingCode: resolvedPairingCode)
        let server = try SpacesDeviceAPIServer(host: host, port: port, transportKey: transportKey) { _ in
            pairingWindowEmitter.openNextWindow(label: "Spaces device pairing window")
        }
        pairingWindowEmitter.server = server
        try server.start()
        pairingWindowEmitter.linkHost = mobileServePairingLinkHost(host: host)
        pairingWindowEmitter.openNextWindow(label: "Spaces Device API ready")
        withExtendedLifetime(server) { dispatchMain() }
    }
}

private struct MobileRequestCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "mobile-request", abstract: "Send a TLS-PSK Device API JSON request.")

    @Option(help: "Full spaces:// pairing link. Supplies host, port, transport key, code, and nonce.") var pairingLink: String?
    @Option(help: "Device API host. Defaults to the pairing link host or 127.0.0.1.") var host: String?
    @Option(help: "Device API port. Defaults to the pairing link port.") var port: Int?
    @Option(help: "Base64url Device API transport key. Defaults to the pairing link PSK.") var transportKey: String?
    @Option(help: "JSON Device API request. Reads stdin when omitted.") var requestJSON: String?
    @Flag(help: "Keep the connection open and print newline-delimited Device API messages.") var stream = false
    @Flag(help: "Read newline-delimited Device API requests from stdin and reuse one request connection.") var requestLines = false

    func run() throws {
        let link = try pairingLink.map { try SpacesDevicePairingLink.parse($0) }
        let resolvedHost = host ?? link?.host ?? "127.0.0.1"
        guard let resolvedPort = port ?? link?.port else { throw ValidationError("Provide --port or a pairing link.") }
        guard (1...65_535).contains(resolvedPort) else { throw ValidationError("Port must be between 1 and 65535.") }
        guard let resolvedTransportKey = transportKey ?? link?.transportKey else {
            throw ValidationError("Provide --transport-key or a pairing link.")
        }

        if requestLines {
            guard !stream else { throw ValidationError("--request-lines cannot be combined with --stream.") }
            guard requestJSON == nil else { throw ValidationError("--request-lines reads requests from stdin; omit --request-json.") }
            try sendRequestLines(host: resolvedHost, port: resolvedPort, transportKey: resolvedTransportKey, pairingLink: link)
            return
        }

        var requestData = try readRequestData()
        if let link { requestData = try requestDataByApplying(pairingLink: link, to: requestData) }

        let client = DeviceAPIRequestClient(host: resolvedHost, port: UInt16(resolvedPort), transportKey: resolvedTransportKey)
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

    private func requestDataByApplying(pairingLink link: SpacesDevicePairingLink, to data: Data) throws -> Data {
        guard var payload = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ValidationError("Request JSON must be an object.")
        }
        if payload["command"] as? String == "pair" {
            payload["pairingCode"] = payload["pairingCode"] ?? link.code
            payload["pairingNonce"] = payload["pairingNonce"] ?? link.nonce
        }
        return try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    }

    private func sendRequestLines(host: String, port: Int, transportKey: String, pairingLink link: SpacesDevicePairingLink?) throws {
        let client = try SpacesDeviceAPIRequestSessionClient(host: host, port: port, transportKey: transportKey)
        defer { client.cancel() }
        while let line = readLine(strippingNewline: true) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            var requestData = Data(trimmed.utf8)
            if let link { requestData = try requestDataByApplying(pairingLink: link, to: requestData) }
            let request = try SpacesDeviceAPICodec.decodeRequest(requestData)
            let response = try client.send(request, timeoutSeconds: 30)
            FileHandle.standardOutput.write(try SpacesDeviceAPICodec.encodeResponse(response))
            FileHandle.standardOutput.write(Data([0x0A]))
            fflush(stdout)
        }
    }
}

private struct RenderUpdateTextCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "render-update-text", abstract: "Decode terminal render update payload lines for harnesses.")

    func run() throws {
        let encoder = JSONEncoder()
        var baseline: GhosttyRenderUpdateBaseline?

        while let line = readLine(strippingNewline: true) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            let response: RenderUpdateTextLine
            do {
                let payload = try GhosttyRemoteSessionStateCodec.decodeLine(Data(trimmed.utf8))
                var appliedRenderUpdate = false
                var updateKind: String?
                var applyError: String?

                if let renderUpdate = payload.decodedRenderUpdate {
                    updateKind = renderUpdate.kind.rawValue
                    do {
                        baseline = try GhosttyRenderUpdateApplier.apply(renderUpdate, to: baseline)
                        appliedRenderUpdate = true
                    } catch {
                        baseline = nil
                        applyError = String(describing: error)
                    }
                } else if payload.renderUpdate != nil {
                    baseline = nil
                    applyError = "render_update_decode_failed"
                }

                response = RenderUpdateTextLine(
                    ok: true, hasRenderUpdate: payload.renderUpdate != nil, appliedRenderUpdate: appliedRenderUpdate, updateKind: updateKind,
                    text: baseline.map { GhosttyTerminalSnapshotLayout.plainText(for: $0.snapshot) }, reason: payload.reason,
                    outputByteCount: payload.outputByteCount, screenStateRevision: payload.screenStateRevision, error: applyError)
            } catch {
                response = RenderUpdateTextLine(
                    ok: false, hasRenderUpdate: nil, appliedRenderUpdate: nil, updateKind: nil, text: nil, reason: nil, outputByteCount: nil,
                    screenStateRevision: nil, error: String(describing: error))
            }

            var data = try encoder.encode(response)
            data.append(0x0A)
            FileHandle.standardOutput.write(data)
            fflush(stdout)
        }
    }
}

private struct RenderUpdateTextLine: Encodable {
    let ok: Bool
    let hasRenderUpdate: Bool?
    let appliedRenderUpdate: Bool?
    let updateKind: String?
    let text: String?
    let reason: String?
    let outputByteCount: Int?
    let screenStateRevision: UInt64?
    let error: String?
}

private struct TerminalServiceTLSRequestCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "terminal-service-tls-request", abstract: "Send a pinned-TLS terminal service JSON request.")

    @Option(help: "Remote spacesd host.") var host: String
    @Option(help: "Remote spacesd port.") var port: Int
    @Option(help: "Terminal service auth token.") var authToken: String
    @Option(help: "Expected daemon certificate fingerprint.") var certificateFingerprint: String
    @Option(help: "JSON terminal service request. Reads stdin when omitted.") var requestJSON: String?
    @Flag(help: "Keep the connection open and print newline-delimited terminal state messages.") var stream = false

    func run() throws {
        let request = try readRequest().withAuthToken(authToken)
        if stream {
            try TerminalServiceTLSStreamClient.stream(request: request, host: host, port: port, certificateFingerprint: certificateFingerprint)
            return
        }
        let response = try TerminalServiceClient.sendPinnedTLS(
            request: request, host: host, port: port, authToken: authToken, certificateFingerprint: certificateFingerprint, timeout: 20)
        try emitJSON(response)
    }

    private func readRequest() throws -> TerminalServiceRequest {
        let data: Data
        if let requestJSON { data = Data(requestJSON.utf8) } else { data = FileHandle.standardInput.readDataToEndOfFile() }
        guard !data.isEmpty else { throw ValidationError("Provide --request-json or request JSON on stdin.") }
        return try JSONDecoder().decode(TerminalServiceRequest.self, from: data)
    }
}

private struct TerminalServiceTLSSessionCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "terminal-service-tls-session", abstract: "Send newline-delimited pinned-TLS terminal service JSON requests over one connection."
    )

    @Option(help: "Remote spacesd host.") var host: String
    @Option(help: "Remote spacesd port.") var port: Int
    @Option(help: "Terminal service auth token.") var authToken: String
    @Option(help: "Expected daemon certificate fingerprint.") var certificateFingerprint: String

    func run() throws {
        let client = try TerminalServicePinnedTLSRequestSessionClient(
            host: host, port: port, authToken: authToken, certificateFingerprint: certificateFingerprint)
        defer { client.cancel() }

        while let line = readLine(strippingNewline: true) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            do {
                let request = try JSONDecoder().decode(TerminalServiceRequest.self, from: Data(trimmed.utf8))
                let response = try client.send(request: request, timeout: 20)
                var data = try JSONEncoder().encode(response)
                data.append(0x0A)
                FileHandle.standardOutput.write(data)
            } catch {
                var data = try JSONEncoder().encode(TerminalServiceResponse(ok: false, message: String(describing: error)))
                data.append(0x0A)
                FileHandle.standardOutput.write(data)
                throw error
            }
        }
    }
}

private enum TerminalServiceTLSStreamClient {
    static func stream(request: TerminalServiceRequest, host: String, port: Int, certificateFingerprint: String) throws {
        let expectedFingerprint = certificateFingerprint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !expectedFingerprint.isEmpty else { throw TerminalServiceTLSError.missingCertificateFingerprint }
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else { throw TerminalServiceTLSError.invalidPort(port) }

        let tlsOptions = NWProtocolTLS.Options()
        let securityOptions = tlsOptions.securityProtocolOptions
        sec_protocol_options_set_min_tls_protocol_version(securityOptions, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(securityOptions, .TLSv13)
        sec_protocol_options_set_peer_authentication_required(securityOptions, true)
        let ready = DispatchSemaphore(value: 0)
        let completed = DispatchSemaphore(value: 0)
        let errorBox = TerminalServiceTLSStreamErrorBox()

        sec_protocol_options_set_verify_block(
            securityOptions,
            { _, trust, complete in
                let secTrust = sec_trust_copy_ref(trust).takeRetainedValue()
                let chain = SecTrustCopyCertificateChain(secTrust) as? [SecCertificate]
                guard let certificate = chain?.first else {
                    errorBox.set(TerminalServiceTLSError.peerCertificateUnavailable)
                    ready.signal()
                    complete(false)
                    return
                }
                let actualFingerprint = TerminalServiceTLSFingerprint.fingerprint(certificate: certificate)
                guard TerminalServiceTLSFingerprint.matches(expectedFingerprint, actualFingerprint) else {
                    errorBox.set(TerminalServiceTLSError.certificatePinMismatch(expected: expectedFingerprint, actual: actualFingerprint))
                    ready.signal()
                    complete(false)
                    return
                }
                complete(true)
            }, DispatchQueue.global(qos: .userInitiated))

        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: NWParameters(tls: tlsOptions, tcp: NWProtocolTCP.Options()))
        let queue = DispatchQueue(label: "spaces.e2e.terminal-service-tls-stream")
        let streamSession = TerminalServiceTLSStreamSession(connection: connection, completed: completed, errorBox: errorBox)

        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                ready.signal()
                do {
                    var payload = try JSONEncoder().encode(request)
                    payload.append(0x0A)
                    connection.send(
                        content: payload, contentContext: .defaultMessage, isComplete: false,
                        completion: .contentProcessed { error in
                            if let error {
                                errorBox.set(TerminalServiceTLSError.connectionFailed(String(describing: error)))
                                completed.signal()
                            } else {
                                streamSession.receiveNext()
                            }
                        })
                } catch {
                    errorBox.set(error)
                    completed.signal()
                }
            case .failed(let error):
                errorBox.set(TerminalServiceTLSError.connectionFailed(String(describing: error)))
                ready.signal()
                completed.signal()
            case .cancelled: completed.signal()
            default: break
            }
        }

        connection.start(queue: queue)
        guard ready.wait(timeout: .now() + 20) == .success else {
            connection.cancel()
            throw TerminalServiceTLSError.requestTimedOut
        }
        if let error = errorBox.error {
            connection.cancel()
            throw error
        }
        completed.wait()
        connection.cancel()
        if let error = errorBox.error { throw error }
    }
}

private final class TerminalServiceTLSStreamSession: @unchecked Sendable {
    private let connection: NWConnection
    private let completed: DispatchSemaphore
    private let errorBox: TerminalServiceTLSStreamErrorBox
    private var buffer = Data()

    init(connection: NWConnection, completed: DispatchSemaphore, errorBox: TerminalServiceTLSStreamErrorBox) {
        self.connection = connection
        self.completed = completed
        self.errorBox = errorBox
    }

    func receiveNext() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [self] content, _, isComplete, error in
            if let error {
                errorBox.set(TerminalServiceTLSError.connectionFailed(String(describing: error)))
                completed.signal()
                return
            }
            if let content, !content.isEmpty {
                buffer.append(content)
                while let newlineIndex = buffer.firstIndex(of: 0x0A) {
                    let line = Data(buffer.prefix(through: newlineIndex))
                    FileHandle.standardOutput.write(line)
                    buffer.removeSubrange(buffer.startIndex...newlineIndex)
                }
            }
            if isComplete {
                if !buffer.isEmpty {
                    FileHandle.standardOutput.write(buffer)
                    FileHandle.standardOutput.write(Data([0x0A]))
                }
                completed.signal()
                return
            }
            receiveNext()
        }
    }
}

private final class TerminalServiceTLSStreamErrorBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storedError: Error?

    var error: Error? {
        lock.lock()
        defer { lock.unlock() }
        return storedError
    }

    func set(_ error: Error) {
        lock.lock()
        if storedError == nil { storedError = error }
        lock.unlock()
    }
}

private final class TerminalServiceTLSLineResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storedResult: Result<Data, Error> = .failure(TerminalServiceTLSError.requestTimedOut)

    var value: Result<Data, Error> {
        lock.lock()
        defer { lock.unlock() }
        return storedResult
    }

    func set(_ result: Result<Data, Error>) {
        lock.lock()
        storedResult = result
        lock.unlock()
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
        try IPCNotification.post(
            IPCNotification.runWorkspaceProcess,
            userInfo: [IPCNotification.workspaceIDUserInfoKey: workspace.id, IPCNotification.workspaceTargetNameUserInfoKey: trimmedProcessName])
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
        try IPCNotification.post(
            IPCNotification.stopWorkspaceProcess,
            userInfo: [IPCNotification.workspaceIDUserInfoKey: workspace.id, IPCNotification.workspaceTargetNameUserInfoKey: trimmedProcessName])
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
        try IPCNotification.post(
            IPCNotification.restartWorkspaceProcess,
            userInfo: [IPCNotification.workspaceIDUserInfoKey: workspace.id, IPCNotification.workspaceTargetNameUserInfoKey: trimmedProcessName])
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
        try IPCNotification.post(
            IPCNotification.launchWorkspaceAgent,
            userInfo: [IPCNotification.workspaceIDUserInfoKey: workspace.id, IPCNotification.workspaceTargetNameUserInfoKey: trimmedName])
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
                id: updated.id, name: updated.displayName, dir: updated.dir, isArchived: updated.isArchived, isRunning: updated.isRunning,
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
                selection: spacesDeviceSelectionPayload(plan.selection), daemonTarget: daemonTargetPayload(plan.daemonTarget),
                manifest: plan.manifest, remoteSSHURI: plan.remoteSSHURI))
    }
}

private struct SeedFixtureCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "seed-fixture")

    @Option(name: .long) var projectDir: String
    @Option(name: .long) var docsURL: String
    @Option(name: .long) var adminURL: String

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
                "python3", "-m", "spaces_e2e_demo", "frontend", "--port", "$SPACES_APP_PORT", "--site-dir", ".spaces-e2e-demo/site", "--backend-url",
                "http://127.0.0.1:$SPACES_API_PORT",
            ])
        let backendCommand = fixtureServiceCommand(
            executable: "/usr/bin/env",
            arguments: ["python3", "-m", "spaces_e2e_demo", "backend", "--port", "$SPACES_API_PORT", "--data-dir", ".spaces-e2e-demo/api"])
        let fixturePorts = [ServiceDefinition(name: "app"), ServiceDefinition(name: "api")]
        let fixtureStopScript =
            #"bash -lc 'for port in "$SPACES_APP_PORT" "$SPACES_API_PORT"; do if [ -n "$port" ]; then pids=(); while IFS= read -r pid; do [ -n "$pid" ] && pids+=("$pid"); done < <(lsof -tiTCP:"$port" -sTCP:LISTEN 2>/dev/null || true); for pid in "${pids[@]}"; do kill "$pid" >/dev/null 2>&1 || true; done; sleep 0.5; for pid in "${pids[@]}"; do kill -0 "$pid" >/dev/null 2>&1 && kill -9 "$pid" >/dev/null 2>&1 || true; done; fi; done; printf "project-stop:%s\n" "${SPACES_WORKSPACE_DIR}" >> "${SPACES_E2E_EVENTS_LOG:-/tmp/spaces-e2e-events.log}"'"#
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
                WorkspaceSummaryPayload(
                    id: $0.id, name: $0.displayName, dir: $0.dir, isArchived: $0.isArchived, isRunning: $0.isRunning, notes: $0.notes)
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
        let path = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        process.waitUntilExit()
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
    // The workspace display name (a git workspace's branch, or a non-git workspace's
    // folder name). When omitted, the project's default workspace is returned.
    @Option(name: .long) var name: String?

    /// Resolves a workspace so the shell harness can pivot from its visible name to
    /// stable workspace directories and IDs.
    func run() throws {
        let orchestrator = try makeOrchestrator()
        guard let payload = try workspaceSummary(orchestrator: orchestrator, projectDir: projectDir, name: name) else {
            throw ValidationError("Workspace not found: \(name ?? "<default>")")
        }
        try emitJSON(payload)
    }
}

private struct CreateWorkspaceCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "create-workspace")

    @Option(name: .long) var projectDir: String
    @Option(name: .long) var branch: String
    @Option(name: .long) var baseBranch: String?
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
        let workspace = try orchestrator.createWorkspaceOnDevice(
            projectID: project.id, branch: branch, baseBranch: baseBranch, directoryName: directoryName, notes: notes, runSetupScript: false,
            allowRemoteBranchLookup: false, allowExistingBranchReuse: existingBranch)
        try emitJSON(
            WorkspaceSummaryPayload(
                id: workspace.id, name: workspace.displayName, dir: workspace.dir, isArchived: workspace.isArchived, isRunning: workspace.isRunning,
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
                id: workspace.id, name: workspace.displayName, dir: workspace.dir, isArchived: workspace.isArchived, isRunning: workspace.isRunning,
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
                    terminalTrackingID: $0.terminalTrackingID, terminalNativeID: $0.terminalNativeID)
            },
            windows: try orchestrator.windows(workspaceID: workspace.id).map {
                WindowPayload(
                    name: $0.name, app: $0.app, role: $0.role, detail: $0.detail, targetURL: $0.targetURL,                     terminalTrackingID: $0.terminalTrackingID, terminalNativeID: $0.terminalNativeID)
            },
            agentWindows: try orchestrator.agentWindows(workspaceID: workspace.id).map {
                AgentWindowPayload(
                    id: $0.id, label: $0.label, provider: $0.provider.rawValue, status: $0.status.rawValue, terminalTrackingID: $0.terminalTrackingID,
                    terminalNativeID: $0.terminalNativeID)
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

    /// Drives the running app's client-side process focus over IPC; the app resolves the
    /// running process by name and threads `requestID` to its terminal-focus follow-through.
    func run() throws {
        let workspaceID = try workspaceID(forDir: workspaceDir)
        var userInfo: [String: String] = [
            IPCNotification.workspaceIDUserInfoKey: workspaceID, IPCNotification.workspaceTargetNameUserInfoKey: processName,
        ]
        if let requestID, !requestID.isEmpty { userInfo[IPCNotification.focusRequestIDUserInfoKey] = requestID }
        try IPCNotification.post(IPCNotification.focusWorkspaceProcess, userInfo: userInfo)
        try emitJSON(["workspaceID": workspaceID, "processName": processName, "requestID": requestID ?? ""])
    }
}

private struct FocusWorkspaceWindowCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "focus-workspace-window")

    @Option(name: .long) var workspaceDir: String
    @Option(name: .long) var name: String

    /// Drives the running app's client-side focus-by-name over IPC.
    func run() throws {
        let workspaceID = try workspaceID(forDir: workspaceDir)
        try IPCNotification.post(
            IPCNotification.focusWorkspaceWindowByName,
            userInfo: [IPCNotification.workspaceIDUserInfoKey: workspaceID, IPCNotification.workspaceTargetNameUserInfoKey: name])
        try emitJSON(["workspaceID": workspaceID, "name": name])
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
            try IPCNotification.post(
                IPCNotification.cycleWorkspaceWindow,
                userInfo: [
                    IPCNotification.workspaceIDUserInfoKey: workspace.id, IPCNotification.cycleDirectionUserInfoKey: direction,
                    IPCNotification.focusRequestIDUserInfoKey: requestID,
                ])
        default: throw ValidationError("Unsupported direction: \(direction)")
        }
        try emitJSON(["workspaceID": workspace.id, "direction": direction])
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
        try IPCNotification.post(IPCNotification.closeTerminalSessionWindow, userInfo: [IPCNotification.terminalSessionIDUserInfoKey: sessionID])
        try emitJSON(["workspaceID": workspace.id, "processName": processName, "sessionID": sessionID])
    }
}

private struct CloseTerminalSessionWindowCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "close-terminal-session-window")

    @Option(name: .long) var sessionID: String

    func run() throws {
        let trimmedSessionID = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSessionID.isEmpty else { throw ValidationError("Missing terminal session id.") }
        try IPCNotification.post(
            IPCNotification.closeTerminalSessionWindow, userInfo: [IPCNotification.terminalSessionIDUserInfoKey: trimmedSessionID])
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
        try IPCNotification.post(
            IPCNotification.focusTerminalSessionWindow,
            userInfo: [IPCNotification.terminalSessionIDUserInfoKey: trimmedSessionID, IPCNotification.focusRequestIDUserInfoKey: effectiveRequestID])
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
        try IPCNotification.post(IPCNotification.dumpTerminalSessionWindowState, userInfo: userInfo)
        try emitJSON(["sessionID": trimmedSessionID, "mode": attachmentMode?.rawValue ?? "any", "outputPath": trimmedOutputPath])
    }
}

private struct TerminalSessionWindowShortcutCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "terminal-window-shortcut")

    @Option(name: .long) var sessionID: String
    @Option(name: .long) var action: String
    @Option(name: .long) var text: String?

    func run() throws {
        let trimmedSessionID = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSessionID.isEmpty else { throw ValidationError("Missing terminal session id.") }
        let trimmedAction = action.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedAction.isEmpty else { throw ValidationError("Missing terminal shortcut action.") }
        var userInfo: [String: String] = [
            IPCNotification.terminalSessionIDUserInfoKey: trimmedSessionID, IPCNotification.terminalShortcutActionUserInfoKey: trimmedAction,
        ]
        if let text { userInfo[IPCNotification.terminalShortcutTextUserInfoKey] = text }
        try IPCNotification.post(IPCNotification.performTerminalSessionWindowShortcut, userInfo: userInfo)
        try emitJSON(["sessionID": trimmedSessionID, "action": trimmedAction, "text": text ?? ""])
    }
}

private struct SurfaceSnapshotCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "surface-snapshot")

    @Option(name: .long) var spacesPID: Int32?

    func run() throws {
        let frontmostApplication = NSWorkspace.shared.frontmostApplication
        let frontmostPID = frontmostApplication.map { Int($0.processIdentifier) }
        let spacesSurface = spacesPID.map { snapshotSpacesSurface(pid: $0, frontmostPID: frontmostPID) }
        try emitJSON(
            SurfaceSnapshotPayload(
                frontmostProcessID: frontmostPID, frontmostApplicationName: frontmostApplication?.localizedName,
                frontmostApplicationBundleID: frontmostApplication?.bundleIdentifier, spaces: spacesSurface))
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

    /// Returns the running app's ordered focusable window names (the numbered-shortcut
    /// order) so the shell harness can align its keyboard assertions with production
    /// ordering. The app owns the ordering and writes it to a file over IPC; this command
    /// posts the request, waits for the file, and relays its `{"names": [...]}` to stdout.
    func run() throws {
        let workspaceID = try workspaceID(forDir: workspaceDir)
        let outputURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("spaces-focusable-window-names-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: outputURL) }
        try IPCNotification.post(
            IPCNotification.dumpFocusableWindowNames,
            userInfo: [IPCNotification.workspaceIDUserInfoKey: workspaceID, IPCNotification.outputPathUserInfoKey: outputURL.path])
        let deadline = Date(timeIntervalSinceNow: 5)
        while Date() < deadline {
            if let data = try? Data(contentsOf: outputURL), !data.isEmpty {
                FileHandle.standardOutput.write(data)
                return
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        throw ValidationError("Timed out waiting for focusable window names from the app for workspace: \(workspaceID)")
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
                id: updated.id, name: updated.displayName, dir: updated.dir, isArchived: updated.isArchived, isRunning: updated.isRunning,
                notes: updated.notes))
    }
}

private struct HideWorkspaceCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "hide-workspace")

    @Option(name: .long) var workspaceDir: String

    func run() throws {
        let orchestrator = try makeOrchestrator()
        let normalizedWorkspaceDir = normalizePath(workspaceDir)
        guard let workspace = try orchestrator.store.workspace(dir: normalizedWorkspaceDir) else {
            throw ValidationError("Workspace not found at: \(normalizedWorkspaceDir)")
        }
        try orchestrator.updateWorkspaceHidden(workspaceID: workspace.id, isHidden: true)
        guard let updated = try orchestrator.store.workspace(id: workspace.id) else {
            throw ValidationError("Workspace disappeared: \(workspace.id)")
        }
        try emitJSON(
            WorkspaceSummaryPayload(
                id: updated.id, name: updated.displayName, dir: updated.dir, isArchived: updated.isArchived, isRunning: updated.isRunning,
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
                id: updated.id, name: updated.displayName, dir: updated.dir, isArchived: updated.isArchived, isRunning: updated.isRunning,
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
                id: updated.id, name: updated.displayName, dir: updated.dir, isArchived: updated.isArchived, isRunning: updated.isRunning,
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

private struct DevicePairingWindowPayload: Codable {
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

private struct RemoteDevicePairingPayload: Codable {
    let deviceID: String
    let name: String
    let host: String
    let port: Int
}

private struct RemoteDevicePairingWindowPayload: Codable {
    let name: String
    let host: String
    let port: Int
    let pairingLink: String
    let transportKey: String
    let certificateFingerprint: String
    let expiresAt: String?
}

private struct SpacesDevicePayload: Codable {
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
    let selection: SpacesDeviceSelectionPayload
    let daemonTarget: SpacesDaemonConnectionTargetPayload
    let manifest: WorkspaceRuntimeManifest
    let remoteSSHURI: String?
}

private struct SpacesDeviceSelectionPayload: Codable {
    let location: String
    let deviceID: String?
    let displayName: String
    let device: SpacesDevicePayload?
}

private struct SpacesDaemonConnectionTargetPayload: Codable {
    let transport: String
    let deviceID: String?
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
    let name: String
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
}

private struct WindowPayload: Codable {
    let name: String?
    let app: String
    let role: String
    let detail: String?
    let targetURL: String?
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
}

private struct SurfaceSnapshotPayload: Codable {
    let frontmostProcessID: Int?
    let frontmostApplicationName: String?
    let frontmostApplicationBundleID: String?
    let spaces: SpacesSurfacePayload?
}

private struct SpacesSurfacePayload: Codable {
    let processID: Int
    let appVisible: Bool
    let frontWindowIdentifier: String?
    let frontWindowTitle: String?
    let frontWindowKind: String
    /// Identity of the focused window's active terminal pane (post-panel-rework terminals are
    /// panes inside one shared window, so the window title/identifier no longer encodes them).
    let frontTerminalPaneSessionID: String?
    let frontTerminalPaneMode: String?
    let frontTerminalPaneTitle: String?
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

private struct ProfileSocketPathsPayload: Codable {
    let profileRoot: String
    let runtimeDirectory: String
    let terminalRootDirectory: String
    let serviceSocketPath: String
    let serviceLockPath: String
    let serviceLogPath: String
    let sessionID: String?
    let sessionRootDirectory: String?
    let sessionControlSocketPath: String?
    let sessionSubscriptionSocketPath: String?

    init(profile: SpacesProfile, sessionID: String?) throws {
        self.profileRoot = profile.rootDirectory
        runtimeDirectory = profile.runtimeDirectory
        terminalRootDirectory = try TerminalServicePaths.terminalRootDirectory().path
        serviceSocketPath = try TerminalServicePaths.socketPath()
        serviceLockPath = try TerminalServicePaths.instanceLockPath()
        serviceLogPath = try TerminalServicePaths.logPath()

        let trimmedSessionID = sessionID?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmedSessionID, !trimmedSessionID.isEmpty {
            let sessionPaths = try TerminalSessionPaths.forSession(id: trimmedSessionID)
            self.sessionID = trimmedSessionID
            sessionRootDirectory = sessionPaths.rootDirectory
            sessionControlSocketPath = sessionPaths.controlSocketPath
            sessionSubscriptionSocketPath = sessionPaths.subscriptionSocketPath
        } else {
            self.sessionID = nil
            sessionRootDirectory = nil
            sessionControlSocketPath = nil
            sessionSubscriptionSocketPath = nil
        }
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

/// Looks up one workspace by project directory and display name, matching the GUI's
/// visible naming semantics rather than internal IDs. When `name` is nil, returns the
/// project's default workspace.
private func workspaceSummary(orchestrator: WorkspaceOrchestrator, projectDir: String, name: String?) throws -> WorkspaceSummaryPayload? {
    let normalizedProjectDir = normalizePath(projectDir)
    guard let project = try orchestrator.project(dir: normalizedProjectDir) else { return nil }
    let workspaces = try orchestrator.listWorkspaces(projectID: project.id, includeArchived: true)
    let match: WorkspaceSummary?
    if let name { match = workspaces.first(where: { $0.displayName == name }) } else { match = workspaces.first(where: \.isDefault) }
    guard let workspace = match else { return nil }
    return WorkspaceSummaryPayload(
        id: workspace.id, name: workspace.displayName, dir: workspace.dir, isArchived: workspace.isArchived, isRunning: workspace.isRunning,
        notes: workspace.notes)
}

private func workspaceSummaryPayload(_ workspace: WorkspaceRecord) -> WorkspaceSummaryPayload {
    WorkspaceSummaryPayload(
        id: workspace.id, name: workspace.displayName, dir: workspace.dir, isArchived: workspace.isArchived, isRunning: workspace.isRunning,
        notes: workspace.notes)
}

private func spacesDevicePayload(_ device: SpacesDeviceRecord) -> SpacesDevicePayload {
    SpacesDevicePayload(
        id: device.id, name: device.name, kind: device.kind.rawValue, sshHost: device.sshHost, sshUser: device.sshUser, sshPort: device.sshPort,
        workspaceRoot: device.workspaceRoot, daemonHost: device.daemonEndpoint.host, daemonPort: device.daemonEndpoint.port,
        certificateFingerprint: device.daemonEndpoint.certificateFingerprint, createdAt: device.createdAt, updatedAt: device.updatedAt)
}

private func spacesDeviceSelectionPayload(_ selection: SpacesDeviceSelection) -> SpacesDeviceSelectionPayload {
    switch selection {
    case .local(let device):
        return SpacesDeviceSelectionPayload(location: "local", deviceID: device.id, displayName: selection.displayName, device: nil)
    case .remote(let device):
        return SpacesDeviceSelectionPayload(
            location: "remote", deviceID: device.id, displayName: selection.displayName, device: spacesDevicePayload(device))
    }
}

private func daemonTargetPayload(_ target: SpacesDaemonConnectionTarget) -> SpacesDaemonConnectionTargetPayload {
    SpacesDaemonConnectionTargetPayload(
        transport: target.transport.rawValue, deviceID: target.deviceID, displayName: target.displayName, socketPath: target.socketPath,
        endpoint: target.endpoint.map { SpacesDaemonEndpointPayload(host: $0.host, port: $0.port, certificateFingerprint: $0.certificateFingerprint) }
    )
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
// Desktop window IDs are client-owned (in spaces-client.db), so the e2e harness — which drives real
// desktop focus through an in-process orchestrator just like the app — must inject the same client
// store. Without it the harness would neither persist captured window IDs nor read them back.
private func makeOrchestrator() throws -> WorkspaceOrchestrator { try WorkspaceOrchestrator(store: .init(path: DatabaseLocator.defaultPath())) }

/// Resolves a workspace directory to its stable id from the store. The harness uses this
/// only to address IPC focus commands at the running app; the focus itself runs in the app.
private func workspaceID(forDir dir: String) throws -> String {
    let normalizedWorkspaceDir = normalizePath(dir)
    guard let workspace = try makeOrchestrator().store.workspace(dir: normalizedWorkspaceDir) else {
        throw ValidationError("Workspace not found at: \(normalizedWorkspaceDir)")
    }
    return workspace.id
}

private func sendTerminalServiceRequestForSession(sessionID rawSessionID: String, request: TerminalServiceRequest) throws -> TerminalServiceResponse {
    let sessionID = try required(rawSessionID, label: "session-id")
    let request = request.withSessionID(sessionID)
    let orchestrator = try makeOrchestrator()
    if let workspaceID = try orchestrator.workspaceIDForTerminalSession(sessionID) {
        let plan = try orchestrator.workspaceRuntimePlan(workspaceID: workspaceID)
        return try WorkspaceOrchestrator.sendTerminalServiceRequest(to: plan.daemonTarget, request: request)
    }
    let target = SpacesDaemonConnectionTarget(
        transport: .localUnixSocket, deviceID: nil, displayName: "local Mac", socketPath: try TerminalServicePaths.socketPath())
    return try WorkspaceOrchestrator.sendTerminalServiceRequest(to: target, request: request)
}

extension TerminalServiceRequest {
    fileprivate func withSessionID(_ sessionID: String) -> TerminalServiceRequest {
        let updatedCommand: TerminalServiceCommand
        switch command {
        case .terminate: updatedCommand = .terminate(.init(sessionID: sessionID))
        case .state: updatedCommand = .state(.init(sessionID: sessionID))
        case .subscribe: updatedCommand = .subscribe(.init(sessionID: sessionID))
        case .control(let payload): updatedCommand = .control(.init(sessionID: sessionID, controlRequest: payload.controlRequest))
        case .ackAgentSignals(let payload): updatedCommand = .ackAgentSignals(.init(sessionID: sessionID, eventIDs: payload.eventIDs))
        case .resolveTerminalLink(let payload): updatedCommand = .resolveTerminalLink(.init(sessionID: sessionID, terminalLink: payload.terminalLink))
        case .readTerminalLinkChunk(let payload):
            updatedCommand = .readTerminalLinkChunk(
                .init(sessionID: sessionID, terminalLinkID: payload.terminalLinkID, offset: payload.offset, limit: payload.limit))
        default: updatedCommand = command
        }
        return TerminalServiceRequest(command: updatedCommand, authToken: authToken)
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
    weak var server: SpacesDeviceAPIServer?
    var linkHost = SpacesDeviceAPIDefaults.loopbackHost

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
        let code = nextPairingCode ?? SpacesDevicePairingCoordinator.generatePairingCode()
        nextPairingCode = nil
        lock.unlock()

        let window = server.openPairingWindow(host: linkHost, name: "Spaces Standalone", code: code)
        print(
            "\(label)\thost=\(bindHost)\tport=\(server.listeningPort)\tpairing_link=\(window.linkString)\tpairing_code=\(window.code)\texpires_at=\(ISO8601DateFormatter().string(from: window.expiresAt))\tbundle=\(SpacesDeviceFirstPartyPolicy.allowedBundleID)"
        )
        fflush(stdout)
    }
}

private final class DeviceAPIRequestClient: @unchecked Sendable {
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
            host: NWEndpoint.Host(host), port: endpointPort, using: try SpacesDeviceAPITransport.parameters(transportKey: transportKey, role: .client)
        )
    }

    private func waitUntilReady(_ connection: NWConnection) throws {
        let queue = DispatchQueue(label: "spaces.e2e.mobile.request")
        let semaphore = DispatchSemaphore(value: 0)
        let box = DeviceAPIRequestResultBox()
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
        guard semaphore.wait(timeout: .now() + 10) == .success else { throw DeviceAPIRequestError.timeout("Timed out connecting to the Device API.") }
        if let error = box.error() { throw error }
    }

    private func send(requestData: Data, connection: NWConnection) throws {
        var payload = requestData
        payload.append(0x0A)
        let semaphore = DispatchSemaphore(value: 0)
        let box = DeviceAPIRequestResultBox()
        connection.send(
            content: payload,
            completion: .contentProcessed { error in
                if let error { box.setError(error) }
                semaphore.signal()
            })
        guard semaphore.wait(timeout: .now() + 10) == .success else {
            throw DeviceAPIRequestError.timeout("Timed out sending the Device API request.")
        }
        if let error = box.error() { throw error }
    }

    private func receiveSingleResponse(from connection: NWConnection) throws -> Data {
        let semaphore = DispatchSemaphore(value: 0)
        let box = DeviceAPIRequestResultBox()
        receiveSingleResponse(from: connection, buffered: Data(), box: box, semaphore: semaphore)
        guard semaphore.wait(timeout: .now() + 10) == .success else {
            throw DeviceAPIRequestError.timeout("Timed out waiting for the Device API response.")
        }
        if let error = box.error() { throw error }
        return box.responseData()
    }

    private func receiveSingleResponse(
        from connection: NWConnection, buffered data: Data, box: DeviceAPIRequestResultBox, semaphore: DispatchSemaphore
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
                guard !nextData.isEmpty else {
                    box.setError(DeviceAPIRequestError.emptyResponse)
                    semaphore.signal()
                    return
                }
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

private enum DeviceAPIRequestError: LocalizedError {
    case emptyResponse
    case timeout(String)

    var errorDescription: String? {
        switch self {
        case .emptyResponse: "The Device API connection closed before returning a response."
        case .timeout(let message): message
        }
    }
}

private final class DeviceAPIRequestResultBox: @unchecked Sendable {
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

private func mobileServePairingLinkHost(host: String) -> String { SpacesDeviceAPINetworkInterfaces.pairingLinkHost(boundHost: host) }

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
    let frontTerminalPane =
        focusedTerminalPaneIdentity(appElement: appElement) ?? focusedWindow.flatMap { firstTerminalPaneIdentity(in: $0) }

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
        frontWindowKind: frontWindowKind, frontTerminalPaneSessionID: frontTerminalPane?.sessionID, frontTerminalPaneMode: frontTerminalPane?.mode,
        frontTerminalPaneTitle: frontTerminalPane?.title, mainWindowVisible: mainWindowVisible, mainWindowFocused: mainWindowFocused,
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

/// The terminal pane that actually holds keyboard focus, resolved by walking up from the
/// app's focused AX element to the nearest `terminal-pane-<sessionID>` ancestor. In a split
/// tab every visible pane is in the window's AX hierarchy, so the first-match DFS in
/// `firstTerminalPaneIdentity` reports the left/top pane even after focus moved to another
/// split; this walk targets the pane the harness actually drove. Returns nil when keyboard
/// focus is not inside a terminal pane (e.g. the sidebar or a rename editor), so the caller
/// falls back to the first visible pane. Same identity tuple as `firstTerminalPaneIdentity`:
/// session id (identifier suffix), owner/viewer mode (AXValue), runtime-target name (AXDescription).
private func focusedTerminalPaneIdentity(appElement: AXUIElement) -> (sessionID: String, mode: String, title: String)? {
    let prefix = "terminal-pane-"
    var element = axElementAttribute(appElement, attribute: kAXFocusedUIElementAttribute as String)
    var depth = 0
    while let current = element, depth < 48 {
        if let identifier = axStringAttribute(current, attribute: kAXIdentifierAttribute as String), identifier.hasPrefix(prefix) {
            return (
                String(identifier.dropFirst(prefix.count)),
                axStringAttribute(current, attribute: kAXValueAttribute as String) ?? "",
                axStringAttribute(current, attribute: kAXDescriptionAttribute as String) ?? "")
        }
        element = axElementAttribute(current, attribute: kAXParentAttribute as String)
        depth += 1
    }
    return nil
}

/// Depth-first search for the selected tab's first (left/top) terminal pane, identified by the
/// `terminal-pane-<sessionID>` AXIdentifier that `TerminalSessionPaneViewController` sets. Only
/// the selected tab's pane tree is in the window's AX hierarchy. This is the fallback the surface
/// snapshot uses when keyboard focus is not inside any pane; `focusedTerminalPaneIdentity` handles
/// the focused-split case. Returns its session id (identifier suffix), owner/viewer mode (AXValue),
/// and runtime-target name (AXDescription). Runs in-process over the AXUIElement C API, which is
/// far cheaper than an equivalent AppleScript/System-Events traversal the harness would otherwise
/// poll in a tight loop.
private func firstTerminalPaneIdentity(in element: AXUIElement, depth: Int = 0) -> (sessionID: String, mode: String, title: String)? {
    guard depth < 48 else { return nil }
    let prefix = "terminal-pane-"
    if let identifier = axStringAttribute(element, attribute: kAXIdentifierAttribute as String), identifier.hasPrefix(prefix) {
        return (
            String(identifier.dropFirst(prefix.count)),
            axStringAttribute(element, attribute: kAXValueAttribute as String) ?? "",
            axStringAttribute(element, attribute: kAXDescriptionAttribute as String) ?? "")
    }
    for child in axElementArrayAttribute(element, attribute: kAXChildrenAttribute as String) {
        if let found = firstTerminalPaneIdentity(in: child, depth: depth + 1) { return found }
    }
    for row in axElementArrayAttribute(element, attribute: kAXRowsAttribute as String) {
        if let found = firstTerminalPaneIdentity(in: row, depth: depth + 1) { return found }
    }
    return nil
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
    guard let value = axAttributeValue(element, attribute: attribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
    return (value as! AXUIElement)
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
