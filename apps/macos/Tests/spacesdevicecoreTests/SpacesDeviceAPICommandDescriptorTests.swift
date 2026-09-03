import Foundation
import Testing

@testable import spacesdevicecore

/// Pins `SpacesDeviceAPICommandDescriptor`'s `lane`/`timeoutSeconds` fields against a per-case table
/// written out by hand:
///
///  - `lane` names, command by command, which serial queue the device-API server answers that command on.
///    Which queue a command takes is a behavioral decision (it decides what a stalled command can hold up),
///    so it is spelled out here independently rather than read back from the descriptor's own switch,
///    and moving a command between lanes has to be done deliberately in both places. The `.agentHook`
///    lane's two commands (`.agentHooksStatus`, `.installAgentHooks`) are the same grouping a caller
///    checks with `lane == .agentHook`; the descriptor carries no separate agent-hook flag.
///  - `timeoutSeconds` mirrors the four timeout groupings `SpacesDeviceClient`'s `requestTimeoutSeconds`
///    switch used to compute directly, deleted from that file in the same change that added the descriptor.
///
/// `expectedLane`/`expectedTimeoutSeconds` below are independent copies of those groupings, not reads of
/// `SpacesDeviceAPICommandDescriptor`'s own switch, so a descriptor case that silently drifted fails here
/// even though the descriptor's own exhaustiveness check would not catch it. Samples come from
/// `SpacesDeviceAPICommandWireKeyTests.samples` (one instance per case) so this suite exercises the
/// identical 74 commands that file's wire-key assertions do, rather than a second hand-built payload table
/// that could drift out of sync with that one.
@Suite struct SpacesDeviceAPICommandDescriptorTests {
    @Test func descriptorLaneMatchesTheIntendedPerCommandGrouping() {
        for command in SpacesDeviceAPICommandWireKeyTests.samples {
            #expect(
                command.descriptor.lane == Self.expectedLane(for: command),
                "\(command.descriptor.wireKey): descriptor.lane did not match the lane this command is meant to answer on")
        }
    }

    @Test func descriptorTimeoutSecondsMatchesPreMigrationClientSwitch() {
        for command in SpacesDeviceAPICommandWireKeyTests.samples {
            #expect(
                command.descriptor.timeoutSeconds == Self.expectedTimeoutSeconds(for: command),
                "\(command.descriptor.wireKey): descriptor.timeoutSeconds did not match the pre-migration client switch")
        }
    }

    /// Every command that answers off a queue of its own, listed by the lane it takes. The groups do not
    /// overlap, so arm order does not matter; everything else answers inline on the shared state queue
    /// (`.mainQueue`), including `.ping`, which both transports answer off every queue before the lane is
    /// ever consulted.
    private static func expectedLane(for command: SpacesDeviceAPICommand) -> SpacesDeviceAPICommandLane {
        switch command {
        case .agentHooksStatus, .installAgentHooks: .agentHook
        case .archiveWorkspace, .deleteProject: .workspaceTeardown
        case .stopWorkspace: .workspaceStop
        case .runWorkspaceSetup: .workspaceSetup
        case .startWorkspaceCommandSession: .workspaceTerminalLaunch
        case .createWorkspace: .workspaceCreate
        case .createProject, .previewGitProject: .projectClone
        case .importProject, .exportProject: .projectConfigFile
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
