import Dispatch
import Foundation
import XCTest

@testable import spacesterminalcore

final class TerminalControlProtocolTests: XCTestCase {
    func testRequestAndResponseRoundTripThroughCodec() throws {
        let client = TerminalClient(
            id: "client-1", kind: .remoteViewer, identity: TerminalClientIdentity(label: "iPhone", deviceName: "iPhone"),
            connectedAt: "2026-05-15T00:00:00Z")
        let request = TerminalControlRequest(
            command: "attach", authToken: "SECRET", text: "hello", clientID: "client-1", client: client, attachmentMode: .viewer, lineCount: 20,
            appendNewline: true)
        let response = TerminalControlResponse(ok: true, message: "ok")

        XCTAssertEqual(try TerminalControlCodec.decodeRequest(TerminalControlCodec.encodeRequest(request)), request)
        XCTAssertEqual(try TerminalControlCodec.decodeResponse(TerminalControlCodec.encodeResponse(response)), response)
    }

    func testRequestDecodeDefaultsMissingOptionalFields() throws {
        let payload = #"{"command":"takeover","clientID":"remote-client"}"#.data(using: .utf8)!

        XCTAssertEqual(
            try TerminalControlCodec.decodeRequest(payload),
            TerminalControlRequest(command: "takeover", clientID: "remote-client", appendNewline: false))
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
            XCTAssertEqual(request, TerminalControlRequest(command: "tail", authToken: "SECRET", lineCount: 10))
            received.fulfill()
            return TerminalControlResponse(ok: true, message: "ack")
        }
        try server.start()
        defer { server.stop() }

        let response = try TerminalControlClient.send(
            request: TerminalControlRequest(command: "tail", authToken: "SECRET", lineCount: 10), host: "127.0.0.1", port: server.listeningPort)

        wait(for: [received], timeout: 2)
        XCTAssertEqual(response, TerminalControlResponse(ok: true, message: "ack"))
    }

    func testTCPServerRejectsUnauthorizedClients() throws {
        let queue = DispatchQueue(label: "terminal-control-protocol-test.tcp.auth")
        let server = TerminalControlTCPServer(host: "127.0.0.1", port: 0, authToken: "SECRET", queue: queue) { _ in
            XCTFail("handler should not run for unauthorized client")
            return TerminalControlResponse(ok: true, message: "unexpected")
        }
        try server.start()
        defer { server.stop() }

        let response = try TerminalControlClient.send(
            request: TerminalControlRequest(command: "tail", authToken: "WRONG", lineCount: 5), host: "127.0.0.1", port: server.listeningPort)

        XCTAssertEqual(response.ok, false)
        XCTAssertEqual(response.message, "Unauthorized terminal client.")
    }
}
