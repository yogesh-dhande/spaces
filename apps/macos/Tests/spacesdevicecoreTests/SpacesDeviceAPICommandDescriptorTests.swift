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
///    switch used to compute directly, deleted from that file in the same change that added the descriptor,
///    plus `.terminalTranscript`, whose deadline is derived from the request's `maxBytes` rather than
///    pinned (see `transcriptTimeoutScalesWithThePageSizeRequested`).
///
/// `expectedLane`/`expectedTimeoutSeconds` below are independent copies of those groupings, not reads of
/// `SpacesDeviceAPICommandDescriptor`'s own switch, so a descriptor case that silently drifted fails here
/// even though the descriptor's own exhaustiveness check would not catch it. Samples come from
/// `SpacesDeviceAPICommandWireKeyTests.samples` (one instance per case) so this suite exercises the
/// identical 81 commands that file's wire-key assertions do, rather than a second hand-built payload table
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

    /// The Files tree's rename/move takes the long-running mutation deadline its two sibling mutations
    /// take, and not a wait without one: its reply drives work only that reply can produce (moving the open
    /// buffer to the destination), but a peer that stops answering without closing the socket would leave a
    /// deadline-free wait blocked forever. The deadline is an unknown outcome rather than a failure, which
    /// the Editor resolves by re-reading the listing (see `CodePaneContentController`).
    @Test func theEntryMoveTakesTheLongRunningMutationDeadlineItsSiblingMutationsTake() {
        let moves = SpacesDeviceAPICommandWireKeyTests.samples.filter { command in
            if case .workspaceFileRename = command { return true }
            return false
        }
        #expect(moves.count == 1, "the wire-key samples must carry exactly one entry move for this to pin")
        for move in moves {
            #expect(
                move.descriptor.timeoutSeconds == SpacesDeviceAPICommand.longRunningMutationTimeoutSeconds,
                "the entry move must share the long-running mutation deadline create-folder and delete take on their common queue")
        }
    }

    /// A transcript read is the one command whose response size the caller picks, so its deadline has to
    /// grow with that size: a deep-history read of the whole scrollback budget on a slow remote link cannot
    /// be held to the deadline a first page needs, or the deepest history stays permanently unreachable.
    /// Pins the shape of that budget at both ends, and that both ends clear the plain default.
    @Test func transcriptTimeoutScalesWithThePageSizeRequested() {
        let firstPageSeconds = Self.transcriptTimeoutSeconds(maxBytes: 1_000_000)
        let fullBudgetSeconds = Self.transcriptTimeoutSeconds(maxBytes: 10_000_000)
        #expect(firstPageSeconds == 26, "a 1MB first page should get about half a minute")
        #expect(fullBudgetSeconds == 163, "the 10MB scrollback budget should get minutes, not the 60s a fixed large-payload deadline gave it")
        #expect(fullBudgetSeconds > 60, "the deep-history read must clear the fixed large-payload deadline it used to share")
        #expect(firstPageSeconds > 10, "even the smallest transcript page clears the default deadline")
        #expect(Self.transcriptTimeoutSeconds(maxBytes: 0) == 10, "a zero-byte read is just the fixed round-trip allowance")
    }

    /// `maxBytes` is whatever a paired client put in the request, and the server reads the command's
    /// descriptor before it validates that number, so every `Int` has to produce a deadline: a size past the
    /// deepest page the daemon serves gets that page's deadline, and a negative one the zero-byte deadline,
    /// instead of trapping the daemon on the rounding's overflow.
    @Test func transcriptTimeoutClampsAPageSizeNoDaemonWouldServe() {
        #expect(Self.transcriptTimeoutSeconds(maxBytes: .max) == Self.transcriptTimeoutSeconds(maxBytes: 10_000_000))
        #expect(Self.transcriptTimeoutSeconds(maxBytes: .min) == Self.transcriptTimeoutSeconds(maxBytes: 0))
    }

    private static func transcriptTimeoutSeconds(maxBytes: Int) -> TimeInterval {
        SpacesDeviceAPICommand.terminalTranscript(SpacesDeviceTerminalTranscriptRequest(sessionID: "session-1", maxBytes: maxBytes)).descriptor
            .timeoutSeconds
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
        case .terminalTranscript: .terminalTranscript
        case .terminalControl, .terminalPasteImage, .sendTerminalInput, .state, .workspaceReviewCommentUpsert, .workspaceReviewCommentDelete,
            .workspaceReviewCommentsSend:
            .terminalControl
        case .workspaceFileRead, .workspaceRevisionFileRead, .workspaceFileWrite, .workspaceFileCreateDirectory, .workspaceFileRename,
            .workspaceFileDelete, .workspaceDiffManifestChunk, .workspaceDiffManifestRelease, .workspaceDiffFileChunk, .workspaceFileList,
            .workspaceRefList:
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
    /// against). `.terminalTranscript` is the one case that is not in any of those groups: its response is
    /// as large as the caller asked for, so its deadline is written out here as the same 10-second
    /// allowance plus one second per 64 KiB of page the policy budgets. The Files-tree create-folder and
    /// delete that postdate that switch take the long-running mutation deadline: they share one serial
    /// per-workspace queue with the 60-second reads, writes, listings, and diff chunks, so their wait is
    /// the queue's, not their own one-entry cost. The rename/move on that same queue takes it for the same
    /// reason (see `theEntryMoveTakesTheLongRunningMutationDeadlineItsSiblingMutationsTake`).
    private static func expectedTimeoutSeconds(for command: SpacesDeviceAPICommand) -> TimeInterval {
        switch command {
        case .createProject, .previewGitProject, .deleteProject, .importProject, .exportProject, .createWorkspace, .launchWorkspace, .stopWorkspace,
            .restartWorkspace, .archiveWorkspace, .runWorkspaceSetup, .openWorkspaceTerminal, .startWorkspaceCommandSession, .stopWorkspaceTerminal,
            .stopWorkspaceTerminalIfBareShell, .runWorkspaceProcess, .stopWorkspaceProcess, .restartWorkspaceProcess, .stopCodingAgent,
            .installAgentHooks, .spawnAgentSession, .killAgentSession, .createAutomation, .updateAutomation, .setAutomationNextRun, .deleteAutomation,
            .triggerAutomation, .cancelAutomationRun, .endAutomationAgents, .restoreSessions, .discardRestorableSessions, .workspaceFileDelete,
            .workspaceFileCreateDirectory, .workspaceFileRename:
            60
        case .agentHooksStatus: 20
        // Clamped to `TerminalScrollbackBudget.defaultMaxBytes`, written out here as its literal value for
        // the same reason the timeouts above are: no page larger than the budget is ever served.
        case .terminalTranscript(let payload): TimeInterval(10 + (min(max(payload.maxBytes, 0), 10_000_000) + 65_535) / 65_536)
        case .workspaceFileRead, .workspaceRevisionFileRead, .workspaceFileWrite, .workspaceDiffManifestChunk, .workspaceDiffManifestRelease,
            .workspaceDiffFileChunk, .workspaceFileList, .workspaceRefList:
            60
        case .pair, .ping, .daemonStatus, .requestDaemonRestart, .overview, .previewProject, .listDirectories, .workspaceCreateOptions,
            .updateProjectConfig, .updateProjectMetadata, .updateWorkspaceConfig, .updateWorkspaceMetadata, .renameTerminalSession,
            .renameAgentSession, .state, .terminalControl, .terminalPasteImage, .sendTerminalInput, .tailTerminalOutput, .resolveTerminalLink,
            .readTerminalLinkChunk, .subscribe, .subscribeDeviceOverview, .subscribeWorkspaceDiffSignature, .subscribeWorkspaceFileSignature,
            .subscribeWorkspaceFileListSignature, .openServiceTunnel, .listAgentSessions, .writeAgentBrief, .readAgentBrief, .clearAgentBrief,
            .listAutomations, .listAutomationRuns, .workspaceReviewCommentList, .workspaceReviewCommentUpsert, .workspaceReviewCommentDelete,
            .workspaceReviewCommentsSend:
            10
        }
    }
}
