import Foundation
import XCTest
import spacesterminalcore

@testable import spacesterminalghostty

final class RemoteGhosttySessionHostTests: XCTestCase {
    @MainActor func testRemoteHostPrefersLiveSnapshotStreamWhenAvailable() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = TerminalSessionPaths(rootDirectory: root.path)
        try paths.ensureDirectories()
        let queue = DispatchQueue(label: "spaces.remote-host.stream-test")
        let initialPayload = GhosttyRemoteSessionStatePayload(
            sessionID: "remote-live", reason: "initial", emittedAt: "2026-05-18T00:00:00Z",
            runtimeState: TerminalSessionRuntimeState(
                sessionID: "remote-live", backend: .ghosttyEmbedded, servicePID: 1, childPID: 2, state: .running, updatedAt: "2026-05-18T00:00:00Z",
                title: "live", workingDirectory: "/tmp/live", columns: 5, rows: 1), attachmentSnapshot: TerminalSessionAttachmentSnapshot(),
            title: "live", workingDirectory: "/tmp/live", snapshot: snapshot(text: "alpha"), snapshotText: "alpha", outputByteCount: nil)
        let server = GhosttyRemoteSessionStateStreamServer(socketPath: paths.subscriptionSocketPath, queue: queue) { initialPayload }
        try server.start()
        defer { server.stop() }

        let host = RemoteGhosttySessionHost(
            launchConfiguration: .init(
                sessionID: "remote-live", title: "remote", workingDirectory: "/tmp/work", shell: "/bin/zsh", command: "cat",
                createdAt: "2026-05-18T00:00:00Z"), paths: paths)

        waitForCondition("initial live snapshot") { host.snapshotText() == "alpha" }
        XCTAssertEqual(host.effectiveTitle, "live")
        XCTAssertEqual(host.effectiveWorkingDirectory, "/tmp/live")

        server.broadcast(
            GhosttyRemoteSessionStatePayload(
                sessionID: "remote-live", reason: "output", emittedAt: "2026-05-18T00:00:01Z",
                runtimeState: TerminalSessionRuntimeState(
                    sessionID: "remote-live", backend: .ghosttyEmbedded, servicePID: 1, childPID: 2, state: .running,
                    updatedAt: "2026-05-18T00:00:01Z", title: "live", workingDirectory: "/tmp/live", columns: 4, rows: 2),
                attachmentSnapshot: TerminalSessionAttachmentSnapshot(), title: "live", workingDirectory: "/tmp/live",
                snapshot: snapshot(text: "beta\ngamm"), snapshotText: "beta\ngamm", outputByteCount: 9))

        waitForCondition("updated live snapshot") { host.snapshotText() == "beta\ngamm" }
        XCTAssertEqual(host.snapshot()?.rows, 2)
    }

    @MainActor func testRemoteHostBuildsSnapshotAndPlainTextFromOutputLog() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = TerminalSessionPaths(rootDirectory: root.path)
        try paths.ensureDirectories()
        try TerminalSessionPersistence.writeRuntimeState(
            TerminalSessionRuntimeState(
                sessionID: "remote-render", backend: .ghosttyEmbedded, servicePID: 1, childPID: 2, state: .running, updatedAt: "2026-05-17T00:00:00Z",
                columns: 4, rows: 2), paths: paths)
        let transcript = "\u{001B}[31mAB\u{001B}[0mCD\u{001B}[2;1HEF"
        try transcript.write(toFile: paths.outputPath, atomically: true, encoding: .utf8)

        let host = RemoteGhosttySessionHost(
            launchConfiguration: .init(
                sessionID: "remote-render", title: "remote", workingDirectory: "/tmp/work", shell: "/bin/zsh", command: "cat",
                createdAt: "2026-05-17T00:00:00Z"), paths: paths)

        let snapshot = try XCTUnwrap(host.snapshot())
        let renderedText = try XCTUnwrap(host.snapshotText())

        XCTAssertEqual(snapshot.columns, 4)
        XCTAssertEqual(snapshot.rows, 2)
        XCTAssertEqual(snapshot.cells.count, 8)
        XCTAssertEqual(snapshot.cells[0].codepoint, UnicodeScalar("A").value)
        XCTAssertNotEqual(snapshot.cells[0].foregroundRGB, snapshot.defaultForegroundRGB)
        XCTAssertTrue(renderedText.contains("ABCD"))
        XCTAssertTrue(renderedText.contains("EF"))
    }

    @MainActor func testRemoteHostResetsReplayStateWhenOutputLogIsTruncated() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = TerminalSessionPaths(rootDirectory: root.path)
        try paths.ensureDirectories()
        try TerminalSessionPersistence.writeRuntimeState(
            TerminalSessionRuntimeState(
                sessionID: "remote-truncate", backend: .ghosttyEmbedded, servicePID: 1, childPID: 2, state: .running,
                updatedAt: "2026-05-17T00:00:00Z", columns: 8, rows: 2), paths: paths)
        try "hello world".write(toFile: paths.outputPath, atomically: true, encoding: .utf8)

        let host = RemoteGhosttySessionHost(
            launchConfiguration: .init(
                sessionID: "remote-truncate", title: "remote", workingDirectory: "/tmp/work", shell: "/bin/zsh", command: "cat",
                createdAt: "2026-05-17T00:00:00Z"), paths: paths)

        XCTAssertTrue((host.snapshotText() ?? "").contains("hello"))

        try "reset".write(toFile: paths.outputPath, atomically: true, encoding: .utf8)

        let updatedText = host.snapshotText() ?? ""
        XCTAssertTrue(updatedText.contains("reset"))
        XCTAssertFalse(updatedText.contains("hello"))
    }

    @MainActor private func waitForCondition(_ label: String, timeout: TimeInterval = 2, condition: @escaping () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        XCTFail("Timed out waiting for \(label)")
    }

    private func snapshot(text: String) -> GhosttyTerminalSnapshot {
        let rows = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let columns = rows.map(\.count).max() ?? 0
        let paddedRows = rows.map { row in row.padding(toLength: columns, withPad: " ", startingAt: 0) }
        let cells = paddedRows.flatMap { row in
            row.unicodeScalars.map { scalar in
                GhosttyTerminalSnapshot.Cell(codepoint: scalar.value, foregroundRGB: 0xFFFFFF, backgroundRGB: 0x000000, flags: 0)
            }
        }
        return GhosttyTerminalSnapshot(
            columns: columns, rows: paddedRows.count, cursorColumn: 0, cursorRow: 0, cursorVisible: false, defaultForegroundRGB: 0xFFFFFF,
            defaultBackgroundRGB: 0x000000, cells: cells)
    }
}
