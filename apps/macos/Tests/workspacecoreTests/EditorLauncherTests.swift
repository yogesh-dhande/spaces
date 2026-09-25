import Foundation
import XCTest

@testable import workspacecore

final class EditorLauncherTests: XCTestCase {
    func testOpenInvokesCLIWithDirectory() throws {
        let (cli, log) = try makeLoggingCLI()
        try EditorLauncher.open(cliExecutablePath: cli, directory: "/tmp/workspace")
        XCTAssertEqual(try loggedLines(log), ["/tmp/workspace|"])
    }

    func testOpenRemoteVSCodeBuildsFolderURI() throws {
        let (cli, log) = try makeLoggingCLI()
        try EditorLauncher.openRemoteVSCode(
            cliExecutablePath: cli, sshHost: "build.example", sshUser: "dev", sshPort: 2200, directory: "/srv/work space")
        XCTAssertEqual(try loggedLines(log), ["--folder-uri|vscode-remote://ssh-remote+dev@build.example:2200/srv/work%20space|"])
    }

    // A Zed remote open hands the CLI an ssh:// URL (Zed's built-in remoting) rather than a vscode-remote folder URI.
    func testOpenRemoteZedBuildsSSHURL() throws {
        let (cli, log) = try makeLoggingCLI()
        try EditorLauncher.openRemoteZed(
            cliExecutablePath: cli, sshHost: "build.example", sshUser: "dev", sshPort: 2200, directory: "/srv/work space")
        XCTAssertEqual(try loggedLines(log), ["ssh://dev@build.example:2200/srv/work%20space|"])
    }

    func testOpenRemoteOmitsMissingUserAndPort() throws {
        let (cli, log) = try makeLoggingCLI()
        try EditorLauncher.openRemoteVSCode(cliExecutablePath: cli, sshHost: "build.example", sshUser: nil, sshPort: nil, directory: "/srv/work")
        XCTAssertEqual(try loggedLines(log), ["--folder-uri|vscode-remote://ssh-remote+build.example/srv/work|"])
    }

    func testOpenRemoteThrowsWhenSSHHostMissing() throws {
        let (cli, _) = try makeLoggingCLI()
        XCTAssertThrowsError(
            try EditorLauncher.openRemoteVSCode(cliExecutablePath: cli, sshHost: "  ", sshUser: nil, sshPort: nil, directory: "/srv/work")
        ) { error in XCTAssertTrue(error.localizedDescription.contains("requires an SSH host")) }
    }

    func testInstallRemoteSSHExtensionInvokesCLI() throws {
        let (cli, log) = try makeLoggingCLI()
        try EditorLauncher.installRemoteSSHExtension(cliExecutablePath: cli, extensionID: "ms-vscode-remote.remote-ssh")
        XCTAssertEqual(try loggedLines(log), ["--install-extension|ms-vscode-remote.remote-ssh|"])
    }

    func testInstallRemoteSSHExtensionThrowsOnFailure() throws {
        let (cli, _) = try makeLoggingCLI(exitCode: 1)
        XCTAssertThrowsError(try EditorLauncher.installRemoteSSHExtension(cliExecutablePath: cli, extensionID: "x")) { error in
            XCTAssertTrue(error.localizedDescription.contains("failed"))
        }
    }

    // Leaking an ephemeral TMPDIR (e.g. a per-step harness temp) would break editors that write SSH
    // askpass scripts under TMPDIR, so a launch pins TMPDIR to the stable per-user temp instead.
    func testLaunchPinsStableTemporaryDirectory() throws {
        let root = try makeTempDirectory()
        let seen = root.appendingPathComponent("seen-tmpdir")
        let cli = root.appendingPathComponent("editor-cli")
        try "#!/bin/bash\nprintf '%s' \"${TMPDIR:-}\" > \"\(seen.path)\"\n".write(to: cli, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)

        let ephemeral = try makeTempDirectory().path
        let original = ProcessInfo.processInfo.environment["TMPDIR"]
        setenv("TMPDIR", ephemeral, 1)
        defer { if let original { setenv("TMPDIR", original, 1) } else { unsetenv("TMPDIR") } }

        try EditorLauncher.open(cliExecutablePath: cli.path, directory: "/tmp/workspace")
        let pinned = try String(contentsOf: seen)
        XCTAssertFalse(pinned.isEmpty)
        XCTAssertNotEqual(pinned, ephemeral, "editor launch must not propagate an ephemeral TMPDIR")
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
