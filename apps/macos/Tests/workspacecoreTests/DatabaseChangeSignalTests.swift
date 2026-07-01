import Dispatch
import Foundation
import XCTest

@testable import workspacecore

#if os(Linux)
    private final class SignalExpectation: @unchecked Sendable {
        private let expectation: XCTestExpectation

        init(_ expectation: XCTestExpectation) { self.expectation = expectation }

        func fulfill() { expectation.fulfill() }
    }

    final class DatabaseChangeSignalTests: XCTestCase {
        func testLinuxReceiverDeliversCrossProcessDatabaseSignal() throws {
            let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).appendingPathComponent(
                "spaces-database-signal-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }

            let delivered = expectation(description: "database change signal delivered")
            let signalExpectation = SignalExpectation(delivered)
            let receiver = try DatabaseChangeSignalReceiver(
                socketPath: root.appendingPathComponent("database-change.sock", isDirectory: false).path,
                queue: DispatchQueue(label: "spaces.database-change-signal.test")
            ) { signalExpectation.fulfill() }
            try receiver.start()
            defer { receiver.stop() }

            try DatabaseChangeSignal.postLinuxSignal(socketPath: root.appendingPathComponent("database-change.sock", isDirectory: false).path)

            wait(for: [delivered], timeout: 2)
        }
    }
#endif
