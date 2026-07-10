import XCTest
import spacesterminalcore

@testable import spacesdeviceapi
@testable import spacesdevicecore

final class SpacesDeviceAPIProtocolTests: XCTestCase {
    func testWireProtocolVersionCoversAgentHooksCommands() {
        XCTAssertGreaterThanOrEqual(SpacesWireProtocol.version, 2)
    }

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
        let request = SpacesDeviceAPIRequest(
            command: .installAgentHooks(.init(kinds: [.claudeCode, .opencode])), authToken: "SECRET")
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
            ],
            failures: [AgentHookInstallFailure(kind: .codex, message: "config.toml already defines `features`.")])
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

    func testDeviceOverviewStreamCodecRoundTripsPayload() throws {
        let payload = SpacesDeviceOverviewPayload(workspaces: [], sessions: [])
        let line = try SpacesDeviceOverviewStreamCodec.encodeLine(payload)
        XCTAssertEqual(line.last, 0x0A)
        XCTAssertEqual(try SpacesDeviceOverviewStreamCodec.decodeLine(line.dropLast()), payload)
    }

    func testTerminalControlRequestsAreNotReplaySafeAfterAmbiguousConnectionFailure() throws {
        let request = SpacesDeviceAPIRequest(
            command: .terminalControl(.init(action: .send, sessionID: "session-1", clientID: "client-1", text: "a")), authToken: "SECRET")

        XCTAssertFalse(request.isSafeToReplayAfterConnectionFailure)
    }

    func testReadOnlyRequestsAreReplaySafeAfterAmbiguousConnectionFailure() throws {
        let requests = [
            SpacesDeviceAPIRequest(command: .ping, authToken: "SECRET"), SpacesDeviceAPIRequest(command: .overview, authToken: "SECRET"),
            SpacesDeviceAPIRequest(command: .workspaceCreateOptions(.init(projectID: "project-1")), authToken: "SECRET"),
            SpacesDeviceAPIRequest(command: .state(.init(sessionID: "session-1")), authToken: "SECRET"),
            SpacesDeviceAPIRequest(command: .resolveTerminalLink(.init(sessionID: "session-1", terminalLink: "file:///tmp/a")), authToken: "SECRET"),
            SpacesDeviceAPIRequest(
                command: .readTerminalLinkChunk(.init(sessionID: "session-1", terminalLinkID: "link-1", offset: 0, limit: 128)), authToken: "SECRET"),
        ]

        for request in requests { XCTAssertTrue(request.isSafeToReplayAfterConnectionFailure, request.commandName) }
    }

    func testMutatingRequestsAreNotReplaySafeAfterAmbiguousConnectionFailure() throws {
        let requests = [
            SpacesDeviceAPIRequest(command: .openWorkspaceTerminal(.init(workspaceID: "workspace-1")), authToken: "SECRET"),
            SpacesDeviceAPIRequest(command: .stopWorkspaceTerminal(.init(workspaceID: "workspace-1", sessionID: "session-1")), authToken: "SECRET"),
            SpacesDeviceAPIRequest(
                command: .runWorkspaceProcess(.init(workspaceID: "workspace-1", processKey: "api", processTemplateID: "template-1")),
                authToken: "SECRET"),
            SpacesDeviceAPIRequest(
                command: .runCodingAgent(.init(workspaceID: "workspace-1", agentName: "Codex", agentLauncherID: "launcher-1")), authToken: "SECRET"),
        ]

        for request in requests { XCTAssertFalse(request.isSafeToReplayAfterConnectionFailure, request.commandName) }
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
                    scrollMods: 7)), authToken: "SECRET")

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
                command: .runWorkspaceProcess(.init(workspaceID: "workspace-1", processKey: "api", processTemplateID: "template-1")),
                authToken: "SECRET"),
            SpacesDeviceAPIRequest(
                command: .restartWorkspaceProcess(
                    .init(workspaceID: "workspace-1", processID: "process-1", processKey: "api", processTemplateID: "template-1")),
                authToken: "SECRET"),
            SpacesDeviceAPIRequest(
                command: .restartCodingAgent(
                    .init(workspaceID: "workspace-1", agentID: "agent-1", agentName: "Codex", agentLauncherID: "launcher-1")), authToken: "SECRET"),
        ]

        for request in requests { XCTAssertEqual(try SpacesDeviceAPICodec.decodeRequest(SpacesDeviceAPICodec.encodeRequest(request)), request) }
    }

    func testOverviewRoundTripsRuntimeRowsAndSessionSummary() throws {
        let processRow = SpacesDeviceWorkspaceProcessRow(
            id: "process-1", workspaceID: "workspace-1", name: "API", command: "npm run dev", processID: "runtime-1", sessionID: "session-1",
            runState: .running, canRun: false, canStop: true, canRestart: true)
        let agentRow = SpacesDeviceWorkspaceCodingAgentRow(
            id: "agent-1", workspaceID: "workspace-1", name: "Codex", command: "codex", agentID: "agent-runtime-1", sessionID: "session-2",
            isConfigured: true, runState: .running, activityState: .spinning, canRun: false, canStop: true, canRestart: true)
        let terminalRow = SpacesDeviceWorkspaceTerminalRow(
            id: "terminal-1", workspaceID: "workspace-1", title: "Shell", workingDirectory: "/repo", sessionID: "session-3", runState: .running,
            canOpenTerminal: true, canStop: true)
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
                    isArchived: false, isHidden: false, isDefault: false, sessionCount: 1, processRows: [processRow], codingAgentRows: [agentRow],
                    terminalRows: [terminalRow])
            ], sessions: [session])

        let decoded = try SpacesDeviceAPICodec.decodeResponse(
            SpacesDeviceAPICodec.encodeResponse(SpacesDeviceAPIResponse(ok: true, message: "ok", result: .overview(overview))))
        XCTAssertEqual(decoded.overview?.workspaces.first?.processRows.first, processRow)
        XCTAssertEqual(decoded.overview?.workspaces.first?.codingAgentRows.first, agentRow)
        XCTAssertEqual(decoded.overview?.workspaces.first?.terminalRows.first, terminalRow)
        XCTAssertEqual(decoded.overview?.sessions.first?.shell, "/bin/zsh")
        XCTAssertEqual(decoded.overview?.sessions.first?.command, "npm run dev")
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
            mediaKind: .image, byteCount: 12, externalURL: nil)
        let chunk = SpacesDeviceTerminalLinkChunk(
            linkID: "link-1", offset: 0, byteCount: 4, isFinal: false, base64Data: Data([1, 2, 3, 4]).base64EncodedString())
        let metadataResponse = SpacesDeviceAPIResponse(ok: true, message: "ok", result: .terminalLinkMetadata(metadata))
        let chunkResponse = SpacesDeviceAPIResponse(ok: true, message: "ok", result: .terminalLinkChunk(chunk))

        XCTAssertEqual(try SpacesDeviceAPICodec.decodeResponse(SpacesDeviceAPICodec.encodeResponse(metadataResponse)), metadataResponse)
        XCTAssertEqual(try SpacesDeviceAPICodec.decodeResponse(SpacesDeviceAPICodec.encodeResponse(chunkResponse)), chunkResponse)
    }

    func testTerminalLinkClassifierRejectsAudioMediaTypes() {
        XCTAssertEqual(SpacesDeviceTerminalLinkClassifier.mediaKind(contentType: nil, pathExtension: "mp4"), .video)
        XCTAssertEqual(SpacesDeviceTerminalLinkClassifier.mediaKind(contentType: nil, pathExtension: "png"), .image)
        XCTAssertNil(SpacesDeviceTerminalLinkClassifier.mediaKind(contentType: "audio/mpeg", pathExtension: nil))
        XCTAssertNil(SpacesDeviceTerminalLinkClassifier.mediaKind(contentType: nil, pathExtension: "mp3"))
        XCTAssertNil(SpacesDeviceTerminalLinkClassifier.mediaKind(contentType: "audio/wav", pathExtension: "wav"))
    }

    func testWorkspaceTerminalRowRoundTripsStopAvailability() throws {
        let row = SpacesDeviceWorkspaceTerminalRow(
            id: "terminal-shell", workspaceID: "workspace-1", title: "shell", workingDirectory: "/repo", sessionID: "session-1", runState: .running,
            canOpenTerminal: true, canStop: true)
        let overview = SpacesDeviceOverviewPayload(
            workspaces: [
                SpacesDeviceWorkspaceSummary(
                    id: "workspace-1", projectID: "project-1", projectName: "Project", branch: nil, baseBranch: nil, dir: "/repo", isRunning: true,
                    isArchived: false, isHidden: false, isDefault: false, sessionCount: 1, terminalRows: [row])
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
        XCTAssertEqual(relativeMetadata.mediaKind, .image)
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
        XCTAssertEqual(metadata.mediaKind, .image)
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
        XCTAssertEqual(metadata.mediaKind, .video)
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
        XCTAssertEqual(metadata.mediaKind, .video)
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
        XCTAssertEqual(image.mediaKind, .image)
        XCTAssertEqual(image.contentType, "image/png")
        XCTAssertEqual(image.externalURL, "https://example.com/screenshot.png")
        XCTAssertEqual(cleartextImage.source, .externalURL)
        XCTAssertNil(cleartextImage.contentType)
        XCTAssertNil(cleartextImage.mediaKind)
        XCTAssertEqual(cleartextImage.externalURL, "http://example.com/screenshot.png")
        XCTAssertEqual(audio.source, .externalURL)
        XCTAssertEqual(audio.contentType, "audio/mpeg")
        XCTAssertNil(audio.mediaKind)
        XCTAssertEqual(page.source, .externalURL)
        XCTAssertNil(page.mediaKind)
    }

    func testTerminalLinkResolverRejectsBlockedAndNonMediaPaths() throws {
        XCTAssertThrowsError(
            try SpacesDeviceTerminalLinkResolver.resolve(sessionID: "session-1", link: "/System/Library/CoreServices", workingDirectory: nil)
        ) { error in XCTAssertEqual(error as? SpacesDeviceTerminalLinkResolverError, .blockedPath("/System/Library/CoreServices")) }

        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let blockedSymlink = root.appendingPathComponent("system-link.png")
        try FileManager.default.createSymbolicLink(at: blockedSymlink, withDestinationURL: URL(fileURLWithPath: "/System"))
        let textFile = root.appendingPathComponent("notes.txt")
        let audioFile = root.appendingPathComponent("sound.mp3")
        try Data("not media".utf8).write(to: textFile)
        try Data([0x49, 0x44, 0x33]).write(to: audioFile)

        XCTAssertThrowsError(
            try SpacesDeviceTerminalLinkResolver.resolve(
                sessionID: "session-1", link: blockedSymlink.path, workingDirectory: nil, workspaceRoots: [root.path], homeDirectory: root.path)
        ) { error in XCTAssertEqual(error as? SpacesDeviceTerminalLinkResolverError, .blockedPath("/System")) }

        XCTAssertThrowsError(
            try SpacesDeviceTerminalLinkResolver.resolve(
                sessionID: "session-1", link: textFile.path, workingDirectory: nil, workspaceRoots: [root.path], homeDirectory: root.path)
        ) { error in XCTAssertEqual(error as? SpacesDeviceTerminalLinkResolverError, .unsupportedMedia) }

        XCTAssertThrowsError(
            try SpacesDeviceTerminalLinkResolver.resolve(
                sessionID: "session-1", link: audioFile.path, workingDirectory: nil, workspaceRoots: [root.path], homeDirectory: root.path)
        ) { error in XCTAssertEqual(error as? SpacesDeviceTerminalLinkResolverError, .unsupportedMedia) }
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

}
