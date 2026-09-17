#if canImport(Network) && canImport(Security)
    import Foundation
    import XCTest

    @testable import spacesdeviceapi
    @testable import spacesdevicecore
    @testable import spacesterminalcore

    final class TerminalTranscriptServerTests: XCTestCase {
        override class func tearDown() {
            try? FileManager.default.removeItem(at: transcriptTestTLSRoot)
            super.tearDown()
        }

        // MARK: Suffix reads

        func testTerminalTranscriptCappedSuffixStartsAtALineBoundary() throws {
            try withTemporaryProfile { _ in
                let sessionID = try makeSession()
                let paths = try TerminalSessionPaths.forSession(id: sessionID)
                // 500 lines of exactly 10 bytes each ("line-0042\n"), so a 995-byte cap lands mid-line.
                // The transcript holds no escape byte at all, so the parser-safe cut falls just past the
                // next newline and the served range starts on a whole line.
                let transcript = Data((0..<500).map { String(format: "line-%04d\n", $0) }.joined().utf8)
                try transcript.write(to: URL(fileURLWithPath: paths.outputPath))

                let result = try transcriptRequest(sessionID: sessionID, maxBytes: 995)

                XCTAssertEqual(result.totalBytes, 5000)
                XCTAssertEqual(result.startByteOffset, 4010)
                XCTAssertFalse(result.isSuffixRebuild)
                let data = try inflated(result)
                XCTAssertEqual(Data(data.suffix(990)), Data(transcript.suffix(990)), "the served range is the file from its cut through the end")
                let text = try XCTUnwrap(String(data: Data(data.suffix(990)), encoding: .utf8))
                XCTAssertTrue(text.hasPrefix("line-"), "the cut lands on a whole line, got: \(text.prefix(20))")
            }
        }

        func testTerminalTranscriptCutsAtTheNominalStartWhenTheWindowHoldsNoParserSafeBoundary() throws {
            try withTemporaryProfile { _ in
                let sessionID = try makeSession()
                let paths = try TerminalSessionPaths.forSession(id: sessionID)
                // Neither an escape nor a newline anywhere, so no boundary is parser-safe and the cut
                // falls on the nominal start; the parser resynchronizes over whatever it lands inside.
                let transcript = Data(repeating: UInt8(ascii: "x"), count: 5000)
                try transcript.write(to: URL(fileURLWithPath: paths.outputPath))

                let result = try transcriptRequest(sessionID: sessionID, maxBytes: 1000)

                XCTAssertEqual(result.totalBytes, 5000)
                XCTAssertEqual(result.startByteOffset, 4000)
                XCTAssertEqual(Data(try inflated(result).suffix(1000)), Data(transcript.suffix(1000)))
            }
        }

        func testTerminalTranscriptReturnsWholeTranscriptWhenUnderCap() throws {
            try withTemporaryProfile { _ in
                let sessionID = try makeSession()
                let paths = try TerminalSessionPaths.forSession(id: sessionID)
                let transcript = Data("row-1\nrow-2\nrow-3\n".utf8)
                try transcript.write(to: URL(fileURLWithPath: paths.outputPath))

                let result = try transcriptRequest(sessionID: sessionID, maxBytes: 1_000_000)

                XCTAssertEqual(result.totalBytes, UInt64(transcript.count))
                XCTAssertEqual(result.startByteOffset, 0, "a transcript returned whole starts where the session did, so it needs no preamble")
                XCTAssertEqual(try inflated(result), transcript)
            }
        }

        /// A suffix drops everything that set the terminal up, so the daemon replays the dropped head and
        /// prepends the state it establishes. Here the head enters the alternate screen and paints a
        /// colored header the tail never redraws: replayed raw the header is simply gone, and replayed
        /// with the preamble it is back, in its color.
        func testTerminalTranscriptSuffixCarriesTheStateTheDroppedHeadEstablished() throws {
            try withTemporaryProfile { _ in
                let sessionID = try makeSession(columns: 20, rows: 5)
                let paths = try TerminalSessionPaths.forSession(id: sessionID)
                var transcript = Data("\u{1B}[?1049h\u{1B}[H\u{1B}[31mHEADER\u{1B}[0m".utf8)
                // Cursor-addressed updates on a single row, which never repaint the header above them.
                for index in 0..<400 { transcript.append(Data("\u{1B}[3;1Hupdate-\(String(format: "%04d", index))".utf8)) }
                try transcript.write(to: URL(fileURLWithPath: paths.outputPath))

                let result = try transcriptRequest(sessionID: sessionID, maxBytes: 500)
                XCTAssertGreaterThan(result.startByteOffset, 0, "the transcript is far larger than the cap, so this is a capped suffix")

                let served = try replay(try inflated(result), columns: 20, rows: 5)
                XCTAssertTrue(served.text.contains("HEADER"), "the preamble repaints what the dropped head drew: \(served.text)")
                XCTAssertEqual(served.foregroundRGB(row: 0, column: 0), paletteSlotOne.packedRGB, "and repaints it in its color")
                XCTAssertTrue(served.text.contains("update-0399"), "the newest output is still there")

                // The same file bytes without the preamble: the state the head established is gone.
                let rawTail = try replay(Data(transcript[Int(result.startByteOffset)...]), columns: 20, rows: 5)
                XCTAssertFalse(rawTail.text.contains("HEADER"))
            }
        }

        /// A trim replaces `output.log` with a fresh inode at any moment. The suffix read holds the file
        /// open, so its preamble must replay THAT file: a preamble taken by reopening the path describes
        /// the post-trim file while the tail beneath it came from the pre-trim one, and the client replays
        /// a screen neither file ever showed.
        func testTerminalTranscriptSuffixPreambleComesFromTheSameFileAsItsTail() throws {
            try withTemporaryProfile { _ in
                let sessionID = try makeSession(columns: 20, rows: 5)
                let paths = try TerminalSessionPaths.forSession(id: sessionID)
                let url = URL(fileURLWithPath: paths.outputPath)
                var served = Data("\u{1B}[?1049h\u{1B}[H\u{1B}[31mSERVED\u{1B}[0m".utf8)
                for index in 0..<400 { served.append(Data("\u{1B}[3;1Hupdate-\(String(format: "%04d", index))".utf8)) }
                try served.write(to: url)

                // The read opens the transcript, and a trim swaps a different file into its path before
                // the read builds its preamble.
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                let totalBytes = try handle.seekToEnd()
                var replacement = Data("\u{1B}[?1049h\u{1B}[H\u{1B}[31mTRIMMED\u{1B}[0m".utf8)
                for index in 0..<400 { replacement.append(Data("\u{1B}[3;1Hother-\(String(format: "%04d", index))".utf8)) }
                try replacement.write(to: url, options: .atomic)

                let read = try SpacesDeviceAPIServer.suffixTranscriptRead(handle: handle, totalBytes: totalBytes, cap: 500, columns: 20, rows: 5)

                XCTAssertGreaterThan(read.startByteOffset, 0, "the transcript is far larger than the cap, so this is a capped suffix")
                let screen = try replay(read.data, columns: 20, rows: 5)
                XCTAssertTrue(screen.text.contains("SERVED"), "the preamble must describe the file the tail came from: \(screen.text)")
                XCTAssertFalse(screen.text.contains("TRIMMED"), "the preamble came from the file that replaced it: \(screen.text)")
                XCTAssertTrue(screen.text.contains("update-0399"), "the tail is still the newest output of the file that was read")
            }
        }

        // MARK: Continuation reads

        func testTerminalTranscriptContinuationReturnsExactlyTheBytesAfterTheOffset() throws {
            try withTemporaryProfile { _ in
                let sessionID = try makeSession()
                let paths = try TerminalSessionPaths.forSession(id: sessionID)
                let head = Data((0..<200).map { String(format: "line-%04d\n", $0) }.joined().utf8)
                try head.write(to: URL(fileURLWithPath: paths.outputPath))

                let tail = Data("\u{1B}[32mtail without a leading newline".utf8)
                let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: paths.outputPath))
                try handle.seekToEnd()
                try handle.write(contentsOf: tail)
                try handle.close()

                let result = try transcriptRequest(
                    sessionID: sessionID, maxBytes: 1_000_000, fromByteOffset: head.count, fileIdentity: try fileIdentity(atPath: paths.outputPath))

                XCTAssertFalse(result.isSuffixRebuild)
                XCTAssertEqual(result.startByteOffset, UInt64(head.count))
                XCTAssertEqual(result.totalBytes, UInt64(head.count + tail.count))
                XCTAssertEqual(try inflated(result), tail, "a continuation is served verbatim: no cut, no preamble")
            }
        }

        func testTerminalTranscriptContinuationAtTheEndReturnsNothing() throws {
            try withTemporaryProfile { _ in
                let sessionID = try makeSession()
                let paths = try TerminalSessionPaths.forSession(id: sessionID)
                let transcript = Data((0..<200).map { String(format: "line-%04d\n", $0) }.joined().utf8)
                try transcript.write(to: URL(fileURLWithPath: paths.outputPath))

                let result = try transcriptRequest(
                    sessionID: sessionID, maxBytes: 1_000_000, fromByteOffset: transcript.count,
                    fileIdentity: try fileIdentity(atPath: paths.outputPath))

                XCTAssertFalse(result.isSuffixRebuild)
                XCTAssertEqual(result.byteCount, 0)
                XCTAssertTrue(result.compressedData.isEmpty)
                XCTAssertEqual(result.totalBytes, UInt64(transcript.count))
            }
        }

        /// A head-trim rewrites the transcript and renames the rewrite over `output.log`, so the client's
        /// offset no longer names the bytes it continues from. The file the client read is what proves
        /// that, and the answer is a fresh suffix the client rebuilds from rather than bytes that do not
        /// follow its own.
        ///
        /// The transcript here repeats one line, which is the case a byte comparison around the offset
        /// cannot decide: the trimmed file carries byte-identical content at the old offset (asserted
        /// below), so a sample taken from the pre-trim file still matches the post-trim one and the
        /// client would silently splice a replay across the bytes the trim dropped.
        func testTerminalTranscriptAnswersATrimmedTranscriptWithARebuildSuffixEvenWhenItsBytesRepeat() throws {
            try withTemporaryProfile { _ in
                let sessionID = try makeSession()
                let paths = try TerminalSessionPaths.forSession(id: sessionID)
                let line = "progress\n"
                let original = Data(String(repeating: line, count: 400).utf8)
                try original.write(to: URL(fileURLWithPath: paths.outputPath))
                let clientOffset = line.utf8.count * 200
                let clientFileIdentity = try fileIdentity(atPath: paths.outputPath)

                // The daemon trims the head under the client, committing the rewrite the way
                // `TerminalTranscriptTrim` does: a sibling file renamed over `output.log`, which gives the
                // path a different file while the client's handle-less offset stays what it was.
                let trimmed = Data(String(repeating: line, count: 300).utf8)
                let trimPath = paths.outputPath + ".trim"
                try trimmed.write(to: URL(fileURLWithPath: trimPath))
                let renamed = trimPath.withCString { tempC in paths.outputPath.withCString { outC in rename(tempC, outC) } }
                XCTAssertEqual(renamed, 0, "the trim commits by renaming its rewrite over the transcript")
                XCTAssertEqual(
                    trimmed[(clientOffset - 32)..<clientOffset], original[(clientOffset - 32)..<clientOffset],
                    "the trimmed file repeats the same bytes at the old offset, which is what a byte sample cannot tell apart")

                let result = try transcriptRequest(
                    sessionID: sessionID, maxBytes: 1_000_000, fromByteOffset: clientOffset, fileIdentity: clientFileIdentity)

                XCTAssertTrue(result.isSuffixRebuild, "the bytes at the offset belong to a different file, so they cannot continue the replay")
                XCTAssertNotEqual(result.fileIdentity, clientFileIdentity, "the trim replaced the file the client read")
                XCTAssertEqual(result.totalBytes, UInt64(trimmed.count))
                XCTAssertEqual(result.startByteOffset, 0, "the whole trimmed file fits the requested page")
                XCTAssertEqual(try inflated(result), trimmed)
            }
        }

        /// Appending leaves the transcript's identity alone, so a replay that is merely behind is served
        /// the bytes it is missing rather than rebuilt: a rebuild replays a whole page for output the
        /// client could have taken as a few hundred bytes.
        func testTerminalTranscriptContinuationIsServedAcrossAppendsToTheSameFile() throws {
            try withTemporaryProfile { _ in
                let sessionID = try makeSession()
                let paths = try TerminalSessionPaths.forSession(id: sessionID)
                let head = Data(String(repeating: "progress\n", count: 200).utf8)
                try head.write(to: URL(fileURLWithPath: paths.outputPath))

                let first = try transcriptRequest(sessionID: sessionID, maxBytes: 1_000_000)
                XCTAssertEqual(first.fileIdentity, try fileIdentity(atPath: paths.outputPath))

                let appended = Data(String(repeating: "progress\n", count: 20).utf8)
                let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: paths.outputPath))
                try handle.seekToEnd()
                try handle.write(contentsOf: appended)
                try handle.close()

                let result = try transcriptRequest(
                    sessionID: sessionID, maxBytes: 1_000_000, fromByteOffset: Int(first.totalBytes), fileIdentity: first.fileIdentity)

                XCTAssertFalse(result.isSuffixRebuild)
                XCTAssertEqual(result.fileIdentity, first.fileIdentity, "an append keeps the file the client read")
                XCTAssertEqual(try inflated(result), appended)
            }
        }

        /// Nothing about an offset can be verified without the file it belongs to, so the read is answered
        /// as the rebuild it has to be.
        func testTerminalTranscriptContinuationWithoutAFileIdentityIsARebuildSuffix() throws {
            try withTemporaryProfile { _ in
                let sessionID = try makeSession()
                let paths = try TerminalSessionPaths.forSession(id: sessionID)
                let transcript = Data(String(repeating: "progress\n", count: 200).utf8)
                try transcript.write(to: URL(fileURLWithPath: paths.outputPath))

                let result = try transcriptRequest(sessionID: sessionID, maxBytes: 1_000_000, fromByteOffset: 900, fileIdentity: nil)

                XCTAssertTrue(result.isSuffixRebuild)
                XCTAssertEqual(result.startByteOffset, 0, "the whole transcript fits the requested page")
                XCTAssertEqual(try inflated(result), transcript)
            }
        }

        /// A replay left idle through a burst of output would otherwise be sent a range far wider than the
        /// page it asked for, on the link the paging exists to protect.
        func testTerminalTranscriptAnswersAContinuationWiderThanThePageWithARebuildSuffix() throws {
            try withTemporaryProfile { _ in
                let sessionID = try makeSession()
                let paths = try TerminalSessionPaths.forSession(id: sessionID)
                let transcript = Data((0..<500).map { String(format: "line-%04d\n", $0) }.joined().utf8)
                try transcript.write(to: URL(fileURLWithPath: paths.outputPath))
                let clientOffset = 1000

                let result = try transcriptRequest(
                    sessionID: sessionID, maxBytes: 500, fromByteOffset: clientOffset, fileIdentity: try fileIdentity(atPath: paths.outputPath))

                XCTAssertTrue(result.isSuffixRebuild)
                XCTAssertEqual(result.startByteOffset, 4510, "the rebuild is the same capped suffix a first read would return")
            }
        }

        // MARK: Transport shape

        func testTerminalTranscriptTravelsCompressedAndInflatesToTheReportedLength() throws {
            try withTemporaryProfile { _ in
                let sessionID = try makeSession()
                let paths = try TerminalSessionPaths.forSession(id: sessionID)
                let transcript = Data((0..<5000).map { String(format: "line-%04d\n", $0) }.joined().utf8)
                try transcript.write(to: URL(fileURLWithPath: paths.outputPath))

                let result = try transcriptRequest(sessionID: sessionID, maxBytes: 1_000_000)

                XCTAssertEqual(result.byteCount, transcript.count)
                XCTAssertLessThan(result.compressedData.count, result.byteCount / 4, "repetitive terminal output is what the compression is here for")
                XCTAssertEqual(try inflated(result), transcript)
            }
        }

        // MARK: Short reads

        /// `FileHandle.read(upToCount:)` may legally return fewer bytes than asked even on a regular
        /// file. A pipe is what lets a test force that: a pipe read returns whatever is currently
        /// buffered rather than waiting to fill the request. Writing here in two chunks from a background
        /// thread, with a pause between them, means the reading side's first `read` call very likely
        /// observes only the first chunk, so `readExactly` has to make a second call to collect the rest.
        /// The assertion does not depend on which call actually short-read; it only checks that the
        /// returned data is the full range, which is what a single-call read would get wrong.
        func testReadExactlyAssemblesAShortReadAcrossMultipleCalls() throws {
            let pipe = Pipe()
            let first = Data("first-chunk-".utf8)
            let second = Data("second-chunk".utf8)
            let writer = Thread {
                try? pipe.fileHandleForWriting.write(contentsOf: first)
                Thread.sleep(forTimeInterval: 0.2)
                try? pipe.fileHandleForWriting.write(contentsOf: second)
                try? pipe.fileHandleForWriting.close()
            }
            writer.start()
            defer { try? pipe.fileHandleForReading.close() }

            let result = try SpacesDeviceAPIServer.readExactly(handle: pipe.fileHandleForReading, count: first.count + second.count)

            XCTAssertEqual(result, first + second)
        }

        /// A short read that never catches up to `count` is an EOF the caller must not paper over:
        /// returning fewer bytes than the response promised is exactly the corruption `readExactly` exists
        /// to prevent, so premature EOF surfaces as a thrown error instead of a truncated result.
        func testReadExactlyThrowsOnPrematureEOF() throws {
            let pipe = Pipe()
            let first = Data("only-this-much".utf8)
            try pipe.fileHandleForWriting.write(contentsOf: first)
            try pipe.fileHandleForWriting.close()
            defer { try? pipe.fileHandleForReading.close() }

            XCTAssertThrowsError(try SpacesDeviceAPIServer.readExactly(handle: pipe.fileHandleForReading, count: first.count + 10))
        }

        // MARK: Run identity

        func testTerminalTranscriptReportsTheRunIdentityFromRuntimeState() throws {
            try withTemporaryProfile { _ in
                let sessionID = try makeSession(childPID: 4242, exitedAt: "2026-06-05T00:00:09Z")
                let paths = try TerminalSessionPaths.forSession(id: sessionID)
                try Data("hello".utf8).write(to: URL(fileURLWithPath: paths.outputPath))

                let result = try transcriptRequest(sessionID: sessionID, maxBytes: 1_000_000)

                XCTAssertEqual(result.runIdentity, "4242|2026-06-05T00:00:09Z")
            }
        }

        func testTerminalTranscriptRunIdentityIsNilWhenNoRuntimeStateExists() throws {
            try withTemporaryProfile { _ in
                let sessionID = "session-transcript-no-runtime-\(UUID().uuidString)"
                let paths = try TerminalSessionPaths.forSession(id: sessionID)
                try paths.ensureDirectories()
                try Data("hello".utf8).write(to: URL(fileURLWithPath: paths.outputPath))

                let result = try transcriptRequest(sessionID: sessionID, maxBytes: 1_000_000)

                XCTAssertNil(result.runIdentity)
            }
        }

        func testTerminalTranscriptMissingOutputErrors() throws {
            try withTemporaryProfile { _ in
                let sessionID = "session-transcript-missing-\(UUID().uuidString)"
                let paths = try TerminalSessionPaths.forSession(id: sessionID)
                try paths.ensureDirectories()

                let (server, requestClient, clientApp, authToken) = try makeServerAndClient()
                defer {
                    requestClient.cancel()
                    server.stop()
                }

                let response = try requestClient.send(
                    SpacesDeviceAPIRequest(
                        command: .terminalTranscript(SpacesDeviceTerminalTranscriptRequest(sessionID: sessionID, maxBytes: 1000)),
                        authToken: authToken, clientApp: clientApp))

                XCTAssertFalse(response.ok)
                XCTAssertEqual(response.errorCode, .sessionNotAvailable)
            }
        }

        /// `maxBytes: 0` has no valid suffix or continuation to serve; it must be rejected before any read,
        /// not clamped into a suffix read that replays the whole transcript through `statePreamble` to
        /// build a preamble for a response the client asked to be empty.
        func testTerminalTranscriptRejectsNonPositiveMaxBytes() throws {
            try withTemporaryProfile { _ in
                let sessionID = try makeSession()
                let paths = try TerminalSessionPaths.forSession(id: sessionID)
                try Data("row-1\nrow-2\nrow-3\n".utf8).write(to: URL(fileURLWithPath: paths.outputPath))

                let (server, requestClient, clientApp, authToken) = try makeServerAndClient()
                defer {
                    requestClient.cancel()
                    server.stop()
                }

                let response = try requestClient.send(
                    SpacesDeviceAPIRequest(
                        command: .terminalTranscript(SpacesDeviceTerminalTranscriptRequest(sessionID: sessionID, maxBytes: 0)), authToken: authToken,
                        clientApp: clientApp))

                XCTAssertFalse(response.ok)
                XCTAssertEqual(response.errorCode, .invalidArgument)
                XCTAssertNil(response.terminalTranscript)
            }
        }

        // MARK: Harness

        /// The session rows a transcript read consults: the launch configuration (which the runtime row
        /// hangs off) and a runtime row carrying the grid a suffix's state preamble is built at.
        private func makeSession(columns: Int = 80, rows: Int = 24, childPID: Int32 = 4242, exitedAt: String = "2026-06-05T00:00:09Z") throws
            -> String
        {
            let sessionID = "session-transcript-\(UUID().uuidString)"
            let paths = try TerminalSessionPaths.forSession(id: sessionID)
            try paths.ensureDirectories()
            try TerminalSessionPersistence.writeLaunchConfiguration(
                TerminalSessionLaunchConfiguration(
                    sessionID: sessionID, title: "transcript", workingDirectory: "/tmp/work", shell: "/bin/zsh", command: nil,
                    createdAt: "2026-06-05T00:00:00Z", workspaceID: "workspace-1", kind: .shell), paths: paths)
            try TerminalSessionPersistence.writeRuntimeState(
                TerminalSessionRuntimeState(
                    sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: 1, childPID: childPID, state: .exited, updatedAt: exitedAt,
                    exitedAt: exitedAt, columns: columns, rows: rows), paths: paths)
            return sessionID
        }

        private func transcriptRequest(sessionID: String, maxBytes: Int, fromByteOffset: Int? = nil, fileIdentity: UInt64? = nil) throws
            -> SpacesDeviceTerminalTranscriptResult
        {
            let (server, requestClient, clientApp, authToken) = try makeServerAndClient()
            defer {
                requestClient.cancel()
                server.stop()
            }
            let response = try requestClient.send(
                SpacesDeviceAPIRequest(
                    command: .terminalTranscript(
                        SpacesDeviceTerminalTranscriptRequest(
                            sessionID: sessionID, maxBytes: maxBytes, fromByteOffset: fromByteOffset, fileIdentity: fileIdentity)),
                    authToken: authToken, clientApp: clientApp))
            XCTAssertTrue(response.ok, response.message)
            return try XCTUnwrap(response.terminalTranscript)
        }

        /// The transcript file's identity as the filesystem reports it for the path, read independently of
        /// the server so a continuation assertion is not the server's own value handed straight back.
        private func fileIdentity(atPath path: String) throws -> UInt64 {
            let attributes = try FileManager.default.attributesOfItem(atPath: path)
            return UInt64(try XCTUnwrap(attributes[.systemFileNumber] as? Int))
        }

        /// The transcript the result carries, inflated the way every client inflates it.
        private func inflated(_ result: SpacesDeviceTerminalTranscriptResult) throws -> Data {
            guard result.byteCount > 0 else { return Data() }
            return try GhosttyRenderUpdateBodyCompression.inflate(result.compressedData, expectedLength: result.byteCount)
        }

        /// Palette slot 1 in the replay theme below, which is what SGR 31 resolves to: the preamble
        /// serializes palette-indexed cells as indexed SGR so the viewer's own palette resolves them.
        private let paletteSlotOne = ThemeColor(8, 8, 8)

        /// Replays served bytes through the same client-local model a pane scrolls, so an assertion about
        /// the served bytes is an assertion about the screen the user would see.
        private func replay(_ transcript: Data, columns: Int, rows: Int) throws -> ReplayedScreen {
            let theme = GhosttyThemeExport(
                background: ThemeColor(0, 0, 0), foreground: ThemeColor(255, 255, 255), cursorColor: ThemeColor(200, 200, 200),
                cursorText: ThemeColor(0, 0, 0), selectionBackground: ThemeColor(50, 50, 50), selectionForeground: ThemeColor(255, 255, 255),
                palette: (0..<16).map { ThemeColor($0 * 8, $0 * 8, $0 * 8) })
            let model = try XCTUnwrap(
                TerminalLocalScrollbackModel(
                    columns: columns, rows: rows, theme: theme, appearance: .dark, transcript: transcript, transcriptStartByteOffset: 0,
                    transcriptEndByteOffset: UInt64(transcript.count), requestedByteCount: transcript.count, transcriptFileIdentity: nil,
                    runIdentity: nil))
            return ReplayedScreen(snapshot: model.currentSnapshot())
        }

        private struct ReplayedScreen {
            let snapshot: GhosttyTerminalSnapshot

            /// The rows exactly as the production row layout renders them, so what these assertions read
            /// is what a pane would paint from the same bytes.
            var text: String { GhosttyTerminalSnapshotLayout.plainText(for: snapshot) }

            func foregroundRGB(row: Int, column: Int) -> UInt32? {
                guard snapshot.columns > column, snapshot.rows > row, snapshot.cells.count >= snapshot.columns * snapshot.rows else { return nil }
                return snapshot.cells[row * snapshot.columns + column].foregroundRGB
            }
        }

        private func makeServerAndClient() throws -> (SpacesDeviceAPIServer, SpacesDeviceAPIRequestSessionClient, SpacesDeviceClientApp, String) {
            let identity = try transcriptTestTLSIdentity()
            let pairingStore = AlwaysAuthorizedTranscriptPairingStore()
            let server = SpacesDeviceAPIServer(host: "127.0.0.1", port: 0, identity: identity, pairingStoreProtocol: pairingStore)
            try server.start()
            let requestClient = try SpacesDeviceAPIRequestSessionClient(
                resolver: SpacesDeviceEndpointResolver(
                    hosts: ["127.0.0.1"], port: server.listeningPort, certificateFingerprint: identity.certificateFingerprint))
            let clientApp = SpacesDeviceClientApp(
                installationID: "transcript-test", bundleID: SpacesDeviceFirstPartyPolicy.allowedBundleID, platform: "macos", deviceName: "Mac",
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
    }

    private let transcriptTestTLSRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
        "spaces-transcript-tests-tls-\(UUID().uuidString)", isDirectory: true)

    private func transcriptTestTLSIdentity() throws -> TerminalServiceTLSIdentity {
        try TerminalServiceTLSIdentityStore.loadOrCreate(root: transcriptTestTLSRoot)
    }

    private final class AlwaysAuthorizedTranscriptPairingStore: SpacesDevicePairingStoreProtocol {
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
