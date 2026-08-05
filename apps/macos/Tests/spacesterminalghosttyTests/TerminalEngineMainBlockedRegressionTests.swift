import Dispatch
import Foundation
import XCTest

@testable import spacesterminalcore
@testable import spacesterminalghostty

/// The headline regression for the daemon main-actor offload: a hard-blocked MAIN actor must NOT freeze
/// the embedded terminal engine. The engine (session core, PTY read loop, tick pump) runs on its own
/// `TerminalEngineActor`; a control request driven from a background (transport-like) thread through the
/// engine's synchronous bridge must complete promptly even while the main actor is stuck, and PTY output
/// must keep flowing to the transcript during the block.
///
/// This test is a plain (non-`@MainActor`, non-engine) `XCTestCase` whose test method is `async`, so it
/// runs on a cooperative-pool thread — neither the main actor (which it deliberately blocks) nor the
/// engine actor (which would deadlock a background `runSynchronously` if the test occupied it).
final class TerminalEngineMainBlockedRegressionTests: XCTestCase {

    override func setUpWithError() throws { try useIsolatedSpacesProfile() }

    /// Carries the engine-isolated core reference to the engine bridge from a background thread — the same
    /// shape the daemon uses (engine-isolated `sessionCores` reached inside `runSynchronously`). The core
    /// is only ever *used* on the engine actor; this box merely moves the reference, never touching it
    /// off-engine, which is what makes the `@unchecked Sendable` sound.
    private final class CoreBox: @unchecked Sendable {
        let core: GhosttyEmbeddedSessionCore
        let outputPath: String
        let root: URL
        init(core: GhosttyEmbeddedSessionCore, outputPath: String, root: URL) {
            self.core = core
            self.outputPath = outputPath
            self.root = root
        }
    }

    func testControlRequestCompletesAndOutputFlowsWhileMainActorBlocked() async throws {
        // Build + start a real PTY-backed session on the engine actor. `cat` echoes stdin, so a later
        // send both exercises the control path and produces transcript output. Setup uses the async
        // engine hop (create-time NSView/NSScreen hops back to a still-free main thread here).
        let box = try await TerminalEngineActor.run { () -> CoreBox in
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let paths = TerminalSessionPaths(rootDirectory: root.path)
            try paths.ensureDirectories()
            let launch = TerminalSessionLaunchConfiguration(
                sessionID: "engine-mainblock-\(UUID().uuidString)", backend: .ghosttyEmbedded, title: "shell",
                workingDirectory: FileManager.default.temporaryDirectory.path, shell: "/bin/sh", command: "cat", createdAt: "2026-07-21T00:00:00Z",
                workspaceID: "workspace-1", kind: .shell)
            let core = GhosttyEmbeddedSessionCore(launchConfiguration: launch, paths: paths)
            try core.startIfNeeded()
            return CoreBox(core: core, outputPath: paths.outputPath, root: root)
        }
        defer {
            TerminalEngineActor.runSynchronously { box.core.terminate() }
            try? FileManager.default.removeItem(at: box.root)
        }

        // Hard-block the main actor for well beyond the assertions' timing budget, and confirm the block
        // has actually begun before proceeding.
        let mainBlockDuration: TimeInterval = 3.0
        let mainBlockStarted = DispatchSemaphore(value: 0)
        DispatchQueue.main.async {
            mainBlockStarted.signal()
            Thread.sleep(forTimeInterval: mainBlockDuration)
        }
        XCTAssertEqual(mainBlockStarted.wait(timeout: .now() + 1.0), .success, "main-actor block never started")
        // Give the blocking sleep a moment to be firmly running on the main thread.
        try? await Task.sleep(nanoseconds: 50_000_000)

        // Drive a control send through the engine's synchronous bridge from THIS cooperative-pool thread
        // (a stand-in for a daemon transport worker) and time it. The marker text is echoed by `cat`.
        let marker = "engine-alive-\(UUID().uuidString.prefix(8))"
        let start = DispatchTime.now()
        let (ok, message) = TerminalEngineActor.runSynchronously { () -> (Bool, String) in
            let request = TerminalControlRequest(command: "send", text: "\(marker)\n", appendNewline: false)
            let response = box.core.handleControlRequest(request)
            return (response.ok, response.message)
        }
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds &- start.uptimeNanoseconds) / 1_000_000_000

        XCTAssertTrue(ok, "control send should succeed while the main actor is blocked: \(message)")
        // Generous margin (the main actor is blocked for 3s); a working offload completes in single-digit ms.
        XCTAssertLessThan(elapsed, 0.5, "control send took \(elapsed)s while main was blocked — the engine must not depend on the main actor")

        // PTY echo must reach the transcript WHILE the main actor is still blocked: the read loop + tick
        // pump + output persistence all run on the engine actor, so `cat`'s echo of the marker should
        // appear in output.log within the remaining block window.
        let echoDeadline = Date().addingTimeInterval(2.0)
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
        XCTAssertTrue(sawEcho, "PTY echo did not reach the transcript while the main actor was blocked")
    }
}
