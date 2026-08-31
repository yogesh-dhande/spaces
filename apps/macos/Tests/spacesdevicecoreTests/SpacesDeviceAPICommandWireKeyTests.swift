import Foundation
import Testing
import spacesterminalcore

@testable import spacesdevicecore

/// Golden characterization of `SpacesDeviceAPICommand`'s wire encoding.
///
/// `SpacesDeviceAPICommand` hand-writes its own `CodingKeys`/`init(from:)`/`encode(to:)`: every case
/// carries an (auto-derived) `String` `CodingKeys` raw value equal to the case name, and the command
/// round-trips as a single-key JSON object `{"<caseName>": <payload>}` (or `{"<caseName>": {}}` for a
/// case with no associated value, via `SpacesDeviceAPIEmptyPayload`). A later stage may replace this
/// hand-written coding with one derived from a per-command descriptor table; this file pins today's byte
/// contract so that stage can prove it produced identical wire output.
///
/// `goldenWireKey` below is an exhaustive `switch` over `SpacesDeviceAPICommand` with no `default:` arm.
/// The enum's cases carry differently-typed associated values, so it cannot conform to `CaseIterable` —
/// this switch is the completeness check in its place: adding, removing, or renaming a case fails this
/// file to compile until the golden mapping (and the `samples` list below, covered by
/// `sampleListCoversEveryCurrentCase`) is updated to match. The expected strings are hand-written
/// literals, never read back out of `SpacesDeviceAPICommand`'s own `CodingKeys`/`name`, so a silent change
/// to the wire format fails this test even though it would not fail a test built from the same table the
/// production code uses.
///
/// `SpacesDeviceAPICommandDescriptor.wireKey` (in `SpacesDeviceAPICommandDescriptor.swift`) is now the
/// production descriptor table this file's stage-1 doc comment above anticipated: it is what
/// `SpacesDeviceAPICommand`'s encoding contract is actually pinned into for downstream consumers, via its
/// own default-less exhaustive switch. `everyCaseEncodesToItsGoldenWireKeyAndRoundTrips` asserts
/// `descriptor.wireKey` against the hand-written golden key for every sample, so a case whose descriptor
/// wire key drifts from the golden (hand-written, independent) one fails here even though both switches
/// individually still compile. This does not fully close completeness layer 3 below — a case missing from
/// `samples` still compiles fine, since `SpacesDeviceAPICommand` still cannot conform to `CaseIterable` and
/// so nothing enumerates "every case" independently of a hand-maintained list — but it does mean the
/// descriptor switch, not just `goldenWireKey`, is now exercised as the thing every non-test consumer
/// actually reads.
@Suite struct SpacesDeviceAPICommandWireKeyTests {
    /// One representative instance per case, in declaration order. Field values are arbitrary — this test
    /// pins the command's wire *key* and round-trip identity, not any payload type's own field encoding.
    /// Not `private`: `SpacesDeviceAPICommandDescriptorTests` reuses this same one-per-case list so its
    /// descriptor assertions run over the identical 74 commands this file's own assertions do, rather than
    /// hand-building a second payload table that could drift out of sync with this one.
    static let samples: [SpacesDeviceAPICommand] = [
        .pair(SpacesDevicePairRequest(pairingCode: "code", pairingNonce: "nonce", clientProtocolVersion: 1)), .ping, .daemonStatus,
        .requestDaemonRestart, .overview, .createProject(SpacesDeviceProjectCreateRequest(projectDir: "/tmp/project", gitURL: nil)),
        .previewGitProject(SpacesDeviceGitProjectPreviewRequest(gitURL: "https://example.com/repo.git")),
        .deleteProject(SpacesDeviceProjectReference(projectID: "project-1")),
        .importProject(SpacesDeviceProjectImportRequest(projectID: "project-1")),
        .exportProject(SpacesDeviceProjectReference(projectID: "project-1")), .previewProject(SpacesDeviceProjectPreviewRequest(dir: "/tmp/project")),
        .listDirectories(SpacesDeviceDirectoryListRequest(path: "/tmp")),
        .workspaceCreateOptions(SpacesDeviceWorkspaceCreateOptionsRequest(projectID: "project-1")),
        .createWorkspace(
            SpacesDeviceWorkspaceCreateRequest(
                projectID: "project-1", branch: "feature", baseBranch: "main", directoryName: "dir", notes: nil, allowExistingBranchReuse: false)),
        .launchWorkspace(SpacesDeviceWorkspaceLifecycleRequest(workspaceID: "workspace-1")),
        .stopWorkspace(SpacesDeviceWorkspaceLifecycleRequest(workspaceID: "workspace-1")),
        .restartWorkspace(SpacesDeviceWorkspaceLifecycleRequest(workspaceID: "workspace-1")),
        .archiveWorkspace(SpacesDeviceWorkspaceArchiveRequest(workspaceID: "workspace-1")),
        .runWorkspaceSetup(SpacesDeviceWorkspaceReference(workspaceID: "workspace-1")),
        .updateProjectConfig(SpacesDeviceProjectConfigUpdateRequest(projectID: "project-1", config: SpacesDeviceProjectConfig())),
        .updateProjectMetadata(SpacesDeviceProjectMetadataUpdateRequest(projectID: "project-1")),
        .updateWorkspaceConfig(SpacesDeviceWorkspaceConfigUpdateRequest(workspaceID: "workspace-1", config: SpacesDeviceWorkspaceConfig())),
        .updateWorkspaceMetadata(SpacesDeviceWorkspaceMetadataUpdateRequest(workspaceID: "workspace-1")),
        .openWorkspaceTerminal(SpacesDeviceWorkspaceReference(workspaceID: "workspace-1")),
        .startWorkspaceCommandSession(SpacesDeviceStartWorkspaceCommandSessionRequest(workspaceID: "workspace-1", command: "npm run dev")),
        .stopWorkspaceTerminal(SpacesDeviceWorkspaceTerminalRequest(workspaceID: "workspace-1", sessionID: "session-1")),
        .stopWorkspaceTerminalIfBareShell(SpacesDeviceWorkspaceTerminalRequest(workspaceID: "workspace-1", sessionID: "session-1")),
        .renameTerminalSession(SpacesDeviceTerminalSessionRenameRequest(workspaceID: "workspace-1", sessionID: "session-1", title: "New Title")),
        .runWorkspaceProcess(SpacesDeviceRunWorkspaceProcessRequest(workspaceID: "workspace-1", processKey: "web")),
        .stopWorkspaceProcess(SpacesDeviceWorkspaceProcessMutationRequest(workspaceID: "workspace-1", processID: "process-1")),
        .restartWorkspaceProcess(SpacesDeviceWorkspaceProcessMutationRequest(workspaceID: "workspace-1", processID: "process-1")),
        .stopCodingAgent(SpacesDeviceCodingAgentMutationRequest(workspaceID: "workspace-1", agentID: "agent-1")),
        .renameAgentSession(SpacesDeviceAgentSessionRenameRequest(workspaceID: "workspace-1", agentID: "agent-1", title: "New Title")),
        .state(SpacesDeviceTerminalSessionRequest(sessionID: "session-1")),
        .terminalControl(SpacesDeviceTerminalControlRequest(action: .attach, sessionID: "session-1")),
        .terminalPasteImage(
            SpacesDeviceTerminalPasteImageRequest(
                sessionID: "session-1", clientID: "client-1", ownerEpoch: nil, fileExtension: "png", imageData: Data([0x01, 0x02]))),
        .sendTerminalInput(SpacesDeviceTerminalInputRequest(sessionID: "session-1", text: "hello")),
        .tailTerminalOutput(SpacesDeviceTerminalTailRequest(sessionID: "session-1", lines: 100)),
        .terminalTranscript(SpacesDeviceTerminalTranscriptRequest(sessionID: "session-1", maxBytes: 1024)),
        .subscribe(SpacesDeviceTerminalSubscriptionRequest(sessionID: "session-1", clientID: "client-1")),
        .resolveTerminalLink(SpacesDeviceTerminalLinkResolveRequest(sessionID: "session-1", terminalLink: "link")),
        .readTerminalLinkChunk(SpacesDeviceTerminalLinkChunkRequest(sessionID: "session-1", terminalLinkID: "link-1", offset: 0, limit: 1024)),
        .subscribeDeviceOverview, .agentHooksStatus, .installAgentHooks(SpacesDeviceInstallAgentHooksRequest(kinds: [.claudeCode])),
        .spawnAgentSession(SpacesDeviceSpawnAgentSessionRequest(workspaceID: "workspace-1", command: "claude")),
        .listAgentSessions(SpacesDeviceListAgentSessionsRequest(workspaceID: "workspace-1")),
        .annotateAgentSession(SpacesDeviceAnnotateAgentSessionRequest(sessionID: "session-1", note: "note")),
        .killAgentSession(SpacesDeviceKillAgentSessionRequest(sessionID: "session-1")),
        .openServiceTunnel(SpacesDeviceServiceTunnelRequest(workspaceID: "workspace-1", serviceName: "web")),
        .createAutomation(Self.automationFields),
        .updateAutomation(TerminalServiceAutomationUpdatePayload(id: "automation-1", fields: Self.automationFields)),
        .setAutomationNextRun(TerminalServiceAutomationNextRunPayload(id: "automation-1", nextRunTime: "2026-01-01T00:00:00Z")),
        .deleteAutomation(SpacesDeviceAutomationReference(id: "automation-1")), .listAutomations,
        .listAutomationRuns(TerminalServiceAutomationRunsListPayload(automationID: "automation-1")),
        .triggerAutomation(SpacesDeviceAutomationReference(id: "automation-1")),
        .cancelAutomationRun(SpacesDeviceAutomationRunReference(runID: "run-1")),
        .endAutomationAgents(SpacesDeviceAutomationRunReference(runID: "run-1")),
        .workspaceFileRead(SpacesDeviceWorkspaceFileReadRequest(workspaceID: "workspace-1", relativePath: "README.md")),
        .workspaceRevisionFileRead(
            SpacesDeviceWorkspaceRevisionFileReadRequest(workspaceID: "workspace-1", revision: "HEAD", relativePath: "README.md")),
        .workspaceFileWrite(SpacesDeviceWorkspaceFileWriteRequest(workspaceID: "workspace-1", relativePath: "README.md", base64Data: "aGVsbG8=")),
        .workspaceFileList(SpacesDeviceWorkspaceFileListRequest(workspaceID: "workspace-1")),
        .workspaceRefList(SpacesDeviceWorkspaceRefListRequest(workspaceID: "workspace-1")),
        .workspaceDiffManifestChunk(SpacesDeviceWorkspaceDiffManifestChunkRequest(workspaceID: "workspace-1", fileIndex: 0)),
        .workspaceDiffManifestRelease(SpacesDeviceWorkspaceDiffManifestReleaseRequest(workspaceID: "workspace-1", manifestID: "manifest-1")),
        .workspaceDiffFileChunk(
            SpacesDeviceWorkspaceDiffFileChunkRequest(workspaceID: "workspace-1", manifestID: "manifest-1", relativePath: "README.md", byteOffset: 0)),
        .subscribeWorkspaceDiffSignature(SpacesDeviceWorkspaceDiffRequest(workspaceID: "workspace-1")),
        .subscribeWorkspaceFileSignature(SpacesDeviceWorkspaceFileSignatureRequest(workspaceID: "workspace-1", path: "README.md")),
        .subscribeWorkspaceFileListSignature(SpacesDeviceWorkspaceFileListSignatureRequest(workspaceID: "workspace-1")),
        .workspaceReviewCommentList(SpacesDeviceWorkspaceReviewCommentListRequest(workspaceID: "workspace-1")),
        .workspaceReviewCommentUpsert(
            SpacesDeviceWorkspaceReviewCommentUpsertRequest(
                workspaceID: "workspace-1", filePath: "README.md", side: .new, lineNumber: 1, lineText: "line", body: "comment")),
        .workspaceReviewCommentDelete(SpacesDeviceWorkspaceReviewCommentDeleteRequest(workspaceID: "workspace-1", id: "comment-1")),
        .workspaceReviewCommentsSend(
            SpacesDeviceWorkspaceReviewCommentsSendRequest(
                workspaceID: "workspace-1", sessionID: "session-1", text: "text",
                comments: [SpacesDeviceReviewCommentSendEntry(id: "comment-1", revision: 1)])),
    ]

    private static let automationFields = TerminalServiceAutomationFields(
        name: "nightly", enabled: true, triggerKind: "cron", cronExpression: "0 0 * * *", script: "echo hi", workspaceID: "workspace-1",
        concurrencyPolicy: "skip", missedRunPolicy: "skip")

    /// Wire keys with no associated value, which the encoder always writes as `{}` via
    /// `SpacesDeviceAPIEmptyPayload`. Checked for a fully literal, exact payload in addition to the key.
    private static let emptyPayloadKeys: Set<String> = [
        "ping", "daemonStatus", "requestDaemonRestart", "overview", "subscribeDeviceOverview", "agentHooksStatus", "listAutomations",
    ]

    /// Completeness contract for `samples`, split across three layers because no single mechanism covers
    /// all of it:
    ///  1. `goldenWireKey`'s default-less `switch` forces a golden mapping entry for any case added to
    ///     `SpacesDeviceAPICommand` at compile time (a missing arm fails the build).
    ///  2. This assertion rejects a duplicated sample: mapping every sample through `goldenWireKey` and
    ///     checking the resulting set is exactly 74 distinct keys catches two samples for the same case
    ///     (the set would be smaller than the list), which a bare `count == 74` check would miss.
    ///  3. What neither closes: a new 75th case added to the enum but never added to `samples` — the
    ///     switch still compiles (it only requires *a* mapping, not that every mapping is exercised) and
    ///     the set stays "74 distinct out of 74 samples". `SpacesDeviceAPICommand` still cannot conform to
    ///     `CaseIterable` (its cases carry differently-typed associated values), so no enumeration source
    ///     independent of a hand-maintained list exists to close this gap against; both `goldenWireKey` and
    ///     `SpacesDeviceAPICommandDescriptor`'s own switch are default-less exhaustive switches over the
    ///     same enum, not case lists, so neither one can be diffed against `samples` to catch an omission.
    @Test func sampleListCoversEveryCurrentCaseExactlyOnce() {
        let keys = Set(Self.samples.map(Self.goldenWireKey))
        #expect(keys.count == 74)
        #expect(keys.count == Self.samples.count)
    }

    @Test func everyCaseEncodesToItsGoldenWireKeyAndRoundTrips() throws {
        for command in Self.samples {
            let expectedKey = Self.goldenWireKey(command)

            // `SpacesDeviceAPICommandDescriptor.wireKey` is the production source every non-test consumer
            // reads; asserting it against the independently hand-written golden key here, per sample,
            // catches a descriptor-switch typo or drift that the descriptor's own exhaustiveness cannot.
            #expect(command.descriptor.wireKey == expectedKey, "\(expectedKey): descriptor.wireKey did not match the golden wire key")

            let data = try JSONEncoder().encode(command)
            let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect(object.count == 1, "\(expectedKey): command must encode to a single-key object")
            #expect(Array(object.keys) == [expectedKey])

            if Self.emptyPayloadKeys.contains(expectedKey) {
                let payload = try #require(object[expectedKey] as? [String: Any])
                #expect(payload.isEmpty, "\(expectedKey): no-payload command must encode an empty object")
            }

            // Round-trip through the real decoder: the JSON carrying the golden key above must decode
            // back to the exact command it came from.
            let decoded = try JSONDecoder().decode(SpacesDeviceAPICommand.self, from: data)
            #expect(decoded == command, "\(expectedKey): did not round-trip to an equal command")
        }
    }

    /// The descriptor's wire keys, taken over `samples`, must be the exact same set as the golden wire
    /// keys taken over `samples` — same 74 distinct members, none extra, none missing. Redundant with the
    /// per-sample equality above in what it would catch (a mismatched key would fail both), but it asserts
    /// the requirement at the set level explicitly, matching how `sampleListCoversEveryCurrentCaseExactlyOnce`
    /// asserts distinctness at the set level rather than only per-element.
    @Test func descriptorWireKeysMatchGoldenWireKeysAsASet() {
        let goldenKeys = Set(Self.samples.map(Self.goldenWireKey))
        let descriptorKeys = Set(Self.samples.map { $0.descriptor.wireKey })
        #expect(descriptorKeys == goldenKeys)
    }

    /// The golden case-name -> wire-key table, hand-written independently of
    /// `SpacesDeviceAPICommand.CodingKeys`/`name` so a change to either fails this test rather than
    /// passing tautologically. No `default:` arm: the switch itself is the exhaustiveness check.
    private static func goldenWireKey(_ command: SpacesDeviceAPICommand) -> String {
        switch command {
        case .pair: "pair"
        case .ping: "ping"
        case .daemonStatus: "daemonStatus"
        case .requestDaemonRestart: "requestDaemonRestart"
        case .overview: "overview"
        case .createProject: "createProject"
        case .previewGitProject: "previewGitProject"
        case .deleteProject: "deleteProject"
        case .importProject: "importProject"
        case .exportProject: "exportProject"
        case .previewProject: "previewProject"
        case .listDirectories: "listDirectories"
        case .workspaceCreateOptions: "workspaceCreateOptions"
        case .createWorkspace: "createWorkspace"
        case .launchWorkspace: "launchWorkspace"
        case .stopWorkspace: "stopWorkspace"
        case .restartWorkspace: "restartWorkspace"
        case .archiveWorkspace: "archiveWorkspace"
        case .runWorkspaceSetup: "runWorkspaceSetup"
        case .updateProjectConfig: "updateProjectConfig"
        case .updateProjectMetadata: "updateProjectMetadata"
        case .updateWorkspaceConfig: "updateWorkspaceConfig"
        case .updateWorkspaceMetadata: "updateWorkspaceMetadata"
        case .openWorkspaceTerminal: "openWorkspaceTerminal"
        case .startWorkspaceCommandSession: "startWorkspaceCommandSession"
        case .stopWorkspaceTerminal: "stopWorkspaceTerminal"
        case .stopWorkspaceTerminalIfBareShell: "stopWorkspaceTerminalIfBareShell"
        case .renameTerminalSession: "renameTerminalSession"
        case .runWorkspaceProcess: "runWorkspaceProcess"
        case .stopWorkspaceProcess: "stopWorkspaceProcess"
        case .restartWorkspaceProcess: "restartWorkspaceProcess"
        case .stopCodingAgent: "stopCodingAgent"
        case .renameAgentSession: "renameAgentSession"
        case .state: "state"
        case .terminalControl: "terminalControl"
        case .terminalPasteImage: "terminalPasteImage"
        case .sendTerminalInput: "sendTerminalInput"
        case .tailTerminalOutput: "tailTerminalOutput"
        case .terminalTranscript: "terminalTranscript"
        case .subscribe: "subscribe"
        case .resolveTerminalLink: "resolveTerminalLink"
        case .readTerminalLinkChunk: "readTerminalLinkChunk"
        case .subscribeDeviceOverview: "subscribeDeviceOverview"
        case .agentHooksStatus: "agentHooksStatus"
        case .installAgentHooks: "installAgentHooks"
        case .spawnAgentSession: "spawnAgentSession"
        case .listAgentSessions: "listAgentSessions"
        case .annotateAgentSession: "annotateAgentSession"
        case .killAgentSession: "killAgentSession"
        case .openServiceTunnel: "openServiceTunnel"
        case .createAutomation: "createAutomation"
        case .updateAutomation: "updateAutomation"
        case .setAutomationNextRun: "setAutomationNextRun"
        case .deleteAutomation: "deleteAutomation"
        case .listAutomations: "listAutomations"
        case .listAutomationRuns: "listAutomationRuns"
        case .triggerAutomation: "triggerAutomation"
        case .cancelAutomationRun: "cancelAutomationRun"
        case .endAutomationAgents: "endAutomationAgents"
        case .workspaceFileRead: "workspaceFileRead"
        case .workspaceRevisionFileRead: "workspaceRevisionFileRead"
        case .workspaceFileWrite: "workspaceFileWrite"
        case .workspaceFileList: "workspaceFileList"
        case .workspaceRefList: "workspaceRefList"
        case .workspaceDiffManifestChunk: "workspaceDiffManifestChunk"
        case .workspaceDiffManifestRelease: "workspaceDiffManifestRelease"
        case .workspaceDiffFileChunk: "workspaceDiffFileChunk"
        case .subscribeWorkspaceDiffSignature: "subscribeWorkspaceDiffSignature"
        case .subscribeWorkspaceFileSignature: "subscribeWorkspaceFileSignature"
        case .subscribeWorkspaceFileListSignature: "subscribeWorkspaceFileListSignature"
        case .workspaceReviewCommentList: "workspaceReviewCommentList"
        case .workspaceReviewCommentUpsert: "workspaceReviewCommentUpsert"
        case .workspaceReviewCommentDelete: "workspaceReviewCommentDelete"
        case .workspaceReviewCommentsSend: "workspaceReviewCommentsSend"
        }
    }
}
