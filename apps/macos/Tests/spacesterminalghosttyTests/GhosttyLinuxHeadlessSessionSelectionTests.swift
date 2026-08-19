#if os(Linux)
    import Foundation
    import Testing
    import spacesterminalcore

    @testable import spacesterminalghostty

    /// Verifies the Linux headless core's `setSelection`/`clearSelection`/`readSelectionText` control
    /// path against a real `libghostty-vt` session: the shared (not owner-gated) selection is written
    /// through `spaces_ghostty_vt_session_set_selection`, read back as text, and exported every frame
    /// as a viewport-relative `GhosttyTerminalSelectionRange` via `GhosttyTerminalSelectionProjection`.
    ///
    /// These are behavioral tests over the real control path (`handleControlRequest`) and real per-frame
    /// export (`currentRemoteStatePayload(reason:)?.renderSnapshot`), not a copy of either's logic, and
    /// require the dynamic `libghostty-vt` runtime the core's vt session is built on. The pure vertical-crop
    /// math itself (fully-inside/extends-above/extends-below/rectangle/no-overlap) is covered exhaustively
    /// by `GhosttyTerminalSelectionProjectionTests` in spacesterminalcoreTests; what these tests prove is
    /// that the live core wires a real scrollbar offset and a real selection query into that math correctly.
    ///
    /// Deliberately not covered here: a selection endpoint garbaged by scrollback trimming. The shim-level
    /// trim/garbage-pin mechanics (`SpacesGhosttyVtSelectionState.valid` flipping false) are already proven
    /// by `GhosttyVtSessionSelectionTests.trimmingThePinnedRowMarksTheSelectionPresentButInvalid`, which uses
    /// a small custom `maxScrollback`. The core's own `maxScrollbackBytes` is a fixed 10MB
    /// (`TerminalScrollbackBudget.defaultMaxBytes`) and is not test-configurable, so reproducing a live trim
    /// through the full core would mean writing megabytes of PTY output in a unit test; the core's
    /// present-but-invalid handling in `resolvedSelection` (clear + defer a broadcast to the next engine-actor
    /// turn) was instead verified by manual review against that shim contract.
    ///
    /// See `GhosttyLinuxHeadlessSessionResizeTests` for the harness pattern this file follows (`Box`,
    /// per-instance `SPACES_DB_PATH`/`SPACES_RUNTIME_DIR` isolation, `.serialized`, Swift Testing instead of
    /// XCTest so async test bodies actually progress on Linux).
    @Suite(.serialized) final class GhosttyLinuxHeadlessSessionSelectionTests {
        private let originalDatabasePath: String?
        private let originalRuntimeDirectory: String?
        private let databaseRoot: URL

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
                sessionID: sessionID, backend: .ghosttyEmbedded, title: "selection",
                workingDirectory: FileManager.default.temporaryDirectory.path, shell: "/bin/sh", command: command, createdAt: "2026-08-17T00:00:00Z",
                workspaceID: "workspace-selection", kind: .shell)
        }

        /// Nonisolated poller so its `Task.sleep` suspensions don't hold the engine's queue while the
        /// engine runs the queued `handleOutput` tasks the condition is waiting on. See
        /// `GhosttyLinuxHeadlessSessionResizeTests.waitAsync` for the full rationale.
        private func waitAsync(
            timeout: TimeInterval = 30, transcriptPath: String? = nil, sourceLocation: SourceLocation = #_sourceLocation,
            _ condition: @escaping @TerminalEngineActor () -> Bool
        ) async throws {
            let started = Date()
            let deadline = started.addingTimeInterval(timeout)
            while Date() < deadline {
                if TerminalEngineActor.runSynchronously({ condition() }) { return }
                try? await Task.sleep(for: .milliseconds(30))
            }
            await GhosttyLinuxHeadlessHangDiagnostics.report(
                wait: "waitAsync at \(sourceLocation)", elapsed: Date().timeIntervalSince(started), timeout: timeout, transcriptPath: transcriptPath)
            #expect(TerminalEngineActor.runSynchronously { condition() }, "waitAsync timed out", sourceLocation: sourceLocation)
        }

        // MARK: - Engine-isolated helpers (call from inside a run/runSynchronously bridge)

        /// Attaches a remote-viewer owner so the core includes screen state (and, for these tests, the
        /// exported selection) in its state payloads; the state policy gates screen frames on an attached
        /// local/remote owner, matching `GhosttyLinuxHeadlessSessionResizeTests.attachRemoteOwner`.
        @TerminalEngineActor private static func attachRemoteOwner(to core: GhosttyEmbeddedSessionCore, id: String) {
            let client = TerminalClient(
                id: id, kind: .remoteViewer, identity: TerminalClientIdentity(label: "iPhone", deviceName: "iPhone"),
                connectedAt: "2026-08-17T00:00:00Z")
            let response = core.handleControlRequest(TerminalControlRequest(command: "attach", client: client, attachmentMode: .owner))
            #expect(response.ok, "attaching a remote owner must succeed: \(response.message)")
        }

        @TerminalEngineActor private static func renderedSnapshot(of core: GhosttyEmbeddedSessionCore) -> GhosttyTerminalSnapshot? {
            core.currentRemoteStatePayload(reason: TerminalRemoteSessionStateReason.initial)?.renderSnapshot
        }

        @TerminalEngineActor private static func renderedScreenText(of core: GhosttyEmbeddedSessionCore) -> String? {
            guard let snapshot = renderedSnapshot(of: core) else { return nil }
            return GhosttyTerminalSnapshotGrid.fullPlainText(for: snapshot)
        }

        /// A viewer that never took ownership setting the shared selection: not owner-gated, same as the
        /// macOS embedded host's `controlResponseForSetSelectionRequest`.
        @TerminalEngineActor private static func setSelection(
            _ core: GhosttyEmbeddedSessionCore, startColumn: UInt16, startRow: UInt32, endColumn: UInt16, endRow: UInt32, rectangle: Bool = false
        ) -> TerminalControlResponse {
            core.handleControlRequest(
                TerminalControlRequest(
                    command: "setSelection", clientID: "viewer-without-ownership", selectionStartColumn: startColumn,
                    selectionStartRow: startRow, selectionEndColumn: endColumn, selectionEndRow: endRow, selectionRectangle: rectangle))
        }

        @TerminalEngineActor private static func clearSelection(_ core: GhosttyEmbeddedSessionCore) -> TerminalControlResponse {
            core.handleControlRequest(TerminalControlRequest(command: "clearSelection", clientID: "viewer-without-ownership"))
        }

        @TerminalEngineActor private static func readSelectionText(_ core: GhosttyEmbeddedSessionCore) -> TerminalControlResponse {
            core.handleControlRequest(TerminalControlRequest(command: "readSelectionText", clientID: "viewer-without-ownership"))
        }

        // MARK: - Tests

        /// A selection entirely inside a 24x80 viewport that has not scrolled: screen-space and
        /// viewport-relative coordinates coincide (offset 0), so this is the simplest end-to-end proof
        /// that `setSelection` reaches the live vt session and the exported selection reflects it.
        @Test func selectionEntirelyInsideTheViewportExportsMatchingCoordinatesAndText() async throws {
            let paths = try makeTemporaryPaths()
            defer { try? FileManager.default.removeItem(atPath: paths.rootDirectory) }

            let marker = "hello world"
            let configuration = makeConfiguration(
                sessionID: "selection-inside-\(UUID().uuidString)", command: "stty -echo; printf '%s\\n' '\(marker)'; cat")
            let coreBox = try await TerminalEngineActor.run { () -> Box<GhosttyEmbeddedSessionCore> in
                let core = GhosttyEmbeddedSessionCore(launchConfiguration: configuration, paths: paths)
                try core.startIfNeeded()
                Self.attachRemoteOwner(to: core, id: "remote-owner")
                _ = core.handleControlRequest(TerminalControlRequest(command: "resize", columns: 80, rows: 24))
                return Box(core)
            }
            let core = coreBox.value
            defer { TerminalEngineActor.runSynchronously { core.terminate() } }
            try await waitAsync(transcriptPath: paths.outputPath) { Self.renderedScreenText(of: core)?.contains(marker) == true }

            // Columns 0...4 of row 0 select "hello" (end column is inclusive, matching
            // `spaces_ghostty_vt_session_set_selection`'s own contract).
            let setResponse = TerminalEngineActor.runSynchronously { Self.setSelection(core, startColumn: 0, startRow: 0, endColumn: 4, endRow: 0) }
            #expect(setResponse.ok, "setSelection must succeed: \(setResponse.message)")
            #expect(setResponse.selectionText == "hello")

            try await waitAsync { Self.renderedSnapshot(of: core)?.selection != nil }
            let selection = try #require(TerminalEngineActor.runSynchronously { Self.renderedSnapshot(of: core)?.selection })
            #expect(selection.startColumn == 0)
            #expect(selection.startRow == 0)
            #expect(selection.endColumn == 4)
            #expect(selection.endRow == 0)
            #expect(!selection.isRectangle)
            #expect(!selection.extendsAbove)
            #expect(!selection.extendsBelow)

            // A pure read must not disturb the shared selection.
            let readResponse = TerminalEngineActor.runSynchronously { Self.readSelectionText(core) }
            #expect(readResponse.ok)
            #expect(readResponse.selectionText == "hello")
            #expect(
                TerminalEngineActor.runSynchronously { Self.renderedSnapshot(of: core)?.selection } != nil,
                "reading selection text must not clear it")

            let clearResponse = TerminalEngineActor.runSynchronously { Self.clearSelection(core) }
            #expect(clearResponse.ok, "clearSelection must succeed: \(clearResponse.message)")
            try await waitAsync { Self.renderedSnapshot(of: core)?.selection == nil }
        }

        /// A selection anchored at screen row 0 (the oldest retained scrollback row) on a session whose
        /// live scrollback has grown well past the viewport's height. New output keeps the viewport
        /// pinned to the bottom (the terminal's default, unscrolled position), so the scrollbar's offset
        /// is naturally non-zero here without this test having to drive an explicit "scroll" control
        /// request (whose wheel-delta-to-row conversion is a separate, already-covered concern in
        /// `GhosttyLinuxMouseEncodingTests`). That non-zero offset is exactly what
        /// `GhosttyTerminalSelectionProjection` needs to rebase a screen-space selection into the
        /// viewport, so this proves the live scrollbar offset is actually threaded into that projection.
        @Test func selectionAnchoredAboveAPinnedToBottomViewportExtendsAbove() async throws {
            let paths = try makeTemporaryPaths()
            defer { try? FileManager.default.removeItem(atPath: paths.rootDirectory) }

            let lineCount = 40
            let printLines = (0..<lineCount).map { String(format: "line%02d", $0) }.map { "printf '%s\\n' '\($0)';" }.joined(separator: " ")
            let configuration = makeConfiguration(sessionID: "selection-scrollback-\(UUID().uuidString)", command: "stty -echo; \(printLines) cat")
            let coreBox = try await TerminalEngineActor.run { () -> Box<GhosttyEmbeddedSessionCore> in
                let core = GhosttyEmbeddedSessionCore(launchConfiguration: configuration, paths: paths)
                try core.startIfNeeded()
                Self.attachRemoteOwner(to: core, id: "remote-owner")
                _ = core.handleControlRequest(TerminalControlRequest(command: "resize", columns: 80, rows: 24))
                return Box(core)
            }
            let core = coreBox.value
            defer { TerminalEngineActor.runSynchronously { core.terminate() } }
            let lastLine = String(format: "line%02d", lineCount - 1)
            try await waitAsync(transcriptPath: paths.outputPath) { Self.renderedScreenText(of: core)?.contains(lastLine) == true }

            // The 40 printed lines overflowed the 24-row viewport, so the bottom-anchored viewport's
            // offset from the top of scrollback must be positive: "line00" scrolled off the top.
            let offset = try #require(TerminalEngineActor.runSynchronously { Self.renderedSnapshot(of: core)?.scrollbarOffset })
            #expect(offset > 0, "40 lines into a 24-row viewport must have scrolled content above the visible screen")
            let firstLine = String(format: "line%02d", 0)
            #expect(TerminalEngineActor.runSynchronously { Self.renderedScreenText(of: core)?.contains(firstLine) } == false)

            // Select from screen row 0 (off-screen, above the viewport) down to a row 5 rows into the
            // current viewport (offset + 5, still on-screen).
            let setResponse = TerminalEngineActor.runSynchronously {
                Self.setSelection(core, startColumn: 0, startRow: 0, endColumn: 79, endRow: offset + 5)
            }
            #expect(setResponse.ok, "setSelection spanning into scrollback must succeed: \(setResponse.message)")

            try await waitAsync { Self.renderedSnapshot(of: core)?.selection != nil }
            let selection = try #require(TerminalEngineActor.runSynchronously { Self.renderedSnapshot(of: core)?.selection })
            #expect(selection.extendsAbove, "a selection starting above the current viewport must report extendsAbove")
            #expect(!selection.extendsBelow)
            #expect(selection.startRow == 0, "the crop's first surviving row is the viewport's own top row")
            #expect(selection.endRow == 5, "screen row (offset + 5) rebases to viewport row 5")
        }

        /// `setSelection` without endpoints (the same validation the macOS embedded host and the protocol
        /// codec enforce) must fail with `.invalidArgument` rather than crash or silently no-op.
        @Test func setSelectionWithoutEndpointsReportsInvalidArgument() async throws {
            let paths = try makeTemporaryPaths()
            defer { try? FileManager.default.removeItem(atPath: paths.rootDirectory) }

            let configuration = makeConfiguration(sessionID: "selection-missing-endpoints-\(UUID().uuidString)", command: "stty -echo; cat")
            let coreBox = try await TerminalEngineActor.run { () -> Box<GhosttyEmbeddedSessionCore> in
                let core = GhosttyEmbeddedSessionCore(launchConfiguration: configuration, paths: paths)
                try core.startIfNeeded()
                Self.attachRemoteOwner(to: core, id: "remote-owner")
                return Box(core)
            }
            let core = coreBox.value
            defer { TerminalEngineActor.runSynchronously { core.terminate() } }
            try await waitAsync { Self.renderedSnapshot(of: core) != nil }

            let response = TerminalEngineActor.runSynchronously {
                core.handleControlRequest(TerminalControlRequest(command: "setSelection", clientID: "viewer-without-ownership"))
            }
            #expect(!response.ok)
            #expect(response.errorCode == .invalidArgument)
            #expect(response.message == "Missing selection endpoints.")
        }
    }
#endif
