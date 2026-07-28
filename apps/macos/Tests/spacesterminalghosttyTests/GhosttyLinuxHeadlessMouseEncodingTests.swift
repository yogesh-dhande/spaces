#if os(Linux)
    import Foundation
    import Testing
    import spacesterminalcore

    @testable import spacesterminalghostty

    /// Linux mirror of the macOS daemon's mouse path. The macOS daemon hands a button to its ghostty
    /// surface; this host runs libghostty-vt's mouse encoder against the vt session. Both must produce the
    /// report the running program asked for, or a mouse-aware application would work on a local pane and
    /// do nothing on a remote one.
    ///
    /// The child puts the tty in raw mode and runs `cat -v`, so every byte the daemon writes comes back
    /// through the PTY in a readable form: an escape as `^[`.
    ///
    /// Swift Testing (not XCTest) on purpose: the swift-testing runner executes tests from an async main,
    /// so async tests make progress on Linux, where an async XCTest method deadlocks. The headless core is
    /// `TerminalEngineActor`-isolated, so the test body stays nonisolated and hops onto the engine for
    /// every core call. `.serialized` because each test mutates the process-wide SPACES_* environment and
    /// owns a real PTY child.
    @Suite(.serialized) final class GhosttyLinuxHeadlessMouseEncodingTests {
        private let originalDatabasePath: String?
        private let originalRuntimeDirectory: String?
        private let databaseRoot: URL

        /// Carries an engine-isolated reference back out to the nonisolated test body; it is only ever used
        /// again through an engine bridge.
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

        // MARK: - Helpers

        private static func transcript(at path: String) -> String { (try? String(contentsOfFile: path, encoding: .utf8)) ?? "" }

        private static func occurrences(of needle: String, in haystack: String) -> Int { haystack.components(separatedBy: needle).count - 1 }

        /// Nonisolated poller so its suspensions don't hold the engine's queue while the engine runs the
        /// queued writes the condition is waiting on.
        private func waitUntil(timeout: TimeInterval = 15, _ comment: Comment, condition: @escaping @Sendable () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if condition() { return }
                try? await Task.sleep(for: .milliseconds(30))
            }
            #expect(condition(), comment)
        }

        /// `programEnables` is emitted by the child before it starts echoing, which is how a real program
        /// announces the mouse modes that decide whether a click is reported at all and in which format.
        private func startEchoSession(programEnables: String = "") async throws -> (core: Box<GhosttyEmbeddedSessionCore>, outputPath: String) {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let paths = TerminalSessionPaths(rootDirectory: root.path)
            try paths.ensureDirectories()
            let enableModes = programEnables.isEmpty ? "" : "printf '\(programEnables)'; "
            let command = "stty raw -echo; \(enableModes)printf 'MOUSE_READY'; cat -v"

            let coreBox = try await TerminalEngineActor.run { () -> Box<GhosttyEmbeddedSessionCore> in
                let core = GhosttyEmbeddedSessionCore(
                    launchConfiguration: TerminalSessionLaunchConfiguration(
                        sessionID: "mouse-encoding-\(UUID().uuidString)", backend: .ghosttyEmbedded, title: "owner",
                        workingDirectory: FileManager.default.temporaryDirectory.path, shell: "/bin/sh", command: command,
                        createdAt: "2026-07-24T00:00:00Z", workspaceID: "workspace-1", kind: .shell), paths: paths)
                try core.startIfNeeded()
                return Box(core)
            }
            let outputPath = paths.outputPath
            try await waitUntil("the child must reach its echo loop") { Self.transcript(at: outputPath).contains("MOUSE_READY") }
            return (coreBox, outputPath)
        }

        private func terminate(_ core: Box<GhosttyEmbeddedSessionCore>) { TerminalEngineActor.runSynchronously { core.value.terminate() } }

        /// Clicks the top-left cell, which the normalized pointer (0, 0) always names whatever the session's
        /// grid size is, so the expected SGR coordinates are fixed at 1;1.
        @discardableResult private func sendTopLeftClick(pressed: Bool, to core: Box<GhosttyEmbeddedSessionCore>) -> TerminalControlResponse {
            TerminalEngineActor.runSynchronously {
                core.value.handleControlRequest(
                    TerminalControlRequest(
                        command: "mouseButton", mouseButton: 1, mousePressed: pressed, mousePointerX: 0, mousePointerY: 0, mousePointerMods: 0))
            }
        }

        @discardableResult private func sendWheel(vertical: Double, horizontal: Double = 0, to core: Box<GhosttyEmbeddedSessionCore>)
            -> TerminalControlResponse
        {
            TerminalEngineActor.runSynchronously {
                core.value.handleControlRequest(
                    TerminalControlRequest(
                        command: "scroll", scrollHorizontal: horizontal, scrollVertical: vertical, scrollMods: 0, scrollPointerX: 0,
                        scrollPointerY: 0, scrollPointerMods: 0))
            }
        }

        // MARK: - Tests

        /// `CSI ? 1000 h` turns on normal button tracking and `CSI ? 1006 h` selects SGR reports, which is
        /// what vim, htop, and tmux enable.
        @Test func clicksReachTheChildAsSGRReportsOnceTheProgramEnablesMouseTracking() async throws {
            let (core, outputPath) = try await startEchoSession(programEnables: "\\033[?1000h\\033[?1006h")
            defer { terminate(core) }

            let press = sendTopLeftClick(pressed: true, to: core)
            #expect(press.ok, "a press must be accepted: \(press.message)")
            try await waitUntil("the press must arrive as an SGR report") { Self.transcript(at: outputPath).contains("^[[<0;1;1M") }

            let release = sendTopLeftClick(pressed: false, to: core)
            #expect(release.ok, "a release must be accepted: \(release.message)")
            try await waitUntil("the release must arrive as an SGR report") { Self.transcript(at: outputPath).contains("^[[<0;1;1m") }
        }

        /// A program that never enabled tracking must not start receiving escape sequences it cannot parse.
        @Test func clicksSendNothingWhileTheProgramIsNotTrackingTheMouse() async throws {
            let (core, outputPath) = try await startEchoSession()
            defer { terminate(core) }

            let press = sendTopLeftClick(pressed: true, to: core)
            #expect(press.ok, "an unreported press is still a successful no-op: \(press.message)")
            sendTopLeftClick(pressed: false, to: core)

            // Give the write queue a chance to deliver anything it was going to deliver.
            try? await Task.sleep(for: .milliseconds(300))
            let output = Self.transcript(at: outputPath)
            #expect(!output.contains("^[[<"), "no mouse report may reach a program that is not tracking: \(output)")
        }

        /// While an application tracks the mouse the wheel belongs to it, not to the local viewport, and
        /// ghostty reports one button-four/five press per row of delta.
        @Test func wheelEventsAreReportedToTheChildWhileTheProgramTracksTheMouse() async throws {
            let (core, outputPath) = try await startEchoSession(programEnables: "\\033[?1000h\\033[?1006h")
            defer { terminate(core) }

            let up = sendWheel(vertical: 1, to: core)
            #expect(up.ok, "a wheel event must be accepted: \(up.message)")
            try await waitUntil("scrolling up must report button four") { Self.transcript(at: outputPath).contains("^[[<64;1;1M") }

            let down = sendWheel(vertical: -1, to: core)
            #expect(down.ok, "a wheel event must be accepted: \(down.message)")
            try await waitUntil("scrolling down must report button five") { Self.transcript(at: outputPath).contains("^[[<65;1;1M") }
        }

        /// Horizontal wheel deltas belong to a tracking application too: ghostty reports one button-six
        /// press per notch scrolled right and one button-seven press per notch scrolled left, so a
        /// horizontal-only gesture must not be dropped as a zero vertical delta. Exactly one report per
        /// notch — the x axis has no discrete multiplier, unlike the vertical axis.
        @Test func horizontalWheelEventsAreReportedToTheChildWhileTheProgramTracksTheMouse() async throws {
            let (core, outputPath) = try await startEchoSession(programEnables: "\\033[?1000h\\033[?1006h")
            defer { terminate(core) }

            let right = sendWheel(vertical: 0, horizontal: 1, to: core)
            #expect(right.ok, "a horizontal wheel event must be accepted: \(right.message)")
            try await waitUntil("scrolling right must report button six") { Self.transcript(at: outputPath).contains("^[[<66;1;1M") }

            let left = sendWheel(vertical: 0, horizontal: -1, to: core)
            #expect(left.ok, "a horizontal wheel event must be accepted: \(left.message)")
            try await waitUntil("scrolling left must report button seven") { Self.transcript(at: outputPath).contains("^[[<67;1;1M") }

            // Give the write queue a chance to deliver anything else it was going to deliver, then
            // pin the per-notch contract: one report per notch, not the vertical axis' multiplied count.
            try? await Task.sleep(for: .milliseconds(300))
            let output = Self.transcript(at: outputPath)
            #expect(Self.occurrences(of: "^[[<66;1;1M", in: output) == 1, "one right notch must produce exactly one report: \(output)")
            #expect(Self.occurrences(of: "^[[<67;1;1M", in: output) == 1, "one left notch must produce exactly one report: \(output)")
        }

        @Test func wheelEventsStayLocalWhileTheProgramIsNotTrackingTheMouse() async throws {
            let (core, outputPath) = try await startEchoSession()
            defer { terminate(core) }

            sendWheel(vertical: 1, to: core)

            try? await Task.sleep(for: .milliseconds(300))
            let output = Self.transcript(at: outputPath)
            #expect(Self.occurrences(of: "^[[<", in: output) == 0, "a local viewport scroll must write nothing to the child: \(output)")
        }
    }
#endif
