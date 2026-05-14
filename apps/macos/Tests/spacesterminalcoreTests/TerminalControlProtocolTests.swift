import Dispatch
import Foundation
import XCTest

@testable import spacesterminalcore

final class TerminalControlProtocolTests: XCTestCase {
    func testRequestAndResponseRoundTripThroughCodec() throws {
        let request = TerminalControlRequest(command: "resize", clientID: "client-1", appendNewline: false, columns: 120, rows: 42)
        let response = TerminalControlResponse(ok: true, message: "ok")

        XCTAssertEqual(try TerminalControlCodec.decodeRequest(TerminalControlCodec.encodeRequest(request)), request)
        XCTAssertEqual(try TerminalControlCodec.decodeResponse(TerminalControlCodec.encodeResponse(response)), response)
    }

    func testRequestDecodeDefaultsMissingAppendNewlineToFalse() throws {
        let payload = #"{"command":"takeover","clientID":"remote-client"}"#.data(using: .utf8)!

        XCTAssertEqual(
            try TerminalControlCodec.decodeRequest(payload),
            TerminalControlRequest(command: "takeover", clientID: "remote-client", appendNewline: false))
    }

    func testRequestDecodePreservesAuthToken() throws {
        let payload = #"{"command":"snapshot","authToken":"SECRET"}"#.data(using: .utf8)!

        XCTAssertEqual(try TerminalControlCodec.decodeRequest(payload), TerminalControlRequest(command: "snapshot", authToken: "SECRET"))
    }

    func testAttachRequestAndSnapshotResponseRoundTripThroughCodec() throws {
        let client = TerminalClient(
            id: "client-1", kind: .remoteViewer, identity: TerminalClientIdentity(label: "iPhone", deviceName: "iPhone"),
            connectedAt: "2026-05-13T00:00:00Z")
        let request = TerminalControlRequest(command: "attach", client: client, attachmentMode: .viewer)
        let response = TerminalControlResponse(
            ok: true, message: "Attached.",
            snapshot: TerminalSessionHostSnapshot(
                launchConfiguration: TerminalSessionLaunchConfiguration(
                    sessionID: "session-1", title: "demo", workingDirectory: "/tmp/demo", shell: "/bin/zsh", command: nil,
                    createdAt: "2026-05-13T00:00:00Z"),
                runtimeState: TerminalSessionRuntimeState(
                    sessionID: "session-1", servicePID: 1, childPID: 2, state: .running, updatedAt: "2026-05-13T00:00:01Z"),
                attachmentSnapshot: TerminalSessionAttachmentSnapshot(clients: [client], attachments: []), recentOutput: "ready\n", outputByteCount: 6
            ))

        XCTAssertEqual(try TerminalControlCodec.decodeRequest(TerminalControlCodec.encodeRequest(request)), request)
        XCTAssertEqual(try TerminalControlCodec.decodeResponse(TerminalControlCodec.encodeResponse(response)), response)
    }

    func testClientCanSendRequestToSessionSocket() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let socketPath = root.appendingPathComponent("control.sock").path
        let queue = DispatchQueue(label: "terminal-control-protocol-test")
        let received = expectation(description: "received request")

        let server = TerminalControlServer(socketPath: socketPath, queue: queue) { request in
            XCTAssertEqual(request, TerminalControlRequest(command: "send", text: "payload", appendNewline: true))
            received.fulfill()
            return TerminalControlResponse(ok: true, message: "ack")
        }
        try server.start()
        defer { server.stop() }

        let response = try TerminalControlClient.send(
            request: TerminalControlRequest(command: "send", text: "payload", appendNewline: true), socketPath: socketPath)

        wait(for: [received], timeout: 2)
        XCTAssertEqual(response, TerminalControlResponse(ok: true, message: "ack"))
    }

    func testClientCanSendRequestToTCPServerWithAuthToken() throws {
        let queue = DispatchQueue(label: "terminal-control-protocol-test.tcp")
        let received = expectation(description: "received tcp request")

        let server = TerminalControlTCPServer(host: "127.0.0.1", port: 0, authToken: "SECRET", queue: queue) { request in
            XCTAssertEqual(request, TerminalControlRequest(command: "snapshot", authToken: "SECRET"))
            received.fulfill()
            return TerminalControlResponse(ok: true, message: "ack")
        }
        try server.start()
        defer { server.stop() }

        let response = try TerminalControlClient.send(
            request: TerminalControlRequest(command: "snapshot", authToken: "SECRET"), host: "127.0.0.1", port: server.listeningPort)

        wait(for: [received], timeout: 2)
        XCTAssertEqual(response, TerminalControlResponse(ok: true, message: "ack"))
    }
}
