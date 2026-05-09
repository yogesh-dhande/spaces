import Foundation
import XCTest
import spacesterminalcore

@testable import spacesterminalghostty

final class GhosttyEmbeddedLocatorTests: XCTestCase {
    func testResolveFindsFrameworkFromEnvironmentOverride() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let frameworkRoot = root.appendingPathComponent("GhosttyKit.xcframework", isDirectory: true)
        let platformRoot = frameworkRoot.appendingPathComponent("macos-arm64_x86_64", isDirectory: true)
        let headersRoot = platformRoot.appendingPathComponent("Headers", isDirectory: true)
        let resourcesRoot = frameworkRoot.appendingPathComponent("Resources/ghostty", isDirectory: true)

        try FileManager.default.createDirectory(at: headersRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: resourcesRoot, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: platformRoot.appendingPathComponent("libghostty-internal.a").path, contents: Data())

        let availability = GhosttyEmbeddedLocator.resolve(
            environment: [
                GhosttyEmbeddedLocator.xcframeworkEnvironmentVariable: frameworkRoot.path,
                GhosttyEmbeddedLocator.resourcesEnvironmentVariable: resourcesRoot.path,
            ], currentDirectoryPath: root.path)

        guard case .available(let paths) = availability else {
            XCTFail("Expected embedded ghostty availability")
            return
        }

        XCTAssertEqual(paths.xcframeworkRootPath, frameworkRoot.path)
        XCTAssertEqual(paths.resourcesDirectoryPath, resourcesRoot.path)
    }

    func testResolveReportsHelpfulReasonWhenFrameworkMissing() {
        let availability = GhosttyEmbeddedLocator.resolve(environment: [:], currentDirectoryPath: "/tmp/spaces-terminal")
        guard case .unavailable(let reason) = availability else {
            XCTFail("Expected unavailable result")
            return
        }

        XCTAssertTrue(reason.contains("GhosttyKit.xcframework"))
        XCTAssertTrue(reason.contains(GhosttyEmbeddedLocator.xcframeworkEnvironmentVariable))
    }

    func testRendererResolverFallsBackWhenEmbeddedGhosttyMissing() {
        let mode = TerminalRendererResolver.resolveGhosttyEmbeddedMode(
            backend: .ghosttyEmbedded, environment: [:], currentDirectoryPath: "/tmp/spaces-terminal")
        guard case .shellFallback(let reason) = mode else {
            XCTFail("Expected shell fallback renderer mode")
            return
        }

        XCTAssertTrue(reason.contains("GhosttyKit.xcframework"))
        XCTAssertTrue(mode.statusSummary.contains("shell fallback"))
    }

    func testRendererResolverFallsBackForNonGhosttyBackends() {
        let mode = TerminalRendererResolver.resolveGhosttyEmbeddedMode(
            backend: .scriptPTY, environment: [:], currentDirectoryPath: "/tmp/spaces-terminal")
        guard case .shellFallback(let reason) = mode else {
            XCTFail("Expected shell fallback renderer mode")
            return
        }

        XCTAssertEqual(reason, "session backend is script-pty")
    }

    func testResolveFindsBranchLocalGhosttykitLayout() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let frameworkRoot = root.appendingPathComponent("apps/macos/.local/ghosttykit/GhosttyKit.xcframework", isDirectory: true)
        let platformRoot = frameworkRoot.appendingPathComponent("macos-arm64_x86_64", isDirectory: true)
        let headersRoot = platformRoot.appendingPathComponent("Headers", isDirectory: true)

        try FileManager.default.createDirectory(at: headersRoot, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: platformRoot.appendingPathComponent("libghostty-internal.a").path, contents: Data())

        let availability = GhosttyEmbeddedLocator.resolve(environment: [:], currentDirectoryPath: root.path)
        guard case .available(let paths) = availability else {
            XCTFail("Expected branch-local ghosttykit discovery")
            return
        }

        XCTAssertEqual(paths.xcframeworkRootPath, frameworkRoot.path)
    }
}
