import Foundation
import XCTest
import spacesterminalcore

@testable import spacesterminalghostty

final class GhosttyEmbeddedSessionHostTests: XCTestCase {
    @MainActor func testActionEventsUpdateEffectiveTitleAndWorkingDirectory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let launchConfiguration = TerminalSessionLaunchConfiguration(
            sessionID: "session-1", backend: .ghosttyEmbedded, title: "fallback-title", workingDirectory: "/tmp/original", shell: "/bin/zsh",
            command: "cat", createdAt: "2026-05-09T00:00:00Z")
        let host = GhosttyEmbeddedSessionHost(launchConfiguration: launchConfiguration, paths: .init(rootDirectory: root.path))

        XCTAssertEqual(host.effectiveTitle, "fallback-title")
        XCTAssertEqual(host.effectiveWorkingDirectory, "/tmp/original")

        host.applyActionEvent(.setTitle(" live-title "))
        host.applyActionEvent(.setWorkingDirectory(" /tmp/updated "))

        XCTAssertEqual(host.debugCurrentTitle, "live-title")
        XCTAssertEqual(host.debugCurrentWorkingDirectory, "/tmp/updated")
        XCTAssertEqual(host.effectiveTitle, "live-title")
        XCTAssertEqual(host.effectiveWorkingDirectory, "/tmp/updated")
    }

    @MainActor func testBlankActionValuesResetToLaunchConfigurationFallbacks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let launchConfiguration = TerminalSessionLaunchConfiguration(
            sessionID: "session-2", backend: .ghosttyEmbedded, title: "fallback-title", workingDirectory: "/tmp/original", shell: "/bin/zsh",
            command: nil, createdAt: "2026-05-09T00:00:00Z")
        let host = GhosttyEmbeddedSessionHost(launchConfiguration: launchConfiguration, paths: .init(rootDirectory: root.path))

        host.applyActionEvent(.setTitle("custom"))
        host.applyActionEvent(.setWorkingDirectory("/tmp/custom"))
        host.applyActionEvent(.setTitle("   "))
        host.applyActionEvent(.setWorkingDirectory("\n"))

        XCTAssertNil(host.debugCurrentTitle)
        XCTAssertNil(host.debugCurrentWorkingDirectory)
        XCTAssertEqual(host.effectiveTitle, "fallback-title")
        XCTAssertEqual(host.effectiveWorkingDirectory, "/tmp/original")
    }

    @MainActor func testIncomingOutputRequestsSurfaceRefreshImmediately() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let launchConfiguration = TerminalSessionLaunchConfiguration(
            sessionID: "session-3", backend: .ghosttyEmbedded, title: "shell", workingDirectory: "/tmp/original", shell: "/bin/zsh", command: "zsh",
            createdAt: "2026-05-10T00:00:00Z")
        var refreshCount = 0
        let host = GhosttyEmbeddedSessionHost(
            launchConfiguration: launchConfiguration, paths: .init(rootDirectory: root.path), requestSurfaceRefreshAction: { refreshCount += 1 })

        host.debugHandleIncomingOutput(Data("echo hello\n".utf8))

        XCTAssertEqual(refreshCount, 1)
        let output = try String(contentsOfFile: TerminalSessionPaths(rootDirectory: root.path).outputPath)
        XCTAssertEqual(output, "echo hello\n")
    }

    @MainActor func testRuntimeStateMarksExitedWhenCachedChildPIDHasDied() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = TerminalSessionPaths(rootDirectory: root.path)
        try paths.ensureDirectories()
        let launchConfiguration = TerminalSessionLaunchConfiguration(
            sessionID: "session-4", backend: .ghosttyEmbedded, title: "shell", workingDirectory: "/tmp/original", shell: "/bin/zsh", command: "zsh",
            createdAt: "2026-05-10T00:00:00Z")
        let host = GhosttyEmbeddedSessionHost(launchConfiguration: launchConfiguration, paths: paths)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "exit 0"]
        try process.run()
        let childPID = process.processIdentifier
        process.waitUntilExit()

        host.debugSetLastKnownChildPID(childPID)
        host.debugPersistRuntimeState()

        let runtimeState = try TerminalSessionPersistence.readRuntimeState(paths: paths)
        XCTAssertEqual(runtimeState.state, .exited)
        XCTAssertEqual(runtimeState.childPID, childPID)
        XCTAssertNotNil(runtimeState.exitedAt)
    }
}
