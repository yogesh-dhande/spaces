import Foundation
import XCTest

@testable import spacesterminalghostty

final class GhosttyTerminalLinkOpenerTests: XCTestCase {
    // MARK: - resolvedURL(for:workingDirectory:)

    func testResolvedURLExpandsTilde() {
        let home = NSHomeDirectory()
        let resolved = GhosttyTerminalLinkOpener.resolvedURL(for: "~/notes.md")
        XCTAssertEqual(resolved?.path, "\(home)/notes.md")
    }

    func testResolvedURLKeepsAbsolutePathAsIs() {
        let resolved = GhosttyTerminalLinkOpener.resolvedURL(for: "/tmp/notes.md")
        XCTAssertEqual(resolved?.path, "/tmp/notes.md")
    }

    func testResolvedURLParsesHTTPAndHTTPS() {
        XCTAssertEqual(GhosttyTerminalLinkOpener.resolvedURL(for: "http://example.com"), URL(string: "http://example.com"))
        XCTAssertEqual(GhosttyTerminalLinkOpener.resolvedURL(for: "https://example.com"), URL(string: "https://example.com"))
    }

    func testResolvedURLParsesFileScheme() {
        let resolved = GhosttyTerminalLinkOpener.resolvedURL(for: "file:///tmp/notes.md")
        XCTAssertEqual(resolved?.path, "/tmp/notes.md")
    }

    func testResolvedURLRejectsRelativePathWithoutWorkingDirectory() {
        XCTAssertNil(GhosttyTerminalLinkOpener.resolvedURL(for: "notes.md"))
        XCTAssertNil(GhosttyTerminalLinkOpener.resolvedURL(for: "notes.md", workingDirectory: nil))
    }

    func testResolvedURLResolvesRelativePathAgainstWorkingDirectory() {
        let resolved = GhosttyTerminalLinkOpener.resolvedURL(for: "notes.md", workingDirectory: "/tmp/project")
        XCTAssertEqual(resolved?.path, "/tmp/project/notes.md")
    }

    func testResolvedURLResolvesNestedRelativePathAgainstWorkingDirectory() {
        let resolved = GhosttyTerminalLinkOpener.resolvedURL(for: "docs/readme.md", workingDirectory: "/tmp/project")
        XCTAssertEqual(resolved?.path, "/tmp/project/docs/readme.md")
    }

    func testResolvedURLIgnoresWorkingDirectoryForAbsolutePaths() {
        let resolved = GhosttyTerminalLinkOpener.resolvedURL(for: "/tmp/notes.md", workingDirectory: "/tmp/project")
        XCTAssertEqual(resolved?.path, "/tmp/notes.md")
    }

    func testResolvedURLIgnoresWorkingDirectoryForTildePaths() {
        let home = NSHomeDirectory()
        let resolved = GhosttyTerminalLinkOpener.resolvedURL(for: "~/notes.md", workingDirectory: "/tmp/project")
        XCTAssertEqual(resolved?.path, "\(home)/notes.md")
    }

    // MARK: - open(_:workingDirectory:openURL:)

    @MainActor
    func testOpenUsesInjectedOpenURLHandlerAndSkipsWorkingDirectoryWhenAbsolute() {
        var openedURLs: [URL] = []
        let handled = GhosttyTerminalLinkOpener.open("/tmp/notes.md") { url in
            openedURLs.append(url)
            return true
        }
        XCTAssertTrue(handled)
        XCTAssertEqual(openedURLs, [URL(fileURLWithPath: "/tmp/notes.md")])
    }

    @MainActor
    func testOpenUsesInjectedOpenURLHandlerWithWorkingDirectoryForRelativePaths() {
        var openedURLs: [URL] = []
        let handled = GhosttyTerminalLinkOpener.open("notes.md", workingDirectory: "/tmp/project") { url in
            openedURLs.append(url)
            return true
        }
        XCTAssertTrue(handled)
        XCTAssertEqual(openedURLs, [URL(fileURLWithPath: "/tmp/project/notes.md")])
    }

    @MainActor
    func testOpenReturnsFalseWhenValueDoesNotResolve() {
        var called = false
        let handled = GhosttyTerminalLinkOpener.open("relative/path.md") { _ in
            called = true
            return true
        }
        XCTAssertFalse(handled)
        XCTAssertFalse(called)
    }
}
