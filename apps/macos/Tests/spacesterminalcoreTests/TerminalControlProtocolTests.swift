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
            command: "attach", authToken: "SECRET", text: "hello", bytes: Data([0, 10, 255]), clientID: "client-1", client: client,
            attachmentMode: .viewer, lineCount: 20, columns: 80, rows: 24, ownerEpoch: 7, resizeSerial: 3, scrollHorizontal: 1.5,
            scrollVertical: -2.5, scrollMods: 7, appendNewline: true, appearance: .light)
        let response = TerminalControlResponse(ok: true, message: "ok")

        let decoded = try TerminalControlCodec.decodeRequest(TerminalControlCodec.encodeRequest(request))
        XCTAssertEqual(decoded, request)
        // The attaching client's appearance must survive the wire so a remote daemon can pick the
        // matching theme variant.
        XCTAssertEqual(decoded.appearance, .light)
        XCTAssertEqual(try TerminalControlCodec.decodeResponse(TerminalControlCodec.encodeResponse(response)), response)
    }

    func testAttachRequestWithoutAppearanceDecodesToNil() throws {
        let payload = #"{"command":"attach","clientID":"remote-client"}"#.data(using: .utf8)!
        XCTAssertNil(try TerminalControlCodec.decodeRequest(payload).appearance)
    }

    func testRequestDecodeDefaultsMissingOptionalFields() throws {
        let payload = #"{"command":"takeover","clientID":"remote-client"}"#.data(using: .utf8)!

        XCTAssertEqual(
            try TerminalControlCodec.decodeRequest(payload),
            TerminalControlRequest(command: "takeover", clientID: "remote-client", appendNewline: false))
    }

    func testLegacyScrollRequestDecodesWithoutScrollMods() throws {
        let payload = #"{"command":"scroll","clientID":"remote-client","scrollHorizontal":1.5,"scrollVertical":-2.5}"#.data(using: .utf8)!
        let request = try TerminalControlCodec.decodeRequest(payload)

        XCTAssertEqual(request.scrollHorizontal, 1.5)
        XCTAssertEqual(request.scrollVertical, -2.5)
        XCTAssertNil(request.scrollMods)
    }

    func testTypedCommandWrapperPreservesWireShape() throws {
        let request = TerminalControlRequest(
            command: .resize(TerminalControlResizePayload(clientID: "client-1", columns: 100, rows: 30, ownerEpoch: 4, resizeSerial: 8)))

        let decoded = try TerminalControlCodec.decodeRequest(TerminalControlCodec.encodeRequest(request))

        XCTAssertEqual(decoded.command, "resize")
        XCTAssertEqual(decoded.commandValue.name, "resize")
        XCTAssertEqual(decoded.commandValue.requiresOwnerClientID, true)
        XCTAssertEqual(decoded.columns, 100)
        XCTAssertEqual(decoded.rows, 30)
        XCTAssertEqual(decoded.ownerEpoch, 4)
        XCTAssertEqual(decoded.resizeSerial, 8)
    }

    func testTypedCommandWrapperReportsMissingPayloadFields() throws {
        let send = try TerminalControlCodec.decodeRequest(#"{"command":"send","clientID":"client-1"}"#.data(using: .utf8)!)
        let attach = try TerminalControlCodec.decodeRequest(#"{"command":"attach","clientID":"legacy-extra"}"#.data(using: .utf8)!)
        let resize = try TerminalControlCodec.decodeRequest(#"{"command":"resize","clientID":"client-1","columns":100}"#.data(using: .utf8)!)

        XCTAssertEqual(send.commandValue.requiredPayloadFailureMessage, "Missing input payload.")
        XCTAssertEqual(attach.commandValue.requiredPayloadFailureMessage, "Missing client payload.")
        XCTAssertEqual(resize.commandValue.requiredPayloadFailureMessage, "Missing terminal size.")
        XCTAssertEqual(attach.clientID, "legacy-extra")
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
