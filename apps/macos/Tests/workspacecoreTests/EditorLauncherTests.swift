import Foundation
import XCTest

@testable import workspacecore

final class EditorLauncherTests: XCTestCase {
    // Tests a local open invokes the editor CLI with the workspace directory.
    func testOpenInvokesCLIWithDirectory() throws {
        let (cli, log) = try makeLoggingCLI()
        try EditorLauncher.open(cliExecutablePath: cli, directory: "/tmp/workspace")
        XCTAssertEqual(try loggedLines(log), ["/tmp/workspace|"])
    }

    // Tests a VS Code remote open hands the CLI a vscode-remote folder URI with [user@]host[:port] authority and a percent-encoded path.
    func testOpenRemoteVSCodeBuildsFolderURI() throws {
        let (cli, log) = try makeLoggingCLI()
        try EditorLauncher.openRemoteVSCode(
            cliExecutablePath: cli, sshHost: "build.example", sshUser: "dev", sshPort: 2200, directory: "/srv/work space")
        XCTAssertEqual(try loggedLines(log), ["--folder-uri|vscode-remote://ssh-remote+dev@build.example:2200/srv/work%20space|"])
    }

    // Tests a Zed remote open hands the CLI an ssh:// URL (Zed's built-in remoting) rather than a vscode-remote folder URI.
    func testOpenRemoteZedBuildsSSHURL() throws {
        let (cli, log) = try makeLoggingCLI()
        try EditorLauncher.openRemoteZed(
            cliExecutablePath: cli, sshHost: "build.example", sshUser: "dev", sshPort: 2200, directory: "/srv/work space")
        XCTAssertEqual(try loggedLines(log), ["ssh://dev@build.example:2200/srv/work%20space|"])
    }

    // Tests a remote open omits user and port from the authority when they are not configured.
    func testOpenRemoteOmitsMissingUserAndPort() throws {
        let (cli, log) = try makeLoggingCLI()
        try EditorLauncher.openRemoteVSCode(cliExecutablePath: cli, sshHost: "build.example", sshUser: nil, sshPort: nil, directory: "/srv/work")
        XCTAssertEqual(try loggedLines(log), ["--folder-uri|vscode-remote://ssh-remote+build.example/srv/work|"])
    }

    // Tests a remote open rejects a paired device that has no SSH host configured.
    func testOpenRemoteThrowsWhenSSHHostMissing() throws {
        let (cli, _) = try makeLoggingCLI()
        XCTAssertThrowsError(
            try EditorLauncher.openRemoteVSCode(cliExecutablePath: cli, sshHost: "  ", sshUser: nil, sshPort: nil, directory: "/srv/work")
        ) { error in XCTAssertTrue(error.localizedDescription.contains("requires an SSH host")) }
    }

    // Tests extension install invokes the editor CLI with the extension identifier.
    func testInstallRemoteSSHExtensionInvokesCLI() throws {
        let (cli, log) = try makeLoggingCLI()
        try EditorLauncher.installRemoteSSHExtension(cliExecutablePath: cli, extensionID: "ms-vscode-remote.remote-ssh")
        XCTAssertEqual(try loggedLines(log), ["--install-extension|ms-vscode-remote.remote-ssh|"])
    }

    // Tests extension install surfaces a non-zero CLI exit as an error so the caller can report it.
    func testInstallRemoteSSHExtensionThrowsOnFailure() throws {
        let (cli, _) = try makeLoggingCLI(exitCode: 1)
        XCTAssertThrowsError(try EditorLauncher.installRemoteSSHExtension(cliExecutablePath: cli, extensionID: "x")) { error in
            XCTAssertTrue(error.localizedDescription.contains("failed"))
        }
    }

    /// Creates a temp executable that records its pipe-joined arguments to a log file and
    /// exits with `exitCode`, standing in for a real editor CLI without launching an app.
    private func makeLoggingCLI(exitCode: Int32 = 0) throws -> (path: String, log: URL) {
        let root = try makeTempDirectory()
        let log = root.appendingPathComponent("cli.log")
        let cli = root.appendingPathComponent("editor-cli")
        let script = """
            #!/bin/bash
            line=""
            for arg in "$@"; do line="${line}${arg}|"; done
            echo "$line" >> "\(log.path)"
            exit \(exitCode)
            """
        try script.write(to: cli, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)
        return (cli.path, log)
    }

    private func loggedLines(_ log: URL) throws -> [String] { try String(contentsOf: log).split(separator: "\n").map(String.init) }
}
