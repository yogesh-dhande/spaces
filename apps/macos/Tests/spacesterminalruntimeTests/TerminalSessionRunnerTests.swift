import XCTest
import spacesterminalcore
import spacesterminalghostty

@testable import spacesterminalruntime

final class TerminalSessionRunnerTests: XCTestCase {
    func testMakeRuntimeBuildsScriptPTYRuntimeForScriptBackend() throws {
        let configuration = TerminalSessionLaunchConfiguration(
            sessionID: "session-1", backend: .scriptPTY, title: "session", workingDirectory: "/tmp/work", shell: "/bin/zsh", command: "cat",
            createdAt: "2026-05-09T00:00:00Z")

        let runtime = try TerminalSessionRunner.makeRuntime(launchConfiguration: configuration, paths: .init(rootDirectory: "/tmp/session-1"))

        XCTAssertEqual(runtime.backendKind, .scriptPTY)
        XCTAssertTrue(runtime is ScriptPTYTerminalSessionRuntime)
    }

    func testMakeRuntimeBuildsGhosttyRuntimeForGhosttyBackend() throws {
        let configuration = TerminalSessionLaunchConfiguration(
            sessionID: "session-2", backend: .ghosttyEmbedded, title: "session", workingDirectory: "/tmp/work", shell: "/bin/zsh", command: nil,
            createdAt: "2026-05-09T00:00:00Z")

        let runtime = try TerminalSessionRunner.makeRuntime(launchConfiguration: configuration, paths: .init(rootDirectory: "/tmp/session-2"))

        XCTAssertEqual(runtime.backendKind, .ghosttyEmbedded)
        XCTAssertTrue(runtime is GhosttyEmbeddedTerminalSessionRuntime)
    }

    func testBackendSupportMarksGhosttyUnavailableWithoutArtifacts() {
        XCTAssertTrue(TerminalSessionBackendSupport.isSupported(.scriptPTY, currentDirectoryPath: "/tmp"))
        XCTAssertFalse(TerminalSessionBackendSupport.isSupported(.ghosttyEmbedded, currentDirectoryPath: "/tmp"))
    }

    func testBackendSupportMarksGhosttyAvailableWhenArtifactsExist() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let frameworkRoot = root.appendingPathComponent("GhosttyKit.xcframework", isDirectory: true)
        let platformRoot = frameworkRoot.appendingPathComponent("macos-arm64_x86_64", isDirectory: true)
        let headersRoot = platformRoot.appendingPathComponent("Headers", isDirectory: true)
        let resourcesRoot = root.appendingPathComponent("ghostty", isDirectory: true)

        try FileManager.default.createDirectory(at: headersRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: resourcesRoot, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: platformRoot.appendingPathComponent("libghostty-internal.a").path, contents: Data())

        XCTAssertTrue(
            TerminalSessionBackendSupport.isSupported(
                .ghosttyEmbedded,
                environment: [
                    GhosttyEmbeddedLocator.xcframeworkEnvironmentVariable: frameworkRoot.path,
                    GhosttyEmbeddedLocator.resourcesEnvironmentVariable: resourcesRoot.path,
                ], currentDirectoryPath: root.path))
    }
}
