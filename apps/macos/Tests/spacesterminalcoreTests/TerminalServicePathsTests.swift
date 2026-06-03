import Foundation
import XCTest

@testable import spacesterminalcore

final class TerminalServicePathsTests: XCTestCase {
    func testSocketPathUsesShortHashedTmpLocationForLongDatabaseRoots() throws {
        let tempRoot = URL(fileURLWithPath: "/tmp", isDirectory: true).appendingPathComponent(
            String(repeating: "nested-", count: 18), isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        let databasePath = tempRoot.appendingPathComponent("spaces.db").path
        let originalOverride = ProcessInfo.processInfo.environment["SPACES_DB_PATH"]
        setenv("SPACES_DB_PATH", databasePath, 1)
        defer {
            if let originalOverride { setenv("SPACES_DB_PATH", originalOverride, 1) } else { unsetenv("SPACES_DB_PATH") }
            try? FileManager.default.removeItem(at: tempRoot)
        }

        let socketPath = try TerminalServicePaths.socketPath()

        XCTAssertTrue(socketPath.hasPrefix("/tmp/spaces-terminal-sockets/service-"))
        XCTAssertLessThan(socketPath.utf8.count, 104)
    }
}
