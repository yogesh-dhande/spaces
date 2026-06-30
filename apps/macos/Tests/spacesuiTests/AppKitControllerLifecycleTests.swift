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
        defer { try? FileManager.default.removeItem(at: root) }
        // `TerminalSessionPersistence` resolves its database through the active profile, not the passed
        // `paths`. Bind the task-local override to an isolated database so this test never touches the
        // developer profile and stays deterministic under parallel execution without mutating the process
        // environment.
        let paths = TerminalSessionPaths(rootDirectory: root.path)
        try TerminalSessionPersistence.$databasePathOverrideForTesting.withValue(root.appendingPathComponent("spaces.db").path) {
            try TerminalSessionPersistence.writeLaunchConfiguration(
                TerminalSessionLaunchConfiguration(
                    sessionID: "ad-hoc-lifecycle-\(UUID().uuidString)", title: "Terminal", workingDirectory: "/tmp", shell: "/bin/zsh", command: nil,
                    createdAt: "2026-06-04T00:00:00Z"), paths: paths)

            #expect(
                AppKitController.shouldTerminateAdHocBuiltInTerminalSession(
                    hasLiveAttachments: false, isConfiguredProcessSession: false, isAppTerminatingAndKeepingSessions: false))
            #expect(
                !AppKitController.shouldTerminateAdHocBuiltInTerminalSession(
                    hasLiveAttachments: false, isConfiguredProcessSession: false, isAppTerminatingAndKeepingSessions: true))
        }
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

    private static func terminalSessionSummary(id: String, title: String = "Terminal", workingDirectory: String = "/tmp")
        -> TerminalServiceSessionSummary
    {
        TerminalServiceSessionSummary(
            id: id, title: title, workingDirectory: workingDirectory, backend: .ghosttyEmbedded, lifetimePolicy: .persistent, state: .running,
            servicePID: 123, childPID: 456, controlSocketPath: "/tmp/\(id).sock", outputPath: "/tmp/\(id).log")
    }
}
