import Foundation
import XCTest

@testable import streamctl

final class DatabaseLocatorTests: XCTestCase {
    func testDefaultPathUsesAgentmuxDirectoryAndCreatesParent() throws {
        let path = try DatabaseLocator.defaultPath()
        let url = URL(fileURLWithPath: path)

        XCTAssertEqual(url.lastPathComponent, "agentmux.db")
        XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent, ".agentmux")
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
    }

    func testDefaultPathIsStableAcrossCalls() throws {
        let first = try DatabaseLocator.defaultPath()
        let second = try DatabaseLocator.defaultPath()
        XCTAssertEqual(first, second)
    }
}
