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

        #expect(sent == .workspaceStop(.init(cwd: FileManager.default.currentDirectoryPath, workspaceID: "workspace-automation")))
    }

    @Test func stopAllQuitCleanupMappingFailureRequiresFailureChoice() {
        let liveSessions = [Self.terminalSessionSummary(id: "session-unknown")]
        var terminatedSessionIDs: [String] = []

        let result = AppKitController.performStopAllQuitCleanup(
            liveSessions: liveSessions, parkAgentSessionsForRestore: { nil }, runningWorkspaces: { [] },
            workspaceForLiveSession: { _ in throw NSError(domain: "Mapping", code: 1) }, stopWorkspace: { _ in },
            terminateSession: { sessionID in terminatedSessionIDs.append(sessionID) }, listLiveSessions: { liveSessions },
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
            liveSessions: liveSessions, parkAgentSessionsForRestore: { nil }, runningWorkspaces: { [] },
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
            liveSessions: liveSessions, parkAgentSessionsForRestore: { nil }, runningWorkspaces: { [] },
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
            liveSessions: liveSessions, parkAgentSessionsForRestore: { nil }, runningWorkspaces: { [] },
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

    /// `parkAgentSessionsForRestore` captures the live coding agents while they are still live, so it has
    /// to run before anything stops a workspace. It also must run exactly once per quit, not once per
    /// workspace being stopped.
    /// The park runs once, in the window where the record it writes is both complete and committed: after
    /// the preparation steps that can still abandon the quit, and before the first stop, while the agent
    /// rows it reads are still live.
    @Test func parkAgentSessionsForRestoreRunsExactlyOnceAfterPreparationAndBeforeTheFirstWorkspaceStop() {
        let liveSessions = [Self.terminalSessionSummary(id: "session-owned")]
        var events: [String] = []

        let result = AppKitController.performStopAllQuitCleanup(
            liveSessions: liveSessions, parkAgentSessionsForRestore: {
                events.append("park")
                return "generation-1"
            }, runningWorkspaces: { [] },
            workspaceForLiveSession: { _ in Self.workspaceRecord(id: "workspace-owned", isRunning: false) },
            stopWorkspace: { workspaceID in events.append("stop:\(workspaceID)") }, terminateSession: { _ in }, listLiveSessions: { [] },
            browserSessionTargetURLs: { workspaceID in
                events.append("targets:\(workspaceID)")
                return []
            }, closeBrowserSessions: { _, _ in })

        #expect(result.succeeded)
        #expect(events == ["targets:workspace-owned", "park", "stop:workspace-owned"])
        #expect(result.parkedRestoreGeneration == "generation-1", "the quit keeps the record it parked, so it can drop it if it cancels")
    }

    /// A quit that fails in preparation hands the user a Cancel Quit choice and stops nothing, so nothing
    /// is parked: agents that keep running must not be offered back as though they had ended.
    @Test func parkAgentSessionsForRestoreDoesNotRunWhenPreparationFailsBeforeAnyStop() {
        let liveSessions = [Self.terminalSessionSummary(id: "session-owned")]
        var parkCount = 0

        let mappingFailure = AppKitController.performStopAllQuitCleanup(
            liveSessions: liveSessions, parkAgentSessionsForRestore: {
                parkCount += 1
                return nil
            }, runningWorkspaces: { [] },
            workspaceForLiveSession: { _ in throw NSError(domain: "Mapping", code: 1) }, stopWorkspace: { _ in }, terminateSession: { _ in },
            listLiveSessions: { liveSessions }, browserSessionTargetURLs: { _ in [] }, closeBrowserSessions: { _, _ in })

        let browserTargetFailure = AppKitController.performStopAllQuitCleanup(
            liveSessions: liveSessions, parkAgentSessionsForRestore: {
                parkCount += 1
                return nil
            }, runningWorkspaces: { [] },
            workspaceForLiveSession: { _ in Self.workspaceRecord(id: "workspace-owned", isRunning: false) }, stopWorkspace: { _ in },
            terminateSession: { _ in }, listLiveSessions: { liveSessions },
            browserSessionTargetURLs: { _ in throw NSError(domain: "BrowserTargets", code: 1) }, closeBrowserSessions: { _, _ in })

        #expect(mappingFailure.preparationError != nil)
        #expect(browserTargetFailure.preparationError != nil)
        #expect(parkCount == 0)
    }

    @Test func stopAllQuitForceChoiceRawTerminatesRemainingSessionsAndAllowsTermination() {
        let result = Self.cleanupResult(workspaceIDs: ["workspace-a"], remainingSessionIDs: ["session-a", "session-b"])
        var terminatedSessionIDs: [String] = []
        var browserCleanupWorkspaceIDs: [String] = []
        var browserCleanupTargetURLs: [String] = []

        let reply = AppKitController.stopAllQuitFailureTerminateReply(
            result: result, choice: .forceQuit, parkAgentSessionsForRestore: { nil },
            terminateSession: { sessionID in terminatedSessionIDs.append(sessionID) },
            closeBrowserSessions: { workspaceID, targetURLs in
                browserCleanupWorkspaceIDs.append(workspaceID)
                browserCleanupTargetURLs = targetURLs
            }, reconcileParkedAgentSessions: { _ in })

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
            result: result, choice: .cancelQuit, parkAgentSessionsForRestore: { nil },
            terminateSession: { sessionID in terminatedSessionIDs.append(sessionID) },
            closeBrowserSessions: { workspaceID, _ in browserCleanupWorkspaceIDs.append(workspaceID) }, reconcileParkedAgentSessions: { _ in })

        #expect(reply == .terminateCancel)
        #expect(terminatedSessionIDs.isEmpty)
        #expect(browserCleanupWorkspaceIDs.isEmpty)
    }

    /// A quit the user cancels asks the daemon to reconcile the record the park wrote, by name. The quit
    /// can have stopped workspaces before it was cancelled, so which parked agents are still worth offering
    /// is a question about what is live, which only the daemon can answer.
    @Test func canceledQuitReconcilesTheRecordItParked() {
        let result = Self.cleanupResult(workspaceIDs: ["workspace-a"], remainingSessionIDs: ["session-a"], parkedRestoreGeneration: "generation-1")
        var reconciledGenerations: [String] = []

        let reply = AppKitController.stopAllQuitFailureTerminateReply(
            result: result, choice: .cancelQuit, parkAgentSessionsForRestore: { nil }, terminateSession: { _ in }, closeBrowserSessions: { _, _ in },
            reconcileParkedAgentSessions: { generation in reconciledGenerations.append(generation) })

        #expect(reply == .terminateCancel)
        #expect(reconciledGenerations == ["generation-1"])
    }

    /// A force quit that cannot stop everything keeps the app open too, so its parked record is reconciled
    /// as well. A force quit that does stop everything keeps the record whole: those agents are ending with
    /// the quit, and every one of them is worth offering back.
    @Test func forceQuitReconcilesTheParkedRecordOnlyWhenTheAppStaysOpen() {
        let stuck = Self.cleanupResult(workspaceIDs: ["workspace-a"], remainingSessionIDs: ["session-a"], parkedRestoreGeneration: "generation-1")
        var reconciledAfterFailedForce: [String] = []
        let failedForce = AppKitController.stopAllQuitFailureTerminateReply(
            result: stuck, choice: .forceQuit, parkAgentSessionsForRestore: { nil },
            terminateSession: { _ in throw NSError(domain: "Terminate", code: 1) },
            closeBrowserSessions: { _, _ in }, reconcileParkedAgentSessions: { generation in reconciledAfterFailedForce.append(generation) })

        var reconciledAfterForce: [String] = []
        let force = AppKitController.stopAllQuitFailureTerminateReply(
            result: stuck, choice: .forceQuit, parkAgentSessionsForRestore: { nil }, terminateSession: { _ in }, closeBrowserSessions: { _, _ in },
            reconcileParkedAgentSessions: { generation in reconciledAfterForce.append(generation) })

        #expect(failedForce == .terminateCancel)
        #expect(reconciledAfterFailedForce == ["generation-1"])
        #expect(force == .terminateNow)
        #expect(reconciledAfterForce.isEmpty)
    }

    /// Cleanup can fail before it parks anything (workspace inspection or browser-target preparation), and
    /// a force quit from there terminates every remaining session, which the daemon reads as a deliberate
    /// end. The park therefore happens on that path too, before the first termination, or a quit from a
    /// half-failed cleanup would silently lose every agent.
    @Test func forceQuitAfterAPreparationFailureParksBeforeItTerminates() {
        let result = Self.cleanupResult(
            workspaceIDs: ["workspace-a"], remainingSessionIDs: ["session-a"], preparationError: NSError(domain: "Preparation", code: 1))
        var events: [String] = []

        let reply = AppKitController.stopAllQuitFailureTerminateReply(
            result: result, choice: .forceQuit,
            parkAgentSessionsForRestore: {
                events.append("park")
                return "generation-forced"
            }, terminateSession: { sessionID in events.append("terminate:\(sessionID)") }, closeBrowserSessions: { _, _ in },
            reconcileParkedAgentSessions: { _ in })

        #expect(reply == .terminateNow)
        #expect(events == ["park", "terminate:session-a"])
    }

    /// The same failed cleanup answered with Cancel Quit parks nothing: the app stays open with its agents
    /// running, so there is nothing to offer back.
    @Test func cancelQuitAfterAPreparationFailureParksNothing() {
        let result = Self.cleanupResult(
            workspaceIDs: ["workspace-a"], remainingSessionIDs: ["session-a"], preparationError: NSError(domain: "Preparation", code: 1))
        var parkCalls = 0
        var reconciledGenerations: [String] = []

        let reply = AppKitController.stopAllQuitFailureTerminateReply(
            result: result, choice: .cancelQuit,
            parkAgentSessionsForRestore: {
                parkCalls += 1
                return "generation-forced"
            }, terminateSession: { _ in }, closeBrowserSessions: { _, _ in },
            reconcileParkedAgentSessions: { generation in reconciledGenerations.append(generation) })

        #expect(reply == .terminateCancel)
        #expect(parkCalls == 0)
        #expect(reconciledGenerations.isEmpty)
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

    private static func cleanupResult(
        workspaceIDs: [String], remainingSessionIDs: [String], parkedRestoreGeneration: String? = nil, preparationError: (any Error)? = nil
    ) -> AppKitController.StopAllQuitCleanupResult {
        AppKitController.StopAllQuitCleanupResult(
            workspaceIDs: workspaceIDs, stoppedWorkspaceIDs: [], associatedLiveSessionIDs: [],
            browserSessionTargetURLsByWorkspaceID: Dictionary(uniqueKeysWithValues: workspaceIDs.map { ($0, ["http://127.0.0.1:3000"]) }),
            stopFailures: [], rawTerminatedSessionIDs: [], rawTerminationFailures: [], remainingSessionIDs: remainingSessionIDs,
            preparationError: preparationError, parkedRestoreGeneration: parkedRestoreGeneration)
    }
}
