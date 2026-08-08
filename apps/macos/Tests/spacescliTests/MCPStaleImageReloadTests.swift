import Foundation
import XCTest

@testable import spacescli
@testable import spacesterminalcore

/// Behavior under test: a long-lived `spaces mcp` server whose daemon has moved ahead of it reloads its
/// own binary image instead of returning unactionable "update Spaces" advice — and does so only in that
/// direction, only when the binary on disk is genuinely a different image, and only after the in-flight
/// tool call has been fully answered.
final class MCPStaleImageReloadTests: XCTestCase {
    private var directoryURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directoryURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).appendingPathComponent(
            "mcp-stale-image-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directoryURL)
        directoryURL = nil
        try super.tearDownWithError()
    }

    // MARK: - Decision

    func testReplacedBinaryBehindTheSymlinkExecsTheResolvedTarget() throws {
        let layout = try makeSymlinkedBinary(named: "build-a")
        var recorded: (path: String, arguments: [String])?
        let reload = MCPStaleImageReload(executablePath: layout.linkPath, replaceExecutable: { recorded = ($0, $1) })

        // A Spaces update replaces the binary at the same path, which is a different file.
        try replaceBinary(at: layout.binaryPath, contents: "updated")

        let target = reload.execTarget(for: daemonWireIncompatible(.clientTooOld))
        XCTAssertEqual(target, MCPStaleImageReload.resolvedPath(of: layout.binaryPath))

        reload.reload(into: try XCTUnwrap(target), arguments: ["/usr/local/bin/spaces", "mcp"])
        XCTAssertEqual(recorded?.path, target)
        // The successor is invoked exactly as this process was, so it comes back up as an MCP server.
        XCTAssertEqual(recorded?.arguments, ["/usr/local/bin/spaces", "mcp"])
    }

    func testRepointedSymlinkExecsItsNewTarget() throws {
        let layout = try makeSymlinkedBinary(named: "build-a")
        let replacementPath = directoryURL.appendingPathComponent("build-b", isDirectory: false).path
        let reload = MCPStaleImageReload(executablePath: layout.linkPath)

        try replaceBinary(at: replacementPath, contents: "build-b")
        try FileManager.default.removeItem(atPath: layout.linkPath)
        try FileManager.default.createSymbolicLink(atPath: layout.linkPath, withDestinationPath: replacementPath)

        XCTAssertEqual(reload.execTarget(for: daemonWireIncompatible(.clientTooOld)), MCPStaleImageReload.resolvedPath(of: replacementPath))
    }

    func testUnchangedOnDiskImageDoesNotExec() throws {
        let layout = try makeSymlinkedBinary(named: "build-a")
        let reload = MCPStaleImageReload(executablePath: layout.linkPath)

        // The mismatch has some cause other than a stale image (a foreign daemon on this profile's
        // socket, say). Exec'ing the same file again would change nothing and could only loop.
        XCTAssertNil(reload.execTarget(for: daemonWireIncompatible(.clientTooOld)))
    }

    func testDaemonOlderThanThisImageDoesNotExec() throws {
        let layout = try makeSymlinkedBinary(named: "build-a")
        let reload = MCPStaleImageReload(executablePath: layout.linkPath)
        try replaceBinary(at: layout.binaryPath, contents: "updated")

        // Loading a newer image cannot help a daemon that is behind; the existing error stands.
        XCTAssertNil(reload.execTarget(for: daemonWireIncompatible(.daemonTooOld)))
    }

    func testOrdinaryToolFailureDoesNotExec() throws {
        let layout = try makeSymlinkedBinary(named: "build-a")
        let reload = MCPStaleImageReload(executablePath: layout.linkPath)
        try replaceBinary(at: layout.binaryPath, contents: "updated")

        XCTAssertNil(reload.execTarget(for: TerminalServiceError.requestFailed("workspace not found")))
    }

    func testMissingExecutablePathDoesNotExec() {
        let reload = MCPStaleImageReload(executablePath: nil)

        XCTAssertNil(reload.execTarget(for: daemonWireIncompatible(.clientTooOld)))
    }

    // MARK: - Server response ordering

    func testStaleImageToolFailureIsAnsweredBeforeTheExec() throws {
        let outputPipe = Pipe()
        var execPath: String?
        var outputAtExecTime: Data?
        let reload = stubbedReload(
            onDiskImageDiffers: true,
            replaceExecutable: { path, _ in
                execPath = path
                // The response bytes must already be on stdout when the image is replaced: anything still
                // buffered here would be lost mid-frame and desynchronize the client's stdio framing.
                outputAtExecTime = outputPipe.fileHandleForReading.availableData
            })
        let server = SpacesMCPStdioServer(input: Pipe().fileHandleForReading, output: outputPipe.fileHandleForWriting, staleImageReload: reload)

        try server.respondToFailedToolCall(id: 7, error: daemonWireIncompatible(.clientTooOld))

        XCTAssertEqual(execPath, "/resolved/spaces")
        let message = try toolResult(from: try XCTUnwrap(outputAtExecTime))
        XCTAssertEqual(message.id, 7)
        XCTAssertTrue(message.isError)
        XCTAssertEqual(message.text, MCPStaleImageReload.retryMessage)
    }

    func testToolFailureWithoutAStaleImageReportsTheOriginalError() throws {
        let outputPipe = Pipe()
        var execPath: String?
        let reload = stubbedReload(onDiskImageDiffers: false, replaceExecutable: { path, _ in execPath = path })
        let server = SpacesMCPStdioServer(input: Pipe().fileHandleForReading, output: outputPipe.fileHandleForWriting, staleImageReload: reload)

        try server.respondToFailedToolCall(id: 9, error: daemonWireIncompatible(.clientTooOld))
        try outputPipe.fileHandleForWriting.close()

        XCTAssertNil(execPath)
        let message = try toolResult(from: outputPipe.fileHandleForReading.readDataToEndOfFile())
        XCTAssertEqual(message.id, 9)
        XCTAssertTrue(message.isError)
        XCTAssertEqual(message.text, "daemon is newer")
    }

    // MARK: - Helpers

    private func daemonWireIncompatible(_ verdict: SpacesWireCompatibility) -> TerminalServiceError {
        .daemonWireIncompatible(
            TerminalServiceDaemonWireIncompatibility(
                verdict: verdict, status: nil, message: verdict == .clientTooOld ? "daemon is newer" : "daemon is older"))
    }

    /// A reload wired to fixed identities instead of the filesystem, so a server-level test exercises only
    /// the respond-then-exec ordering.
    private func stubbedReload(onDiskImageDiffers: Bool, replaceExecutable: @escaping MCPStaleImageReload.ExecutableReplacement)
        -> MCPStaleImageReload
    {
        MCPStaleImageReload(
            executablePath: "/bin/spaces",
            identityReader: { path in SpacesBinaryFileIdentity(deviceID: 1, inode: path == "/bin/spaces" || !onDiskImageDiffers ? 1 : 2) },
            pathResolver: { _ in "/resolved/spaces" }, replaceExecutable: replaceExecutable)
    }

    private func makeSymlinkedBinary(named name: String) throws -> (binaryPath: String, linkPath: String) {
        let binaryPath = directoryURL.appendingPathComponent(name, isDirectory: false).path
        let linkPath = directoryURL.appendingPathComponent("spaces", isDirectory: false).path
        try replaceBinary(at: binaryPath, contents: name)
        try FileManager.default.createSymbolicLink(atPath: linkPath, withDestinationPath: binaryPath)
        return (binaryPath, linkPath)
    }

    /// Writes a distinct file at `path`, removing any predecessor first so the replacement is a different
    /// inode — how an updated app bundle's binary differs from the one a running process was exec'd from.
    private func replaceBinary(at path: String, contents: String) throws {
        try? FileManager.default.removeItem(atPath: path)
        try Data(contents.utf8).write(to: URL(fileURLWithPath: path))
    }

    private func toolResult(from data: Data) throws -> (id: Int?, isError: Bool, text: String) {
        let line = try XCTUnwrap(String(decoding: data, as: UTF8.self).split(separator: "\n").first)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        let result = try XCTUnwrap(object["result"] as? [String: Any])
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        return (object["id"] as? Int, try XCTUnwrap(result["isError"] as? Bool), try XCTUnwrap(content.first?["text"] as? String))
    }
}
