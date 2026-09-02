import AppKit
import Foundation
import Testing
import workspacecore

@testable import spacesterminalcore
@testable import spacesui

@Suite struct AppKitControllerLifecycleTests {
    private final class LaunchConfigurationCapture: @unchecked Sendable { var value: TerminalSessionLaunchConfiguration? }

    private final class ProcessLifecyclePolicySpy: ProcessLifecyclePolicyController {
        var automaticTerminationReasons: [String] = []
        var disableSuddenTerminationCallCount = 0

        func disableAutomaticTermination(_ reason: String) { automaticTerminationReasons.append(reason) }
        func disableSuddenTermination() { disableSuddenTerminationCallCount += 1 }
    }

    @Test func persistentTerminationPolicyProtectsTheAppProcess() {
        let spy = ProcessLifecyclePolicySpy()

        AppKitController.applyPersistentTerminationPolicy(processInfo: spy)

        #expect(spy.automaticTerminationReasons == [AppKitController.persistentTerminationPolicyReason()])
        #expect(spy.disableSuddenTerminationCallCount == 1)
    }

    @Test func terminalQuitPolicyPromptsOnlyWhenLiveSessionsExist() {
        #expect(TerminalPaneService.terminalQuitPolicy(liveTerminalSessionCount: 0) == .quitImmediately)
        #expect(TerminalPaneService.terminalQuitPolicy(liveTerminalSessionCount: 2) == .promptForLiveSessions(count: 2))
    }

    @Test func liveBuiltInTerminalSessionsTreatsListFailureAsEmpty() {
        let sessions = TerminalPaneService.liveBuiltInTerminalSessions { throw NSError(domain: "TerminalServiceUnavailable", code: 1) }

        #expect(sessions.isEmpty)
    }

    @Test func stopAllQuitSelectionMapsLiveSessionsToUniqueWorkspaceIDs() throws {
        let runningWorkspace = Self.workspaceRecord(id: "workspace-running", isRunning: true)
        let stoppedWorkspaceWithSession = Self.workspaceRecord(id: "workspace-session", isRunning: false)
        let secondStoppedWorkspaceWithSession = Self.workspaceRecord(id: "workspace-session-b", isRunning: false)
        let sessions = [
            Self.terminalSessionSummary(id: "session-owned-a"), Self.terminalSessionSummary(id: "session-owned-b"),
            Self.terminalSessionSummary(id: "session-owned-c"),
        ]

        let selection = try AppKitController.stopAllQuitWorkspaceSelection(runningWorkspaces: [runningWorkspace], liveSessions: sessions) {
            sessionID in
            switch sessionID {
            case "session-owned-a": stoppedWorkspaceWithSession
            case "session-owned-b": runningWorkspace
            case "session-owned-c": secondStoppedWorkspaceWithSession
            default: nil
            }
        }

        #expect(selection.workspaceIDs == ["workspace-running", "workspace-session", "workspace-session-b"])
        #expect(selection.associatedLiveSessionIDs == ["session-owned-a", "session-owned-b", "session-owned-c"])
    }

    @Test func stopAllQuitRoutesWorkspaceStopThroughDaemonProfileCommand() throws {
        var sent: TerminalServiceProfileCommand?

        try AppKitController.stopWorkspaceForStopAllQuit(workspaceID: "workspace-automation") { command in
            sent = command
            return TerminalServiceProfileCommandResponse(message: "Workspace stopped.")
        }

        #expect(sent == .workspaceStop(workspaceID: "workspace-automation"))
    }

    @Test func stopAllQuitCleanupMappingFailureRequiresFailureChoice() {
        let liveSessions = [Self.terminalSessionSummary(id: "session-unknown")]
        var terminatedSessionIDs: [String] = []

        let result = AppKitController.performStopAllQuitCleanup(
            liveSessions: liveSessions, runningWorkspaces: { [] }, workspaceForLiveSession: { _ in throw NSError(domain: "Mapping", code: 1) },
            stopWorkspace: { _ in }, terminateSession: { sessionID in terminatedSessionIDs.append(sessionID) }, listLiveSessions: { liveSessions },
            browserSessionTargetURLs: { _ in [] }, closeBrowserSessions: { _, _ in })

        #expect(!result.succeeded)
        #expect(result.preparationError != nil)
        #expect(result.remainingSessionIDs == ["session-unknown"])
        #expect(terminatedSessionIDs.isEmpty)
    }

    @Test func stopAllQuitCleanupRawTerminatesOnlyUnownedRemainingSessions() {
        let liveSessions = [Self.terminalSessionSummary(id: "session-owned"), Self.terminalSessionSummary(id: "session-unowned")]
        var stoppedWorkspaceIDs: [String] = []
        var terminatedSessionIDs: [String] = []
        var browserCleanupWorkspaceIDs: [String] = []
        var listCalls = 0

        let result = AppKitController.performStopAllQuitCleanup(
            liveSessions: liveSessions, runningWorkspaces: { [] },
            workspaceForLiveSession: { sessionID in sessionID == "session-owned" ? Self.workspaceRecord(id: "workspace-owned", isRunning: false) : nil
            }, stopWorkspace: { workspaceID in stoppedWorkspaceIDs.append(workspaceID) },
            terminateSession: { sessionID in terminatedSessionIDs.append(sessionID) },
            listLiveSessions: {
                listCalls += 1
                return listCalls == 1 ? liveSessions : [Self.terminalSessionSummary(id: "session-owned")]
            }, browserSessionTargetURLs: { _ in ["http://127.0.0.1:3000"] },
            closeBrowserSessions: { workspaceID, _ in browserCleanupWorkspaceIDs.append(workspaceID) })

        #expect(stoppedWorkspaceIDs == ["workspace-owned"])
        #expect(browserCleanupWorkspaceIDs == ["workspace-owned"])
        #expect(terminatedSessionIDs == ["session-unowned"])
        #expect(result.rawTerminatedSessionIDs == ["session-unowned"])
        #expect(result.remainingSessionIDs == ["session-owned"])
    }

    @Test func stopAllQuitCleanupLoadsBrowserTargetsBeforeStoppingWorkspace() {
        let liveSessions = [Self.terminalSessionSummary(id: "session-owned")]
        var events: [String] = []
        var browserCleanupRequest: String?

        let result = AppKitController.performStopAllQuitCleanup(
            liveSessions: liveSessions, runningWorkspaces: { [] },
            workspaceForLiveSession: { _ in Self.workspaceRecord(id: "workspace-owned", isRunning: false) },
            stopWorkspace: { workspaceID in events.append("stop:\(workspaceID)") }, terminateSession: { _ in }, listLiveSessions: { [] },
            browserSessionTargetURLs: { workspaceID in
                events.append("targets:\(workspaceID)")
                return ["http://127.0.0.1:3000", "http://127.0.0.1:3000/admin"]
            }, closeBrowserSessions: { workspaceID, targetURLs in browserCleanupRequest = "\(workspaceID):\(targetURLs.joined(separator: ","))" })

        #expect(result.succeeded)
        #expect(events == ["targets:workspace-owned", "stop:workspace-owned"])
        #expect(browserCleanupRequest == "workspace-owned:http://127.0.0.1:3000,http://127.0.0.1:3000/admin")
        #expect(result.browserSessionTargetURLsByWorkspaceID["workspace-owned"] == ["http://127.0.0.1:3000", "http://127.0.0.1:3000/admin"])
    }

    @Test func stopAllQuitCleanupBrowserTargetFailureRequiresFailureChoiceBeforeMutation() {
        let liveSessions = [Self.terminalSessionSummary(id: "session-owned")]
        var stoppedWorkspaceIDs: [String] = []
        var terminatedSessionIDs: [String] = []
        var browserCleanupWorkspaceIDs: [String] = []

        let result = AppKitController.performStopAllQuitCleanup(
            liveSessions: liveSessions, runningWorkspaces: { [] },
            workspaceForLiveSession: { _ in Self.workspaceRecord(id: "workspace-owned", isRunning: false) },
            stopWorkspace: { workspaceID in stoppedWorkspaceIDs.append(workspaceID) },
            terminateSession: { sessionID in terminatedSessionIDs.append(sessionID) }, listLiveSessions: { liveSessions },
            browserSessionTargetURLs: { _ in throw NSError(domain: "BrowserTargets", code: 1) },
            closeBrowserSessions: { workspaceID, _ in browserCleanupWorkspaceIDs.append(workspaceID) })

        #expect(!result.succeeded)
        #expect(result.preparationError != nil)
        #expect(result.remainingSessionIDs == ["session-owned"])
        #expect(stoppedWorkspaceIDs.isEmpty)
        #expect(terminatedSessionIDs.isEmpty)
        #expect(browserCleanupWorkspaceIDs.isEmpty)
    }

    @Test func stopAllQuitForceChoiceRawTerminatesRemainingSessionsAndAllowsTermination() {
        let result = Self.cleanupResult(workspaceIDs: ["workspace-a"], remainingSessionIDs: ["session-a", "session-b"])
        var terminatedSessionIDs: [String] = []
        var browserCleanupWorkspaceIDs: [String] = []
        var browserCleanupTargetURLs: [String] = []

        let reply = AppKitController.stopAllQuitFailureTerminateReply(
            result: result, choice: .forceQuit, terminateSession: { sessionID in terminatedSessionIDs.append(sessionID) },
            closeBrowserSessions: { workspaceID, targetURLs in
                browserCleanupWorkspaceIDs.append(workspaceID)
                browserCleanupTargetURLs = targetURLs
            })

        #expect(reply == .terminateNow)
        #expect(terminatedSessionIDs == ["session-a", "session-b"])
        #expect(browserCleanupWorkspaceIDs == ["workspace-a"])
        #expect(browserCleanupTargetURLs == ["http://127.0.0.1:3000"])
    }

    @Test func stopAllQuitCancelChoiceKeepsAppOpenAfterCleanupFailure() {
        let result = Self.cleanupResult(workspaceIDs: ["workspace-a"], remainingSessionIDs: ["session-a"])
        var terminatedSessionIDs: [String] = []
        var browserCleanupWorkspaceIDs: [String] = []

        let reply = AppKitController.stopAllQuitFailureTerminateReply(
            result: result, choice: .cancelQuit, terminateSession: { sessionID in terminatedSessionIDs.append(sessionID) },
            closeBrowserSessions: { workspaceID, _ in browserCleanupWorkspaceIDs.append(workspaceID) })

        #expect(reply == .terminateCancel)
        #expect(terminatedSessionIDs.isEmpty)
        #expect(browserCleanupWorkspaceIDs.isEmpty)
    }

    /// Quitting with sessions kept running must leave every session alone, including the ad hoc terminal
    /// whose pane the app tears down on the way out.
    @Test func adHocSessionStopIsNotRequestedWhenQuitKeepsSessionsRunning() {
        #expect(TerminalPaneService.shouldRequestAdHocBareShellStopOnPaneClose(closedPaneOwnedOrEnded: true, isAppTerminatingAndKeepingSessions: false))
        #expect(!TerminalPaneService.shouldRequestAdHocBareShellStopOnPaneClose(closedPaneOwnedOrEnded: true, isAppTerminatingAndKeepingSessions: true))
    }

    @Test func appBuiltInTerminalLauncherUsesServiceCreateSessionPath() throws {
        let launchConfiguration = TerminalSessionLaunchConfiguration(
            sessionID: "service-session", title: "service", workingDirectory: "/tmp", shell: "/bin/zsh", command: nil,
            createdAt: "2026-05-27T00:00:00Z", workspaceID: "workspace-1", kind: .shell)
        let capturedConfiguration = LaunchConfigurationCapture()

        let launcher = TerminalPaneService.appBuiltInTerminalSessionLauncher { configuration in
            capturedConfiguration.value = configuration
            return Self.terminalSessionSummary(
                id: configuration.sessionID, title: configuration.title, workingDirectory: configuration.workingDirectory)
        }

        let summary = try launcher(launchConfiguration)

        #expect(capturedConfiguration.value == launchConfiguration)
        #expect(summary.id == "service-session")
    }

    private static func terminalSessionSummary(id: String, title: String = "Terminal", workingDirectory: String = "/tmp")
        -> TerminalServiceSessionSummary
    {
        TerminalServiceSessionSummary(
            id: id, title: title, workingDirectory: workingDirectory, backend: .ghosttyEmbedded, lifetimePolicy: .persistent, state: .running,
            servicePID: 123, childPID: 456, controlSocketPath: "/tmp/\(id).sock", outputPath: "/tmp/\(id).log")
    }

    private static func workspaceRecord(id: String, isRunning: Bool) -> WorkspaceRecord {
        WorkspaceRecord(
            id: id, projectID: "project-\(id)", dir: "/tmp/\(id)", dirname: nil, branch: nil, isDefault: false, isRunning: isRunning,
            lastLaunchedAt: isRunning ? "2026-07-01T00:00:00Z" : nil)
    }

    private static func cleanupResult(workspaceIDs: [String], remainingSessionIDs: [String]) -> AppKitController.StopAllQuitCleanupResult {
        AppKitController.StopAllQuitCleanupResult(
            workspaceIDs: workspaceIDs, stoppedWorkspaceIDs: [], associatedLiveSessionIDs: [],
            browserSessionTargetURLsByWorkspaceID: Dictionary(uniqueKeysWithValues: workspaceIDs.map { ($0, ["http://127.0.0.1:3000"]) }),
            stopFailures: [], rawTerminatedSessionIDs: [], rawTerminationFailures: [], remainingSessionIDs: remainingSessionIDs, preparationError: nil
        )
    }
}
