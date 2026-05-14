import Foundation
import XCTest

@testable import spacesterminalcore

final class TerminalSessionClientTransportTests: XCTestCase {
    private final class OutputCapture: @unchecked Sendable { var value = "" }
    private final class RequestRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var commands: [String] = []

        func record(_ command: String) {
            lock.lock()
            commands.append(command)
            lock.unlock()
        }
    }

    func testLocalTransportLoadsSnapshotAndEmitsFileBackedEvents() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = TerminalSessionPaths(rootDirectory: root.path)
        try paths.ensureDirectories()
        FileManager.default.createFile(atPath: paths.outputPath, contents: Data())

        let launchConfiguration = TerminalSessionLaunchConfiguration(
            sessionID: "session-1", backend: .scriptPTY, title: "session", workingDirectory: "/tmp/project", shell: "/bin/zsh", command: "echo hello",
            createdAt: "2026-05-13T00:00:00Z")
        try TerminalSessionPersistence.writeLaunchConfiguration(launchConfiguration, paths: paths)
        try TerminalSessionPersistence.writeRuntimeState(
            TerminalSessionRuntimeState(
                sessionID: "session-1", backend: .scriptPTY, servicePID: 11, childPID: 22, state: .running, updatedAt: "2026-05-13T00:00:01Z"),
            paths: paths)

        let transport = TerminalSessionClientTransport.local(sessionID: "session-1", paths: paths)
        let initialSnapshot = try transport.loadSnapshot()
        XCTAssertEqual(initialSnapshot.launchConfiguration, launchConfiguration)
        XCTAssertEqual(initialSnapshot.runtimeState?.childPID, 22)
        XCTAssertEqual(initialSnapshot.recentOutput, "")
        XCTAssertEqual(initialSnapshot.outputByteCount, 0)

        let snapshotChanged = expectation(description: "snapshot changed")
        let outputChanged = expectation(description: "output changed")
        snapshotChanged.assertForOverFulfill = false
        outputChanged.assertForOverFulfill = false
        let outputCapture = OutputCapture()

        let observation = transport.observe { event in
            switch event {
            case .snapshotChanged: snapshotChanged.fulfill()
            case .outputChanged(_, let recentOutput):
                outputCapture.value = recentOutput
                outputChanged.fulfill()
            }
        }
        defer { observation.cancel() }

        let outputHandle = try FileHandle(forWritingTo: URL(fileURLWithPath: paths.outputPath))
        try outputHandle.seekToEnd()
        try outputHandle.write(contentsOf: Data("hello\n".utf8))
        try outputHandle.close()
        try TerminalSessionPersistence.writeRuntimeState(
            TerminalSessionRuntimeState(
                sessionID: "session-1", backend: .scriptPTY, servicePID: 11, childPID: 33, state: .running, updatedAt: "2026-05-13T00:00:02Z"),
            paths: paths)

        wait(for: [snapshotChanged, outputChanged], timeout: 2)

        let updatedSnapshot = try transport.loadSnapshot()
        XCTAssertEqual(updatedSnapshot.runtimeState?.childPID, 33)
        XCTAssertTrue(outputCapture.value.contains("hello"))
        XCTAssertTrue(updatedSnapshot.recentOutput.contains("hello"))
        XCTAssertEqual(updatedSnapshot.outputByteCount, 6)
    }

    func testLocalTransportReadsOutputChunksByOffset() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = TerminalSessionPaths(rootDirectory: root.path)
        try paths.ensureDirectories()
        FileManager.default.createFile(atPath: paths.outputPath, contents: Data("alpha\nbeta\ngamma\n".utf8))

        let transport = TerminalSessionClientTransport.local(sessionID: "session-2", paths: paths)

        XCTAssertEqual(try transport.currentOutputSize(), 17)

        let firstChunk = try XCTUnwrap(transport.readOutputChunk(0, 6))
        XCTAssertEqual(firstChunk.offset, 0)
        XCTAssertEqual(firstChunk.lineIndex, 0)
        XCTAssertEqual(String(decoding: firstChunk.bytes, as: UTF8.self), "alpha\n")

        let secondChunk = try XCTUnwrap(transport.readOutputChunk(6, 5))
        XCTAssertEqual(secondChunk.offset, 6)
        XCTAssertEqual(secondChunk.lineIndex, 1)
        XCTAssertEqual(String(decoding: secondChunk.bytes, as: UTF8.self), "beta\n")

        let tailChunk = try XCTUnwrap(transport.readOutputChunk(11, 6))
        XCTAssertEqual(tailChunk.offset, 11)
        XCTAssertEqual(tailChunk.lineIndex, 2)
        XCTAssertEqual(String(decoding: tailChunk.bytes, as: UTF8.self), "gamma\n")

        XCTAssertNil(try transport.readOutputChunk(17, 4))
    }

    func testHostBackedTransportUsesConnectionForHostProtocolRequests() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = TerminalSessionPaths(rootDirectory: root.path)
        try paths.ensureDirectories()
        FileManager.default.createFile(atPath: paths.outputPath, contents: Data("fallback\n".utf8))

        let recorder = RequestRecorder()
        let snapshot = TerminalSessionHostSnapshot(
            launchConfiguration: .init(
                sessionID: "session-remote", backend: .scriptPTY, title: "remote", workingDirectory: "/tmp/remote", shell: "/bin/zsh", command: "top",
                createdAt: "2026-05-14T00:00:00Z"),
            runtimeState: .init(
                sessionID: "session-remote", backend: .scriptPTY, servicePID: 99, childPID: 100, state: .running, updatedAt: "2026-05-14T00:00:01Z"),
            attachmentSnapshot: nil, recentOutput: "remote-output\n", outputByteCount: 42)

        let transport = TerminalSessionClientTransport.hostBacked(
            sessionID: "session-remote", paths: paths,
            hostConnection: .init(
                isAvailable: { true },
                send: { request in
                    recorder.record(request.command)
                    switch request.command {
                    case "snapshot": return TerminalControlResponse(ok: true, message: "snapshot", snapshot: snapshot)
                    case "output_size": return TerminalControlResponse(ok: true, message: "size", outputByteCount: 42)
                    case "read_output_chunk":
                        return TerminalControlResponse(
                            ok: true, message: "chunk",
                            outputChunk: TerminalOutputChunk(
                                sessionID: "session-remote", offset: 0, lineIndex: 0, bytes: Data("remote".utf8), createdAt: "2026-05-14T00:00:03Z"))
                    case "send", "key", "resize", "takeover", "terminate", "attach", "detach":
                        return TerminalControlResponse(ok: true, message: request.command)
                    default: return TerminalControlResponse(ok: false, message: "unsupported")
                    }
                }))

        XCTAssertEqual(try transport.loadSnapshot().recentOutput, "remote-output\n")
        XCTAssertEqual(try transport.currentOutputSize(), 42)
        let chunk = try XCTUnwrap(try transport.readOutputChunk(0, 16))
        XCTAssertEqual(String(decoding: chunk.bytes, as: UTF8.self), "remote")
        XCTAssertEqual(try transport.sendInput("hello", false, "owner").message, "send")
        XCTAssertEqual(try transport.sendKey("enter", "owner").message, "key")
        XCTAssertEqual(try transport.resize(80, 24, "owner").message, "resize")
        XCTAssertEqual(try transport.takeover("viewer").message, "takeover")
        XCTAssertEqual(try transport.terminate("owner").message, "terminate")
        try transport.attachClient(
            TerminalClient(id: "client-1", kind: .localWindow, identity: .init(label: "label"), connectedAt: "2026-05-14T00:00:02Z"), .viewer)
        try transport.detachClient("client-1")

        XCTAssertEqual(
            recorder.commands, ["snapshot", "output_size", "read_output_chunk", "send", "key", "resize", "takeover", "terminate", "attach", "detach"])
    }
}
