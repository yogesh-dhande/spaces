import Dispatch
import Foundation
import XCTest

@testable import spacesterminalcore

final class TerminalServiceProtocolTests: XCTestCase {
    func testRequestAndResponseRoundTripThroughCodec() throws {
        let launchConfiguration = TerminalSessionLaunchConfiguration(
            sessionID: "session-1", backend: .ghosttyEmbedded, lifetimePolicy: .whileAttached, title: "shell", workingDirectory: "/tmp/work",
            shell: "/bin/zsh", command: "cat", createdAt: "2026-05-17T00:00:00Z")
        let request = TerminalServiceRequest(command: "create", launchConfiguration: launchConfiguration, sessionID: "session-1")
        let response = TerminalServiceResponse(
            ok: true, message: "Started.",
            session: TerminalServiceSessionSummary(
                id: "session-1", title: "shell", workingDirectory: "/tmp/work", backend: .ghosttyEmbedded, lifetimePolicy: .whileAttached,
                state: .running, servicePID: 123, childPID: 456, controlSocketPath: "/tmp/control.sock", outputPath: "/tmp/output.log"))

        XCTAssertEqual(try TerminalServiceCodec.decodeRequest(TerminalServiceCodec.encodeRequest(request)), request)
        XCTAssertEqual(try TerminalServiceCodec.decodeResponse(TerminalServiceCodec.encodeResponse(response)), response)
    }

    func testClientCanSendRequestToServiceSocket() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let socketPath = root.appendingPathComponent("service.sock").path
        let queue = DispatchQueue(label: "terminal-service-protocol-test")
        let received = expectation(description: "received request")

        let server = TerminalServiceServer(socketPath: socketPath, queue: queue) { request in
            XCTAssertEqual(request, TerminalServiceRequest(command: "ping"))
            received.fulfill()
            return TerminalServiceResponse(ok: true, message: "pong")
        }
        try server.start()
        defer { server.stop() }

        let response = try TerminalServiceClient.send(request: TerminalServiceRequest(command: "ping"), socketPath: socketPath)

        wait(for: [received], timeout: 2)
        XCTAssertEqual(response, TerminalServiceResponse(ok: true, message: "pong"))
    }
}
