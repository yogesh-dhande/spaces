import XCTest
import spacesterminalcore

@testable import spacesdeviceapi
@testable import spacesdevicecore

final class SpacesDeviceAPIProtocolTests: XCTestCase {
    func testWireProtocolVersionCoversAgentHooksCommands() { XCTAssertGreaterThanOrEqual(SpacesWireProtocol.version, 2) }

    func testWireProtocolVersionCoversTerminalForegroundCommandSummary() { XCTAssertGreaterThanOrEqual(SpacesWireProtocol.version, 26) }

    func testSubscribeDeviceOverviewRoundTripsThroughCodecAndIsASubscription() throws {
        let request = SpacesDeviceAPIRequest(command: .subscribeDeviceOverview, authToken: "SECRET")
        XCTAssertTrue(request.command.isSubscriptionCommand)
        XCTAssertTrue(request.command.isDeviceOverviewSubscription)
        XCTAssertFalse(SpacesDeviceAPIRequest(command: .overview).command.isDeviceOverviewSubscription)
        XCTAssertEqual(try SpacesDeviceAPICodec.decodeRequest(SpacesDeviceAPICodec.encodeRequest(request)), request)
    }

    func testAgentHooksStatusCommandIsReplaySafeAndRoundTrips() throws {
        let request = SpacesDeviceAPIRequest(command: .agentHooksStatus, authToken: "SECRET")
        XCTAssertTrue(request.isSafeToReplayAfterConnectionFailure)
        XCTAssertEqual(try SpacesDeviceAPICodec.decodeRequest(SpacesDeviceAPICodec.encodeRequest(request)), request)
    }

    func testInstallAgentHooksCommandRoundTripsAndIsNotReplaySafe() throws {
        let request = SpacesDeviceAPIRequest(command: .installAgentHooks(.init(kinds: [.claudeCode, .opencode])), authToken: "SECRET")
        XCTAssertFalse(request.isSafeToReplayAfterConnectionFailure)
        XCTAssertEqual(try SpacesDeviceAPICodec.decodeRequest(SpacesDeviceAPICodec.encodeRequest(request)), request)
    }

    func testAgentHooksStatusResultRoundTripsThroughResponse() throws {
        let payload = SpacesAgentHooksStatusPayload(agents: [
            AgentHookStatus(kind: .claudeCode, displayName: "Claude Code", available: true, installState: .current),
            AgentHookStatus(kind: .codex, displayName: "Codex", available: true, installState: .notInstalled),
            AgentHookStatus(kind: .opencode, displayName: "opencode", available: false, installState: .notInstalled),
        ])
        let response = SpacesDeviceAPIResponse(ok: true, message: "Loaded agent hook status.", result: .agentHooksStatus(payload))
        let decoded = try SpacesDeviceAPICodec.decodeResponse(SpacesDeviceAPICodec.encodeResponse(response))
        XCTAssertEqual(decoded, response)
        XCTAssertEqual(decoded.agentHooksStatus, payload)
    }

    /// An install answers `ok` even when one agent failed, so the per-agent failures have to survive the
    /// wire: they are the only way the client learns which agents to record and which to retry.
    func testAgentHooksInstallResultCarriesPerAgentFailuresThroughResponse() throws {
        let outcome = AgentHookInstallOutcome(
            agents: [
                AgentHookStatus(kind: .claudeCode, displayName: "Claude Code", available: true, installState: .current),
                AgentHookStatus(kind: .codex, displayName: "Codex", available: true, installState: .notInstalled),
            ], failures: [AgentHookInstallFailure(kind: .codex, message: "config.toml already defines `features`.")])
        let response = SpacesDeviceAPIResponse(ok: true, message: "Installed agent hooks.", result: .agentHooksInstall(outcome))

        let decoded = try SpacesDeviceAPICodec.decodeResponse(SpacesDeviceAPICodec.encodeResponse(response))

        XCTAssertEqual(decoded, response)
        XCTAssertEqual(decoded.agentHooksInstall, outcome)
        XCTAssertNil(decoded.agentHooksStatus)
    }

    func testResponseErrorCodeEncodesWhenSetAndDecodesNilWhenAbsent() throws {
        let failure = SpacesDeviceAPIResponse(ok: false, message: "Terminal session 'abc' is not running.", errorCode: .sessionNotRunning)
        let failureData = try SpacesDeviceAPICodec.encodeResponse(failure)
        XCTAssertTrue(String(decoding: failureData, as: UTF8.self).contains(#""errorCode":"sessionNotRunning""#))
        XCTAssertEqual(try SpacesDeviceAPICodec.decodeResponse(failureData), failure)

        let success = SpacesDeviceAPIResponse(ok: true, message: "pong")
        let successData = try SpacesDeviceAPICodec.encodeResponse(success)
        XCTAssertFalse(String(decoding: successData, as: UTF8.self).contains("errorCode"))

        let jsonWithoutErrorCode = #"{"ok":false,"message":"Provide a project directory."}"#.data(using: .utf8)!
        XCTAssertNil(try SpacesDeviceAPICodec.decodeResponse(jsonWithoutErrorCode).errorCode)
    }

    func testSpawnAgentSessionRequestRoundTripsAndIsNotReplaySafe() throws {
        let request = SpacesDeviceAPIRequest(
            command: .spawnAgentSession(.init(workspaceID: "workspace-1", command: "codex --yolo", title: "Reviewer")), authToken: "SECRET")

        XCTAssertEqual(request.commandName, "spawnAgentSession")
        // A spawn creates a session; a replayed spawn after an ambiguous failure could start two.
        XCTAssertFalse(request.isSafeToReplayAfterConnectionFailure)
        XCTAssertEqual(try SpacesDeviceAPICodec.decodeRequest(SpacesDeviceAPICodec.encodeRequest(request)), request)
    }

    func testListAgentSessionsRequestRoundTripsAndIsReplaySafe() throws {
        let request = SpacesDeviceAPIRequest(command: .listAgentSessions(.init(sessionID: "agent-session")), authToken: "SECRET")

        XCTAssertEqual(request.commandName, "listAgentSessions")
        // A read-only listing (also the remote readiness poll) is safe to replay.
        XCTAssertTrue(request.isSafeToReplayAfterConnectionFailure)
        XCTAssertEqual(try SpacesDeviceAPICodec.decodeRequest(SpacesDeviceAPICodec.encodeRequest(request)), request)
    }

    func testAnnotateAgentSessionRequestRoundTripsAndIsNotReplaySafe() throws {
        let request = SpacesDeviceAPIRequest(
            command: .annotateAgentSession(.init(sessionID: "agent-session", note: "review auth")), authToken: "SECRET")

        XCTAssertEqual(request.commandName, "annotateAgentSession")
        XCTAssertFalse(request.isSafeToReplayAfterConnectionFailure)
        XCTAssertEqual(try SpacesDeviceAPICodec.decodeRequest(SpacesDeviceAPICodec.encodeRequest(request)), request)
    }

    func testKillAgentSessionRequestRoundTripsAndIsNotReplaySafe() throws {
        let request = SpacesDeviceAPIRequest(command: .killAgentSession(.init(sessionID: "agent-session")), authToken: "SECRET")

        XCTAssertEqual(request.commandName, "killAgentSession")
        // Killing a session is a mutation; a replay after an ambiguous failure could kill a session
        // reusing the id, so it is not replay-safe.
        XCTAssertFalse(request.isSafeToReplayAfterConnectionFailure)
        XCTAssertEqual(try SpacesDeviceAPICodec.decodeRequest(SpacesDeviceAPICodec.encodeRequest(request)), request)
    }

    func testAgentSessionsResultRoundTripsThroughResponse() throws {
        let row = SpacesDeviceAgentSessionRow(
            id: "agent-1", terminalSessionID: "session-1", agent: "Claude Code CLI", label: "Claude Code CLI", status: "waiting", note: "review auth",
            projectID: "project-1", projectName: "Spaces", workspaceID: "workspace-1", workspaceName: "feature",
            workspaceDir: "/repo/workspaces/feature", branch: "feature", updatedAt: "2026-07-14T00:00:00Z", lastSignalAt: "2026-07-14T00:00:01Z")
        let response = SpacesDeviceAPIResponse(ok: true, message: "Listed agent sessions.", result: .agentSessions(.init(rows: [row])))

        let decoded = try SpacesDeviceAPICodec.decodeResponse(SpacesDeviceAPICodec.encodeResponse(response))

        XCTAssertEqual(decoded, response)
        XCTAssertEqual(decoded.agentSessions?.first, row)
        XCTAssertEqual(decoded.agentSessions?.first?.note, "review auth")
        XCTAssertEqual(decoded.agentSessions?.first?.lastSignalAt, "2026-07-14T00:00:01Z")
    }

    func testDeviceOverviewStreamCodecRoundTripsPayload() throws {
        let payload = SpacesDeviceOverviewPayload(workspaces: [], sessions: [])
        let line = try SpacesDeviceOverviewStreamCodec.encodeLine(payload)
        XCTAssertEqual(line.last, 0x0A)
        XCTAssertEqual(try SpacesDeviceOverviewStreamCodec.decodeLine(line.dropLast()), payload)
    }

    /// A daemon that predates the automations feature (or, for `projects`, predates whatever shipped
    /// that field) never emits `automations`/`automationRuns`/`projects` keys at all. The synthesized
    /// `Decodable` initializer requires every key regardless of the memberwise-init defaults, so a
    /// missing key would previously fail decoding of the *entire* overview -- workspaces and sessions
    /// included, not just the new field. Verify the custom `init(from:)` tolerates all three being absent.
    func testOverviewPayloadDecodesWhenAutomationsAndProjectsKeysAreMissing() throws {
        let session = SpacesDeviceTerminalSessionSummary(
            id: "session-1", title: "API", workingDirectory: "/repo", shell: "/bin/zsh", command: "npm run dev", state: .running,
            backend: .ghosttyEmbedded, lifetimePolicy: .persistent, servicePID: 123, childPID: 456, workspaceID: "workspace-1",
            workspaceTitle: "Feature", projectID: "project-1", projectName: "Project", createdAt: "2026-01-01T00:00:00Z",
            updatedAt: "2026-01-01T00:00:01Z", isControlAvailable: true, isSubscriptionAvailable: true,
            attachmentSnapshot: TerminalSessionAttachmentSnapshot())
        let overview = SpacesDeviceOverviewPayload(
            workspaces: [
                SpacesDeviceWorkspaceSummary(
                    id: "workspace-1", projectID: "project-1", projectName: "Project", branch: nil, baseBranch: nil, dir: "/repo", isRunning: true,
                    isHidden: false, isDefault: false, sessionCount: 1)
            ], sessions: [session],
            daemonStatus: TerminalServiceDaemonStatus(version: "1.0", installedVersion: nil, certificateFingerprint: nil, activeSessionCount: 1))

        let encoded = try JSONEncoder().encode(overview)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertNotNil(json["automations"])
        XCTAssertNotNil(json["automationRuns"])
        XCTAssertNotNil(json["projects"])
        json.removeValue(forKey: "automations")
        json.removeValue(forKey: "automationRuns")
        json.removeValue(forKey: "projects")
        let strippedData = try JSONSerialization.data(withJSONObject: json)

        let decoded = try JSONDecoder().decode(SpacesDeviceOverviewPayload.self, from: strippedData)

        XCTAssertEqual(decoded.automations, [])
        XCTAssertEqual(decoded.automationRuns, [])
        XCTAssertEqual(decoded.projects, [])
        XCTAssertEqual(decoded.workspaces.count, 1)
        XCTAssertEqual(decoded.workspaces.first?.id, "workspace-1")
        XCTAssertEqual(decoded.sessions.first?.id, "session-1")
        XCTAssertEqual(decoded.sessions.first?.shell, "/bin/zsh")
    }

    // A project summary sent by a peer that predates project-level hiding decodes as visible rather than
    // failing the whole overview.
    func testProjectSummaryDecodesWithoutHiddenFlag() throws {
        let project = SpacesDeviceProjectSummary(
            id: "project-1", name: "Project", dir: "/repo", isGitRepo: true, defaultBranch: "main", isHidden: true)

        let encoded = try JSONEncoder().encode(project)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(json["isHidden"] as? Bool, true)
        json.removeValue(forKey: "isHidden")
        let strippedData = try JSONSerialization.data(withJSONObject: json)

        let decoded = try JSONDecoder().decode(SpacesDeviceProjectSummary.self, from: strippedData)

        XCTAssertFalse(decoded.isHidden)
        XCTAssertEqual(decoded.id, "project-1")
        XCTAssertEqual(decoded.defaultBranch, "main")
    }

    func testTerminalControlRequestsAreNotReplaySafeAfterAmbiguousConnectionFailure() throws {
        let request = SpacesDeviceAPIRequest(
            command: .terminalControl(.init(action: .send, sessionID: "session-1", clientID: "client-1", text: "a")), authToken: "SECRET")

        XCTAssertFalse(request.isSafeToReplayAfterConnectionFailure)
    }

    func testTerminalControlSendPasteIntentRoundTripsThroughCodec() throws {
        let request = SpacesDeviceAPIRequest(
            command: .terminalControl(
                .init(action: .send, sessionID: "session-1", clientID: "client-1", text: "line one\nline two", ownerEpoch: 4, asPaste: true)),
            authToken: "SECRET")

        let decoded = try SpacesDeviceAPICodec.decodeRequest(SpacesDeviceAPICodec.encodeRequest(request))

        guard case .terminalControl(let payload) = decoded.command else { return XCTFail("Expected terminalControl request.") }
        XCTAssertEqual(payload.action, .send)
        XCTAssertEqual(payload.text, "line one\nline two")
        XCTAssertEqual(payload.ownerEpoch, 4)
        XCTAssertTrue(payload.asPaste)
        XCTAssertFalse(decoded.isSafeToReplayAfterConnectionFailure)
    }

    func testReadOnlyRequestsAreReplaySafeAfterAmbiguousConnectionFailure() throws {
        let requests = [
            SpacesDeviceAPIRequest(command: .ping, authToken: "SECRET"), SpacesDeviceAPIRequest(command: .overview, authToken: "SECRET"),
            SpacesDeviceAPIRequest(command: .workspaceCreateOptions(.init(projectID: "project-1")), authToken: "SECRET"),
            SpacesDeviceAPIRequest(command: .state(.init(sessionID: "session-1")), authToken: "SECRET"),
            SpacesDeviceAPIRequest(command: .resolveTerminalLink(.init(sessionID: "session-1", terminalLink: "file:///tmp/a")), authToken: "SECRET"),
            SpacesDeviceAPIRequest(
                command: .readTerminalLinkChunk(.init(sessionID: "session-1", terminalLinkID: "link-1", offset: 0, limit: 128)), authToken: "SECRET"),
            SpacesDeviceAPIRequest(command: .workspaceDiffManifestChunk(.init(workspaceID: "workspace-1", fileIndex: 0)), authToken: "SECRET"),
            SpacesDeviceAPIRequest(
                command: .workspaceDiffManifestRelease(.init(workspaceID: "workspace-1", manifestID: "manifest-1")), authToken: "SECRET"),
            SpacesDeviceAPIRequest(
                command: .workspaceDiffFileChunk(
                    .init(workspaceID: "workspace-1", manifestID: "manifest-1", relativePath: "README.md", byteOffset: 0)), authToken: "SECRET"),
            SpacesDeviceAPIRequest(
                command: .workspaceRevisionFileRead(
                    .init(workspaceID: "workspace-1", revision: String(repeating: "a", count: 40), relativePath: "README.md")), authToken: "SECRET"),
        ]

        for request in requests { XCTAssertTrue(request.isSafeToReplayAfterConnectionFailure, request.commandName) }
    }

    func testWorkspaceRevisionFileReadRoundTripsThroughTheProtocol() throws {
        let revision = String(repeating: "a", count: 40)
        let request = SpacesDeviceAPIRequest(
            command: .workspaceRevisionFileRead(
                .init(workspaceID: "workspace-1", revision: revision, relativePath: "Sources/App.swift", oldPath: "Sources/OldApp.swift")),
            authToken: "SECRET")
        let response = SpacesDeviceAPIResponse(
            ok: true, message: "Read workspace revision file.",
            result: .workspaceRevisionFileRead(.init(
                worktreeFile: .init(base64Data: "d29ya3RyZWU=", sha256: "worktree-sha", size: 8, isBinaryGuess: false),
                isWorktreeEquivalentToRevision: true, comparisonOldBase64Data: "aGVsbG8=")))

        XCTAssertEqual(try SpacesDeviceAPICodec.decodeRequest(SpacesDeviceAPICodec.encodeRequest(request)), request)
        let decodedResponse = try SpacesDeviceAPICodec.decodeResponse(SpacesDeviceAPICodec.encodeResponse(response))
        XCTAssertEqual(decodedResponse, response)
        XCTAssertEqual(decodedResponse.workspaceRevisionFileRead?.worktreeFile.sha256, "worktree-sha")
        XCTAssertEqual(decodedResponse.workspaceRevisionFileRead?.comparisonOldBase64Data, "aGVsbG8=")
    }

    func testDiffManifestChunkRequiresAnExplicitSemanticFileIndex() {
        let data = Data(#"{"workspaceID":"workspace-1"}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(SpacesDeviceWorkspaceDiffManifestChunkRequest.self, from: data))
    }

    /// `.workspaceReviewCommentList` is a pure read (its handler only SELECTs from the review-comment
    /// store), so it joins `.workspaceFileRead`/the workspace diff manifest as safe to replay after a
    /// dropped/stale persistent socket. The sibling mutation commands must stay excluded: an upsert/delete/
    /// send is not idempotent on the wire, so a blind replay could double-create or double-send.
    func testWorkspaceReviewCommentListIsReplaySafeButItsMutationsAreNot() throws {
        let listRequest = SpacesDeviceAPIRequest(command: .workspaceReviewCommentList(.init(workspaceID: "workspace-1")), authToken: "SECRET")
        XCTAssertTrue(listRequest.isSafeToReplayAfterConnectionFailure)

        let upsertRequest = SpacesDeviceAPIRequest(
            command: .workspaceReviewCommentUpsert(
                .init(workspaceID: "workspace-1", filePath: "a.swift", side: .new, lineNumber: 1, lineText: "let x = 1", body: "comment")),
            authToken: "SECRET")
        XCTAssertFalse(upsertRequest.isSafeToReplayAfterConnectionFailure)

        let deleteRequest = SpacesDeviceAPIRequest(
            command: .workspaceReviewCommentDelete(.init(workspaceID: "workspace-1", id: "comment-1")), authToken: "SECRET")
        XCTAssertFalse(deleteRequest.isSafeToReplayAfterConnectionFailure)

        let sendRequest = SpacesDeviceAPIRequest(
            command: .workspaceReviewCommentsSend(.init(workspaceID: "workspace-1", sessionID: "session-1", text: "please address", comments: [])),
            authToken: "SECRET")
        XCTAssertFalse(sendRequest.isSafeToReplayAfterConnectionFailure)
    }

    func testMutatingRequestsAreNotReplaySafeAfterAmbiguousConnectionFailure() throws {
        let requests = [
            SpacesDeviceAPIRequest(command: .openWorkspaceTerminal(.init(workspaceID: "workspace-1")), authToken: "SECRET"),
            SpacesDeviceAPIRequest(command: .stopWorkspaceTerminal(.init(workspaceID: "workspace-1", sessionID: "session-1")), authToken: "SECRET"),
            SpacesDeviceAPIRequest(
                command: .runWorkspaceProcess(.init(workspaceID: "workspace-1", processKey: "api", processTemplateID: "template-1")),
                authToken: "SECRET"),
            SpacesDeviceAPIRequest(command: .stopCodingAgent(.init(workspaceID: "workspace-1", agentID: "agent-1")), authToken: "SECRET"),
        ]

        for request in requests { XCTAssertFalse(request.isSafeToReplayAfterConnectionFailure, request.commandName) }
    }

    /// The conditional stop a closed owner pane sends. It names the same session as the unconditional
    /// stop and, like it, must not be replayed after an ambiguous failure: a replay could catch the
    /// terminal at a prompt it was busy at the first time.
    func testStopWorkspaceTerminalIfBareShellRoundTripsAndIsNotReplaySafe() throws {
        let request = SpacesDeviceAPIRequest(
            command: .stopWorkspaceTerminalIfBareShell(.init(workspaceID: "workspace-1", sessionID: "session-1")), authToken: "SECRET")

        XCTAssertEqual(request.commandName, "stopWorkspaceTerminalIfBareShell")
        XCTAssertEqual(request.sessionID, "session-1")
        XCTAssertFalse(request.isSafeToReplayAfterConnectionFailure)
        XCTAssertEqual(try SpacesDeviceAPICodec.decodeRequest(SpacesDeviceAPICodec.encodeRequest(request)), request)
    }

    func testRenameTerminalSessionRequestRoundTripsAndIsNotReplaySafe() throws {
        let request = SpacesDeviceAPIRequest(
            command: .renameTerminalSession(.init(workspaceID: "workspace-1", sessionID: "session-1", title: "build watcher")), authToken: "SECRET")

        XCTAssertEqual(request.commandName, "renameTerminalSession")
        XCTAssertEqual(request.sessionID, "session-1")
        XCTAssertFalse(request.isSafeToReplayAfterConnectionFailure)
        XCTAssertEqual(try SpacesDeviceAPICodec.decodeRequest(SpacesDeviceAPICodec.encodeRequest(request)), request)
    }

    func testSendTerminalInputRoundTripsAndIsNotReplaySafe() throws {
        let textRequest = SpacesDeviceAPIRequest(
            command: .sendTerminalInput(.init(sessionID: "session-1", text: "echo hello", appendNewline: true)), authToken: "SECRET")
        let bytesRequest = SpacesDeviceAPIRequest(
            command: .sendTerminalInput(.init(sessionID: "session-1", bytes: Data([0x03]))), authToken: "SECRET")

        XCTAssertEqual(textRequest.commandName, "sendTerminalInput")
        XCTAssertEqual(textRequest.sessionID, "session-1")
        // A send that vanished into an ambiguous connection failure may already have reached the
        // shell; replaying it could execute the command twice.
        XCTAssertFalse(textRequest.isSafeToReplayAfterConnectionFailure)
        XCTAssertEqual(try SpacesDeviceAPICodec.decodeRequest(SpacesDeviceAPICodec.encodeRequest(textRequest)), textRequest)
        XCTAssertEqual(try SpacesDeviceAPICodec.decodeRequest(SpacesDeviceAPICodec.encodeRequest(bytesRequest)), bytesRequest)
    }

    func testTailTerminalOutputRoundTripsAndIsReplaySafe() throws {
        let request = SpacesDeviceAPIRequest(command: .tailTerminalOutput(.init(sessionID: "session-1", lines: 40)), authToken: "SECRET")

        XCTAssertEqual(request.commandName, "tailTerminalOutput")
        XCTAssertEqual(request.sessionID, "session-1")
        XCTAssertTrue(request.isSafeToReplayAfterConnectionFailure)
        XCTAssertEqual(try SpacesDeviceAPICodec.decodeRequest(SpacesDeviceAPICodec.encodeRequest(request)), request)

        let response = SpacesDeviceAPIResponse(ok: true, message: "Read terminal output.", result: .terminalOutput(.init(text: "hello\n")))
        let decoded = try SpacesDeviceAPICodec.decodeResponse(SpacesDeviceAPICodec.encodeResponse(response))
        XCTAssertEqual(decoded.terminalOutput, "hello\n")
    }

    func testRequestRoundTripsScrollModsThroughCodec() throws {
        let request = SpacesDeviceAPIRequest(
            command: .terminalControl(
                .init(
                    action: .scroll, sessionID: "session-1", clientID: "ios-client", ownerEpoch: 3, scrollHorizontal: 1.5, scrollVertical: -2.5,
                    scrollMods: 7, scrollPointerX: 0.25, scrollPointerY: 0.75, scrollPointerMods: 9)), authToken: "SECRET")

        XCTAssertEqual(try SpacesDeviceAPICodec.decodeRequest(SpacesDeviceAPICodec.encodeRequest(request)), request)
    }

    func testGitProjectPreviewCommandAndResultRoundTripThroughCodec() throws {
        let preview = SpacesDeviceAPIRequest(command: .previewGitProject(.init(gitURL: "https://example.com/repo.git")), authToken: "SECRET")
        XCTAssertEqual(try SpacesDeviceAPICodec.decodeRequest(SpacesDeviceAPICodec.encodeRequest(preview)), preview)
        // The preview only reads spaces.yaml and has no side effects, so it is replay-safe.
        XCTAssertTrue(preview.isSafeToReplayAfterConnectionFailure)

        // The git create carries only the URL and config; the clone happens as part of Create.
        let create = SpacesDeviceAPIRequest(
            command: .createProject(.init(projectDir: nil, gitURL: "https://example.com/repo.git", config: SpacesDeviceProjectConfig())),
            authToken: "SECRET")
        XCTAssertEqual(try SpacesDeviceAPICodec.decodeRequest(SpacesDeviceAPICodec.encodeRequest(create)), create)

        let result = SpacesDeviceGitProjectPreview(
            config: SpacesDeviceProjectConfig(),
            replacementCandidates: [SpacesDeviceManagedDirectoryReplacementCandidate(kind: "projectRepository", path: "/tmp/repo")],
            spacesYAMLFound: true)
        let response = SpacesDeviceAPIResponse(ok: true, message: "ok", result: .gitProjectPreview(result))
        let decoded = try JSONDecoder().decode(SpacesDeviceAPIResponse.self, from: JSONEncoder().encode(response))
        XCTAssertEqual(decoded.gitProjectPreview, result)
    }

    func testAmbiguousRequestPayloadIsRejected() throws {
        let payload = #"{"command":{"overview":{},"ping":{}}}"#.data(using: .utf8)!

        XCTAssertThrowsError(try SpacesDeviceAPICodec.decodeRequest(payload))
    }

    func testMutationRequestRoundTripsWorkspaceAndRuntimeFields() throws {
        let requests = [
            SpacesDeviceAPIRequest(
                command: .createProject(
                    .init(
                        projectDir: "/repo", gitURL: nil,
                        config: SpacesDeviceProjectConfig(
                            setupScript: "make setup", ports: [SpacesDeviceServiceDefinition(id: "port-web", name: "WEB")],
                            processes: [SpacesDeviceProcessTemplate(id: "process-web", name: "web", command: "npm run dev")]))), authToken: "SECRET"),
            SpacesDeviceAPIRequest(command: .deleteProject(.init(projectID: "project-1")), authToken: "SECRET"),
            SpacesDeviceAPIRequest(command: .importProject(.init(projectID: "project-1", updateAllWorkspaces: true)), authToken: "SECRET"),
            SpacesDeviceAPIRequest(command: .exportProject(.init(projectID: "project-1")), authToken: "SECRET"),
            SpacesDeviceAPIRequest(
                command: .createWorkspace(
                    .init(projectID: "project-1", branch: "feature", baseBranch: "main", directoryName: "feature-dir", allowExistingBranchReuse: true)
                ), authToken: "SECRET"), SpacesDeviceAPIRequest(command: .runWorkspaceSetup(.init(workspaceID: "workspace-1")), authToken: "SECRET"),
            SpacesDeviceAPIRequest(
                command: .updateWorkspaceMetadata(.init(workspaceID: "workspace-1", isHidden: true, updatesHidden: true)), authToken: "SECRET"),
            SpacesDeviceAPIRequest(
                command: .updateProjectMetadata(.init(projectID: "project-1", isHidden: true, updatesHidden: true)), authToken: "SECRET"),
            SpacesDeviceAPIRequest(
                command: .runWorkspaceProcess(.init(workspaceID: "workspace-1", processKey: "api", processTemplateID: "template-1")),
                authToken: "SECRET"),
            SpacesDeviceAPIRequest(
                command: .restartWorkspaceProcess(
                    .init(workspaceID: "workspace-1", processID: "process-1", processKey: "api", processTemplateID: "template-1")),
                authToken: "SECRET"),
            SpacesDeviceAPIRequest(command: .stopCodingAgent(.init(workspaceID: "workspace-1", agentID: "agent-1")), authToken: "SECRET"),
        ]

        for request in requests { XCTAssertEqual(try SpacesDeviceAPICodec.decodeRequest(SpacesDeviceAPICodec.encodeRequest(request)), request) }
    }

    func testOverviewRoundTripsRuntimeRowsAndSessionSummary() throws {
        let processRow = SpacesDeviceWorkspaceProcessRow(
            id: "process-1", workspaceID: "workspace-1", name: "API", command: "npm run dev", processID: "runtime-1", sessionID: "session-1",
            runState: .running, canRun: false, canStop: true, canRestart: true)
        let agentRow = SpacesDeviceWorkspaceCodingAgentRow(
            id: "agent-1", workspaceID: "workspace-1", name: "Codex", command: "codex", agentID: "agent-runtime-1", sessionID: "session-2",
            runState: .running, activityState: .spinning, canStop: true)
        let terminalRow = SpacesDeviceWorkspaceTerminalRow(
            id: "terminal-1", workspaceID: "workspace-1", title: "Shell", workingDirectory: "/repo", sessionID: "session-3", runState: .running,
            canOpenTerminal: true, canStop: true)
        let session = SpacesDeviceTerminalSessionSummary(
            id: "session-1", title: "API", workingDirectory: "/repo", shell: "/bin/zsh", command: "npm run dev", state: .running,
            backend: .ghosttyEmbedded, lifetimePolicy: .persistent, servicePID: 123, childPID: 456, workspaceID: "workspace-1",
            workspaceTitle: "Feature", projectID: "project-1", projectName: "Project", createdAt: "2026-01-01T00:00:00Z",
            updatedAt: "2026-01-01T00:00:01Z", isControlAvailable: true, isSubscriptionAvailable: true,
            attachmentSnapshot: TerminalSessionAttachmentSnapshot(), foregroundDetectedAgentKind: "codex", foregroundCommand: "codex --model gpt-5")
        let overview = SpacesDeviceOverviewPayload(
            workspaces: [
                SpacesDeviceWorkspaceSummary(
                    id: "workspace-1", projectID: "project-1", projectName: "Project", branch: nil, baseBranch: nil, dir: "/repo", isRunning: true,
                    isHidden: false, isDefault: false, sessionCount: 1, processRows: [processRow], codingAgentRows: [agentRow],
                    terminalRows: [terminalRow])
            ], sessions: [session])

        let decoded = try SpacesDeviceAPICodec.decodeResponse(
            SpacesDeviceAPICodec.encodeResponse(SpacesDeviceAPIResponse(ok: true, message: "ok", result: .overview(overview))))
        XCTAssertEqual(decoded.overview?.workspaces.first?.processRows.first, processRow)
        XCTAssertEqual(decoded.overview?.workspaces.first?.codingAgentRows.first, agentRow)
        XCTAssertEqual(decoded.overview?.workspaces.first?.terminalRows.first, terminalRow)
        XCTAssertEqual(decoded.overview?.sessions.first?.shell, "/bin/zsh")
        XCTAssertEqual(decoded.overview?.sessions.first?.command, "npm run dev")
        XCTAssertEqual(decoded.overview?.sessions.first?.foregroundDetectedAgentKind, "codex")
        XCTAssertEqual(decoded.overview?.sessions.first?.foregroundCommand, "codex --model gpt-5")
        let encodedResponse = try SpacesDeviceAPICodec.encodeResponse(SpacesDeviceAPIResponse(ok: true, message: "ok", result: .overview(overview)))
        XCTAssertFalse(String(data: encodedResponse, encoding: .utf8)?.contains("authToken") == true)
    }

    func testResponseRoundTripsMutationOutputsAndCreateOptions() throws {
        let options = SpacesDeviceWorkspaceCreateOptions(
            projects: [SpacesDeviceProjectSummary(id: "project-1", name: "Project", dir: "/repo", isGitRepo: true, defaultBranch: "main")],
            selectedProjectID: "project-1", branchOptions: ["main"])
        let response = SpacesDeviceAPIResponse(
            ok: true, message: "ok", result: .mutation(.init(projectID: "project-1", workspaceID: "workspace-1", sessionID: "session-1")))
        let optionsResponse = SpacesDeviceAPIResponse(ok: true, message: "ok", result: .workspaceCreateOptions(options))

        XCTAssertEqual(try SpacesDeviceAPICodec.decodeResponse(SpacesDeviceAPICodec.encodeResponse(response)), response)
        XCTAssertEqual(try SpacesDeviceAPICodec.decodeResponse(SpacesDeviceAPICodec.encodeResponse(optionsResponse)), optionsResponse)
    }

    func testTerminalLinkRequestsAndResponsesRoundTrip() throws {
        let resolveRequest = SpacesDeviceAPIRequest(
            command: .resolveTerminalLink(.init(sessionID: "session-1", terminalLink: "images/screenshot.png")), authToken: "SECRET")
        let chunkRequest = SpacesDeviceAPIRequest(
            command: .readTerminalLinkChunk(.init(sessionID: "session-1", terminalLinkID: "link-1", offset: 128, limit: 4096)), authToken: "SECRET")

        XCTAssertEqual(try SpacesDeviceAPICodec.decodeRequest(SpacesDeviceAPICodec.encodeRequest(resolveRequest)), resolveRequest)
        XCTAssertEqual(try SpacesDeviceAPICodec.decodeRequest(SpacesDeviceAPICodec.encodeRequest(chunkRequest)), chunkRequest)

        let metadata = SpacesDeviceTerminalLinkMetadata(
            id: "link-1", source: .localFile, originalLink: "images/screenshot.png", displayName: "screenshot.png", contentType: "image/png",
            artifactKind: .image, byteCount: 12, externalURL: nil)
        let chunk = SpacesDeviceTerminalLinkChunk(
            linkID: "link-1", offset: 0, byteCount: 4, isFinal: false, base64Data: Data([1, 2, 3, 4]).base64EncodedString())
        let metadataResponse = SpacesDeviceAPIResponse(ok: true, message: "ok", result: .terminalLinkMetadata(metadata))
        let chunkResponse = SpacesDeviceAPIResponse(ok: true, message: "ok", result: .terminalLinkChunk(chunk))

        XCTAssertEqual(try SpacesDeviceAPICodec.decodeResponse(SpacesDeviceAPICodec.encodeResponse(metadataResponse)), metadataResponse)
        XCTAssertEqual(try SpacesDeviceAPICodec.decodeResponse(SpacesDeviceAPICodec.encodeResponse(chunkResponse)), chunkResponse)
    }

    func testTerminalLinkClassifierRejectsAudioMediaTypes() {
        XCTAssertEqual(SpacesDeviceTerminalLinkClassifier.artifactKind(contentType: nil, pathExtension: "mp4"), .video)
        XCTAssertEqual(SpacesDeviceTerminalLinkClassifier.artifactKind(contentType: nil, pathExtension: "png"), .image)
        XCTAssertNil(SpacesDeviceTerminalLinkClassifier.artifactKind(contentType: "audio/mpeg", pathExtension: nil))
        XCTAssertNil(SpacesDeviceTerminalLinkClassifier.artifactKind(contentType: nil, pathExtension: "mp3"))
        XCTAssertNil(SpacesDeviceTerminalLinkClassifier.artifactKind(contentType: "audio/wav", pathExtension: "wav"))
    }

    func testTerminalLinkClassifierClassifiesDocumentExtensions() {
        let byExtension = SpacesDeviceTerminalLinkClassifier.artifactKind
        XCTAssertEqual(byExtension(nil, "md"), .markdown)
        XCTAssertEqual(byExtension(nil, "markdown"), .markdown)
        XCTAssertEqual(byExtension(nil, "html"), .html)
        XCTAssertEqual(byExtension(nil, "htm"), .html)
        XCTAssertEqual(byExtension(nil, "pdf"), .pdf)
        XCTAssertEqual(byExtension(nil, "txt"), .text)
        XCTAssertEqual(byExtension(nil, "log"), .text)
        XCTAssertEqual(byExtension(nil, "json"), .text)
        XCTAssertEqual(byExtension(nil, "jsonl"), .text)
        XCTAssertEqual(byExtension(nil, "yaml"), .text)
        XCTAssertEqual(byExtension(nil, "yml"), .text)
        XCTAssertEqual(byExtension(nil, "csv"), .text)
        XCTAssertEqual(byExtension(nil, "tsv"), .text)
        XCTAssertEqual(byExtension(nil, "toml"), .text)
        XCTAssertEqual(byExtension(nil, "ini"), .text)
        XCTAssertEqual(byExtension(nil, "cfg"), .text)
        XCTAssertEqual(byExtension(nil, "conf"), .text)
    }

    func testTerminalLinkClassifierClassifiesDocumentContentTypes() {
        let byContentType = { (contentType: String) in SpacesDeviceTerminalLinkClassifier.artifactKind(contentType: contentType, pathExtension: nil) }
        XCTAssertEqual(byContentType("text/markdown"), .markdown)
        XCTAssertEqual(byContentType("text/html"), .html)
        XCTAssertEqual(byContentType("application/pdf"), .pdf)
        XCTAssertEqual(byContentType("application/json"), .text)
        XCTAssertEqual(byContentType("application/toml"), .text)
        XCTAssertEqual(byContentType("application/x-yaml"), .text)
        XCTAssertEqual(byContentType("application/yaml"), .text)
        XCTAssertEqual(byContentType("text/yaml"), .text)
        XCTAssertEqual(byContentType("text/toml"), .text)
        XCTAssertEqual(byContentType("text/csv"), .text)
        XCTAssertEqual(byContentType("text/tab-separated-values"), .text)
        XCTAssertEqual(byContentType("text/plain"), .text)
        XCTAssertEqual(byContentType("image/png"), .image)
        XCTAssertEqual(byContentType("video/mp4"), .video)
    }

    func testTerminalLinkClassifierRejectsSourceTextContentTypes() {
        let byContentType = { (contentType: String) in SpacesDeviceTerminalLinkClassifier.artifactKind(contentType: contentType, pathExtension: nil) }
        XCTAssertNil(byContentType("text/x-python-script"))
        XCTAssertNil(byContentType("text/javascript"))
        XCTAssertNil(byContentType("text/css"))
        XCTAssertNil(byContentType("text/x-swift"))
    }

    func testTerminalLinkClassifierRejectsNonPreviewableExtensions() {
        let byExtension = SpacesDeviceTerminalLinkClassifier.artifactKind
        XCTAssertNil(byExtension(nil, "swift"))
        XCTAssertNil(byExtension(nil, "py"))
        XCTAssertNil(byExtension(SpacesDeviceTerminalLinkClassifier.preferredContentType(pathExtension: "py"), "py"))
        XCTAssertNil(byExtension(SpacesDeviceTerminalLinkClassifier.preferredContentType(pathExtension: "js"), "js"))
        XCTAssertNil(byExtension(SpacesDeviceTerminalLinkClassifier.preferredContentType(pathExtension: "css"), "css"))
        XCTAssertNil(byExtension(nil, "svg"))
        XCTAssertNil(byExtension(nil, "mp3"))
        XCTAssertNil(byExtension(nil, nil))
    }

    func testTerminalLinkClassifierRejectsSVGContentTypes() {
        XCTAssertNil(SpacesDeviceTerminalLinkClassifier.artifactKind(contentType: "image/svg+xml", pathExtension: nil))
        XCTAssertNil(SpacesDeviceTerminalLinkClassifier.artifactKind(contentType: "image/svg+xml; charset=utf-8", pathExtension: nil))
        XCTAssertNil(
            SpacesDeviceTerminalLinkClassifier.artifactKind(
                contentType: SpacesDeviceTerminalLinkClassifier.preferredContentType(pathExtension: "svg"), pathExtension: "svg"))
    }

    func testTerminalLinkRouteClassifiesWebLoopbackAndFileLinks() {
        XCTAssertEqual(SpacesDeviceTerminalLinkClassifier.route(for: "https://example.com/docs"), .webURL(URL(string: "https://example.com/docs")!))
        XCTAssertEqual(SpacesDeviceTerminalLinkClassifier.route(for: "http://localhost:3000"), .loopbackURL(URL(string: "http://localhost:3000")!))
        XCTAssertEqual(
            SpacesDeviceTerminalLinkClassifier.route(for: "http://127.0.0.1:8080/path"), .loopbackURL(URL(string: "http://127.0.0.1:8080/path")!))
        XCTAssertEqual(SpacesDeviceTerminalLinkClassifier.route(for: "http://[::1]:9999"), .loopbackURL(URL(string: "http://[::1]:9999")!))
        XCTAssertEqual(SpacesDeviceTerminalLinkClassifier.route(for: "http://0.0.0.0:4000"), .loopbackURL(URL(string: "http://0.0.0.0:4000")!))
        XCTAssertEqual(SpacesDeviceTerminalLinkClassifier.route(for: "/abs/path.md"), .fileLink("/abs/path.md"))
        XCTAssertEqual(SpacesDeviceTerminalLinkClassifier.route(for: "~/x.md"), .fileLink("~/x.md"))
        XCTAssertEqual(SpacesDeviceTerminalLinkClassifier.route(for: "rel/path.md"), .fileLink("rel/path.md"))
        XCTAssertEqual(SpacesDeviceTerminalLinkClassifier.route(for: "file:///tmp/a.md"), .fileLink("file:///tmp/a.md"))
        XCTAssertNil(SpacesDeviceTerminalLinkClassifier.route(for: "mailto:x@y.z"))
        XCTAssertNil(SpacesDeviceTerminalLinkClassifier.route(for: ""))
        XCTAssertNil(SpacesDeviceTerminalLinkClassifier.route(for: "   "))
    }

    func testTerminalLinkRouteClassifiesSpacesTerminalDeepLinks() {
        XCTAssertEqual(
            SpacesDeviceTerminalLinkClassifier.route(for: "spaces://terminal/session-1"),
            .spacesTerminal(SpacesTerminalDeepLink(sessionID: "session-1")))
        XCTAssertEqual(
            SpacesDeviceTerminalLinkClassifier.route(for: "spaces://terminal/session-1?device=device-9"),
            .spacesTerminal(SpacesTerminalDeepLink(sessionID: "session-1", deviceID: "device-9")))
        // Malformed `spaces://` links (pairing host, missing or multi-segment path) are not routable.
        XCTAssertNil(SpacesDeviceTerminalLinkClassifier.route(for: "spaces://pair?code=abc"))
        XCTAssertNil(SpacesDeviceTerminalLinkClassifier.route(for: "spaces://terminal"))
        XCTAssertNil(SpacesDeviceTerminalLinkClassifier.route(for: "spaces://terminal/session-1/extra"))
    }

    func testTerminalLinkClassifierIsLoopbackHost() {
        XCTAssertTrue(SpacesDeviceTerminalLinkClassifier.isLoopbackHost("localhost"))
        XCTAssertTrue(SpacesDeviceTerminalLinkClassifier.isLoopbackHost("LOCALHOST"))
        XCTAssertTrue(SpacesDeviceTerminalLinkClassifier.isLoopbackHost("127.0.0.1"))
        XCTAssertTrue(SpacesDeviceTerminalLinkClassifier.isLoopbackHost("127.5.10.20"))
        XCTAssertTrue(SpacesDeviceTerminalLinkClassifier.isLoopbackHost("::1"))
        XCTAssertTrue(SpacesDeviceTerminalLinkClassifier.isLoopbackHost("0.0.0.0"))
        XCTAssertFalse(SpacesDeviceTerminalLinkClassifier.isLoopbackHost("dev.localhost.example.com"))
        XCTAssertFalse(SpacesDeviceTerminalLinkClassifier.isLoopbackHost("sub.localhost"))
        XCTAssertFalse(SpacesDeviceTerminalLinkClassifier.isLoopbackHost("example.com"))
        XCTAssertFalse(SpacesDeviceTerminalLinkClassifier.isLoopbackHost(nil))
    }

    func testWorkspaceTerminalRowRoundTripsStopAvailability() throws {
        let row = SpacesDeviceWorkspaceTerminalRow(
            id: "terminal-shell", workspaceID: "workspace-1", title: "shell", workingDirectory: "/repo", sessionID: "session-1", runState: .running,
            canOpenTerminal: true, canStop: true)
        let overview = SpacesDeviceOverviewPayload(
            workspaces: [
                SpacesDeviceWorkspaceSummary(
                    id: "workspace-1", projectID: "project-1", projectName: "Project", branch: nil, baseBranch: nil, dir: "/repo", isRunning: true,
                    isHidden: false, isDefault: false, sessionCount: 1, terminalRows: [row])
            ], sessions: [])

        let decoded = try SpacesDeviceAPICodec.decodeResponse(
            SpacesDeviceAPICodec.encodeResponse(SpacesDeviceAPIResponse(ok: true, message: "ok", result: .overview(overview))))

        XCTAssertEqual(decoded.overview?.workspaces.first?.terminalRows.first?.canStop, true)
    }

    func testTerminalLinkResolverResolvesRelativeAndHomeImageFiles() throws {
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let relativeImage = root.appendingPathComponent("image.png")
        let homeImage = root.appendingPathComponent("home-image.png")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: relativeImage)
        try Data([0x89, 0x50, 0x4E, 0x47, 0x02]).write(to: homeImage)

        let relativeMetadata = try SpacesDeviceTerminalLinkResolver.resolve(
            sessionID: "session-1", link: "image.png", workingDirectory: root.path, workspaceRoots: [root.path], homeDirectory: root.path)
        let homeMetadata = try SpacesDeviceTerminalLinkResolver.resolve(
            sessionID: "session-1", link: "~/home-image.png", workingDirectory: nil, workspaceRoots: [], homeDirectory: root.path)

        XCTAssertEqual(relativeMetadata.source, .localFile)
        XCTAssertEqual(relativeMetadata.displayName, "image.png")
        XCTAssertEqual(relativeMetadata.contentType, "image/png")
        XCTAssertEqual(relativeMetadata.artifactKind, .image)
        XCTAssertEqual(relativeMetadata.byteCount, 4)
        XCTAssertEqual(homeMetadata.displayName, "home-image.png")
        XCTAssertEqual(homeMetadata.byteCount, 5)
    }

    func testTerminalLinkResolverAllowsTmpImagePathsAfterSymlinkResolution() throws {
        let tmpImage = URL(fileURLWithPath: "/tmp", isDirectory: true).appendingPathComponent("\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: tmpImage) }
        let payload = Data([0x89, 0x50, 0x4E, 0x47, 0x01])
        try payload.write(to: tmpImage)

        let metadata = try SpacesDeviceTerminalLinkResolver.resolve(sessionID: "session-1", link: tmpImage.path, workingDirectory: nil)
        let chunk = try SpacesDeviceTerminalLinkResolver.readChunk(sessionID: "session-1", linkID: metadata.id, offset: 0, limit: 32)

        XCTAssertEqual(metadata.source, .localFile)
        XCTAssertEqual(metadata.displayName, tmpImage.lastPathComponent)
        XCTAssertEqual(metadata.artifactKind, .image)
        XCTAssertEqual(Data(base64Encoded: chunk.base64Data), payload)
        XCTAssertTrue(chunk.isFinal)
    }

    func testTerminalLinkResolverReadsLocalMediaFileWithSpaces() throws {
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let movie = root.appendingPathComponent("Screen Recording 2026-03-20 at 11.17.57 AM.mov")
        let payload = Data([0, 0, 0, 20, 0x66, 0x74, 0x79, 0x70, 0x71, 0x74, 0x20, 0x20, 1, 2, 3, 4])
        try payload.write(to: movie)

        let metadata = try SpacesDeviceTerminalLinkResolver.resolve(
            sessionID: "session-1", link: movie.path, workingDirectory: nil, workspaceRoots: [root.path], homeDirectory: root.path)
        let chunk = try SpacesDeviceTerminalLinkResolver.readChunk(
            sessionID: "session-1", linkID: metadata.id, offset: 0, limit: 32, workspaceRoots: [root.path], homeDirectory: root.path)

        XCTAssertEqual(metadata.source, .localFile)
        XCTAssertEqual(metadata.originalLink, movie.path)
        XCTAssertEqual(metadata.displayName, "Screen Recording 2026-03-20 at 11.17.57 AM.mov")
        XCTAssertEqual(metadata.contentType, "video/quicktime")
        XCTAssertEqual(metadata.artifactKind, .video)
        XCTAssertEqual(metadata.byteCount, Int64(payload.count))
        XCTAssertEqual(Data(base64Encoded: chunk.base64Data), payload)
        XCTAssertTrue(chunk.isFinal)
    }

    func testTerminalLinkResolverReadsLocalMediaFileWithMacNoBreakSpace() throws {
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let movieName = "Screen Recording 2026-05-07 at 10.11.01\u{202F}AM.mov"
        let movie = root.appendingPathComponent(movieName)
        let payload = Data([0, 0, 0, 20, 0x66, 0x74, 0x79, 0x70, 0x71, 0x74, 0x20, 0x20, 1, 2, 3, 4])
        try payload.write(to: movie)

        let metadata = try SpacesDeviceTerminalLinkResolver.resolve(
            sessionID: "session-1", link: movie.path, workingDirectory: nil, workspaceRoots: [root.path], homeDirectory: root.path)
        let chunk = try SpacesDeviceTerminalLinkResolver.readChunk(
            sessionID: "session-1", linkID: metadata.id, offset: 0, limit: 32, workspaceRoots: [root.path], homeDirectory: root.path)

        XCTAssertEqual(metadata.source, .localFile)
        XCTAssertEqual(metadata.originalLink, movie.path)
        XCTAssertEqual(metadata.displayName, movieName)
        XCTAssertEqual(metadata.contentType, "video/quicktime")
        XCTAssertEqual(metadata.artifactKind, .video)
        XCTAssertEqual(metadata.byteCount, Int64(payload.count))
        XCTAssertEqual(Data(base64Encoded: chunk.base64Data), payload)
        XCTAssertTrue(chunk.isFinal)
    }

    func testTerminalLinkResolverRejectsRemoteFileURLHosts() throws {
        let tmpImage = URL(fileURLWithPath: "/tmp", isDirectory: true).appendingPathComponent("\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: tmpImage) }
        try Data([0x89, 0x50, 0x4E, 0x47, 0x01]).write(to: tmpImage)

        let localhostMetadata = try SpacesDeviceTerminalLinkResolver.resolve(
            sessionID: "session-1", link: "file://localhost\(tmpImage.path)", workingDirectory: nil)
        XCTAssertEqual(localhostMetadata.source, .localFile)
        XCTAssertEqual(localhostMetadata.displayName, tmpImage.lastPathComponent)

        XCTAssertThrowsError(
            try SpacesDeviceTerminalLinkResolver.resolve(sessionID: "session-1", link: "file://build-host\(tmpImage.path)", workingDirectory: nil)
        ) { error in XCTAssertEqual(error as? SpacesDeviceTerminalLinkResolverError, .unsupportedFileURLHost("build-host")) }
    }

    func testTerminalLinkResolverClassifiesExternalURLsWithoutTransfer() throws {
        let image = try SpacesDeviceTerminalLinkResolver.resolve(
            sessionID: "session-1", link: "https://example.com/screenshot.png", workingDirectory: nil)
        let cleartextImage = try SpacesDeviceTerminalLinkResolver.resolve(
            sessionID: "session-1", link: "http://example.com/screenshot.png", workingDirectory: nil)
        let audio = try SpacesDeviceTerminalLinkResolver.resolve(sessionID: "session-1", link: "https://example.com/sound.mp3", workingDirectory: nil)
        let page = try SpacesDeviceTerminalLinkResolver.resolve(sessionID: "session-1", link: "https://example.com/docs", workingDirectory: nil)

        XCTAssertEqual(image.source, .externalURL)
        XCTAssertEqual(image.artifactKind, .image)
        XCTAssertEqual(image.contentType, "image/png")
        XCTAssertEqual(image.externalURL, "https://example.com/screenshot.png")
        XCTAssertEqual(cleartextImage.source, .externalURL)
        XCTAssertNil(cleartextImage.contentType)
        XCTAssertNil(cleartextImage.artifactKind)
        XCTAssertEqual(cleartextImage.externalURL, "http://example.com/screenshot.png")
        XCTAssertEqual(audio.source, .externalURL)
        XCTAssertEqual(audio.contentType, "audio/mpeg")
        XCTAssertNil(audio.artifactKind)
        XCTAssertEqual(page.source, .externalURL)
        XCTAssertNil(page.artifactKind)
    }

    func testTerminalLinkResolverRejectsBlockedAndUnsupportedArtifactPaths() throws {
        XCTAssertThrowsError(
            try SpacesDeviceTerminalLinkResolver.resolve(sessionID: "session-1", link: "/System/Library/CoreServices", workingDirectory: nil)
        ) { error in XCTAssertEqual(error as? SpacesDeviceTerminalLinkResolverError, .blockedPath("/System/Library/CoreServices")) }

        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let blockedSymlink = root.appendingPathComponent("system-link.png")
        try FileManager.default.createSymbolicLink(at: blockedSymlink, withDestinationURL: URL(fileURLWithPath: "/System"))
        // .swift is source code, not one of the previewable artifact kinds, so it stays unsupported
        // even though .txt (a sibling plain-text extension) now classifies as `.text`.
        let sourceFile = root.appendingPathComponent("notes.swift")
        let audioFile = root.appendingPathComponent("sound.mp3")
        try Data("not previewable".utf8).write(to: sourceFile)
        try Data([0x49, 0x44, 0x33]).write(to: audioFile)

        XCTAssertThrowsError(
            try SpacesDeviceTerminalLinkResolver.resolve(
                sessionID: "session-1", link: blockedSymlink.path, workingDirectory: nil, workspaceRoots: [root.path], homeDirectory: root.path)
        ) { error in XCTAssertEqual(error as? SpacesDeviceTerminalLinkResolverError, .blockedPath("/System")) }

        XCTAssertThrowsError(
            try SpacesDeviceTerminalLinkResolver.resolve(
                sessionID: "session-1", link: sourceFile.path, workingDirectory: nil, workspaceRoots: [root.path], homeDirectory: root.path)
        ) { error in XCTAssertEqual(error as? SpacesDeviceTerminalLinkResolverError, .unsupportedArtifact) }

        XCTAssertThrowsError(
            try SpacesDeviceTerminalLinkResolver.resolve(
                sessionID: "session-1", link: audioFile.path, workingDirectory: nil, workspaceRoots: [root.path], homeDirectory: root.path)
        ) { error in XCTAssertEqual(error as? SpacesDeviceTerminalLinkResolverError, .unsupportedArtifact) }
    }

    func testTerminalLinkResolverReadsLocalMediaInChunksAndChecksSession() throws {
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let image = root.appendingPathComponent("chunked.png")
        let bytes = Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3, 4, 5])
        try bytes.write(to: image)
        let metadata = try SpacesDeviceTerminalLinkResolver.resolve(
            sessionID: "session-1", link: image.path, workingDirectory: nil, workspaceRoots: [root.path], homeDirectory: root.path)

        let first = try SpacesDeviceTerminalLinkResolver.readChunk(
            sessionID: "session-1", linkID: metadata.id, offset: 0, limit: 4, workspaceRoots: [root.path], homeDirectory: root.path)
        let second = try SpacesDeviceTerminalLinkResolver.readChunk(
            sessionID: "session-1", linkID: metadata.id, offset: 4, limit: 20, workspaceRoots: [root.path], homeDirectory: root.path)

        XCTAssertEqual(Data(base64Encoded: first.base64Data), bytes.prefix(4))
        XCTAssertFalse(first.isFinal)
        XCTAssertEqual(Data(base64Encoded: second.base64Data), bytes.dropFirst(4))
        XCTAssertTrue(second.isFinal)
        XCTAssertThrowsError(
            try SpacesDeviceTerminalLinkResolver.readChunk(
                sessionID: "other-session", linkID: metadata.id, offset: 0, limit: 4, workspaceRoots: [root.path], homeDirectory: root.path)
        ) { error in XCTAssertEqual(error as? SpacesDeviceTerminalLinkResolverError, .sessionMismatch) }
    }

    func testTerminalLinkResolverResolvesDocumentFixtureFiles() throws {
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let markdown = root.appendingPathComponent("README.md")
        let json = root.appendingPathComponent("data.json")
        let html = root.appendingPathComponent("page.html")
        let pdf = root.appendingPathComponent("doc.pdf")
        try Data("# Title".utf8).write(to: markdown)
        try Data("{}".utf8).write(to: json)
        try Data("<html></html>".utf8).write(to: html)
        try Data("%PDF-1.4".utf8).write(to: pdf)

        let markdownMetadata = try SpacesDeviceTerminalLinkResolver.resolve(
            sessionID: "session-1", link: markdown.path, workingDirectory: nil, workspaceRoots: [root.path], homeDirectory: root.path)
        let jsonMetadata = try SpacesDeviceTerminalLinkResolver.resolve(
            sessionID: "session-1", link: json.path, workingDirectory: nil, workspaceRoots: [root.path], homeDirectory: root.path)
        let htmlMetadata = try SpacesDeviceTerminalLinkResolver.resolve(
            sessionID: "session-1", link: html.path, workingDirectory: nil, workspaceRoots: [root.path], homeDirectory: root.path)
        let pdfMetadata = try SpacesDeviceTerminalLinkResolver.resolve(
            sessionID: "session-1", link: pdf.path, workingDirectory: nil, workspaceRoots: [root.path], homeDirectory: root.path)

        XCTAssertEqual(markdownMetadata.artifactKind, .markdown)
        XCTAssertEqual(jsonMetadata.artifactKind, .text)
        XCTAssertEqual(htmlMetadata.artifactKind, .html)
        XCTAssertEqual(pdfMetadata.artifactKind, .pdf)
    }

    func testTerminalLinkResolverLinkIDPayloadUsesRenamedArtifactKindField() throws {
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let markdown = root.appendingPathComponent("notes.md")
        try Data("notes".utf8).write(to: markdown)

        let metadata = try SpacesDeviceTerminalLinkResolver.resolve(
            sessionID: "session-1", link: markdown.path, workingDirectory: nil, workspaceRoots: [root.path], homeDirectory: root.path)

        var base64 = metadata.id.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        let payloadData = try XCTUnwrap(Data(base64Encoded: base64))
        let payloadJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: payloadData) as? [String: Any])

        XCTAssertEqual(payloadJSON["artifactKind"] as? String, "markdown")
        XCTAssertNil(payloadJSON["mediaKind"])
    }

    func testTerminalLinkResolverLinkIDChangesWhenSameSizeFileChanges() throws {
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let text = root.appendingPathComponent("same-size.txt")
        let firstModificationDate = Date(timeIntervalSince1970: 1_700_000_000)
        let secondModificationDate = Date(timeIntervalSince1970: 1_700_000_010)

        try Data("first".utf8).write(to: text)
        try FileManager.default.setAttributes([.modificationDate: firstModificationDate], ofItemAtPath: text.path)
        let firstMetadata = try SpacesDeviceTerminalLinkResolver.resolve(
            sessionID: "session-1", link: text.path, workingDirectory: nil, workspaceRoots: [root.path], homeDirectory: root.path)

        try Data("other".utf8).write(to: text)
        try FileManager.default.setAttributes([.modificationDate: secondModificationDate], ofItemAtPath: text.path)
        let secondMetadata = try SpacesDeviceTerminalLinkResolver.resolve(
            sessionID: "session-1", link: text.path, workingDirectory: nil, workspaceRoots: [root.path], homeDirectory: root.path)

        XCTAssertEqual(firstMetadata.byteCount, secondMetadata.byteCount)
        XCTAssertNotEqual(firstMetadata.id, secondMetadata.id)
        XCTAssertThrowsError(
            try SpacesDeviceTerminalLinkResolver.readChunk(
                sessionID: "session-1", linkID: firstMetadata.id, offset: 0, limit: 32, workspaceRoots: [root.path], homeDirectory: root.path)
        ) { error in XCTAssertEqual(error as? SpacesDeviceTerminalLinkResolverError, .fileChanged) }
    }

    func testTerminalLinkResolverReadsChunkOfTextFile() throws {
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let text = root.appendingPathComponent("log.txt")
        let payload = Data("line one\nline two\n".utf8)
        try payload.write(to: text)

        let metadata = try SpacesDeviceTerminalLinkResolver.resolve(
            sessionID: "session-1", link: text.path, workingDirectory: nil, workspaceRoots: [root.path], homeDirectory: root.path)
        let chunk = try SpacesDeviceTerminalLinkResolver.readChunk(
            sessionID: "session-1", linkID: metadata.id, offset: 0, limit: 32, workspaceRoots: [root.path], homeDirectory: root.path)

        XCTAssertEqual(metadata.artifactKind, .text)
        XCTAssertEqual(Data(base64Encoded: chunk.base64Data), payload)
        XCTAssertTrue(chunk.isFinal)
    }

    func testTerminalLinkResolverRequiresWorkingDirectoryOnlyForRelativeLocalFileLinks() throws {
        XCTAssertFalse(SpacesDeviceTerminalLinkResolver.requiresWorkingDirectory(link: "/tmp/screenshot.png"))
        XCTAssertFalse(SpacesDeviceTerminalLinkResolver.requiresWorkingDirectory(link: "~"))
        XCTAssertFalse(SpacesDeviceTerminalLinkResolver.requiresWorkingDirectory(link: "~/screenshot.png"))
        XCTAssertFalse(SpacesDeviceTerminalLinkResolver.requiresWorkingDirectory(link: "file:///tmp/screenshot.png"))
        XCTAssertFalse(SpacesDeviceTerminalLinkResolver.requiresWorkingDirectory(link: "https://example.com/screenshot.png"))
        XCTAssertFalse(SpacesDeviceTerminalLinkResolver.requiresWorkingDirectory(link: nil))
        XCTAssertFalse(SpacesDeviceTerminalLinkResolver.requiresWorkingDirectory(link: "   "))

        XCTAssertTrue(SpacesDeviceTerminalLinkResolver.requiresWorkingDirectory(link: "screenshot.png"))
        XCTAssertTrue(SpacesDeviceTerminalLinkResolver.requiresWorkingDirectory(link: "src/screenshot.png"))
    }

}
