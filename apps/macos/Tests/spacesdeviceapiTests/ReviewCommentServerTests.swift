#if canImport(Network) && canImport(Security)
    import Foundation
    import XCTest
    import workspacecore

    @testable import spacesdeviceapi
    @testable import spacesdevicecore
    @testable import spacesterminalcore

    /// Device API server coverage for the code pane's review-comment surface (`workspaceReviewCommentList`,
    /// `workspaceReviewCommentUpsert`, `workspaceReviewCommentDelete`, `workspaceReviewCommentsSend`): CRUD
    /// ownership rules (an id naming another workspace's, an already-sent, or an unknown comment is
    /// rejected), and the send+archive endpoint's validation gates (including the per-comment `revision`
    /// version echo) and its terminal-write/archive side effects.
    final class ReviewCommentServerTests: XCTestCase {
        func testListReturnsOnlyThisWorkspacesDrafts() throws {
            try withTemporaryProfile { _ in
                try seedWorkspace(id: "workspace-1")
                try seedWorkspace(id: "workspace-2")
                try seedDraftComment(id: "comment-1", workspaceID: "workspace-1", filePath: "a.swift")
                try seedDraftComment(id: "comment-2", workspaceID: "workspace-2", filePath: "b.swift")
                try seedDraftComment(id: "comment-3", workspaceID: "workspace-1", filePath: "c.swift", sentAt: "2026-08-20T10:00:00Z")

                let (server, client, clientApp, token) = try makeServerAndClient()
                defer {
                    client.cancel()
                    server.stop()
                }

                let response = try client.send(
                    SpacesDeviceAPIRequest(
                        command: .workspaceReviewCommentList(.init(workspaceID: "workspace-1")), authToken: token, clientApp: clientApp))

                XCTAssertTrue(response.ok, response.message)
                let comments = try XCTUnwrap(response.workspaceReviewCommentList?.comments)
                XCTAssertEqual(comments.map(\.id), ["comment-1"])
            }
        }

        func testUpsertCreatesDraftThenUpdatesItByID() throws {
            try withTemporaryProfile { _ in
                try seedWorkspace(id: "workspace-1")
                let (server, client, clientApp, token) = try makeServerAndClient()
                defer {
                    client.cancel()
                    server.stop()
                }

                let createResponse = try client.send(
                    SpacesDeviceAPIRequest(
                        command: .workspaceReviewCommentUpsert(
                            .init(
                                workspaceID: "workspace-1", filePath: "a.swift", side: .new, lineNumber: 10, lineText: "let x = 1",
                                body: "why?")), authToken: token, clientApp: clientApp))
                XCTAssertTrue(createResponse.ok, createResponse.message)
                let created = try XCTUnwrap(createResponse.workspaceReviewCommentUpsert?.comment)
                XCTAssertEqual(created.filePath, "a.swift")
                XCTAssertEqual(created.body, "why?")

                let updateResponse = try client.send(
                    SpacesDeviceAPIRequest(
                        command: .workspaceReviewCommentUpsert(
                            .init(
                                workspaceID: "workspace-1", id: created.id, filePath: "a.swift", side: .new, lineNumber: 10,
                                lineText: "let x = 1", body: "actually, why not?")), authToken: token, clientApp: clientApp))
                XCTAssertTrue(updateResponse.ok, updateResponse.message)
                let updated = try XCTUnwrap(updateResponse.workspaceReviewCommentUpsert?.comment)
                XCTAssertEqual(updated.id, created.id)
                XCTAssertEqual(updated.body, "actually, why not?")
                XCTAssertEqual(updated.createdAt, created.createdAt)
            }
        }

        func testUpsertRejectsMissingFilePathAndBody() throws {
            try withTemporaryProfile { _ in
                try seedWorkspace(id: "workspace-1")
                let (server, client, clientApp, token) = try makeServerAndClient()
                defer {
                    client.cancel()
                    server.stop()
                }

                let missingFilePath = try client.send(
                    SpacesDeviceAPIRequest(
                        command: .workspaceReviewCommentUpsert(
                            .init(workspaceID: "workspace-1", filePath: "", side: .new, lineNumber: 1, lineText: "x", body: "note")),
                        authToken: token, clientApp: clientApp))
                XCTAssertFalse(missingFilePath.ok)
                XCTAssertEqual(missingFilePath.errorCode, .invalidArgument)

                let missingBody = try client.send(
                    SpacesDeviceAPIRequest(
                        command: .workspaceReviewCommentUpsert(
                            .init(workspaceID: "workspace-1", filePath: "a.swift", side: .new, lineNumber: 1, lineText: "x", body: "")),
                        authToken: token, clientApp: clientApp))
                XCTAssertFalse(missingBody.ok)
                XCTAssertEqual(missingBody.errorCode, .invalidArgument)
            }
        }

        func testUpsertRejectsIDBelongingToAnotherWorkspace() throws {
            try withTemporaryProfile { _ in
                try seedWorkspace(id: "workspace-1")
                try seedWorkspace(id: "workspace-2")
                try seedDraftComment(id: "comment-1", workspaceID: "workspace-2", filePath: "a.swift")
                let (server, client, clientApp, token) = try makeServerAndClient()
                defer {
                    client.cancel()
                    server.stop()
                }

                let response = try client.send(
                    SpacesDeviceAPIRequest(
                        command: .workspaceReviewCommentUpsert(
                            .init(
                                workspaceID: "workspace-1", id: "comment-1", filePath: "a.swift", side: .new, lineNumber: 1, lineText: "x",
                                body: "note")), authToken: token, clientApp: clientApp))

                XCTAssertFalse(response.ok)
                XCTAssertEqual(response.errorCode, .invalidArgument)
                // The other workspace's draft is untouched.
                let store = try SQLiteStore(path: DatabaseLocator.defaultPath())
                let untouched = try XCTUnwrap(store.reviewComment(id: "comment-1"))
                XCTAssertEqual(untouched.body, "draft body")
            }
        }

        func testUpsertRejectsEditingAnAlreadySentComment() throws {
            try withTemporaryProfile { _ in
                try seedWorkspace(id: "workspace-1")
                try seedDraftComment(id: "comment-1", workspaceID: "workspace-1", filePath: "a.swift", sentAt: "2026-08-20T10:00:00Z")
                let (server, client, clientApp, token) = try makeServerAndClient()
                defer {
                    client.cancel()
                    server.stop()
                }

                let response = try client.send(
                    SpacesDeviceAPIRequest(
                        command: .workspaceReviewCommentUpsert(
                            .init(
                                workspaceID: "workspace-1", id: "comment-1", filePath: "a.swift", side: .new, lineNumber: 1, lineText: "x",
                                body: "note")), authToken: token, clientApp: clientApp))

                XCTAssertFalse(response.ok)
                XCTAssertEqual(response.errorCode, .invalidArgument)
                XCTAssertTrue(response.message.contains("already sent"), response.message)
            }
        }

        /// An `id` present but naming no comment at all must not fall through to the create path just
        /// because `existing` came back nil — that would let a caller mint a server row under any id it
        /// chooses (e.g. a stale id from a previous session). It gets the same `.notFound` the delete
        /// handler already gives an unknown id, and creates nothing.
        func testUpsertRejectsUnknownID() throws {
            try withTemporaryProfile { _ in
                try seedWorkspace(id: "workspace-1")
                let (server, client, clientApp, token) = try makeServerAndClient()
                defer {
                    client.cancel()
                    server.stop()
                }

                let response = try client.send(
                    SpacesDeviceAPIRequest(
                        command: .workspaceReviewCommentUpsert(
                            .init(
                                workspaceID: "workspace-1", id: "does-not-exist", filePath: "a.swift", side: .new, lineNumber: 1,
                                lineText: "x", body: "note")), authToken: token, clientApp: clientApp))

                XCTAssertFalse(response.ok)
                XCTAssertEqual(response.errorCode, .notFound)
                let store = try SQLiteStore(path: DatabaseLocator.defaultPath())
                XCTAssertNil(try store.reviewComment(id: "does-not-exist"))
            }
        }

        func testDeleteRemovesDraft() throws {
            try withTemporaryProfile { _ in
                try seedWorkspace(id: "workspace-1")
                try seedDraftComment(id: "comment-1", workspaceID: "workspace-1", filePath: "a.swift")
                let (server, client, clientApp, token) = try makeServerAndClient()
                defer {
                    client.cancel()
                    server.stop()
                }

                let response = try client.send(
                    SpacesDeviceAPIRequest(
                        command: .workspaceReviewCommentDelete(.init(workspaceID: "workspace-1", id: "comment-1")), authToken: token,
                        clientApp: clientApp))

                XCTAssertTrue(response.ok, response.message)
                let store = try SQLiteStore(path: DatabaseLocator.defaultPath())
                XCTAssertNil(try store.reviewComment(id: "comment-1"))
            }
        }

        func testDeleteReturnsNotFoundForUnknownOrForeignID() throws {
            try withTemporaryProfile { _ in
                try seedWorkspace(id: "workspace-1")
                try seedWorkspace(id: "workspace-2")
                try seedDraftComment(id: "comment-1", workspaceID: "workspace-2", filePath: "a.swift")
                let (server, client, clientApp, token) = try makeServerAndClient()
                defer {
                    client.cancel()
                    server.stop()
                }

                let unknown = try client.send(
                    SpacesDeviceAPIRequest(
                        command: .workspaceReviewCommentDelete(.init(workspaceID: "workspace-1", id: "does-not-exist")), authToken: token,
                        clientApp: clientApp))
                XCTAssertFalse(unknown.ok)
                XCTAssertEqual(unknown.errorCode, .notFound)

                let foreign = try client.send(
                    SpacesDeviceAPIRequest(
                        command: .workspaceReviewCommentDelete(.init(workspaceID: "workspace-1", id: "comment-1")), authToken: token,
                        clientApp: clientApp))
                XCTAssertFalse(foreign.ok)
                XCTAssertEqual(foreign.errorCode, .notFound)

                // The other workspace's comment survives both rejected calls.
                let store = try SQLiteStore(path: DatabaseLocator.defaultPath())
                XCTAssertNotNil(try store.reviewComment(id: "comment-1"))
            }
        }

        /// Round-12 Fix 3: delete is DRAFT-only, mirroring the upsert handler's already-sent guard above
        /// (`testUpsertRejectsEditingAnAlreadySentComment`). A comment that has already been sent is part of
        /// the append-only archive; the row must survive the rejected delete with its `sentAt` untouched.
        func testDeleteRejectsAnAlreadySentComment() throws {
            try withTemporaryProfile { _ in
                try seedWorkspace(id: "workspace-1")
                try seedDraftComment(id: "comment-1", workspaceID: "workspace-1", filePath: "a.swift", sentAt: "2026-08-20T10:00:00Z")
                let (server, client, clientApp, token) = try makeServerAndClient()
                defer {
                    client.cancel()
                    server.stop()
                }

                let response = try client.send(
                    SpacesDeviceAPIRequest(
                        command: .workspaceReviewCommentDelete(.init(workspaceID: "workspace-1", id: "comment-1")), authToken: token,
                        clientApp: clientApp))

                XCTAssertFalse(response.ok)
                XCTAssertEqual(response.errorCode, .invalidArgument)
                XCTAssertTrue(response.message.contains("already sent"), response.message)
                let store = try SQLiteStore(path: DatabaseLocator.defaultPath())
                let stillArchived = try XCTUnwrap(store.reviewComment(id: "comment-1"))
                XCTAssertNotNil(stillArchived.sentAt)
            }
        }

        func testSendRejectsEmptyComments() throws {
            try withTemporaryProfile { _ in
                try seedWorkspace(id: "workspace-1")
                let (server, client, clientApp, token) = try makeServerAndClient()
                defer {
                    client.cancel()
                    server.stop()
                }

                let response = try client.send(
                    SpacesDeviceAPIRequest(
                        command: .workspaceReviewCommentsSend(
                            .init(workspaceID: "workspace-1", sessionID: "agent-session", text: "hi", comments: [])), authToken: token,
                        clientApp: clientApp))

                XCTAssertFalse(response.ok)
                XCTAssertEqual(response.errorCode, .invalidArgument)
            }
        }

        func testSendRejectsUnknownWorkspace() throws {
            try withTemporaryProfile { _ in
                let (server, client, clientApp, token) = try makeServerAndClient()
                defer {
                    client.cancel()
                    server.stop()
                }

                let response = try client.send(
                    SpacesDeviceAPIRequest(
                        command: .workspaceReviewCommentsSend(
                            .init(workspaceID: "does-not-exist", sessionID: "agent-session", text: "hi", comments: sendEntries(["comment-1"]))),
                        authToken: token, clientApp: clientApp))

                XCTAssertFalse(response.ok)
                XCTAssertEqual(response.errorCode, .notFound)
            }
        }

        /// A comments list mixing a valid draft with one that does not belong to this workspace is
        /// rejected wholesale, and — because the endpoint validates every entry before writing or
        /// archiving anything — the valid draft is left untouched rather than partially sent.
        func testSendValidationFailureLeavesDraftsIntact() throws {
            try withTemporaryProfile { _ in
                try seedWorkspace(id: "workspace-1")
                try seedWorkspace(id: "workspace-2")
                try seedDraftComment(id: "comment-1", workspaceID: "workspace-1", filePath: "a.swift")
                try seedDraftComment(id: "comment-2", workspaceID: "workspace-2", filePath: "b.swift")
                let (server, client, clientApp, token) = try makeServerAndClient()
                defer {
                    client.cancel()
                    server.stop()
                }

                let response = try client.send(
                    SpacesDeviceAPIRequest(
                        command: .workspaceReviewCommentsSend(
                            .init(
                                workspaceID: "workspace-1", sessionID: "agent-session", text: "hi",
                                comments: sendEntries(["comment-1", "comment-2"]))), authToken: token, clientApp: clientApp))

                XCTAssertFalse(response.ok)
                XCTAssertEqual(response.errorCode, .invalidArgument)
                let store = try SQLiteStore(path: DatabaseLocator.defaultPath())
                let stillDraft = try XCTUnwrap(store.reviewComment(id: "comment-1"))
                XCTAssertNil(stillDraft.sentAt)
            }
        }

        func testSendRejectsSessionNotBelongingToWorkspace() throws {
            try withTemporaryProfile { _ in
                try seedWorkspace(id: "workspace-1")
                try seedWorkspace(id: "other-workspace")
                try seedDraftComment(id: "comment-1", workspaceID: "workspace-1", filePath: "a.swift")
                try seedTerminalSession(sessionID: "agent-session", workspaceID: "other-workspace", state: .running)
                let (server, client, clientApp, token) = try makeServerAndClient()
                defer {
                    client.cancel()
                    server.stop()
                }

                let response = try client.send(
                    SpacesDeviceAPIRequest(
                        command: .workspaceReviewCommentsSend(
                            .init(workspaceID: "workspace-1", sessionID: "agent-session", text: "hi", comments: sendEntries(["comment-1"]))),
                        authToken: token, clientApp: clientApp))

                XCTAssertFalse(response.ok)
                XCTAssertEqual(response.errorCode, .invalidArgument)
                let store = try SQLiteStore(path: DatabaseLocator.defaultPath())
                XCTAssertNil(try store.reviewComment(id: "comment-1")?.sentAt)
            }
        }

        func testSendRejectsSessionNotRunning() throws {
            try withTemporaryProfile { _ in
                try seedWorkspace(id: "workspace-1")
                try seedDraftComment(id: "comment-1", workspaceID: "workspace-1", filePath: "a.swift")
                try seedTerminalSession(sessionID: "agent-session", workspaceID: "workspace-1", state: .exited)
                let (server, client, clientApp, token) = try makeServerAndClient()
                defer {
                    client.cancel()
                    server.stop()
                }

                let response = try client.send(
                    SpacesDeviceAPIRequest(
                        command: .workspaceReviewCommentsSend(
                            .init(workspaceID: "workspace-1", sessionID: "agent-session", text: "hi", comments: sendEntries(["comment-1"]))),
                        authToken: token, clientApp: clientApp))

                XCTAssertFalse(response.ok)
                XCTAssertEqual(response.errorCode, .sessionNotRunning)
                let store = try SQLiteStore(path: DatabaseLocator.defaultPath())
                XCTAssertNil(try store.reviewComment(id: "comment-1")?.sentAt)
            }
        }

        /// An exited agent may leave its interactive terminal open as a bare shell. Review text must not
        /// be sent to that surviving shell: the persisted agent lifecycle row is the authority for whether
        /// this session is still an agent target, independently of the terminal runtime state.
        func testSendRejectsExitedAgentWithInteractiveSessionWithoutWritingOrArchiving() throws {
            try withTemporaryProfile { _ in
                try seedWorkspace(id: "workspace-1")
                try seedDraftComment(id: "comment-1", workspaceID: "workspace-1", filePath: "a.swift")
                try seedTerminalSession(sessionID: "agent-session", workspaceID: "workspace-1", state: .running, agentStatus: .exited)

                let paths = try TerminalSessionPaths.forSession(id: "agent-session")
                try paths.ensureDirectories()
                let recorder = ReviewCommentTerminalControlRecorder()
                let controlServer = TerminalControlServer(
                    socketPath: paths.controlSocketPath, queue: DispatchQueue(label: "spaces.review-comment.send.exited.test")
                ) { request in
                    recorder.record(request)
                    return TerminalControlResponse(ok: true, message: "Sent input.")
                }
                try controlServer.start()
                defer { controlServer.stop() }

                let (server, client, clientApp, token) = try makeServerAndClient()
                defer {
                    client.cancel()
                    server.stop()
                }

                let response = try client.send(
                    SpacesDeviceAPIRequest(
                        command: .workspaceReviewCommentsSend(
                            .init(
                                workspaceID: "workspace-1", sessionID: "agent-session", text: "please fix these",
                                comments: sendEntries(["comment-1"]))), authToken: token, clientApp: clientApp))

                XCTAssertFalse(response.ok)
                XCTAssertEqual(response.errorCode, .invalidArgument)
                XCTAssertTrue(recorder.requests().isEmpty)
                let store = try SQLiteStore(path: DatabaseLocator.defaultPath())
                let stillDraft = try XCTUnwrap(store.reviewComment(id: "comment-1"))
                XCTAssertNil(stillDraft.sentAt)
            }
        }

        /// A send whose named comment's echoed `revision` no longer matches the draft's current one —
        /// because it was edited since the client read it — is rejected before writing anything to the
        /// terminal or archiving anything, with a typed `.conflict` distinct from `.invalidArgument`: the
        /// id and ownership are fine, it's specifically the version echo that's stale.
        func testSendRejectsStaleRevisionWithNoTerminalWriteOrArchive() throws {
            try withTemporaryProfile { _ in
                try seedWorkspace(id: "workspace-1")
                try seedDraftComment(id: "comment-1", workspaceID: "workspace-1", filePath: "a.swift")
                try seedTerminalSession(sessionID: "agent-session", workspaceID: "workspace-1", state: .running)

                let paths = try TerminalSessionPaths.forSession(id: "agent-session")
                try paths.ensureDirectories()
                let recorder = ReviewCommentTerminalControlRecorder()
                let controlServer = TerminalControlServer(
                    socketPath: paths.controlSocketPath, queue: DispatchQueue(label: "spaces.review-comment.send.stale.test")
                ) { request in
                    recorder.record(request)
                    return TerminalControlResponse(ok: true, message: "Sent input.")
                }
                try controlServer.start()
                defer { controlServer.stop() }

                let (server, client, clientApp, token) = try makeServerAndClient()
                defer {
                    client.cancel()
                    server.stop()
                }

                let response = try client.send(
                    SpacesDeviceAPIRequest(
                        command: .workspaceReviewCommentsSend(
                            .init(
                                workspaceID: "workspace-1", sessionID: "agent-session", text: "please fix these",
                                comments: [.init(id: "comment-1", revision: 41)])), authToken: token,
                        clientApp: clientApp))

                XCTAssertFalse(response.ok)
                XCTAssertEqual(response.errorCode, .conflict)
                XCTAssertTrue(recorder.requests().isEmpty)
                let store = try SQLiteStore(path: DatabaseLocator.defaultPath())
                XCTAssertNil(try store.reviewComment(id: "comment-1")?.sentAt)
            }
        }

        /// The success path: writes `text` to the session's control socket (the same mechanism
        /// `sendTerminalInput` uses) and archives every requested comment whose echoed `revision`
        /// matches — the matching-version counterpart of `testSendRejectsStaleRevisionWithNoTerminalWriteOrArchive`.
        func testSendWritesToTerminalAndArchivesComments() throws {
            try withTemporaryProfile { _ in
                try seedWorkspace(id: "workspace-1")
                try seedDraftComment(id: "comment-1", workspaceID: "workspace-1", filePath: "a.swift")
                try seedDraftComment(id: "comment-2", workspaceID: "workspace-1", filePath: "b.swift")
                try seedTerminalSession(sessionID: "agent-session", workspaceID: "workspace-1", state: .running)

                let paths = try TerminalSessionPaths.forSession(id: "agent-session")
                try paths.ensureDirectories()
                let recorder = ReviewCommentTerminalControlRecorder()
                let controlServer = TerminalControlServer(
                    socketPath: paths.controlSocketPath, queue: DispatchQueue(label: "spaces.review-comment.send.test")
                ) { request in
                    recorder.record(request)
                    return TerminalControlResponse(ok: true, message: "Sent input.")
                }
                try controlServer.start()
                defer { controlServer.stop() }

                let (server, client, clientApp, token) = try makeServerAndClient()
                defer {
                    client.cancel()
                    server.stop()
                }

                let response = try client.send(
                    SpacesDeviceAPIRequest(
                        command: .workspaceReviewCommentsSend(
                            .init(
                                workspaceID: "workspace-1", sessionID: "agent-session", text: "please fix these",
                                comments: sendEntries(["comment-1", "comment-2"]))), authToken: token, clientApp: clientApp))

                XCTAssertTrue(response.ok, response.message)
                let sentRequests = recorder.requests()
                XCTAssertEqual(sentRequests.count, 1)
                let sentRequest = try XCTUnwrap(sentRequests.first)
                XCTAssertEqual(sentRequest.command, "send")
                XCTAssertEqual(sentRequest.text, "please fix these")
                XCTAssertEqual(sentRequest.appendNewline, true)

                let store = try SQLiteStore(path: DatabaseLocator.defaultPath())
                let first = try XCTUnwrap(store.reviewComment(id: "comment-1"))
                let second = try XCTUnwrap(store.reviewComment(id: "comment-2"))
                XCTAssertNotNil(first.sentAt)
                XCTAssertNotNil(second.sentAt)
                // Archived comments no longer appear as drafts.
                XCTAssertTrue(try store.reviewCommentDrafts(workspaceID: "workspace-1").isEmpty)
            }
        }

        /// Fix 4 (P1): `.workspaceReviewCommentsSend` and `.workspaceReviewCommentUpsert` serialize on the
        /// server's `reviewCommentQueue`, closing the TOCTOU window a `revision` check alone cannot: a send
        /// validates each comment's `revision` well before it archives, and an edit that lands in that gap
        /// would otherwise be silently discarded once the (already-validated, now-stale) send text is
        /// archived over it.
        ///
        /// The terminal-control double blocks mid-request (via `sendEnteredSocket`/`releaseSend`) so the
        /// send handler is provably still holding `reviewCommentQueue` — past its `revision` check, inside
        /// the terminal-write step — while a concurrent upsert is fired from a second client connection.
        /// The upsert is asserted not to complete while held; once released, the send finishes and archives
        /// the comment, and only then does the queued upsert run — landing on the ordinary "already sent"
        /// rejection rather than silently overwriting the archived text. That rejection is the proof the two
        /// operations never interleaved: without `reviewCommentQueue`, the upsert would race in while
        /// `sentAt` is still nil, succeed, and have its edit thrown away the instant the send it raced
        /// against archives over it.
        func testSendAndUpsertSerializeOnReviewCommentQueue() throws {
            try withTemporaryProfile { _ in
                try seedWorkspace(id: "workspace-1")
                try seedDraftComment(id: "comment-1", workspaceID: "workspace-1", filePath: "a.swift")
                try seedTerminalSession(sessionID: "agent-session", workspaceID: "workspace-1", state: .running)

                let paths = try TerminalSessionPaths.forSession(id: "agent-session")
                try paths.ensureDirectories()
                let sendEnteredSocket = DispatchSemaphore(value: 0)
                let releaseSend = DispatchSemaphore(value: 0)
                let controlServer = TerminalControlServer(
                    socketPath: paths.controlSocketPath, queue: DispatchQueue(label: "spaces.review-comment.serialize.test")
                ) { _ in
                    sendEnteredSocket.signal()
                    _ = releaseSend.wait(timeout: .now() + 5)
                    return TerminalControlResponse(ok: true, message: "Sent input.")
                }
                try controlServer.start()
                defer { controlServer.stop() }

                let identity = try reviewCommentTestTLSIdentity()
                let pairingStore = AlwaysAuthorizedReviewCommentPairingStore()
                let server = SpacesDeviceAPIServer(host: "127.0.0.1", port: 0, identity: identity, pairingStoreProtocol: pairingStore)
                try server.start()
                defer { server.stop() }
                let resolver = SpacesDeviceEndpointResolver(
                    hosts: ["127.0.0.1"], port: server.listeningPort, certificateFingerprint: identity.certificateFingerprint)
                let clientApp = SpacesDeviceClientApp(
                    installationID: "review-comment-test", bundleID: SpacesDeviceFirstPartyPolicy.allowedBundleID, platform: "macos",
                    deviceName: "Mac", appVersion: "1.0")
                let token = pairingStore.authToken

                // Two separate connections, since one client serializes its own requests behind its own
                // lock (see `SpacesDeviceAPIRequestSessionClient.send`) and the point here is a genuine
                // two-connection race arriving at the daemon concurrently.
                let sendClient = try SpacesDeviceAPIRequestSessionClient(resolver: resolver)
                defer { sendClient.cancel() }
                let upsertClient = try SpacesDeviceAPIRequestSessionClient(resolver: resolver)
                defer { upsertClient.cancel() }

                let sendRequest = SpacesDeviceAPIRequest(
                    command: .workspaceReviewCommentsSend(
                        .init(
                            workspaceID: "workspace-1", sessionID: "agent-session", text: "please fix these",
                            comments: sendEntries(["comment-1"]))), authToken: token, clientApp: clientApp)
                let sendResultBox = ReviewCommentAsyncResultBox<SpacesDeviceAPIResponse>()
                DispatchQueue.global(qos: .userInitiated).async {
                    sendResultBox.set(Result { try sendClient.send(sendRequest) })
                }

                // Wait until the send handler has validated `revision` and reached the terminal-control
                // write — proof it is holding `reviewCommentQueue` for the rest of its body, not just for
                // the initial validation loop.
                XCTAssertEqual(sendEnteredSocket.wait(timeout: .now() + 5), .success, "send never reached the terminal-control write")

                let upsertRequest = SpacesDeviceAPIRequest(
                    command: .workspaceReviewCommentUpsert(
                        .init(
                            workspaceID: "workspace-1", id: "comment-1", filePath: "a.swift", side: .new, lineNumber: 1,
                            lineText: "let x = 1", body: "raced edit")), authToken: token, clientApp: clientApp)
                let upsertResultBox = ReviewCommentAsyncResultBox<SpacesDeviceAPIResponse>()
                DispatchQueue.global(qos: .userInitiated).async {
                    upsertResultBox.set(Result { try upsertClient.send(upsertRequest) })
                }

                // Give the upsert ample time to race in if `reviewCommentQueue` were not actually serializing
                // the two handlers; it must still be blocked because the send has not released the queue yet.
                Thread.sleep(forTimeInterval: 0.3)
                XCTAssertNil(upsertResultBox.peek(), "upsert must not complete while the send holds reviewCommentQueue")

                releaseSend.signal()

                guard let sendResult = sendResultBox.wait(timeout: 5) else {
                    XCTFail("send did not complete after being released")
                    return
                }
                let sendResponse = try sendResult.get()
                XCTAssertTrue(sendResponse.ok, sendResponse.message)

                guard let upsertResult = upsertResultBox.wait(timeout: 5) else {
                    XCTFail("upsert did not complete after the send released reviewCommentQueue")
                    return
                }
                let upsertResponse = try upsertResult.get()
                XCTAssertFalse(upsertResponse.ok)
                XCTAssertTrue(upsertResponse.message.contains("already sent"), upsertResponse.message)

                let store = try SQLiteStore(path: DatabaseLocator.defaultPath())
                let archived = try XCTUnwrap(store.reviewComment(id: "comment-1"))
                XCTAssertNotNil(archived.sentAt)
                // The raced edit never landed: the archived text is exactly what the draft held before
                // either request started.
                XCTAssertEqual(archived.body, "draft body")
            }
        }

        /// round-13 Fix 3: `.workspaceReviewCommentUpsert`/`.workspaceReviewCommentDelete` divert to
        /// `terminalControlQueue` (see `runsOnTerminalControlQueue`) instead of running on the main serial
        /// device-API queue. Before this fix, an upsert blocked on `reviewCommentQueue` behind an in-flight
        /// send would block on the STATE queue itself (a single serial executor), stalling every unrelated
        /// request — including a `.ping` sent purely to check whether the connection is still alive — behind
        /// one comment save. This test proves the state queue stays responsive: a third connection's `.ping`
        /// resolves quickly even while a send is blocked mid-flight holding `reviewCommentQueue` and a
        /// concurrent upsert is queued behind it on that same queue.
        func testPingStaysResponsiveWhileSendAndUpsertAreBlockedOnReviewCommentQueue() throws {
            try withTemporaryProfile { _ in
                try seedWorkspace(id: "workspace-1")
                try seedDraftComment(id: "comment-1", workspaceID: "workspace-1", filePath: "a.swift")
                try seedTerminalSession(sessionID: "agent-session", workspaceID: "workspace-1", state: .running)

                let paths = try TerminalSessionPaths.forSession(id: "agent-session")
                try paths.ensureDirectories()
                let sendEnteredSocket = DispatchSemaphore(value: 0)
                let releaseSend = DispatchSemaphore(value: 0)
                let controlServer = TerminalControlServer(
                    socketPath: paths.controlSocketPath, queue: DispatchQueue(label: "spaces.review-comment.ping-responsive.test")
                ) { _ in
                    sendEnteredSocket.signal()
                    _ = releaseSend.wait(timeout: .now() + 5)
                    return TerminalControlResponse(ok: true, message: "Sent input.")
                }
                try controlServer.start()
                defer { controlServer.stop() }

                let identity = try reviewCommentTestTLSIdentity()
                let pairingStore = AlwaysAuthorizedReviewCommentPairingStore()
                let server = SpacesDeviceAPIServer(host: "127.0.0.1", port: 0, identity: identity, pairingStoreProtocol: pairingStore)
                try server.start()
                defer { server.stop() }
                let resolver = SpacesDeviceEndpointResolver(
                    hosts: ["127.0.0.1"], port: server.listeningPort, certificateFingerprint: identity.certificateFingerprint)
                let clientApp = SpacesDeviceClientApp(
                    installationID: "review-comment-test", bundleID: SpacesDeviceFirstPartyPolicy.allowedBundleID, platform: "macos",
                    deviceName: "Mac", appVersion: "1.0")
                let token = pairingStore.authToken

                // Three separate connections: send and upsert race genuinely (see
                // `testSendAndUpsertSerializeOnReviewCommentQueue`'s rationale for why one client per racing
                // request is required), and the third is the probe this test is actually about — a `.ping`
                // that must not queue behind the other two on the state queue.
                let sendClient = try SpacesDeviceAPIRequestSessionClient(resolver: resolver)
                defer { sendClient.cancel() }
                let upsertClient = try SpacesDeviceAPIRequestSessionClient(resolver: resolver)
                defer { upsertClient.cancel() }
                let pingClient = try SpacesDeviceAPIRequestSessionClient(resolver: resolver)
                defer { pingClient.cancel() }

                let sendRequest = SpacesDeviceAPIRequest(
                    command: .workspaceReviewCommentsSend(
                        .init(
                            workspaceID: "workspace-1", sessionID: "agent-session", text: "please fix these",
                            comments: sendEntries(["comment-1"]))), authToken: token, clientApp: clientApp)
                let sendResultBox = ReviewCommentAsyncResultBox<SpacesDeviceAPIResponse>()
                DispatchQueue.global(qos: .userInitiated).async {
                    sendResultBox.set(Result { try sendClient.send(sendRequest) })
                }

                XCTAssertEqual(sendEnteredSocket.wait(timeout: .now() + 5), .success, "send never reached the terminal-control write")

                let upsertRequest = SpacesDeviceAPIRequest(
                    command: .workspaceReviewCommentUpsert(
                        .init(
                            workspaceID: "workspace-1", id: "comment-1", filePath: "a.swift", side: .new, lineNumber: 1,
                            lineText: "let x = 1", body: "raced edit")), authToken: token, clientApp: clientApp)
                let upsertResultBox = ReviewCommentAsyncResultBox<SpacesDeviceAPIResponse>()
                DispatchQueue.global(qos: .userInitiated).async {
                    upsertResultBox.set(Result { try upsertClient.send(upsertRequest) })
                }

                // Give the upsert time to queue behind the send on `reviewCommentQueue` before probing: the
                // point of the ping below is that it resolves despite both of these still being blocked.
                Thread.sleep(forTimeInterval: 0.3)
                XCTAssertNil(upsertResultBox.peek(), "upsert must not complete while the send holds reviewCommentQueue")

                let pingStart = Date()
                let pingResponse = try pingClient.send(SpacesDeviceAPIRequest(command: .ping, authToken: token, clientApp: clientApp))
                let pingElapsed = Date().timeIntervalSince(pingStart)
                XCTAssertTrue(pingResponse.ok, pingResponse.message)
                XCTAssertLessThan(pingElapsed, 1.0, "ping must not queue behind the blocked send/upsert on the state queue")

                releaseSend.signal()

                guard let sendResult = sendResultBox.wait(timeout: 5) else {
                    XCTFail("send did not complete after being released")
                    return
                }
                XCTAssertTrue(try sendResult.get().ok)

                guard let upsertResult = upsertResultBox.wait(timeout: 5) else {
                    XCTFail("upsert did not complete after the send released reviewCommentQueue")
                    return
                }
                let upsertResponse = try upsertResult.get()
                XCTAssertFalse(upsertResponse.ok)
                XCTAssertTrue(upsertResponse.message.contains("already sent"), upsertResponse.message)
            }
        }

        // MARK: - Fixtures

        private func seedWorkspace(id: String, projectID: String = "project-1") throws {
            let store = try SQLiteStore(path: DatabaseLocator.defaultPath())
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
            if try store.project(id: projectID) == nil {
                try store.upsert(
                    project: ProjectRecord(
                        id: projectID, name: "Spaces", dir: dir, isGitRepo: false, defaultBranch: nil, setupScript: nil, stopScript: nil,
                        ports: [], processes: [], browserSessions: []))
            }
            // `branch` is unique per project, so two workspaces seeded under the same project (several
            // tests here seed "workspace-1" and "workspace-2" under the default "project-1") need
            // distinct branch names — a shared literal collides on `(project_id, branch)`.
            try store.upsert(
                workspace: WorkspaceRecord(
                    id: id, projectID: projectID, dir: dir + "/" + id, dirname: nil, branch: "feature-\(id)", isDefault: false, isRunning: false,
                    lastLaunchedAt: nil))
        }

        @discardableResult private func seedDraftComment(
            id: String, workspaceID: String, filePath: String, sentAt: String? = nil
        ) throws -> WorkspaceReviewCommentRecord {
            let store = try SQLiteStore(path: DatabaseLocator.defaultPath())
            let record = WorkspaceReviewCommentRecord(
                id: id, workspaceID: workspaceID, filePath: filePath, side: .new, lineNumber: 1, lineText: "let x = 1", body: "draft body",
                createdAt: "2026-08-20T09:00:00Z", updatedAt: "2026-08-20T09:00:00Z", revision: 0, sentAt: sentAt)
            try store.upsertReviewComment(record)
            return record
        }

        /// Builds send entries with `seedDraftComment`'s default `revision` (a fresh insert always starts
        /// at 0), so a test that isn't specifically exercising the version-echo check can name comments
        /// without repeating that literal at every call site.
        private func sendEntries(_ ids: [String], revision: Int = 0) -> [SpacesDeviceReviewCommentSendEntry] {
            ids.map { SpacesDeviceReviewCommentSendEntry(id: $0, revision: revision) }
        }

        private func seedTerminalSession(
            sessionID: String, workspaceID: String, state: TerminalSessionState, agentStatus: AgentWindowStatus = .idle
        ) throws {
            let paths = try TerminalSessionPaths.forSession(id: sessionID)
            try paths.ensureDirectories()
            try TerminalSessionPersistence.writeLaunchConfiguration(
                TerminalSessionLaunchConfiguration(
                    sessionID: sessionID, title: "Agent", workingDirectory: "/tmp", shell: "/bin/zsh", command: nil,
                    createdAt: "2026-08-20T09:00:00Z", workspaceID: workspaceID, kind: .agent),
                paths: paths)
            try TerminalSessionPersistence.writeRuntimeState(
                TerminalSessionRuntimeState(sessionID: sessionID, servicePID: 1, childPID: 1, state: state, updatedAt: "2026-08-20T09:00:00Z"),
                paths: paths)
            let store = try SQLiteStore(path: DatabaseLocator.defaultPath())
            try store.upsertAgentWindow(
                AgentWindowRecord(
                    id: "agent-\(sessionID)", workspaceID: workspaceID, provider: .spaces, label: "Codex", terminalTrackingID: sessionID,
                    sessionKey: nil, status: agentStatus,
                    createdAt: "2026-08-20T09:00:00Z", updatedAt: "2026-08-20T09:00:00Z"))
        }

        private func makeServerAndClient() throws -> (
            server: SpacesDeviceAPIServer, client: SpacesDeviceAPIRequestSessionClient, clientApp: SpacesDeviceClientApp, token: String
        ) {
            let identity = try reviewCommentTestTLSIdentity()
            let pairingStore = AlwaysAuthorizedReviewCommentPairingStore()
            let server = SpacesDeviceAPIServer(host: "127.0.0.1", port: 0, identity: identity, pairingStoreProtocol: pairingStore)
            try server.start()
            let client = try SpacesDeviceAPIRequestSessionClient(
                resolver: SpacesDeviceEndpointResolver(
                    hosts: ["127.0.0.1"], port: server.listeningPort, certificateFingerprint: identity.certificateFingerprint))
            let clientApp = SpacesDeviceClientApp(
                installationID: "review-comment-test", bundleID: SpacesDeviceFirstPartyPolicy.allowedBundleID, platform: "macos",
                deviceName: "Mac", appVersion: "1.0")
            return (server, client, clientApp, pairingStore.authToken)
        }

        private func withTemporaryProfile(_ body: (URL) throws -> Void) throws {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let originalDatabasePath = ProcessInfo.processInfo.environment[SpacesProfile.databasePathEnvironmentVariable]
            let originalRuntimePath = ProcessInfo.processInfo.environment[SpacesProfile.runtimeDirectoryEnvironmentVariable]
            setenv(SpacesProfile.databasePathEnvironmentVariable, root.appendingPathComponent("spaces.db").path, 1)
            unsetenv(SpacesProfile.runtimeDirectoryEnvironmentVariable)
            defer {
                if let originalDatabasePath {
                    setenv(SpacesProfile.databasePathEnvironmentVariable, originalDatabasePath, 1)
                } else {
                    unsetenv(SpacesProfile.databasePathEnvironmentVariable)
                }
                if let originalRuntimePath {
                    setenv(SpacesProfile.runtimeDirectoryEnvironmentVariable, originalRuntimePath, 1)
                } else {
                    unsetenv(SpacesProfile.runtimeDirectoryEnvironmentVariable)
                }
                try? FileManager.default.removeItem(at: root)
            }
            try body(root)
        }

        private let reviewCommentTestTLSRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
            "spaces-review-comment-tests-tls-\(UUID().uuidString)", isDirectory: true)

        private func reviewCommentTestTLSIdentity() throws -> TerminalServiceTLSIdentity {
            try TerminalServiceTLSIdentityStore.loadOrCreate(root: reviewCommentTestTLSRoot)
        }
    }

    /// Records the control requests a stand-in terminal session receives. The control server dispatches
    /// on its own queue, so access is lock-guarded.
    private final class ReviewCommentTerminalControlRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var storedRequests: [TerminalControlRequest] = []

        func record(_ request: TerminalControlRequest) {
            lock.lock()
            storedRequests.append(request)
            lock.unlock()
        }

        func requests() -> [TerminalControlRequest] {
            lock.lock()
            defer { lock.unlock() }
            return storedRequests
        }
    }

    /// One-shot result holder used to hand a `Result` computed on a background queue back to the test
    /// thread, mirroring `ReviewCommentTerminalControlRecorder`'s lock-guarded access pattern. `peek()` is
    /// a non-blocking read used to assert nothing has landed yet; `wait(timeout:)` blocks for a result.
    private final class ReviewCommentAsyncResultBox<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private let semaphore = DispatchSemaphore(value: 0)
        private var storedResult: Result<Value, Error>?

        func set(_ result: Result<Value, Error>) {
            lock.lock()
            storedResult = result
            lock.unlock()
            semaphore.signal()
        }

        func peek() -> Result<Value, Error>? {
            lock.lock()
            defer { lock.unlock() }
            return storedResult
        }

        func wait(timeout: TimeInterval) -> Result<Value, Error>? {
            _ = semaphore.wait(timeout: .now() + timeout)
            return peek()
        }
    }

    private final class AlwaysAuthorizedReviewCommentPairingStore: SpacesDevicePairingStoreProtocol {
        let authToken = "valid-token"

        func issueToken(for _: SpacesDeviceClientApp, presentedToken _: String?) throws -> String { authToken }
        func listDevices() throws -> [SpacesDevicePairedClient] { [] }
        func revoke(installationID _: String) throws {}
        func removeAll() throws {}
        func authorize(clientApp: SpacesDeviceClientApp?, authToken: String?) throws {
            guard clientApp != nil, authToken == self.authToken else {
                throw NSError(domain: "SpacesDeviceAPIServer", code: 401, userInfo: [NSLocalizedDescriptionKey: "Invalid device auth token."])
            }
        }
        func validate(clientApp _: SpacesDeviceClientApp) throws {}
    }
#endif
