import Foundation
import XCTest

@testable import spacesterminalcore

/// Runs the real wrapper and the real launch statements Spaces builds against real shells, in a temp
/// profile root and a fake HOME whose startup files prepend a fake version-manager directory holding a fake
/// `codex` (the way fnm's per-shell directory shadows a global install).
final class SpacesShellIntegrationTests: XCTestCase {
    private var sandbox: URL!
    private var home: URL!
    private var fnmBin: URL!
    private var integration: SpacesShellIntegration!

    override func setUpWithError() throws {
        // A space in the sandbox and profile paths exercises the quoting of every embedded absolute path.
        sandbox = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("spaces shell-\(UUID().uuidString)", isDirectory: true)
        home = sandbox.appendingPathComponent("home", isDirectory: true)
        fnmBin = home.appendingPathComponent("fnm/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: fnmBin, withIntermediateDirectories: true)
        try writeExecutable(
            "#!/bin/sh\necho \"real-codex:$#\"\nfor arg in \"$@\"; do echo \"arg:$arg\"; done\n", at: fnmBin.appendingPathComponent("codex"))
        integration = SpacesShellIntegration(profileRoot: sandbox.appendingPathComponent("profile dir", isDirectory: true).path)
        try integration.ensureInstalled()
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: sandbox) }

    // MARK: Wrapper

    func testWrapperAddsNoDaemonExactlyOnce() throws {
        let result = try runWrapper(arguments: ["resume", "abc"])
        XCTAssertEqual(result.args, ["--no-daemon", "resume", "abc"], "\(result)")
    }

    func testWrapperPassesThroughWithoutAnExtraFlag() throws {
        for arguments in [
            ["agents"], ["queue", "list"], ["--remote", "ws://host"], ["--remote=ws://host"], ["--no-daemon"], ["--no-daemon", "resume", "abc"],
            ["resume", "abc", "--no-daemon"],
        ] {
            let result = try runWrapper(arguments: arguments)
            XCTAssertEqual(result.args, arguments, "arguments \(arguments)")
        }
    }

    func testWrapperDoesNotPassThroughOnSubstringMatches() throws {
        let result = try runWrapper(arguments: ["fix the agents", "--remote-ish"])
        XCTAssertEqual(result.args, ["--no-daemon", "fix the agents", "--remote-ish"], "\(result)")
    }

    func testTwoWrapperDirectoriesDoNotLoop() throws {
        let other = SpacesShellIntegration(profileRoot: sandbox.appendingPathComponent("other profile", isDirectory: true).path)
        try other.ensureInstalled()
        for order in [[integration.binDirectory, other.binDirectory], [other.binDirectory, integration.binDirectory]] {
            let result = try runWrapper(arguments: ["x"], path: (order + [fnmBin.path, "/usr/bin", "/bin"]).joined(separator: ":"))
            XCTAssertEqual(result.args, ["--no-daemon", "x"], "\(result)")
        }
    }

    func testMissingCodexExits127() throws {
        let result = try runWrapper(arguments: ["x"], path: "\(integration.binDirectory):/usr/bin:/bin")
        XCTAssertEqual(result.status, 127)
        XCTAssertTrue(result.stderr.contains("codex: command not found"))
    }

    func testWrapperSkipsNonExecutableAndDirectoryCandidates() throws {
        let decoy = home.appendingPathComponent("decoy", isDirectory: true)
        try FileManager.default.createDirectory(at: decoy.appendingPathComponent("codex"), withIntermediateDirectories: true)
        let result = try runWrapper(arguments: ["x"], path: "\(integration.binDirectory):\(decoy.path):\(fnmBin.path):/usr/bin:/bin")
        XCTAssertEqual(result.args, ["--no-daemon", "x"], "\(result)")
    }

    func testWrapperTreatsAnEmptyPATHEntryAsTheCurrentDirectory() throws {
        // A trailing ":" is an empty entry: the current directory, which here holds the fake codex.
        let result = try runWrapper(arguments: ["x"], path: "\(integration.binDirectory):/usr/bin:", currentDirectory: fnmBin)
        XCTAssertEqual(result.args, ["--no-daemon", "x"], "\(result)")
    }

    func testWrapperDoesNotStayInTheProcessTree() throws {
        // The fake codex reports its parent's command: with exec the parent is this test process, not a wrapper script.
        try writeExecutable("#!/bin/sh\nps -o command= -p $PPID\n", at: fnmBin.appendingPathComponent("codex"))
        let result = try run(
            "/bin/sh", ["-c", "exec \"$1\" x", "sh", integration.wrapperPath], environment: baseEnvironment(path: "\(fnmBin.path):/usr/bin:/bin"))
        XCTAssertFalse(result.stdout.contains(integration.wrapperPath), result.stdout)
    }

    // MARK: Files

    func testInstallWritesWrapperMarkerAndIsRepeatable() throws {
        try integration.ensureInstalled()
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: integration.wrapperPath))
        let attributes = try FileManager.default.attributesOfItem(atPath: integration.wrapperPath)
        XCTAssertEqual(attributes[.posixPermissions] as? Int, 0o755)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: integration.markerPath)), Data())
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: integration.binDirectory).filter { $0.contains(".tmp-") }
        XCTAssertEqual(leftovers, [])
    }

    func testEnsureInstalledRecreatesMissingFilesAndLeavesIdenticalOnesUntouched() throws {
        let unchanged = try FileManager.default.attributesOfItem(atPath: integration.wrapperPath)
        try integration.ensureInstalled()
        let after = try FileManager.default.attributesOfItem(atPath: integration.wrapperPath)
        XCTAssertEqual(unchanged[.systemFileNumber] as? Int, after[.systemFileNumber] as? Int)

        try FileManager.default.removeItem(atPath: integration.rootDirectory)
        try integration.ensureInstalled()
        for path in [
            integration.wrapperPath, integration.markerPath, integration.bashScriptPath, integration.fishScriptPath,
            integration.zshDirectory + "/.zshenv",
        ] { XCTAssertTrue(FileManager.default.fileExists(atPath: path), path) }
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: integration.wrapperPath))

        try writeFile("stale", at: URL(fileURLWithPath: integration.bashScriptPath))
        try integration.ensureInstalled()
        XCTAssertNotEqual(try String(contentsOfFile: integration.bashScriptPath, encoding: .utf8), "stale")
    }

    func testPathRemovingWrapperDirectories() throws {
        let other = SpacesShellIntegration(profileRoot: sandbox.appendingPathComponent("other", isDirectory: true).path)
        try other.ensureInstalled()
        let path = "\(other.binDirectory):/usr/bin::\(integration.binDirectory):/bin:"
        XCTAssertEqual(SpacesShellIntegration.pathRemovingWrapperDirectories(path), "/usr/bin::/bin:")
        XCTAssertNil(SpacesShellIntegration.pathRemovingWrapperDirectories("/usr/bin:/bin"))
        XCTAssertNil(SpacesShellIntegration.pathRemovingWrapperDirectories(nil))
    }

    // MARK: Launch shapes

    func testBareShellsStillReadAsBareShells() {
        for (shell, name) in [("/bin/zsh", "zsh"), ("/usr/local/bin/bash", "bash"), ("/usr/bin/fish", "fish")] {
            let arguments = [name] + integration.bareShellLaunch(shellPath: shell).shellArguments
            XCTAssertTrue(TerminalBareShellForeground.isBareShell(executableName: name, argv: arguments, launchShell: shell), "\(arguments)")
        }
    }

    func testRestoredCodexCommandsKeepASingleNoDaemon() {
        let resumed = CodingAgent.resumeCommand(launchCommand: "codex --no-daemon", sessionKey: "abc")
        XCTAssertEqual(resumed, "codex resume abc --no-daemon")
        XCTAssertTrue(CodingAgent.launchIsOneShotJob(launchCommand: "codex --no-daemon exec fix"))
    }

    func testAppleBashGetsOnlyTheLaunchPathEntry() {
        #if canImport(Darwin)
            let launch = integration.bareShellLaunch(shellPath: "/bin/bash")
            XCTAssertEqual(launch.statements.count, 1)
            XCTAssertEqual(launch.shellArguments, ["-l"])
            XCTAssertNotNil(integration.commandPathPrelude(shellPath: "/bin/bash"))
        #endif
    }

    func testUnknownShellsGetOnlyTheLaunchPathEntry() {
        let launch = integration.bareShellLaunch(shellPath: "/usr/bin/dash")
        XCTAssertEqual(launch.statements, ["export PATH=\(SpacesShellIntegrationScripts.quoted(integration.binDirectory)):\"$PATH\""])
        XCTAssertNil(integration.commandPathPrelude(shellPath: "/usr/bin/dash"))
    }

    // MARK: Real shells, bare shell launch

    func testZshBareShellResolvesTheWrapperAfterStartupFiles() throws {
        let shell = try requireShell(["/bin/zsh", "/usr/bin/zsh"])
        try writeFile(prependFnm, at: home.appendingPathComponent(".zshrc"))
        let result = try runBareShell(shell, stdin: "command -v codex\ncodex hello\n")
        XCTAssertTrue(result.stdout.contains(integration.wrapperPath), result.stdout)
        XCTAssertEqual(result.args, ["--no-daemon", "hello"], "\(result)")
        XCTAssertFalse(result.stderr.contains("__spaces"), result.stderr)
    }

    func testBashBareShellResolvesTheWrapperAfterStartupFiles() throws {
        let shell = try requireInjectableBash()
        try writeFile(prependFnm, at: home.appendingPathComponent(".bash_profile"))
        let result = try runBareShell(shell, stdin: "command -v codex\ncodex hello\n")
        XCTAssertTrue(result.stdout.contains(integration.wrapperPath), result.stdout)
        XCTAssertEqual(result.args, ["--no-daemon", "hello"], "\(result)")
        XCTAssertFalse(result.stderr.contains("__spaces"), result.stderr)
    }

    func testFishBareShellResolvesTheWrapperAfterStartupFiles() throws {
        let shell = try requireShell(["/opt/homebrew/bin/fish", "/usr/local/bin/fish", "/usr/bin/fish", "/bin/fish"])
        try writeFile("set -gx PATH \(quotedFnm) $PATH\n", at: home.appendingPathComponent(".config/fish/config.fish"))
        let result = try runBareShell(shell, stdin: "command -v codex\ncodex hello\n")
        XCTAssertTrue(result.stdout.contains(integration.wrapperPath), result.stdout)
        XCTAssertEqual(result.args, ["--no-daemon", "hello"], "\(result)")
    }

    func testAppleBashBareShellResolvesTheWrapperFromTheLaunchPathEntry() throws {
        #if canImport(Darwin)
            let shell = try requireShell(["/bin/bash"])
            // Only the launch-time entry exists; the real codex is found behind it.
            try writeFile("export PATH=\"$PATH\":\(quotedFnm)\n", at: home.appendingPathComponent(".bash_profile"))
            let result = try runBareShell(shell, stdin: "codex hello\n")
            XCTAssertEqual(result.args, ["--no-daemon", "hello"], "\(result)")
        #else
            throw XCTSkip("Apple's bash is macOS only")
        #endif
    }

    func testZshRestoresTheUsersZDOTDIR() throws {
        let shell = try requireShell(["/bin/zsh", "/usr/bin/zsh"])
        let userDotDir = home.appendingPathComponent("zdot", isDirectory: true)
        try writeFile("export USER_ZSHENV_RAN=1\n", at: userDotDir.appendingPathComponent(".zshenv"))
        try writeFile(prependFnm, at: userDotDir.appendingPathComponent(".zshrc"))
        let probe = "echo \"zdotdir=${ZDOTDIR-UNSET}\"\necho \"envzdot=$(/usr/bin/env | /usr/bin/grep -c '^ZDOTDIR=')\"\n"
        let leftovers = "echo \"leftovers=$(/usr/bin/env | /usr/bin/grep -c '^SPACES_USER_')\"\ncodex hi\n"

        let withUser = try runBareShell(
            shell, stdin: probe + "echo \"ran=$USER_ZSHENV_RAN\"\n" + leftovers, extraEnvironment: ["ZDOTDIR": userDotDir.path])
        XCTAssertTrue(withUser.stdout.contains("zdotdir=\(userDotDir.path)"), withUser.stdout)
        XCTAssertTrue(withUser.stdout.contains("ran=1"), withUser.stdout)
        XCTAssertTrue(withUser.stdout.contains("leftovers=0"), withUser.stdout)
        XCTAssertEqual(withUser.args, ["--no-daemon", "hi"], "\(withUser)")

        try writeFile(prependFnm, at: home.appendingPathComponent(".zshrc"))
        let unset = try runBareShell(shell, stdin: probe + leftovers)
        XCTAssertTrue(unset.stdout.contains("zdotdir=UNSET"), unset.stdout)
        XCTAssertTrue(unset.stdout.contains("envzdot=0"), unset.stdout)
        XCTAssertTrue(unset.stdout.contains("leftovers=0"), unset.stdout)
        XCTAssertEqual(unset.args, ["--no-daemon", "hi"], "\(unset)")
    }

    func testBashRestoresTheUsersENV() throws {
        let shell = try requireInjectableBash()
        try writeFile(prependFnm, at: home.appendingPathComponent(".bash_profile"))
        let probe = "echo \"env=${ENV-UNSET}\"\necho \"leftovers=$(/usr/bin/env | /usr/bin/grep -c '^SPACES_USER_')\"\n"

        let withUser = try runBareShell(shell, stdin: probe, extraEnvironment: ["ENV": "/users/own-env-file"])
        XCTAssertTrue(withUser.stdout.contains("env=/users/own-env-file"), withUser.stdout)
        XCTAssertTrue(withUser.stdout.contains("leftovers=0"), withUser.stdout)

        let unset = try runBareShell(shell, stdin: probe)
        XCTAssertTrue(unset.stdout.contains("env=UNSET"), unset.stdout)
        XCTAssertTrue(unset.stdout.contains("leftovers=0"), unset.stdout)
    }

    func testFishRestoresTheUsersXDGDataDirs() throws {
        let shell = try requireShell(["/opt/homebrew/bin/fish", "/usr/local/bin/fish", "/usr/bin/fish", "/bin/fish"])
        let probe =
            "set -q XDG_DATA_DIRS; and echo \"xdg=$XDG_DATA_DIRS\"; or echo xdg=UNSET\nset -q SPACES_USER_XDG_DATA_DIRS; and echo leftover; or echo clean\n"
        let withUser = try runBareShell(shell, stdin: probe, extraEnvironment: ["XDG_DATA_DIRS": "/users/share"])
        XCTAssertTrue(withUser.stdout.contains("xdg=/users/share"), withUser.stdout)
        XCTAssertTrue(withUser.stdout.contains("clean"), withUser.stdout)
        let unset = try runBareShell(shell, stdin: probe)
        XCTAssertTrue(unset.stdout.contains("xdg=UNSET"), unset.stdout)
        XCTAssertTrue(unset.stdout.contains("clean"), unset.stdout)
    }

    func testZshPromptHookPreservesTheLastStatus() throws {
        let shell = try requireShell(["/bin/zsh", "/usr/bin/zsh"])
        try writeFile(prependFnm + "PS1='PROMPT_STATUS=%?;'\n", at: home.appendingPathComponent(".zshrc"))
        let result = try runBareShell(shell, stdin: "false\ntrue\nfalse\n")
        XCTAssertTrue(result.stderr.contains("PROMPT_STATUS=1;"), result.stderr)
        XCTAssertFalse(result.stderr.contains("__spaces"), result.stderr)
    }

    func testBashPromptHookPreservesTheLastStatus() throws {
        let shell = try requireInjectableBash()
        try writeFile(prependFnm + "PS1='PROMPT_STATUS=$?;'\n", at: home.appendingPathComponent(".bash_profile"))
        let result = try runBareShell(shell, stdin: "false\ntrue\nfalse\n")
        XCTAssertTrue(result.stderr.contains("PROMPT_STATUS=1;"), result.stderr)
        XCTAssertFalse(result.stderr.contains("__spaces"), result.stderr)
    }

    func testZshHookWinsOverAHookThatPrependsLater() throws {
        let shell = try requireShell(["/bin/zsh", "/usr/bin/zsh"])
        try writeFile(
            prependFnm + "prepend_node() { path=(\(quotedFnm) $path) }\nprecmd_functions+=(prepend_node)\n", at: home.appendingPathComponent(".zshrc")
        )
        let result = try runBareShell(shell, stdin: "command -v codex\n")
        XCTAssertTrue(result.stdout.contains(integration.wrapperPath), result.stdout)
    }

    // MARK: Real shells, command launch

    func testCommandLaunchResolvesTheWrapperForEachShell() throws {
        var ran = 0
        for candidates in [
            ["/bin/zsh", "/usr/bin/zsh"], ["/bin/bash", "/usr/bin/bash", "/usr/local/bin/bash", "/opt/homebrew/bin/bash"], fishCandidates,
        ] {
            guard let shell = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { continue }
            let name = URL(fileURLWithPath: shell).lastPathComponent
            let rc: URL
            let line: String
            switch name {
            case "zsh": (rc, line) = (home.appendingPathComponent(".zshrc"), prependFnm)
            case "bash": (rc, line) = (home.appendingPathComponent(".bash_profile"), prependFnm)
            default: (rc, line) = (home.appendingPathComponent(".config/fish/config.fish"), "set -gx PATH \(quotedFnm) $PATH\n")
            }
            try writeFile(line, at: rc)
            let result = try runCommandLaunch(shell, command: "command -v codex; codex one two")
            XCTAssertTrue(result.stdout.contains(integration.wrapperPath), "\(shell): \(result.stdout)\n\(result.stderr)")
            XCTAssertEqual(result.args, ["--no-daemon", "one", "two"], "\(shell): \(result)")
            ran += 1
        }
        if ran == 0 { throw XCTSkip("no zsh, bash or fish available") }
    }

    // MARK: Harness

    private var quotedFnm: String { SpacesShellIntegrationScripts.quoted(fnmBin.path) }
    /// What a version manager's rc line does: puts its per-shell directory (holding the real `codex`) first.
    private var prependFnm: String { "export PATH=\(quotedFnm):\"$PATH\"\n" }

    private var fishCandidates: [String] { ["/opt/homebrew/bin/fish", "/usr/local/bin/fish", "/usr/bin/fish", "/bin/fish"] }

    private struct Result {
        let stdout: String
        let stderr: String
        let status: Int32
        /// The arguments the fake real codex received (lines `arg:<value>`).
        var args: [String] { stdout.split(separator: "\n").compactMap { $0.hasPrefix("arg:") ? String($0.dropFirst(4)) : nil } }
    }

    private func requireShell(_ candidates: [String]) throws -> String {
        guard let shell = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw XCTSkip("none of \(candidates) is installed")
        }
        return shell
    }

    private func requireInjectableBash() throws -> String {
        let candidates = ["/opt/homebrew/bin/bash", "/usr/local/bin/bash", "/usr/bin/bash", "/bin/bash"].filter {
            FileManager.default.isExecutableFile(atPath: $0) && SpacesShellIntegration.bashSupportsStartupInjection(shellPath: $0)
        }
        guard let shell = candidates.first else { throw XCTSkip("no bash that accepts startup injection (Apple's /bin/bash does not)") }
        return shell
    }

    private func baseEnvironment(path: String, extra: [String: String] = [:]) -> [String: String] {
        var environment = ["HOME": home.path, "PATH": path, "TERM": "dumb", "SHELL": "/bin/sh", "LANG": "C"]
        environment.merge(extra) { _, new in new }
        return environment
    }

    private func runWrapper(arguments: [String], path: String? = nil, currentDirectory: URL? = nil) throws -> Result {
        let path = path ?? "\(integration.binDirectory):\(fnmBin.path):/usr/bin:/bin"
        return try run(integration.wrapperPath, arguments, environment: baseEnvironment(path: path), currentDirectory: currentDirectory)
    }

    /// The launch Spaces builds for a bare shell, driven the way the PTY driver drives it (`<shell> -l -c
    /// '<statements>; exec <shell> ...'`). `-i` is added to the exec'd shell because the test has no
    /// terminal to make it interactive.
    private func runBareShell(_ shell: String, stdin: String, extraEnvironment: [String: String] = [:]) throws -> Result {
        let launch = integration.bareShellLaunch(shellPath: shell)
        let exec = "exec \(SpacesShellIntegrationScripts.quoted(shell)) \((launch.shellArguments + ["-i"]).joined(separator: " "))"
        let command = (launch.statements + [exec]).joined(separator: "; ")
        return try run(shell, ["-l", "-c", command], environment: baseEnvironment(path: "/usr/bin:/bin", extra: extraEnvironment), stdin: stdin)
    }

    private func runCommandLaunch(_ shell: String, command: String) throws -> Result {
        let inner = integration.commandPathPrelude(shellPath: shell).map { "\($0); \(command)" } ?? command
        let exec = "exec \(SpacesShellIntegrationScripts.quoted(shell)) -l -i -c \(SpacesShellIntegrationScripts.quoted(inner))"
        let launch = (integration.commandLaunchStatements(shellPath: shell) + [exec]).joined(separator: "; ")
        return try run(shell, ["-l", "-c", launch], environment: baseEnvironment(path: "/usr/bin:/bin"))
    }

    private func run(_ executable: String, _ arguments: [String], environment: [String: String], stdin: String = "", currentDirectory: URL? = nil)
        throws -> Result
    {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = currentDirectory ?? home
        let stdoutURL = sandbox.appendingPathComponent("out-\(UUID().uuidString)")
        let stderrURL = sandbox.appendingPathComponent("err-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: stdoutURL.path, contents: nil)
        FileManager.default.createFile(atPath: stderrURL.path, contents: nil)
        process.standardOutput = try FileHandle(forWritingTo: stdoutURL)
        process.standardError = try FileHandle(forWritingTo: stderrURL)
        let input = Pipe()
        process.standardInput = input
        try process.run()
        input.fileHandleForWriting.write(Data(stdin.utf8))
        try input.fileHandleForWriting.close()
        // Two wrappers exec'ing each other would never exit; fail instead of hanging the suite.
        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 30, execute: watchdog)
        process.waitUntilExit()
        watchdog.cancel()
        XCTAssertNotEqual(process.terminationReason, .uncaughtSignal, "\(executable) \(arguments) was killed")
        return Result(
            stdout: (try? String(contentsOf: stdoutURL, encoding: .utf8)) ?? "", stderr: (try? String(contentsOf: stderrURL, encoding: .utf8)) ?? "",
            status: process.terminationStatus)
    }

    private func writeExecutable(_ contents: String, at url: URL) throws {
        try writeFile(contents, at: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private func writeFile(_ contents: String, at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }
}
