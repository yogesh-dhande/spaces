import Foundation
import Testing

@testable import spacesdevicecore

/// Pins `SpacesDeviceAPICommandDescriptor`'s `lane`/`timeoutSeconds` fields against the exact per-case
/// values the code they replaced produced, before this repo introduced a single descriptor switch:
///
///  - `lane` mirrors the per-lane command groupings `SpacesDeviceAPIServer` used to compute with a set of
///    `fileprivate` predicates (one per lane, plus an agent-hook predicate) and a priority if-chain built
///    from them, all deleted from that file in the same change that added the descriptor. The old
///    agent-hook predicate's two commands (`.agentHooksStatus`, `.installAgentHooks`) are exactly the
///    `.agentHook` lane's commands, so the lane assertion below covers that grouping too; the descriptor
///    has no separate agent-hook flag for a caller to check `lane == .agentHook` instead.
///  - `timeoutSeconds` mirrors the four timeout groupings `SpacesDeviceClient`'s `requestTimeoutSeconds`
///    switch used to compute directly, deleted from that file in the same change.
///
/// `expectedLane`/`expectedTimeoutSeconds` below are copies of those old groupings, not reads of
/// `SpacesDeviceAPICommandDescriptor`'s own switch, so a descriptor case that silently drifted from the
/// pre-migration behavior fails here even though the descriptor's own exhaustiveness check would not catch
/// it. Samples come from `SpacesDeviceAPICommandWireKeyTests.samples` (one instance per case) so this suite
/// exercises the identical 74 commands that file's wire-key assertions do, rather than a second hand-built
/// payload table that could drift out of sync with that one.
@Suite struct SpacesDeviceAPICommandDescriptorTests {
    @Test func descriptorLaneMatchesPreMigrationServerPredicates() {
        for command in SpacesDeviceAPICommandWireKeyTests.samples {
            #expect(
                command.descriptor.lane == Self.expectedLane(for: command),
                "\(command.descriptor.wireKey): descriptor.lane did not match the pre-migration server predicate")
        }
    }

    @Test func descriptorTimeoutSecondsMatchesPreMigrationClientSwitch() {
        for command in SpacesDeviceAPICommandWireKeyTests.samples {
            #expect(
                command.descriptor.timeoutSeconds == Self.expectedTimeoutSeconds(for: command),
                "\(command.descriptor.wireKey): descriptor.timeoutSeconds did not match the pre-migration client switch")
        }
    }

    /// Copy of the old agentHook → workspaceTeardown → workspaceStop → workspaceSetup →
    /// workspaceTerminalLaunch → terminalControl → workspaceGit → `.mainQueue` priority if-chain
    /// `SpacesDeviceAPIServer` used to compute a command's lane from, with the exact same per-case
    /// membership each predicate in that chain had. None of the groups below overlap (each case appeared in
    /// at most one predicate in the original chain), so priority order between the `case` arms does not
    /// matter for any of these 74 samples; `.ping` falls through every predicate exactly as it did before,
    /// landing on `.mainQueue` even though the server special-cases `.ping` before ever consulting the lane.
    private static func expectedLane(for command: SpacesDeviceAPICommand) -> SpacesDeviceAPICommandLane {
        switch command {
        case .agentHooksStatus, .installAgentHooks: .agentHook
        case .archiveWorkspace, .deleteProject: .workspaceTeardown
        case .stopWorkspace: .workspaceStop
        case .runWorkspaceSetup: .workspaceSetup
        case .startWorkspaceCommandSession: .workspaceTerminalLaunch
        case .terminalControl, .terminalPasteImage, .sendTerminalInput, .state, .workspaceReviewCommentUpsert, .workspaceReviewCommentDelete,
            .workspaceReviewCommentsSend:
            .terminalControl
        case .workspaceFileRead, .workspaceRevisionFileRead, .workspaceFileWrite, .workspaceDiffManifestChunk, .workspaceDiffManifestRelease,
            .workspaceDiffFileChunk, .workspaceFileList, .workspaceRefList:
            .workspaceGit
        default: .mainQueue
        }
    }

    /// Copy of the old `SpacesDeviceClient.requestTimeoutSeconds` switch's four groups, with the same
    /// per-case membership, expressed as the literal second values `SpacesDeviceClient`'s named constants
    /// held at the time this test was written (`defaultRequestTimeoutSeconds` = 10,
    /// `agentHooksStatusRequestTimeoutSeconds` = 20, `longRunningMutationTimeoutSeconds` = 60,
    /// `largePayloadRequestTimeoutSeconds` = 60) rather than a reference to those constants, so this test
    /// does not depend on `spacesclientcore` (which `spacesdevicecoreTests` does not, and should not, link
    /// against).
    private static func expectedTimeoutSeconds(for command: SpacesDeviceAPICommand) -> TimeInterval {
        switch command {
        case .createProject, .previewGitProject, .deleteProject, .importProject, .exportProject, .createWorkspace, .launchWorkspace, .stopWorkspace,
            .restartWorkspace, .archiveWorkspace, .runWorkspaceSetup, .openWorkspaceTerminal, .startWorkspaceCommandSession, .stopWorkspaceTerminal,
            .stopWorkspaceTerminalIfBareShell, .runWorkspaceProcess, .stopWorkspaceProcess, .restartWorkspaceProcess, .stopCodingAgent,
            .installAgentHooks, .spawnAgentSession, .killAgentSession, .createAutomation, .updateAutomation, .setAutomationNextRun, .deleteAutomation,
            .triggerAutomation, .cancelAutomationRun, .endAutomationAgents:
            60
        case .agentHooksStatus: 20
        case .terminalTranscript, .workspaceFileRead, .workspaceRevisionFileRead, .workspaceFileWrite, .workspaceDiffManifestChunk,
            .workspaceDiffManifestRelease, .workspaceDiffFileChunk, .workspaceFileList, .workspaceRefList:
            60
        case .pair, .ping, .daemonStatus, .requestDaemonRestart, .overview, .previewProject, .listDirectories, .workspaceCreateOptions,
            .updateProjectConfig, .updateProjectMetadata, .updateWorkspaceConfig, .updateWorkspaceMetadata, .renameTerminalSession,
            .renameAgentSession, .state, .terminalControl, .terminalPasteImage, .sendTerminalInput, .tailTerminalOutput, .resolveTerminalLink,
            .readTerminalLinkChunk, .subscribe, .subscribeDeviceOverview, .subscribeWorkspaceDiffSignature, .subscribeWorkspaceFileSignature,
            .subscribeWorkspaceFileListSignature, .openServiceTunnel, .listAgentSessions, .annotateAgentSession, .listAutomations,
            .listAutomationRuns, .workspaceReviewCommentList, .workspaceReviewCommentUpsert, .workspaceReviewCommentDelete,
            .workspaceReviewCommentsSend:
            10
        }
    }
}
