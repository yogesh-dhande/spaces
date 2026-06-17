import Foundation
import Testing
import spacesterminalcore
import workspacecore

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
        #expect(AppKitController.terminalQuitPolicy(liveTerminalSessionCount: 0) == .quitImmediately)
        #expect(AppKitController.terminalQuitPolicy(liveTerminalSessionCount: 2) == .promptForLiveSessions(count: 2))
    }

    @Test func liveBuiltInTerminalSessionsTreatsListFailureAsEmpty() {
        let sessions = AppKitController.liveBuiltInTerminalSessions { throw NSError(domain: "TerminalServiceUnavailable", code: 1) }

        #expect(sessions.isEmpty)
    }

    @Test func stopAllBuiltInTerminalSessionsTerminatesEveryListedSession() {
        let sessions = [Self.terminalSessionSummary(id: "session-a"), Self.terminalSessionSummary(id: "session-b")]
        var terminatedIDs: [String] = []

        let stoppedCount = AppKitController.stopAllBuiltInTerminalSessions(liveSessions: sessions) { sessionID in terminatedIDs.append(sessionID) }

        #expect(stoppedCount == 2)
        #expect(terminatedIDs == ["session-a", "session-b"])
    }

    @Test func adHocSessionTeardownSkipsWhenQuitKeepsSessionsRunning() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let originalDatabasePath = ProcessInfo.processInfo.environment[SpacesProfile.databasePathEnvironmentVariable]
        let databaseRoot = root.appendingPathComponent("profile", isDirectory: true)
        setenv(SpacesProfile.databasePathEnvironmentVariable, databaseRoot.appendingPathComponent("spaces.db").path, 1)
        defer {
            if let originalDatabasePath {
                setenv(SpacesProfile.databasePathEnvironmentVariable, originalDatabasePath, 1)
            } else {
                unsetenv(SpacesProfile.databasePathEnvironmentVariable)
            }
            try? FileManager.default.removeItem(at: root)
        }
        let paths = TerminalSessionPaths(rootDirectory: root.path)
        try TerminalSessionPersistence.writeLaunchConfiguration(
            TerminalSessionLaunchConfiguration(
                sessionID: "ad-hoc-lifecycle-\(UUID().uuidString)", title: "Terminal", workingDirectory: "/tmp", shell: "/bin/zsh", command: nil,
                createdAt: "2026-06-04T00:00:00Z"), paths: paths)

        #expect(
            AppKitController.shouldTerminateAdHocBuiltInTerminalSession(
                paths: paths, isConfiguredProcessSession: false, isAppTerminatingAndKeepingSessions: false))
        #expect(
            !AppKitController.shouldTerminateAdHocBuiltInTerminalSession(
                paths: paths, isConfiguredProcessSession: false, isAppTerminatingAndKeepingSessions: true))
    }

    @Test func appBuiltInTerminalLauncherUsesServiceCreateSessionPath() throws {
        let launchConfiguration = TerminalSessionLaunchConfiguration(
            sessionID: "service-session", title: "service", workingDirectory: "/tmp", shell: "/bin/zsh", command: nil,
            createdAt: "2026-05-27T00:00:00Z")
        let capturedConfiguration = LaunchConfigurationCapture()

        let launcher = AppKitController.appBuiltInTerminalSessionLauncher { configuration in
            capturedConfiguration.value = configuration
            return Self.terminalSessionSummary(
                id: configuration.sessionID, title: configuration.title, workingDirectory: configuration.workingDirectory)
        }

        let summary = try launcher(launchConfiguration)

        #expect(capturedConfiguration.value == launchConfiguration)
        #expect(summary.id == "service-session")
    }

    @Test func upgradeActiveRemoteSessionsAlertUsesSingularSessionCopy() {
        let sessions = [Self.terminalSessionSummary(id: "session-a", title: "Shell", workingDirectory: "/tmp/a")]

        #expect(AppKitController.upgradeActiveRemoteSessionsAlertTitle(activeSessionCount: 1) == "Stop Active Remote Session?")
        #expect(AppKitController.upgradeActiveRemoteSessionsActionTitle(activeSessionCount: 1) == "Stop Session and Upgrade")
        let detail = AppKitController.upgradeActiveRemoteSessionsAlertDetail(hostName: "Builder", activeSessionCount: 1, sessions: sessions)
        #expect(detail.contains("Builder has 1 active remote session."))
        #expect(detail.contains("- Shell (/tmp/a)"))
        #expect(detail.contains("Spaces can stop the session and continue upgrading, or you can cancel."))
    }

    @Test func upgradeActiveRemoteSessionsAlertUsesPluralSessionCopy() {
        let sessions = [
            Self.terminalSessionSummary(id: "session-a", title: "Shell", workingDirectory: "/tmp/a"),
            Self.terminalSessionSummary(id: "session-b", title: "Agent", workingDirectory: "/tmp/b"),
            Self.terminalSessionSummary(id: "session-c", title: "Logs", workingDirectory: "/tmp/c"),
            Self.terminalSessionSummary(id: "session-d", title: "Extra", workingDirectory: "/tmp/d"),
        ]

        #expect(AppKitController.upgradeActiveRemoteSessionsAlertTitle(activeSessionCount: 4) == "Stop Active Remote Sessions?")
        #expect(AppKitController.upgradeActiveRemoteSessionsActionTitle(activeSessionCount: 4) == "Stop Sessions and Upgrade")
        let detail = AppKitController.upgradeActiveRemoteSessionsAlertDetail(hostName: "Builder", activeSessionCount: 4, sessions: sessions)
        #expect(detail.contains("Builder has 4 active remote sessions."))
        #expect(detail.contains("- Shell (/tmp/a)"))
        #expect(detail.contains("- Agent (/tmp/b)"))
        #expect(detail.contains("- Logs (/tmp/c)"))
        #expect(detail.contains("- 1 more"))
        #expect(detail.contains("Spaces can stop these sessions and continue upgrading, or you can cancel."))
    }

    @Test func remoteHostUpgradeStopPlanTerminatesRemoteCodingAgentSession() {
        let descriptor = AppKitController.TerminalRuntimeControlDescriptor(
            kind: .codingAgent, workspaceID: "workspace-1", sessionID: "remote-agent-session", title: "Codex", processID: nil, processTemplateID: nil,
            processKey: nil, agentID: "agent-1", agentLauncherID: "launcher-codex", agentLauncherName: "Codex", canRun: false, canStop: true,
            canRestart: true)

        let plan = AppKitController.remoteHostUpgradeSessionStopPlan(sessionID: "remote-agent-session", descriptor: descriptor)

        #expect(plan.localStop == .codingAgent(workspaceID: "workspace-1", agentID: "agent-1"))
        #expect(plan.remoteSessionID == "remote-agent-session")
    }

    @Test func remoteHostUpgradeStopPlanTerminatesUntrackedRemoteSession() {
        let plan = AppKitController.remoteHostUpgradeSessionStopPlan(sessionID: "remote-shell-session", descriptor: nil)

        #expect(plan.localStop == nil)
        #expect(plan.remoteSessionID == "remote-shell-session")
    }

    @Test func currentRemoteHostUpgradeSkipsIdleRequirement() {
        let report = ComputeHostDaemonStatusReport(
            daemonVersion: "1.2.3", artifactVersion: "1.2.3", certificateFingerprint: "SHA256:abc", activeSessionCount: 4,
            savedCertificateFingerprint: "SHA256:abc", appVersion: "1.2.3")

        #expect(!AppKitController.shouldRequireRemoteHostIdleBeforeUpgrade(report: report))
    }

    @Test func availableRemoteHostUpgradeRequiresIdleCheck() {
        let report = ComputeHostDaemonStatusReport(
            daemonVersion: "1.2.2", artifactVersion: "1.2.2", certificateFingerprint: "SHA256:abc", activeSessionCount: 0,
            savedCertificateFingerprint: "SHA256:abc", appVersion: "1.2.3")

        #expect(AppKitController.shouldRequireRemoteHostIdleBeforeUpgrade(report: report))
    }

    @Test func unknownRemoteHostUpgradeRequiresIdleCheck() {
        let report = ComputeHostDaemonStatusReport(
            daemonVersion: nil, artifactVersion: nil, certificateFingerprint: "SHA256:abc", activeSessionCount: nil,
            savedCertificateFingerprint: "SHA256:abc", appVersion: "1.2.3")

        #expect(AppKitController.shouldRequireRemoteHostIdleBeforeUpgrade(report: report))
    }

    @Test func daemonExitWaitPollsUntilPinnedTLSPingFails() {
        var pingCount = 0
        var sleepIntervals: [TimeInterval] = []

        let exited = AppKitController.waitForRemoteHostDaemonExit(
            attempts: 5, pollInterval: 0.2, sleep: { sleepIntervals.append($0) },
            ping: {
                pingCount += 1
                if pingCount == 3 { throw TerminalServiceTLSError.connectionFailed("Connection refused") }
            })

        #expect(exited)
        #expect(pingCount == 3)
        #expect(sleepIntervals == [0.2, 0.2])
    }

    @Test func daemonExitWaitFailsWhenPinnedTLSPingKeepsSucceeding() {
        var pingCount = 0
        var sleepIntervals: [TimeInterval] = []

        let exited = AppKitController.waitForRemoteHostDaemonExit(
            attempts: 3, pollInterval: 0.1, sleep: { sleepIntervals.append($0) }, ping: { pingCount += 1 })

        #expect(!exited)
        #expect(pingCount == 3)
        #expect(sleepIntervals == [0.1, 0.1])
    }

    private static func terminalSessionSummary(id: String, title: String = "Terminal", workingDirectory: String = "/tmp")
        -> TerminalServiceSessionSummary
    {
        TerminalServiceSessionSummary(
            id: id, title: title, workingDirectory: workingDirectory, backend: .ghosttyEmbedded, lifetimePolicy: .persistent, state: .running,
            servicePID: 123, childPID: 456, controlSocketPath: "/tmp/\(id).sock", outputPath: "/tmp/\(id).log")
    }
}
