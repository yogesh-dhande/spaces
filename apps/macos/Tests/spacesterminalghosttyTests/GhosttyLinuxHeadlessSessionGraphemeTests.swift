#if os(Linux)
    import Foundation
    import Testing
    import spacesterminalcore

    @testable import spacesterminalghostty

    /// Grapheme fidelity of the Linux headless core end to end: a program writing emoji sequences to a
    /// real PTY must reach the render snapshot the daemon exports with its clusters intact, not
    /// collapsed to base scalars. The shim-level export is covered by
    /// `GhosttyVtSnapshotGraphemeTests`; this drives the whole session path (PTY -> vt session ->
    /// snapshot export -> remote state payload) that a client actually consumes.
    ///
    /// Structure follows the other Linux headless suites: Swift Testing (corelibs-xctest deadlocks
    /// async tests on Linux), `.serialized` because each test mutates the process-wide SPACES_*
    /// environment and owns a real PTY child, and every core call hops onto `TerminalEngineActor`.
    @Suite(.serialized) final class GhosttyLinuxHeadlessSessionGraphemeTests {
        /// Sequences a terminal segments differently depending on mode 2027 (grapheme clustering): with
        /// it on, each occupies one cell carrying the whole cluster.
        private static let sequences = ["\u{2764}\u{FE0F}", "👋🏽", "👨‍👩‍👧‍👦", "🇯🇵", "e\u{0301}"]

        private let originalDatabasePath: String?
        private let originalRuntimeDirectory: String?
        private let databaseRoot: URL

        /// Carries an engine-isolated reference (created inside a `TerminalEngineActor.run` block) back out
        /// to the nonisolated test body; the value is only ever *used* on the engine actor via a later bridge.
        private final class Box<Value>: @unchecked Sendable {
            let value: Value
            init(_ value: Value) { self.value = value }
        }

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

        // MARK: - Nonisolated helpers

        private func makeTemporaryPaths() throws -> TerminalSessionPaths {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let paths = TerminalSessionPaths(rootDirectory: root.path)
            try paths.ensureDirectories()
            return paths
        }

        private func makeConfiguration(sessionID: String, command: String) -> TerminalSessionLaunchConfiguration {
            TerminalSessionLaunchConfiguration(
                sessionID: sessionID, backend: .ghosttyEmbedded, title: "grapheme", workingDirectory: FileManager.default.temporaryDirectory.path,
                shell: "/bin/sh", command: command, createdAt: "2026-07-20T00:00:00Z", workspaceID: "workspace-grapheme", kind: .shell)
        }

        /// Nonisolated poller so its `Task.sleep` suspensions don't hold the engine's queue while the
        /// engine runs the queued `handleOutput` tasks the condition is waiting on.
        private func waitAsync(
            timeout: TimeInterval = 30, sourceLocation: SourceLocation = #_sourceLocation, _ condition: @escaping @TerminalEngineActor () -> Bool
        ) async throws {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if TerminalEngineActor.runSynchronously({ condition() }) { return }
                try? await Task.sleep(for: .milliseconds(30))
            }
            #expect(TerminalEngineActor.runSynchronously { condition() }, "waitAsync timed out", sourceLocation: sourceLocation)
        }

        /// A row's text with the spacer cells a double-width glyph trails removed and trailing blanks
        /// dropped, so the result is what the program printed however the terminal split it into cells.
        private static func rowText(of snapshot: GhosttyTerminalSnapshot, row: Int) -> String {
            var text = ""
            for column in 0..<snapshot.columns {
                let cell = snapshot.cells[row * snapshot.columns + column]
                guard cell.flags & GhosttyTerminalSnapshotGrid.spacerFlag == 0 else { continue }
                text +=
                    snapshot.clusters[row * snapshot.columns + column] ?? (cell.codepoint == 0 ? " " : String(UnicodeScalar(cell.codepoint) ?? " "))
            }
            return text.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
        }

        private static func nonEmptyRows(of snapshot: GhosttyTerminalSnapshot) -> [String] {
            (0..<snapshot.rows).map { rowText(of: snapshot, row: $0) }.filter { !$0.isEmpty }
        }

        // MARK: - Engine-isolated helpers (call from inside a run/runSynchronously bridge)

        /// Attaches a remote-viewer owner so the core includes screen state in exported payloads (the
        /// state policy gates screen frames on an attached local/remote owner).
        @TerminalEngineActor private static func attachRemoteOwner(to core: GhosttyEmbeddedSessionCore, id: String) {
            let client = TerminalClient(
                id: id, kind: .remoteViewer, identity: TerminalClientIdentity(label: "iPhone", deviceName: "iPhone"),
                connectedAt: "2026-07-20T00:00:00Z")
            let response = core.handleControlRequest(TerminalControlRequest(command: "attach", client: client, attachmentMode: .owner))
            #expect(response.ok, "attaching a remote owner must succeed: \(response.message)")
        }

        @TerminalEngineActor private static func renderedSnapshot(of core: GhosttyEmbeddedSessionCore) -> GhosttyTerminalSnapshot? {
            core.currentRemoteStatePayload(reason: TerminalRemoteSessionStateReason.initial)?.renderSnapshot
        }

        // MARK: - Tests

        /// Prints each sequence on its own line under grapheme clustering, then one more line with the
        /// mode off. Every line must read back exactly as printed, and each clustered cell must carry
        /// the whole sequence — the emoji a coding agent, package manager, or test runner emits.
        @Test func emojiSequencesReachTheRenderSnapshotWithTheirClustersIntact() async throws {
            let paths = try makeTemporaryPaths()
            defer { try? FileManager.default.removeItem(atPath: paths.rootDirectory) }

            let clustered = Self.sequences.map { "'\($0)|'" }.joined(separator: " ")
            // Mode 2027 on for the sequence lines, then off for a final combining-mark line: a zero-width
            // mark attaches to the cell it modifies with or without grapheme clustering.
            let command = "stty -echo; printf '\\033[?2027h'; printf '%s\\n' \(clustered); printf '\\033[?2027l'; printf '%s\\n' 'e\u{0301}|'; cat"
            let configuration = makeConfiguration(sessionID: "grapheme-\(UUID().uuidString)", command: command)
            let coreBox = try await TerminalEngineActor.run { () -> Box<GhosttyEmbeddedSessionCore> in
                let core = GhosttyEmbeddedSessionCore(launchConfiguration: configuration, paths: paths)
                try core.startIfNeeded()
                Self.attachRemoteOwner(to: core, id: "remote-owner")
                return Box(core)
            }
            let core = coreBox.value
            defer { TerminalEngineActor.runSynchronously { core.terminate() } }

            let expectedRows = Self.sequences.map { $0 + "|" } + ["e\u{0301}|"]
            try await waitAsync {
                guard let snapshot = Self.renderedSnapshot(of: core) else { return false }
                return Self.nonEmptyRows(of: snapshot).count >= expectedRows.count
            }

            let snapshot = try #require(TerminalEngineActor.runSynchronously { Self.renderedSnapshot(of: core) })
            #expect(Self.nonEmptyRows(of: snapshot) == expectedRows)

            // Under grapheme clustering the whole sequence is one cell, so a client renders one glyph.
            for (row, sequence) in Self.sequences.enumerated() {
                let index = row * snapshot.columns
                #expect(
                    GhosttyTerminalSnapshotCellText.displayText(for: snapshot.cells[index], cluster: snapshot.clusters[index]) == sequence,
                    "row \(row) lost part of a \(sequence.unicodeScalars.count)-scalar cluster")
            }

            // The combining mark attaches with the mode off too.
            #expect(snapshot.clusters[Self.sequences.count * snapshot.columns] == "e\u{0301}")
        }
    }
#endif
