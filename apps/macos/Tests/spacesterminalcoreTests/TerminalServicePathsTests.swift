import Foundation
import XCTest

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

@testable import spacesterminalcore

final class TerminalServicePathsTests: XCTestCase {
    func testSocketPathUsesShortHashedTmpLocationForLongDatabaseRoots() throws {
        let tempRoot = URL(fileURLWithPath: "/tmp", isDirectory: true).appendingPathComponent(
            String(repeating: "nested-", count: 18), isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        let databasePath = tempRoot.appendingPathComponent("spaces.db").path
        let originalDatabasePath = ProcessInfo.processInfo.environment[SpacesProfile.databasePathEnvironmentVariable]
        let originalRuntimePath = ProcessInfo.processInfo.environment[SpacesProfile.runtimeDirectoryEnvironmentVariable]
        setenv("SPACES_DB_PATH", databasePath, 1)
        unsetenv("SPACES_RUNTIME_DIR")
        SpacesProfile.resetCacheForTesting()
        defer {
            restoreEnvironmentValue(originalDatabasePath, name: SpacesProfile.databasePathEnvironmentVariable)
            restoreEnvironmentValue(originalRuntimePath, name: SpacesProfile.runtimeDirectoryEnvironmentVariable)
            SpacesProfile.resetCacheForTesting()
            try? FileManager.default.removeItem(at: tempRoot)
        }

        let socketPath = try TerminalServicePaths.socketPath()
        let lockPath = try TerminalServicePaths.instanceLockPath()
        let databaseChangeSignalSocketPath = try TerminalServicePaths.databaseChangeSignalSocketPath()

        XCTAssertTrue(socketPath.hasPrefix("/tmp/spaces-sockets-\(getuid())/service-"))
        XCTAssertTrue(lockPath.hasPrefix("/tmp/spaces-sockets-\(getuid())/daemon-"))
        XCTAssertTrue(databaseChangeSignalSocketPath.hasPrefix("/tmp/spaces-sockets-\(getuid())/database-change-"))
        XCTAssertLessThan(socketPath.utf8.count, 104)
        XCTAssertLessThan(lockPath.utf8.count, 104)
        XCTAssertLessThan(databaseChangeSignalSocketPath.utf8.count, 104)
    }

    func testSocketPathsAreStableAcrossSymlinkedProfilePaths() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let realRoot = root.appendingPathComponent("real", isDirectory: true)
        let linkedRoot = root.appendingPathComponent("linked", isDirectory: true)
        try FileManager.default.createDirectory(at: realRoot, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: linkedRoot, withDestinationURL: realRoot)

        let originalDatabasePath = ProcessInfo.processInfo.environment[SpacesProfile.databasePathEnvironmentVariable]
        let originalRuntimePath = ProcessInfo.processInfo.environment[SpacesProfile.runtimeDirectoryEnvironmentVariable]
        defer {
            restoreEnvironmentValue(originalDatabasePath, name: SpacesProfile.databasePathEnvironmentVariable)
            restoreEnvironmentValue(originalRuntimePath, name: SpacesProfile.runtimeDirectoryEnvironmentVariable)
            SpacesProfile.resetCacheForTesting()
            try? FileManager.default.removeItem(at: root)
        }

        let realPaths = try terminalPaths(
            databasePath: realRoot.appendingPathComponent("spaces.db").path,
            runtimeDirectory: realRoot.appendingPathComponent("runtime", isDirectory: true).path)
        let linkedPaths = try terminalPaths(
            databasePath: linkedRoot.appendingPathComponent("spaces.db").path,
            runtimeDirectory: linkedRoot.appendingPathComponent("runtime", isDirectory: true).path)

        XCTAssertEqual(linkedPaths.serviceSocketPath, realPaths.serviceSocketPath)
        XCTAssertEqual(linkedPaths.serviceLockPath, realPaths.serviceLockPath)
        XCTAssertEqual(linkedPaths.databaseChangeSignalSocketPath, realPaths.databaseChangeSignalSocketPath)
        XCTAssertEqual(linkedPaths.sessionControlSocketPath, realPaths.sessionControlSocketPath)
        XCTAssertEqual(linkedPaths.sessionSubscriptionSocketPath, realPaths.sessionSubscriptionSocketPath)
        XCTAssertEqual(linkedPaths.terminalRoot, realPaths.terminalRoot)
        XCTAssertFalse(linkedPaths.terminalRoot.contains("/linked/"))
    }

    func testExistingExplicitPrivateRuntimePathHashesResolvedTerminalRoot() throws {
        let root = URL(fileURLWithPath: "/private/var/tmp", isDirectory: true).appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("runtime", isDirectory: true), withIntermediateDirectories: true)
        let originalDatabasePath = ProcessInfo.processInfo.environment[SpacesProfile.databasePathEnvironmentVariable]
        let originalRuntimePath = ProcessInfo.processInfo.environment[SpacesProfile.runtimeDirectoryEnvironmentVariable]
        defer {
            restoreEnvironmentValue(originalDatabasePath, name: SpacesProfile.databasePathEnvironmentVariable)
            restoreEnvironmentValue(originalRuntimePath, name: SpacesProfile.runtimeDirectoryEnvironmentVariable)
            SpacesProfile.resetCacheForTesting()
            try? FileManager.default.removeItem(at: root)
        }

        let paths = try terminalPaths(
            databasePath: root.appendingPathComponent("spaces.db").path,
            runtimeDirectory: root.appendingPathComponent("runtime", isDirectory: true).path)

        XCTAssertEqual(paths.serviceSocketPath, serviceSocketPath(forTerminalRoot: paths.terminalRoot))
        XCTAssertEqual(paths.databaseChangeSignalSocketPath, databaseChangeSignalSocketPath(forTerminalRoot: paths.terminalRoot))
        if paths.terminalRoot.hasPrefix("/private/var/") {
            XCTAssertNotEqual(
                paths.serviceSocketPath,
                serviceSocketPath(forTerminalRoot: paths.terminalRoot.replacingOccurrences(of: "/private/var/", with: "/var/")))
            XCTAssertNotEqual(
                paths.databaseChangeSignalSocketPath,
                databaseChangeSignalSocketPath(forTerminalRoot: paths.terminalRoot.replacingOccurrences(of: "/private/var/", with: "/var/")))
        }
    }

    private func terminalPaths(databasePath: String, runtimeDirectory: String) throws -> TerminalPathSnapshot {
        setenv(SpacesProfile.databasePathEnvironmentVariable, databasePath, 1)
        setenv(SpacesProfile.runtimeDirectoryEnvironmentVariable, runtimeDirectory, 1)
        SpacesProfile.resetCacheForTesting()

        let sessionPaths = try TerminalSessionPaths.forSession(id: "session-symlink")
        return TerminalPathSnapshot(
            serviceSocketPath: try TerminalServicePaths.socketPath(), serviceLockPath: try TerminalServicePaths.instanceLockPath(),
            databaseChangeSignalSocketPath: try TerminalServicePaths.databaseChangeSignalSocketPath(),
            sessionControlSocketPath: sessionPaths.controlSocketPath, sessionSubscriptionSocketPath: sessionPaths.subscriptionSocketPath,
            terminalRoot: try TerminalServicePaths.terminalRootDirectory().path)
    }

    private func serviceSocketPath(forTerminalRoot terminalRoot: String) -> String {
        var hash: UInt64 = 5381
        for byte in terminalRoot.utf8 { hash = ((hash << 5) &+ hash) &+ UInt64(byte) }
        return String(format: "/tmp/spaces-sockets-\(getuid())/service-%016llx.sock", hash)
    }

    private func databaseChangeSignalSocketPath(forTerminalRoot terminalRoot: String) -> String {
        var hash: UInt64 = 5381
        for byte in terminalRoot.utf8 { hash = ((hash << 5) &+ hash) &+ UInt64(byte) }
        return String(format: "/tmp/spaces-sockets-\(getuid())/database-change-%016llx.sock", hash)
    }

    private func restoreEnvironmentValue(_ value: String?, name: String) { if let value { setenv(name, value, 1) } else { unsetenv(name) } }
}

private struct TerminalPathSnapshot {
    let serviceSocketPath: String
    let serviceLockPath: String
    let databaseChangeSignalSocketPath: String
    let sessionControlSocketPath: String
    let sessionSubscriptionSocketPath: String
    let terminalRoot: String
}
