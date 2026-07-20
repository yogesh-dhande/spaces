#if os(Linux)
    import Foundation
    import Testing
    import spacesterminalcore

    @testable import spacesterminalghostty

    /// Verifies the Linux headless core resizes the LIVE vt session in place (reflowing existing
    /// content and preserving terminal state) rather than discarding the session and replaying
    /// `output.log` from offset 0 at the new size. Replay-at-a-new-size garbles the screen because
    /// the transcript's bytes were produced for the old width (and, since transcript trimming, may
    /// begin with a state preamble laid out for the old grid). The tests prove the file is never read
    /// on resize by making it unusable for replay (corrupted or deleted) before resizing.
    ///
    /// These are behavioral tests over the real `resize` control path (`handleControlRequest`), not a
    /// copy of its logic, and require the dynamic `libghostty-vt` runtime (the core's vt session).
    ///
    /// Swift Testing (not XCTest) on purpose: the swift-testing runner executes tests from an async
    /// main, so `@MainActor` async tests make progress on Linux. Under corelibs-xctest an async
    /// `@MainActor` test deadlocks before its first line — the test job is queued to the main
    /// executor while XCTest's main thread waits in a poll that never drains it. `.serialized`
    /// because each test mutates the process-wide SPACES_* environment and owns a real PTY child.
    @Suite(.serialized) final class GhosttyLinuxHeadlessSessionResizeTests {
        private let originalDatabasePath: String?
        private let originalRuntimeDirectory: String?
        private let databaseRoot: URL

        init() throws {
            originalDatabasePath = ProcessInfo.processInfo.environment["SPACES_DB_PATH"]
            originalRuntimeDirectory = ProcessInfo.processInfo.environment["SPACES_RUNTIME_DIR"]
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            databaseRoot = root
            setenv("SPACES_DB_PATH", root.appendingPathComponent("spaces.db").path, 1)
            setenv("SPACES_RUNTIME_DIR", root.appendingPathComponent("runtime", isDirectory: true).path, 1)
        }

        deinit {
            if let originalDatabasePath { setenv("SPACES_DB_PATH", originalDatabasePath, 1) } else { unsetenv("SPACES_DB_PATH") }
            if let originalRuntimeDirectory { setenv("SPACES_RUNTIME_DIR", originalRuntimeDirectory, 1) } else { unsetenv("SPACES_RUNTIME_DIR") }
            try? FileManager.default.removeItem(at: databaseRoot)
        }

        // MARK: - Helpers

        private func makeTemporaryPaths() throws -> TerminalSessionPaths {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let paths = TerminalSessionPaths(rootDirectory: root.path)
            try paths.ensureDirectories()
            return paths
        }

        private func makeConfiguration(sessionID: String, command: String?) -> TerminalSessionLaunchConfiguration {
            TerminalSessionLaunchConfiguration(
                sessionID: sessionID, backend: .ghosttyEmbedded, title: "resize", workingDirectory: FileManager.default.temporaryDirectory.path,
                shell: "/bin/sh", command: command, createdAt: "2026-07-20T00:00:00Z", workspaceID: "workspace-resize", kind: .shell)
        }

        @MainActor private func waitUntil(
            timeout: TimeInterval = 15, _ comment: Comment, condition: @MainActor () -> Bool
        ) async throws {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if condition() { return }
                try? await Task.sleep(for: .milliseconds(30))
            }
            #expect(condition(), comment)
        }

        /// Attaches a remote-viewer owner so the core includes screen state in exported payloads (the
        /// state policy gates screen frames on an attached local/remote owner).
        @MainActor private func attachRemoteOwner(to core: GhosttyEmbeddedSessionCore, id: String) throws {
            let client = TerminalClient(
                id: id, kind: .remoteViewer, identity: TerminalClientIdentity(label: "iPhone", deviceName: "iPhone"),
                connectedAt: "2026-07-20T00:00:00Z")
            let response = core.handleControlRequest(TerminalControlRequest(command: "attach", client: client, attachmentMode: .owner))
            #expect(response.ok, "attaching a remote owner must succeed: \(response.message)")
        }

        /// Drives the trusted (client-less) resize command through the real control path.
        @MainActor @discardableResult private func resize(_ core: GhosttyEmbeddedSessionCore, columns: Int, rows: Int) -> TerminalControlResponse {
            core.handleControlRequest(TerminalControlRequest(command: "resize", columns: columns, rows: rows))
        }

        /// Reconstructs the visible screen text from a self-contained full-frame export.
        @MainActor private func renderedScreenText(of core: GhosttyEmbeddedSessionCore) -> String? {
            guard let snapshot = core.currentRemoteStatePayload(reason: TerminalRemoteSessionStateReason.initial)?.renderSnapshot else { return nil }
            return Self.screenText(of: snapshot)
        }

        @MainActor private func renderedSnapshot(of core: GhosttyEmbeddedSessionCore) -> GhosttyTerminalSnapshot? {
            core.currentRemoteStatePayload(reason: TerminalRemoteSessionStateReason.initial)?.renderSnapshot
        }

        private static func screenText(of snapshot: GhosttyTerminalSnapshot) -> String {
            guard snapshot.columns > 0, snapshot.rows > 0 else { return "" }
            var lines: [String] = []
            for row in 0..<snapshot.rows {
                var line = ""
                for column in 0..<snapshot.columns {
                    let index = row * snapshot.columns + column
                    let codepoint = index < snapshot.cells.count ? snapshot.cells[index].codepoint : 0
                    if codepoint == 0 {
                        line.append(" ")
                    } else if let scalar = Unicode.Scalar(codepoint) {
                        line.append(Character(scalar))
                    } else {
                        line.append(" ")
                    }
                }
                lines.append(line)
            }
            return lines.joined(separator: "\n")
        }

        /// The reflowed logical line, reconstructed by concatenating the visible rows with their
        /// trailing padding stripped. A soft-wrapped line spans several physical rows, so joining the
        /// non-empty rows recovers the original text regardless of the wrap width.
        private func reflowedText(_ text: String?) -> String {
            (text ?? "").split(separator: "\n", omittingEmptySubsequences: false).map { line in
                String(line).replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
            }.filter { !$0.isEmpty }.joined()
        }

        // MARK: - Tests

        /// Corrupts `output.log` with content that does not contain the rendered marker, then resizes.
        /// In-place resize keeps the live screen; the pre-fix recreate-and-replay path would rebuild
        /// the screen from the corrupted bytes and lose the marker, and a wide line would re-wrap from
        /// garbage rather than from its live content.
        @Test @MainActor func resizeReflowsInPlaceWithoutReplayingTranscript() async throws {
            let paths = try makeTemporaryPaths()
            defer { try? FileManager.default.removeItem(atPath: paths.rootDirectory) }

            // A single logical line far wider than either grid width, so its wrapping depends entirely
            // on the current grid — reflow must re-wrap the live content, not replay a fixed transcript.
            let wideLine = String(repeating: "A", count: 120) + "END"
            let configuration = makeConfiguration(
                sessionID: "resize-reflow-\(UUID().uuidString)", command: "stty -echo; printf '%s\\n' '\(wideLine)'; cat")
            let core = GhosttyEmbeddedSessionCore(launchConfiguration: configuration, paths: paths)
            defer { core.terminate() }
            try core.startIfNeeded()
            try attachRemoteOwner(to: core, id: "remote-owner")
            try await waitUntil("the wide line must render before the resize") { self.renderedScreenText(of: core)?.contains("END") == true }

            // The default 80-column grid wraps the 123-column line across at least two physical rows,
            // yet the reconstructed logical line is intact.
            let beforeSnapshot = try #require(renderedSnapshot(of: core))
            #expect(beforeSnapshot.columns == 80)
            #expect(reflowedText(renderedScreenText(of: core)) == wideLine)

            // Make output.log unusable for replay: overwrite it with content that shares no substring
            // with the rendered line. A from-zero replay would render this instead of the live screen.
            try Data("CORRUPTED_TRANSCRIPT_XYZ\n".utf8).write(to: URL(fileURLWithPath: paths.outputPath))

            let response = resize(core, columns: 100, rows: 30)
            #expect(response.ok, "resize must succeed without reading output.log: \(response.message)")

            // The grid is the new size and the wide line re-wrapped for width 100 while keeping its
            // text — proving the live session reflowed rather than replaying the corrupted transcript.
            let afterSnapshot = try #require(renderedSnapshot(of: core))
            #expect(afterSnapshot.columns == 100)
            #expect(afterSnapshot.rows == 30)
            let afterText = try #require(renderedScreenText(of: core))
            #expect(reflowedText(afterText) == wideLine, "the wide line must survive the resize with its text intact after reflow")
            #expect(!afterText.contains("CORRUPTED_TRANSCRIPT_XYZ"), "resize must not render the corrupted transcript")
        }

        /// Deletes `output.log` before resizing. In-place resize never touches the file, so it
        /// succeeds and the live screen is preserved; the pre-fix recreate-and-replay path opens the
        /// (now missing) file, fails the replay, and returns a resize error.
        @Test @MainActor func resizeSucceedsWhenTranscriptDeleted() async throws {
            let paths = try makeTemporaryPaths()
            defer { try? FileManager.default.removeItem(atPath: paths.rootDirectory) }

            let marker = "KEEP_MARKER"
            let configuration = makeConfiguration(
                sessionID: "resize-deleted-\(UUID().uuidString)", command: "stty -echo; printf '%s\\n' '\(marker)'; cat")
            let core = GhosttyEmbeddedSessionCore(launchConfiguration: configuration, paths: paths)
            defer { core.terminate() }
            try core.startIfNeeded()
            try attachRemoteOwner(to: core, id: "remote-owner")
            try await waitUntil("the marker must render before the resize") { self.renderedScreenText(of: core)?.contains(marker) == true }

            // Remove the durable transcript. The live session still holds the rendered marker.
            try FileManager.default.removeItem(atPath: paths.outputPath)

            let response = resize(core, columns: 90, rows: 28)
            #expect(response.ok, "resize must succeed even with no transcript file to replay: \(response.message)")

            let snapshot = try #require(renderedSnapshot(of: core))
            #expect(snapshot.columns == 90)
            #expect(snapshot.rows == 28)
            #expect(
                Self.screenText(of: snapshot).contains(marker), "the live screen content must survive a resize that cannot read output.log")
        }
    }
#endif
