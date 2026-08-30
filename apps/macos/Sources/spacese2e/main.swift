import AppKit
import ApplicationServices
import ArgumentParser
import Carbon
import CoreGraphics
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
            E2ECommand.self, SeedFixtureCommand.self, CleanupFixturesCommand.self, RegisterProjectCommand.self, CreateWorkspaceCommand.self,
            LookupWorkspaceCommand.self, ShowMainWindowCommand.self, HideMainWindowCommand.self, ShowWindowIssueModalCommand.self,
            SelectWorkspaceDetailCommand.self, OpenWorkspaceTerminalCommand.self, RunWorkspaceProcessCommand.self, StopWorkspaceProcessCommand.self,
            OpenWorkspaceEditorCommand.self, RestartWorkspaceProcessCommand.self, DumpWorkspaceCommand.self, FocusableWindowNamesCommand.self,
            ArchiveWorkspaceCommand.self, HideWorkspaceCommand.self, StopWorkspaceCommand.self, StopFixturesCommand.self,
            SetWorkspaceBrowserSessionURLsCommand.self, ClearWorkspaceAgentWindowsCommand.self, SetWorkspaceStopScriptCommand.self,
            AddWorkspaceProcessCommand.self, RemoveWorkspaceProcessCommand.self, FocusWorkspaceWindowCommand.self, CycleWorkspaceWindowCommand.self,
            FocusWorkspaceProcessCommand.self, CloseWorkspaceProcessWindowCommand.self, SurfaceSnapshotCommand.self,
            CloseTerminalSessionWindowCommand.self, FocusTerminalSessionWindowCommand.self, DumpTerminalSessionWindowStateCommand.self,
            TerminalSessionWindowShortcutCommand.self, StartWorkspaceTerminalSessionCommand.self, TerminateTerminalSessionCommand.self,
            TerminalServiceStateCommand.self, TerminalServiceControlCommand.self, OpenDevicePairingWindowCommand.self, PairRemoteDeviceCommand.self,
            OpenRemoteDevicePairingWindowCommand.self, SeedPairedDeviceCommand.self, RecordScreenCommand.self, ProfileShowCommand.self,
            ProfileAppOwnerCommand.self, MacClientInstallationIDCommand.self, ProfileSocketPathsCommand.self, ProfileDesktopControlOwnerCommand.self,
            ProfileWaitForDesktopControlCommand.self, MobileStatusCommand.self, MobileServeCommand.self, MobileRequestCommand.self,
            ProfileCommand.self, ServiceTunnelCommand.self, RenderUpdateTextCommand.self, RecordMobileDemoCommand.self,
            ScrollApplicationWindowCommand.self, ClickApplicationWindowCommand.self, TypeApplicationWindowCommand.self,
            DragApplicationWindowCommand.self, AutomationCreateCommand.self, AutomationUpdateCommand.self, AutomationDeleteCommand.self,
            AutomationListCommand.self, AutomationRunsCommand.self, AutomationTriggerCommand.self, AutomationCancelCommand.self,
            AutomationEndAgentsCommand.self, WindowStackingCommand.self,
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
    @Option(name: .long) var applicationPid: Int32?
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
        let target = try targetApplicationWindow(
            executableName: executableName, applicationPID: applicationPid, windowTitleContains: windowTitleContains)

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

private struct ClickApplicationWindowCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "click-application-window")

    @Option(name: .long) var executableName: String
    @Option(name: .long) var applicationPid: Int32?
    @Option(name: .long) var windowTitleContains: String?
    @Option(name: .long) var normalizedX = 0.5
    @Option(name: .long) var normalizedY = 0.5

    func run() throws {
        guard (0...1).contains(normalizedX), (0...1).contains(normalizedY) else {
            throw ValidationError("Normalized coordinates must be between 0 and 1.")
        }
        let target = try targetApplicationWindow(
            executableName: executableName, applicationPID: applicationPid, windowTitleContains: windowTitleContains)

        target.application.activate(options: [])
        axPerformAction(target.window, action: kAXRaiseAction as String)
        Thread.sleep(forTimeInterval: 0.2)

        let point = CGPoint(x: target.frame.minX + target.frame.width * normalizedX, y: target.frame.minY + target.frame.height * normalizedY)
        let timing = try postClickEvent(at: point)
        try emitJSON(
            ClickApplicationWindowPayload(
                executableName: executableName, windowTitle: target.title, pointX: point.x, pointY: point.y,
                mouseDownUptimeNanoseconds: timing.mouseDownUptimeNanoseconds, mouseUpUptimeNanoseconds: timing.mouseUpUptimeNanoseconds,
                success: true))
    }
}

private struct TypeApplicationWindowCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "type-application-window")

    @Option(name: .long) var executableName: String
    @Option(name: .long) var applicationPid: Int32?
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
        let target = try targetApplicationWindow(
            executableName: executableName, applicationPID: applicationPid, windowTitleContains: windowTitleContains)

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
    @Option(name: .long) var applicationPid: Int32?
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
        let target = try targetApplicationWindow(
            executableName: executableName, applicationPID: applicationPid, windowTitleContains: windowTitleContains)

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
        let workspace = try resolveWorkspace(dir: workspaceDir).workspace
        try IPCNotification.post(IPCNotification.selectWorkspaceDetail, userInfo: [IPCNotification.workspaceIDUserInfoKey: workspace.id])
        try emitJSON(workspaceSummaryPayload(workspace))
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
        let workspace = try resolveWorkspace(dir: workspaceDir).workspace
        try IPCNotification.post(IPCNotification.openWorkspaceTerminal, userInfo: [IPCNotification.workspaceIDUserInfoKey: workspace.id])
        try emitJSON(workspaceSummaryPayload(workspace))
    }
}

private struct OpenWorkspaceEditorCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "open-workspace-editor", abstract: "Open the built-in Editor for a workspace through the running app.")

    @Option(name: .long) var workspaceID: String

    func run() throws {
        guard !workspaceID.isEmpty else { throw ValidationError("--workspace-id must not be empty.") }
        try IPCNotification.post(IPCNotification.openWorkspaceEditor, userInfo: [IPCNotification.workspaceIDUserInfoKey: workspaceID])
        try emitJSON(["workspaceID": workspaceID])
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
        let (orchestrator, workspace) = try resolveWorkspace(dir: workspaceDir)
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
    @Option(name: .long) var selectionStartColumn: UInt16?
    @Option(name: .long) var selectionStartRow: UInt32?
    @Option(name: .long) var selectionEndColumn: UInt16?
    @Option(name: .long) var selectionEndRow: UInt32?
    @Flag(name: .long) var directControl = false
    @Flag(name: .long) var appendNewline = false
    @Flag(name: .long) var selectionRectangle = false

    func run() throws {
        let trimmedCommand = try required(command, label: "command")
        let trimmedSessionID = try required(sessionID, label: "session-id")
        let normalizedClientID = normalizedOptional(clientID)
        let client = try terminalClientFromOptions(clientID: normalizedClientID)
        let parsedAttachmentMode = try terminalAttachmentModeFromOption(attachmentMode)
        let controlRequest = TerminalControlRequest(
            command: trimmedCommand, text: text, key: key, clientID: normalizedClientID, client: client, attachmentMode: parsedAttachmentMode,
            columns: nil, rows: nil, ownerEpoch: nil, resizeSerial: nil, scrollHorizontal: scrollHorizontal, scrollVertical: scrollVertical,
            scrollMods: scrollMods, appendNewline: appendNewline, selectionStartColumn: selectionStartColumn, selectionStartRow: selectionStartRow,
            selectionEndColumn: selectionEndColumn, selectionEndRow: selectionEndRow, selectionRectangle: selectionRectangle ? true : nil)
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
                pairingCode: window.code, pairingNonce: window.nonce, certificateFingerprint: link.certificateFingerprint,
                expiresAt: e2eISO8601Formatter.string(from: window.expiresAt), message: response.message))
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
                clientAppVersion: AppVersion.short))
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
            id: "remote-pairing-window", name: "Remote Device", platform: "remote", hosts: [sshHost], port: SpacesDeviceAPIEndpointDefaults.port,
            certificateFingerprint: "", sshHost: sshHost, sshUser: normalizedOptional(sshUser), sshPort: sshPort, createdAt: nowISO8601(),
            updatedAt: nowISO8601())
        let result = try SpacesDevicePairingClient.openRemotePairingWindow(for: device, appVersion: AppVersion.short)
        let link = try SpacesDevicePairingLink.parse(result.linkString)
        try emitJSON(
            RemoteDevicePairingWindowPayload(
                name: result.name, host: result.host, port: result.port, pairingLink: result.linkString,
                certificateFingerprint: link.certificateFingerprint, expiresAt: result.expiresAt))
    }
}

/// Records a device a harness already paired out of band — the remote Device API E2E pairs this Mac
/// over SSH and reports the issued token — into this profile's client store and secret store.
///
/// It goes through the client store's own writers on purpose. A harness that hand-writes the
/// `paired_devices` row leaves a client database that has tables but not the rest of the schema, and
/// schema creation only ever runs on an empty database, so the app then fails its first read of any
/// other client table.
private struct SeedPairedDeviceCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "seed-paired-device", abstract: "Record an already-paired remote device in this profile's client store.")

    @Option(name: .long, help: "Device id the remote daemon's pinned certificate resolves to.") var deviceID: String

    @Option(name: .long, help: "Device display name.") var name: String

    @Option(name: .long, help: "Remote Device API host.") var host: String

    @Option(name: .long, help: "Remote Device API port.") var port: Int

    @Option(name: .long, help: "Remote daemon certificate fingerprint to pin.") var certificateFingerprint: String

    @Option(name: .long, help: "Remote SSH host.") var sshHost: String?

    @Option(name: .long, help: "Remote SSH user.") var sshUser: String?

    @Option(name: .long, help: "Remote SSH port.") var sshPort: Int?

    @Option(name: .long, help: "Auth token the remote daemon issued to this Mac client.") var authToken: String

    func run() throws {
        let timestamp = nowISO8601()
        // The only device a harness seeds this way is the Linux remote daemon under test, and its
        // seeding stands in for a pairing that already happened, so it is also the last selected one.
        let device = SpacesPairedDeviceRecord(
            id: deviceID, name: name, platform: "linux", hosts: [host], port: port, certificateFingerprint: certificateFingerprint,
            sshHost: normalizedOptional(sshHost), sshUser: normalizedOptional(sshUser), sshPort: sshPort, createdAt: timestamp, updatedAt: timestamp,
            lastSelectedAt: timestamp)
        try SpacesClientDatabase.withDefaultDatabase { try $0.upsert(device: device) }
        try SpacesDeviceCredentialStore.saveToken(authToken, deviceID: deviceID)
    }
}

private struct ProfileShowCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "profile-show", abstract: "Show resolved Spaces profile paths for harnesses.")

    @Flag(name: .long, help: "Emit JSON instead of text.") var json = false

    /// Reports the profile this binary resolves; it never emits a binding for a caller to export. A
    /// repo-local binary resolves its own profile from where it sits in the checkout, so a shell binding is
    /// redundant for the binary that owns the profile and wrong for any other worktree's binary that later
    /// runs in the same shell — and `SPACES_DB_PATH`, which names an ephemeral throwaway profile only, is
    /// refused inside a live profile root, so a binding could not name a real profile at all. A harness that
    /// needs the concrete database or runtime path reads it from this output.
    func run() throws {
        let profile = try SpacesProfile.current()
        let payload = ProfilePayload(profile: profile)
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

private struct WindowStackingCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "window-stacking", abstract: "Print the on-screen window stack, front to back.")

    /// Cross-application z-order (which app's window is above which) is not something any app can observe
    /// about itself; it is only visible through the window server. `CGWindowListCopyWindowInfo` already
    /// returns on-screen windows front-to-back, so this just filters to ordinary application windows
    /// (layer 0, which excludes menu bars, the dock, and other system chrome) and prints one line per
    /// window so a harness can assert on stacking order across applications, e.g. that focusing a
    /// workspace browser session raises only its Chrome window and not every Chrome window.
    func run() throws {
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: AnyObject]] ?? []
        for window in info {
            guard (window[kCGWindowLayer as String] as? Int) == 0 else { continue }
            let ownerPID = window[kCGWindowOwnerPID as String] as? Int ?? 0
            let ownerName = window[kCGWindowOwnerName as String] as? String ?? ""
            let windowNumber = window[kCGWindowNumber as String] as? Int ?? 0
            let windowTitle = window[kCGWindowName as String] as? String ?? ""
            print("\(ownerPID)\t\(ownerName)\t\(windowNumber)\t\(windowTitle)")
        }
    }
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

/// Profile inventory and cleanup. Every profile on a machine — the installed one plus one development
/// profile per worktree — owns its own root, database, Device API port, and daemon, so development
/// profiles accumulate as worktrees come and go; on a shared Linux device they accumulate from several
/// developers at once. These commands show that inventory and reclaim the abandoned parts of it.
///
/// They deliberately live in `spacese2e` rather than the `spaces` CLI: a user never manages development
/// profiles, and the `spaces` surface is product behavior.
private struct ProfileCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "profile", abstract: "Inspect and clean up Spaces development profiles.",
        subcommands: [ProfileListCommand.self, ProfileStopCommand.self, ProfileRemoveCommand.self])
}

private struct ProfileListCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List the profiles on this Mac or on the remote device.")

    @Flag(name: .long, help: "List the remote device's profiles instead of this Mac's.") var remote = false

    func run() throws {
        if remote {
            let rows = try remoteProfileRows(device: try RemoteDevice.fromEnvironment())
            printProfileTable(headers: ["PROFILE", "PORT", "DAEMON", "SESSIONS", "UPDATED"], rows: rows)
            return
        }
        printProfileTable(headers: ["PROFILE", "PORT", "UPDATED"], rows: try localProfileRows())
    }
}

private struct ProfileStopCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "stop", abstract: "Stop a development profile's daemon on the remote device, leaving the profile in place.")

    @Flag(name: .long, help: "Required: this command acts on the remote device.") var remote = false

    @Argument(help: "Development profile name, as shown by `profile list --remote`.") var profileName: String

    func run() throws {
        let device = try RemoteDevice.forDeviceOnlyCommand(remote: remote, command: "profile stop")
        let name = try validatedDevelopmentProfileName(profileName)
        print(try device.runReportingScript(stopDevelopmentProfileScript(profileName: name)).detail)
    }
}

private struct ProfileRemoveCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "remove", abstract: "Stop, disable, and delete a development profile on the remote device.")

    @Flag(name: .long, help: "Required: this command acts on the remote device.") var remote = false

    @Argument(help: "Development profile name, as shown by `profile list --remote`.") var profileName: String

    func run() throws {
        let device = try RemoteDevice.forDeviceOnlyCommand(remote: remote, command: "profile remove")
        let name = try validatedDevelopmentProfileName(profileName)
        print(try device.runReportingScript(removeDevelopmentProfileScript(profileName: name)).detail)
    }
}

/// How the installed profile is named in this tooling's output. It has no directory name of its own —
/// it is the account's `~/.spaces` — so it needs a label, and the label doubles as the name `stop` and
/// `remove` refuse.
private let installedProfileLabel = "(installed)"

private let developmentProfilesRelativePath = ".spaces-dev/profiles/spaces"

/// Rejects anything that is not a plain development profile directory name.
///
/// The installed profile is refused by name: it is the profile clients pair with and the one profile on a
/// device that is nobody's leftover, so neither stopping nor deleting it is ever this tooling's job. Path
/// separators and relative segments are refused because the name is interpolated into a remote path that
/// `remove` deletes.
private func validatedDevelopmentProfileName(_ value: String) throws -> String {
    let name = try required(value, label: "profile name")
    guard name != installedProfileLabel else {
        throw ValidationError("\(installedProfileLabel) is the installed profile. It is not a development profile and cannot be stopped or removed.")
    }
    guard !name.contains("/"), name != ".", name != ".." else {
        throw ValidationError("'\(name)' is not a profile name. Pass a development profile name as shown by `profile list --remote`.")
    }
    return name
}

/// The remote device these commands act on, resolved from the repository `.env` variables that
/// `scripts/spaces-e2e-env.sh` surfaces for every remote-device workflow. There is deliberately no second
/// way to name a device: a caller binds that env first, exactly as the remote E2E scripts do.
private struct RemoteDevice {
    let destination: String
    let sshPort: Int?

    static func fromEnvironment() throws -> RemoteDevice {
        let environment = ProcessInfo.processInfo.environment
        guard let host = normalizedOptional(environment["SPACES_E2E_REMOTE_SSH_HOST"]) else {
            throw ValidationError(
                "SPACES_E2E_REMOTE_SSH_HOST is not set. Load the repository .env (as scripts/spaces-e2e-env.sh does) before using --remote.")
        }
        let user = normalizedOptional(environment["SPACES_E2E_REMOTE_SSH_USER"])
        let port = try validOptionalPort(
            normalizedOptional(environment["SPACES_E2E_REMOTE_SSH_PORT"]).flatMap(Int.init), label: "SPACES_E2E_REMOTE_SSH_PORT")
        return RemoteDevice(destination: user.map { "\($0)@\(host)" } ?? host, sshPort: port)
    }

    /// Resolves the device for a command that only exists for a device. Stopping and removing a profile is
    /// systemd's business — a profile's daemon on a device is a unit instance, and that is what makes the
    /// lifecycle addressable at all — so there is no local counterpart to fall back to, and `--remote` is
    /// required rather than assumed.
    static func forDeviceOnlyCommand(remote: Bool, command: String) throws -> RemoteDevice {
        guard remote else { throw ValidationError("`\(command)` acts on a device's systemd-managed daemon. Pass --remote.") }
        return try fromEnvironment()
    }

    /// Runs a script whose last line is a `##ok`/`##error` marker, and returns the lines it printed before
    /// that marker together with the marker's own detail message. An `##error` marker is raised as its
    /// detail, which is a message written for the person running the command.
    ///
    /// The marker is the whole result protocol: these scripts report every outcome in it and always exit 0,
    /// because an SSH exit status cannot carry the answer — Tailscale SSH reports 0 for every remote
    /// command, so a nonzero exit is not required for a failure and a zero exit does not mean success. A
    /// missing marker therefore means the script did not run to completion no matter what the transport
    /// claims, and is itself a failure.
    func runReportingScript(_ script: String) throws -> (lines: [String], detail: String) {
        let output = try run(script: script)
        var lines = output.split(whereSeparator: \.isNewline).map(String.init)
        guard let markerIndex = lines.lastIndex(where: { $0.hasPrefix("\(Self.okMarker)\t") || $0.hasPrefix("\(Self.errorMarker)\t") }) else {
            throw ValidationError("\(destination) did not report a result for this command. Output:\n\(output)")
        }
        let marker = lines[markerIndex]
        lines.removeSubrange(markerIndex..<lines.endIndex)
        let detail = String(marker.drop(while: { $0 != "\t" }).dropFirst())
        guard marker.hasPrefix("\(Self.okMarker)\t") else { throw ValidationError(detail) }
        return (lines, detail)
    }

    /// Runs `script` on the device with `sh -c`, returning its standard output.
    ///
    /// The scripts route their own diagnostics into the marker lines they print on stdout and silence
    /// everything else, so stderr stays small enough to drain after stdout without deadlocking the pipe.
    func run(script: String) throws -> String {
        var arguments = ["ssh", "-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", "-o", "StrictHostKeyChecking=yes"]
        if let sshPort { arguments += ["-p", String(sshPort)] }
        arguments += [destination, "sh -c \(profileShellQuoted(script))"]
        do { return try Shell.runAndCapture(arguments) } catch {
            throw ValidationError("Running a profile command on \(destination) failed: \(error.localizedDescription)")
        }
    }

    static let okMarker = "##ok"
    static let errorMarker = "##error"
}

/// One row per profile on the device, read from the device itself.
///
/// `DAEMON` reports what user systemd holds for that profile's unit, and `SESSIONS` comes from asking that
/// profile's OWN `spaces` binary — the same socket a client uses, so the count is the real one. The CLI is
/// only run for a unit systemd already reports active: `spaces terminal list` starts a daemon that is
/// down, which would resurrect every stopped profile just for listing them, and would contradict the very
/// state this table exists to show. An active unit whose CLI does not answer therefore shows `up` with no
/// session count, which is the honest reading of a daemon that is running but not serving.
private func remoteProfileRows(device: RemoteDevice) throws -> [[String]] {
    try device.runReportingScript(listProfilesScript()).lines.map { $0.components(separatedBy: "\t") }
}

/// Emits one tab-separated row per profile, then the completion marker. Everything the listing needs is a
/// fact on disk or a fact systemd holds, except the session count, which only the profile's own daemon
/// knows.
private func listProfilesScript() -> String {
    """
    set -u
    # Reports its outcome in a trailing ##ok/##error marker line and always exits 0; see runReportingScript.

    report_profile() {
        name="$1"
        root="$2"
        cli="$3"
        unit="$4"
        # The installed profile's port is the canonical constant computed from its identity — it records
        # nothing — so it is reported as that rather than read from a file it does not write.
        if [ "$name" = '\(installedProfileLabel)' ]; then
            port='\(SpacesDeviceAPIDefaults.port)'
        else
            port="$(tr -d ' \\n' < "$root/runtime/terminal/device-api.json" 2>/dev/null | sed -n 's/.*"port":\\([0-9][0-9]*\\).*/\\1/p')"
            [ -n "$port" ] || port='-'
            # A development profile still recording the canonical port has never assigned itself one, so that
            # value is not a port it would ever bind: it assigns a development-range port the next time its
            # daemon starts. Reporting it verbatim would name the installed daemon's port for a profile that
            # cannot use it, so it reads as unassigned instead.
            if [ "$port" = '\(SpacesDeviceAPIDefaults.port)' ]; then
                port='-'
            fi
        fi
        daemon='down'
        sessions='-'
        if systemctl --user is-active --quiet "$unit" 2>/dev/null; then
            daemon='up'
            if listing="$("$cli" terminal list 2>/dev/null)"; then
                sessions="$(printf '%s\\n' "$listing" | grep -c 'state=' || true)"
            fi
        fi
        # Newest modification date directly inside the profile root: its database, runtime directory and
        # deployed daemon all live there, so this is when the profile was last touched at all. The date
        # format sorts lexically, so no separate timestamp column is needed to pick the newest.
        updated="$(find "$root" -maxdepth 1 -printf '%TY-%Tm-%Td\\n' 2>/dev/null | sort -r | head -n 1)"
        [ -n "$updated" ] || updated='-'
        printf '%s\t%s\t%s\t%s\t%s\\n' "$name" "$port" "$daemon" "$sessions" "$updated"
    }

    report_profile '\(installedProfileLabel)' "$HOME/.spaces" "$HOME/.spaces/bin/spaces" 'spacesd.service'
    for root in "$HOME/\(developmentProfilesRelativePath)"/*; do
        [ -d "$root" ] || continue
        name="$(basename "$root")"
        report_profile "$name" "$root" "$root/daemon/current/bin/spaces" "spacesd@$name.service"
    done
    printf '\(RemoteDevice.okMarker)\tlisted every profile.\\n'
    """
}

/// Shell helpers that read a unit's state from user systemd, shared by the two lifecycle scripts.
///
/// `systemctl --user is-active --quiet` cannot serve as a boolean here: it exits nonzero BOTH when systemd
/// answers "this unit is not running" AND when systemd cannot be asked at all — an SSH session that reaches
/// no user service manager for the account (no `XDG_RUNTIME_DIR`/`DBUS_SESSION_BUS_ADDRESS`, no user
/// manager, no systemd) fails exactly like an idle unit does. Reading that as "not running" is what would
/// let a removal delete a profile root out from under a daemon that is still serving sessions, and a
/// deleted root is unrecoverable. These helpers read the state systemd PRINTS instead: a state word means
/// systemd answered, and empty output means it could not be reached, which the scripts refuse on rather
/// than treating as idle.
private let systemdUnitStateShellHelpers = """
    # Prints the state user systemd holds for the unit, and nothing at all when systemd could not be asked.
    unit_state() {
        systemctl --user is-active "$1" 2>/dev/null
    }

    # True only for the states that mean the unit is not running. Every other answer — active, activating,
    # deactivating, reloading — is a unit that still holds its daemon.
    unit_is_stopped() {
        [ "$1" = 'inactive' ] || [ "$1" = 'failed' ]
    }
    """

/// Stops the profile's unit instance and confirms systemd reports it stopped. Only this instance is
/// touched, so the device's installed daemon and every other development profile keep running. The unit
/// stays enabled: a stopped profile is one nobody is using right now, not one that may never run again.
///
/// A systemd that cannot be asked about the unit is reported as such rather than counted as a successful
/// stop; see `systemdUnitStateShellHelpers`.
private func stopDevelopmentProfileScript(profileName: String) -> String {
    """
    set -u
    # Reports its outcome in a trailing ##ok/##error marker line and always exits 0; see runReportingScript.
    \(systemdUnitStateShellHelpers)
    name=\(profileShellQuoted(profileName))
    root="$HOME/\(developmentProfilesRelativePath)/$name"
    unit="spacesd@$name.service"
    if [ ! -d "$root" ]; then
        printf '\(RemoteDevice.errorMarker)\tThere is no development profile at %s.\\n' "$root"
        exit 0
    fi
    systemctl --user stop "$unit" >/dev/null 2>&1
    state="$(unit_state "$unit")"
    if [ -z "$state" ]; then
        printf '\(RemoteDevice.errorMarker)\tUser systemd could not be asked about %s over this SSH session, so it cannot be shown to have stopped.\\n' "$unit"
        exit 0
    fi
    if ! unit_is_stopped "$state"; then
        printf '\(RemoteDevice.errorMarker)\t%s is still %s after being asked to stop.\\n' "$unit" "$state"
        exit 0
    fi
    printf '\(RemoteDevice.okMarker)\tStopped %s.\\n' "$unit"
    """
}

/// Refuses a profile whose daemon still holds terminal sessions, then stops and disables its unit
/// instance and deletes the profile root.
///
/// Disabling before deleting is what makes the deletion safe: the unit restarts on failure, so a unit left
/// enabled comes straight back up against a half-deleted profile. The unit's stopped state is verified
/// rather than assumed from a command's exit status.
///
/// A running daemon that does not answer its own CLI is also refused: idleness cannot be proven, and
/// `profile stop` is the way through — once the unit is stopped it holds no sessions at all.
///
/// Both state checks refuse when systemd itself cannot be asked, before and after disabling: an
/// unanswerable systemd says nothing about whether the daemon is serving sessions, so nothing is deleted.
/// See `systemdUnitStateShellHelpers`.
private func removeDevelopmentProfileScript(profileName: String) -> String {
    """
    set -u
    # Reports its outcome in a trailing ##ok/##error marker line and always exits 0; see runReportingScript.
    \(systemdUnitStateShellHelpers)
    name=\(profileShellQuoted(profileName))
    root="$HOME/\(developmentProfilesRelativePath)/$name"
    unit="spacesd@$name.service"
    cli="$root/daemon/current/bin/spaces"
    if [ ! -d "$root" ]; then
        printf '\(RemoteDevice.errorMarker)\tThere is no development profile at %s.\\n' "$root"
        exit 0
    fi
    state="$(unit_state "$unit")"
    if [ -z "$state" ]; then
        printf '\(RemoteDevice.errorMarker)\tUser systemd could not be asked whether %s is running over this SSH session, so %s was left in place.\\n' "$unit" "$root"
        exit 0
    fi
    if ! unit_is_stopped "$state"; then
        if ! listing="$("$cli" terminal list 2>/dev/null)"; then
            printf '\(RemoteDevice.errorMarker)\t%s is running but did not answer its own CLI, so it cannot be shown to be idle. Run: spacese2e profile stop --remote %s\\n' "$unit" "$name"
            exit 0
        fi
        sessions="$(printf '%s\\n' "$listing" | grep -c 'state=' || true)"
        if [ "$sessions" -gt 0 ]; then
            printf '\(RemoteDevice.errorMarker)\tProfile %s still has %s live terminal session(s). End them first.\\n' "$name" "$sessions"
            exit 0
        fi
    fi
    systemctl --user disable --now "$unit" >/dev/null 2>&1
    state="$(unit_state "$unit")"
    if [ -z "$state" ]; then
        printf '\(RemoteDevice.errorMarker)\tUser systemd could not be asked whether %s stopped over this SSH session, so %s was left in place.\\n' "$unit" "$root"
        exit 0
    fi
    if ! unit_is_stopped "$state"; then
        printf '\(RemoteDevice.errorMarker)\t%s is still %s after being disabled, so %s was left in place.\\n' "$unit" "$state" "$root"
        exit 0
    fi
    # Clears a leftover failed state for the instance, so a removed profile leaves nothing behind in
    # systemd's view of the account's units.
    systemctl --user reset-failed "$unit" >/dev/null 2>&1
    rm -rf "$root"
    printf '\(RemoteDevice.okMarker)\tRemoved %s and disabled %s.\\n' "$root" "$unit"
    """
}

/// The profiles on this Mac: the installed one, then every development profile, with the port each has
/// recorded for itself and when it was last touched.
///
/// There are deliberately no daemon or session columns here. A Mac has no per-profile unit to ask about
/// another profile's daemon, and a profile's session count is only knowable through that profile's own
/// daemon, which on a Mac means the running build of whichever worktree owns it — not something this
/// process can address. The columns a Mac can answer honestly are the ones it prints.
private func localProfileRows() throws -> [[String]] {
    let homeDirectory = FileManager.default.homeDirectoryForCurrentUser
    let installedRoot = homeDirectory.appendingPathComponent(".spaces", isDirectory: true)
    let developmentProfilesRoot = homeDirectory.appendingPathComponent(developmentProfilesRelativePath, isDirectory: true)
    let developmentRoots =
        ((try? FileManager.default.contentsOfDirectory(
            at: developmentProfilesRoot, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []).filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    // The installed profile's port is the canonical constant, not a recorded assignment: it records nothing,
    // so it is reported from identity the same way its daemon computes it.
    return [[installedProfileLabel, String(SpacesDeviceAPIDefaults.port), lastTouchedDate(profileRoot: installedRoot)]]
        + developmentRoots.map { [$0.lastPathComponent, recordedDeviceAPIPort(profileRoot: $0), lastTouchedDate(profileRoot: $0)] }
}

/// The Device API port a development profile has recorded for itself, or `-` when it has never recorded one
/// (a profile whose daemon has not started yet). This is the profile's assignment, which is what a daemon
/// started for it binds unless an environment override names another port.
private func recordedDeviceAPIPort(profileRoot: URL) -> String {
    let settingsURL = profileRoot.appendingPathComponent("runtime/terminal/device-api.json", isDirectory: false)
    guard let data = try? Data(contentsOf: settingsURL), let settings = try? JSONDecoder().decode(SpacesDeviceAPISettings.self, from: data) else {
        return "-"
    }
    return String(settings.port)
}

/// The newest modification date directly inside a profile root — its database, runtime directory, and
/// staged binaries all live there — so it reads as when the profile was last touched at all.
private func lastTouchedDate(profileRoot: URL) -> String {
    let children = (try? FileManager.default.contentsOfDirectory(at: profileRoot, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
    let modificationDates = ([profileRoot] + children).compactMap {
        try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }
    guard let newest = modificationDates.max() else { return "-" }
    return profileDateFormatter.string(from: newest)
}

private let profileDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter
}()

/// Prints a left-aligned table. Column widths follow the widest value so a profile name is never
/// truncated — the names in this table are the arguments `stop` and `remove` take — with a floor on the
/// profile column so the layout is stable across devices.
private func printProfileTable(headers: [String], rows: [[String]]) {
    let profileColumnFloor = 32
    let widths = headers.indices.map { column in
        max(column == 0 ? profileColumnFloor : 0, ([headers] + rows).map { $0.indices.contains(column) ? $0[column].count : 0 }.max() ?? 0)
    }
    for row in [headers] + rows {
        // The last cell is never padded, and a cell is never padded shorter than its own value, so a row
        // that carries more fields than the headers describe still prints intact.
        let line = row.indices.map { column in
            let width = column < widths.count ? widths[column] : 0
            return column == row.count - 1 ? row[column] : row[column].padding(toLength: max(width, row[column].count), withPad: " ", startingAt: 0)
        }.joined(separator: "  ")
        print(line)
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
        let identity = try TerminalServiceTLSIdentityStore.loadOrCreate()
        let pairingWindowEmitter = MobileServePairingWindowEmitter(
            bindHost: host, totalWindowCount: pairingWindowCount, firstPairingCode: resolvedPairingCode)
        let server = try SpacesDeviceAPIServer(host: host, port: port, identity: identity) { _ in
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
    static let configuration = CommandConfiguration(commandName: "mobile-request", abstract: "Send a pinned-TLS Device API JSON request.")

    @Option(help: "Full spaces:// pairing link. Supplies host, port, certificate fingerprint, code, and nonce.") var pairingLink: String?
    @Option(help: "Device API host. Defaults to the pairing link host or 127.0.0.1.") var host: String?
    @Option(help: "Device API port. Defaults to the pairing link port.") var port: Int?
    @Option(help: "Expected daemon certificate fingerprint. Defaults to the pairing link fingerprint.") var certificateFingerprint: String?
    @Option(help: "JSON Device API request. Reads stdin when omitted.") var requestJSON: String?
    @Flag(help: "Keep the connection open and print newline-delimited Device API messages.") var stream = false
    @Flag(help: "Read newline-delimited Device API requests from stdin and reuse one request connection.") var requestLines = false

    func run() throws {
        let link = try pairingLink.map { try SpacesDevicePairingLink.parse($0) }
        let resolvedHost = host ?? link?.hosts.first ?? "127.0.0.1"
        guard let resolvedPort = port ?? link?.port else { throw ValidationError("Provide --port or a pairing link.") }
        guard (1...65_535).contains(resolvedPort) else { throw ValidationError("Port must be between 1 and 65535.") }
        guard let resolvedFingerprint = certificateFingerprint ?? link?.certificateFingerprint else {
            throw ValidationError("Provide --certificate-fingerprint or a pairing link.")
        }

        if requestLines {
            guard !stream else { throw ValidationError("--request-lines cannot be combined with --stream.") }
            guard requestJSON == nil else { throw ValidationError("--request-lines reads requests from stdin; omit --request-json.") }
            try sendRequestLines(host: resolvedHost, port: resolvedPort, certificateFingerprint: resolvedFingerprint, pairingLink: link)
            return
        }

        var requestData = try readRequestData()
        if let link { requestData = try requestDataByApplying(pairingLink: link, to: requestData) }

        let client = DeviceAPIRequestClient(host: resolvedHost, port: UInt16(resolvedPort), certificateFingerprint: resolvedFingerprint)
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

    private func sendRequestLines(host: String, port: Int, certificateFingerprint: String, pairingLink link: SpacesDevicePairingLink?) throws {
        let client = try SpacesDeviceAPIRequestSessionClient(
            resolver: SpacesDeviceEndpointResolver(hosts: [host], port: port, certificateFingerprint: certificateFingerprint))
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

private struct ServiceTunnelCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "service-tunnel", abstract: "Open a Device API service tunnel and perform one HTTP GET through it.")

    @Option(help: "Device API host.") var host = "127.0.0.1"
    @Option(help: "Device API port.") var port: Int
    @Option(help: "Expected daemon certificate fingerprint.") var certificateFingerprint: String
    @Option(help: "Paired-device auth token.") var authToken: String
    @Option(help: "Installation ID the auth token was paired with; the daemon binds each token to its paired installation and bundle.")
    var clientInstallationID: String
    @Option(help: "Workspace whose running service the tunnel targets.") var workspaceID: String
    @Option(help: "Configured service name to tunnel to.") var serviceName: String
    @Option(help: "Absolute request path for the single HTTP GET performed through the tunnel, e.g. /README.txt.") var httpGet: String
    @Option(help: "Host header value for the HTTP GET.") var httpHost = "127.0.0.1"
    @Option(help: "Timeout in seconds for the tunneled HTTP exchange.") var timeoutSeconds: Double = 30

    func run() throws {
        guard (1...65_535).contains(port) else { throw ValidationError("Port must be between 1 and 65535.") }
        guard httpGet.hasPrefix("/") else { throw ValidationError("--http-get must be an absolute path starting with /.") }
        let request = SpacesDeviceAPIRequest(
            command: .openServiceTunnel(SpacesDeviceServiceTunnelRequest(workspaceID: workspaceID, serviceName: serviceName)), authToken: authToken,
            clientApp: SpacesDeviceClientApp(
                installationID: clientInstallationID, bundleID: SpacesDeviceFirstPartyPolicy.iosBundleID, platform: "ios",
                deviceName: "Spaces E2E Service Tunnel", appVersion: "1.0"))

        let client = DeviceAPIRequestClient(host: host, port: UInt16(port), certificateFingerprint: certificateFingerprint)
        let tunnel = try client.openTunnel(requestData: SpacesDeviceAPICodec.encodeRequest(request))
        let response = try SpacesDeviceAPICodec.decodeResponse(tunnel.responseLine)
        guard response.ok else {
            tunnel.connection.cancel()
            FileHandle.standardOutput.write(tunnel.responseLine)
            FileHandle.standardOutput.write(Data([0x0A]))
            throw ExitCode.failure
        }

        let deadline = Date(timeIntervalSinceNow: timeoutSeconds)
        if !tunnel.initialTunnelData.isEmpty { FileHandle.standardOutput.write(tunnel.initialTunnelData) }
        let httpRequest = "GET \(httpGet) HTTP/1.1\r\nHost: \(httpHost)\r\nConnection: close\r\n\r\n"
        try client.sendTunnelBytes(Data(httpRequest.utf8), over: tunnel.connection)
        try client.relayTunnelToStandardOutput(from: tunnel.connection, deadline: deadline)
        tunnel.connection.cancel()
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
                    text: baseline.map { GhosttyTerminalSnapshotLayout.plainText(for: $0.snapshot) }, columns: baseline?.snapshot.columns,
                    rows: baseline?.snapshot.rows, reason: payload.reason, outputByteCount: payload.outputByteCount,
                    screenStateRevision: payload.screenStateRevision, error: applyError)
            } catch {
                response = RenderUpdateTextLine(
                    ok: false, hasRenderUpdate: nil, appliedRenderUpdate: nil, updateKind: nil, text: nil, columns: nil, rows: nil, reason: nil,
                    outputByteCount: nil, screenStateRevision: nil, error: String(describing: error))
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
    let columns: Int?
    let rows: Int?
    let reason: String?
    let outputByteCount: Int?
    let screenStateRevision: UInt64?
    let error: String?
}

/// Records the bundled iOS Demo Mode recording from a live daemon: the real device-API overview plus
/// full-frame Ghostty terminal payloads captured at iOS-native grids. The output is deterministic and
/// idempotent — daemon session IDs are rewritten to stable slugs, temp paths are rewritten to fixed
/// placeholders, and every timestamp is normalized to a signed second-offset from a reference date the
/// demo backend rebases to "now" at load. See `apps/macos/Tests/record_ios_demo_recording.sh`.
private struct RecordMobileDemoCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "record-mobile-demo",
        abstract: "Record the bundled iOS Demo Mode recording (overview + full-frame terminal payloads) from a live daemon.",
        discussion: """
            Attaches to every terminal session in the seeded fixture workspaces as an owner-capable device \
            client, resizes each interactive session to each requested iOS-native grid, subscribes, collapses \
            the streamed delta frames into a single steady-state FULL frame, and writes \
            grids/<cols>x<rows>/<stable-id>.ndjson. Fetches the overview once into overview.json and writes a \
            manifest.json describing the schema version, reference date, grids, sessions, and the daemon→slug \
            session-id map. Post-processing rewrites session IDs to stable slugs, rewrites --path-rewrite \
            prefixes to fixed placeholders, strips browser sessions / assigned ports / workspace environment, \
            and rebases every ISO8601 timestamp to a signed second-offset from --reference-date so the output \
            is deterministic across runs.
            """)

    @Option(help: "Output directory for the recording bundle (manifest.json, overview.json, grids/).") var output: String
    @Option(name: .customLong("grid"), parsing: .singleValue, help: "Target grid as <cols>x<rows>. Repeat for multiple device classes.") var grids:
        [String] = []
    @Option(help: "Device API host. Defaults to 127.0.0.1.") var host: String = "127.0.0.1"
    @Option(help: "Device API port.") var port: Int
    @Option(help: "Expected daemon certificate fingerprint.") var certificateFingerprint: String
    @Option(help: "Paired-device auth token.") var authToken: String
    @Option(help: "Installation ID the auth token was paired with.") var clientInstallationID: String
    @Option(help: "ISO8601 reference date offsets are measured from. Defaults to the recorder's start instant.") var referenceDate: String?
    @Option(help: "Recording schema version written to the manifest.") var schemaVersion: Int = 1
    @Option(
        name: .customLong("path-rewrite"), parsing: .singleValue,
        help: "Rewrite a path prefix as <from>=<to> in overview and payloads for determinism. Repeatable.") var pathRewrites: [String] = []
    @Option(help: "Idle time in milliseconds with no new stream frames before a session is considered settled.") var settleMS: Int = 1200
    @Option(help: "Overall per-session capture timeout in milliseconds.") var overallTimeoutMS: Int = 20000

    func run() throws {
        guard (1...65_535).contains(port) else { throw ValidationError("Port must be between 1 and 65535.") }
        guard !grids.isEmpty else { throw ValidationError("Provide at least one --grid <cols>x<rows>.") }
        let parsedGrids = try grids.map(Self.parseGrid)
        let rewrites = try pathRewrites.map(Self.parsePathRewrite)
        let reference: Date
        if let referenceDate {
            guard let parsed = e2eISO8601Formatter.date(from: referenceDate) ?? ISO8601DateFormatter().date(from: referenceDate) else {
                throw ValidationError("--reference-date must be ISO8601.")
            }
            reference = parsed
        } else {
            reference = Date()
        }

        let outputURL = URL(fileURLWithPath: normalizePath(output), isDirectory: true)
        let recorder = DemoRecorder(
            host: host, port: port, certificateFingerprint: certificateFingerprint, authToken: authToken, clientInstallationID: clientInstallationID,
            settleSeconds: Double(settleMS) / 1000, overallSeconds: Double(overallTimeoutMS) / 1000)

        let overviewResponseData = try recorder.fetchOverviewResponseData()
        let overviewResponse = try SpacesDeviceAPICodec.decodeResponse(overviewResponseData)
        guard let overview = overviewResponse.overview else {
            throw ValidationError("Device API overview response did not include an overview payload: \(overviewResponse.message)")
        }
        let plans = DemoRecorder.buildSessionPlans(overview: overview)
        guard !plans.isEmpty else { throw ValidationError("The seeded fixture has no terminal sessions to record.") }
        let sessionIDMap = Dictionary(uniqueKeysWithValues: plans.map { ($0.daemonSessionID, $0.slug) })
        let transform = DemoRecordingTransform(sessionIDMap: sessionIDMap, pathRewrites: rewrites, referenceDate: reference)

        let fileManager = FileManager.default
        try? fileManager.removeItem(at: outputURL.appendingPathComponent("grids", isDirectory: true))
        try fileManager.createDirectory(at: outputURL, withIntermediateDirectories: true)

        var capturedSummaries: [DemoRecordedSessionSummary] = []
        for plan in plans {
            capturedSummaries.append(
                DemoRecordedSessionSummary(stableID: plan.slug, workspaceName: plan.workspaceName, title: plan.title, kind: plan.kind))
        }

        for grid in parsedGrids {
            let gridDir = outputURL.appendingPathComponent("grids/\(grid.columns)x\(grid.rows)", isDirectory: true)
            try fileManager.createDirectory(at: gridDir, withIntermediateDirectories: true)
            for plan in plans {
                let payload = try recorder.captureSession(plan: plan, columns: grid.columns, rows: grid.rows)
                let renderText = payload.renderText ?? ""
                if renderText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    throw ValidationError("Captured empty terminal frame for \(plan.slug) at \(grid.columns)x\(grid.rows).")
                }
                let lineData = try transform.transformedPayloadLine(payload)
                try lineData.write(to: gridDir.appendingPathComponent("\(plan.slug).ndjson"))
            }
        }

        let overviewJSON = try transform.transformedOverviewResponse(overviewResponseData)
        try overviewJSON.write(to: outputURL.appendingPathComponent("overview.json"))

        let manifest = DemoRecordingManifest(
            schemaVersion: schemaVersion, referenceDate: GhosttyRemoteSessionStateTimestamp.string(from: reference),
            rebasingContract:
                "All ISO8601 timestamp fields in overview.json and every payload are replaced with signed integer second-offset strings relative to referenceDate; the demo backend adds each offset to load-time now. daemonStatus.protocolVersion is patched to the client's expected wire protocol version at load.",
            grids: parsedGrids.map { DemoRecordingGrid(columns: $0.columns, rows: $0.rows) },
            sessions: capturedSummaries.sorted { $0.stableID < $1.stableID }, sessionIDMap: sessionIDMap)
        let manifestEncoder = JSONEncoder()
        manifestEncoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try manifestEncoder.encode(manifest).write(to: outputURL.appendingPathComponent("manifest.json"))

        try emitJSON(
            DemoRecordingResult(
                sessionCount: plans.count, gridCount: parsedGrids.count, sessions: capturedSummaries.map(\.stableID).sorted(),
                grids: parsedGrids.map { "\($0.columns)x\($0.rows)" }))
    }

    private static func parseGrid(_ raw: String) throws -> (columns: Int, rows: Int) {
        let parts = raw.lowercased().split(separator: "x", maxSplits: 1)
        guard parts.count == 2, let columns = Int(parts[0]), let rows = Int(parts[1]), columns > 0, rows > 0, columns <= 1000, rows <= 1000 else {
            throw ValidationError("Invalid --grid '\(raw)'. Use <cols>x<rows>, e.g. 55x52.")
        }
        return (columns, rows)
    }

    private static func parsePathRewrite(_ raw: String) throws -> (from: String, to: String) {
        guard let separatorIndex = raw.firstIndex(of: "="), separatorIndex != raw.startIndex else {
            throw ValidationError("Invalid --path-rewrite '\(raw)'. Use <from>=<to>.")
        }
        return (String(raw[raw.startIndex..<separatorIndex]), String(raw[raw.index(after: separatorIndex)...]))
    }
}

private struct DemoRecordedSessionSummary: Codable {
    let stableID: String
    let workspaceName: String
    let title: String
    let kind: String
}

private struct DemoRecordingGrid: Codable {
    let columns: Int
    let rows: Int
}

private struct DemoRecordingManifest: Codable {
    let schemaVersion: Int
    let referenceDate: String
    let rebasingContract: String
    let grids: [DemoRecordingGrid]
    let sessions: [DemoRecordedSessionSummary]
    let sessionIDMap: [String: String]
}

private struct DemoRecordingResult: Codable {
    let sessionCount: Int
    let gridCount: Int
    let sessions: [String]
    let grids: [String]
}

/// One terminal session to record, resolved from the overview with a deterministic stable slug.
private struct DemoSessionPlan {
    let daemonSessionID: String
    let slug: String
    let workspaceName: String
    let title: String
    let kind: String
    let isInteractive: Bool
}

/// Drives the device API to capture each session's settled full frame. Mirrors the iOS viewer's
/// attach → takeover → resize → subscribe sequence so the daemon renders each session at the exact
/// iOS-native grid before the frame is captured (never a Mac-sized grid).
private struct DemoRecorder {
    let host: String
    let port: Int
    let certificateFingerprint: String
    let authToken: String
    let clientInstallationID: String
    let settleSeconds: Double
    let overallSeconds: Double

    private let recorderClientID = UUID().uuidString
    private let client: DeviceAPIRequestClient

    init(
        host: String, port: Int, certificateFingerprint: String, authToken: String, clientInstallationID: String, settleSeconds: Double,
        overallSeconds: Double
    ) {
        self.host = host
        self.port = port
        self.certificateFingerprint = certificateFingerprint
        self.authToken = authToken
        self.clientInstallationID = clientInstallationID
        self.settleSeconds = settleSeconds
        self.overallSeconds = overallSeconds
        client = DeviceAPIRequestClient(host: host, port: UInt16(port), certificateFingerprint: certificateFingerprint)
    }

    private var clientApp: SpacesDeviceClientApp {
        SpacesDeviceClientApp(
            installationID: clientInstallationID, bundleID: SpacesDeviceFirstPartyPolicy.iosBundleID, platform: "ios",
            deviceName: "Spaces Demo Recorder", appVersion: AppVersion.short)
    }

    private var recorderClient: TerminalClient {
        TerminalClient(
            id: recorderClientID, kind: .remoteViewer,
            identity: TerminalClientIdentity(label: "Spaces Demo Recorder", deviceName: "Spaces Demo Recorder", networkAddress: host),
            connectedAt: nowISO8601())
    }

    func fetchOverviewResponseData() throws -> Data { try request(command: .overview) }

    private func request(command: SpacesDeviceAPICommand) throws -> Data {
        let request = SpacesDeviceAPIRequest(command: command, authToken: authToken, clientApp: clientApp)
        return try client.request(requestData: try SpacesDeviceAPICodec.encodeRequest(request))
    }

    private func sendControl(_ payload: SpacesDeviceTerminalControlRequest) throws -> SpacesDeviceAPIResponse {
        try SpacesDeviceAPICodec.decodeResponse(try request(command: .terminalControl(payload)))
    }

    /// Attaches (view-only), takes ownership, resizes to the target grid, subscribes, and collapses the
    /// streamed frames into one steady-state FULL-frame payload. Ended (non-interactive) sessions skip the
    /// owner/resize path and subscribe directly for their persisted final frame.
    func captureSession(plan: DemoSessionPlan, columns: Int, rows: Int) throws -> GhosttyRemoteSessionStatePayload {
        let sessionID = plan.daemonSessionID
        if plan.isInteractive {
            let attachResponse = try sendControl(
                SpacesDeviceTerminalControlRequest(
                    action: .attach, sessionID: sessionID, client: recorderClient, attachmentMode: .viewer, appearance: .dark))
            guard attachResponse.ok else { throw ValidationError("attach failed for \(plan.slug): \(attachResponse.message)") }
            let takeoverResponse = try sendControl(
                SpacesDeviceTerminalControlRequest(action: .takeover, sessionID: sessionID, clientID: recorderClientID))
            guard takeoverResponse.ok else { throw ValidationError("takeover failed for \(plan.slug): \(takeoverResponse.message)") }
            var ownerEpoch = takeoverResponse.sessionState?.renderOwnerEpoch
            if ownerEpoch == nil {
                ownerEpoch = try? SpacesDeviceAPICodec.decodeResponse(request(command: .state(.init(sessionID: sessionID)))).sessionState?
                    .renderOwnerEpoch
            }
            let resizeResponse = try sendControl(
                SpacesDeviceTerminalControlRequest(
                    action: .resize, sessionID: sessionID, clientID: recorderClientID, columns: columns, rows: rows, ownerEpoch: ownerEpoch,
                    resizeSerial: 1))
            guard resizeResponse.ok else { throw ValidationError("resize failed for \(plan.slug): \(resizeResponse.message)") }
            // An accepted resize applies and broadcasts asynchronously; a subscription opened in that
            // window can serve a pre-resize frame and then settle on an idle session, recording the
            // whole capture at the wrong grid. Poll until the daemon serves the target grid so the
            // subscription below can only ever start from a post-resize frame.
            try waitUntilSessionServesGrid(sessionID: sessionID, columns: columns, rows: rows, slug: plan.slug)
            let payload = try collectSteadyState(sessionID: sessionID)
            _ = try? sendControl(SpacesDeviceTerminalControlRequest(action: .detach, sessionID: sessionID, clientID: recorderClientID))
            return payload
        }
        return try collectSteadyState(sessionID: sessionID)
    }

    private func waitUntilSessionServesGrid(sessionID: String, columns: Int, rows: Int, slug: String) throws {
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if let state = try? SpacesDeviceAPICodec.decodeResponse(request(command: .state(.init(sessionID: sessionID)))).sessionState,
                let update = state.decodedRenderUpdate, let applied = try? GhosttyRenderUpdateApplier.apply(update, to: nil),
                applied.snapshot.columns == columns, applied.snapshot.rows == rows
            {
                return
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        throw ValidationError("session \(slug) never served a \(columns)x\(rows) frame after its accepted resize")
    }

    private func collectSteadyState(sessionID: String) throws -> GhosttyRemoteSessionStatePayload {
        let subscribeRequest = SpacesDeviceAPIRequest(
            command: .subscribe(.init(sessionID: sessionID, clientID: recorderClientID)), authToken: authToken, clientApp: clientApp)
        let lines = try client.collectStream(
            requestData: try SpacesDeviceAPICodec.encodeRequest(subscribeRequest), settleSeconds: settleSeconds, overallSeconds: overallSeconds)
        var baseline: GhosttyRenderUpdateBaseline?
        var lastPayload: GhosttyRemoteSessionStatePayload?
        for line in lines {
            guard let payload = try? GhosttyRemoteSessionStateCodec.decodeLine(line) else { continue }
            lastPayload = payload
            if let update = payload.decodedRenderUpdate {
                if let applied = try? GhosttyRenderUpdateApplier.apply(update, to: baseline) { baseline = applied }
            }
        }
        guard let baseline, let lastPayload else { throw ValidationError("No render frames received for session \(sessionID).") }
        let frame = GhosttyRenderFrame(sessionRevision: baseline.sessionRevision, ownerEpoch: baseline.ownerEpoch, snapshot: baseline.snapshot)
        let fullUpdate = GhosttyRenderUpdate.full(frame)
        let encoded = try GhosttyRenderUpdateBinaryCodec.encode(fullUpdate)
        return lastPayload.replacingRenderUpdate(encoded)
    }

    /// Resolves a stable slug per session from its workspace role (process name, coding agent, or plain
    /// terminal). Slugs are role-derived so they are identical across runs even though daemon session IDs
    /// are random. Deterministically ordered by slug.
    static func buildSessionPlans(overview: SpacesDeviceOverviewPayload) -> [DemoSessionPlan] {
        let workspacesByID = Dictionary(uniqueKeysWithValues: overview.workspaces.map { ($0.id, $0) })
        var usedSlugs: Set<String> = []
        var plans: [DemoSessionPlan] = []
        for session in overview.sessions {
            let workspace = workspacesByID[session.workspaceID]
            let projectName = session.projectName ?? workspace?.projectName ?? "demo"
            let projectSlug = slugComponent(projectName.split(separator: "-").first.map(String.init) ?? projectName)
            let kind: String
            let role: String
            if let workspace, workspace.codingAgentRows.contains(where: { $0.sessionID == session.id }) {
                kind = "agent"
                role = "agent"
            } else if let workspace, let process = workspace.processRows.first(where: { $0.sessionID == session.id }) {
                kind = "process"
                role = slugComponent(process.name)
            } else {
                kind = "terminal"
                role = "terminal"
            }
            var slug = "demo-\(projectSlug)-\(role)"
            if usedSlugs.contains(slug) {
                var index = 2
                while usedSlugs.contains("\(slug)-\(index)") { index += 1 }
                slug = "\(slug)-\(index)"
            }
            usedSlugs.insert(slug)
            plans.append(
                DemoSessionPlan(
                    daemonSessionID: session.id, slug: slug, workspaceName: workspace?.displayName ?? projectName, title: session.title, kind: kind,
                    isInteractive: session.state.isInteractive))
        }
        return plans.sorted { $0.slug < $1.slug }
    }

    private static func slugComponent(_ raw: String) -> String {
        let lowered = raw.lowercased()
        let mapped = lowered.map { character -> Character in character.isLetter || character.isNumber ? character : "-" }
        let collapsed = String(mapped).split(separator: "-").joined(separator: "-")
        return collapsed.isEmpty ? "session" : collapsed
    }
}

/// Deterministic post-processing shared by overview.json and each payload line: rewrite daemon session
/// IDs to stable slugs, rewrite temp-path prefixes to fixed placeholders, drop volatile/irrelevant keys,
/// and rebase every ISO8601 timestamp to a signed second-offset string from the reference date.
private struct DemoRecordingTransform {
    let sessionIDMap: [String: String]
    let pathRewrites: [(from: String, to: String)]
    let referenceDate: Date

    // Volatile / machine-specific keys dropped wholesale. `environment` and `assignedPorts` carry
    // run-specific ports; the foreground* fields carry the resolved process argv/executable paths
    // (real ports and absolute paths) that must never ship in a committed demo bundle. All are optional
    // in their decoded types, so dropping them decodes back to nil.
    private static let strippedKeys: Set<String> = [
        "browserSessions", "resolvedBrowserSessions", "assignedPorts", "environment", "foregroundArgv", "foregroundExecutablePath",
        "foregroundExecutableName",
        // The recorder Mac's live LAN/Tailscale addresses: machine-specific and irrelevant to a
        // deterministic demo bundle.
        "deviceAPIAddresses",
    ]
    private static let clearedArrayKeys: Set<String> = ["attachments"]

    nonisolated(unsafe) private static let fractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    nonisolated(unsafe) private static let plainFormatter = ISO8601DateFormatter()

    func transformedOverviewResponse(_ data: Data) throws -> Data {
        try serialize(transform(JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])), pretty: true)
    }

    /// Emits one compact (single-line) JSON object plus a trailing newline so the file is valid ndjson
    /// the production `GhosttyRemoteSessionStateCodec.decodeLine` reads one payload per line.
    func transformedPayloadLine(_ payload: GhosttyRemoteSessionStatePayload) throws -> Data {
        let data = try JSONEncoder().encode(payload)
        var out = try serialize(transform(JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])), pretty: false)
        out.append(0x0A)
        return out
    }

    private func serialize(_ object: Any, pretty: Bool) throws -> Data {
        var options: JSONSerialization.WritingOptions = [.sortedKeys, .withoutEscapingSlashes]
        if pretty { options.insert(.prettyPrinted) }
        return try JSONSerialization.data(withJSONObject: object, options: options)
    }

    private func transform(_ value: Any) -> Any {
        switch value {
        case let dictionary as [String: Any]:
            var result: [String: Any] = [:]
            for (key, element) in dictionary {
                if Self.strippedKeys.contains(key) { continue }
                if Self.clearedArrayKeys.contains(key) {
                    result[key] = []
                    continue
                }
                result[key] = transform(element)
            }
            return result
        case let array as [Any]: return array.map(transform)
        case let string as String: return transformString(string)
        default: return value
        }
    }

    private func transformString(_ string: String) -> String {
        if let slug = sessionIDMap[string] { return slug }
        if let sanitized = sanitizedLaunchCommand(string) { return sanitized }
        var rewritten = string
        for rewrite in pathRewrites { rewritten = rewritten.replacingOccurrences(of: rewrite.from, with: rewrite.to) }
        if let offset = timestampOffset(rewritten) { return offset }
        return rewritten
    }

    /// The daemon persists each session's fully-resolved launch command — a shell wrapper that exports
    /// the real PATH, per-run ports, the workspace slug, and temp paths before exec'ing the process. None
    /// of that belongs in a shipped, deterministic demo bundle, so any string carrying that resolved
    /// wrapper is replaced with a clean command reconstructed from the fixture role (or a plain shell).
    /// Returns nil for ordinary strings (including the clean template command on process rows, which uses
    /// literal `$SPACES_APP_PORT`), leaving them to the path/timestamp passes.
    private func sanitizedLaunchCommand(_ string: String) -> String? {
        guard string.contains("export PATH=") || string.contains("exec /bin/zsh") else { return nil }
        if let range = string.range(of: "spaces_e2e_demo", options: .backwards) {
            let role = string[range.upperBound...].drop { !$0.isLetter }.prefix { $0.isLetter }
            if !role.isEmpty { return "python3 -m spaces_e2e_demo \(role)" }
        }
        return "/bin/zsh -l"
    }

    /// Rebases an ISO8601 datetime string to a signed integer second offset from the reference date.
    /// Guards on datetime shape (`YYYY-MM-DDThh:...`) so ordinary strings are never misread as timestamps.
    private func timestampOffset(_ string: String) -> String? {
        guard string.count >= 19, string.contains("T"), string.prefix(4).allSatisfy(\.isNumber), string.dropFirst(4).first == "-" else { return nil }
        guard let date = Self.fractionalFormatter.date(from: string) ?? Self.plainFormatter.date(from: string) else { return nil }
        return String(Int(date.timeIntervalSince(referenceDate).rounded()))
    }
}

/// Shared resolve + post + emit flow for commands that look up a workspace and tell the
/// running app to act on one named configured process inside it. The call sites differ
/// only in which notification to post.
private func postWorkspaceTargetIPC(_ notification: Notification.Name, workspaceDir: String, processName: String) throws {
    let workspace = try resolveWorkspace(dir: workspaceDir).workspace
    let trimmedProcessName = processName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedProcessName.isEmpty else { throw ValidationError("Missing process name.") }
    try IPCNotification.post(
        notification,
        userInfo: [IPCNotification.workspaceIDUserInfoKey: workspace.id, IPCNotification.workspaceTargetNameUserInfoKey: trimmedProcessName])
    try emitJSON(["workspaceID": workspace.id, "processName": trimmedProcessName])
}

private struct RunWorkspaceProcessCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "run-workspace-process")

    @Option(name: .long) var workspaceDir: String
    @Option(name: .long) var processName: String

    /// Tells the running Spaces app to launch one configured process through
    /// the same app-side path used by GUI recovery or focus actions.
    func run() throws { try postWorkspaceTargetIPC(IPCNotification.runWorkspaceProcess, workspaceDir: workspaceDir, processName: processName) }
}

private struct StopWorkspaceProcessCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "stop-workspace-process")

    @Option(name: .long) var workspaceDir: String
    @Option(name: .long) var processName: String

    func run() throws { try postWorkspaceTargetIPC(IPCNotification.stopWorkspaceProcess, workspaceDir: workspaceDir, processName: processName) }
}

private struct RestartWorkspaceProcessCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "restart-workspace-process")

    @Option(name: .long) var workspaceDir: String
    @Option(name: .long) var processName: String

    func run() throws { try postWorkspaceTargetIPC(IPCNotification.restartWorkspaceProcess, workspaceDir: workspaceDir, processName: processName) }
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
        let (orchestrator, workspace) = try resolveWorkspace(dir: workspaceDir)
        _ = try orchestrator.stopWorkspace(workspaceID: workspace.id)
        guard let updated = try orchestrator.store.workspace(id: workspace.id) else {
            throw ValidationError("Workspace disappeared: \(workspace.id)")
        }
        try emitJSON(workspaceSummaryPayload(updated))
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
            for workspace in try orchestrator.store.workspaces(projectID: project.id) {
                _ = try? orchestrator.stopWorkspace(workspaceID: workspace.id)
                stoppedWorkspaces.append(workspace.dir)
            }
        }

        try emitJSON(["stoppedWorkspaces": stoppedWorkspaces])
    }
}

private struct SeedFixtureCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "seed-fixture", abstract: "Register a local git repo as a Spaces project and seed deterministic browser/process defaults.",
        discussion: """
            The seeded project serves one of the hand-authored Lighthouse demo templates \
            (harbor, lantern, atlas). Pass --template to pick which one; when the project \
            directory has no pre-seeded .spaces-e2e-demo payload the matching template is \
            materialized into it.
            """)

    @Option(name: .long) var projectDir: String
    @Option(name: .long, help: "Demo template to seed: harbor (primary web app), lantern (API service), or atlas (docs site).") var template: String =
        "harbor"
    @Option(name: .long) var docsURL: String
    @Option(name: .long) var adminURL: String

    /// Registers a local git repo as a Spaces project and seeds deterministic
    /// browser/process defaults that the manual E2E script can assert against.
    func run() throws {
        let orchestrator = try makeOrchestrator()
        let normalizedProjectDir = normalizePath(projectDir)
        try materializeDemoFixtureIfNeeded(projectDir: normalizedProjectDir, variant: template)
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

        try orchestrator.updateProjectConfig(projectID: project.id) { config in
            config.ports = fixturePorts
            config.stopScript = fixtureStopScript
            config.processes = fixtureProcesses
            config.browserSessions = fixtureBrowserSessions
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
            }
        }

        let payload = SeedFixturePayload(
            projectID: project.id, defaultWorkspace: try orchestrator.store.workspace(dir: project.dir).map(workspaceSummaryPayload))
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

private struct RegisterProjectCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "register-project")

    @Option(name: .long) var projectDir: String

    /// Registers a directory as a Spaces project (reusing one already registered
    /// there) and emits its default workspace, so latency/perf harnesses that
    /// have no project of their own can get a workspace-owned terminal session
    /// without the git worktree setup `create-workspace` implies.
    func run() throws {
        let orchestrator = try makeOrchestrator()
        let normalizedProjectDir = normalizePath(projectDir)
        let project = try orchestrator.project(dir: normalizedProjectDir) ?? orchestrator.addProject(dir: normalizedProjectDir)
        guard let workspace = try orchestrator.store.workspace(dir: project.dir) else {
            throw ValidationError("Default workspace not found for project: \(project.dir)")
        }
        try emitJSON(workspaceSummaryPayload(workspace))
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
        try emitJSON(workspaceSummaryPayload(workspace))
    }
}

private struct DumpWorkspaceCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "dump-workspace")

    @Option(name: .long) var workspaceDir: String

    /// Dumps persisted workspace/runtime state as JSON so the manual E2E script
    /// can assert on the real database contents without reaching into SQLite
    /// directly.
    func run() throws {
        let (orchestrator, workspace) = try resolveWorkspace(dir: workspaceDir)
        let payload = WorkspaceDumpPayload(
            workspace: workspaceSummaryPayload(workspace),
            settings: try orchestrator.workspaceSettings(workspaceID: workspace.id).map(workspaceSettingsPayload),
            runningProcesses: try orchestrator.runningProcesses(workspaceID: workspace.id).map {
                RunningProcessPayload(
                    id: $0.id, name: $0.templateName, pid: try resolvedPID(for: $0), status: $0.status.rawValue, terminalApp: $0.terminalApp,
                    terminalTrackingID: $0.terminalTrackingID)
            },
            windows: try orchestrator.windows(workspaceID: workspace.id).map {
                WindowPayload(
                    name: $0.name, app: $0.app, role: $0.role, detail: $0.detail, targetURL: $0.targetURL, terminalTrackingID: $0.terminalTrackingID)
            },
            agentWindows: try orchestrator.agentWindows(workspaceID: workspace.id).map {
                AgentWindowPayload(
                    id: $0.id, label: $0.label, provider: $0.provider.rawValue, status: $0.status.rawValue, terminalTrackingID: $0.terminalTrackingID)
            })
        try emitJSON(payload)
    }

    private func resolvedPID(for process: RunningProcessRecord) throws -> Int? {
        if let pid = process.pid { return pid }
        guard process.terminalApp == TerminalHost.spaces.appName else { return nil }
        guard let sessionID = process.terminalTrackingID, !sessionID.isEmpty else { return nil }
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
        let workspace = try resolveWorkspace(dir: workspaceDir).workspace
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
        let (orchestrator, workspace) = try resolveWorkspace(dir: workspaceDir)
        guard let process = try orchestrator.runningProcesses(workspaceID: workspace.id).first(where: { $0.templateName == processName }) else {
            throw ValidationError("Running process not found: \(processName)")
        }
        guard let sessionID = process.terminalTrackingID, !sessionID.isEmpty else {
            throw ValidationError("Running process has no built-in terminal session: \(processName)")
        }
        try IPCNotification.post(
            IPCNotification.closeTerminalSessionWindow,
            userInfo: [
                IPCNotification.terminalSessionIDUserInfoKey: sessionID,
                IPCNotification.terminalCloseDispositionUserInfoKey: TerminalPaneCloseDisposition.teardown.rawValue,
            ])
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
            IPCNotification.closeTerminalSessionWindow,
            userInfo: [
                IPCNotification.terminalSessionIDUserInfoKey: trimmedSessionID,
                IPCNotification.terminalCloseDispositionUserInfoKey: TerminalPaneCloseDisposition.teardown.rawValue,
            ])
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

    /// Deletes one workspace through the production lifecycle path so the manual harness can fall back when
    /// the delete confirmation UI is flaky. The record is gone afterwards, so the harness gets the identity
    /// it asked to delete plus whatever the delete reported about its branches.
    func run() throws {
        let (orchestrator, workspace) = try resolveWorkspace(dir: workspaceDir)
        let outcome = try orchestrator.archiveWorkspace(workspaceID: workspace.id)
        guard try orchestrator.store.workspace(id: workspace.id) == nil else {
            throw ValidationError("Workspace still present after delete: \(workspace.id)")
        }
        try emitJSON(WorkspaceDeletePayload(id: workspace.id, name: workspace.displayName, dir: workspace.dir, notice: outcome.notice))
    }
}

private struct HideWorkspaceCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "hide-workspace")

    @Option(name: .long) var workspaceDir: String

    func run() throws {
        let (orchestrator, workspace) = try resolveWorkspace(dir: workspaceDir)
        try orchestrator.updateWorkspaceHidden(workspaceID: workspace.id, isHidden: true)
        guard let updated = try orchestrator.store.workspace(id: workspace.id) else {
            throw ValidationError("Workspace disappeared: \(workspace.id)")
        }
        try emitJSON(workspaceSummaryPayload(updated))
    }
}

private struct ClearWorkspaceAgentWindowsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "clear-workspace-agent-windows")

    @Option(name: .long) var workspaceDir: String

    func run() throws {
        let (orchestrator, workspace) = try resolveWorkspace(dir: workspaceDir)
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
        let (orchestrator, workspace) = try resolveWorkspace(dir: workspaceDir)
        try orchestrator.updateWorkspaceSettings(workspaceID: workspace.id) { settings in settings.stopScript = stopScript }
        guard let updated = try orchestrator.store.workspace(dir: workspace.dir) else {
            throw ValidationError("Workspace disappeared at: \(workspace.dir)")
        }
        try emitJSON(workspaceSummaryPayload(updated))
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
        let (orchestrator, workspace) = try resolveWorkspace(dir: workspaceDir)
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
        guard let updated = try orchestrator.store.workspace(dir: workspace.dir) else {
            throw ValidationError("Workspace disappeared at: \(workspace.dir)")
        }
        try emitJSON(workspaceSummaryPayload(updated))
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
        let (orchestrator, workspace) = try resolveWorkspace(dir: workspaceDir)
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedCommand = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { throw ValidationError("Missing process name.") }
        guard !trimmedCommand.isEmpty else { throw ValidationError("Missing process command.") }
        try orchestrator.updateWorkspaceSettings(workspaceID: workspace.id) { settings in
            settings.processes.removeAll { ($0.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines) == trimmedName }
            settings.processes.append(ProcessTemplate(name: trimmedName, command: trimmedCommand))
        }
        guard let updated = try orchestrator.workspaceSettings(workspaceID: workspace.id) else {
            throw ValidationError("Workspace settings missing at: \(workspace.dir)")
        }
        try emitJSON(workspaceSettingsPayload(updated))
    }
}

private struct RemoveWorkspaceProcessCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "remove-workspace-process")

    @Option(name: .long) var workspaceDir: String
    @Option(name: .long) var name: String

    func run() throws {
        let (orchestrator, workspace) = try resolveWorkspace(dir: workspaceDir)
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { throw ValidationError("Missing process name.") }
        try orchestrator.updateWorkspaceSettings(workspaceID: workspace.id) { settings in
            settings.processes.removeAll { ($0.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines) == trimmedName }
        }
        guard let updated = try orchestrator.workspaceSettings(workspaceID: workspace.id) else {
            throw ValidationError("Workspace settings missing at: \(workspace.dir)")
        }
        try emitJSON(workspaceSettingsPayload(updated))
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
    let certificateFingerprint: String
    let expiresAt: String?
}

private struct WorkspaceDeletePayload: Codable {
    let id: String
    let name: String
    let dir: String
    let notice: String?
}

private struct WorkspaceSummaryPayload: Codable {
    let id: String
    let name: String
    let dir: String
    let isRunning: Bool
    let notes: String?
}

private struct WorkspaceSettingsPayload: Codable {
    let stopScript: String?
    let ports: [String]
    let processes: [NamedCommandPayload]
    let browserSessions: [NamedURLPayload]
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
}

private struct WindowPayload: Codable {
    let name: String?
    let app: String
    let role: String
    let detail: String?
    let targetURL: String?
    let terminalTrackingID: String?
}

private struct AgentWindowPayload: Codable {
    let id: String
    let label: String?
    let provider: String
    let status: String
    let terminalTrackingID: String?
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

private struct ClickApplicationWindowPayload: Codable {
    let executableName: String
    let windowTitle: String?
    let pointX: CGFloat
    let pointY: CGFloat
    let mouseDownUptimeNanoseconds: UInt64
    let mouseUpUptimeNanoseconds: UInt64
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
    /// Admin socket of the Caddy router this profile's daemon owns. Harness cleanup needs it to
    /// recognize a router that outlived its daemon: the path embeds a hash of the runtime directory,
    /// so resolving it here — through the same profile logic that produced it — is what keeps a
    /// harness from ever reaching another profile's (or the installed profile's) router.
    let routerAdminSocketPath: String
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
        routerAdminSocketPath = try CaddyService.adminSocketPath()

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

private struct ClickEventTiming {
    let mouseDownUptimeNanoseconds: UInt64
    let mouseUpUptimeNanoseconds: UInt64
}

/// Looks up one workspace by project directory and display name, matching the GUI's
/// visible naming semantics rather than internal IDs. When `name` is nil, returns the
/// project's default workspace.
private func workspaceSummary(orchestrator: WorkspaceOrchestrator, projectDir: String, name: String?) throws -> WorkspaceSummaryPayload? {
    let normalizedProjectDir = normalizePath(projectDir)
    guard let project = try orchestrator.project(dir: normalizedProjectDir) else { return nil }
    let workspaces = try orchestrator.listWorkspaces(projectID: project.id)
    let match: WorkspaceSummary?
    if let name { match = workspaces.first(where: { $0.displayName == name }) } else { match = workspaces.first(where: \.isDefault) }
    guard let workspace = match else { return nil }
    return workspaceSummaryPayload(workspace)
}

private func workspaceSummaryPayload(_ workspace: WorkspaceRecord) -> WorkspaceSummaryPayload {
    WorkspaceSummaryPayload(id: workspace.id, name: workspace.displayName, dir: workspace.dir, isRunning: workspace.isRunning, notes: workspace.notes)
}

private func workspaceSummaryPayload(_ workspace: WorkspaceSummary) -> WorkspaceSummaryPayload {
    WorkspaceSummaryPayload(id: workspace.id, name: workspace.displayName, dir: workspace.dir, isRunning: workspace.isRunning, notes: workspace.notes)
}

private func workspaceSettingsPayload(_ settings: WorkspaceSettings) -> WorkspaceSettingsPayload {
    WorkspaceSettingsPayload(
        stopScript: settings.stopScript, ports: settings.ports.map(\.name),
        processes: settings.processes.map { .init(name: $0.name, command: $0.command) },
        browserSessions: settings.browserSessions.map { .init(name: $0.name, url: $0.url) })
}

/// Shared JSON encoder for the shell harness.
// MARK: - Automation helpers (test seam; automation authoring is GUI-only in the product)

/// Sends a profile automation command to the adjacent daemon and emits its response section as JSON,
/// exactly like the app/CLI would over the same profile socket, so the shell harness drives real
/// scheduler state. The harness is bound to this worktree's profile by construction: this binary
/// resolves its own profile from where it sits in the checkout.
private func sendAutomationProfileCommand(_ command: TerminalServiceProfileCommand) throws -> TerminalServiceProfileCommandResponse {
    try TerminalService.sendProfileCommand(command)
}

private func automationFields(
    name: String, enabled: Bool, trigger: String, cron: String?, kind: String, script: String, agentCommand: String?, agentPrompt: String?,
    workspaceID: String, timeoutSeconds: Int?, concurrency: String, missedRun: String
) -> TerminalServiceAutomationFields {
    TerminalServiceAutomationFields(
        name: name, enabled: enabled, triggerKind: trigger, cronExpression: normalizedOptional(cron), kind: kind, script: script,
        agentCommand: normalizedOptional(agentCommand), agentPrompt: normalizedOptional(agentPrompt), workspaceID: workspaceID,
        timeoutSeconds: timeoutSeconds, concurrencyPolicy: concurrency, missedRunPolicy: missedRun)
}

private struct AutomationCreateCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "automation-create")

    @Option(name: .long) var name: String
    @Option(name: .long) var script: String
    @Option(name: .long) var trigger: String = "manual"
    @Option(name: .long) var cron: String?
    /// `script` or `agent` — plumbed through so a later commit can e2e agent-kind automations; the daemon's
    /// scheduler does not yet execute an agent-kind run (see `AutomationService`'s launch guard).
    @Option(name: .long) var kind: String = "script"
    @Option(name: .long) var agentCommand: String?
    @Option(name: .long) var agentPrompt: String?
    @Option(name: .long) var workspaceID: String
    @Option(name: .long) var concurrency: String = "allow"
    @Option(name: .long) var missedRun: String = "run_once"
    @Option(name: .long) var timeoutSeconds: Int?
    @Flag(name: .long, inversion: .prefixedNo) var enabled = true

    func run() throws {
        let fields = automationFields(
            name: name, enabled: enabled, trigger: trigger, cron: cron, kind: kind, script: script, agentCommand: agentCommand,
            agentPrompt: agentPrompt, workspaceID: workspaceID, timeoutSeconds: timeoutSeconds, concurrency: concurrency, missedRun: missedRun)
        try emitJSON(try sendAutomationProfileCommand(.automationCreate(fields)).automations ?? [])
    }
}

private struct AutomationUpdateCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "automation-update")

    @Option(name: .long) var id: String
    @Option(name: .long) var name: String
    @Option(name: .long) var script: String
    @Option(name: .long) var trigger: String = "manual"
    @Option(name: .long) var cron: String?
    @Option(name: .long) var kind: String = "script"
    @Option(name: .long) var agentCommand: String?
    @Option(name: .long) var agentPrompt: String?
    @Option(name: .long) var workspaceID: String
    @Option(name: .long) var concurrency: String = "allow"
    @Option(name: .long) var missedRun: String = "run_once"
    @Option(name: .long) var timeoutSeconds: Int?
    @Flag(name: .long, inversion: .prefixedNo) var enabled = true

    func run() throws {
        let fields = automationFields(
            name: name, enabled: enabled, trigger: trigger, cron: cron, kind: kind, script: script, agentCommand: agentCommand,
            agentPrompt: agentPrompt, workspaceID: workspaceID, timeoutSeconds: timeoutSeconds, concurrency: concurrency, missedRun: missedRun)
        try emitJSON(try sendAutomationProfileCommand(.automationUpdate(.init(id: id, fields: fields))).automations ?? [])
    }
}

private struct AutomationDeleteCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "automation-delete")

    @Option(name: .long) var id: String

    func run() throws {
        let response = try sendAutomationProfileCommand(.automationDelete(id: try required(id, label: "id")))
        try emitJSON(AutomationDeletePayload(success: true, message: response.message))
    }
}

private struct AutomationDeletePayload: Encodable {
    let success: Bool
    let message: String
}

private struct AutomationListCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "automation-list")

    func run() throws { try emitJSON(try sendAutomationProfileCommand(.automationList).automations ?? []) }
}

private struct AutomationRunsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "automation-runs")

    @Option(name: .long) var automationID: String?

    func run() throws {
        try emitJSON(
            try sendAutomationProfileCommand(.automationRunsList(.init(automationID: normalizedOptional(automationID)))).automationRuns ?? [])
    }
}

private struct AutomationTriggerCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "automation-trigger")

    @Option(name: .long) var id: String

    func run() throws { try emitJSON(try sendAutomationProfileCommand(.automationTrigger(id: try required(id, label: "id"))).automationRuns ?? []) }
}

private struct AutomationCancelCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "automation-cancel")

    @Option(name: .long) var runID: String

    func run() throws {
        try emitJSON(try sendAutomationProfileCommand(.automationRunCancel(runID: try required(runID, label: "run-id"))).automationRuns ?? [])
    }
}

private struct AutomationEndAgentsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "automation-end-agents")

    @Option(name: .long) var runID: String

    func run() throws {
        try emitJSON(try sendAutomationProfileCommand(.automationEndAgents(runID: try required(runID, label: "run-id"))).automationRuns ?? [])
    }
}

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

/// Resolves a workspace directory to its orchestrator and stored record. Shared by every
/// command that looks up one workspace by `--workspace-dir` before acting on it, so the
/// "Workspace not found at: <normalized dir>" error stays identical across all of them.
private func resolveWorkspace(dir: String) throws -> (orchestrator: WorkspaceOrchestrator, workspace: WorkspaceRecord) {
    let orchestrator = try makeOrchestrator()
    let normalizedWorkspaceDir = normalizePath(dir)
    guard let workspace = try orchestrator.store.workspace(dir: normalizedWorkspaceDir) else {
        throw ValidationError("Workspace not found at: \(normalizedWorkspaceDir)")
    }
    return (orchestrator, workspace)
}

/// Resolves a workspace directory to its stable id from the store. The harness uses this
/// only to address IPC focus commands at the running app; the focus itself runs in the app.
private func workspaceID(forDir dir: String) throws -> String { try resolveWorkspace(dir: dir).workspace.id }

private func sendTerminalServiceRequestForSession(sessionID rawSessionID: String, request: TerminalServiceRequest) throws -> TerminalServiceResponse {
    let sessionID = try required(rawSessionID, label: "session-id")
    let request = request.withSessionID(sessionID)
    return try TerminalServiceClient.send(request: request, socketPath: try TerminalServicePaths.socketPath(), timeout: 15)
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

private func normalizedOptional(_ value: String?) -> String? { normalizedNonEmpty(value) }

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

// Cached because ISO8601DateFormatter construction is expensive; ISO8601DateFormatter is
// documented thread-safe so one shared instance is safe to reuse across this module's helpers.
nonisolated(unsafe) private let e2eISO8601Formatter = ISO8601DateFormatter()

private func nowISO8601() -> String { e2eISO8601Formatter.string(from: Date()) }

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

        let window = server.openPairingWindow(hosts: [linkHost], name: "Spaces Standalone", code: code)
        print(
            "\(label)\thost=\(bindHost)\tport=\(server.listeningPort)\tpairing_link=\(window.linkString)\tpairing_code=\(window.code)\texpires_at=\(e2eISO8601Formatter.string(from: window.expiresAt))\tbundle=\(SpacesDeviceFirstPartyPolicy.allowedBundleID)"
        )
        fflush(stdout)
    }
}

private final class DeviceAPIRequestClient: @unchecked Sendable {
    private let host: String
    private let port: UInt16
    private let certificateFingerprint: String

    init(host: String, port: UInt16, certificateFingerprint: String) {
        self.host = host
        self.port = port
        self.certificateFingerprint = certificateFingerprint
    }

    func request(requestData: Data) throws -> Data {
        let connection = makeConnection()
        defer { connection.cancel() }
        try waitUntilReady(connection)
        try send(requestData: requestData, connection: connection)
        return try receiveSingleResponse(from: connection)
    }

    func stream(requestData: Data) throws -> Never {
        let connection = makeConnection()
        try waitUntilReady(connection)
        try send(requestData: requestData, connection: connection)
        receiveStream(from: connection, buffered: LineFrameBuffer())
        dispatchMain()
    }

    /// Opens a subscription stream, collects every newline-delimited payload line, and returns once the
    /// stream has been idle for `settleSeconds` (with at least one line received) or `overallSeconds`
    /// elapses. Used by the demo recorder to capture a session's settled steady-state frames.
    func collectStream(requestData: Data, settleSeconds: Double, overallSeconds: Double) throws -> [Data] {
        let connection = makeConnection()
        defer { connection.cancel() }
        try waitUntilReady(connection)
        try send(requestData: requestData, connection: connection)
        let box = StreamCollectorBox()
        receiveCollectStream(from: connection, buffered: LineFrameBuffer(), box: box)
        let startedAt = Date()
        while true {
            Thread.sleep(forTimeInterval: 0.05)
            let snapshot = box.snapshot()
            if let error = snapshot.error, snapshot.lineCount == 0 { throw error }
            let now = Date()
            if snapshot.lineCount > 0, let lastActivity = snapshot.lastActivity, now.timeIntervalSince(lastActivity) >= settleSeconds { break }
            if now.timeIntervalSince(startedAt) >= overallSeconds { break }
        }
        return box.lines()
    }

    private func receiveCollectStream(from connection: NWConnection, buffered buffer: LineFrameBuffer, box: StreamCollectorBox) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { content, _, isComplete, error in
            if let error {
                box.setError(error)
                return
            }
            var nextBuffer = buffer
            if let content { nextBuffer.append(content) }
            while let line = nextBuffer.popLine() { box.append(line) }
            if isComplete {
                box.markComplete()
                return
            }
            self.receiveCollectStream(from: connection, buffered: nextBuffer, box: box)
        }
    }

    /// Sends one tunnel-opening request line and reads exactly one response line, returning the
    /// still-open connection as a raw byte pipe. Any bytes received after the response line's
    /// trailing newline already belong to the pipe and are surfaced as `initialTunnelData`.
    func openTunnel(requestData: Data) throws -> OpenedTunnel {
        let connection = makeConnection()
        try waitUntilReady(connection)
        try send(requestData: requestData, connection: connection)
        let semaphore = DispatchSemaphore(value: 0)
        let box = TunnelResponseLineBox()
        receiveTunnelResponseLine(from: connection, buffered: LineFrameBuffer(), box: box, semaphore: semaphore)
        guard semaphore.wait(timeout: .now() + 10) == .success else {
            connection.cancel()
            throw DeviceAPIRequestError.timeout("Timed out waiting for the Device API tunnel response.")
        }
        if let error = box.error() {
            connection.cancel()
            throw error
        }
        let (line, remainder) = box.value()
        return OpenedTunnel(connection: connection, responseLine: line, initialTunnelData: remainder)
    }

    /// Writes raw bytes into an opened tunnel pipe. Unlike `send(requestData:connection:)`, no
    /// newline is appended: the connection no longer speaks newline-delimited JSON.
    func sendTunnelBytes(_ data: Data, over connection: NWConnection) throws {
        let semaphore = DispatchSemaphore(value: 0)
        let box = DeviceAPIRequestResultBox()
        connection.send(
            content: data,
            completion: .contentProcessed { error in
                if let error { box.setError(error) }
                semaphore.signal()
            })
        guard semaphore.wait(timeout: .now() + 10) == .success else {
            throw DeviceAPIRequestError.timeout("Timed out sending bytes through the service tunnel.")
        }
        if let error = box.error() { throw error }
    }

    /// Copies tunnel pipe bytes to stdout until the remote side closes the pipe, failing if the
    /// deadline passes before EOF.
    func relayTunnelToStandardOutput(from connection: NWConnection, deadline: Date) throws {
        while true {
            let semaphore = DispatchSemaphore(value: 0)
            let box = TunnelChunkBox()
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1_048_576) { content, _, isComplete, error in
                box.set(content: content, isComplete: isComplete, error: error)
                semaphore.signal()
            }
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0, semaphore.wait(timeout: .now() + remaining) == .success else {
                connection.cancel()
                throw DeviceAPIRequestError.timeout("Timed out waiting for tunneled service bytes.")
            }
            let chunk = box.value()
            if let error = chunk.error {
                connection.cancel()
                throw error
            }
            if let content = chunk.content, !content.isEmpty { FileHandle.standardOutput.write(content) }
            if chunk.isComplete { return }
        }
    }

    private func receiveTunnelResponseLine(
        from connection: NWConnection, buffered buffer: LineFrameBuffer, box: TunnelResponseLineBox, semaphore: DispatchSemaphore
    ) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { content, _, isComplete, error in
            if let error {
                box.setError(error)
                semaphore.signal()
                return
            }
            var nextBuffer = buffer
            if let content { nextBuffer.append(content) }
            if let line = nextBuffer.popLine() {
                box.set(line: line, remainder: nextBuffer.drainRemainder())
                semaphore.signal()
                return
            }
            if isComplete {
                box.setError(DeviceAPIRequestError.emptyResponse)
                semaphore.signal()
                return
            }
            self.receiveTunnelResponseLine(from: connection, buffered: nextBuffer, box: box, semaphore: semaphore)
        }
    }

    private func makeConnection() -> NWConnection {
        let endpointPort = NWEndpoint.Port(rawValue: port)!
        return NWConnection(
            host: NWEndpoint.Host(host), port: endpointPort,
            using: SpacesPinnedTLSConnector.tlsParameters(certificateFingerprint: certificateFingerprint))
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
        receiveSingleResponse(from: connection, buffered: LineFrameBuffer(), box: box, semaphore: semaphore)
        guard semaphore.wait(timeout: .now() + 10) == .success else {
            throw DeviceAPIRequestError.timeout("Timed out waiting for the Device API response.")
        }
        if let error = box.error() { throw error }
        return box.responseData()
    }

    private func receiveSingleResponse(
        from connection: NWConnection, buffered buffer: LineFrameBuffer, box: DeviceAPIRequestResultBox, semaphore: DispatchSemaphore
    ) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { content, _, isComplete, error in
            if let error {
                box.setError(error)
                semaphore.signal()
                return
            }
            var nextBuffer = buffer
            if let content { nextBuffer.append(content) }
            if let line = nextBuffer.popLine() {
                box.setResponseData(line)
                semaphore.signal()
                return
            }
            if isComplete {
                guard !nextBuffer.isEmpty else {
                    box.setError(DeviceAPIRequestError.emptyResponse)
                    semaphore.signal()
                    return
                }
                box.setResponseData(nextBuffer.drainRemainder())
                semaphore.signal()
                return
            }
            self.receiveSingleResponse(from: connection, buffered: nextBuffer, box: box, semaphore: semaphore)
        }
    }

    private func receiveStream(from connection: NWConnection, buffered buffer: LineFrameBuffer) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { content, _, isComplete, error in
            if let error {
                fputs("\(error)\n", stderr)
                exit(1)
            }
            var nextBuffer = buffer
            if let content { nextBuffer.append(content) }
            while let line = nextBuffer.popLine() {
                FileHandle.standardOutput.write(line)
                FileHandle.standardOutput.write(Data([0x0A]))
                fflush(stdout)
            }
            if isComplete { exit(0) }
            self.receiveStream(from: connection, buffered: nextBuffer)
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

/// Thread-safe accumulator for a subscription stream: collects newline-delimited payload lines and
/// tracks the wall-clock time of the most recent line so a poller can detect the stream has settled.
private final class StreamCollectorBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storedLines: [Data] = []
    private var storedError: Error?
    private var storedLastActivity: Date?
    private var storedComplete = false

    func append(_ line: Data) {
        lock.lock()
        storedLines.append(line)
        storedLastActivity = Date()
        lock.unlock()
    }

    func setError(_ error: Error) {
        lock.lock()
        storedError = error
        lock.unlock()
    }

    func markComplete() {
        lock.lock()
        storedComplete = true
        lock.unlock()
    }

    func snapshot() -> (lineCount: Int, lastActivity: Date?, error: Error?, complete: Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (storedLines.count, storedLastActivity, storedError, storedComplete)
    }

    func lines() -> [Data] {
        lock.lock()
        defer { lock.unlock() }
        return storedLines
    }
}

/// A service tunnel opened over the Device API: the raw pipe connection, the single response
/// line the daemon issued before the handover, and any pipe bytes that arrived with it.
private struct OpenedTunnel {
    let connection: NWConnection
    let responseLine: Data
    let initialTunnelData: Data
}

private final class TunnelResponseLineBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storedError: Error?
    private var storedLine = Data()
    private var storedRemainder = Data()

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

    func set(line: Data, remainder: Data) {
        lock.lock()
        storedLine = line
        storedRemainder = remainder
        lock.unlock()
    }

    func value() -> (line: Data, remainder: Data) {
        lock.lock()
        let value = (storedLine, storedRemainder)
        lock.unlock()
        return value
    }
}

private final class TunnelChunkBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storedError: Error?
    private var storedContent: Data?
    private var storedIsComplete = false

    func set(content: Data?, isComplete: Bool, error: Error?) {
        lock.lock()
        storedContent = content
        storedIsComplete = isComplete
        storedError = error
        lock.unlock()
    }

    func value() -> (content: Data?, isComplete: Bool, error: Error?) {
        lock.lock()
        let value = (storedContent, storedIsComplete, storedError)
        lock.unlock()
        return value
    }
}

private func mobileServePairingLinkHost(host: String) -> String {
    SpacesDeviceAPINetworkInterfaces.pairingLinkHosts(boundHost: host).first ?? SpacesDeviceAPIDefaults.loopbackHost
}

/// Wraps a value in single quotes for a POSIX shell, ending and reopening the quoted run around each
/// embedded quote (`'\''`). This is the escape the shell actually reverses; the `'\"'\"'` spelling yields
/// `"\"` instead of a quote, which matters here because these values include whole remote scripts.
private func profileShellQuoted(_ value: String) -> String {
    let escaped = value.replacingOccurrences(of: "'", with: #"'\''"#)
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
    let frontTerminalPane = focusedTerminalPaneIdentity(appElement: appElement) ?? focusedWindow.flatMap { firstTerminalPaneIdentity(in: $0) }

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
                String(identifier.dropFirst(prefix.count)), axStringAttribute(current, attribute: kAXValueAttribute as String) ?? "",
                axStringAttribute(current, attribute: kAXDescriptionAttribute as String) ?? ""
            )
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
            String(identifier.dropFirst(prefix.count)), axStringAttribute(element, attribute: kAXValueAttribute as String) ?? "",
            axStringAttribute(element, attribute: kAXDescriptionAttribute as String) ?? ""
        )
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

// When applicationPID is provided, target that exact running instance instead of matching by executable
// name: multiple Spaces profiles (the installed app plus dev worktrees) can all run executables named
// SpacesApp, and synthetic events must land on the instance the harness itself launched.
private func targetApplicationWindow(executableName: String, applicationPID: Int32?, windowTitleContains: String?) throws -> TargetApplicationWindow {
    let executableName = executableName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !executableName.isEmpty else { throw ValidationError("Missing executable name.") }
    let titleFilter = windowTitleContains?.trimmingCharacters(in: .whitespacesAndNewlines)
    let applications: [NSRunningApplication]
    if let applicationPID {
        guard let application = NSWorkspace.shared.runningApplications.first(where: { $0.processIdentifier == applicationPID }) else {
            throw ValidationError("Application not running: pid \(applicationPID)")
        }
        guard application.executableURL?.lastPathComponent == executableName else {
            throw ValidationError("Application with pid \(applicationPID) is not \(executableName)")
        }
        applications = [application]
    } else {
        applications = NSWorkspace.shared.runningApplications.filter { $0.executableURL?.lastPathComponent == executableName }
    }
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

private func postClickEvent(at point: CGPoint) throws -> ClickEventTiming {
    guard let downEvent = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left),
        let upEvent = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)
    else { throw ValidationError("Unable to create mouse click event.") }
    let mouseDownUptimeNanoseconds = DispatchTime.now().uptimeNanoseconds
    downEvent.post(tap: .cghidEventTap)
    Thread.sleep(forTimeInterval: 0.02)
    let mouseUpUptimeNanoseconds = DispatchTime.now().uptimeNanoseconds
    upEvent.post(tap: .cghidEventTap)
    return ClickEventTiming(mouseDownUptimeNanoseconds: mouseDownUptimeNanoseconds, mouseUpUptimeNanoseconds: mouseUpUptimeNanoseconds)
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
