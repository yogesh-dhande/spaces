import Foundation
import XCTest

@testable import spacesterminalcore
@testable import spacesterminalghostty

/// Lease-touch coalescing on the embedded core's send path (issue #212): typing must not spend one durable
/// `BEGIN IMMEDIATE` lease write per keystroke on the shared profile database.
///
/// Each test writes a sentinel lease value straight into the durable mirror after the core's own lease write
/// has committed, then drives another send: the sentinel surviving means the core skipped the write, the
/// sentinel being replaced means it performed one. That counts real database writes without instrumenting
/// product code.
final class GhosttyEmbeddedSessionLeaseCoalescingTests: XCTestCase {
    private static let sentinelLease = "1999-01-01T00:00:00Z"

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

    private func makeStartedCore(owner: TerminalClient) async throws -> CoreBox {
        try await TerminalEngineActor.run { () -> CoreBox in
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let paths = TerminalSessionPaths(rootDirectory: root.path)
            try paths.ensureDirectories()
            let launch = TerminalSessionLaunchConfiguration(
                sessionID: "lease-coalescing-\(UUID().uuidString)", backend: .ghosttyEmbedded, title: "shell",
                workingDirectory: FileManager.default.temporaryDirectory.path, shell: "/bin/sh", command: "cat", createdAt: "2026-07-21T00:00:00Z",
                workspaceID: "workspace-1", kind: .shell)
            let core = GhosttyEmbeddedSessionCore(launchConfiguration: launch, paths: paths)
            try core.startIfNeeded()
            try core.attachClient(owner, mode: .owner)
            return CoreBox(core: core, paths: paths, root: root)
        }
    }

    private func send(_ text: String, from clientID: String, on box: CoreBox) {
        let ok = TerminalEngineActor.runSynchronously { () -> Bool in
            box.core.handleControlRequest(.init(command: "send", text: "\(text)\n", clientID: clientID, appendNewline: false)).ok
        }
        XCTAssertTrue(ok, "owner send '\(text)' should be accepted")
        TerminalEngineActor.runSynchronously { box.core.debugDrainPersistenceQueue() }
    }

    private func heartbeat(from clientID: String, on box: CoreBox) {
        let ok = TerminalEngineActor.runSynchronously { () -> Bool in
            box.core.handleControlRequest(.init(command: "heartbeat", clientID: clientID)).ok
        }
        XCTAssertTrue(ok, "heartbeat from an attached client should be accepted")
        TerminalEngineActor.runSynchronously { box.core.debugDrainPersistenceQueue() }
    }

    private func writeSentinelLease(for clientID: String, on box: CoreBox) throws {
        XCTAssertTrue(
            try TerminalSessionPersistence.touchClient(id: clientID, paths: box.paths, touchedAt: Self.sentinelLease),
            "the sentinel must land on a still-attached client")
    }

    private func durableLease(for clientID: String, on box: CoreBox) throws -> String? {
        try TerminalSessionPersistence.readAttachmentSnapshot(paths: box.paths).clients.first { $0.id == clientID }?.leaseRefreshedAt
    }

    /// Successive keystrokes inside the coalescing window perform one lease write between them.
    func testRepeatedSendsWithinTheCoalescingWindowPerformOneLeaseWrite() async throws {
        let owner = TerminalClient(
            id: "owner-client", kind: .localWindow, identity: .init(label: "Spaces window"), connectedAt: "2026-07-21T00:00:00Z")
        let box = try await makeStartedCore(owner: owner)
        defer {
            TerminalEngineActor.runSynchronously { box.core.terminate() }
            try? FileManager.default.removeItem(at: box.root)
        }

        send("first", from: owner.id, on: box)
        XCTAssertNotEqual(try durableLease(for: owner.id, on: box), Self.sentinelLease)
        try writeSentinelLease(for: owner.id, on: box)

        for index in 0..<10 { send("burst-\(index)", from: owner.id, on: box) }

        XCTAssertEqual(
            try durableLease(for: owner.id, on: box), Self.sentinelLease,
            "sends inside the coalescing window must not each write the lease — the first send's write already covers them")
    }

    /// A re-attached client must not inherit the previous attachment's write record: the first lease touch of
    /// the new attachment writes, so the daemon's liveness readers see the new attachment's own lease rather
    /// than a touch skipped against a record from before the detach.
    func testReattachedClientWritesItsLeaseOnTheNextTouch() async throws {
        let client = TerminalClient(
            id: "viewer-client", kind: .remoteViewer, identity: .init(label: "iPhone", deviceName: "iPhone"), connectedAt: "2026-07-21T00:00:00Z")
        let box = try await makeStartedCore(owner: client)
        defer {
            TerminalEngineActor.runSynchronously { box.core.terminate() }
            try? FileManager.default.removeItem(at: box.root)
        }

        heartbeat(from: client.id, on: box)
        try writeSentinelLease(for: client.id, on: box)
        heartbeat(from: client.id, on: box)
        XCTAssertEqual(
            try durableLease(for: client.id, on: box), Self.sentinelLease, "a heartbeat inside the coalescing window must not write the lease again")

        try await TerminalEngineActor.run {
            try box.core.detach(clientID: client.id)
            try box.core.attachClient(client, mode: .owner)
        }
        try writeSentinelLease(for: client.id, on: box)
        heartbeat(from: client.id, on: box)

        XCTAssertNotEqual(
            try durableLease(for: client.id, on: box), Self.sentinelLease,
            "the first lease touch of a fresh attachment must write rather than resting on the previous attachment's write")
    }
}
