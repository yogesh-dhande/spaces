import AppKit
import Carbon
import Foundation
import XCTest
import spacesterminalcore

@testable import spacesterminalghostty

final class GhosttyEmbeddedSessionHostTests: XCTestCase {
    @MainActor func testEmbeddedViewSuppressesFunctionKeyPrivateUseText() {
        let event = try! XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: "\u{F700}",
                charactersIgnoringModifiers: "\u{F700}", isARepeat: false, keyCode: UInt16(kVK_UpArrow)))

        XCTAssertNil(GhosttyEmbeddedTerminalView.ghosttyText(for: event))
        XCTAssertEqual(GhosttyEmbeddedTerminalView.rawKeyFallbackSpecifier(for: event), "up")
    }

    @MainActor func testEmbeddedViewMapsCommonNavigationAndFunctionFallbackKeys() {
        let homeEvent = try! XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: "\u{F729}",
                charactersIgnoringModifiers: "\u{F729}", isARepeat: false, keyCode: UInt16(kVK_Home)))
        let pageDownEvent = try! XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: "\u{F72D}",
                charactersIgnoringModifiers: "\u{F72D}", isARepeat: false, keyCode: UInt16(kVK_PageDown)))
        let backtabEvent = try! XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [.shift], timestamp: 0, windowNumber: 0, context: nil, characters: "\u{19}",
                charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: UInt16(kVK_Tab)))
        let f5Event = try! XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: "\u{F708}",
                charactersIgnoringModifiers: "\u{F708}", isARepeat: false, keyCode: UInt16(kVK_F5)))

        XCTAssertEqual(GhosttyEmbeddedTerminalView.rawKeyFallbackSpecifier(for: homeEvent), "home")
        XCTAssertEqual(GhosttyEmbeddedTerminalView.rawKeyFallbackSpecifier(for: pageDownEvent), "pagedown")
        XCTAssertEqual(GhosttyEmbeddedTerminalView.rawKeyFallbackSpecifier(for: backtabEvent), "backtab")
        XCTAssertEqual(GhosttyEmbeddedTerminalView.rawKeyFallbackSpecifier(for: f5Event), "f5")
    }

    @MainActor func testEmbeddedViewDoesNotInventModifiedNavigationFallbacks() {
        let optionLeftEvent = try! XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [.option], timestamp: 0, windowNumber: 0, context: nil, characters: "\u{F702}",
                charactersIgnoringModifiers: "\u{F702}", isARepeat: false, keyCode: UInt16(kVK_LeftArrow)))

        XCTAssertNil(GhosttyEmbeddedTerminalView.rawKeyFallbackSpecifier(for: optionLeftEvent))
    }

    @MainActor func testEmbeddedViewUsesPrintableTextForControlKeyEvents() {
        let event = try! XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [.control], timestamp: 0, windowNumber: 0, context: nil, characters: "\u{1F}",
                charactersIgnoringModifiers: "_", isARepeat: false, keyCode: UInt16(kVK_ANSI_U)))

        XCTAssertEqual(GhosttyEmbeddedTerminalView.ghosttyText(for: event), "u")
    }

    @MainActor func testEmbeddedViewDefersStandardWindowManagementShortcutsToSystem() {
        XCTAssertTrue(GhosttyEmbeddedTerminalView.shouldDeferToSystemShortcut(keyCode: UInt16(kVK_ANSI_W), modifierFlags: [.command]))
        XCTAssertTrue(GhosttyEmbeddedTerminalView.shouldDeferToSystemShortcut(keyCode: UInt16(kVK_ANSI_M), modifierFlags: [.command]))
        XCTAssertTrue(GhosttyEmbeddedTerminalView.shouldDeferToSystemShortcut(keyCode: UInt16(kVK_LeftArrow), modifierFlags: [.control, .function]))
        XCTAssertTrue(GhosttyEmbeddedTerminalView.shouldDeferToSystemShortcut(keyCode: UInt16(kVK_RightArrow), modifierFlags: [.control, .function]))
        XCTAssertFalse(GhosttyEmbeddedTerminalView.shouldDeferToSystemShortcut(keyCode: UInt16(kVK_ANSI_C), modifierFlags: [.command]))
        XCTAssertFalse(GhosttyEmbeddedTerminalView.shouldDeferToSystemShortcut(keyCode: UInt16(kVK_UpArrow), modifierFlags: []))
    }

    @MainActor func testEmbeddedViewPacksPreciseAndMomentumScrollModsLikeNativeGhostty() {
        XCTAssertEqual(Int32(GhosttyEmbeddedTerminalView.makeScrollMods(hasPreciseDeltas: true, momentumPhase: .changed)), Int32(0b0000_0111))
        XCTAssertEqual(Int32(GhosttyEmbeddedTerminalView.makeScrollMods(hasPreciseDeltas: false, momentumPhase: .ended)), Int32(0b0000_1000))
        XCTAssertEqual(Int32(GhosttyEmbeddedTerminalView.makeScrollMods(hasPreciseDeltas: false, momentumPhase: [])), Int32(0))
    }

    @MainActor func testSurfaceDataOutputDispatchRequiresHandlerAndBytes() {
        XCTAssertFalse(GhosttyEmbeddedTerminalView.shouldDispatchSurfaceDataOutput(hasHandler: false, byteCount: 32))
        XCTAssertFalse(GhosttyEmbeddedTerminalView.shouldDispatchSurfaceDataOutput(hasHandler: true, byteCount: 0))
        XCTAssertTrue(GhosttyEmbeddedTerminalView.shouldDispatchSurfaceDataOutput(hasHandler: true, byteCount: 32))
    }

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

    @MainActor func testRuntimeStateRemainsRunningWhenCachedChildPIDHasDied() throws {
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
        XCTAssertEqual(runtimeState.state, .running)
        XCTAssertEqual(runtimeState.childPID, childPID)
        XCTAssertNil(runtimeState.exitedAt)
    }

    @MainActor func testTerminateMarksRuntimeExited() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = TerminalSessionPaths(rootDirectory: root.path)
        try paths.ensureDirectories()
        let launchConfiguration = TerminalSessionLaunchConfiguration(
            sessionID: "session-5", backend: .ghosttyEmbedded, title: "shell", workingDirectory: "/tmp/original", shell: "/bin/zsh", command: "zsh",
            createdAt: "2026-05-10T00:00:00Z")
        let host = GhosttyEmbeddedSessionHost(launchConfiguration: launchConfiguration, paths: paths)

        host.terminate()

        let runtimeState = try TerminalSessionPersistence.readRuntimeState(paths: paths)
        XCTAssertEqual(runtimeState.state, .exited)
        XCTAssertNotNil(runtimeState.exitedAt)
    }
}
