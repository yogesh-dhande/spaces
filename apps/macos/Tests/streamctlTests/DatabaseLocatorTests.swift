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
        if let tempHomeURL, FileManager.default.fileExists(atPath: tempHomeURL.path) { try FileManager.default.removeItem(at: tempHomeURL) }
        tempHomeURL = nil
    }

    // Tests default path uses muxy directory and creates parent by arranging representative inputs and asserting the expected result.
    func testDefaultPathUsesMuxyDirectoryAndCreatesParent() throws {
        let path = try DatabaseLocator.defaultPath(homeDirectoryURL: tempHomeURL)
        let url = URL(fileURLWithPath: path)

        XCTAssertEqual(url.lastPathComponent, "muxy.db")
        XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent, ".muxy")
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
    }

    // Tests default path is stable across calls by arranging representative inputs and asserting the expected result.
    func testDefaultPathIsStableAcrossCalls() throws {
        let first = try DatabaseLocator.defaultPath(homeDirectoryURL: tempHomeURL)
        let second = try DatabaseLocator.defaultPath(homeDirectoryURL: tempHomeURL)
        XCTAssertEqual(first, second)
    }

    // Tests the public defaultPath() overload succeeds and returns a path ending in muxy.db.
    func testPublicDefaultPathReturnsValidPath() throws {
        let path = try DatabaseLocator.defaultPath()
        XCTAssertTrue(path.hasSuffix("muxy.db"), "Expected path to end with muxy.db, got \(path)")
    }
}
