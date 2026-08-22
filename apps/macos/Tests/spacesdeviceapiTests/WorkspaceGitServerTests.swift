#if canImport(Network) && canImport(Security)
    import Darwin
    import Foundation
    import XCTest

    @testable import spacesdeviceapi
    @testable import spacesdevicecore
    @testable import spacesterminalcore
    import workspacecore

    /// End-to-end coverage for `workspaceFileRead`/`workspaceFileWrite`/`workspaceDiff` over the real
    /// TLS request/response path, complementing `SpacesDeviceWorkspaceGitTests.swift`'s pure-logic
    /// coverage of the path resolver and diff engine. `SpacesDeviceAPIServer` holds its
    /// `RemoteWorkspaceGitClient` as a non-injectable stored property, so these tests seed a real
    /// on-disk git fixture (mirroring `SpacesDeviceWorkspaceGitTests.makeRepo`) and a real workspace
    /// row pointed at it, rather than mocking the git client.
    final class WorkspaceGitServerTests: XCTestCase {
        func testWorkspaceFileReadReturnsContentSHAAndSize() throws {
            try withWorkspaceFixture { workspaceID, repo, server, requestClient, clientApp, authToken in
                try "hello workspace".write(to: repo.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)

                let response = try requestClient.send(
                    SpacesDeviceAPIRequest(
                        command: .workspaceFileRead(SpacesDeviceWorkspaceFileReadRequest(workspaceID: workspaceID, relativePath: "README.md")),
                        authToken: authToken, clientApp: clientApp))

                XCTAssertTrue(response.ok, response.message)
                let result = try XCTUnwrap(response.workspaceFileRead)
                let data = try XCTUnwrap(Data(base64Encoded: result.base64Data))
                XCTAssertEqual(String(data: data, encoding: .utf8), "hello workspace")
                XCTAssertEqual(result.size, data.count)
                XCTAssertEqual(result.sha256, SpacesDeviceWorkspaceGitHashing.sha256Hex(data))
                XCTAssertFalse(result.isBinaryGuess)
            }
        }

        func testWorkspaceFileReadRejectsAPathThatEscapesTheWorkspace() throws {
            try withWorkspaceFixture { workspaceID, _, server, requestClient, clientApp, authToken in
                let response = try requestClient.send(
                    SpacesDeviceAPIRequest(
                        command: .workspaceFileRead(SpacesDeviceWorkspaceFileReadRequest(workspaceID: workspaceID, relativePath: "../escape.txt")),
                        authToken: authToken, clientApp: clientApp))

                XCTAssertFalse(response.ok)
                XCTAssertEqual(response.errorCode, .invalidArgument)
            }
        }

        func testWorkspaceFileReadOnAMissingFileReturnsNotFound() throws {
            try withWorkspaceFixture { workspaceID, _, server, requestClient, clientApp, authToken in
                let response = try requestClient.send(
                    SpacesDeviceAPIRequest(
                        command: .workspaceFileRead(SpacesDeviceWorkspaceFileReadRequest(workspaceID: workspaceID, relativePath: "does-not-exist.txt")),
                        authToken: authToken, clientApp: clientApp))

                XCTAssertFalse(response.ok)
                XCTAssertEqual(response.errorCode, .notFound)
            }
        }

        func testWorkspaceFileReadOnAnUnknownWorkspaceReturnsNotFound() throws {
            try withWorkspaceFixture { _, _, server, requestClient, clientApp, authToken in
                let response = try requestClient.send(
                    SpacesDeviceAPIRequest(
                        command: .workspaceFileRead(SpacesDeviceWorkspaceFileReadRequest(workspaceID: "no-such-workspace", relativePath: "README.md")),
                        authToken: authToken, clientApp: clientApp))

                XCTAssertFalse(response.ok)
                XCTAssertEqual(response.errorCode, .notFound)
                // Round-10 fix 3: the workspace-git routing chokepoint rejects an id that does not resolve
                // to a real workspace before it ever mints that id's entry in the per-workspace queue
                // registry, so an arbitrary/nonexistent id can never grow it without bound.
                XCTAssertNil(server.workspaceGitQueuesByWorkspaceID["no-such-workspace"])
            }
        }

        func testWorkspaceFileWriteCreatesANewFileWhenExpectedSHAIsNil() throws {
            try withWorkspaceFixture { workspaceID, repo, server, requestClient, clientApp, authToken in
                let content = Data("brand new file".utf8)
                let response = try requestClient.send(
                    SpacesDeviceAPIRequest(
                        command: .workspaceFileWrite(
                            SpacesDeviceWorkspaceFileWriteRequest(
                                workspaceID: workspaceID, relativePath: "NEW.md", base64Data: content.base64EncodedString(), expectedSHA256: nil)),
                        authToken: authToken, clientApp: clientApp))

                XCTAssertTrue(response.ok, response.message)
                let result = try XCTUnwrap(response.workspaceFileWrite)
                XCTAssertTrue(result.didWrite)
                XCTAssertEqual(result.sha256, SpacesDeviceWorkspaceGitHashing.sha256Hex(content))
                XCTAssertEqual(try Data(contentsOf: repo.appendingPathComponent("NEW.md")), content)
            }
        }

        func testWorkspaceFileWriteWithAMatchingSHAOverwritesTheFile() throws {
            try withWorkspaceFixture { workspaceID, repo, server, requestClient, clientApp, authToken in
                let original = Data("initial".utf8)
                try original.write(to: repo.appendingPathComponent("README.md"))
                let originalSHA = SpacesDeviceWorkspaceGitHashing.sha256Hex(original)

                let updated = Data("updated content".utf8)
                let response = try requestClient.send(
                    SpacesDeviceAPIRequest(
                        command: .workspaceFileWrite(
                            SpacesDeviceWorkspaceFileWriteRequest(
                                workspaceID: workspaceID, relativePath: "README.md", base64Data: updated.base64EncodedString(),
                                expectedSHA256: originalSHA)),
                        authToken: authToken, clientApp: clientApp))

                XCTAssertTrue(response.ok, response.message)
                let result = try XCTUnwrap(response.workspaceFileWrite)
                XCTAssertTrue(result.didWrite)
                XCTAssertEqual(try Data(contentsOf: repo.appendingPathComponent("README.md")), updated)
            }
        }

        /// A stale `expectedSHA256` (the file changed on disk since the client last read it) is a CAS
        /// conflict, not a transport error: the response is `ok: true` with `didWrite: false` and the
        /// server's current content/hash so the client can three-way merge and retry.
        func testWorkspaceFileWriteWithAStaleSHAReportsAConflictInsteadOfFailing() throws {
            try withWorkspaceFixture { workspaceID, repo, server, requestClient, clientApp, authToken in
                let onDisk = Data("changed underneath you".utf8)
                try onDisk.write(to: repo.appendingPathComponent("README.md"))

                let response = try requestClient.send(
                    SpacesDeviceAPIRequest(
                        command: .workspaceFileWrite(
                            SpacesDeviceWorkspaceFileWriteRequest(
                                workspaceID: workspaceID, relativePath: "README.md", base64Data: Data("my edit".utf8).base64EncodedString(),
                                expectedSHA256: "stale-sha-that-does-not-match")),
                        authToken: authToken, clientApp: clientApp))

                XCTAssertTrue(response.ok, response.message)
                let result = try XCTUnwrap(response.workspaceFileWrite)
                XCTAssertFalse(result.didWrite)
                XCTAssertEqual(result.currentSHA256, SpacesDeviceWorkspaceGitHashing.sha256Hex(onDisk))
                let currentData = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(result.currentBase64Data)))
                XCTAssertEqual(currentData, onDisk)
                XCTAssertEqual(try Data(contentsOf: repo.appendingPathComponent("README.md")), onDisk, "the conflicting write must not land on disk")
            }
        }

        /// An oversized file already on disk makes the CAS comparison itself unusable regardless of what the
        /// client sent, so the write handler must refuse it as a hard error (mirroring the read handler's
        /// guard) rather than hash the whole file and/or report a CAS conflict.
        func testWorkspaceFileWriteWithAnOversizedFileOnDiskReturnsPayloadTooLargeInsteadOfHashingIt() throws {
            try withWorkspaceFixture { workspaceID, repo, server, requestClient, clientApp, authToken in
                let oversized = Data(repeating: 0x61, count: 11 * 1024 * 1024)
                try oversized.write(to: repo.appendingPathComponent("HUGE.md"))

                let response = try requestClient.send(
                    SpacesDeviceAPIRequest(
                        command: .workspaceFileWrite(
                            SpacesDeviceWorkspaceFileWriteRequest(
                                workspaceID: workspaceID, relativePath: "HUGE.md", base64Data: Data("small edit".utf8).base64EncodedString(),
                                expectedSHA256: nil)),
                        authToken: authToken, clientApp: clientApp))

                XCTAssertFalse(response.ok)
                XCTAssertEqual(response.errorCode, .payloadTooLarge)
                XCTAssertEqual(
                    try Data(contentsOf: repo.appendingPathComponent("HUGE.md")).count, oversized.count,
                    "the oversized file must be left untouched")
            }
        }

        /// `FileManager.contents(atPath:)` returns `nil` both for "does not exist" and "exists but could
        /// not be opened/read" (e.g. permissions). Left unguarded, the latter would present as
        /// `expectedSHA256 == nil` (create), pass the CAS guard, and silently overwrite content nobody
        /// could compare against. `posixPermissions: 0` makes the file exist but unreadable so the write
        /// handler must refuse it as a hard error rather than treat it as a fresh create.
        func testWorkspaceFileWriteCreateOnAnExistingButUnreadableFileReturnsInternalErrorInsteadOfOverwritingIt() throws {
            try withWorkspaceFixture { workspaceID, repo, server, requestClient, clientApp, authToken in
                let path = repo.appendingPathComponent("UNREADABLE.md")
                let original = Data("original content nobody can read".utf8)
                try original.write(to: path)
                try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: path.path)
                defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path.path) }

                let response = try requestClient.send(
                    SpacesDeviceAPIRequest(
                        command: .workspaceFileWrite(
                            SpacesDeviceWorkspaceFileWriteRequest(
                                workspaceID: workspaceID, relativePath: "UNREADABLE.md", base64Data: Data("attempted overwrite".utf8).base64EncodedString(),
                                expectedSHA256: nil)),
                        authToken: authToken, clientApp: clientApp))

                XCTAssertFalse(response.ok)
                XCTAssertEqual(response.errorCode, .internalError)
                try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path.path)
                XCTAssertEqual(try Data(contentsOf: path), original, "an unreadable existing file must never be overwritten by a create")
            }
        }

        /// Mirrors the write handler's fix: an existing-but-unreadable file must not be conflated with a
        /// missing one on the read path either.
        func testWorkspaceFileReadOnAnExistingButUnreadableFileReturnsInternalError() throws {
            try withWorkspaceFixture { workspaceID, repo, server, requestClient, clientApp, authToken in
                let path = repo.appendingPathComponent("UNREADABLE.md")
                try Data("secret".utf8).write(to: path)
                try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: path.path)
                defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path.path) }

                let response = try requestClient.send(
                    SpacesDeviceAPIRequest(
                        command: .workspaceFileRead(SpacesDeviceWorkspaceFileReadRequest(workspaceID: workspaceID, relativePath: "UNREADABLE.md")),
                        authToken: authToken, clientApp: clientApp))

                XCTAssertFalse(response.ok)
                XCTAssertEqual(response.errorCode, .internalError)
            }
        }

        /// A FIFO opened for reading blocks until a writer appears, with no timeout — `contents(atPath:)`
        /// would wedge this workspace's serial queue forever. The regular-file type guard (checked from the
        /// same `attributesOfItem` stat used for the size pre-check) must refuse it before any open happens,
        /// so this request returns promptly with `.invalidArgument` instead of hanging.
        func testWorkspaceFileReadOnAFIFORefusesItWithoutBlocking() throws {
            try withWorkspaceFixture { workspaceID, repo, server, requestClient, clientApp, authToken in
                let path = repo.appendingPathComponent("FIFO")
                XCTAssertEqual(mkfifo(path.path, 0o644), 0, "mkfifo failed: \(String(cString: strerror(errno)))")
                defer { try? FileManager.default.removeItem(at: path) }

                let response = try requestClient.send(
                    SpacesDeviceAPIRequest(
                        command: .workspaceFileRead(SpacesDeviceWorkspaceFileReadRequest(workspaceID: workspaceID, relativePath: "FIFO")),
                        authToken: authToken, clientApp: clientApp))

                XCTAssertFalse(response.ok)
                XCTAssertEqual(response.errorCode, .invalidArgument)
            }
        }

        /// Mirrors the read test: a create-write targeting an existing FIFO must be refused (a CAS write
        /// over a non-regular path is never meaningful) rather than blocking on `contents(atPath:)` or
        /// replacing the FIFO on disk.
        func testWorkspaceFileWriteOnAFIFORefusesItWithoutReplacingIt() throws {
            try withWorkspaceFixture { workspaceID, repo, server, requestClient, clientApp, authToken in
                let path = repo.appendingPathComponent("FIFO")
                XCTAssertEqual(mkfifo(path.path, 0o644), 0, "mkfifo failed: \(String(cString: strerror(errno)))")
                defer { try? FileManager.default.removeItem(at: path) }

                let response = try requestClient.send(
                    SpacesDeviceAPIRequest(
                        command: .workspaceFileWrite(
                            SpacesDeviceWorkspaceFileWriteRequest(
                                workspaceID: workspaceID, relativePath: "FIFO", base64Data: Data("attempted overwrite".utf8).base64EncodedString(),
                                expectedSHA256: nil)),
                        authToken: authToken, clientApp: clientApp))

                XCTAssertFalse(response.ok)
                XCTAssertEqual(response.errorCode, .invalidArgument)
                var statInfo = stat()
                XCTAssertEqual(stat(path.path, &statInfo), 0)
                XCTAssertTrue((statInfo.st_mode & S_IFMT) == S_IFIFO, "the FIFO must not have been replaced by the write attempt")
            }
        }

        func testWorkspaceFileWriteOnAnUnknownWorkspaceReturnsNotFound() throws {
            try withWorkspaceFixture { _, _, server, requestClient, clientApp, authToken in
                let response = try requestClient.send(
                    SpacesDeviceAPIRequest(
                        command: .workspaceFileWrite(
                            SpacesDeviceWorkspaceFileWriteRequest(
                                workspaceID: "no-such-workspace", relativePath: "README.md", base64Data: Data("x".utf8).base64EncodedString(),
                                expectedSHA256: nil)),
                        authToken: authToken, clientApp: clientApp))

                XCTAssertFalse(response.ok)
                XCTAssertEqual(response.errorCode, .notFound)
            }
        }

        func testWorkspaceDiffReportsUncommittedChangesOverTheWire() throws {
            try withWorkspaceFixture { workspaceID, repo, server, requestClient, clientApp, authToken in
                try "edited content".write(to: repo.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)

                let response = try requestClient.send(
                    SpacesDeviceAPIRequest(
                        command: .workspaceDiff(SpacesDeviceWorkspaceDiffRequest(workspaceID: workspaceID, refName: nil)),
                        authToken: authToken, clientApp: clientApp))

                XCTAssertTrue(response.ok, response.message)
                let result = try XCTUnwrap(response.workspaceDiff)
                let file = try XCTUnwrap(result.files.first { $0.path == "README.md" })
                XCTAssertEqual(file.status, .modified)
                XCTAssertTrue(file.patch?.contains("edited content") == true)
                XCTAssertFalse(result.scopeSignature.isEmpty)
            }
        }

        func testWorkspaceDiffOnAnUnknownWorkspaceReturnsNotFound() throws {
            try withWorkspaceFixture { _, _, server, requestClient, clientApp, authToken in
                let response = try requestClient.send(
                    SpacesDeviceAPIRequest(
                        command: .workspaceDiff(SpacesDeviceWorkspaceDiffRequest(workspaceID: "no-such-workspace", refName: nil)),
                        authToken: authToken, clientApp: clientApp))

                XCTAssertFalse(response.ok)
                XCTAssertEqual(response.errorCode, .notFound)
            }
        }

        /// Round-9: a workspace can be a plain directory with no `.git` (single workspace = project dir is
        /// a supported product type, docs/spec.md), and the picker offers Diff for every workspace
        /// regardless. Before the fix, `workspaceDiff` against such a directory surfaced whatever generic
        /// failure the first git invocation happened to produce; the fix probes `rev-parse
        /// --is-inside-work-tree` up front and returns a typed, client-renderable refusal instead.
        /// `workspaceFileRead` must keep working unmodified in the same workspace: the editor path is
        /// git-independent by design and this fix must not touch it.
        func testWorkspaceDiffOnANonGitWorkspaceReturnsInvalidArgument() throws {
            try withNonGitWorkspaceFixture { workspaceID, dir, _, requestClient, clientApp, authToken in
                try "hello".write(to: dir.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)

                let diffResponse = try requestClient.send(
                    SpacesDeviceAPIRequest(
                        command: .workspaceDiff(SpacesDeviceWorkspaceDiffRequest(workspaceID: workspaceID, refName: nil)),
                        authToken: authToken, clientApp: clientApp))

                XCTAssertFalse(diffResponse.ok)
                XCTAssertEqual(diffResponse.errorCode, .invalidArgument)
                XCTAssertEqual(diffResponse.message, "Workspace directory is not a git repository.")

                let readResponse = try requestClient.send(
                    SpacesDeviceAPIRequest(
                        command: .workspaceFileRead(SpacesDeviceWorkspaceFileReadRequest(workspaceID: workspaceID, relativePath: "README.md")),
                        authToken: authToken, clientApp: clientApp))

                XCTAssertTrue(readResponse.ok, readResponse.message)
            }
        }

        /// A `subscribeWorkspaceDiffSignature` subscription's `pollTimer` (`WorkspaceDiffSignatureSubscription`
        /// in `SpacesDeviceAPIServer`) is created suspended and only resumed once the scope's own tiny
        /// Unix-socket producer (`DeviceOverviewStreamServer`) starts successfully; releasing a still-suspended
        /// `DispatchSourceTimer` traps in libdispatch. Pre-occupying the producer's socket path with a
        /// directory forces that `start()` to fail (unlink/bind cannot succeed against a directory), which
        /// exercises the exact path the fix guards: before the fix, `addWorkspaceDiffSignatureSubscriber`
        /// throwing here deallocated `subscription` — and its still-suspended `pollTimer` — as the throw
        /// unwound, trapping the whole daemon process. With the fix (`WorkspaceDiffSignatureSubscription.start()`
        /// resumes-then-cancels the timer before rethrowing), the subscribe request fails cleanly instead, and
        /// a second, unrelated subscription proves the failure did not corrupt the server's subscriber-registry
        /// state (e.g. a stuck `queue` or a leaked scope entry blocking future subscribers).
        func testSubscribeWorkspaceDiffSignatureWithABlockedSocketPathReturnsAnErrorInsteadOfCrashingTheServer() throws {
            try withWorkspaceFixture { workspaceID, repo, server, _, clientApp, authToken in
                let blockedSocketPath = try TerminalServicePaths.workspaceDiffSignatureSocketPath(workspaceID: workspaceID, refName: nil)
                try FileManager.default.createDirectory(atPath: blockedSocketPath, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(atPath: blockedSocketPath) }

                let identity = try workspaceGitTestTLSIdentity()
                let resolver = SpacesDeviceEndpointResolver(
                    hosts: ["127.0.0.1"], port: server.listeningPort, certificateFingerprint: identity.certificateFingerprint)

                let rejected = expectation(description: "blocked subscription is rejected instead of crashing the server")
                let blockedClient = try SpacesDeviceWorkspaceDiffSignatureStreamClient(
                    workspaceID: workspaceID, refName: nil, authToken: authToken, clientApp: clientApp, resolver: resolver,
                    onFrame: { _ in XCTFail("a subscription whose producer socket could not start must never deliver a frame") },
                    onDisconnect: { error in
                        // The client's own `stop()` (called internally after the rejection) triggers a second,
                        // ordinary `onClosed(nil)` once the connection finishes cancelling; only the first,
                        // non-nil call carries the rejection this test cares about.
                        guard let error else { return }
                        guard let clientError = error as? SpacesDeviceAPIRequestClientError, case .requestRejected(_, let code) = clientError else {
                            XCTFail("expected a rejected response, got \(error)")
                            return
                        }
                        XCTAssertEqual(code, .internalError)
                        rejected.fulfill()
                    })
                try blockedClient.start()
                wait(for: [rejected], timeout: 5)
                blockedClient.stop()

                // Round 9: `relayWorkspaceDiffSignatureSubscription` refuses up front for a workspace whose
                // directory is not a git repository (`assertWorkspaceDiffScopeIsGitRepository`), which
                // includes a workspace ID with no matching row at all. This "unrelated" scope must resolve
                // to a real workspace over a real git repo so it exercises registry isolation rather than
                // that unrelated refusal; it reuses the fixture's own repo directory (`workspaces.dir` has
                // no uniqueness constraint, unlike `projects.dir`) and project under a second workspace row,
                // since only the scope key (workspace id + ref name) needs to differ from the blocked
                // subscription's, and `workspaces(project_id, branch)` is unique so the branch must differ too.
                let otherWorkspaceID = "workspace-\(UUID().uuidString)"
                let store = try SQLiteStore(path: DatabaseLocator.defaultPath())
                let fixtureWorkspace = try XCTUnwrap(store.workspace(id: workspaceID))
                try store.upsert(
                    workspace: WorkspaceRecord(
                        id: otherWorkspaceID, projectID: fixtureWorkspace.projectID, dir: repo.path, dirname: nil, branch: "other", isDefault: false,
                        isRunning: false, lastLaunchedAt: nil))

                let received = expectation(description: "an unrelated subscription still succeeds after the blocked one failed")
                let otherClient = try SpacesDeviceWorkspaceDiffSignatureStreamClient(
                    workspaceID: otherWorkspaceID, refName: nil, authToken: authToken, clientApp: clientApp, resolver: resolver,
                    onFrame: { _ in received.fulfill() },
                    onDisconnect: { error in
                        if let error { XCTFail("unrelated subscription must not be rejected: \(error)") }
                    })
                try otherClient.start()
                wait(for: [received], timeout: 5)
                otherClient.stop()
            }
        }

        /// Round-4 regression: every `subscribeWorkspaceDiffSignature` scope's `WorkspaceDiffSignatureSubscription`
        /// gets its own dedicated serial queue, created in `addWorkspaceDiffSignatureSubscriber`, never one
        /// shared across scopes. Before the fix, every subscription's poll timer and producer socket ran on one
        /// shared `workspaceDiffSignatureStreamQueue`; a wedged repository's `git` calls (now up to 30s, per the
        /// git-command timeout) would serialize behind every other subscribed scope's polling, keepalives, and
        /// socket accepts on that same queue, degrading every subscribed workspace at once, continuously, for as
        /// long as the wedge lasted.
        ///
        /// This constructs two subscriptions directly with injected `signatureProvider` closures — bypassing the
        /// real git client, which has no injection seam on `SpacesDeviceAPIServer` — each on its own dedicated
        /// queue built exactly the way `addWorkspaceDiffSignatureSubscriber` builds them. Scope A's provider
        /// blocks for 3s on every call; scope B's returns immediately. It asserts scope B's ~2s poll cadence
        /// (via provider-invocation counts, since these subscriptions are constructed outside a running
        /// `SpacesDeviceAPIServer`/relay, so there is no broadcast to observe through this seam) keeps advancing
        /// while scope A is still blocked inside its first call — the two must never be serialized against each
        /// other.
        func testIndependentDiffSignatureSubscriptionsPollOnSeparateQueuesSoASlowScopeNeverBlocksAnother() throws {
            let scopeA = SpacesDeviceAPIServer.WorkspaceDiffScope(workspaceID: "workspace-\(UUID().uuidString)", refName: nil)
            let scopeB = SpacesDeviceAPIServer.WorkspaceDiffScope(workspaceID: "workspace-\(UUID().uuidString)", refName: nil)
            let socketPathA = try TerminalServicePaths.workspaceDiffSignatureSocketPath(workspaceID: scopeA.workspaceID, refName: scopeA.refName)
            let socketPathB = try TerminalServicePaths.workspaceDiffSignatureSocketPath(workspaceID: scopeB.workspaceID, refName: scopeB.refName)

            let aCounter = InvocationCounter()
            let bCounter = InvocationCounter()

            // Dedicated per-scope queues, named exactly the way `addWorkspaceDiffSignatureSubscriber` names them,
            // so this exercises the same "never shared" contract the fix establishes.
            let queueA = DispatchQueue(label: "spaces.workspace-diff-signature.\(scopeA.workspaceID).uncommitted")
            let subscriptionA = SpacesDeviceAPIServer.WorkspaceDiffSignatureSubscription(
                scope: scopeA, socketPath: socketPathA, streamQueue: queueA,
                signatureProvider: { _ in
                    aCounter.increment()
                    Thread.sleep(forTimeInterval: 3)
                    return "signature-a"
                })
            let queueB = DispatchQueue(label: "spaces.workspace-diff-signature.\(scopeB.workspaceID).uncommitted")
            let subscriptionB = SpacesDeviceAPIServer.WorkspaceDiffSignatureSubscription(
                scope: scopeB, socketPath: socketPathB, streamQueue: queueB,
                signatureProvider: { _ in
                    bCounter.increment()
                    return "signature-b"
                })

            try subscriptionA.start()
            defer {
                subscriptionA.stop()
                try? FileManager.default.removeItem(atPath: socketPathA)
            }
            try subscriptionB.start()
            defer {
                subscriptionB.stop()
                try? FileManager.default.removeItem(atPath: socketPathB)
            }

            // Both poll timers fire at t=2s (repeating every 2s thereafter). Scope A's provider is still inside
            // its first, 3s-blocking call at t=4.5s; scope B's fast provider should have ticked twice (t=2s,
            // t=4s) in that same window if — and only if — the two subscriptions are never serialized on a
            // shared queue.
            Thread.sleep(forTimeInterval: 4.5)

            XCTAssertEqual(
                aCounter.value, 1, "scope A's poll timer should have fired exactly once by 4.5s: one 2s tick, then still inside its 3s-blocking call")
            XCTAssertGreaterThanOrEqual(bCounter.value, 2, "scope B must keep polling on its own ~2s cadence while scope A is blocked inside its provider")
        }

        /// Round-21 regression: the poll timer's tick computed `signature = signatureProvider(scope)`, recorded
        /// it, then called `server.broadcast()` — but the producer's `lineProvider` closure independently
        /// recomputed `signatureProvider(scope)` again to build the frame it actually sent, rather than reusing
        /// the tick's own value. `signatureProvider` reads the live filesystem, so a workspace change landing
        /// between those two calls could make the broadcast frame disagree with the very value the tick just
        /// compared and recorded.
        ///
        /// This constructs a subscription directly (same pattern as
        /// `testIndependentDiffSignatureSubscriptionsPollOnSeparateQueuesSoASlowScopeNeverBlocksAnother` above)
        /// with an injected provider that returns a DIFFERENT value on every call, so any extra call is
        /// immediately visible as a value mismatch rather than hiding behind a repeated constant. A raw Unix
        /// socket client reads the producer's actual frames directly — `DeviceOverviewStreamServer` is a plain,
        /// TLS-free Unix socket (the daemon's TLS/relay code is a client of it, not part of it), so no TLS or
        /// relay harness is needed to observe what it broadcasts.
        ///
        /// Expected frames with the fix: frame 0 is the connect-time fallback (the box is still nil pre-first-
        /// tick, so `lineProvider` computes fresh for that one initial frame — provider call 1, "S1"); frame 1
        /// is the first poll tick's broadcast (+2s), sharing that tick's own provider call 2, "S2". Before the
        /// fix, frame 1 would instead carry call 3's value ("S3"): call 2 for the tick's own compare, plus a
        /// second, independent call inside `lineProvider` to build the frame.
        func testWorkspaceDiffSignatureBroadcastCarriesExactlyTheValueTheTickComparedAndRecorded() throws {
            let scope = SpacesDeviceAPIServer.WorkspaceDiffScope(workspaceID: "workspace-\(UUID().uuidString)", refName: nil)
            let socketPath = try TerminalServicePaths.workspaceDiffSignatureSocketPath(workspaceID: scope.workspaceID, refName: scope.refName)
            let providerCallCounter = InvocationCounter()

            let subscription = SpacesDeviceAPIServer.WorkspaceDiffSignatureSubscription(
                scope: scope, socketPath: socketPath,
                streamQueue: DispatchQueue(label: "spaces.workspace-diff-signature.\(scope.workspaceID).uncommitted"),
                signatureProvider: { _ in "S\(providerCallCounter.increment())" })
            try subscription.start()
            defer {
                subscription.stop()
                try? FileManager.default.removeItem(atPath: socketPath)
            }

            let receivedFrames = FrameSignatureCollector()
            let secondFrameArrived = expectation(description: "the first poll tick's broadcast frame arrived")
            let client = try RawWorkspaceDiffSignatureSocketClient(socketPath: socketPath) { frame in
                receivedFrames.append(frame.scopeSignature)
                if receivedFrames.count == 2 { secondFrameArrived.fulfill() }
            }
            defer { client.stop() }

            wait(for: [secondFrameArrived], timeout: 5)

            XCTAssertEqual(receivedFrames.values, ["S1", "S2"])
            XCTAssertEqual(
                providerCallCounter.value, 2,
                "the first tick must feed exactly one provider call to both the change-compare and the broadcast frame")
        }

        // MARK: - Test helpers

        /// Thread-safe invocation counter for `signatureProvider` closures under test, which
        /// `WorkspaceDiffSignatureSubscription` calls from its own dedicated queue and which must be `@Sendable`.
        /// A local `var` capture cannot satisfy that; a lock-guarded reference type can.
        private final class InvocationCounter: @unchecked Sendable {
            private let lock = NSLock()
            private var count = 0

            @discardableResult
            func increment() -> Int {
                lock.lock()
                defer { lock.unlock() }
                count += 1
                return count
            }

            var value: Int {
                lock.lock()
                defer { lock.unlock() }
                return count
            }
        }

        /// Thread-safe ordered collector for the `scopeSignature` values a
        /// `RawWorkspaceDiffSignatureSocketClient` decodes, appended from that client's own read queue.
        private final class FrameSignatureCollector: @unchecked Sendable {
            private let lock = NSLock()
            private var storage: [String] = []

            func append(_ value: String) {
                lock.lock()
                defer { lock.unlock() }
                storage.append(value)
            }

            var values: [String] {
                lock.lock()
                defer { lock.unlock() }
                return storage
            }

            var count: Int {
                lock.lock()
                defer { lock.unlock() }
                return storage.count
            }
        }

        /// Minimal raw Unix-domain-socket line reader for a `WorkspaceDiffSignatureSubscription`'s producer
        /// socket. Used only by tests that construct the subscription directly (bypassing the full TLS
        /// request/relay path, as `testIndependentDiffSignatureSubscriptionsPollOnSeparateQueuesSoASlowScopeNeverBlocksAnother`
        /// above does) and still need to observe the actual frames it broadcasts.
        /// `DeviceOverviewStreamServer` (the producer) is payload-agnostic newline-delimited `Data` over a
        /// plain Unix socket — the daemon's TLS/relay code is just one consumer of it, not part of it — so a
        /// client this small is enough; no TLS and no `SpacesDeviceWorkspaceDiffSignatureStreamClient` needed.
        private final class RawWorkspaceDiffSignatureSocketClient: @unchecked Sendable {
            private let fileDescriptor: Int32
            private let queue = DispatchQueue(label: "test.raw-workspace-diff-signature-client")
            private var source: DispatchSourceRead?
            /// Confined to `queue`: only the read source's event handler, always dispatched there, touches it.
            private var pendingBytes = Data()
            private let onFrame: (SpacesDeviceWorkspaceDiffSignatureFrame) -> Void

            init(socketPath: String, onFrame: @escaping (SpacesDeviceWorkspaceDiffSignatureFrame) -> Void) throws {
                self.onFrame = onFrame
                let fd = socket(AF_UNIX, SOCK_STREAM, 0)
                guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                var address = sockaddr_un()
                address.sun_family = sa_family_t(AF_UNIX)
                let maxLength = MemoryLayout.size(ofValue: address.sun_path)
                let utf8Path = socketPath.utf8CString
                guard utf8Path.count <= maxLength else { throw POSIXError(.ENAMETOOLONG) }
                withUnsafeMutablePointer(to: &address.sun_path.0) { pointer in
                    utf8Path.withUnsafeBufferPointer { if let baseAddress = $0.baseAddress { memcpy(pointer, baseAddress, $0.count) } }
                }
                let connectResult = withUnsafePointer(to: &address) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
                }
                guard connectResult == 0 else {
                    let code = POSIXErrorCode(rawValue: errno) ?? .EIO
                    close(fd)
                    throw POSIXError(code)
                }
                fileDescriptor = fd
                let readSource = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
                readSource.setEventHandler { [weak self] in self?.drain() }
                readSource.setCancelHandler { close(fd) }
                source = readSource
                readSource.resume()
            }

            private func drain() {
                var readBuffer = [UInt8](repeating: 0, count: 4096)
                let count = read(fileDescriptor, &readBuffer, readBuffer.count)
                guard count > 0 else { return }
                pendingBytes.append(contentsOf: readBuffer[0..<count])
                while let newlineIndex = pendingBytes.firstIndex(of: 0x0A) {
                    let line = pendingBytes[..<newlineIndex]
                    pendingBytes.removeSubrange(...newlineIndex)
                    if let frame = try? SpacesDeviceWorkspaceDiffSignatureStreamCodec.decodeLine(Data(line)) {
                        onFrame(frame)
                    }
                }
            }

            func stop() { source?.cancel() }
        }

        // MARK: - Fixture helpers

        /// Seeds a real git repo, a matching `ProjectRecord`/`WorkspaceRecord` pointed at it, and a live
        /// TLS server/client pair, then runs `body`. Modeled on `TerminalTranscriptServerTests`'
        /// `withTemporaryProfile`/`makeServerAndClient`, extended with the workspace-git fixture that
        /// `SpacesDeviceWorkspaceGitTests.makeRepo` uses for the pure-logic suite.
        private func withWorkspaceFixture(
            _ body: (
                _ workspaceID: String, _ repo: URL, _ server: SpacesDeviceAPIServer, _ requestClient: SpacesDeviceAPIRequestSessionClient,
                _ clientApp: SpacesDeviceClientApp, _ authToken: String
            ) throws -> Void
        ) throws {
            try withTemporaryProfile { _ in
                let repo = FileManager.default.temporaryDirectory.appendingPathComponent("spaces-workspace-git-server-\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: repo) }
                try runGit(["init", "--initial-branch", "main"], cwd: repo.path)
                try "initial".write(to: repo.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
                try runGit(["add", "README.md"], cwd: repo.path)
                try runGit(["-c", "user.name=spaces-test", "-c", "user.email=test@example.com", "commit", "-m", "initial"], cwd: repo.path)

                let store = try SQLiteStore(path: DatabaseLocator.defaultPath())
                let projectID = "project-\(UUID().uuidString)"
                let workspaceID = "workspace-\(UUID().uuidString)"
                try store.upsert(project: ProjectRecord(id: projectID, name: "Fixture Project", dir: repo.path, isGitRepo: true, defaultBranch: "main"))
                try store.upsert(
                    workspace: WorkspaceRecord(
                        id: workspaceID, projectID: projectID, dir: repo.path, dirname: nil, branch: "main", isDefault: true, isRunning: false,
                        lastLaunchedAt: nil))

                let (server, requestClient, clientApp, authToken) = try makeServerAndClient()
                defer {
                    requestClient.cancel()
                    server.stop()
                }

                try body(workspaceID, repo, server, requestClient, clientApp, authToken)
            }
        }

        /// Same shape as `withWorkspaceFixture`, but `dir` is never `git init`'d: a plain project directory,
        /// exercising the non-git workspace product type `testWorkspaceDiffOnANonGitWorkspaceReturnsInvalidArgument`
        /// needs (`workspaceDiff` requires a repo; `workspaceFileRead`/`Write` do not).
        private func withNonGitWorkspaceFixture(
            _ body: (
                _ workspaceID: String, _ dir: URL, _ server: SpacesDeviceAPIServer, _ requestClient: SpacesDeviceAPIRequestSessionClient,
                _ clientApp: SpacesDeviceClientApp, _ authToken: String
            ) throws -> Void
        ) throws {
            try withTemporaryProfile { _ in
                let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
                    "spaces-workspace-git-server-nongit-\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: dir) }

                let store = try SQLiteStore(path: DatabaseLocator.defaultPath())
                let projectID = "project-\(UUID().uuidString)"
                let workspaceID = "workspace-\(UUID().uuidString)"
                try store.upsert(project: ProjectRecord(id: projectID, name: "Fixture Project", dir: dir.path, isGitRepo: false, defaultBranch: nil))
                try store.upsert(
                    workspace: WorkspaceRecord(
                        id: workspaceID, projectID: projectID, dir: dir.path, dirname: nil, branch: nil, isDefault: true, isRunning: false,
                        lastLaunchedAt: nil))

                let (server, requestClient, clientApp, authToken) = try makeServerAndClient()
                defer {
                    requestClient.cancel()
                    server.stop()
                }

                try body(workspaceID, dir, server, requestClient, clientApp, authToken)
            }
        }

        private func makeServerAndClient() throws -> (SpacesDeviceAPIServer, SpacesDeviceAPIRequestSessionClient, SpacesDeviceClientApp, String) {
            let identity = try workspaceGitTestTLSIdentity()
            let pairingStore = AlwaysAuthorizedWorkspaceGitPairingStore()
            let server = SpacesDeviceAPIServer(host: "127.0.0.1", port: 0, identity: identity, pairingStoreProtocol: pairingStore)
            try server.start()
            let requestClient = try SpacesDeviceAPIRequestSessionClient(
                resolver: SpacesDeviceEndpointResolver(
                    hosts: ["127.0.0.1"], port: server.listeningPort, certificateFingerprint: identity.certificateFingerprint))
            let clientApp = SpacesDeviceClientApp(
                installationID: "workspace-git-test", bundleID: SpacesDeviceFirstPartyPolicy.allowedBundleID, platform: "macos", deviceName: "Mac",
                appVersion: "1.0")
            return (server, requestClient, clientApp, pairingStore.authToken)
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

        @discardableResult private func runGit(_ arguments: [String], cwd: String) throws -> String {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["git"] + arguments
            process.currentDirectoryURL = URL(fileURLWithPath: cwd)
            var environment = ProcessInfo.processInfo.environment
            environment.removeValue(forKey: "GIT_DIR")
            environment.removeValue(forKey: "GIT_WORK_TREE")
            environment.removeValue(forKey: "GIT_INDEX_FILE")
            process.environment = environment
            let output = Pipe()
            let errorOutput = Pipe()
            process.standardOutput = output
            process.standardError = errorOutput
            try process.run()
            process.waitUntilExit()
            let outputData = output.fileHandleForReading.readDataToEndOfFile()
            guard process.terminationStatus == 0 else {
                let errorData = errorOutput.fileHandleForReading.readDataToEndOfFile()
                let message = String(data: errorData, encoding: .utf8) ?? "unknown git failure"
                struct GitFixtureError: Error, CustomStringConvertible { let description: String }
                throw GitFixtureError(description: "git \(arguments.joined(separator: " ")) failed: \(message)")
            }
            return String(data: outputData, encoding: .utf8) ?? ""
        }
    }

    private let workspaceGitTestTLSRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
        "spaces-workspace-git-tests-tls-\(UUID().uuidString)", isDirectory: true)

    private func workspaceGitTestTLSIdentity() throws -> TerminalServiceTLSIdentity {
        try TerminalServiceTLSIdentityStore.loadOrCreate(root: workspaceGitTestTLSRoot)
    }

    private final class AlwaysAuthorizedWorkspaceGitPairingStore: SpacesDevicePairingStoreProtocol {
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
