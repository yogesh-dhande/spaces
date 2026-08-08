import Foundation
import XCTest

@testable import spacescli
@testable import spacesterminalcore

/// Behavior under test: a long-lived `spaces mcp` server whose daemon has moved ahead of it reloads its
/// own binary image instead of returning unactionable "update Spaces" advice — and does so only in that
/// direction, only when the stable invocation path now loads a different image, and only after the
/// in-flight tool call has been fully answered with nothing left buffered from the client.
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

    // MARK: - macOS layout: the bundle binary is replaced at a stable path

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

    // MARK: - Linux release layout: a new release directory and a repointed `current`

    func testReleaseLayoutExecsTheCurrentWrapperAfterAnUpdate() throws {
        try makeRelease(version: "1.0")
        try pointCurrentAtRelease(version: "1.0")
        let reload = MCPStaleImageReload(executablePath: releaseBinaryPath(version: "1.0"))

        // An update unpacks a whole new release directory and repoints `current`. The running binary's own
        // path still names release 1.0 and its inode never changes, so only `current` reveals the update.
        try makeRelease(version: "2.0")
        try pointCurrentAtRelease(version: "2.0")

        // The wrapper is the exec target, not the binary: it rebuilds LD_LIBRARY_PATH for release 2.0.
        XCTAssertEqual(reload.execTarget(for: daemonWireIncompatible(.clientTooOld)), currentWrapperPath())
    }

    func testReleaseLayoutDoesNotExecOnAnUnchangedInstall() throws {
        try makeRelease(version: "1.0")
        try pointCurrentAtRelease(version: "1.0")
        let reload = MCPStaleImageReload(executablePath: releaseBinaryPath(version: "1.0"))

        XCTAssertNil(reload.execTarget(for: daemonWireIncompatible(.clientTooOld)))
    }

    /// The process may report either half of the wrapper/binary pair as its own path — `/proc/self/exe`
    /// gives the binary, a resolved stable symlink gives the wrapper. Both must compare binary against
    /// binary: comparing the wrapper script's inode against the binary's would differ on an untouched
    /// install and exec on every retry forever.
    func testReleaseLayoutFromStableSymlinkComparesBinariesNotTheWrapper() throws {
        try makeRelease(version: "1.0")
        try pointCurrentAtRelease(version: "1.0")
        let stablePath = directoryURL.appendingPathComponent("bin/spaces", isDirectory: false).path
        try FileManager.default.createDirectory(at: directoryURL.appendingPathComponent("bin", isDirectory: true), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: stablePath, withDestinationPath: releaseWrapperPath(version: "1.0"))
        let reload = MCPStaleImageReload(executablePath: stablePath)

        XCTAssertNil(reload.execTarget(for: daemonWireIncompatible(.clientTooOld)))

        try makeRelease(version: "2.0")
        try pointCurrentAtRelease(version: "2.0")

        XCTAssertEqual(reload.execTarget(for: daemonWireIncompatible(.clientTooOld)), currentWrapperPath())
    }

    // MARK: - Direction and unrelated failures

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

    // MARK: - Server response ordering and the empty-buffer exec gate

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

    /// A client that pipelined leaves further frames drained into this image's memory. Exec would discard
    /// them, so the reload waits: the failed call is still answered, and the buffered frame is still served
    /// by this image. The next stale-image failure — reached by the last buffered frame at the latest —
    /// finds an empty buffer and execs.
    func testStaleImageDefersTheExecUntilBufferedFramesAreDrained() throws {
        let outputPipe = Pipe()
        var execPath: String?
        let reload = stubbedReload(onDiskImageDiffers: true, replaceExecutable: { path, _ in execPath = path })
        let server = SpacesMCPStdioServer(input: Pipe().fileHandleForReading, output: outputPipe.fileHandleForWriting, staleImageReload: reload)
        server.readBuffer = Data(#"{"jsonrpc":"2.0","id":2,"method":"ping"}"#.utf8 + [0x0A])

        try server.respondToFailedToolCall(id: 1, error: daemonWireIncompatible(.clientTooOld))

        XCTAssertNil(execPath, "a pipelined frame is still buffered, so exec would discard it")
        XCTAssertEqual(try toolResult(from: outputPipe.fileHandleForReading.availableData).text, MCPStaleImageReload.retryMessage)
        // The buffered frame stays available to this image rather than being lost.
        XCTAssertFalse(server.readBuffer.isEmpty)

        // Once the read loop has drained it, the next failure reloads.
        server.readBuffer = Data()
        try server.respondToFailedToolCall(id: 3, error: daemonWireIncompatible(.clientTooOld))

        XCTAssertEqual(execPath, "/resolved/spaces")
    }

    /// Pipelined frames written in one client write are each read and answered — the property the deferred
    /// exec above preserves.
    func testPipelinedFramesInOneWriteAreEachServed() throws {
        let requests = [#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#, #"{"jsonrpc":"2.0","id":2,"method":"ping"}"#]
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        inputPipe.fileHandleForWriting.write(Data((requests.joined(separator: "\n") + "\n").utf8))
        try inputPipe.fileHandleForWriting.close()

        let server = SpacesMCPStdioServer(input: inputPipe.fileHandleForReading, output: outputPipe.fileHandleForWriting)
        try server.run()
        try outputPipe.fileHandleForWriting.close()

        let lines = String(decoding: outputPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
    }

    // MARK: - Helpers

    private func daemonWireIncompatible(_ verdict: SpacesWireCompatibility) -> TerminalServiceError {
        .daemonWireIncompatible(
            TerminalServiceDaemonWireIncompatibility(
                verdict: verdict, status: nil, message: verdict == .clientTooOld ? "daemon is newer" : "daemon is older"))
    }

    /// Mutable so a stub can model the one thing that actually happens: the image on disk changes after
    /// this process read its own.
    private final class MutableIdentity { var inode: Int64 = 1 }

    /// A reload wired to a fixed path and a mutable identity instead of the filesystem, so a server-level
    /// test exercises only the respond-then-exec ordering and the buffer gate.
    private func stubbedReload(onDiskImageDiffers: Bool, replaceExecutable: @escaping MCPStaleImageReload.ExecutableReplacement)
        -> MCPStaleImageReload
    {
        let identity = MutableIdentity()
        let reload = MCPStaleImageReload(
            executablePath: "/bin/spaces", identityReader: { _ in SpacesBinaryFileIdentity(deviceID: 1, inode: identity.inode) },
            pathResolver: { _ in "/resolved/spaces" }, replaceExecutable: replaceExecutable)
        if onDiskImageDiffers { identity.inode = 2 }
        return reload
    }

    private func makeSymlinkedBinary(named name: String) throws -> (binaryPath: String, linkPath: String) {
        let binaryPath = directoryURL.appendingPathComponent(name, isDirectory: false).path
        let linkPath = directoryURL.appendingPathComponent("spaces", isDirectory: false).path
        try replaceBinary(at: binaryPath, contents: name)
        try FileManager.default.createSymbolicLink(atPath: linkPath, withDestinationPath: binaryPath)
        return (binaryPath, linkPath)
    }

    /// The Linux artifact's per-release `bin/`: a `spaces` wrapper script beside the `spaces-bin` binary it
    /// executes.
    private func makeRelease(version: String) throws {
        let binDirectory = directoryURL.appendingPathComponent("releases/\(version)/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: binDirectory, withIntermediateDirectories: true)
        try replaceBinary(at: releaseWrapperPath(version: version), contents: "wrapper \(version)")
        try replaceBinary(at: releaseBinaryPath(version: version), contents: "binary \(version)")
    }

    private func pointCurrentAtRelease(version: String) throws {
        let currentPath = directoryURL.appendingPathComponent("current", isDirectory: false).path
        try? FileManager.default.removeItem(atPath: currentPath)
        try FileManager.default.createSymbolicLink(
            atPath: currentPath, withDestinationPath: directoryURL.appendingPathComponent("releases/\(version)", isDirectory: true).path)
    }

    private func releaseWrapperPath(version: String) -> String {
        directoryURL.appendingPathComponent("releases/\(version)/bin/spaces", isDirectory: false).path
    }

    private func releaseBinaryPath(version: String) -> String {
        directoryURL.appendingPathComponent("releases/\(version)/bin/spaces-bin", isDirectory: false).path
    }

    /// The exec target the release layout resolves to, expressed against the symlink-resolved root the
    /// production code derives from the running executable's own resolved path.
    private func currentWrapperPath() -> String? { MCPStaleImageReload.resolvedPath(of: directoryURL.path).map { $0 + "/current/bin/spaces" } }

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
