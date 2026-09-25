import Foundation
import XCTest
import spacestestsupport

@testable import workspacecore

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

    func testDefaultPathUsesSpacesDirectoryAndCreatesParent() throws {
        let path = try DatabaseLocator.defaultPath(homeDirectoryURL: tempHomeURL)
        let url = URL(fileURLWithPath: path)

        XCTAssertEqual(url.lastPathComponent, "spaces.db")
        XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent, ".spaces")
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
    }

    func testDefaultPathIsStableAcrossCalls() throws {
        let first = try DatabaseLocator.defaultPath(homeDirectoryURL: tempHomeURL)
        let second = try DatabaseLocator.defaultPath(homeDirectoryURL: tempHomeURL)
        XCTAssertEqual(first, second)
    }

    // `HOME` is redirected along with the cleared override because resolution refuses the installed
    // profile under a test host; a redirected home is the isolated profile this exercises.
    func testPublicDefaultPathReturnsValidPath() throws {
        let path = try withEnvironmentValues([DatabaseLocator.databasePathEnvironmentVariable: nil, "HOME": tempHomeURL.path]) {
            try DatabaseLocator.defaultPath()
        }
        XCTAssertEqual(path, tempHomeURL.appendingPathComponent(".spaces/spaces.db").path)
    }

    func testPublicDefaultPathHonorsEnvironmentOverride() throws {
        let overrideURL = tempHomeURL.appendingPathComponent("isolated/state/spaces-test.db")
        let previous = getenv(DatabaseLocator.databasePathEnvironmentVariable).map { String(cString: $0) }
        setenv(DatabaseLocator.databasePathEnvironmentVariable, overrideURL.path, 1)
        defer {
            if let previous {
                setenv(DatabaseLocator.databasePathEnvironmentVariable, previous, 1)
            } else {
                unsetenv(DatabaseLocator.databasePathEnvironmentVariable)
            }
        }

        let path = try DatabaseLocator.defaultPath()

        XCTAssertEqual(path, overrideURL.path)
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: overrideURL.deletingLastPathComponent().path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
    }
}
