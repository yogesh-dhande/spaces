import Dispatch
import Foundation
import XCTest

@testable import spacesterminalcore

final class TerminalServiceProtocolTests: XCTestCase {
    func testRequestAndResponseRoundTripThroughCodec() throws {
        let launchConfiguration = TerminalSessionLaunchConfiguration(
            sessionID: "session-1", backend: .ghosttyEmbedded, lifetimePolicy: .whileAttached, title: "shell", workingDirectory: "/tmp/work",
            shell: "/bin/zsh", command: "cat", createdAt: "2026-05-17T00:00:00Z")
        let manifest = TerminalServiceWorkspaceRuntimeManifest(
            workspaceID: "workspace-1", projectID: "project-1", computeHostID: "host-1", location: .remote, localPath: "/local/work",
            remotePath: "/srv/work", branch: "feature", targetBranch: "main", gitRemoteURL: "git@example.com:repo.git",
            namedPorts: [TerminalServiceWorkspaceRuntimePortMapping(id: "api", name: "API_PORT", port: 3000)],
            processEnvironment: ["SPACES_WORKSPACE_ID": "workspace-1"], allowedFileRoots: ["/srv/work"])
        let request = TerminalServiceRequest(
            command: "create", authToken: "SECRET", launchConfiguration: launchConfiguration, sessionID: "session-1", runtimeManifest: manifest,
            worktreeRefresh: TerminalServiceWorktreeRefreshRequest(path: "/srv/work", branch: "feature", hostName: "Builder"),
            workspaceCommand: TerminalServiceWorkspaceCommandRequest(command: "true", workingDirectory: "/srv/work"))
        let response = TerminalServiceResponse(
            ok: true, message: "Started.",
            session: TerminalServiceSessionSummary(
                id: "session-1", title: "shell", workingDirectory: "/tmp/work", backend: .ghosttyEmbedded, lifetimePolicy: .whileAttached,
                state: .running, servicePID: 123, childPID: 456, controlSocketPath: "/tmp/control.sock", outputPath: "/tmp/output.log"),
            commandResult: TerminalServiceCommandResult(exitCode: 0, logPath: "/tmp/setup.log"))

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

    func testClientCanSendRequestToRemoteServiceSocket() throws {
        let queue = DispatchQueue(label: "terminal-service-tcp-protocol-test")
        let received = expectation(description: "received request")
        let server = TerminalServiceTCPServer(host: "127.0.0.1", port: 0, authToken: "SECRET", queue: queue) { request in
            XCTAssertEqual(request, TerminalServiceRequest(command: "ping", authToken: "SECRET"))
            received.fulfill()
            return TerminalServiceResponse(ok: true, message: "pong")
        }
        try server.start()
        defer { server.stop() }

        let response = try TerminalServiceClient.send(
            request: TerminalServiceRequest(command: "ping"), host: "127.0.0.1", port: server.listeningPort, authToken: "SECRET")

        wait(for: [received], timeout: 2)
        XCTAssertEqual(response, TerminalServiceResponse(ok: true, message: "pong"))
    }

    func testRemoteServiceSocketRejectsInvalidAuthToken() throws {
        let queue = DispatchQueue(label: "terminal-service-tcp-auth-test")
        let server = TerminalServiceTCPServer(host: "127.0.0.1", port: 0, authToken: "SECRET", queue: queue) { _ in
            XCTFail("Unauthorized requests should not reach handler")
            return TerminalServiceResponse(ok: true, message: "unexpected")
        }
        try server.start()
        defer { server.stop() }

        let response = try TerminalServiceClient.send(
            request: TerminalServiceRequest(command: "ping"), host: "127.0.0.1", port: server.listeningPort, authToken: "WRONG")

        XCTAssertEqual(response, TerminalServiceResponse(ok: false, message: "Unauthorized spacesd client."))
    }

    func testPinnedTLSClientCanSendRequestToRemoteService() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let identity = try TerminalServiceTLSIdentityStore.loadOrCreate(root: root)
        let queue = DispatchQueue(label: "terminal-service-tls-protocol-test")
        let received = expectation(description: "received pinned TLS request")
        let server = TerminalServiceTLSServer(host: "127.0.0.1", port: 0, authToken: "SECRET", identity: identity, queue: queue) { request in
            XCTAssertEqual(request, TerminalServiceRequest(command: "ping", authToken: "SECRET"))
            received.fulfill()
            return TerminalServiceResponse(ok: true, message: "pong")
        }
        try server.start()
        defer { server.stop() }

        let response = try TerminalServiceClient.sendPinnedTLS(
            request: TerminalServiceRequest(command: "ping"), host: "127.0.0.1", port: server.listeningPort, authToken: "SECRET",
            certificateFingerprint: identity.certificateFingerprint)

        wait(for: [received], timeout: 5)
        XCTAssertEqual(response, TerminalServiceResponse(ok: true, message: "pong"))
    }

    func testPinnedTLSClientRejectsCertificateMismatch() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let identity = try TerminalServiceTLSIdentityStore.loadOrCreate(root: root)
        let queue = DispatchQueue(label: "terminal-service-tls-pin-test")
        let server = TerminalServiceTLSServer(host: "127.0.0.1", port: 0, authToken: "SECRET", identity: identity, queue: queue) { _ in
            XCTFail("A mismatched certificate pin should not reach the handler.")
            return TerminalServiceResponse(ok: true, message: "unexpected")
        }
        try server.start()
        defer { server.stop() }

        XCTAssertThrowsError(
            try TerminalServiceClient.sendPinnedTLS(
                request: TerminalServiceRequest(command: "ping"), host: "127.0.0.1", port: server.listeningPort, authToken: "SECRET",
                certificateFingerprint: "SHA256:0000000000000000000000000000000000000000000000000000000000000000")
        ) { error in
            guard case TerminalServiceTLSError.certificatePinMismatch = error else {
                XCTFail("Expected certificate pin mismatch, got \(error)")
                return
            }
        }
    }
}
