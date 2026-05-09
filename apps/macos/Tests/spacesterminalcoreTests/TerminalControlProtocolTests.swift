import Dispatch
import Foundation
import XCTest

@testable import spacesterminalcore

final class TerminalControlProtocolTests: XCTestCase {
    func testRequestAndResponseRoundTripThroughCodec() throws {
        let request = TerminalControlRequest(command: "send", text: "hello", appendNewline: true)
        let response = TerminalControlResponse(ok: true, message: "ok")

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
}
