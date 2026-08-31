import Foundation

/// The serial lane a `SpacesDeviceAPICommand` dispatches to inside `SpacesDeviceAPIServer`. One case per
/// queue choice the two transports' dispatch ladders make. `.terminalControl` and `.workspaceGit` name a
/// lane whose actual queue is resolved per request — a per-session control lane
/// (`TerminalControlLaneRegistry`) and a per-workspace queue (`workspaceGitQueue(for:)`) — rather than one
/// fixed instance, so `SpacesDeviceAPIServer.queue(for:)` does not cover them; each transport keeps that
/// resolution explicit at its own call site. `.mainQueue` means "no divert": the command runs inline on
/// whichever queue is already dispatching it (the shared `spaces.device.api` state queue for both
/// transports).
///
/// Lives in `spacesdevicecore` (not `spacesdeviceapi`) so it can sit on `SpacesDeviceAPICommandDescriptor`
/// alongside the command's other cross-platform metadata; `spacesdeviceapi` owns everything about how a
/// lane actually executes (the fixed `DispatchQueue` table, the per-session/per-workspace dynamic
/// resolvers, the dispatch helpers).
public enum SpacesDeviceAPICommandLane: Sendable, Equatable {
    case agentHook
    case workspaceTeardown
    case workspaceStop
    case workspaceSetup
    case workspaceTerminalLaunch
    case terminalControl
    case workspaceGit
    case mainQueue
}

/// Per-command metadata pinned once per `SpacesDeviceAPICommand` case and read by every consumer that
/// used to derive it independently (the device-API server's lane router, the client's request-timeout
/// table). Kept as plain values with no `Dispatch`/server imports so this type stays usable from every
/// platform `spacesdevicecore` compiles for, including Linux and iOS.
public struct SpacesDeviceAPICommandDescriptor: Sendable, Equatable {
    /// The single JSON key this command encodes to and decodes from (see
    /// `SpacesDeviceAPICommand.CodingKeys`). Populated with the auto-derived raw string for each case
    /// (the case name); `init(from:)`/`encode(to:)` are unchanged by this descriptor.
    public let wireKey: String
    /// Which serial lane the device-API server routes this command's handling to. The two agent-hook
    /// commands (`.agentHooksStatus`, `.installAgentHooks`) are exactly the `.agentHook` lane; a
    /// caller that needs to gate on "is this an agent-hook command" checks `lane == .agentHook` rather
    /// than a separate flag.
    public let lane: SpacesDeviceAPICommandLane
    /// The deadline `SpacesDeviceClient` uses when sending this command.
    public let timeoutSeconds: TimeInterval
}

extension SpacesDeviceAPICommand {
    /// Long-running mutations (workspace/project lifecycle, agent sessions, automations): the deadline
    /// has to cover real work, not just a database round trip.
    private static let longRunningMutationTimeoutSeconds: TimeInterval = 60
    /// `.agentHooksStatus` probes every configured coding agent's shell/config state, which can take
    /// longer than the default deadline but far less than a long-running mutation.
    private static let agentHooksStatusRequestTimeoutSeconds: TimeInterval = 20
    /// A response carrying a large embedded payload — a transcript up to the full scrollback budget,
    /// a workspace file read/write, or one bounded workspace-diff patch range — needs more than the
    /// default timeout on slow remote links.
    private static let largePayloadRequestTimeoutSeconds: TimeInterval = 60
    /// Everything else: reads and small, fast mutations.
    private static let defaultRequestTimeoutSeconds: TimeInterval = 10

    /// The per-command metadata every consumer of `SpacesDeviceAPICommand` used to derive independently.
    /// One exhaustive, default-less switch so a new case fails to compile here until it is given a
    /// lane, timeout, and wire key — the same completeness guarantee the golden wire-key test's
    /// `goldenWireKey` switch gives the coding round trip.
    public var descriptor: SpacesDeviceAPICommandDescriptor {
        switch self {
        case .pair: return Self.descriptor(wireKey: "pair", lane: .mainQueue, timeoutSeconds: Self.defaultRequestTimeoutSeconds)
        case .ping:
            // `.ping` never reaches the lane switch: both transports answer it inline, off every queue,
            // before either dispatch ladder is consulted (see `SpacesDeviceAPIServer.isPingCommand`).
            // `.mainQueue` mirrors what the old `lane` if-chain would have computed for it, since none of
            // its predicates match `.ping`, even though that value is never actually read.
            return Self.descriptor(wireKey: "ping", lane: .mainQueue, timeoutSeconds: Self.defaultRequestTimeoutSeconds)
        case .daemonStatus: return Self.descriptor(wireKey: "daemonStatus", lane: .mainQueue, timeoutSeconds: Self.defaultRequestTimeoutSeconds)
        case .requestDaemonRestart:
            return Self.descriptor(wireKey: "requestDaemonRestart", lane: .mainQueue, timeoutSeconds: Self.defaultRequestTimeoutSeconds)
        case .overview: return Self.descriptor(wireKey: "overview", lane: .mainQueue, timeoutSeconds: Self.defaultRequestTimeoutSeconds)
        case .createProject:
            return Self.descriptor(wireKey: "createProject", lane: .mainQueue, timeoutSeconds: Self.longRunningMutationTimeoutSeconds)
        case .previewProject: return Self.descriptor(wireKey: "previewProject", lane: .mainQueue, timeoutSeconds: Self.defaultRequestTimeoutSeconds)
        case .previewGitProject:
            return Self.descriptor(wireKey: "previewGitProject", lane: .mainQueue, timeoutSeconds: Self.longRunningMutationTimeoutSeconds)
        case .deleteProject:
            return Self.descriptor(wireKey: "deleteProject", lane: .workspaceTeardown, timeoutSeconds: Self.longRunningMutationTimeoutSeconds)
        case .importProject:
            return Self.descriptor(wireKey: "importProject", lane: .mainQueue, timeoutSeconds: Self.longRunningMutationTimeoutSeconds)
        case .exportProject:
            return Self.descriptor(wireKey: "exportProject", lane: .mainQueue, timeoutSeconds: Self.longRunningMutationTimeoutSeconds)
        case .listDirectories: return Self.descriptor(wireKey: "listDirectories", lane: .mainQueue, timeoutSeconds: Self.defaultRequestTimeoutSeconds)
        case .updateProjectConfig:
            return Self.descriptor(wireKey: "updateProjectConfig", lane: .mainQueue, timeoutSeconds: Self.defaultRequestTimeoutSeconds)
        case .updateProjectMetadata:
            return Self.descriptor(wireKey: "updateProjectMetadata", lane: .mainQueue, timeoutSeconds: Self.defaultRequestTimeoutSeconds)
        case .workspaceCreateOptions:
            return Self.descriptor(wireKey: "workspaceCreateOptions", lane: .mainQueue, timeoutSeconds: Self.defaultRequestTimeoutSeconds)
        case .createWorkspace:
            return Self.descriptor(wireKey: "createWorkspace", lane: .mainQueue, timeoutSeconds: Self.longRunningMutationTimeoutSeconds)
        case .launchWorkspace:
            return Self.descriptor(wireKey: "launchWorkspace", lane: .mainQueue, timeoutSeconds: Self.longRunningMutationTimeoutSeconds)
        case .stopWorkspace:
            return Self.descriptor(wireKey: "stopWorkspace", lane: .workspaceStop, timeoutSeconds: Self.longRunningMutationTimeoutSeconds)
        case .restartWorkspace:
            return Self.descriptor(wireKey: "restartWorkspace", lane: .mainQueue, timeoutSeconds: Self.longRunningMutationTimeoutSeconds)
        case .archiveWorkspace:
            return Self.descriptor(wireKey: "archiveWorkspace", lane: .workspaceTeardown, timeoutSeconds: Self.longRunningMutationTimeoutSeconds)
        case .runWorkspaceSetup:
            return Self.descriptor(wireKey: "runWorkspaceSetup", lane: .workspaceSetup, timeoutSeconds: Self.longRunningMutationTimeoutSeconds)
        case .updateWorkspaceConfig:
            return Self.descriptor(wireKey: "updateWorkspaceConfig", lane: .mainQueue, timeoutSeconds: Self.defaultRequestTimeoutSeconds)
        case .updateWorkspaceMetadata:
            return Self.descriptor(wireKey: "updateWorkspaceMetadata", lane: .mainQueue, timeoutSeconds: Self.defaultRequestTimeoutSeconds)
        case .openWorkspaceTerminal:
            return Self.descriptor(wireKey: "openWorkspaceTerminal", lane: .mainQueue, timeoutSeconds: Self.longRunningMutationTimeoutSeconds)
        case .startWorkspaceCommandSession:
            return Self.descriptor(
                wireKey: "startWorkspaceCommandSession", lane: .workspaceTerminalLaunch, timeoutSeconds: Self.longRunningMutationTimeoutSeconds)
        case .renameTerminalSession:
            return Self.descriptor(wireKey: "renameTerminalSession", lane: .mainQueue, timeoutSeconds: Self.defaultRequestTimeoutSeconds)
        case .stopWorkspaceTerminal:
            return Self.descriptor(wireKey: "stopWorkspaceTerminal", lane: .mainQueue, timeoutSeconds: Self.longRunningMutationTimeoutSeconds)
        case .stopWorkspaceTerminalIfBareShell:
            return Self.descriptor(
                wireKey: "stopWorkspaceTerminalIfBareShell", lane: .mainQueue, timeoutSeconds: Self.longRunningMutationTimeoutSeconds)
        case .runWorkspaceProcess:
            return Self.descriptor(wireKey: "runWorkspaceProcess", lane: .mainQueue, timeoutSeconds: Self.longRunningMutationTimeoutSeconds)
        case .stopWorkspaceProcess:
            return Self.descriptor(wireKey: "stopWorkspaceProcess", lane: .mainQueue, timeoutSeconds: Self.longRunningMutationTimeoutSeconds)
        case .restartWorkspaceProcess:
            return Self.descriptor(wireKey: "restartWorkspaceProcess", lane: .mainQueue, timeoutSeconds: Self.longRunningMutationTimeoutSeconds)
        case .stopCodingAgent:
            return Self.descriptor(wireKey: "stopCodingAgent", lane: .mainQueue, timeoutSeconds: Self.longRunningMutationTimeoutSeconds)
        case .renameAgentSession:
            return Self.descriptor(wireKey: "renameAgentSession", lane: .mainQueue, timeoutSeconds: Self.defaultRequestTimeoutSeconds)
        case .agentHooksStatus:
            return Self.descriptor(wireKey: "agentHooksStatus", lane: .agentHook, timeoutSeconds: Self.agentHooksStatusRequestTimeoutSeconds)
        case .installAgentHooks:
            return Self.descriptor(wireKey: "installAgentHooks", lane: .agentHook, timeoutSeconds: Self.longRunningMutationTimeoutSeconds)
        case .spawnAgentSession:
            return Self.descriptor(wireKey: "spawnAgentSession", lane: .mainQueue, timeoutSeconds: Self.longRunningMutationTimeoutSeconds)
        case .killAgentSession:
            return Self.descriptor(wireKey: "killAgentSession", lane: .mainQueue, timeoutSeconds: Self.longRunningMutationTimeoutSeconds)
        case .listAgentSessions:
            return Self.descriptor(wireKey: "listAgentSessions", lane: .mainQueue, timeoutSeconds: Self.defaultRequestTimeoutSeconds)
        case .annotateAgentSession:
            return Self.descriptor(wireKey: "annotateAgentSession", lane: .mainQueue, timeoutSeconds: Self.defaultRequestTimeoutSeconds)
        case .state: return Self.descriptor(wireKey: "state", lane: .terminalControl, timeoutSeconds: Self.defaultRequestTimeoutSeconds)
        case .terminalControl:
            return Self.descriptor(wireKey: "terminalControl", lane: .terminalControl, timeoutSeconds: Self.defaultRequestTimeoutSeconds)
        case .terminalPasteImage:
            return Self.descriptor(wireKey: "terminalPasteImage", lane: .terminalControl, timeoutSeconds: Self.defaultRequestTimeoutSeconds)
        case .sendTerminalInput:
            return Self.descriptor(wireKey: "sendTerminalInput", lane: .terminalControl, timeoutSeconds: Self.defaultRequestTimeoutSeconds)
        case .tailTerminalOutput:
            return Self.descriptor(wireKey: "tailTerminalOutput", lane: .mainQueue, timeoutSeconds: Self.defaultRequestTimeoutSeconds)
        case .terminalTranscript:
            return Self.descriptor(wireKey: "terminalTranscript", lane: .mainQueue, timeoutSeconds: Self.largePayloadRequestTimeoutSeconds)
        case .resolveTerminalLink:
            return Self.descriptor(wireKey: "resolveTerminalLink", lane: .mainQueue, timeoutSeconds: Self.defaultRequestTimeoutSeconds)
        case .readTerminalLinkChunk:
            return Self.descriptor(wireKey: "readTerminalLinkChunk", lane: .mainQueue, timeoutSeconds: Self.defaultRequestTimeoutSeconds)
        case .subscribe: return Self.descriptor(wireKey: "subscribe", lane: .mainQueue, timeoutSeconds: Self.defaultRequestTimeoutSeconds)
        case .subscribeDeviceOverview:
            return Self.descriptor(wireKey: "subscribeDeviceOverview", lane: .mainQueue, timeoutSeconds: Self.defaultRequestTimeoutSeconds)
        case .subscribeWorkspaceDiffSignature:
            return Self.descriptor(wireKey: "subscribeWorkspaceDiffSignature", lane: .mainQueue, timeoutSeconds: Self.defaultRequestTimeoutSeconds)
        case .subscribeWorkspaceFileSignature:
            return Self.descriptor(wireKey: "subscribeWorkspaceFileSignature", lane: .mainQueue, timeoutSeconds: Self.defaultRequestTimeoutSeconds)
        case .subscribeWorkspaceFileListSignature:
            return Self.descriptor(
                wireKey: "subscribeWorkspaceFileListSignature", lane: .mainQueue, timeoutSeconds: Self.defaultRequestTimeoutSeconds)
        case .workspaceFileRead:
            return Self.descriptor(wireKey: "workspaceFileRead", lane: .workspaceGit, timeoutSeconds: Self.largePayloadRequestTimeoutSeconds)
        case .workspaceRevisionFileRead:
            return Self.descriptor(wireKey: "workspaceRevisionFileRead", lane: .workspaceGit, timeoutSeconds: Self.largePayloadRequestTimeoutSeconds)
        case .workspaceFileWrite:
            return Self.descriptor(wireKey: "workspaceFileWrite", lane: .workspaceGit, timeoutSeconds: Self.largePayloadRequestTimeoutSeconds)
        case .workspaceDiffManifestChunk:
            return Self.descriptor(wireKey: "workspaceDiffManifestChunk", lane: .workspaceGit, timeoutSeconds: Self.largePayloadRequestTimeoutSeconds)
        case .workspaceDiffManifestRelease:
            return Self.descriptor(
                wireKey: "workspaceDiffManifestRelease", lane: .workspaceGit, timeoutSeconds: Self.largePayloadRequestTimeoutSeconds)
        case .workspaceDiffFileChunk:
            return Self.descriptor(wireKey: "workspaceDiffFileChunk", lane: .workspaceGit, timeoutSeconds: Self.largePayloadRequestTimeoutSeconds)
        case .workspaceFileList:
            return Self.descriptor(wireKey: "workspaceFileList", lane: .workspaceGit, timeoutSeconds: Self.largePayloadRequestTimeoutSeconds)
        case .workspaceRefList:
            return Self.descriptor(wireKey: "workspaceRefList", lane: .workspaceGit, timeoutSeconds: Self.largePayloadRequestTimeoutSeconds)
        case .openServiceTunnel:
            return Self.descriptor(wireKey: "openServiceTunnel", lane: .mainQueue, timeoutSeconds: Self.defaultRequestTimeoutSeconds)
        case .createAutomation:
            return Self.descriptor(wireKey: "createAutomation", lane: .mainQueue, timeoutSeconds: Self.longRunningMutationTimeoutSeconds)
        case .updateAutomation:
            return Self.descriptor(wireKey: "updateAutomation", lane: .mainQueue, timeoutSeconds: Self.longRunningMutationTimeoutSeconds)
        case .setAutomationNextRun:
            return Self.descriptor(wireKey: "setAutomationNextRun", lane: .mainQueue, timeoutSeconds: Self.longRunningMutationTimeoutSeconds)
        case .deleteAutomation:
            return Self.descriptor(wireKey: "deleteAutomation", lane: .mainQueue, timeoutSeconds: Self.longRunningMutationTimeoutSeconds)
        case .listAutomations: return Self.descriptor(wireKey: "listAutomations", lane: .mainQueue, timeoutSeconds: Self.defaultRequestTimeoutSeconds)
        case .listAutomationRuns:
            return Self.descriptor(wireKey: "listAutomationRuns", lane: .mainQueue, timeoutSeconds: Self.defaultRequestTimeoutSeconds)
        case .triggerAutomation:
            return Self.descriptor(wireKey: "triggerAutomation", lane: .mainQueue, timeoutSeconds: Self.longRunningMutationTimeoutSeconds)
        case .cancelAutomationRun:
            return Self.descriptor(wireKey: "cancelAutomationRun", lane: .mainQueue, timeoutSeconds: Self.longRunningMutationTimeoutSeconds)
        case .endAutomationAgents:
            return Self.descriptor(wireKey: "endAutomationAgents", lane: .mainQueue, timeoutSeconds: Self.longRunningMutationTimeoutSeconds)
        case .workspaceReviewCommentList:
            return Self.descriptor(wireKey: "workspaceReviewCommentList", lane: .mainQueue, timeoutSeconds: Self.defaultRequestTimeoutSeconds)
        case .workspaceReviewCommentUpsert:
            return Self.descriptor(wireKey: "workspaceReviewCommentUpsert", lane: .terminalControl, timeoutSeconds: Self.defaultRequestTimeoutSeconds)
        case .workspaceReviewCommentDelete:
            return Self.descriptor(wireKey: "workspaceReviewCommentDelete", lane: .terminalControl, timeoutSeconds: Self.defaultRequestTimeoutSeconds)
        case .workspaceReviewCommentsSend:
            return Self.descriptor(wireKey: "workspaceReviewCommentsSend", lane: .terminalControl, timeoutSeconds: Self.defaultRequestTimeoutSeconds)
        }
    }

    private static func descriptor(wireKey: String, lane: SpacesDeviceAPICommandLane, timeoutSeconds: TimeInterval)
        -> SpacesDeviceAPICommandDescriptor
    { SpacesDeviceAPICommandDescriptor(wireKey: wireKey, lane: lane, timeoutSeconds: timeoutSeconds) }
}
