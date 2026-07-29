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
    /// The headless core runs on `TerminalEngineActor`, so the test body stays nonisolated and hops
    /// onto the engine for every core call: cores are created inside a `TerminalEngineActor.run`
    /// block, carried back out through a `Box`, and used only via `runSynchronously`/`run` bridges.
    ///
    /// Swift Testing (not XCTest) on purpose: the swift-testing runner executes tests from an async
    /// main, so async tests actually make progress on Linux. Under corelibs-xctest an async test
    /// deadlocks before its first line regardless of isolation — the test job is queued to run while
    /// XCTest's blocked main thread polls in a loop that never drains it. Test bodies stay nonisolated
    /// (not `@MainActor`) because the headless core is isolated to `TerminalEngineActor`, a distinct
    /// global actor from `MainActor`: a nonisolated body can legally bridge onto the engine with the
    /// synchronous `TerminalEngineActor.runSynchronously`, whereas the one-way rule forbids calling
    /// that bridge from the main actor. `.serialized` because each test mutates the process-wide
    /// SPACES_* environment and owns a real PTY child.
    @Suite(.serialized) final class GhosttyLinuxHeadlessSessionResizeTests {
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

        private func makeConfiguration(sessionID: String, command: String?) -> TerminalSessionLaunchConfiguration {
            TerminalSessionLaunchConfiguration(
                sessionID: sessionID, backend: .ghosttyEmbedded, title: "resize", workingDirectory: FileManager.default.temporaryDirectory.path,
                shell: "/bin/sh", command: command, createdAt: "2026-07-20T00:00:00Z", workspaceID: "workspace-resize", kind: .shell)
        }

        /// Nonisolated poller so its `Task.sleep` suspensions don't hold the engine's queue while the
        /// engine runs the queued `handleOutput` tasks the condition is waiting on. Each poll hops onto
        /// the engine synchronously to evaluate the (engine-isolated) condition. libghostty-vt writes are
        /// synchronous, so unlike the macOS harness no renderer tick is needed here.
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

        /// Drives the trusted (client-less) resize command through the real control path.
        @TerminalEngineActor @discardableResult private static func resize(_ core: GhosttyEmbeddedSessionCore, columns: Int, rows: Int)
            -> TerminalControlResponse
        { core.handleControlRequest(TerminalControlRequest(command: "resize", columns: columns, rows: rows)) }

        /// Drives an attached owner's resize, carrying the serial that orders it against that client's
        /// other resizes.
        @TerminalEngineActor @discardableResult private static func resize(
            _ core: GhosttyEmbeddedSessionCore, clientID: String, columns: Int, rows: Int, serial: UInt64
        ) -> TerminalControlResponse {
            core.handleControlRequest(
                TerminalControlRequest(command: "resize", clientID: clientID, columns: columns, rows: rows, resizeSerial: serial))
        }

        @TerminalEngineActor private static func screenStateRevision(of core: GhosttyEmbeddedSessionCore) -> UInt64? {
            core.currentRemoteStatePayload(reason: TerminalRemoteSessionStateReason.initial)?.screenStateRevision
        }

        /// Reconstructs the visible screen text from a self-contained full-frame export.
        @TerminalEngineActor private static func renderedScreenText(of core: GhosttyEmbeddedSessionCore) -> String? {
            guard let snapshot = core.currentRemoteStatePayload(reason: TerminalRemoteSessionStateReason.initial)?.renderSnapshot else { return nil }
            return screenText(of: snapshot)
        }

        @TerminalEngineActor private static func renderedSnapshot(of core: GhosttyEmbeddedSessionCore) -> GhosttyTerminalSnapshot? {
            core.currentRemoteStatePayload(reason: TerminalRemoteSessionStateReason.initial)?.renderSnapshot
        }

        // MARK: - Tests

        /// Corrupts `output.log` with content that does not contain the rendered marker, then resizes.
        /// In-place resize keeps the live screen; the pre-fix recreate-and-replay path would rebuild
        /// the screen from the corrupted bytes and lose the marker, and a wide line would re-wrap from
        /// garbage rather than from its live content.
        @Test func resizeReflowsInPlaceWithoutReplayingTranscript() async throws {
            let paths = try makeTemporaryPaths()
            defer { try? FileManager.default.removeItem(atPath: paths.rootDirectory) }

            // A single logical line far wider than either grid width, so its wrapping depends entirely
            // on the current grid — reflow must re-wrap the live content, not replay a fixed transcript.
            let wideLine = String(repeating: "A", count: 120) + "END"
            let configuration = makeConfiguration(
                sessionID: "resize-reflow-\(UUID().uuidString)", command: "stty -echo; printf '%s\\n' '\(wideLine)'; cat")
            let coreBox = try await TerminalEngineActor.run { () -> Box<GhosttyEmbeddedSessionCore> in
                let core = GhosttyEmbeddedSessionCore(launchConfiguration: configuration, paths: paths)
                try core.startIfNeeded()
                Self.attachRemoteOwner(to: core, id: "remote-owner")
                return Box(core)
            }
            let core = coreBox.value
            defer { TerminalEngineActor.runSynchronously { core.terminate() } }
            try await waitAsync { Self.renderedScreenText(of: core)?.contains("END") == true }

            // The default 80-column grid wraps the 123-column line across at least two physical rows,
            // yet the reconstructed logical line is intact.
            let beforeSnapshot = try #require(TerminalEngineActor.runSynchronously { Self.renderedSnapshot(of: core) })
            #expect(beforeSnapshot.columns == 80)
            #expect(reflowedText(TerminalEngineActor.runSynchronously { Self.renderedScreenText(of: core) }) == wideLine)

            // Make output.log unusable for replay: overwrite it with content that shares no substring
            // with the rendered line. A from-zero replay would render this instead of the live screen.
            try Data("CORRUPTED_TRANSCRIPT_XYZ\n".utf8).write(to: URL(fileURLWithPath: paths.outputPath))

            let response = TerminalEngineActor.runSynchronously { Self.resize(core, columns: 100, rows: 30) }
            #expect(response.ok, "resize must succeed without reading output.log: \(response.message)")

            // The grid is the new size and the wide line re-wrapped for width 100 while keeping its
            // text — proving the live session reflowed rather than replaying the corrupted transcript.
            let afterSnapshot = try #require(TerminalEngineActor.runSynchronously { Self.renderedSnapshot(of: core) })
            #expect(afterSnapshot.columns == 100)
            #expect(afterSnapshot.rows == 30)
            let afterText = try #require(TerminalEngineActor.runSynchronously { Self.renderedScreenText(of: core) })
            #expect(reflowedText(afterText) == wideLine, "the wide line must survive the resize with its text intact after reflow")
            #expect(!afterText.contains("CORRUPTED_TRANSCRIPT_XYZ"), "resize must not render the corrupted transcript")
        }

        /// Deletes `output.log` before resizing. In-place resize never touches the file, so it
        /// succeeds and the live screen is preserved; the pre-fix recreate-and-replay path opens the
        /// (now missing) file, fails the replay, and returns a resize error.
        @Test func resizeSucceedsWhenTranscriptDeleted() async throws {
            let paths = try makeTemporaryPaths()
            defer { try? FileManager.default.removeItem(atPath: paths.rootDirectory) }

            let marker = "KEEP_MARKER"
            let configuration = makeConfiguration(
                sessionID: "resize-deleted-\(UUID().uuidString)", command: "stty -echo; printf '%s\\n' '\(marker)'; cat")
            let coreBox = try await TerminalEngineActor.run { () -> Box<GhosttyEmbeddedSessionCore> in
                let core = GhosttyEmbeddedSessionCore(launchConfiguration: configuration, paths: paths)
                try core.startIfNeeded()
                Self.attachRemoteOwner(to: core, id: "remote-owner")
                return Box(core)
            }
            let core = coreBox.value
            defer { TerminalEngineActor.runSynchronously { core.terminate() } }
            try await waitAsync { Self.renderedScreenText(of: core)?.contains(marker) == true }

            // Remove the durable transcript. The live session still holds the rendered marker.
            try FileManager.default.removeItem(atPath: paths.outputPath)

            let response = TerminalEngineActor.runSynchronously { Self.resize(core, columns: 90, rows: 28) }
            #expect(response.ok, "resize must succeed even with no transcript file to replay: \(response.message)")

            let snapshot = try #require(TerminalEngineActor.runSynchronously { Self.renderedSnapshot(of: core) })
            #expect(snapshot.columns == 90)
            #expect(snapshot.rows == 28)
            #expect(Self.screenText(of: snapshot).contains(marker), "the live screen content must survive a resize that cannot read output.log")
        }

        /// Carries a same-size resize's observations out of the single engine hop they are taken in, so
        /// no output turn can land between the readings and move the revision on its own.
        private struct SameSizeResizeOutcome: Sendable {
            let revisionBefore: UInt64?
            let response: TerminalControlResponse
            let revisionAfter: UInt64?
            let snapshot: GhosttyTerminalSnapshot?
        }

        /// A client that comes back to a session it left at the same size resizes it to the grid it
        /// already has. Reflowing that rewrites every row, advances the screen revision and pushes a
        /// full frame to every attached client — a visible flash of stale layout on a screen that did
        /// not change — so the session must answer it without touching the terminal.
        @Test func resizingToTheGridTheSessionAlreadyHasChangesNothing() async throws {
            let paths = try makeTemporaryPaths()
            defer { try? FileManager.default.removeItem(atPath: paths.rootDirectory) }

            let marker = "STEADY_MARKER"
            let configuration = makeConfiguration(
                sessionID: "resize-noop-\(UUID().uuidString)", command: "stty -echo; printf '%s\\n' '\(marker)'; cat")
            let coreBox = try await TerminalEngineActor.run { () -> Box<GhosttyEmbeddedSessionCore> in
                let core = GhosttyEmbeddedSessionCore(launchConfiguration: configuration, paths: paths)
                try core.startIfNeeded()
                Self.attachRemoteOwner(to: core, id: "remote-owner")
                return Box(core)
            }
            let core = coreBox.value
            defer { TerminalEngineActor.runSynchronously { core.terminate() } }
            try await waitAsync { Self.renderedScreenText(of: core)?.contains(marker) == true }

            // Settle the session on a grid other than its 80x24 default, so the repeat below is a
            // deliberate resize to a size the session was told about rather than its starting state.
            let settled = TerminalEngineActor.runSynchronously { Self.resize(core, columns: 96, rows: 26) }
            #expect(settled.ok, "the first resize must succeed: \(settled.message)")

            let outcome = TerminalEngineActor.runSynchronously { () -> SameSizeResizeOutcome in
                let revisionBefore = Self.screenStateRevision(of: core)
                let response = Self.resize(core, columns: 96, rows: 26)
                return SameSizeResizeOutcome(
                    revisionBefore: revisionBefore, response: response, revisionAfter: Self.screenStateRevision(of: core),
                    snapshot: Self.renderedSnapshot(of: core))
            }

            #expect(outcome.response.ok, "a resize to the current grid must succeed: \(outcome.response.message)")
            #expect(
                outcome.revisionBefore == outcome.revisionAfter,
                "a resize to the grid the session already has reflowed the screen and pushed a new frame to every client")
            let snapshot = try #require(outcome.snapshot)
            #expect(snapshot.columns == 96)
            #expect(snapshot.rows == 26)
            #expect(Self.screenText(of: snapshot).contains(marker), "the screen content must survive a resize to the size it already had")
        }

        /// Carries an out-of-order resize pair's observations out of the one engine hop they are sent in.
        private struct OutOfOrderResizeOutcome: Sendable {
            let newer: TerminalControlResponse
            let stale: TerminalControlResponse
            let snapshot: GhosttyTerminalSnapshot?
        }

        /// Resizes leave a client off its serialized input path, so two sizes measured in order can
        /// reach the session out of order. The size the client has already left must never win: a
        /// session pinned to a superseded grid stays narrow until something else resizes it, with every
        /// client rendering the wrong width in the meantime.
        @Test func resizeThatArrivesAfterANewerOneIsIgnored() async throws {
            let paths = try makeTemporaryPaths()
            defer { try? FileManager.default.removeItem(atPath: paths.rootDirectory) }

            let marker = "ORDERED_MARKER"
            let configuration = makeConfiguration(
                sessionID: "resize-serial-\(UUID().uuidString)", command: "stty -echo; printf '%s\\n' '\(marker)'; cat")
            let coreBox = try await TerminalEngineActor.run { () -> Box<GhosttyEmbeddedSessionCore> in
                let core = GhosttyEmbeddedSessionCore(launchConfiguration: configuration, paths: paths)
                try core.startIfNeeded()
                Self.attachRemoteOwner(to: core, id: "remote-owner")
                return Box(core)
            }
            let core = coreBox.value
            defer { TerminalEngineActor.runSynchronously { core.terminate() } }
            try await waitAsync { Self.renderedScreenText(of: core)?.contains(marker) == true }

            let outcome = TerminalEngineActor.runSynchronously { () -> OutOfOrderResizeOutcome in
                let newer = Self.resize(core, clientID: "remote-owner", columns: 100, rows: 30, serial: 7)
                // The grid the pane passed through before it settled, delivered late.
                let stale = Self.resize(core, clientID: "remote-owner", columns: 16, rows: 5, serial: 6)
                return OutOfOrderResizeOutcome(newer: newer, stale: stale, snapshot: Self.renderedSnapshot(of: core))
            }

            #expect(outcome.newer.ok, "the newest resize must be applied: \(outcome.newer.message)")
            #expect(!outcome.stale.ok, "a resize older than the one already applied must be rejected")
            let staleSnapshot = try #require(outcome.snapshot)
            #expect(staleSnapshot.columns == 100, "a superseded resize pinned the session to a grid its client had already left")
            #expect(staleSnapshot.rows == 30, "a superseded resize pinned the session to a grid its client had already left")
        }

        /// Carries a reconnecting owner's resize observations out of the one engine hop they are sent in.
        private struct ReattachedResizeOutcome: Sendable {
            let reattach: TerminalControlResponse
            let restarted: TerminalControlResponse
            let snapshot: GhosttyTerminalSnapshot?
        }

        /// A client that reconnects to a session it already owns keeps its client id — the app reattaches
        /// as the same owner after a relaunch — while the host behind it is new and counts resize serials
        /// from zero again. Nothing else retires the previous attachment's serials on that path: the owner
        /// did not change, so the epoch does not advance. The attach itself has to start a fresh serial
        /// incarnation, or every resize the reconnected client sends is rejected as stale and its pane
        /// stays pinned to the grid it had before.
        @Test func resizeSerialsRestartedByAReattachingOwnerAreAccepted() async throws {
            let paths = try makeTemporaryPaths()
            defer { try? FileManager.default.removeItem(atPath: paths.rootDirectory) }

            let marker = "REATTACH_MARKER"
            let configuration = makeConfiguration(
                sessionID: "resize-reattach-\(UUID().uuidString)", command: "stty -echo; printf '%s\\n' '\(marker)'; cat")
            let coreBox = try await TerminalEngineActor.run { () -> Box<GhosttyEmbeddedSessionCore> in
                let core = GhosttyEmbeddedSessionCore(launchConfiguration: configuration, paths: paths)
                try core.startIfNeeded()
                Self.attachRemoteOwner(to: core, id: "remote-owner")
                return Box(core)
            }
            let core = coreBox.value
            defer { TerminalEngineActor.runSynchronously { core.terminate() } }
            try await waitAsync { Self.renderedScreenText(of: core)?.contains(marker) == true }

            let settled = TerminalEngineActor.runSynchronously { Self.resize(core, clientID: "remote-owner", columns: 100, rows: 30, serial: 5) }
            #expect(settled.ok, "the first attachment's resize must be applied: \(settled.message)")

            let outcome = TerminalEngineActor.runSynchronously { () -> ReattachedResizeOutcome in
                // The same client attaches again as owner: no ownership change, so no epoch advance.
                let client = TerminalClient(
                    id: "remote-owner", kind: .remoteViewer, identity: TerminalClientIdentity(label: "iPhone", deviceName: "iPhone"),
                    connectedAt: "2026-07-29T00:00:00Z")
                let reattach = core.handleControlRequest(TerminalControlRequest(command: "attach", client: client, attachmentMode: .owner))
                let restarted = Self.resize(core, clientID: "remote-owner", columns: 70, rows: 20, serial: 1)
                return ReattachedResizeOutcome(reattach: reattach, restarted: restarted, snapshot: Self.renderedSnapshot(of: core))
            }

            #expect(outcome.reattach.ok, "the owner must be able to attach again: \(outcome.reattach.message)")
            #expect(outcome.restarted.ok, "a reconnected owner's restarted resize serial was rejected as stale: \(outcome.restarted.message)")
            let snapshot = try #require(outcome.snapshot)
            #expect(snapshot.columns == 70, "the reconnected owner's resize did not reach the terminal")
            #expect(snapshot.rows == 20, "the reconnected owner's resize did not reach the terminal")
        }
    }
#endif
