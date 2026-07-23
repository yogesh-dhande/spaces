import Dispatch
import Foundation
import XCTest

@testable import spacesterminalcore
@testable import spacesterminalghostty

/// Regression for input starvation under continuous output (the daemon main-actor offload).
///
/// An agent TUI floods the terminal engine actor with output-drain and per-chunk render-broadcast work.
/// A control-request input write must still reach the PTY promptly rather than queueing behind that
/// backlog on the serial engine executor until output pauses. The regression this guards against had the
/// broadcast path re-reading runtime state and the attachment snapshot from SQLite on every output chunk,
/// saturating the engine so typed input only landed once the agent went idle.
///
/// Exercised WITH a state-stream subscriber attached — the primary product scenario, a GUI mirror — so the
/// per-output-chunk broadcast pipeline actually runs (it is skipped when nobody is subscribed).
///
/// A plain (non-`@MainActor`, non-engine) `XCTestCase` with an `async` test method, so it runs on a
/// cooperative-pool thread: neither the main actor nor the engine actor (which a background
/// `runSynchronously` would deadlock against if the test occupied it).
final class TerminalEngineInputUnderOutputLoadRegressionTests: XCTestCase {
    /// Carries the engine-isolated core reference to the engine bridge from a background thread — the core
    /// is only ever *used* on the engine actor; this box merely moves the reference.
    private final class CoreBox: @unchecked Sendable {
        let core: GhosttyEmbeddedSessionCore
        let paths: TerminalSessionPaths
        let outputPath: String
        let root: URL
        init(core: GhosttyEmbeddedSessionCore, paths: TerminalSessionPaths, root: URL) {
            self.core = core
            self.paths = paths
            self.outputPath = paths.outputPath
            self.root = root
        }
    }

    func testInputReachesTranscriptWhileOutputFloodsWithSubscriberAttached() async throws {
        // A PTY-backed session that BOTH echoes stdin (`cat`) and continuously floods output (the dot
        // loop). The flood keeps the engine actor busy with drain + broadcast work; `cat` echoes a later
        // send so it appears in the transcript.
        let box = try await TerminalEngineActor.run { () -> CoreBox in
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let paths = TerminalSessionPaths(rootDirectory: root.path)
            try paths.ensureDirectories()
            let launch = TerminalSessionLaunchConfiguration(
                sessionID: "engine-inputload-\(UUID().uuidString)", backend: .ghosttyEmbedded, title: "shell",
                workingDirectory: FileManager.default.temporaryDirectory.path, shell: "/bin/sh",
                command: "cat & while : ; do printf . ; sleep 0.02 ; done", createdAt: "2026-07-21T00:00:00Z", workspaceID: "workspace-1",
                kind: .shell)
            let core = GhosttyEmbeddedSessionCore(launchConfiguration: launch, paths: paths)
            try core.startIfNeeded()
            return CoreBox(core: core, paths: paths, root: root)
        }
        defer {
            TerminalEngineActor.runSynchronously { box.core.terminate() }
            try? FileManager.default.removeItem(at: box.root)
        }

        // Attach the GUI mirror's own stream client as a subscriber so the per-output-chunk broadcast
        // pipeline runs (it is skipped entirely when there are no subscribers).
        let subscriber = GhosttyRemoteSessionStateStreamClient(socketPath: box.paths.subscriptionSocketPath, onEvent: { _ in }, onDisconnect: {})
        try subscriber.start()
        defer { subscriber.stop() }

        // Wait until output is genuinely flooding (the transcript is growing) so the send lands mid-stream,
        // and give the subscriber connection a moment to register with the stream server. This wait is a
        // precondition, not the regression assertion: the dot loop forks /bin/sleep per iteration, which
        // caps it near 30 dots/sec even on a fast machine, so a loaded CI runner needs well over 5s to
        // clear the 64-byte threshold. The 5s input-latency budget below is what guards the regression.
        let floodDeadline = Date().addingTimeInterval(20.0)
        var floodedByteCount = 0
        while Date() < floodDeadline {
            floodedByteCount = (FileManager.default.contents(atPath: box.outputPath)?.count) ?? 0
            if floodedByteCount > 64 { break }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertGreaterThan(floodedByteCount, 64, "output flood never started")
        // Let the flood run for a beat so a broadcast backlog would have formed if input shared its fate.
        try? await Task.sleep(nanoseconds: 400_000_000)

        // Drive a control send through the engine's synchronous bridge from THIS cooperative-pool thread
        // (a stand-in for a daemon transport worker), mid-flood. `cat` echoes the marker.
        let marker = "inputload-\(UUID().uuidString.prefix(8))"
        let (ok, message) = TerminalEngineActor.runSynchronously { () -> (Bool, String) in
            let request = TerminalControlRequest(command: "send", text: "\(marker)\n", appendNewline: false)
            let response = box.core.handleControlRequest(request)
            return (response.ok, response.message)
        }
        XCTAssertTrue(ok, "control send should succeed under output load: \(message)")

        // The echoed marker must reach the transcript within a bounded time DESPITE the continuous output
        // flood + per-chunk broadcast load. Under the pre-fix per-chunk DB churn the marker did not land
        // until the flood stopped (many seconds); the 5s budget is generous for the fixed path (which lands
        // in well under a second) yet far below the starvation the regression produced.
        let echoDeadline = Date().addingTimeInterval(5.0)
        var sawEcho = false
        while Date() < echoDeadline {
            if let data = FileManager.default.contents(atPath: box.outputPath), let transcript = String(data: data, encoding: .utf8),
                transcript.contains(marker)
            {
                sawEcho = true
                break
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(sawEcho, "input did not reach the transcript within 5s while output was flooding — input starved behind the broadcast load")
    }
}
