import Foundation
import XCTest

@testable import spacesterminalcore

final class TerminalSessionHostProtocolSupportTests: XCTestCase {
    func testAttachSnapshotAndReadOutputChunkUseExplicitSocketProtocolShape() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = TerminalSessionPaths(rootDirectory: root.path)
        try paths.ensureDirectories()
        let launchConfiguration = TerminalSessionLaunchConfiguration(
            sessionID: "session-1", backend: .scriptPTY, title: "session", workingDirectory: "/tmp/project", shell: "/bin/zsh", command: nil,
            createdAt: "2026-05-13T00:00:00Z")
        try TerminalSessionPersistence.writeLaunchConfiguration(launchConfiguration, paths: paths)
        try TerminalSessionPersistence.writeRuntimeState(
            TerminalSessionRuntimeState(
                sessionID: "session-1", backend: .scriptPTY, servicePID: 11, childPID: 22, state: .running, updatedAt: "2026-05-13T00:00:01Z"),
            paths: paths)
        FileManager.default.createFile(atPath: paths.outputPath, contents: Data("alpha\nbeta\n".utf8))

        let client = TerminalClient(
            id: "remote-1", kind: .remoteViewer, identity: TerminalClientIdentity(label: "iPhone"), connectedAt: "2026-05-13T00:00:00Z")

        let attachResponse = try TerminalSessionHostProtocolSupport.attach(
            request: TerminalControlRequest(command: "attach", client: client, attachmentMode: .viewer), sessionID: "session-1", paths: paths,
            attachedAt: { "2026-05-13T00:00:02Z" })
        XCTAssertTrue(attachResponse.ok)
        XCTAssertEqual(attachResponse.snapshot?.attachmentSnapshot?.clients, [client])

        let snapshotResponse = TerminalSessionHostProtocolSupport.snapshot(
            request: TerminalControlRequest(command: "snapshot", recentOutputLineCount: 20), paths: paths)
        XCTAssertTrue(snapshotResponse.ok)
        XCTAssertEqual(snapshotResponse.snapshot?.recentOutput, "alpha\nbeta")
        XCTAssertEqual(snapshotResponse.snapshot?.outputByteCount, 11)

        let chunkResponse = TerminalSessionHostProtocolSupport.readOutputChunk(
            request: TerminalControlRequest(command: "read_output_chunk", offset: 6, maximumBytes: 5), sessionID: "session-1", paths: paths)
        XCTAssertTrue(chunkResponse.ok)
        XCTAssertEqual(String(decoding: try XCTUnwrap(chunkResponse.outputChunk?.bytes), as: UTF8.self), "beta\n")
        XCTAssertEqual(chunkResponse.outputChunk?.lineIndex, 1)
        XCTAssertEqual(chunkResponse.outputByteCount, 11)
    }
}
