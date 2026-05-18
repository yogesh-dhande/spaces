import Foundation
import XCTest
import spacesterminalcore

@testable import spacesterminalghostty

final class RemoteGhosttySessionHostTests: XCTestCase {
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
}
