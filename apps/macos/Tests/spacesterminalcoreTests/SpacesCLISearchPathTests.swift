import Foundation
import XCTest
import spacesterminalcore

final class SpacesCLISearchPathTests: XCTestCase {
    private var binDirectory: URL!

    override func setUpWithError() throws {
        binDirectory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(
            "spaces-cli-search-path-tests-\(UUID().uuidString)/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: binDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: binDirectory.deletingLastPathComponent()) }

    private func installExecutable(named name: String) throws -> String {
        let path = binDirectory.appendingPathComponent(name).path
        FileManager.default.createFile(atPath: path, contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o755])
        return path
    }

    func testPrependsSiblingCLIDirectory() throws {
        let daemonPath = try installExecutable(named: "spacesd-bin")
        _ = try installExecutable(named: "spaces")
        let path = SpacesCLISearchPath.pathPrependingSiblingCLIDirectory(executablePath: daemonPath, currentPATH: "/usr/local/bin:/usr/bin:/bin")
        XCTAssertEqual(path, "\(binDirectory.path):/usr/local/bin:/usr/bin:/bin")
    }

    /// The daemon passes its unresolved launch path, so the directory that leads PATH is the stable
    /// `current/bin` one and survives the versioned release it points at being deleted.
    func testStableSymlinkDirectoryLeadsPATHInsteadOfTheVersionedRelease() throws {
        let root = binDirectory.deletingLastPathComponent()
        let releaseBin = root.appendingPathComponent("releases/1.0.0/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: releaseBin, withIntermediateDirectories: true)
        for name in ["spacesd", "spaces"] {
            FileManager.default.createFile(
                atPath: releaseBin.appendingPathComponent(name).path, contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o755])
        }
        let current = root.appendingPathComponent("current", isDirectory: false)
        try FileManager.default.createSymbolicLink(atPath: current.path, withDestinationPath: "releases/1.0.0")
        let stableBin = current.appendingPathComponent("bin", isDirectory: true).path

        let path = SpacesCLISearchPath.pathPrependingSiblingCLIDirectory(
            executablePath: "\(stableBin)/spacesd", currentPATH: "/usr/bin:/bin")

        XCTAssertEqual(path, "\(stableBin):/usr/bin:/bin")
        XCTAssertFalse(path?.contains("releases") ?? true)
    }

    func testReturnsNilWithoutSiblingCLI() throws {
        let daemonPath = try installExecutable(named: "spacesd-bin")
        XCTAssertNil(SpacesCLISearchPath.pathPrependingSiblingCLIDirectory(executablePath: daemonPath, currentPATH: "/usr/bin:/bin"))
    }

    func testReturnsNilWhenCLIFileIsNotExecutable() throws {
        let daemonPath = try installExecutable(named: "spacesd-bin")
        let cliPath = binDirectory.appendingPathComponent("spaces").path
        FileManager.default.createFile(atPath: cliPath, contents: Data(), attributes: [.posixPermissions: 0o644])
        XCTAssertNil(SpacesCLISearchPath.pathPrependingSiblingCLIDirectory(executablePath: daemonPath, currentPATH: "/usr/bin:/bin"))
    }

    func testReturnsNilWhenDirectoryAlreadyLeadsPATH() throws {
        let daemonPath = try installExecutable(named: "spacesd-bin")
        _ = try installExecutable(named: "spaces")
        XCTAssertNil(
            SpacesCLISearchPath.pathPrependingSiblingCLIDirectory(executablePath: daemonPath, currentPATH: "\(binDirectory.path):/usr/bin:/bin"))
    }

    func testMovesExistingLaterEntryToFront() throws {
        let daemonPath = try installExecutable(named: "spacesd-bin")
        _ = try installExecutable(named: "spaces")
        let path = SpacesCLISearchPath.pathPrependingSiblingCLIDirectory(
            executablePath: daemonPath, currentPATH: "/usr/bin:\(binDirectory.path):/bin")
        XCTAssertEqual(path, "\(binDirectory.path):/usr/bin:/bin")
    }

    func testPreservesEmptyPATHComponentsWhenMovingExistingLaterEntryToFront() throws {
        let daemonPath = try installExecutable(named: "spacesd-bin")
        _ = try installExecutable(named: "spaces")
        let path = SpacesCLISearchPath.pathPrependingSiblingCLIDirectory(
            executablePath: daemonPath, currentPATH: ":/usr/bin::\(binDirectory.path):/bin:")
        XCTAssertEqual(path, "\(binDirectory.path)::/usr/bin::/bin:")
    }

    func testEmptyPATHYieldsCLIDirectoryOnly() throws {
        let daemonPath = try installExecutable(named: "spacesd-bin")
        _ = try installExecutable(named: "spaces")
        XCTAssertEqual(SpacesCLISearchPath.pathPrependingSiblingCLIDirectory(executablePath: daemonPath, currentPATH: nil), binDirectory.path)
        XCTAssertEqual(SpacesCLISearchPath.pathPrependingSiblingCLIDirectory(executablePath: daemonPath, currentPATH: ""), binDirectory.path)
    }

    func testNilExecutablePathReturnsNil() {
        XCTAssertNil(SpacesCLISearchPath.pathPrependingSiblingCLIDirectory(executablePath: nil, currentPATH: "/usr/bin"))
    }
}
