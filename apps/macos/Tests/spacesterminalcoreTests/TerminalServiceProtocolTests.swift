import Dispatch
import Foundation
import XCTest

@testable import spacesterminalcore

#if canImport(Network)
    import Network
#endif

final class TerminalServiceProtocolTests: XCTestCase {
    func testRequestAndResponseRoundTripThroughCodec() throws {
        let launchConfiguration = TerminalSessionLaunchConfiguration(
            sessionID: "session-1", backend: .ghosttyEmbedded, lifetimePolicy: .whileAttached, title: "shell", workingDirectory: "/tmp/work",
            shell: "/bin/zsh", command: "cat", createdAt: "2026-05-17T00:00:00Z", workspaceID: "workspace-1", kind: .shell)
        let manifest = TerminalServiceWorkspaceRuntimeManifest(
            workspaceID: "workspace-1", projectID: "project-1", deviceID: "host-1", location: .remote, localPath: "/local/work",
            remotePath: "/srv/work", branch: "feature", baseBranch: "main", gitRemoteURL: "git@example.com:repo.git",
            namedPorts: [TerminalServiceWorkspaceRuntimePortMapping(id: "api", name: "API_PORT", port: 3000)],
            processEnvironment: ["SPACES_WORKSPACE_ID": "workspace-1"], allowedFileRoots: ["/srv/work"])
        let refresh = TerminalServiceWorktreeRefreshRequest(path: "/srv/work", branch: "feature", hostName: "Builder")
        let workspaceCommand = TerminalServiceWorkspaceCommandRequest(command: "true", workingDirectory: "/srv/work")
        let controlRequest = TerminalControlRequest(command: "send", text: "hello", clientID: "ios-client", ownerEpoch: 7)
        let agentSignal = TerminalServiceAgentSignalEvent(
            id: "event-1", sessionID: "session-1", workspaceID: "workspace-1", workspacePath: "/srv/work", type: "blocked", label: "Mock Agent",
            terminalTrackingID: "session-1", environmentKeys: ["SPACES_TERMINAL_TRACKING_ID"], createdAt: "2026-06-11T00:00:00Z")
        let profileCommand = TerminalServiceProfileCommand.workspaceCreate(
            .init(projectID: "project-1", branch: "feature", baseBranch: "main", existingBranch: true))
        let requests = [
            TerminalServiceRequest(command: .ping),
            TerminalServiceRequest(
                command: .create(.init(launchConfiguration: launchConfiguration, runtimeManifest: manifest, worktreeRefresh: refresh)),
                authToken: "SECRET"),
            TerminalServiceRequest(
                command: .runWorkspaceCommand(.init(runtimeManifest: manifest, worktreeRefresh: refresh, workspaceCommand: workspaceCommand))),
            TerminalServiceRequest(command: .control(.init(sessionID: "session-1", controlRequest: controlRequest))),
            TerminalServiceRequest(command: .resolveTerminalLink(.init(sessionID: "session-1", terminalLink: "image.png"))),
            TerminalServiceRequest(
                command: .readTerminalLinkChunk(.init(sessionID: "session-1", terminalLinkID: "link-1", offset: 128, limit: 4096))),
            TerminalServiceRequest(command: .agentSignal(.init(event: agentSignal))),
            TerminalServiceRequest(command: .ackAgentSignals(.init(sessionID: "session-1", eventIDs: ["event-1"]))),
            TerminalServiceRequest(command: .profileCommand(profileCommand)),
        ]
        let response = TerminalServiceResponse(
            ok: true, message: "Started.",
            session: TerminalServiceSessionSummary(
                id: "session-1", title: "shell", workingDirectory: "/tmp/work", backend: .ghosttyEmbedded, lifetimePolicy: .whileAttached,
                state: .running, servicePID: 123, childPID: 456, controlSocketPath: "/tmp/control.sock", outputPath: "/tmp/output.log"),
            commandResult: TerminalServiceCommandResult(exitCode: 0, logPath: "/tmp/setup.log"),
            controlResponse: TerminalControlResponse(ok: true, message: "sent"),
            terminalLinkMetadata: TerminalServiceTerminalLinkMetadata(
                id: "link-1", source: "localFile", originalLink: "image.png", displayName: "image.png", contentType: "image/png",
                artifactKind: "image", byteCount: 12, externalURL: nil),
            terminalLinkChunk: TerminalServiceTerminalLinkChunk(
                linkID: "link-1", offset: 0, byteCount: 4, isFinal: true, base64Data: Data([1, 2, 3, 4]).base64EncodedString()),
            agentSignals: [
                TerminalServiceAgentSignalEvent(
                    id: "event-1", sessionID: "session-1", workspaceID: "workspace-1", workspacePath: "/srv/work", type: "blocked",
                    label: "Mock Agent", terminalTrackingID: "session-1", environmentKeys: ["SPACES_TERMINAL_TRACKING_ID"],
                    createdAt: "2026-06-11T00:00:00Z")
            ],
            profile: TerminalServiceProfileCommandResponse(
                message: "Created workspace.",
                workspace: TerminalServiceProfileWorkspaceRecord(
                    id: "workspace-1", projectID: "project-1", dir: "/srv/work", dirname: "feature", branch: "feature", baseBranch: "main",
                    isDefault: false, isHidden: false, isRunning: false, lastLaunchedAt: nil, notes: nil), terminalOutput: "recent output"),
            daemonStatus: TerminalServiceDaemonStatus(
                version: "1.2.3", installedVersion: "1.2.3", certificateFingerprint: "SHA256:abcdef", activeSessionCount: 2))

        for request in requests { XCTAssertEqual(try TerminalServiceCodec.decodeRequest(TerminalServiceCodec.encodeRequest(request)), request) }
        XCTAssertEqual(try TerminalServiceCodec.decodeResponse(TerminalServiceCodec.encodeResponse(response)), response)
    }

    func testApplyStagedUpdateCommandRoundTripsThroughCodec() throws {
        let request = TerminalServiceRequest(command: .applyStagedUpdate)
        XCTAssertEqual(try TerminalServiceCodec.decodeRequest(TerminalServiceCodec.encodeRequest(request)), request)
        XCTAssertEqual(request.commandName, "applyStagedUpdate")
    }

    func testApplyStagedUpdateDecodesFromFrozenRawJSON() throws {
        // Frozen shape — never change. A same-or-older bundled CLI/installer sends exactly this bytes
        // to any future daemon to trigger an exec-in-place staged-update handoff, so the daemon must
        // keep decoding this literal request forever.
        let json = Data(#"{"command":{"applyStagedUpdate":{}}}"#.utf8)
        XCTAssertEqual(try TerminalServiceCodec.decodeRequest(json).command, .applyStagedUpdate)
    }

    func testRequestDecodeRejectsAmbiguousCommandPayloads() {
        let emptyCommand = #"{"command":{}}"#.data(using: .utf8)!
        let multipleCommands = #"{"command":{"ping":{},"list":{}}}"#.data(using: .utf8)!

        XCTAssertThrowsError(try TerminalServiceCodec.decodeRequest(emptyCommand))
        XCTAssertThrowsError(try TerminalServiceCodec.decodeRequest(multipleCommands))
    }

    func testResponseErrorCodeEncodesWhenSetAndIsAbsentWhenNil() throws {
        let failure = TerminalServiceResponse(ok: false, message: "Unauthorized spacesd client.", errorCode: .unauthorized)
        let failureData = try TerminalServiceCodec.encodeResponse(failure)
        XCTAssertTrue(String(decoding: failureData, as: UTF8.self).contains(#""errorCode":"unauthorized""#))
        XCTAssertEqual(try TerminalServiceCodec.decodeResponse(failureData), failure)

        let success = TerminalServiceResponse(ok: true, message: "pong")
        let successData = try TerminalServiceCodec.encodeResponse(success)
        XCTAssertFalse(String(decoding: successData, as: UTF8.self).contains("errorCode"))
        XCTAssertNil(try TerminalServiceCodec.decodeResponse(successData).errorCode)
    }

    func testProfileCommandResponseCarriesStructuredAgentSpawnResult() throws {
        // The spawn command response carries the structured outcome (the MCP tool encodes this response
        // as its result), so a client reads the session id / detected agent / subscribed flag from fields
        // instead of parsing the prose message.
        let response = TerminalServiceProfileCommandResponse(
            message: "Started agent session term-9 (detected codex).",
            agentSpawn: TerminalServiceAgentSpawnResult(
                terminalSessionID: "term-9", workspaceID: "workspace-1", detectedAgent: "codex", deviceID: nil, subscribed: false,
                open: "spaces://terminal/term-9"))
        let encoded = try TerminalServiceCodec.encodeResponse(TerminalServiceResponse(ok: true, message: "ok", profile: response))
        let json = String(decoding: encoded, as: UTF8.self)
        XCTAssertTrue(json.contains(#""terminalSessionID":"term-9""#))
        XCTAssertTrue(json.contains(#""detectedAgent":"codex""#))
        XCTAssertTrue(json.contains(#""subscribed":false"#))
        // JSONEncoder escapes forward slashes by default, so the deep link reads back with `\/`.
        XCTAssertTrue(json.contains(#""open":"spaces:\/\/terminal\/term-9""#))
        XCTAssertEqual(try TerminalServiceCodec.decodeResponse(encoded).profile, response)

        // A response without a spawn outcome omits the field entirely.
        let plain = try TerminalServiceCodec.encodeResponse(
            TerminalServiceResponse(ok: true, message: "ok", profile: TerminalServiceProfileCommandResponse(message: "Listed.")))
        XCTAssertFalse(String(decoding: plain, as: UTF8.self).contains("agentSpawn"))
    }

    func testProfileCommandResponseCarriesPendingAgentEvents() throws {
        // The MCP tools/call chokepoint attaches a busy orchestrator's drained child events to the tool
        // result, so a client reads them from `pendingAgentEvents` — the busy-time counterpart to idle
        // injection. The field is present only when the piggyback drained a row, and omitted otherwise.
        let response = TerminalServiceProfileCommandResponse(message: "Listed agent sessions.").addingPendingAgentEvents([
            "[spaces] A (claude) is blocked", "[spaces] B (codex) is done",
        ])
        let encoded = try JSONEncoder().encode(response)
        let json = String(decoding: encoded, as: UTF8.self)
        XCTAssertTrue(json.contains(#""pendingAgentEvents""#))
        XCTAssertTrue(json.contains(#""[spaces] A (claude) is blocked""#))
        XCTAssertEqual(try JSONDecoder().decode(TerminalServiceProfileCommandResponse.self, from: encoded), response)

        // Nothing to attach leaves the response unchanged and the field omitted (nil or empty alike).
        for events: [String]? in [nil, []] {
            let plain = try JSONEncoder().encode(TerminalServiceProfileCommandResponse(message: "Listed.").addingPendingAgentEvents(events))
            XCTAssertFalse(String(decoding: plain, as: UTF8.self).contains("pendingAgentEvents"))
        }
    }

    func testResponseDecodesNilErrorCodeWhenAbsentFromJSON() throws {
        let json = #"{"ok":false,"message":"Terminal session 'abc' is not running."}"#.data(using: .utf8)!
        XCTAssertNil(try TerminalServiceCodec.decodeResponse(json).errorCode)
    }

    func testTerminalControlResponseErrorCodeRoundTrips() throws {
        let response = TerminalControlResponse(ok: false, message: "Only the active owner can send input.", errorCode: .ownershipRejected)
        let data = try JSONEncoder().encode(response)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains(#""errorCode":"ownershipRejected""#))
        XCTAssertEqual(try JSONDecoder().decode(TerminalControlResponse.self, from: data), response)

        let successData = try JSONEncoder().encode(TerminalControlResponse(ok: true, message: "Sent input."))
        XCTAssertFalse(String(decoding: successData, as: UTF8.self).contains("errorCode"))
    }

    func testClosesConnectionAfterDeliveryOnlyForUnauthorizedCode() {
        // The close decision keys on the typed code, not the message: an unauthorized code closes the
        // connection, while a message that merely contains "unauthorized" without the code does not.
        XCTAssertTrue(
            TerminalServiceResponse(ok: false, message: "Unauthorized spacesd client.", errorCode: .unauthorized).closesConnectionAfterDelivery)
        XCTAssertFalse(TerminalServiceResponse(ok: false, message: "unauthorized-looking message").closesConnectionAfterDelivery)
        XCTAssertFalse(
            TerminalServiceResponse(ok: false, message: "Terminal session is not running.", errorCode: .sessionNotRunning)
                .closesConnectionAfterDelivery)
        XCTAssertFalse(TerminalServiceResponse(ok: true, message: "pong").closesConnectionAfterDelivery)
    }

    func testProfileCommandRoundTripsEveryOperation() throws {
        let commands: [TerminalServiceProfileCommand] = [
            .projectList, .terminalList, .workspaceList(.init(projectID: "project-1")), .workspaceList(.init()),
            .workspaceCreate(.init(projectID: "project-1", branch: "feature", baseBranch: "main", existingBranch: true)),
            .workspaceCreate(.init(projectID: "project-1", branch: "feature")), .workspaceStart(workspaceID: "workspace-1"),
            .workspaceRestart(workspaceID: "workspace-1"),
            .agentSignal(.init(workspaceID: "workspace-1", terminalSessionID: "session-1", event: "blocked")),
            .agentList(.init(workspaceID: "workspace-1", sessionID: "session-1")), .agentList(.init()),
            .agentAnnotate(.init(sessionID: "session-1", note: "review the auth flow")), .agentAnnotate(.init(sessionID: "session-1", note: "")),
            .agentSpawn(.init(cwd: "/tmp/work", workspaceID: "workspace-1", command: "claude", title: "Claude Code")),
            .agentSpawn(.init(cwd: "/tmp/work", command: "codex --yolo")), .agentKill(.init(sessionID: "session-1")),
            .agentSubscribe(.init(subscriberTerminalSessionID: "orchestrator-session", agentSessionID: "agent-1")),
            .agentUnsubscribe(.init(subscriberTerminalSessionID: "orchestrator-session", agentSessionID: "agent-1")),
            .agentConsumePendingEvents(subscriberTerminalSessionID: "orchestrator-session"),
            .terminalSend(.init(sessionID: "session-1", input: .text("hello"), appendNewline: true)),
            .terminalSend(.init(sessionID: "session-1", input: .bytes(Data([0, 10, 255])))),
            .terminalTail(.init(sessionID: "session-1", lineCount: 40)), .terminalTail(.init(sessionID: "session-1")),
            .terminalCommand(.init(cwd: "/tmp/work", workspaceID: "workspace-1", command: "ls", title: "list")),
            .terminalCommand(.init(cwd: "/tmp/work")),
        ]
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        for command in commands {
            let decoded = try decoder.decode(TerminalServiceProfileCommand.self, from: encoder.encode(command))
            XCTAssertEqual(decoded, command)
        }
    }

    func testAgentSessionRowResponseRoundTrips() throws {
        let response = TerminalServiceProfileCommandResponse(
            message: "Listed agent sessions.",
            agentSessions: [
                TerminalServiceAgentSessionRow(
                    id: "agent-1", terminalSessionID: "session-1", agent: "Claude Code CLI", label: "Claude Code CLI", status: "waiting",
                    note: "review the auth flow", projectID: "project-1", projectName: "Spaces", workspaceID: "workspace-1", workspaceName: "feature",
                    workspaceDir: "/repo/workspaces/feature", branch: "feature", updatedAt: "2026-07-14T00:00:00Z",
                    lastSignalAt: "2026-07-14T00:00:00Z"),
                TerminalServiceAgentSessionRow(
                    id: "agent-2", terminalSessionID: "session-2", agent: nil, label: nil, status: "idle", note: nil, projectID: "project-1",
                    projectName: "Spaces", workspaceID: "workspace-1", workspaceName: "feature", workspaceDir: "/repo/workspaces/feature",
                    branch: nil, updatedAt: "2026-07-14T00:00:00Z", lastSignalAt: nil),
            ])
        let decoded = try JSONDecoder().decode(TerminalServiceProfileCommandResponse.self, from: JSONEncoder().encode(response))
        XCTAssertEqual(decoded, response)
    }

    func testAgentAnnotatePayloadRejectsEmptySessionButKeepsEmptyNote() throws {
        let decoder = JSONDecoder()
        // An empty note is a valid clear request; an empty session id is not.
        XCTAssertEqual(
            try decoder.decode(TerminalServiceProfileCommand.self, from: Data(#"{"agentAnnotate":{"sessionID":"session-1","note":""}}"#.utf8)),
            .agentAnnotate(.init(sessionID: "session-1", note: "")))
        XCTAssertThrowsError(
            try decoder.decode(TerminalServiceProfileCommand.self, from: Data(#"{"agentAnnotate":{"sessionID":"  ","note":"hi"}}"#.utf8)))
    }

    func testAgentSpawnPayloadRequiresCwdAndCommand() throws {
        let decoder = JSONDecoder()
        XCTAssertEqual(
            try decoder.decode(TerminalServiceProfileCommand.self, from: Data(#"{"agentSpawn":{"cwd":"/tmp","command":"claude"}}"#.utf8)),
            .agentSpawn(.init(cwd: "/tmp", command: "claude")))
        // A blank command is not a spawnable agent command.
        XCTAssertThrowsError(
            try decoder.decode(TerminalServiceProfileCommand.self, from: Data(#"{"agentSpawn":{"cwd":"/tmp","command":"  "}}"#.utf8)))
        XCTAssertThrowsError(
            try decoder.decode(TerminalServiceProfileCommand.self, from: Data(#"{"agentSpawn":{"cwd":"","command":"claude"}}"#.utf8)))
    }

    func testAgentSubscriptionPayloadRequiresBothEndpoints() throws {
        let decoder = JSONDecoder()
        XCTAssertThrowsError(
            try decoder.decode(
                TerminalServiceProfileCommand.self, from: Data(#"{"agentSubscribe":{"subscriberTerminalSessionID":"sub","agentSessionID":""}}"#.utf8))
        )
        XCTAssertThrowsError(
            try decoder.decode(
                TerminalServiceProfileCommand.self,
                from: Data(#"{"agentSubscribe":{"subscriberTerminalSessionID":"","agentSessionID":"agent-1"}}"#.utf8)))
    }

    func testProfileCommandDecodeNormalizesRequiredStringsAndRejectsEmpty() throws {
        let decoder = JSONDecoder()

        // Surrounding whitespace on a required field is trimmed at the wire boundary.
        let padded = Data(#"{"workspaceStart":"  workspace-1  "}"#.utf8)
        XCTAssertEqual(try decoder.decode(TerminalServiceProfileCommand.self, from: padded), .workspaceStart(workspaceID: "workspace-1"))

        // An empty-after-trim required field is rejected during decode.
        let empty = Data(#"{"workspaceStart":"   "}"#.utf8)
        XCTAssertThrowsError(try decoder.decode(TerminalServiceProfileCommand.self, from: empty))
    }

    func testProfileCommandDecodeRejectsAmbiguousPayloads() {
        let decoder = JSONDecoder()
        XCTAssertThrowsError(try decoder.decode(TerminalServiceProfileCommand.self, from: Data("{}".utf8)))
        XCTAssertThrowsError(try decoder.decode(TerminalServiceProfileCommand.self, from: Data(#"{"projectList":{},"terminalList":{}}"#.utf8)))
    }

    func testTerminalProfileInputRejectsZeroAndTwoKeyPayloads() throws {
        let decoder = JSONDecoder()

        XCTAssertEqual(try decoder.decode(TerminalProfileInput.self, from: Data(#"{"text":""}"#.utf8)), .text(""))
        XCTAssertEqual(try decoder.decode(TerminalProfileInput.self, from: Data(#"{"bytes":"AAr/"}"#.utf8)), .bytes(Data([0, 10, 255])))

        XCTAssertThrowsError(try decoder.decode(TerminalProfileInput.self, from: Data("{}".utf8)))
        XCTAssertThrowsError(try decoder.decode(TerminalProfileInput.self, from: Data(#"{"text":"hi","bytes":"AA=="}"#.utf8)))
    }

    func testClientCanSendRequestToServiceSocket() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let socketPath = root.appendingPathComponent("service.sock").path
        let queue = DispatchQueue(label: "terminal-service-protocol-test")
        let received = expectation(description: "received request")

        let server = TerminalServiceServer(socketPath: socketPath, queue: queue) { request in
            XCTAssertEqual(request, TerminalServiceRequest(command: .ping))
            received.fulfill()
            return TerminalServiceResponse(ok: true, message: "pong")
        }
        try server.start()
        defer { server.stop() }

        let response = try TerminalServiceClient.send(request: TerminalServiceRequest(command: .ping), socketPath: socketPath)

        wait(for: [received], timeout: 2)
        XCTAssertEqual(response, TerminalServiceResponse(ok: true, message: "pong"))
    }

    func testPingIsAnsweredByLivenessResponderWithoutReachingHandleRequest() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let socketPath = root.appendingPathComponent("service.sock").path
        let queue = DispatchQueue(label: "terminal-service-liveness-test")
        let handleRequestCalled = LockedFlag()

        // A handleRequest that blocks indefinitely if a ping ever reached it (proving the liveness
        // fast path is what answered, not a slow handler that happened to return before the assertions
        // ran), and records that it was called at all. Signalled unconditionally at the end of the test
        // so a buggy routing that did invoke this closure doesn't leak a permanently blocked work-queue
        // thread past this test.
        let handleRequestGate = DispatchSemaphore(value: 0)
        defer { handleRequestGate.signal() }
        let server = TerminalServiceServer(
            socketPath: socketPath, queue: queue, livenessResponder: { TerminalServiceResponse(ok: true, message: "pong", servicePID: 4242) }
        ) { _ in
            handleRequestCalled.set()
            handleRequestGate.wait()
            return TerminalServiceResponse(ok: false, message: "should not be used for ping")
        }
        try server.start()
        defer { server.stop() }

        let start = Date()
        let response = try TerminalServiceClient.send(request: TerminalServiceRequest(command: .ping), socketPath: socketPath, timeout: 2)
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.servicePID, 4242)
        XCTAssertLessThan(elapsed, 1, "Liveness ping must not go through the blocking handleRequest path")
        XCTAssertFalse(handleRequestCalled.value, "Ping must be served by the liveness responder, not handleRequest")
    }

    func testSlowRequestDoesNotBlockConcurrentPing() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let socketPath = root.appendingPathComponent("service.sock").path
        let queue = DispatchQueue(label: "terminal-service-concurrency-test")

        // handleRequest simulates a heavy `.create` that holds the work queue until the test releases
        // it. `slowRequestStarted` is signalled once the handler actually begins, which is the precise
        // moment the request has reached and occupied the server's worker (replacing a guess at how long
        // that takes). `releaseSlowRequest` is signalled unconditionally via defer so the handler (and the
        // background client send below) always unblocks, even if an assertion fails first.
        let slowRequestStarted = DispatchSemaphore(value: 0)
        let releaseSlowRequest = DispatchSemaphore(value: 0)
        defer { releaseSlowRequest.signal() }
        let server = TerminalServiceServer(
            socketPath: socketPath, queue: queue, livenessResponder: { TerminalServiceResponse(ok: true, message: "pong", servicePID: 7) }
        ) { _ in
            slowRequestStarted.signal()
            releaseSlowRequest.wait()
            return TerminalServiceResponse(ok: true, message: "slow-done")
        }
        try server.start()
        defer { server.stop() }

        // Start a slow non-ping request that occupies a connection worker, without waiting for it.
        DispatchQueue.global().async {
            _ = try? TerminalServiceClient.send(request: TerminalServiceRequest(command: .list), socketPath: socketPath, timeout: 10)
        }
        XCTAssertEqual(slowRequestStarted.wait(timeout: .now() + 2), .success, "Slow request never reached the server")

        let start = Date()
        let ping = try TerminalServiceClient.send(request: TerminalServiceRequest(command: .ping), socketPath: socketPath, timeout: 2)
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertTrue(ping.ok)
        XCTAssertLessThan(elapsed, 1.5, "A ping must not be head-of-line-blocked behind an in-flight slow request")
    }

    func testRelaunchIfIdleLeavesBusyDaemonRunningWhenItRefuses() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let originalRuntimeDir = getenv(SpacesProfile.runtimeDirectoryEnvironmentVariable).map { String(cString: $0) }
        let originalDatabasePath = getenv(SpacesProfile.databasePathEnvironmentVariable).map { String(cString: $0) }
        setenv(SpacesProfile.runtimeDirectoryEnvironmentVariable, root.path, 1)
        setenv(SpacesProfile.databasePathEnvironmentVariable, root.appendingPathComponent("spaces.db").path, 1)
        defer {
            if let originalRuntimeDir {
                setenv(SpacesProfile.runtimeDirectoryEnvironmentVariable, originalRuntimeDir, 1)
            } else {
                unsetenv(SpacesProfile.runtimeDirectoryEnvironmentVariable)
            }
            if let originalDatabasePath {
                setenv(SpacesProfile.databasePathEnvironmentVariable, originalDatabasePath, 1)
            } else {
                unsetenv(SpacesProfile.databasePathEnvironmentVariable)
            }
            try? FileManager.default.removeItem(at: root)
        }

        let socketPath = try TerminalServicePaths.socketPath()
        let queue = DispatchQueue(label: "terminal-service-relaunch-if-idle-test")
        let shutdownIfIdleRequests = ThreadSafeCounter()
        let server = TerminalServiceServer(socketPath: socketPath, queue: queue) { request in
            switch request.command {
            case .shutdownIfIdle:
                shutdownIfIdleRequests.increment()
                return TerminalServiceResponse(ok: false, message: "spacesd has 1 active session(s).", servicePID: getpid())
            case .ping: return TerminalServiceResponse(ok: true, message: "pong", servicePID: getpid())
            default: return TerminalServiceResponse(ok: false, message: "unexpected command")
            }
        }
        try server.start()
        defer { server.stop() }

        // A daemon that refuses `shutdownIfIdle` (it has live sessions) must be left running, and relaunchIfIdle
        // must report false rather than killing or respawning anything.
        XCTAssertFalse(try TerminalService.relaunchIfIdle(timeout: 1))
        XCTAssertEqual(shutdownIfIdleRequests.value, 1)

        let ping = try TerminalServiceClient.send(request: TerminalServiceRequest(command: .ping), socketPath: socketPath)
        XCTAssertEqual(ping, TerminalServiceResponse(ok: true, message: "pong", servicePID: getpid()))
    }

    func testTerminalServiceInstanceLockRejectsSecondOwnerAndReleases() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // A record for another live process must still be rejected: only a record for
        // this process's own pid (the exec-in-place resume case) is adoptable.
        let foreignProcess = Process()
        foreignProcess.executableURL = URL(fileURLWithPath: "/bin/sleep")
        foreignProcess.arguments = ["30"]
        try foreignProcess.run()
        defer {
            foreignProcess.terminate()
            foreignProcess.waitUntilExit()
        }
        let foreignPID = foreignProcess.processIdentifier

        let lockPath = root.appendingPathComponent("daemon.lock").path
        let lock = try TerminalServiceInstanceLock.acquire(path: lockPath, processID: foreignPID)
        XCTAssertThrowsError(try TerminalServiceInstanceLock.acquire(path: lockPath)) { error in
            guard case TerminalServiceInstanceLockError.alreadyRunning(let pid, let path) = error else {
                return XCTFail("Expected an already-running lock error, got \(error).")
            }
            XCTAssertEqual(pid, foreignPID)
            XCTAssertEqual(path, lockPath)
        }

        lock.release()
        let reacquired = try TerminalServiceInstanceLock.acquire(path: lockPath)
        reacquired.release()
    }

    func testTerminalServiceInstanceLockReclaimsStaleOwner() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let lockPath = root.appendingPathComponent("daemon.lock").path
        try #"{"pid":-1,"token":"stale"}"#.write(toFile: lockPath, atomically: true, encoding: .utf8)

        let lock = try TerminalServiceInstanceLock.acquire(path: lockPath)
        lock.release()
    }

    #if canImport(Network) && canImport(Security)
        func testPinnedTLSClientCanSendRequestToRemoteService() throws {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }

            let identity = try TerminalServiceTLSIdentityStore.loadOrCreate(root: root)
            let queue = DispatchQueue(label: "terminal-service-tls-protocol-test")
            let received = expectation(description: "received pinned TLS request")
            let server = TerminalServiceTLSServer(host: "127.0.0.1", port: 0, authToken: "SECRET", identity: identity, queue: queue) { request in
                XCTAssertEqual(request, TerminalServiceRequest(command: .ping, authToken: "SECRET"))
                received.fulfill()
                return TerminalServiceResponse(ok: true, message: "pong")
            }
            try server.start()
            defer { server.stop() }

            let response = try TerminalServiceClient.sendPinnedTLS(
                request: TerminalServiceRequest(command: .ping), host: "127.0.0.1", port: server.listeningPort, authToken: "SECRET",
                certificateFingerprint: identity.certificateFingerprint)

            wait(for: [received], timeout: 5)
            XCTAssertEqual(response, TerminalServiceResponse(ok: true, message: "pong"))
        }

        func testPinnedTLSServerKeepsConnectionOpenForMultipleRequests() throws {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }

            let identity = try TerminalServiceTLSIdentityStore.loadOrCreate(root: root)
            let queue = DispatchQueue(label: "terminal-service-tls-persistent-test")
            let requestCount = LockedCounter()
            let server = TerminalServiceTLSServer(host: "127.0.0.1", port: 0, authToken: "SECRET", identity: identity, queue: queue) { request in
                let count = requestCount.increment()
                return TerminalServiceResponse(ok: true, message: "\(request.commandName)-\(count)")
            }
            try server.start()
            defer { server.stop() }

            let connection = try Self.makeUnpinnedTLSConnection(port: server.listeningPort)
            try Self.waitUntilReady(connection, queue: DispatchQueue(label: "terminal-service-tls-persistent-client"))
            defer { connection.cancel() }

            let first = try Self.sendRequestLineAndReadResponse(TerminalServiceRequest(command: .ping, authToken: "SECRET"), connection: connection)
            let second = try Self.sendRequestLineAndReadResponse(TerminalServiceRequest(command: .list, authToken: "SECRET"), connection: connection)

            XCTAssertEqual(first, TerminalServiceResponse(ok: true, message: "ping-1"))
            XCTAssertEqual(second, TerminalServiceResponse(ok: true, message: "list-2"))
            XCTAssertEqual(requestCount.value, 2)
        }

        func testPinnedTLSRequestSessionClientSendsMultipleRequestsOverOneConnection() throws {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }

            let identity = try TerminalServiceTLSIdentityStore.loadOrCreate(root: root)
            let queue = DispatchQueue(label: "terminal-service-tls-session-client-test")
            let requestCount = LockedCounter()
            let server = TerminalServiceTLSServer(host: "127.0.0.1", port: 0, authToken: "SECRET", identity: identity, queue: queue) { request in
                let count = requestCount.increment()
                return TerminalServiceResponse(ok: true, message: "\(request.commandName)-\(request.authToken ?? "")-\(count)")
            }
            try server.start()
            defer { server.stop() }

            let client = try TerminalServicePinnedTLSRequestSessionClient(
                host: "127.0.0.1", port: server.listeningPort, authToken: "SECRET", certificateFingerprint: identity.certificateFingerprint)
            defer { client.cancel() }

            let first = try client.send(request: TerminalServiceRequest(command: .ping))
            let second = try client.send(request: TerminalServiceRequest(command: .list))

            XCTAssertEqual(first, TerminalServiceResponse(ok: true, message: "ping-SECRET-1"))
            XCTAssertEqual(second, TerminalServiceResponse(ok: true, message: "list-SECRET-2"))
            XCTAssertEqual(requestCount.value, 2)
        }

        func testPinnedTLSRequestSessionClientReconnectsAfterServerClosesConnection() throws {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }

            let identity = try TerminalServiceTLSIdentityStore.loadOrCreate(root: root)
            let queue = DispatchQueue(label: "terminal-service-tls-session-client-reconnect-test")
            let requestCount = LockedCounter()
            let server = TerminalServiceTLSServer(host: "127.0.0.1", port: 0, authToken: "SECRET", identity: identity, queue: queue) { request in
                let count = requestCount.increment()
                if count == 1 { return TerminalServiceResponse(ok: false, message: "Unauthorized test connection close.", errorCode: .unauthorized) }
                return TerminalServiceResponse(ok: true, message: "\(request.commandName)-\(request.authToken ?? "")-\(count)")
            }
            try server.start()
            defer { server.stop() }

            let client = try TerminalServicePinnedTLSRequestSessionClient(
                host: "127.0.0.1", port: server.listeningPort, authToken: "SECRET", certificateFingerprint: identity.certificateFingerprint)
            defer { client.cancel() }

            let first = try client.send(request: TerminalServiceRequest(command: .ping))
            let second = try client.send(request: TerminalServiceRequest(command: .list))

            XCTAssertEqual(first, TerminalServiceResponse(ok: false, message: "Unauthorized test connection close.", errorCode: .unauthorized))
            XCTAssertEqual(second, TerminalServiceResponse(ok: true, message: "list-SECRET-2"))
            XCTAssertEqual(requestCount.value, 2)
        }
    #endif

    func testTLSIdentityStoreReloadsExistingIdentity() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let first = try TerminalServiceTLSIdentityStore.loadOrCreate(root: root)
        let second = try TerminalServiceTLSIdentityStore.loadOrCreate(root: root)

        XCTAssertEqual(try posixPermissions(at: root), 0o700)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("identity.key.der").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("identity.certificate.der").path))
        XCTAssertEqual(try posixPermissions(at: root.appendingPathComponent("identity.key.der")), 0o600)
        XCTAssertEqual(try posixPermissions(at: root.appendingPathComponent("identity.certificate.der")), 0o600)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("identity.p12").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("identity.passphrase").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("identity.keychain-db").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("identity.keychain.passphrase").path))
        XCTAssertEqual(second.certificateFingerprint, first.certificateFingerprint)
    }

    #if os(macOS)
        func testTLSIdentityStoreCreatesIdentityWithSystemLibreSSL() throws {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }

            let originalPath = getenv("PATH").map { String(cString: $0) }
            setenv("PATH", "/usr/bin:/bin:/usr/sbin:/sbin", 1)
            defer { if let originalPath { setenv("PATH", originalPath, 1) } else { unsetenv("PATH") } }

            let identity = try TerminalServiceTLSIdentityStore.loadOrCreate(root: root)

            XCTAssertFalse(identity.certificateFingerprint.isEmpty)
            XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("identity.key.der").path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("identity.certificate.der").path))
        }
    #endif

    func testTLSIdentityStoreRemovesObsoleteIdentityFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        for filename in ["identity.p12", "identity.passphrase", "identity.keychain-db", "identity.keychain.passphrase"] {
            try Data("obsolete".utf8).write(to: root.appendingPathComponent(filename))
        }

        let identity = try TerminalServiceTLSIdentityStore.loadOrCreate(root: root)

        XCTAssertFalse(identity.certificateFingerprint.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("identity.key.der").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("identity.certificate.der").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("identity.p12").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("identity.passphrase").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("identity.keychain-db").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("identity.keychain.passphrase").path))
    }

    #if canImport(Network) && canImport(Security)
        func testPinnedTLSClientRejectsCertificateMismatch() throws {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }

            let identity = try TerminalServiceTLSIdentityStore.loadOrCreate(root: root)
            let queue = DispatchQueue(label: "terminal-service-tls-pin-test")
            let server = TerminalServiceTLSServer(host: "127.0.0.1", port: 0, authToken: "SECRET", identity: identity, queue: queue) { _ in
                XCTFail("A mismatched certificate pin should not reach the handler.")
                return TerminalServiceResponse(ok: true, message: "unexpected")
            }
            try server.start()
            defer { server.stop() }

            XCTAssertThrowsError(
                try TerminalServiceClient.sendPinnedTLS(
                    request: TerminalServiceRequest(command: .ping), host: "127.0.0.1", port: server.listeningPort, authToken: "SECRET",
                    certificateFingerprint: "SHA256:0000000000000000000000000000000000000000000000000000000000000000")
            ) { error in
                guard case TerminalServiceTLSError.certificatePinMismatch = error else {
                    XCTFail("Expected certificate pin mismatch, got \(error)")
                    return
                }
            }
        }
    #endif
}

/// File-scope and unguarded so both the Network/Security-only tests and the cross-platform
/// identity-store tests can assert on-disk permission modes.
private func posixPermissions(at url: URL) throws -> Int {
    guard let value = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber else {
        XCTFail("Missing POSIX permissions for \(url.path)")
        return -1
    }
    return value.intValue & 0o777
}

/// File-scope thread-safe flag usable from the `@Sendable` service-server handler on macOS and Linux.
private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue = false

    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return storedValue
    }

    func set() {
        lock.lock()
        storedValue = true
        lock.unlock()
    }
}

/// File-scope thread-safe counter usable from the `@Sendable` service-server handler on macOS and Linux
/// (unlike the `LockedCounter` nested under the Network/Security-only extension below).
private final class ThreadSafeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }
}

#if canImport(Network) && canImport(Security)
    extension TerminalServiceProtocolTests {
        fileprivate static func makeUnpinnedTLSConnection(port: Int) throws -> NWConnection {
            guard let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else { throw TerminalServiceTLSError.invalidPort(port) }
            let tlsOptions = NWProtocolTLS.Options()
            let securityOptions = tlsOptions.securityProtocolOptions
            sec_protocol_options_set_min_tls_protocol_version(securityOptions, .TLSv12)
            sec_protocol_options_set_max_tls_protocol_version(securityOptions, .TLSv13)
            sec_protocol_options_set_peer_authentication_required(securityOptions, true)
            sec_protocol_options_set_verify_block(securityOptions, { _, _, complete in complete(true) }, DispatchQueue.global(qos: .userInitiated))
            return NWConnection(host: "127.0.0.1", port: nwPort, using: NWParameters(tls: tlsOptions, tcp: NWProtocolTCP.Options()))
        }

        fileprivate static func waitUntilReady(_ connection: NWConnection, queue: DispatchQueue) throws {
            let semaphore = DispatchSemaphore(value: 0)
            let errorBox = LockedErrorBox()
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: semaphore.signal()
                case .failed(let error):
                    errorBox.set(error)
                    semaphore.signal()
                default: break
                }
            }
            connection.start(queue: queue)
            guard semaphore.wait(timeout: .now() + 5) == .success else { throw TerminalServiceTLSError.requestTimedOut }
            if let error = errorBox.value { throw error }
        }

        fileprivate static func sendRequestLineAndReadResponse(_ request: TerminalServiceRequest, connection: NWConnection) throws
            -> TerminalServiceResponse
        {
            var data = try TerminalServiceCodec.encodeRequest(request)
            data.append(0x0A)
            try send(data, connection: connection)
            return try TerminalServiceCodec.decodeResponse(readLine(connection: connection))
        }

        fileprivate static func send(_ data: Data, connection: NWConnection) throws {
            let semaphore = DispatchSemaphore(value: 0)
            let errorBox = LockedErrorBox()
            connection.send(
                content: data, contentContext: .defaultMessage, isComplete: false,
                completion: .contentProcessed { error in
                    if let error { errorBox.set(error) }
                    semaphore.signal()
                })
            guard semaphore.wait(timeout: .now() + 5) == .success else { throw TerminalServiceTLSError.requestTimedOut }
            if let error = errorBox.value { throw error }
        }

        fileprivate static func readLine(connection: NWConnection, data: Data = Data()) throws -> Data {
            if let newlineIndex = data.firstIndex(of: 0x0A) { return Data(data.prefix(upTo: newlineIndex)) }
            let semaphore = DispatchSemaphore(value: 0)
            let result = LockedResultBox<Data>()
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { content, _, isComplete, error in
                if let error {
                    result.set(.failure(error))
                    semaphore.signal()
                    return
                }
                var nextData = data
                if let content, !content.isEmpty { nextData.append(content) }
                if let newlineIndex = nextData.firstIndex(of: 0x0A) {
                    result.set(.success(Data(nextData.prefix(upTo: newlineIndex))))
                    semaphore.signal()
                    return
                }
                if isComplete {
                    result.set(.success(nextData))
                    semaphore.signal()
                    return
                }
                do { result.set(.success(try readLine(connection: connection, data: nextData))) } catch { result.set(.failure(error)) }
                semaphore.signal()
            }
            guard semaphore.wait(timeout: .now() + 5) == .success else { throw TerminalServiceTLSError.requestTimedOut }
            return try result.value.get()
        }
    }

    private final class LockedCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        var value: Int {
            lock.lock()
            defer { lock.unlock() }
            return count
        }

        func increment() -> Int {
            lock.lock()
            defer { lock.unlock() }
            count += 1
            return count
        }
    }

    private final class LockedErrorBox: @unchecked Sendable {
        private let lock = NSLock()
        private var error: (any Error)?

        var value: (any Error)? {
            lock.lock()
            defer { lock.unlock() }
            return error
        }

        func set(_ error: any Error) {
            lock.lock()
            self.error = error
            lock.unlock()
        }
    }

    private final class LockedResultBox<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var result: Result<T, any Error> = .failure(TerminalServiceTLSError.requestTimedOut)

        var value: Result<T, any Error> {
            lock.lock()
            defer { lock.unlock() }
            return result
        }

        func set(_ result: Result<T, any Error>) {
            lock.lock()
            self.result = result
            lock.unlock()
        }
    }
#endif
