import Foundation
import XCTest

@testable import spacesterminalcore
@testable import spacesterminalghostty

/// What an `attach` control costs the database (issue #298). Every refocus of an already-open terminal pane
/// re-attaches the same client in the same mode, so an attach that changes nothing must write nothing: the
/// durable runtime-state row is the expensive part (a delete plus a wide upsert on the shared profile
/// database, inline on the queue that also carries every session's keystrokes), and no reader learns
/// anything from rewriting it with identical values.
///
/// Each test stamps a sentinel `updatedAt` straight into the durable row after the core's own write has
/// committed, then drives another attach: the sentinel surviving means the core skipped the write, the
/// sentinel being replaced means it performed one. That counts real database writes without instrumenting
/// product code, and without depending on the second-resolution timestamp differing between two attaches.
final class GhosttyEmbeddedSessionAttachWriteTests: XCTestCase {

    override func setUpWithError() throws { try useIsolatedSpacesProfile() }

    private static let sentinelUpdatedAt = "1999-01-01T00:00:00Z"

    /// Carries the engine-isolated core to the engine bridge from a background thread; the core is only ever
    /// *used* on the engine actor.
    private final class CoreBox: @unchecked Sendable {
        let core: GhosttyEmbeddedSessionCore
        let paths: TerminalSessionPaths
        let root: URL
        init(core: GhosttyEmbeddedSessionCore, paths: TerminalSessionPaths, root: URL) {
            self.core = core
            self.paths = paths
            self.root = root
        }
    }

    private func makeStartedCore() async throws -> CoreBox {
        try await TerminalEngineActor.run { () -> CoreBox in
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let paths = TerminalSessionPaths(rootDirectory: root.path)
            try paths.ensureDirectories()
            let launch = TerminalSessionLaunchConfiguration(
                sessionID: "attach-write-\(UUID().uuidString)", backend: .ghosttyEmbedded, title: "shell",
                workingDirectory: FileManager.default.temporaryDirectory.path, shell: "/bin/sh", command: "cat", createdAt: "2026-07-26T00:00:00Z",
                workspaceID: "workspace-1", kind: .shell)
            let core = GhosttyEmbeddedSessionCore(launchConfiguration: launch, paths: paths)
            try core.startIfNeeded()
            return CoreBox(core: core, paths: paths, root: root)
        }
    }

    private func attach(_ client: TerminalClient, mode: TerminalAttachmentMode, on box: CoreBox) {
        let response = TerminalEngineActor.runSynchronously { () -> TerminalControlResponse in
            box.core.handleControlRequest(.init(command: "attach", client: client, attachmentMode: mode))
        }
        XCTAssertTrue(response.ok, "attach should be accepted: \(response.message)")
        TerminalEngineActor.runSynchronously { box.core.debugDrainPersistenceQueue() }
    }

    private func stampSentinelRuntimeState(on box: CoreBox) throws {
        let current = try TerminalSessionPersistence.readRuntimeState(paths: box.paths)
        let sentinel = TerminalSessionRuntimeState(
            sessionID: current.sessionID, backend: current.backend, servicePID: current.servicePID, childPID: current.childPID, state: current.state,
            updatedAt: Self.sentinelUpdatedAt, exitedAt: current.exitedAt, title: current.title, workingDirectory: current.workingDirectory,
            columns: current.columns, rows: current.rows)
        try TerminalSessionPersistence.writeRuntimeState(sentinel, paths: box.paths)
    }

    private func durableUpdatedAt(on box: CoreBox) throws -> String {
        try TerminalSessionPersistence.readRuntimeState(paths: box.paths).updatedAt
    }

    private func makeClient() -> TerminalClient {
        TerminalClient(id: "window-client", kind: .localWindow, identity: .init(label: "Spaces window"), connectedAt: "2026-07-26T00:00:00Z")
    }

    func testReAttachingTheSameClientInTheSameModeRewritesNoRuntimeState() async throws {
        let box = try await makeStartedCore()
        defer {
            TerminalEngineActor.runSynchronously { box.core.terminate() }
            try? FileManager.default.removeItem(at: box.root)
        }
        let client = makeClient()

        attach(client, mode: .owner, on: box)
        try stampSentinelRuntimeState(on: box)

        attach(client, mode: .owner, on: box)

        XCTAssertEqual(
            try durableUpdatedAt(on: box), Self.sentinelUpdatedAt,
            "an attach that leaves the attachments exactly as it found them must not rewrite the runtime-state row")
    }

    func testAttachingTheSameClientInANewModeWritesRuntimeState() async throws {
        let box = try await makeStartedCore()
        defer {
            TerminalEngineActor.runSynchronously { box.core.terminate() }
            try? FileManager.default.removeItem(at: box.root)
        }
        let client = makeClient()

        attach(client, mode: .viewer, on: box)
        try stampSentinelRuntimeState(on: box)

        attach(client, mode: .owner, on: box)

        XCTAssertNotEqual(
            try durableUpdatedAt(on: box), Self.sentinelUpdatedAt,
            "promoting a client to owner changes the session's attachments, so the runtime state is written")
    }
}
