import XCTest

@testable import systembridge

final class TmuxAdapterTests: XCTestCase {
    func testExecutableLocatorPrefersPATHBeforeAbsoluteFallbacks() throws {
        let root = try makeTempDirectory()
        let preferred = root.appending(path: "preferred-tmux")
        let pathDir = root.appending(path: "bin", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: pathDir, withIntermediateDirectories: true)
        let pathCandidate = pathDir.appending(path: "tmux")

        try "#!/bin/sh\nexit 0\n".write(to: preferred, atomically: true, encoding: .utf8)
        try "#!/bin/sh\nexit 0\n".write(to: pathCandidate, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: preferred.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: pathCandidate.path)

        let resolved = ExecutableLocator.resolve(commandName: "tmux", preferredAbsolutePaths: [preferred.path], environment: ["PATH": pathDir.path])

        XCTAssertEqual(resolved, pathCandidate.path)
    }

    func testExecutableLocatorFallsBackToPATHSearch() throws {
        let root = try makeTempDirectory()
        let pathDir = root.appending(path: "bin", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: pathDir, withIntermediateDirectories: true)
        let pathCandidate = pathDir.appending(path: "tmux")
        try "#!/bin/sh\nexit 0\n".write(to: pathCandidate, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: pathCandidate.path)

        let resolved = ExecutableLocator.resolve(commandName: "tmux", preferredAbsolutePaths: [], environment: ["PATH": pathDir.path])

        XCTAssertEqual(resolved, pathCandidate.path)
    }

    func testParseWindowPreservesVisibleSentinelInsideWindowName() {
        let adapter = TmuxAdapter()
        let separator = "\u{1F}"
        let line = ["@12", "3", "frontend <<<SPACES_FIELD>>> debug", "workspace <<<SPACES_FIELD>>> session", "1", "4242"].joined(separator: separator)

        let window = adapter.parseWindow(line: line)

        XCTAssertEqual(window?.id, "@12")
        XCTAssertEqual(window?.index, 3)
        XCTAssertEqual(window?.name, "frontend <<<SPACES_FIELD>>> debug")
        XCTAssertEqual(window?.sessionName, "workspace <<<SPACES_FIELD>>> session")
        XCTAssertEqual(window?.isActive, true)
        XCTAssertEqual(window?.panePID, 4242)
    }

    func testParseWindowHandlesSanitizedUnderscoreDelimiters() {
        let adapter = TmuxAdapter()

        let window = adapter.parseWindow(line: "@1_0_dev server_spaces-session_1_46074")

        XCTAssertEqual(window?.id, "@1")
        XCTAssertEqual(window?.index, 0)
        XCTAssertEqual(window?.name, "dev server")
        XCTAssertEqual(window?.sessionName, "spaces-session")
        XCTAssertEqual(window?.isActive, true)
        XCTAssertEqual(window?.panePID, 46074)
    }

    func testParseWindowIDTrimsWhitespace() {
        let adapter = TmuxAdapter()

        let windowID = adapter.parseWindowID(output: "  @7 \n")

        XCTAssertEqual(windowID, "@7")
    }

    func testParseWindowIDReturnsUnderscoreDelimitedOutputVerbatim() {
        let adapter = TmuxAdapter()

        let windowID = adapter.parseWindowID(output: "@0_1_dev server_session_1_4242\n")

        XCTAssertEqual(windowID, "@0_1_dev server_session_1_4242")
    }

    func testParseCreatedWindowHandlesSanitizedUnderscoreDelimiters() {
        let adapter = TmuxAdapter()

        let window = adapter.parseCreatedWindow(output: "@0_1_1_4242\n", fallbackName: "dev server", sessionName: "spaces-session")

        XCTAssertEqual(window?.id, "@0")
        XCTAssertEqual(window?.index, 1)
        XCTAssertEqual(window?.name, "dev server")
        XCTAssertEqual(window?.sessionName, "spaces-session")
        XCTAssertEqual(window?.isActive, true)
        XCTAssertEqual(window?.panePID, 4242)
    }

    func testIsMissingTmuxTargetErrorMatchesMissingSession() {
        let adapter = TmuxAdapter()
        let error = NSError(domain: "spaces.shell", code: 1, userInfo: [NSLocalizedDescriptionKey: "can't find session: spaces-demo-backend"])

        XCTAssertTrue(adapter.isMissingTmuxTargetError(error))
    }

    func testIsMissingTmuxTargetErrorMatchesMissingWindow() {
        let adapter = TmuxAdapter()
        let error = NSError(domain: "spaces.shell", code: 1, userInfo: [NSLocalizedDescriptionKey: "can't find window: @12"])

        XCTAssertTrue(adapter.isMissingTmuxTargetError(error))
    }

    func testIsMissingTmuxTargetErrorIgnoresOtherFailures() {
        let adapter = TmuxAdapter()
        let error = NSError(domain: "spaces.shell", code: 1, userInfo: [NSLocalizedDescriptionKey: "permission denied"])

        XCTAssertFalse(adapter.isMissingTmuxTargetError(error))
    }
}
