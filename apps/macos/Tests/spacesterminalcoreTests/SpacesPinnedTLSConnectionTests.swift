import Dispatch
import Foundation
import XCTest

@testable import spacesterminalcore

/// Exercises the shared pinned-TLS client connection against the pinned-cert TLS server on the
/// same wire contract every daemon exposes: TLS with a pinned self-signed identity and
/// newline-framed JSON. The Darwin backend runs here; the OpenSSL backend speaks the identical
/// wire format and is exercised by the Linux artifact smoke and the remote-daemon e2e.
#if canImport(Network) && canImport(Security)
    final class SpacesPinnedTLSConnectionTests: XCTestCase {
        private func makeServer(
            identityRoot: URL, handleRequest: @escaping @Sendable (TerminalServiceRequest) throws -> TerminalServiceResponse
        ) throws -> TerminalServiceTLSServer {
            let identity = try TerminalServiceTLSIdentityStore.loadOrCreate(root: identityRoot)
            let server = TerminalServiceTLSServer(
                host: "127.0.0.1", port: 0, authToken: nil, identity: identity, queue: DispatchQueue(label: "pinned-tls-connection-test-server"),
                handleRequest: handleRequest)
            try server.start()
            return server
        }

        private func temporaryRoot() throws -> URL {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            addTeardownBlock { try? FileManager.default.removeItem(at: root) }
            return root
        }

        func testSendsAndReadsMultipleLinesOverOneConnection() throws {
            let root = try temporaryRoot()
            let counter = LockedCounter()
            let server = try makeServer(identityRoot: root) { request in
                TerminalServiceResponse(ok: true, message: "\(request.commandName)-\(counter.increment())")
            }
            defer { server.stop() }

            let connection = try SpacesPinnedTLSConnector.connect(
                host: "127.0.0.1", port: server.listeningPort, certificateFingerprint: server.certificateFingerprint)
            defer { connection.cancel() }

            for expectedMessage in ["ping-1", "ping-2", "ping-3"] {
                try connection.sendLine(TerminalServiceCodec.encodeRequest(TerminalServiceRequest(command: .ping)), timeout: 5)
                let response = try TerminalServiceCodec.decodeResponse(connection.readLine(timeout: 5))
                XCTAssertEqual(response, TerminalServiceResponse(ok: true, message: expectedMessage))
            }
        }

        func testRejectsCertificatePinMismatch() throws {
            let root = try temporaryRoot()
            let server = try makeServer(identityRoot: root) { _ in TerminalServiceResponse(ok: true, message: "pong") }
            defer { server.stop() }

            let wrongFingerprint = "SHA256:" + String(repeating: "ab", count: 32)
            XCTAssertThrowsError(
                try SpacesPinnedTLSConnector.connect(
                    host: "127.0.0.1", port: server.listeningPort, certificateFingerprint: wrongFingerprint)
            ) { error in
                guard case TerminalServiceTLSError.certificatePinMismatch(let expected, let actual) = error else {
                    return XCTFail("Expected certificatePinMismatch, got \(error)")
                }
                XCTAssertEqual(expected, wrongFingerprint)
                XCTAssertEqual(TerminalServiceTLSFingerprint.normalized(actual), TerminalServiceTLSFingerprint.normalized(server.certificateFingerprint))
            }
        }

        func testRejectsMissingFingerprint() {
            XCTAssertThrowsError(try SpacesPinnedTLSConnector.connect(host: "127.0.0.1", port: 47_999, certificateFingerprint: "  ")) { error in
                guard case TerminalServiceTLSError.missingCertificateFingerprint = error else {
                    return XCTFail("Expected missingCertificateFingerprint, got \(error)")
                }
            }
        }

        func testTransfersLineLargerThanReceiveChunk() throws {
            let root = try temporaryRoot()
            let largeMessage = String(repeating: "x", count: 2_000_000)
            let server = try makeServer(identityRoot: root) { _ in TerminalServiceResponse(ok: true, message: largeMessage) }
            defer { server.stop() }

            let connection = try SpacesPinnedTLSConnector.connect(
                host: "127.0.0.1", port: server.listeningPort, certificateFingerprint: server.certificateFingerprint)
            defer { connection.cancel() }

            try connection.sendLine(TerminalServiceCodec.encodeRequest(TerminalServiceRequest(command: .ping)), timeout: 10)
            let response = try TerminalServiceCodec.decodeResponse(connection.readLine(timeout: 10))
            XCTAssertEqual(response.message, largeMessage)
        }

        func testReceiveLoopDeliversLinesAndClosesCleanlyOnCancel() throws {
            let root = try temporaryRoot()
            let server = try makeServer(identityRoot: root) { request in TerminalServiceResponse(ok: true, message: request.commandName) }
            defer { server.stop() }

            let connection = try SpacesPinnedTLSConnector.connect(
                host: "127.0.0.1", port: server.listeningPort, certificateFingerprint: server.certificateFingerprint)

            let receivedLines = expectation(description: "received three streamed lines")
            receivedLines.expectedFulfillmentCount = 3
            let closed = expectation(description: "receive loop closed")
            let lineBox = LockedLineCollector()
            connection.startReceiveLoop(
                onLine: { line in
                    lineBox.append(line)
                    receivedLines.fulfill()
                },
                onClosed: { error in
                    XCTAssertNil(error)
                    closed.fulfill()
                })

            for _ in 0..<3 { try connection.sendLine(TerminalServiceCodec.encodeRequest(TerminalServiceRequest(command: .ping)), timeout: 5) }
            wait(for: [receivedLines], timeout: 10)
            connection.cancel()
            wait(for: [closed], timeout: 5)

            let responses = try lineBox.lines().map { try TerminalServiceCodec.decodeResponse($0) }
            XCTAssertEqual(responses, Array(repeating: TerminalServiceResponse(ok: true, message: "ping"), count: 3))
        }

        func testReadLineTimesOutWithoutData() throws {
            let root = try temporaryRoot()
            let server = try makeServer(identityRoot: root) { _ in TerminalServiceResponse(ok: true, message: "pong") }
            defer { server.stop() }

            let connection = try SpacesPinnedTLSConnector.connect(
                host: "127.0.0.1", port: server.listeningPort, certificateFingerprint: server.certificateFingerprint)
            defer { connection.cancel() }

            XCTAssertThrowsError(try connection.readLine(timeout: 0.5)) { error in
                guard case SpacesPinnedTLSConnectionError.timeout = error else { return XCTFail("Expected timeout, got \(error)") }
            }
        }
    }

    private final class LockedCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        func increment() -> Int {
            lock.lock()
            defer { lock.unlock() }
            count += 1
            return count
        }
    }

    private final class LockedLineCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var storedLines: [Data] = []

        func append(_ line: Data) {
            lock.lock()
            storedLines.append(line)
            lock.unlock()
        }

        func lines() -> [Data] {
            lock.lock()
            defer { lock.unlock() }
            return storedLines
        }
    }
#endif
