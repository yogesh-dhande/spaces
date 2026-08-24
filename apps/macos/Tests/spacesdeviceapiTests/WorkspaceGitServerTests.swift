#if canImport(Network) && canImport(Security)
    import Darwin
    import Foundation
    import XCTest

    @testable import spacesdeviceapi
    @testable import spacesdevicecore
    @testable import spacesterminalcore
    import spacesruntimecore
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

        /// round-13 Fix 4: a stale `expectedSHA256` whose bytes already match what's on disk is a retry of an
        /// already-landed write (its original response lost to a transport drop or the client hibernating
        /// mid-round-trip), not a genuine conflict — the client asks to write exactly the content that is
        /// already there. This must report an idempotent success (`didWrite: true`), not the `.conflict`
        /// shape `testWorkspaceFileWriteWithAStaleSHAReportsAConflictInsteadOfFailing` covers for genuinely
        /// different bytes.
        func testWorkspaceFileWriteRetryWithSameBytesAndStaleSHASucceedsIdempotently() throws {
            try withWorkspaceFixture { workspaceID, repo, server, requestClient, clientApp, authToken in
                let original = Data("initial".utf8)
                try original.write(to: repo.appendingPathComponent("README.md"))
                let originalSHA = SpacesDeviceWorkspaceGitHashing.sha256Hex(original)

                let updated = Data("updated content".utf8)
                let firstResponse = try requestClient.send(
                    SpacesDeviceAPIRequest(
                        command: .workspaceFileWrite(
                            SpacesDeviceWorkspaceFileWriteRequest(
                                workspaceID: workspaceID, relativePath: "README.md", base64Data: updated.base64EncodedString(),
                                expectedSHA256: originalSHA)),
                        authToken: authToken, clientApp: clientApp))
                XCTAssertTrue(firstResponse.ok, firstResponse.message)
                XCTAssertTrue(try XCTUnwrap(firstResponse.workspaceFileWrite).didWrite)
                let updatedSHA = SpacesDeviceWorkspaceGitHashing.sha256Hex(updated)

                // Retries with the SAME new bytes but the now-stale ORIGINAL expected SHA, as a client would
                // if it never learned the first write landed (its response was lost).
                let retryResponse = try requestClient.send(
                    SpacesDeviceAPIRequest(
                        command: .workspaceFileWrite(
                            SpacesDeviceWorkspaceFileWriteRequest(
                                workspaceID: workspaceID, relativePath: "README.md", base64Data: updated.base64EncodedString(),
                                expectedSHA256: originalSHA)),
                        authToken: authToken, clientApp: clientApp))

                XCTAssertTrue(retryResponse.ok, retryResponse.message)
                let retryResult = try XCTUnwrap(retryResponse.workspaceFileWrite)
                XCTAssertTrue(retryResult.didWrite, "an identical-bytes retry of a landed write must report success, not a conflict")
                XCTAssertEqual(retryResult.sha256, updatedSHA)
                XCTAssertNil(retryResult.currentBase64Data, "an idempotent success carries no conflict payload")
                XCTAssertEqual(
                    try Data(contentsOf: repo.appendingPathComponent("README.md")), updated,
                    "file contents are unchanged by the idempotent retry")
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

        /// Round-3 codex finding: a dangling symlink (the link exists; its target does not) whose target
        /// names a location OUTSIDE the workspace must not let a create-CAS write land there. Before the
        /// fix, `fileExists` (which follows links) reported the dangling link as a plain missing component,
        /// so the walk reappended the remaining path literally under the workspace root and containment
        /// passed against the wrong (workspace-relative) candidate while the actual write followed the link
        /// straight outside.
        func testWorkspaceFileWriteThroughADanglingSymlinkToOutsideTheWorkspaceRejectsItAndCreatesNothing() throws {
            try withWorkspaceFixture { workspaceID, repo, server, requestClient, clientApp, authToken in
                let outside = FileManager.default.temporaryDirectory.appendingPathComponent(
                    "spaces-workspace-git-server-outside-\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: outside) }
                let outsideTarget = outside.appendingPathComponent("new.txt")
                try FileManager.default.createSymbolicLink(at: repo.appendingPathComponent("dangling-outside-link"), withDestinationURL: outsideTarget)

                let response = try requestClient.send(
                    SpacesDeviceAPIRequest(
                        command: .workspaceFileWrite(
                            SpacesDeviceWorkspaceFileWriteRequest(
                                workspaceID: workspaceID, relativePath: "dangling-outside-link",
                                base64Data: Data("should not land".utf8).base64EncodedString(), expectedSHA256: nil)),
                        authToken: authToken, clientApp: clientApp))

                XCTAssertFalse(response.ok)
                XCTAssertEqual(response.errorCode, .invalidArgument)
                XCTAssertFalse(FileManager.default.fileExists(atPath: outsideTarget.path), "the write must not have created anything outside the workspace")
            }
        }

        /// Companion to the outside case above: a dangling symlink whose target names a location INSIDE the
        /// workspace must keep resolving there so the editor's "Keep mine" recreate (and a plain read of a
        /// deleted-but-still-symlinked file) keeps working.
        func testWorkspaceFileReadThenWriteThroughADanglingSymlinkToInsideTheWorkspaceRecreatesTheTarget() throws {
            try withWorkspaceFixture { workspaceID, repo, server, requestClient, clientApp, authToken in
                try FileManager.default.createSymbolicLink(
                    atPath: repo.appendingPathComponent("dangling-inside-link").path, withDestinationPath: "recreated.md")

                let readResponse = try requestClient.send(
                    SpacesDeviceAPIRequest(
                        command: .workspaceFileRead(SpacesDeviceWorkspaceFileReadRequest(workspaceID: workspaceID, relativePath: "dangling-inside-link")),
                        authToken: authToken, clientApp: clientApp))
                XCTAssertFalse(readResponse.ok)
                XCTAssertEqual(readResponse.errorCode, .notFound, "the link's target does not exist yet")

                let content = Data("keep mine".utf8)
                let writeResponse = try requestClient.send(
                    SpacesDeviceAPIRequest(
                        command: .workspaceFileWrite(
                            SpacesDeviceWorkspaceFileWriteRequest(
                                workspaceID: workspaceID, relativePath: "dangling-inside-link", base64Data: content.base64EncodedString(),
                                expectedSHA256: nil)),
                        authToken: authToken, clientApp: clientApp))

                XCTAssertTrue(writeResponse.ok, writeResponse.message)
                XCTAssertTrue(try XCTUnwrap(writeResponse.workspaceFileWrite).didWrite)
                XCTAssertEqual(try Data(contentsOf: repo.appendingPathComponent("recreated.md")), content, "the write must have landed inside the workspace, at the link's relative target")
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

        /// round-14 Fix 1 regression: a caller-supplied ref that simply does not resolve must still be
        /// rejected as `.invalidArgument` — this must keep working unmodified after `assertRefIsResolvable`'s
        /// rewrite to an exit-code-based check.
        func testWorkspaceDiffWithANonexistentRefReturnsInvalidArgument() throws {
            try withWorkspaceFixture { workspaceID, _, _, requestClient, clientApp, authToken in
                let response = try requestClient.send(
                    SpacesDeviceAPIRequest(
                        command: .workspaceDiff(SpacesDeviceWorkspaceDiffRequest(workspaceID: workspaceID, refName: "no-such-ref")),
                        authToken: authToken, clientApp: clientApp))

                XCTAssertFalse(response.ok)
                XCTAssertEqual(response.errorCode, .invalidArgument)
                XCTAssertEqual(response.message, "Ref 'no-such-ref' could not be resolved in this workspace.")
            }
        }

        /// round-14 Fix 1 regression: a ref that DOES resolve (the fixture repo's own "main" branch) must
        /// keep succeeding — `assertRefIsResolvable`'s move to `allowedExitCodes: [0, 1]` and a non-empty-stdout
        /// check must not turn a legitimate resolvable ref into a failure.
        func testWorkspaceDiffWithAResolvableRefSucceeds() throws {
            try withWorkspaceFixture { workspaceID, _, _, requestClient, clientApp, authToken in
                let response = try requestClient.send(
                    SpacesDeviceAPIRequest(
                        command: .workspaceDiff(SpacesDeviceWorkspaceDiffRequest(workspaceID: workspaceID, refName: "main")),
                        authToken: authToken, clientApp: clientApp))

                XCTAssertTrue(response.ok, response.message)
                XCTAssertNotNil(response.workspaceDiff)
            }
        }

        /// round-14 Fix 1: the actual bug fix under test. Before the fix, `assertRefIsResolvable` wrapped its
        /// `runGitAndCapture` call in `try?`, so ANY thrown failure — including an already-exhausted
        /// request-wide deadline, simulated here by handing it a `deadlineStart` far in the past —
        /// collapsed into the same "ref could not be resolved" 400 this function throws for an actually-bad
        /// ref. That is wrong even for "main", a perfectly resolvable ref in this fixture: the failure is the
        /// daemon's own trouble (a blown deadline), not a caller typo, and must propagate uncaught so the
        /// server's normal mapping (`SpacesDeviceAPIServer.errorCode(for:)`) reports it as `.internalError` —
        /// which the client's retry classification retries with backoff — rather than the permanent
        /// `.invalidArgument` rejection a genuinely bad ref gets. This test would have FAILED before the fix:
        /// the old `try?` swallowed the deadline-exhaustion throw and always produced the 400 NSError instead.
        func testAssertRefIsResolvablePropagatesADeadlineExhaustionInsteadOfMisclassifyingItAsABadRef() throws {
            let repo = FileManager.default.temporaryDirectory.appendingPathComponent(
                "spaces-assert-ref-resolvable-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: repo) }
            try runGit(["init", "--initial-branch", "main"], cwd: repo.path)
            try "initial".write(to: repo.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
            try runGit(["add", "README.md"], cwd: repo.path)
            try runGit(["-c", "user.name=spaces-test", "-c", "user.email=test@example.com", "commit", "-m", "initial"], cwd: repo.path)

            let expiredDeadlineStart = Date().addingTimeInterval(-1000)
            XCTAssertThrowsError(
                try SpacesDeviceWorkspaceDiffEngine.assertRefIsResolvable(
                    workspaceDir: repo.path, refName: "main", gitClient: RemoteWorkspaceGitClient(), deadlineStart: expiredDeadlineStart)
            ) { error in
                let nsError = error as NSError
                XCTAssertFalse(
                    nsError.domain == "SpacesDeviceAPIServer" && nsError.code == 400,
                    "a blown deadline must not be misreported as the bad-ref 400, got \(error)")
                guard case .gitCommandFailed = error as? SpacesRuntimeError else {
                    XCTFail("expected the deadline-exhaustion failure to propagate as SpacesRuntimeError.gitCommandFailed, got \(error)")
                    return
                }
                XCTAssertEqual(
                    SpacesDeviceAPIServer.errorCode(for: error), .internalError,
                    "the server's normal error mapping must report this as internalError, not invalidArgument")
            }
        }

        /// round-15: `buildDiff` now takes the same `deadlineStart` parameter `assertRefIsResolvable` above
        /// already accepted, so `handleWorkspaceDiffRequest` can share ONE clock across repo/ref validation
        /// and diff-building instead of `buildDiff` starting its own fresh `Date()` internally. Before this
        /// fix, handing `buildDiff` an already-exhausted `deadlineStart` would have had no effect at all —
        /// the parameter did not exist, and `buildDiff` measured its 45s window from its own call. This test
        /// mirrors `testAssertRefIsResolvablePropagatesADeadlineExhaustionInsteadOfMisclassifyingItAsABadRef`
        /// above: a `deadlineStart` far enough in the past that `remainingTimeout` sees zero budget left
        /// must make `buildDiff` throw immediately (`scopeSignature`'s first probe never gets a positive
        /// timeout), never spawn git as if it had a fresh 45s.
        func testBuildDiffWithAnAlreadyExpiredDeadlineStartThrowsImmediately() throws {
            let repo = FileManager.default.temporaryDirectory.appendingPathComponent(
                "spaces-build-diff-expired-deadline-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: repo) }
            try runGit(["init", "--initial-branch", "main"], cwd: repo.path)
            try "initial".write(to: repo.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
            try runGit(["add", "README.md"], cwd: repo.path)
            try runGit(["-c", "user.name=spaces-test", "-c", "user.email=test@example.com", "commit", "-m", "initial"], cwd: repo.path)

            // Well past the real 45s `diffBuildDeadline` (private to the engine, so mirrored here as a
            // literal — see this file's own `-1000` above and `SpacesDeviceWorkspaceGitTests.swift`'s
            // round-9/12 comments on why this engine has no configurable-deadline test seam).
            let expiredDeadlineStart = Date().addingTimeInterval(-1000)
            XCTAssertThrowsError(
                try SpacesDeviceWorkspaceDiffEngine.buildDiff(
                    workspaceDir: repo.path, refName: nil, gitClient: RemoteWorkspaceGitClient(), deadlineStart: expiredDeadlineStart)
            ) { error in
                guard case .gitCommandFailed = error as? SpacesRuntimeError else {
                    XCTFail("expected the request-wide deadline-elapsed failure, got \(error)")
                    return
                }
            }
        }

        /// round-15: proves `deadlineStart` is a SHARED clock rather than each call getting its own,
        /// without the flaky knife-edge timing `SpacesDeviceWorkspaceGitTests.swift`'s round-9/12 comments
        /// explicitly avoid (there is no seam here to observe the exact timeout value a fake git client
        /// would receive — `RemoteWorkspaceGitClient` is a real, non-injectable `final class`). Instead this
        /// hands `assertRefIsResolvable` and `buildDiff` the SAME `deadlineStart`, already most of the way
        /// through the 45s window (3s of budget left — generous for this tiny fixture repo's real git
        /// calls, far from the near-zero edge that would risk flaking on a loaded machine), simulating ref
        /// validation having already burned most of the shared request budget before `buildDiff` ever runs.
        /// Before this round's fix, `buildDiff` would have ignored that already-elapsed time entirely (it
        /// had no `deadlineStart` parameter and always measured a fresh 45s from its own call) — this test
        /// would still have passed on unfixed code, since a fresh 45s is even more generous than 3s, so its
        /// real value is regression coverage once combined with the fully-expired test above: together they
        /// show `buildDiff` neither ignores the shared clock (this test would still need the code to accept
        /// the parameter at all, which is the round-15 API change) nor treats a non-zero remainder as
        /// insufficient when a real git call is fast enough to fit inside it.
        func testASharedDeadlineStartAcrossRefValidationAndBuildDiffStillLeavesEnoughBudgetForAnOrdinaryDiff() throws {
            let repo = FileManager.default.temporaryDirectory.appendingPathComponent(
                "spaces-build-diff-shared-deadline-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: repo) }
            try runGit(["init", "--initial-branch", "main"], cwd: repo.path)
            try "initial".write(to: repo.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
            try runGit(["add", "README.md"], cwd: repo.path)
            try runGit(["-c", "user.name=spaces-test", "-c", "user.email=test@example.com", "commit", "-m", "initial"], cwd: repo.path)
            try "edited".write(to: repo.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)

            let client = RemoteWorkspaceGitClient()
            let sharedDeadlineStart = Date().addingTimeInterval(-42)
            try SpacesDeviceWorkspaceDiffEngine.assertRefIsResolvable(
                workspaceDir: repo.path, refName: "main", gitClient: client, deadlineStart: sharedDeadlineStart)

            let result = try SpacesDeviceWorkspaceDiffEngine.buildDiff(
                workspaceDir: repo.path, refName: nil, gitClient: client, deadlineStart: sharedDeadlineStart)
            let file = try XCTUnwrap(result.files.first { $0.path == "README.md" })
            XCTAssertFalse(file.truncated)
            XCTAssertNotNil(file.patch)
        }

        /// `buildCoalescedDeletedButUntrackedFile` (see `SpacesDeviceWorkspaceGitTests.swift`'s round-13
        /// coverage for the coalescing behavior itself) is the one file builder in this engine that spawns
        /// two git commands for a single file: `update-index --add` stages the recreated worktree content
        /// into a scratch index, then `diff` compares that scratch index against `compareRef`. Both used to
        /// share the exact same already-shrunk `timeout` value, so a slow-but-successful `update-index` could
        /// hand the second command a stale budget as if no time had passed since the first ran.
        ///
        /// This isolates the second command's own deadline recompute by giving the two new parameters
        /// deliberately different values: `timeout` is a generous 10s so the FIRST command (`update-index
        /// --add`) runs and succeeds normally, with no risk of a spurious timeout of its own; `deadlineStart`
        /// is already 1000s in the past, a value with NO effect on the first command (which only ever sees
        /// `timeout`) but that the second command's `remainingTimeout(start: deadlineStart)` recompute sees as
        /// exhausted. The fix must degrade to the same truncated shape every other cap in this engine uses
        /// (mirroring the per-file loop's own entry gate in `buildDiff`), not throw a request-level error.
        func testCoalescedDeletedButUntrackedFileDegradesToTruncatedWhenDeadlineStartIsAlreadyExpired() throws {
            let repo = FileManager.default.temporaryDirectory.appendingPathComponent(
                "spaces-coalesced-deleted-untracked-expired-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: repo) }
            try runGit(["init", "--initial-branch", "main"], cwd: repo.path)
            try "content A\nshared\n".write(to: repo.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)
            try runGit(["add", "f.txt"], cwd: repo.path)
            try runGit(["-c", "user.name=spaces-test", "-c", "user.email=test@example.com", "commit", "-m", "add f"], cwd: repo.path)

            // `git rm --cached` untracks the file from the index without touching its worktree content, then
            // the recreated content differs from the committed blob — exactly the `.deletedButUntrackedInWorktree`
            // scenario `buildDiff`'s coalescing exists for (see `SpacesDeviceWorkspaceGitTests.swift` round-13).
            try runGit(["rm", "--cached", "f.txt"], cwd: repo.path)
            try "content B\nshared\n".write(to: repo.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)

            let expiredDeadlineStart = Date().addingTimeInterval(-1000)
            let file = try SpacesDeviceWorkspaceDiffEngine.buildCoalescedDeletedButUntrackedFile(
                path: "f.txt", compareRef: "HEAD", workspaceDir: repo.path, gitClient: RemoteWorkspaceGitClient(), timeout: 10.0,
                deadlineStart: expiredDeadlineStart)

            XCTAssertTrue(file.truncated, "an expired deadlineStart at the second command's recompute must degrade to the truncated shape")
            XCTAssertEqual(file.status, .modified)
            XCTAssertNil(file.patch, "a truncated entry must carry no patch")
        }

        /// round-17 Fix B1: `assertIsGitRepository` now calls `isRepoStrict` (which throws on a could-not-run
        /// probe) instead of `isRepo` (which folded that into a plain `false`), so an execution failure must
        /// surface as the existing retryable `gitCommandFailed` → `.internalError` shape rather than the
        /// permanent "not a git repository" 400 a real non-repo gets. `RemoteWorkspaceGitClient` has no fake
        /// git executable errors to inject directly, but its `gitExecutable` initializer parameter is already
        /// an established test seam (see `RemoteWorkspaceGitClientTests.swift`'s `/bin/sleep` and
        /// stub-script substitutions) for exactly this: this stub ignores its arguments entirely and just
        /// hangs, so whatever `isRepoStrict` invokes always times out and gets killed rather than exiting
        /// with any real status — a clean simulation of "git could not run to completion" that is agnostic to
        /// the exact arguments `isRepoStrict` happens to pass. `metadataCommandTimeout` is shortened so the
        /// kill (and this test) happens promptly rather than waiting out the client's default 2s.
        ///
        /// The real non-repo regression (a confirmed non-repo directory must still report `.invalidArgument`)
        /// is already covered end-to-end by `testWorkspaceDiffOnANonGitWorkspaceReturnsInvalidArgument` above,
        /// which exercises this same `assertIsGitRepository` call through the real server path against a real
        /// plain (non-git) directory — that test would have failed to distinguish this bug (both outcomes
        /// look identical, a 400), which is exactly why this new test exists alongside it.
        func testAssertIsGitRepositoryPropagatesAnExecutionFailureInsteadOfMisclassifyingItAsANotARepo() throws {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(
                "spaces-assert-is-git-repository-exec-failure-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }

            let scriptURL = root.appendingPathComponent("stub-hangs-forever.sh")
            try "#!/bin/sh\nsleep 30\n".write(to: scriptURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

            let client = RemoteWorkspaceGitClient(gitExecutable: scriptURL.path, metadataCommandTimeout: 0.3)
            XCTAssertThrowsError(try SpacesDeviceWorkspaceDiffEngine.assertIsGitRepository(workspaceDir: root.path, gitClient: client)) { error in
                let nsError = error as NSError
                XCTAssertFalse(
                    nsError.domain == "SpacesDeviceAPIServer" && nsError.code == 400,
                    "an execution failure must not be misreported as the not-a-repo 400, got \(error)")
                guard case .gitCommandFailed = error as? SpacesRuntimeError else {
                    XCTFail("expected the execution failure to propagate as SpacesRuntimeError.gitCommandFailed, got \(error)")
                    return
                }
                XCTAssertEqual(
                    SpacesDeviceAPIServer.errorCode(for: error), .internalError,
                    "the server's normal error mapping must report this as internalError, not invalidArgument")
            }
        }

        /// round-17 Fix B2: `buildDiff`'s HEAD-existence probe (and `scopeSignature`'s parallel `headSHA`
        /// probe, now the textually identical `rev-parse --verify --quiet HEAD` invocation) must throw on an
        /// execution failure rather than collapsing it into "HEAD does not exist" (an unborn repo). `buildDiff`
        /// calls `scopeSignature` first, so in this fixture the throw actually originates from
        /// `scopeSignature`'s copy of the probe — that is expected and, since both call sites now share the
        /// exact same command shape, this is valid regression coverage for both: a fix to only one of them
        /// (or a future regression reintroducing `try?` in either) would be caught here.
        ///
        /// This stub script hangs ONLY when it recognizes this specific `rev-parse --verify --quiet HEAD`
        /// invocation and otherwise `exec`s the real `git`, so the repo fixture itself (a real, born commit)
        /// is not needed for this probe to be reachable — a real repo is used anyway for realism and so this
        /// test would also catch a regression that made some OTHER probe in the same call path start
        /// misbehaving instead. `deadlineStart` is set to leave roughly 1s of the shared request-wide budget,
        /// so the hang is killed quickly rather than waiting out the full `diffBuildDeadline`.
        ///
        /// The real unborn-HEAD regression (a genuinely HEAD-less repo must still diff against the empty
        /// tree) is already covered by `SpacesDeviceWorkspaceGitTests.swift`'s
        /// `buildDiffOnAnUnbornRepoReportsAStagedAdditionAndAnUntrackedFile`.
        func testBuildDiffHeadExistenceProbeExecutionFailurePropagatesAsInternalErrorInsteadOfMisclassifyingAsUnbornHead() throws {
            let repo = FileManager.default.temporaryDirectory.appendingPathComponent(
                "spaces-build-diff-head-probe-exec-failure-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: repo) }
            try runGit(["init", "--initial-branch", "main"], cwd: repo.path)
            try "initial".write(to: repo.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
            try runGit(["add", "README.md"], cwd: repo.path)
            try runGit(["-c", "user.name=spaces-test", "-c", "user.email=test@example.com", "commit", "-m", "initial"], cwd: repo.path)

            let scriptURL = repo.appendingPathComponent("stub-hangs-on-head-verify.sh")
            let script = """
                #!/bin/sh
                if [ "$3" = "rev-parse" ] && [ "$4" = "--verify" ] && [ "$5" = "--quiet" ] && [ "$6" = "HEAD" ]; then
                    sleep 30
                    exit 0
                fi
                exec git "$@"
                """
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

            let client = RemoteWorkspaceGitClient(gitExecutable: scriptURL.path)
            let deadlineStart = Date().addingTimeInterval(-44)
            XCTAssertThrowsError(
                try SpacesDeviceWorkspaceDiffEngine.buildDiff(workspaceDir: repo.path, refName: nil, gitClient: client, deadlineStart: deadlineStart)
            ) { error in
                guard case .gitCommandFailed = error as? SpacesRuntimeError else {
                    XCTFail("expected the HEAD-probe execution failure to propagate as SpacesRuntimeError.gitCommandFailed, got \(error)")
                    return
                }
                XCTAssertEqual(
                    SpacesDeviceAPIServer.errorCode(for: error), .internalError,
                    "the server's normal error mapping must report this as internalError, not a misclassified unborn-HEAD outcome")
            }
        }

        /// round-17 Fix B3: `buildDiff`'s workspace-prefix (`--show-prefix`) probe (and `scopeSignature`'s
        /// parallel `prefix` probe, now the textually identical invocation) must throw on an execution
        /// failure rather than collapsing it into `""` — which used to silently produce an UNSCOPED
        /// enumeration for subtree workspaces (every path in the whole repo resolved against the wrong root,
        /// not just the workspace's subtree). As with the B2 test above, `buildDiff` calls `scopeSignature`
        /// first, so the throw actually originates from `scopeSignature`'s copy of the probe here too; that is
        /// valid shared coverage for the same reason.
        ///
        /// This stub script lets `rev-parse --verify --quiet HEAD` and `status --porcelain -z
        /// --untracked-files=all` run against the real repo normally, and hangs only on the `--show-prefix`
        /// invocation, isolating the fix under test from the probes ahead of it in `scopeSignature`.
        ///
        /// The real subtree-scoping regression (a subtree workspace's enumeration and patches stay
        /// workspace-relative) is already covered by `SpacesDeviceWorkspaceGitTests.swift`'s
        /// `trackedModificationInsideTheSubtreeReportsOneWorkspaceRelativeEntryWithAWorkspaceRelativePatch` and
        /// its sibling subtree tests.
        func testBuildDiffShowPrefixProbeExecutionFailurePropagatesAsInternalErrorInsteadOfSilentlyUnscoping() throws {
            let repo = FileManager.default.temporaryDirectory.appendingPathComponent(
                "spaces-build-diff-prefix-probe-exec-failure-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: repo) }
            try runGit(["init", "--initial-branch", "main"], cwd: repo.path)
            try "initial".write(to: repo.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
            try runGit(["add", "README.md"], cwd: repo.path)
            try runGit(["-c", "user.name=spaces-test", "-c", "user.email=test@example.com", "commit", "-m", "initial"], cwd: repo.path)

            let scriptURL = repo.appendingPathComponent("stub-hangs-on-show-prefix.sh")
            let script = """
                #!/bin/sh
                if [ "$3" = "rev-parse" ] && [ "$4" = "--show-prefix" ]; then
                    sleep 30
                    exit 0
                fi
                exec git "$@"
                """
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

            let client = RemoteWorkspaceGitClient(gitExecutable: scriptURL.path)
            let deadlineStart = Date().addingTimeInterval(-44)
            XCTAssertThrowsError(
                try SpacesDeviceWorkspaceDiffEngine.buildDiff(workspaceDir: repo.path, refName: nil, gitClient: client, deadlineStart: deadlineStart)
            ) { error in
                guard case .gitCommandFailed = error as? SpacesRuntimeError else {
                    XCTFail("expected the show-prefix execution failure to propagate as SpacesRuntimeError.gitCommandFailed, got \(error)")
                    return
                }
                XCTAssertEqual(
                    SpacesDeviceAPIServer.errorCode(for: error), .internalError,
                    "the server's normal error mapping must report this as internalError, not a silently-unscoped empty prefix")
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

        // MARK: - workspaceFileSignature subscription (Phase 5 Part A)

        /// The connect-time frame (`WorkspaceFileSignatureSubscription`'s `lineProvider` computing fresh since
        /// `latestValueBox` is still nil pre-first-tick) must reflect the file's actual on-disk content at
        /// subscribe time — the first frame any subscriber ever receives.
        func testSubscribeWorkspaceFileSignatureDeliversAnInitialFrameMatchingTheFilesCurrentContent() throws {
            try withWorkspaceFixture { workspaceID, repo, server, _, clientApp, authToken in
                try "hello workspace".write(to: repo.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
                let expectedSHA = SpacesDeviceWorkspaceGitHashing.sha256Hex(Data("hello workspace".utf8))

                let identity = try workspaceGitTestTLSIdentity()
                let resolver = SpacesDeviceEndpointResolver(
                    hosts: ["127.0.0.1"], port: server.listeningPort, certificateFingerprint: identity.certificateFingerprint)

                let firstFrameArrived = expectation(description: "the initial connect-time frame arrived")
                let frames = FileSignatureFrameCollector()
                let client = try SpacesDeviceWorkspaceFileSignatureStreamClient(
                    workspaceID: workspaceID, path: "README.md", authToken: authToken, clientApp: clientApp, resolver: resolver,
                    onFrame: { frame in
                        frames.append(frame)
                        firstFrameArrived.fulfill()
                    },
                    onDisconnect: { error in if let error { XCTFail("unexpected disconnect: \(error)") } })
                try client.start()
                defer { client.stop() }
                wait(for: [firstFrameArrived], timeout: 5)

                let frame = try XCTUnwrap(frames.values.first)
                XCTAssertEqual(frame.sha256, expectedSHA)
                XCTAssertFalse(frame.missing)
            }
        }

        /// A poll tick after the file's content changes on disk must deliver a second frame carrying the
        /// updated hash — the ordinary "changed content" case `subscribeWorkspaceFileSignature` exists for.
        func testSubscribeWorkspaceFileSignatureDeliversAChangedFrameAfterTheFileIsEdited() throws {
            try withWorkspaceFixture { workspaceID, repo, server, _, clientApp, authToken in
                try "hello workspace".write(to: repo.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)

                let identity = try workspaceGitTestTLSIdentity()
                let resolver = SpacesDeviceEndpointResolver(
                    hosts: ["127.0.0.1"], port: server.listeningPort, certificateFingerprint: identity.certificateFingerprint)

                let secondFrameArrived = expectation(description: "the second, changed-content frame arrived")
                let frames = FileSignatureFrameCollector()
                let client = try SpacesDeviceWorkspaceFileSignatureStreamClient(
                    workspaceID: workspaceID, path: "README.md", authToken: authToken, clientApp: clientApp, resolver: resolver,
                    onFrame: { frame in
                        frames.append(frame)
                        if frames.count == 2 { secondFrameArrived.fulfill() }
                    },
                    onDisconnect: { error in if let error { XCTFail("unexpected disconnect: \(error)") } })
                try client.start()
                defer { client.stop() }

                // Give the initial connect-time frame a moment to land before mutating the file, so the edit
                // lands after that frame instead of racing it.
                Thread.sleep(forTimeInterval: 0.5)
                try "edited content".write(to: repo.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)

                wait(for: [secondFrameArrived], timeout: 5)

                // Guard the index rather than assume `wait(for:timeout:)` actually saw both frames: a timeout
                // there does not stop this code from running, and indexing an out-of-range element would
                // crash the whole test process (taking every later test down with it) instead of failing just
                // this one.
                guard frames.values.count > 1 else {
                    XCTFail("expected at least 2 frames, got \(frames.values.count)")
                    return
                }
                let expectedSHA = SpacesDeviceWorkspaceGitHashing.sha256Hex(Data("edited content".utf8))
                XCTAssertEqual(frames.values[1].sha256, expectedSHA)
                XCTAssertFalse(frames.values[1].missing)
            }
        }

        /// Round-tripped through the same "construct the subscription directly + a raw socket reader" pattern
        /// `testWorkspaceDiffSignatureBroadcastCarriesExactlyTheValueTheTickComparedAndRecorded` above uses:
        /// an injected `signatureProvider` returning an unchanged value across multiple poll ticks must not
        /// rebroadcast beyond the first poll tick (divergence #1's `tick`-always-increments rule means the
        /// provider IS still called every tick; only the broadcast itself is suppressed for an unchanged
        /// value). `lastBroadcastValue` starts nil, so the connect-time frame's own fresh computation never
        /// updates it — the first poll tick's compare is always against nil and so always "changes" and
        /// broadcasts once (see `WorkspaceFileSignatureSubscription`'s own doc comment), even though the
        /// value it carries is identical to the connect-time frame's. Only the SECOND tick onward, once
        /// `lastBroadcastValue` actually holds a real value to compare against, is where a truly unchanged
        /// value stops rebroadcasting — which is what this test's 4.5s window (covering exactly two ticks)
        /// is verifying: 2 total frames (connect-time + first-tick), never a 3rd from the second tick.
        func testWorkspaceFileSignatureSubscriptionDoesNotRebroadcastAnUnchangedValueAcrossMultiplePolls() throws {
            let scope = SpacesDeviceAPIServer.WorkspaceFileScope(workspaceID: "workspace-\(UUID().uuidString)", path: "unchanged.txt")
            let socketPath = try TerminalServicePaths.workspaceFileSignatureSocketPath(workspaceID: scope.workspaceID, path: scope.path)
            let providerCallCounter = InvocationCounter()

            let subscription = SpacesDeviceAPIServer.WorkspaceFileSignatureSubscription(
                scope: scope, socketPath: socketPath,
                streamQueue: DispatchQueue(label: "spaces.workspace-file-signature.\(scope.workspaceID).\(scope.path)"),
                signatureProvider: { _ in
                    providerCallCounter.increment()
                    return SpacesDeviceAPIServer.WorkspaceFileSignatureValue(sha256: "same-sha", missing: false)
                })
            try subscription.start()
            defer {
                subscription.stop()
                try? FileManager.default.removeItem(atPath: socketPath)
            }

            let receivedFrames = FileSignatureFrameCollector()
            let client = try RawWorkspaceFileSignatureSocketClient(socketPath: socketPath) { frame in receivedFrames.append(frame) }
            defer { client.stop() }

            // Two poll ticks (t=2s, t=4s) fire in this window. The first tick always broadcasts once (its
            // compare is against a still-nil `lastBroadcastValue`, even though the value itself is
            // unchanged from the connect-time frame); the second tick's compare is against a real recorded
            // value and so must not rebroadcast. Expected total: connect-time frame + first-tick frame = 2.
            Thread.sleep(forTimeInterval: 4.5)

            XCTAssertEqual(
                receivedFrames.count, 2,
                "expected exactly the connect-time frame plus the first poll tick's mandatory broadcast; a 3rd frame would mean the second tick "
                    + "rebroadcast an unchanged value")
            XCTAssertGreaterThanOrEqual(
                providerCallCounter.value, 2, "the poll timer must still be calling the provider each tick even though it isn't rebroadcasting")
        }

        /// Guards `computeWorkspaceFileScopeSignature`'s stat-before-hash type guard (Phase 5 review round-1
        /// Fix 2), through the real production path rather than an injected provider: a subscribed regular
        /// file replaced on disk by a FIFO must have its poll tick skipped silently (no frame, no crash) —
        /// the type guard refuses the FIFO before the hashing open that would otherwise block this scope's
        /// `streamQueue` forever — and, crucially, a LATER tick once the path is a regular file again must
        /// still land and broadcast normally. That final broadcast is the actual liveness proof: if the FIFO
        /// tick had wedged the queue instead of merely skipping, this restore would never produce a frame and
        /// the test would hang instead of failing cleanly.
        func testSubscribeWorkspaceFileSignatureSkipsATickWhenTheFileIsReplacedByAFIFOAndRecoversAfterwards() throws {
            try withWorkspaceFixture { workspaceID, repo, server, _, clientApp, authToken in
                let path = repo.appendingPathComponent("swap.txt")
                try "hello workspace".write(to: path, atomically: true, encoding: .utf8)

                let identity = try workspaceGitTestTLSIdentity()
                let resolver = SpacesDeviceEndpointResolver(
                    hosts: ["127.0.0.1"], port: server.listeningPort, certificateFingerprint: identity.certificateFingerprint)

                let frames = FileSignatureFrameCollector()
                let client = try SpacesDeviceWorkspaceFileSignatureStreamClient(
                    workspaceID: workspaceID, path: "swap.txt", authToken: authToken, clientApp: clientApp, resolver: resolver,
                    onFrame: { frame in frames.append(frame) },
                    onDisconnect: { error in if let error { XCTFail("unexpected disconnect: \(error)") } })
                try client.start()
                defer { client.stop() }

                // Let the connect-time frame land before swapping the file out from under it.
                Thread.sleep(forTimeInterval: 0.5)
                let framesBeforeSwap = frames.count

                try FileManager.default.removeItem(at: path)
                XCTAssertEqual(mkfifo(path.path, 0o644), 0, "mkfifo failed: \(String(cString: strerror(errno)))")

                // Two poll ticks (t≈2s, t≈4s from subscribe) land inside this window. Neither may produce a
                // frame: the type guard refuses the FIFO before any hashing open, so the tick is skipped
                // exactly like a read failure. Were the guard missing, the first of these ticks would block
                // this scope's `streamQueue` on the FIFO's open forever, and every assertion below —
                // including the recovery one — would hang rather than fail.
                Thread.sleep(forTimeInterval: 4.5)
                XCTAssertEqual(
                    frames.count, framesBeforeSwap,
                    "a poll tick landing on a FIFO must be skipped entirely — no frame for content that was never hashed")

                // Restore a regular file with new content at the same path. A fresh, correct frame arriving
                // here is the liveness proof: it can only happen if the poll timer kept firing and the
                // `streamQueue` kept servicing ticks straight through the FIFO ticks above.
                try FileManager.default.removeItem(at: path)
                try "restored content".write(to: path, atomically: true, encoding: .utf8)
                let expectedSHA = SpacesDeviceWorkspaceGitHashing.sha256Hex(Data("restored content".utf8))

                let deadline = Date().addingTimeInterval(5)
                while frames.count == framesBeforeSwap, Date() < deadline {
                    Thread.sleep(forTimeInterval: 0.1)
                }

                guard let latest = frames.values.last else {
                    XCTFail("expected a frame reporting the restored regular file's content")
                    return
                }
                XCTAssertEqual(latest.sha256, expectedSHA)
                XCTAssertFalse(latest.missing)
            }
        }

        /// A subscribed path that does not exist is a legitimate reportable state (`missing: true`, `sha256:
        /// nil`), not a subscribe-time refusal — mirrors `testWorkspaceFileReadOnAMissingFileReturnsNotFound`'s
        /// scenario, but for the signature stream, whose contract is to report absence rather than error on it.
        func testSubscribeWorkspaceFileSignatureOnAMissingFileDeliversAFrameWithNoSha256() throws {
            try withWorkspaceFixture { workspaceID, _, server, _, clientApp, authToken in
                let identity = try workspaceGitTestTLSIdentity()
                let resolver = SpacesDeviceEndpointResolver(
                    hosts: ["127.0.0.1"], port: server.listeningPort, certificateFingerprint: identity.certificateFingerprint)

                let frameArrived = expectation(description: "the missing-file frame arrived")
                let frames = FileSignatureFrameCollector()
                let client = try SpacesDeviceWorkspaceFileSignatureStreamClient(
                    workspaceID: workspaceID, path: "does-not-exist.txt", authToken: authToken, clientApp: clientApp, resolver: resolver,
                    onFrame: { frame in
                        frames.append(frame)
                        frameArrived.fulfill()
                    },
                    onDisconnect: { error in if let error { XCTFail("unexpected disconnect: \(error)") } })
                try client.start()
                defer { client.stop() }
                wait(for: [frameArrived], timeout: 5)

                let frame = try XCTUnwrap(frames.values.first)
                XCTAssertNil(frame.sha256)
                XCTAssertTrue(frame.missing)
            }
        }

        /// Mirrors `testWorkspaceFileReadRejectsAPathThatEscapesTheWorkspace`, but through the full subscribe
        /// relay path: `assertWorkspaceFileScopeIsValid` runs before subscriber registration (divergence #2),
        /// so an escaping path is rejected synchronously with a typed error rather than ever reaching the poll
        /// loop.
        func testSubscribeWorkspaceFileSignatureRejectsAPathThatEscapesTheWorkspace() throws {
            try withWorkspaceFixture { workspaceID, _, server, _, clientApp, authToken in
                let identity = try workspaceGitTestTLSIdentity()
                let resolver = SpacesDeviceEndpointResolver(
                    hosts: ["127.0.0.1"], port: server.listeningPort, certificateFingerprint: identity.certificateFingerprint)

                let rejected = expectation(description: "an escaping path is rejected instead of subscribed")
                let client = try SpacesDeviceWorkspaceFileSignatureStreamClient(
                    workspaceID: workspaceID, path: "../escape.txt", authToken: authToken, clientApp: clientApp, resolver: resolver,
                    onFrame: { _ in XCTFail("a rejected subscription must never deliver a frame") },
                    onDisconnect: { error in
                        guard let error else { return }
                        guard let clientError = error as? SpacesDeviceAPIRequestClientError, case .requestRejected(_, let code) = clientError else {
                            XCTFail("expected a rejected response, got \(error)")
                            return
                        }
                        XCTAssertEqual(code, .invalidArgument)
                        rejected.fulfill()
                    })
                try client.start()
                defer { client.stop() }
                wait(for: [rejected], timeout: 5)
            }
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

        /// Thread-safe ordered collector for `SpacesDeviceWorkspaceFileSignatureFrame` values delivered to a
        /// `SpacesDeviceWorkspaceFileSignatureStreamClient`'s `onFrame` callback — mirrors
        /// `FrameSignatureCollector` above, just holding whole frames instead of a bare signature string
        /// (a file-signature frame's `sha256`/`missing` pair needs both fields asserted, not one).
        private final class FileSignatureFrameCollector: @unchecked Sendable {
            private let lock = NSLock()
            private var storage: [SpacesDeviceWorkspaceFileSignatureFrame] = []

            func append(_ value: SpacesDeviceWorkspaceFileSignatureFrame) {
                lock.lock()
                defer { lock.unlock() }
                storage.append(value)
            }

            var values: [SpacesDeviceWorkspaceFileSignatureFrame] {
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

        /// Mirrors `RawWorkspaceDiffSignatureSocketClient` exactly, decoding
        /// `SpacesDeviceWorkspaceFileSignatureFrame` lines instead — used only by
        /// `testWorkspaceFileSignatureSubscriptionDoesNotRebroadcastAnUnchangedValueAcrossMultiplePolls`, which
        /// constructs a `WorkspaceFileSignatureSubscription` directly and needs to observe its raw producer
        /// broadcasts without a TLS/relay harness.
        private final class RawWorkspaceFileSignatureSocketClient: @unchecked Sendable {
            private let fileDescriptor: Int32
            private let queue = DispatchQueue(label: "test.raw-workspace-file-signature-client")
            private var source: DispatchSourceRead?
            /// Confined to `queue`: only the read source's event handler, always dispatched there, touches it.
            private var pendingBytes = Data()
            private let onFrame: (SpacesDeviceWorkspaceFileSignatureFrame) -> Void

            init(socketPath: String, onFrame: @escaping (SpacesDeviceWorkspaceFileSignatureFrame) -> Void) throws {
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
                    if let frame = try? SpacesDeviceWorkspaceFileSignatureStreamCodec.decodeLine(Data(line)) {
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
