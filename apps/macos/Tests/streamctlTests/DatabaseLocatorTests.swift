import Foundation
import XCTest

@testable import streamctl

final class DatabaseLocatorTests: XCTestCase {
    private var tempHomeURL: URL!

    override func setUpWithError() throws {
        tempHomeURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempHomeURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempHomeURL, FileManager.default.fileExists(atPath: tempHomeURL.path) {
            try FileManager.default.removeItem(at: tempHomeURL)
        }
        tempHomeURL = nil
    }

    func testDefaultPathUsesSpaceshipDirectoryAndCreatesParent() throws {
        let path = try DatabaseLocator.defaultPath(homeDirectoryURL: tempHomeURL)
        let url = URL(fileURLWithPath: path)

        XCTAssertEqual(url.lastPathComponent, "spaceship.db")
        XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent, ".spaceship")
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
    }

    func testDefaultPathIsStableAcrossCalls() throws {
        let first = try DatabaseLocator.defaultPath(homeDirectoryURL: tempHomeURL)
        let second = try DatabaseLocator.defaultPath(homeDirectoryURL: tempHomeURL)
        XCTAssertEqual(first, second)
    }
}
