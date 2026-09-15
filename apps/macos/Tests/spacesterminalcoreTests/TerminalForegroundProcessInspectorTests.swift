import XCTest

@testable import spacesterminalcore

final class TerminalForegroundProcessInspectorTests: XCTestCase {
    func testClassifiesNativeCodexCommand() {
        let process = TerminalForegroundProcessSnapshot(
            pid: 100, executablePath: "/opt/homebrew/bin/codex", argv: ["/opt/homebrew/bin/codex", "--model", "gpt-5"])

        let detected = TerminalForegroundProcessInspector.classify(process)

        XCTAssertEqual(detected?.detectedAgentKind, .codex)
        XCTAssertEqual(detected?.displayLabel, "codex")
        XCTAssertEqual(detected?.displayCommand, "codex --model gpt-5")
    }

    func testClassifiesNodeWrappedCodexCommand() {
        let process = TerminalForegroundProcessSnapshot(
            pid: 101, executablePath: "/opt/homebrew/bin/node",
            argv: ["/opt/homebrew/bin/node", "/opt/homebrew/lib/node_modules/@openai/codex/bin/codex.js", "--ask-for-approval", "never"])

        let detected = TerminalForegroundProcessInspector.classify(process)

        XCTAssertEqual(detected?.detectedAgentKind, .codex)
        XCTAssertEqual(detected?.displayCommand, "codex --ask-for-approval never")
    }

    func testClassifiesNodeWrappedCodexCommandAfterNodeOptions() {
        let process = TerminalForegroundProcessSnapshot(
            pid: 101, executablePath: "/opt/homebrew/bin/node",
            argv: [
                "/opt/homebrew/bin/node", "--require", "source-map-support/register", "/opt/homebrew/lib/node_modules/@openai/codex/bin/codex.js",
                "--ask-for-approval", "never",
            ])

        let detected = TerminalForegroundProcessInspector.classify(process)

        XCTAssertEqual(detected?.detectedAgentKind, .codex)
        XCTAssertEqual(detected?.displayCommand, "codex --ask-for-approval never")
    }

    func testClassifiesClaudeCommands() {
        let claude = TerminalForegroundProcessSnapshot(pid: 102, executablePath: "/usr/local/bin/claude", argv: ["claude"])
        let claudeCode = TerminalForegroundProcessSnapshot(pid: 103, executablePath: "/usr/local/bin/claude-code", argv: ["claude-code", "resume"])

        XCTAssertEqual(TerminalForegroundProcessInspector.classify(claude)?.detectedAgentKind, .claude)
        XCTAssertEqual(TerminalForegroundProcessInspector.classify(claude)?.displayLabel, "claude")
        XCTAssertEqual(TerminalForegroundProcessInspector.classify(claudeCode)?.detectedAgentKind, .claudeCode)
        XCTAssertEqual(TerminalForegroundProcessInspector.classify(claudeCode)?.displayLabel, "claude-code")
        XCTAssertEqual(TerminalForegroundProcessInspector.classify(claudeCode)?.displayCommand, "claude-code resume")
    }

    func testClassifiesClaudeVersionedBinaryFromInvokedCommandName() {
        let process = TerminalForegroundProcessSnapshot(
            pid: 104, executablePath: "/fixtures/agents/claude/versions/2.1.168", argv: ["claude", "--dangerously-skip-permissions"])

        let detected = TerminalForegroundProcessInspector.classify(process)

        XCTAssertEqual(detected?.detectedAgentKind, .claude)
        XCTAssertEqual(detected?.displayCommand, "claude --dangerously-skip-permissions")
    }

    func testClassifiesLinuxClaudeVersionedBinaryFromProcArguments() {
        let argv = TerminalForegroundProcessInspector.procCmdlineArguments(from: Data("claude\0--dangerously-skip-permissions\0".utf8))
        let process = TerminalForegroundProcessSnapshot(pid: 104, executablePath: "/home/user/.local/share/claude/versions/2.1.168", argv: argv)

        let detected = TerminalForegroundProcessInspector.classify(process)

        XCTAssertEqual(detected?.detectedAgentKind, .claude)
        XCTAssertEqual(detected?.displayCommand, "claude --dangerously-skip-permissions")
    }

    func testParsesProcCmdlineArgumentsWithOrWithoutTrailingTerminator() {
        XCTAssertEqual(
            TerminalForegroundProcessInspector.procCmdlineArguments(from: Data("node\0/usr/lib/node_modules/@openai/codex/bin/codex.js\0".utf8)),
            ["node", "/usr/lib/node_modules/@openai/codex/bin/codex.js"])
        XCTAssertEqual(
            TerminalForegroundProcessInspector.procCmdlineArguments(from: Data("opencode\0run\0fix lint".utf8)), ["opencode", "run", "fix lint"])
    }

    /// An argument the user wrote as `""` is a word the agent was given: dropped, `claude --tools ""` would
    /// be rebuilt as `claude --tools`, which means something else. Only the empty span the trailing
    /// terminator produces is dropped.
    func testProcCmdlineArgumentsKeepEmptyArgumentsAndDropOnlyTheTrailingTerminator() {
        XCTAssertEqual(
            TerminalForegroundProcessInspector.procCmdlineArguments(from: Data("claude\0--tools\0\0--model\0opus\0".utf8)),
            ["claude", "--tools", "", "--model", "opus"])
        XCTAssertEqual(TerminalForegroundProcessInspector.procCmdlineArguments(from: Data("claude\0\0".utf8)), ["claude", ""])
    }

    // The macOS reader parses a `KERN_PROCARGS2` buffer; the Linux one parses `/proc/<pid>/cmdline`
    // above. This directory compiles on Linux too, where the macOS reader does not exist.
    #if os(macOS)
        /// `KERN_PROCARGS2` carries an `argc` int, the executable path, NUL padding, then exactly `argc`
        /// NUL-terminated argv strings, then the environment. Reading exactly `argc` strings after the padding
        /// keeps an empty argument the user wrote and never reads an environment variable as an argument: the
        /// padding is what a reader that skips runs of terminators would take the empty argument for.
        func testProcargs2ArgumentsKeepEmptyArgumentsAndStopAtTheEndOfArgv() {
            let padded = procargs2Buffer(
                executablePath: "/usr/local/bin/claude", paddingAfterExecutablePath: 7, argv: ["claude", "--tools", "", "--model", "opus"],
                environment: ["PATH=/usr/bin", "ANTHROPIC_API_KEY=secret"])
            let unpadded = procargs2Buffer(
                executablePath: "/usr/local/bin/claude", paddingAfterExecutablePath: 0, argv: ["claude", "--tools", ""],
                environment: ["PATH=/usr/bin"])

            XCTAssertEqual(
                TerminalForegroundProcessInspector.procargs2Arguments(from: padded, limit: padded.count),
                ["claude", "--tools", "", "--model", "opus"])
            XCTAssertEqual(TerminalForegroundProcessInspector.procargs2Arguments(from: unpadded, limit: unpadded.count), ["claude", "--tools", ""])
        }

        /// A `KERN_PROCARGS2` buffer laid out the way the kernel lays one out.
        private func procargs2Buffer(executablePath: String, paddingAfterExecutablePath: Int, argv: [String], environment: [String]) -> [CChar] {
            var bytes: [UInt8] = []
            withUnsafeBytes(of: Int32(argv.count)) { bytes.append(contentsOf: $0) }
            bytes.append(contentsOf: Array(executablePath.utf8))
            // The path's own terminator, then however much padding the kernel left before argv starts.
            bytes.append(contentsOf: Array(repeating: 0, count: paddingAfterExecutablePath + 1))
            for value in argv + environment {
                bytes.append(contentsOf: Array(value.utf8))
                bytes.append(0)
            }
            return bytes.map { CChar(bitPattern: $0) }
        }
    #endif

    func testClassifiesOpencodeCommands() {
        let opencode = TerminalForegroundProcessSnapshot(pid: 104, executablePath: "/usr/local/bin/opencode", argv: ["opencode", "run", "fix lint"])
        let npmOpencode = TerminalForegroundProcessSnapshot(
            pid: 105, executablePath: "/opt/homebrew/lib/node_modules/opencode-ai/bin/opencode.exe", argv: ["opencode", "tui"])

        XCTAssertEqual(TerminalForegroundProcessInspector.classify(opencode)?.detectedAgentKind, .opencode)
        XCTAssertEqual(TerminalForegroundProcessInspector.classify(opencode)?.displayLabel, "opencode")
        XCTAssertEqual(TerminalForegroundProcessInspector.classify(opencode)?.displayCommand, "opencode run 'fix lint'")
        XCTAssertEqual(TerminalForegroundProcessInspector.classify(npmOpencode)?.detectedAgentKind, .opencode)
        XCTAssertEqual(TerminalForegroundProcessInspector.classify(npmOpencode)?.displayCommand, "opencode tui")
    }

    func testDoesNotClassifyShellOrUnknownProcess() {
        let shell = TerminalForegroundProcessSnapshot(pid: 106, executablePath: "/bin/zsh", argv: ["zsh"])
        let unknown = TerminalForegroundProcessSnapshot(pid: 107, executablePath: "/usr/bin/vim", argv: ["vim", "README.md"])

        XCTAssertNil(TerminalForegroundProcessInspector.classify(shell))
        XCTAssertNil(TerminalForegroundProcessInspector.classify(unknown))
    }

    func testDoesNotClassifyAgentNamesInNonExecutableArguments() {
        let grep = TerminalForegroundProcessSnapshot(pid: 108, executablePath: "/usr/bin/grep", argv: ["grep", "codex", "README.md"])
        let editor = TerminalForegroundProcessSnapshot(pid: 109, executablePath: "/usr/bin/vim", argv: ["vim", "./claude-code"])

        XCTAssertNil(TerminalForegroundProcessInspector.classify(grep))
        XCTAssertNil(TerminalForegroundProcessInspector.classify(editor))
    }

    func testDoesNotClassifyAgentNamesInLaterNodeArguments() {
        let process = TerminalForegroundProcessSnapshot(
            pid: 110, executablePath: "/opt/homebrew/bin/node", argv: ["node", "/tmp/print-args.js", "codex", "claude"])

        XCTAssertNil(TerminalForegroundProcessInspector.classify(process))
    }

    func testDoesNotClassifyAgentNamesInNodeEvalCode() {
        let process = TerminalForegroundProcessSnapshot(pid: 111, executablePath: "/opt/homebrew/bin/node", argv: ["node", "-e", "codex"])

        XCTAssertNil(TerminalForegroundProcessInspector.classify(process))
    }

    func testDisplayCommandQuotesWhitespaceAndBoundsArguments() {
        let longArgument = String(repeating: "x", count: 180)
        let process = TerminalForegroundProcessSnapshot(
            pid: 112, executablePath: "/usr/local/bin/codex", argv: ["codex", "hello world", longArgument])

        let detected = TerminalForegroundProcessInspector.classify(process)

        XCTAssertEqual(detected?.displayCommand, "codex 'hello world' \(String(repeating: "x", count: 160))...")
    }

    // MARK: - agentCommand: the relaunchable command line

    /// The relaunch command keeps the executable the user typed: a bare word stays a bare word, and an
    /// absolute path stays that path. Rewriting the path to `claude` would relaunch whatever the login
    /// shell's PATH happens to resolve, or nothing at all, and the agent the user was running is the one
    /// that has to come back.
    func testAgentCommandKeepsTheExecutableTheAgentWasInvokedWith() throws {
        let bare = TerminalForegroundProcessSnapshot(pid: 200, executablePath: "/usr/local/bin/claude", argv: ["claude", "--model", "opus"])
        let absolute = TerminalForegroundProcessSnapshot(
            pid: 201, executablePath: "/opt/x/bin/claude", argv: ["/opt/x/bin/claude", "--model", "opus"])

        XCTAssertEqual(TerminalForegroundProcessInspector.classify(bare)?.agentCommand, "claude --model opus")
        let absoluteCommand = try XCTUnwrap(TerminalForegroundProcessInspector.classify(absolute)?.agentCommand)
        XCTAssertEqual(absoluteCommand, "/opt/x/bin/claude --model opus")
        XCTAssertEqual(CodingAgent.matching(command: absoluteCommand), .claudeCode, "a path resolves to its agent by basename")
        XCTAssertEqual(
            CodingAgent.resumeCommand(launchCommand: absoluteCommand, sessionKey: "abc"), "/opt/x/bin/claude --resume abc --model opus",
            "and resumes through that path rather than being handed back unchanged")
    }

    /// A node wrapper is the one invocation rewritten to the agent's own command name: its executable token
    /// is `node` and the agent is named by a script path further along, where the gate's scan cannot see it
    /// and Claude Code's `--resume <key>` splice cannot go.
    func testAgentCommandRewritesANodeWrapperToTheAgentsCommandName() throws {
        let codexWrapped = TerminalForegroundProcessSnapshot(
            pid: 202, executablePath: "/opt/homebrew/bin/node",
            argv: ["node", "/opt/homebrew/lib/node_modules/@openai/codex/bin/codex.js", "--ask-for-approval", "never"])
        let claudeWrapped = TerminalForegroundProcessSnapshot(
            pid: 207, executablePath: "/opt/homebrew/bin/node",
            argv: ["node", "/opt/homebrew/lib/node_modules/@anthropic-ai/claude-code/claude.js", "--model", "opus"])

        XCTAssertEqual(TerminalForegroundProcessInspector.classify(codexWrapped)?.agentCommand, "codex --ask-for-approval never")
        let claudeCommand = try XCTUnwrap(TerminalForegroundProcessInspector.classify(claudeWrapped)?.agentCommand)
        XCTAssertEqual(claudeCommand, "claude --model opus")
        XCTAssertEqual(CodingAgent.resumeCommand(launchCommand: claudeCommand, sessionKey: "abc"), "claude --resume abc --model opus")
    }

    /// A wrapper literally named `claude-code` is reported as the `claude-code` kind, shown under that
    /// name, and relaunched under it too: the shim is what is installed on this machine, and `claude` may
    /// resolve to something else or to nothing. The gate and the resume rewrite match the whole detection
    /// variant table, so the wrapper's command still resumes.
    func testAgentCommandKeepsAClaudeCodeWrapperName() throws {
        let process = TerminalForegroundProcessSnapshot(pid: 206, executablePath: "/opt/x/claude-code", argv: ["claude-code", "--model", "opus"])

        let detected = try XCTUnwrap(TerminalForegroundProcessInspector.classify(process))

        XCTAssertEqual(detected.detectedAgentKind, .claudeCode)
        XCTAssertEqual(detected.displayCommand, "claude-code --model opus")
        XCTAssertEqual(detected.agentCommand, "claude-code --model opus")
        XCTAssertEqual(CodingAgent.matching(command: detected.agentCommand), .claudeCode)
        XCTAssertEqual(CodingAgent.resumeCommand(launchCommand: detected.agentCommand, sessionKey: "abc"), "claude-code --resume abc --model opus")
    }

    /// Arguments are quoted the way a shell needs them back, so a prompt with spaces or quotes in it
    /// relaunches as the one argument the user passed rather than several.
    func testAgentCommandQuotesArgumentsSoTheRelaunchPassesThemWhole() throws {
        let process = TerminalForegroundProcessSnapshot(
            pid: 203, executablePath: "/usr/local/bin/claude", argv: ["claude", "fix the build", #"say "hello""#, "it's here"])

        let agentCommand = try XCTUnwrap(TerminalForegroundProcessInspector.classify(process)?.agentCommand)

        XCTAssertEqual(agentCommand, #"claude 'fix the build' 'say "hello"' 'it'\''s here'"#)
    }

    /// The relaunch is handed to an interactive login shell, so an argument carrying a substitution, a
    /// glob, a backtick, or a command separator has to arrive as the literal word the agent was given.
    /// Left bare, `$(rm -rf /)` would run before the agent ever saw it and `*.swift` would arrive as a list
    /// of file names. A word a shell has nothing to do with stays bare, so an ordinary command line reads
    /// the way the user typed it.
    func testAgentCommandQuotesEveryArgumentAShellWouldOtherwiseActOn() throws {
        let hostileArguments = ["$(rm -rf /)", "*.swift", "`id`", "$HOME", "a;b", "a|b", "a&b", "a>b", "~/notes", "it's"]
        let process = TerminalForegroundProcessSnapshot(
            pid: 205, executablePath: "/usr/local/bin/claude", argv: ["claude", "--dangerously-skip-permissions"] + hostileArguments)

        let agentCommand = try XCTUnwrap(TerminalForegroundProcessInspector.classify(process)?.agentCommand)

        XCTAssertEqual(
            agentCommand, #"claude --dangerously-skip-permissions '$(rm -rf /)' '*.swift' '`id`' '$HOME' 'a;b' 'a|b' 'a&b' 'a>b' '~/notes' 'it'\''s'"#
        )
        XCTAssertEqual(
            try shellWords(of: agentCommand), ["claude", "--dangerously-skip-permissions"] + hostileArguments,
            "a real shell hands the agent the arguments it was given, expanding and running nothing")
    }

    /// The relaunch command is built from the unbounded argv: a command bounded for display drops arguments
    /// past the sixteenth and truncates long ones, which would relaunch the agent with a mangled prompt. The
    /// display command alongside it stays bounded.
    func testAgentCommandIsNotBoundedWhileTheDisplayCommandStillIs() throws {
        let longArgument = String(repeating: "x", count: 400)
        let manyArguments = (1...20).map { "--flag\($0)" }
        let process = TerminalForegroundProcessSnapshot(
            pid: 204, executablePath: "/usr/local/bin/codex", argv: ["codex"] + manyArguments + [longArgument])

        let detected = try XCTUnwrap(TerminalForegroundProcessInspector.classify(process))

        XCTAssertEqual(detected.agentCommand, (["codex"] + manyArguments + [longArgument]).joined(separator: " "))
        XCTAssertTrue(detected.displayCommand.contains("..."), "the display command is still bounded: \(detected.displayCommand)")
    }

    /// A relaunch command quotes an executable whose path needs it, so the agent match has to read that
    /// token the way a shell does: the raw token's basename is `claude'`, which is in no variant table, and
    /// the agent would come back on a fresh conversation after the offer promised a resumed one.
    func testAgentCommandWithAQuotedExecutablePathStillResolvesToItsAgent() throws {
        let process = TerminalForegroundProcessSnapshot(
            pid: 208, executablePath: "/opt/My Tools/claude", argv: ["/opt/My Tools/claude", "--model", "opus"])

        let agentCommand = try XCTUnwrap(TerminalForegroundProcessInspector.classify(process)?.agentCommand)

        XCTAssertEqual(agentCommand, "'/opt/My Tools/claude' --model opus")
        XCTAssertEqual(CodingAgent.matching(command: agentCommand), .claudeCode)
        XCTAssertEqual(CodingAgent.resumeCommand(launchCommand: agentCommand, sessionKey: "abc"), "'/opt/My Tools/claude' --resume abc --model opus")
    }

    /// An empty argument is a word the agent was given, so it comes back as the empty word rather than
    /// disappearing: `claude --tools ""` relaunched as `claude --tools` hands the option the next word.
    func testAgentCommandKeepsAnEmptyArgumentTheAgentWasGiven() throws {
        let process = TerminalForegroundProcessSnapshot(
            pid: 209, executablePath: "/usr/local/bin/claude", argv: ["claude", "--tools", "", "--model", "opus"])

        let detected = try XCTUnwrap(TerminalForegroundProcessInspector.classify(process))

        XCTAssertEqual(detected.agentCommand, "claude --tools '' --model opus")
        XCTAssertEqual(detected.displayCommand, "claude --tools '' --model opus")
        XCTAssertEqual(
            CodingAgent.resumeCommand(launchCommand: detected.agentCommand, sessionKey: "abc"), "claude --resume abc --tools '' --model opus")
        XCTAssertEqual(
            try shellWords(of: detected.agentCommand), ["claude", "--tools", "", "--model", "opus"],
            "a real shell hands the agent the empty word back")
    }

    func testDisplayCommandUsesAlreadyInspectedGenericForegroundState() {
        XCTAssertEqual(
            TerminalForegroundProcessInspector.displayCommand(executableName: "/usr/bin/vim", argv: ["/usr/bin/vim", "README with spaces.md"]),
            "vim 'README with spaces.md'")
        XCTAssertEqual(TerminalForegroundProcessInspector.displayCommand(executableName: "/bin/zsh", argv: []), "zsh")
        XCTAssertNil(TerminalForegroundProcessInspector.displayCommand(executableName: nil, argv: nil))
    }

    func testWorkingDirectoryReadsLiveProcessCurrentDirectory() throws {
        // Anchor under /private/tmp so the kernel-reported cwd path matches exactly (the default
        // temporary directory lives under /var/folders, where /var is a symlink to /private/var).
        let directory = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let expectedPath = directory.path

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]
        process.currentDirectoryURL = directory
        try process.run()
        defer {
            process.terminate()
            process.waitUntilExit()
        }

        // The child chdir/execs asynchronously; poll briefly until the live cwd is observable.
        var observed: String?
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            observed = TerminalForegroundProcessInspector.workingDirectory(pid: process.processIdentifier)
            if observed != nil { break }
            Thread.sleep(forTimeInterval: 0.02)
        }
        XCTAssertEqual(observed, expectedPath)
    }

    func testWorkingDirectoryReturnsNilForDeadOrInvalidPid() throws {
        XCTAssertNil(TerminalForegroundProcessInspector.workingDirectory(pid: 0))
        XCTAssertNil(TerminalForegroundProcessInspector.workingDirectory(pid: -1))

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/echo")
        process.arguments = ["done"]
        try process.run()
        let pid = process.processIdentifier
        process.waitUntilExit()

        XCTAssertNil(TerminalForegroundProcessInspector.workingDirectory(pid: pid))
    }

    /// The child probe the conditional stop asks about a session's shell: a process holding a child
    /// answers yes, and a leaf process answers no. Both sides are read against live processes, since the
    /// whole point of the probe is that the OS knows what the shell's own argv cannot say.
    func testChildProcessProbeSeesLiveChildren() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]
        try process.run()
        defer {
            process.terminate()
            process.waitUntilExit()
        }

        var observed = false
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            observed = TerminalForegroundProcessInspector.hasChildProcesses(pid: getpid())
            if observed { break }
            Thread.sleep(forTimeInterval: 0.02)
        }
        XCTAssertTrue(observed)
        XCTAssertFalse(TerminalForegroundProcessInspector.hasChildProcesses(pid: process.processIdentifier))
        XCTAssertFalse(TerminalForegroundProcessInspector.hasChildProcesses(pid: 0))
    }

    /// Pins the executable-name semantics the inspector needs, rather than whatever `URL` happened to do
    /// with these shapes. `.` and `..` in particular must stay as they are: resolving them would name the
    /// daemon's own working directory, which has nothing to do with the process being inspected.
    func testExecutableNameIsTheTrailingPathComponent() {
        let cases: [(String, String)] = [
            ("/opt/homebrew/bin/codex", "codex"), ("codex", "codex"), ("/usr/bin/", "bin"), ("/usr/bin///", "bin"), ("/", ""), ("", ""), (".", "."),
            ("..", ".."), ("./codex", "codex"),
        ]
        for (path, expected) in cases { XCTAssertEqual(TerminalForegroundProcessInspector.lastPathComponent(of: path), expected, "path: \(path)") }
    }

    func testSnapshotDerivesExecutableNameFromThePathWithoutResolvingIt() {
        XCTAssertEqual(TerminalForegroundProcessSnapshot(pid: 1, executablePath: "/opt/homebrew/bin/opencode", argv: []).executableName, "opencode")
        XCTAssertEqual(TerminalForegroundProcessSnapshot(pid: 2, executablePath: nil, argv: ["/usr/bin/claude", "-p"]).executableName, "claude")
    }

    /// The resume rewrite compares each token of a launch command against option and subcommand names, so
    /// the token has to be read into the same word a shell hands the agent however the user quoted it.
    func testReadsATokenIntoTheWordAShellHandsOn() throws {
        for token in [#""--""#, #"'-p'"#, #"'exec'"#, #""claude""#, #""fix \"this\"""#, #"'/opt/My Tools/claude'"#, #"plain"#] {
            XCTAssertEqual(TerminalForegroundProcessInspector.posixUnquoted(token), try shellWords(of: token).first, token)
        }
    }

    /// The words a real shell parses `command` into. The relaunch runs through an interactive login shell,
    /// so this is the only assertion that speaks for what the agent actually receives: `printf` reports the
    /// arguments the shell passed on, NUL-separated because a word may contain anything else.
    private func shellWords(of command: String) throws -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "printf '%s\\0' \(command)"]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self).split(separator: "\0", omittingEmptySubsequences: false).dropLast().map(String.init)
    }
}
