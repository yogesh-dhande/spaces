import Foundation
import XCTest
import spacesterminalcore

@testable import spacesterminalghostty

final class GhosttyEmbeddedLocatorTests: XCTestCase {
    func testResolveFindsResourcesFromEnvironmentOverride() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let resourcesRoot = root.appendingPathComponent("ghostty", isDirectory: true)

        try FileManager.default.createDirectory(at: resourcesRoot, withIntermediateDirectories: true)

        let availability = GhosttyEmbeddedLocator.resolve(
            environment: [GhosttyEmbeddedLocator.resourcesEnvironmentVariable: resourcesRoot.path], currentDirectoryPath: root.path,
            bundleResourcesURL: nil, executableURL: nil)

        guard case .available(let paths) = availability else {
            XCTFail("Expected embedded ghostty availability")
            return
        }

        XCTAssertEqual(paths.resourcesDirectoryPath, resourcesRoot.path)
    }

    func testResolveFindsResourcesBesideFrameworkEnvironmentOverride() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let frameworkRoot = root.appendingPathComponent("GhosttyKit.xcframework", isDirectory: true)
        let resourcesRoot = root.appendingPathComponent("Resources/ghostty", isDirectory: true)
        try FileManager.default.createDirectory(at: resourcesRoot, withIntermediateDirectories: true)

        let availability = GhosttyEmbeddedLocator.resolve(
            environment: [GhosttyEmbeddedLocator.xcframeworkEnvironmentVariable: frameworkRoot.path], currentDirectoryPath: root.path,
            bundleResourcesURL: nil, executableURL: nil)

        guard case .available(let paths) = availability else {
            XCTFail("Expected Ghostty resources beside the framework override")
            return
        }
        XCTAssertEqual(paths.resourcesDirectoryPath, resourcesRoot.path)
    }

    func testResolveFindsResourcesInAppBundle() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleResources = root.appendingPathComponent("Spaces.app/Contents/Resources", isDirectory: true)
        let resourcesRoot = bundleResources.appendingPathComponent("ghostty", isDirectory: true)
        try FileManager.default.createDirectory(at: resourcesRoot, withIntermediateDirectories: true)

        let availability = GhosttyEmbeddedLocator.resolve(
            environment: [:], currentDirectoryPath: root.path, bundleResourcesURL: bundleResources, executableURL: nil)

        guard case .available(let paths) = availability else {
            XCTFail("Expected app-bundled Ghostty resources")
            return
        }
        XCTAssertEqual(paths.resourcesDirectoryPath, resourcesRoot.path)
    }

    func testResolveFindsResourcesBesideSymlinkedDaemonExecutable() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleResources = root.appendingPathComponent("Spaces.app/Contents/Resources", isDirectory: true)
        let resourcesRoot = bundleResources.appendingPathComponent("ghostty", isDirectory: true)
        let daemonURL = bundleResources.appendingPathComponent("spacesd")
        let installedBin = root.appendingPathComponent(".spaces/bin", isDirectory: true)
        let daemonSymlink = installedBin.appendingPathComponent("spacesd")
        try FileManager.default.createDirectory(at: resourcesRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: installedBin, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: daemonURL.path, contents: Data())
        try FileManager.default.createSymbolicLink(at: daemonSymlink, withDestinationURL: daemonURL)

        let availability = GhosttyEmbeddedLocator.resolve(
            environment: [:], currentDirectoryPath: root.path, bundleResourcesURL: nil, executableURL: daemonSymlink)

        guard case .available(let paths) = availability else {
            XCTFail("Expected Ghostty resources beside the resolved daemon executable")
            return
        }
        XCTAssertEqual(paths.resourcesDirectoryPath, resourcesRoot.path)
    }

    /// A `spacesd` a client spawns on demand inherits the client's working directory, which need not be
    /// the repo. Ghostty resources must still resolve from the branch-local `.local/ghosttykit` tree by
    /// anchoring the dev-tree search to the daemon binary's own location rather than the cwd (issue #188).
    func testResolveFindsBranchLocalGhosttykitFromExecutableWhenCwdIsUnrelated() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let packageDir = root.appendingPathComponent("apps/macos", isDirectory: true)
        let resourcesRoot = packageDir.appendingPathComponent(".local/ghosttykit/Resources/ghostty", isDirectory: true)
        let daemonURL = packageDir.appendingPathComponent(".build/arm64-apple-macosx/debug/spacesd")
        try FileManager.default.createDirectory(at: resourcesRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: daemonURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: daemonURL.path, contents: Data())

        // A cwd that resolves nothing on its own, proving the executable anchor carries resolution.
        let unrelatedCwd = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: unrelatedCwd) }
        try FileManager.default.createDirectory(at: unrelatedCwd, withIntermediateDirectories: true)

        let availability = GhosttyEmbeddedLocator.resolve(
            environment: [:], currentDirectoryPath: unrelatedCwd.path, bundleResourcesURL: nil, executableURL: daemonURL)
        guard case .available(let paths) = availability else {
            XCTFail("Expected Ghostty resources resolved from the daemon executable location")
            return
        }

        XCTAssertEqual(paths.resourcesDirectoryPath, resourcesRoot.path)
    }

    func testResolveReportsHelpfulReasonWhenResourcesMissing() {
        let availability = GhosttyEmbeddedLocator.resolve(
            environment: [:], currentDirectoryPath: "/tmp/spaces-terminal", bundleResourcesURL: nil, executableURL: nil)
        guard case .unavailable(let reason) = availability else {
            XCTFail("Expected unavailable result")
            return
        }

        XCTAssertTrue(reason.contains("Ghostty runtime resources"))
        XCTAssertTrue(reason.contains(GhosttyEmbeddedLocator.resourcesEnvironmentVariable))
    }

    func testRendererResolverFallsBackWhenEmbeddedGhosttyMissing() {
        let mode = TerminalRendererResolver.resolveGhosttyEmbeddedMode(
            backend: .ghosttyEmbedded, environment: [:], currentDirectoryPath: "/tmp/spaces-terminal")
        guard case .shellFallback(let reason) = mode else {
            XCTFail("Expected shell fallback renderer mode")
            return
        }

        XCTAssertTrue(reason.contains("Ghostty runtime resources"))
        XCTAssertTrue(mode.statusSummary.contains("shell fallback"))
    }

    func testResolveFindsBranchLocalGhosttykitLayout() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let resourcesRoot = root.appendingPathComponent("apps/macos/.local/ghosttykit/Resources/ghostty", isDirectory: true)

        try FileManager.default.createDirectory(at: resourcesRoot, withIntermediateDirectories: true)

        let availability = GhosttyEmbeddedLocator.resolve(
            environment: [:], currentDirectoryPath: root.path, bundleResourcesURL: nil, executableURL: nil)
        guard case .available(let paths) = availability else {
            XCTFail("Expected branch-local ghosttykit discovery")
            return
        }

        XCTAssertEqual(paths.resourcesDirectoryPath, resourcesRoot.path)
    }
}
