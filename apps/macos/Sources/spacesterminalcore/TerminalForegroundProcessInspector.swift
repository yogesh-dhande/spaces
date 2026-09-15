import Foundation

#if os(macOS)
    import Darwin
#endif

public struct TerminalForegroundProcessSnapshot: Codable, Sendable, Equatable {
    public let pid: Int32
    public let executablePath: String?
    public let executableName: String
    /// The process's arguments bounded for display (see `TerminalForegroundProcessInspector.boundedArguments`):
    /// this is what every reader that shows a command to a person reads, and what the runtime row stores.
    public let argv: [String]
    /// The same arguments exactly as the OS reported them. Only the relaunch command is built from these
    /// (`TerminalForegroundAgentSnapshot.agentCommand`): a bounded argv drops arguments past the sixteenth
    /// and truncates long ones, which is right for a label and wrong for a command line another process
    /// has to run.
    public let fullArgv: [String]

    public init(pid: Int32, executablePath: String?, executableName: String? = nil, argv: [String]) {
        self.pid = pid
        self.executablePath = executablePath
        self.executableName =
            executableName?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? executablePath.flatMap(Self.basename) ?? argv.first.flatMap(
                Self.basename) ?? ""
        self.argv = TerminalForegroundProcessInspector.boundedArguments(argv)
        self.fullArgv = argv
    }

    private static func basename(_ value: String) -> String? {
        TerminalForegroundProcessInspector.lastPathComponent(of: value.trimmingCharacters(in: .whitespacesAndNewlines)).nilIfEmpty
    }
}

public struct TerminalForegroundAgentSnapshot: Codable, Sendable, Equatable {
    public let process: TerminalForegroundProcessSnapshot
    public let detectedAgentKind: TerminalDetectedAgentKind
    public let displayLabel: String
    public let displayCommand: String
    /// A shell command line that relaunches this agent: the executable token it was invoked with followed
    /// by every argument after that token, each POSIX-quoted so the shell that runs the relaunch passes it
    /// on as the literal word the agent was given (see `posixQuoted`). Built from the unbounded argv, unlike
    /// `displayCommand`, because this string is run rather than read.
    ///
    /// The executable is kept as the user typed it (a bare `claude`, an absolute path, a `claude-code`
    /// wrapper), and only a `node .../cli.js` invocation is rewritten to the agent's canonical command
    /// name (see `relaunchExecutableToken`).
    public let agentCommand: String

    public init(
        process: TerminalForegroundProcessSnapshot, detectedAgentKind: TerminalDetectedAgentKind, displayLabel: String, displayCommand: String,
        agentCommand: String
    ) {
        self.process = process
        self.detectedAgentKind = detectedAgentKind
        self.displayLabel = displayLabel
        self.displayCommand = displayCommand
        self.agentCommand = agentCommand
    }
}

public enum TerminalForegroundProcessInspector {
    private struct CommandNameCandidate {
        let name: String
        let matchedArgumentIndex: Int?
    }

    private static let maxArgumentCount = 16
    private static let maxArgumentLength = 160
    private static let nodeExecutableNames: Set<String> = ["node", "nodejs"]
    // Derived from the coding-agent registry (`CodingAgent`) rather than hard-coded here, so a new
    // registry entry's detection variants are picked up automatically. Order matters only in that
    // the more specific `claude-code` variant is listed before the broader `claude` variant within
    // `.claudeCode` — see `CodingAgent.detectionVariants`; matching itself is disjoint-set membership,
    // so ordering across agents does not matter.
    private static let definitions: [CodingAgentDetectionVariant] = CodingAgent.allCases.flatMap(\.detectionVariants)

    public static func inspect(pid: Int32) -> TerminalForegroundProcessSnapshot? {
        guard pid > 0 else { return nil }
        #if os(macOS)
            let executablePath = processExecutablePath(pid: pid)
            let argv = processArguments(pid: pid)
            let executableName = executablePath.flatMap { Self.lastPathComponent(of: $0).nilIfEmpty }
            guard executableName != nil || !argv.isEmpty else { return nil }
            return TerminalForegroundProcessSnapshot(pid: pid, executablePath: executablePath, executableName: executableName, argv: argv)
        #elseif os(Linux)
            let executablePath = processExecutablePath(pid: pid)
            let argv = processArguments(pid: pid)
            let executableName = executablePath.flatMap { Self.lastPathComponent(of: $0).nilIfEmpty }
            guard executableName != nil || !argv.isEmpty else { return nil }
            return TerminalForegroundProcessSnapshot(pid: pid, executablePath: executablePath, executableName: executableName, argv: argv)
        #else
            return nil
        #endif
    }

    /// Whether `pid` has at least one child process right now, read live from the OS.
    ///
    /// The conditional stop of a user-closed ad hoc terminal asks this about the session's shell: a shell
    /// holding background or stopped jobs, or waiting on one, is the tty's foreground process with the
    /// same argv it has at an idle prompt, so its own foreground sample cannot tell the two apart. Work
    /// the shell holds shows up as a child.
    public static func hasChildProcesses(pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        #if os(macOS)
            // A one-pid buffer is enough for a yes/no: the call reports what it found, and a NULL buffer
            // would answer with a system-wide size estimate instead of this pid's children.
            var childPID: pid_t = 0
            let found = withUnsafeMutablePointer(to: &childPID) { proc_listchildpids(pid, $0, Int32(MemoryLayout<pid_t>.size)) }
            return found > 0
        #elseif os(Linux)
            // Children are per-thread, so every thread of the process has to be asked. The `children` file
            // needs CONFIG_PROC_CHILDREN; a kernel without it makes every read fail. Alive but unanswerable
            // presumes children, so a kernel without CONFIG_PROC_CHILDREN degrades to keeping sessions,
            // never to killing jobs; only a genuinely empty read counts as "no children".
            let taskDirectory = URL(fileURLWithPath: "/proc/\(pid)/task", isDirectory: true)
            guard let taskURLs = try? FileManager.default.contentsOfDirectory(at: taskDirectory, includingPropertiesForKeys: nil), !taskURLs.isEmpty
            else { return false }
            var anyChildrenFileRead = false
            for taskURL in taskURLs {
                guard let children = try? String(contentsOf: taskURL.appendingPathComponent("children"), encoding: .utf8) else { continue }
                anyChildrenFileRead = true
                if children.contains(where: { !$0.isWhitespace }) { return true }
            }
            return !anyChildrenFileRead
        #else
            return false
        #endif
    }

    public static func detectedAgent(pid: Int32) -> TerminalForegroundAgentSnapshot? {
        guard let process = inspect(pid: pid) else { return nil }
        return classify(process)
    }

    /// The current working directory of `pid`'s process, read live from the OS.
    ///
    /// The daemon consults this at terminal-link resolve time (and when publishing session runtime
    /// state) because the tracked working directory only advances when the shell reports a new PWD
    /// through Ghostty shell integration (OSC 7), which many shells — including a plain zsh — never
    /// emit. That leaves the tracked value pinned to the launch directory after a `cd`, so relative
    /// links anchor in the wrong place. The owning process's real cwd is always current. Returns nil
    /// on any failure (invalid/dead pid, permission, or an unreadable path).
    public static func workingDirectory(pid: Int32) -> String? {
        guard pid > 0 else { return nil }
        #if os(macOS)
            var info = proc_vnodepathinfo()
            let expectedSize = Int32(MemoryLayout<proc_vnodepathinfo>.size)
            let returnedSize = withUnsafeMutablePointer(to: &info) { pointer in proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, pointer, expectedSize) }
            guard returnedSize == expectedSize else { return nil }
            let capacity = MemoryLayout.size(ofValue: info.pvi_cdir.vip_path)
            let path = withUnsafePointer(to: &info.pvi_cdir.vip_path) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { String(cString: $0) }
            }
            return path.nilIfEmpty
        #elseif os(Linux)
            return (try? FileManager.default.destinationOfSymbolicLink(atPath: "/proc/\(pid)/cwd"))?.nilIfEmpty
        #else
            return nil
        #endif
    }

    public static func classify(_ process: TerminalForegroundProcessSnapshot) -> TerminalForegroundAgentSnapshot? {
        // Matching runs on the unbounded argv so the matched index addresses the same argument in both
        // command builds below; bounding only ever drops arguments the executable token sits ahead of.
        let argv = process.fullArgv
        let commandNameCandidates = commandNameCandidates(executableName: process.executableName, argv: argv)

        for definition in definitions {
            if let candidate = commandNameCandidates.first(where: { definition.executableNames.contains($0.name) }) {
                return snapshot(for: process, definition: definition, matchedArgumentIndex: candidate.matchedArgumentIndex)
            }
        }

        guard commandNameCandidates.contains(where: { nodeExecutableNames.contains($0.name) }) else { return nil }
        guard let scriptIndex = nodeScriptArgumentIndex(in: argv) else { return nil }
        for definition in definitions {
            if matchesNodeScript(argv[scriptIndex], definition: definition) {
                return snapshot(for: process, definition: definition, matchedArgumentIndex: scriptIndex)
            }
        }
        return nil
    }

    public static func boundedArguments(_ argv: [String]) -> [String] {
        var bounded = argv.prefix(maxArgumentCount).map { argument -> String in
            if argument.count <= maxArgumentLength { return argument }
            return "\(argument.prefix(maxArgumentLength))..."
        }
        if argv.count > maxArgumentCount { bounded.append("...") }
        return Array(bounded)
    }

    /// A compact command line for an already-inspected foreground process. This performs no process
    /// inspection: callers pass the bounded argv/executable name already stored in terminal runtime
    /// state. The executable is rendered by basename and arguments use the same quoting as detected-agent
    /// commands so UI consumers never need to reconstruct a command independently.
    public static func displayCommand(executableName: String?, argv: [String]?) -> String? {
        var arguments = boundedArguments(argv ?? [])
        if !arguments.isEmpty {
            if let invokedName = lastPathComponent(of: arguments[0]).nilIfEmpty { arguments[0] = invokedName }
            return arguments.map(renderArgument).joined(separator: " ")
        }
        guard let executableName = executableName?.trimmingCharacters(in: .whitespacesAndNewlines), !executableName.isEmpty else { return nil }
        return lastPathComponent(of: executableName).nilIfEmpty
    }

    /// The argv a `/proc/<pid>/cmdline` read carries: the arguments NUL-separated, with a terminator after
    /// the last one. Every span between terminators is an argument, an empty one included (`claude --tools
    /// ""`), and only the empty span the trailing terminator produces is dropped.
    static func procCmdlineArguments(from data: Data) -> [String] {
        guard !data.isEmpty else { return [] }
        var arguments: [String] = []
        var start = data.startIndex
        var index = start
        while index < data.endIndex {
            if data[index] == 0 {
                appendProcArgument(data[start..<index], to: &arguments)
                start = data.index(after: index)
            }
            index = data.index(after: index)
        }
        // A read the kernel truncated ends without a terminator and still carries a last argument.
        if start < data.endIndex { appendProcArgument(data[start..<data.endIndex], to: &arguments) }
        return arguments
    }

    private static func commandNameCandidates(executableName: String, argv: [String]) -> [CommandNameCandidate] {
        var candidates: [CommandNameCandidate] = []
        let executableBasename = normalizedBasename(executableName)
        if !executableBasename.isEmpty {
            candidates.append(
                CommandNameCandidate(name: executableBasename, matchedArgumentIndex: executableArgumentIndex(in: argv, matching: executableBasename)))
        }

        // Some native tools run a versioned binary while preserving the user-facing
        // command in argv[0]. Treat argv[0] as process identity, but never scan later arguments.
        if let firstArgument = argv.first {
            let invokedName = normalizedBasename(firstArgument)
            if !invokedName.isEmpty, !candidates.contains(where: { $0.name == invokedName }) {
                candidates.append(CommandNameCandidate(name: invokedName, matchedArgumentIndex: 0))
            }
        }
        return candidates
    }

    private static func snapshot(for process: TerminalForegroundProcessSnapshot, definition: CodingAgentDetectionVariant, matchedArgumentIndex: Int?)
        -> TerminalForegroundAgentSnapshot
    {
        TerminalForegroundAgentSnapshot(
            process: process, detectedAgentKind: definition.kind, displayLabel: definition.displayLabel,
            displayCommand: command(
                arguments: boundedArguments(process.argv), commandName: definition.commandName, matchedArgumentIndex: matchedArgumentIndex,
                render: renderArgument),
            // Inline environment assignments typed before the command (`CODEX_HOME=/custom codex`,
            // `ANTHROPIC_API_KEY=... claude`) are not part of this command: the shell consumes them into
            // the child's environment, so they are nowhere in argv and a relaunch comes back without them.
            // Recovering them would mean reading and persisting the child's whole environment, which holds
            // the user's secrets, and diffing it against the shell's to tell an assignment typed on the
            // line from a variable the shell already exported. Accepted rather than paid for.
            agentCommand: command(
                arguments: process.fullArgv, commandName: relaunchExecutableToken(for: process, definition: definition),
                matchedArgumentIndex: matchedArgumentIndex, render: posixQuoted))
    }

    /// The executable token a relaunch leads with, already quoted for the shell that runs it.
    ///
    /// It is `argv[0]` exactly as the agent was invoked whenever that word's basename is one of the owning
    /// agent's detection variant executable names, because that word is what actually starts the agent on
    /// this machine: an absolute path (`/opt/x/bin/claude`) and a wrapper named `claude-code` both name an
    /// executable the relaunch's login shell may not find under any other spelling, and a relaunch is
    /// worth nothing if it does not run. `CodingAgent.matching(command:)` matches the same variant names,
    /// so a token kept as typed still resolves to its agent for the spawn gate and the resume rewrite.
    ///
    /// A node wrapper (`node .../cli.js ...`) is the one shape rewritten to the agent's canonical command
    /// name: its executable token is `node` and the agent is named by a script path further along, where
    /// neither the gate's scan nor the resume rewrite's splice can reach: Claude Code's `--resume <key>`
    /// goes immediately after the executable token, which would put it before the script. A hand-typed
    /// node invocation is rare enough to pay for that, and the rewritten command runs the agent the user
    /// was using.
    private static func relaunchExecutableToken(for process: TerminalForegroundProcessSnapshot, definition: CodingAgentDetectionVariant) -> String {
        let agent = definition.kind.agent
        guard let invoked = process.fullArgv.first,
            agent.detectionVariants.contains(where: { $0.executableNames.contains(normalizedBasename(invoked)) })
        else { return agent.primaryCommandName }
        return posixQuoted(invoked)
    }

    /// `commandName` followed by everything after the executable token (after the script token for a node
    /// wrapper). Fed the bounded argv, the display rendering, and the observed variant's name it is a
    /// label; fed the unbounded argv, POSIX quoting, and the token the agent was invoked with it is a
    /// runnable command line. The two are built the same way so what the user is shown and what a relaunch
    /// runs can only differ in that leading token, in quoting, and in where bounding trimmed.
    private static func command(arguments: [String], commandName: String, matchedArgumentIndex: Int?, render: (String) -> String) -> String {
        let trailingArguments: ArraySlice<String>
        if let matchedArgumentIndex, matchedArgumentIndex < arguments.count {
            trailingArguments = arguments.dropFirst(matchedArgumentIndex + 1)
        } else if !arguments.isEmpty {
            trailingArguments = arguments.dropFirst()
        } else {
            trailingArguments = []
        }
        return ([commandName] + trailingArguments.map(render)).joined(separator: " ")
    }

    /// Quoting for a command a person reads: only an argument that would visibly run together with its
    /// neighbours is quoted, so a label stays as close to what the user typed as it can.
    private static func renderArgument(_ argument: String) -> String {
        guard !argument.isEmpty else { return "''" }
        let needsQuoting = argument.rangeOfCharacter(from: .whitespacesAndNewlines) != nil || argument.contains("'") || argument.contains("\"")
        guard needsQuoting else { return argument }
        return "'\(argument.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    /// Quoting for a command a shell runs. A relaunch is handed to an interactive login shell, so every
    /// argument that is not plainly inert has to come back as the single literal word the agent was given:
    /// left bare, an argument carrying `$(...)`, a backtick, a glob, or a `;`/`|`/`&`/`>` would be expanded
    /// or executed rather than passed on. Only characters no shell treats specially stay unquoted;
    /// everything else is wrapped in single quotes, which suppress every expansion, with an embedded single
    /// quote spliced back in as `'\''` (close, escaped quote, reopen) since single quotes cannot nest.
    private static func posixQuoted(_ argument: String) -> String {
        guard !argument.isEmpty else { return "''" }
        guard argument.unicodeScalars.contains(where: { !shellSafeArgumentScalars.contains($0) }) else { return argument }
        return "'\(argument.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    /// The inverse of `posixQuoted`: the literal word a shell hands on for a token quoted that way.
    ///
    /// `CodingAgent.matching(command:)` reads a relaunch command's executable token through this before
    /// taking its basename, because that token is quoted whenever the path the agent was invoked with
    /// needs it: the basename of the raw token `'/opt/My Tools/claude'` is `claude'`, which matches no
    /// agent, and the restore would then bring the agent back on a fresh conversation. Single quotes are
    /// dropped and the `'\''` splice `posixQuoted` writes for an embedded quote reads back as that quote,
    /// so the two stay exact inverses of each other.
    ///
    /// Double quotes are read the same way a shell reads them, because a command a person typed is quoted
    /// however they chose rather than the way `posixQuoted` writes one, and the rewrite in
    /// `CodingAgent+Resume` has to see the same word the agent's CLI will: the token `"--"` is the word
    /// `--`, which ends option parsing. Inside double quotes a backslash escapes only `"`, `\`, `$`, and a
    /// backtick, and stands for itself anywhere else.
    public static func posixUnquoted(_ token: String) -> String {
        guard token.contains("'") || token.contains("\"") || token.contains("\\") else { return token }
        var literal = ""
        var insideSingleQuotes = false
        var insideDoubleQuotes = false
        var index = token.startIndex
        while index < token.endIndex {
            let character = token[index]
            if insideSingleQuotes {
                if character == "'" { insideSingleQuotes = false } else { literal.append(character) }
            } else if insideDoubleQuotes {
                if character == "\"" {
                    insideDoubleQuotes = false
                } else if character == "\\" {
                    let next = token.index(after: index)
                    guard next < token.endIndex else {
                        literal.append(character)
                        break
                    }
                    if #"\"$`"#.contains(token[next]) {
                        index = next
                        literal.append(token[next])
                    } else {
                        literal.append(character)
                    }
                } else {
                    literal.append(character)
                }
            } else if character == "'" {
                insideSingleQuotes = true
            } else if character == "\"" {
                insideDoubleQuotes = true
            } else if character == "\\" {
                // Outside quotes a backslash makes the next character literal, which is how `posixQuoted`
                // carries an embedded single quote through the close/escape/reopen splice.
                index = token.index(after: index)
                guard index < token.endIndex else { break }
                literal.append(token[index])
            } else {
                literal.append(character)
            }
            index = token.index(after: index)
        }
        return literal
    }

    /// The characters an argument may consist of and still be passed to a shell unquoted.
    private static let shellSafeArgumentScalars = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_@%+=:,./-")

    private static func executableArgumentIndex(in argv: [String], matching executableName: String) -> Int? {
        guard !executableName.isEmpty else { return nil }
        return argv.first.map(normalizedBasename) == executableName ? 0 : nil
    }

    private static func nodeScriptArgumentIndex(in argv: [String]) -> Int? {
        guard !argv.isEmpty else { return nil }
        var index = nodeExecutableNames.contains(normalizedBasename(argv[0])) ? 1 : 0
        var expectsValueForPreviousOption = false
        while index < argv.count {
            let argument = argv[index]
            if expectsValueForPreviousOption {
                expectsValueForPreviousOption = false
                index += 1
                continue
            }
            if argument == "--" { return index + 1 < argv.count ? index + 1 : nil }
            if argument.hasPrefix("--") {
                let optionName = String(argument.split(separator: "=", maxSplits: 1).first ?? "")
                if nodeLongOptionsWithoutScript.contains(optionName) { return nil }
                if nodeLongOptionsTakingValue.contains(optionName), !argument.contains("=") { expectsValueForPreviousOption = true }
                index += 1
                continue
            }
            if argument.hasPrefix("-"), argument.count > 1 {
                let shortOption = String(argument.prefix(2))
                if nodeShortOptionsWithoutScript.contains(shortOption) { return nil }
                if nodeShortOptionsTakingValue.contains(shortOption), argument.count == 2 { expectsValueForPreviousOption = true }
                index += 1
                continue
            }
            return index
        }
        return nil
    }

    private static func matchesNodeScript(_ argument: String, definition: CodingAgentDetectionVariant) -> Bool {
        let basename = normalizedBasename(argument)
        if definition.nodeScriptNames.contains(basename) || definition.executableNames.contains(basename) { return true }
        let normalizedPath = argument.replacingOccurrences(of: "\\", with: "/").lowercased()
        return definition.nodePathFragments.contains { normalizedPath.contains($0) }
    }

    private static func normalizedBasename(_ value: String) -> String {
        lastPathComponent(of: value.trimmingCharacters(in: .whitespacesAndNewlines)).lowercased()
    }

    /// The trailing name in a path, computed as string arithmetic.
    ///
    /// This runs for the executable path and for every argv element of every foreground process the
    /// daemon inspects, once a second per live session. `URL(fileURLWithPath:)` was doing it, and each
    /// construction cost a `stat` to decide whether the path is a directory plus a `getcwd` to resolve a
    /// relative one — file-system work to answer a question about a string.
    ///
    /// The semantics are the ones this job needs rather than `URL`'s incidental ones: trailing slashes
    /// are ignored, so `/usr/bin/` names `bin`; a value that is empty or only slashes names nothing; and
    /// `.` and `..` are returned unchanged instead of being resolved against the daemon's own working
    /// directory, which named a directory that has nothing to do with the inspected process.
    static func lastPathComponent(of value: String) -> String {
        var name = Substring(value)
        while name.hasSuffix("/") { name = name.dropLast() }
        guard !name.isEmpty else { return "" }
        if let separator = name.lastIndex(of: "/") { name = name[name.index(after: separator)...] }
        return String(name)
    }

    /// Appends one argv element, an empty one included: an argument the user wrote as `""` is a word the
    /// agent was given, and dropping it rebuilds a command that means something else (`claude --tools ""`
    /// would come back as `claude --tools`). Bytes that are not valid UTF-8 cannot be rebuilt into a
    /// command at all, so such an element is dropped, on this reader and on the macOS one alike.
    private static func appendProcArgument(_ bytes: Data.SubSequence, to arguments: inout [String]) {
        guard let argument = String(bytes: bytes, encoding: .utf8) else { return }
        arguments.append(argument)
    }

    private static let nodeLongOptionsTakingValue: Set<String> = [
        "--require", "--import", "--conditions", "--icu-data-dir", "--loader", "--max-http-header-size", "--openssl-config",
        "--openssl-shared-config", "--pending-deprecation", "--preserve-symlinks-main", "--redirect-warnings", "--test-name-pattern",
        "--test-reporter", "--test-reporter-destination", "--title", "--use-bundled-ca", "--use-openssl-ca",
    ]
    private static let nodeShortOptionsTakingValue: Set<String> = ["-r", "-C"]
    private static let nodeLongOptionsWithoutScript: Set<String> = ["--eval", "--print"]
    private static let nodeShortOptionsWithoutScript: Set<String> = ["-e", "-p"]

    #if os(macOS)
        private static func processExecutablePath(pid: Int32) -> String? {
            var buffer = [CChar](repeating: 0, count: 4096)
            let count = buffer.withUnsafeMutableBufferPointer { pointer in proc_pidpath(pid, pointer.baseAddress, UInt32(pointer.count)) }
            guard count > 0 else { return nil }
            let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
            return String(bytes: bytes, encoding: .utf8)?.nilIfEmpty
        }

        private static func processArguments(pid: Int32) -> [String] {
            var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
            var size: size_t = 0
            guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return [] }
            var buffer = [CChar](repeating: 0, count: size)
            guard sysctl(&mib, u_int(mib.count), &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return [] }
            return procargs2Arguments(from: buffer, limit: size)
        }

        /// The argv a `KERN_PROCARGS2` buffer carries. The kernel lays one out as an `argc` int, the
        /// executable path, NUL padding, then exactly `argc` NUL-terminated argv strings, then the
        /// environment.
        ///
        /// Exactly `argc` strings are read after the padding, each ending at its own single terminator.
        /// That is what keeps an empty argument the user wrote (`claude --tools ""`) in the argv as the
        /// empty word it is, rather than letting it be swallowed as more padding and rebuilding the
        /// command with a different meaning, while still stopping at the end of argv so no environment
        /// variable is ever read as an argument. Only the padding that follows the executable path is
        /// skipped as padding, which the layout permits because `argv[0]` is never the empty string.
        static func procargs2Arguments(from buffer: [CChar], limit: Int) -> [String] {
            guard limit > MemoryLayout<Int32>.size, limit <= buffer.count else { return [] }
            let argc = buffer.withUnsafeBytes { $0.load(as: Int32.self) }
            guard argc > 0 else { return [] }

            var cursor = MemoryLayout<Int32>.size
            skipString(in: buffer, cursor: &cursor, limit: limit)
            skipNULs(in: buffer, cursor: &cursor, limit: limit)

            var arguments: [String] = []
            for _ in 0..<argc {
                guard cursor < limit else { break }
                let start = cursor
                skipString(in: buffer, cursor: &cursor, limit: limit)
                let bytes = buffer[start..<cursor].map { UInt8(bitPattern: $0) }
                // Bytes that are not valid UTF-8 cannot be rebuilt into a command, so that element is
                // dropped, the way the `/proc` reader drops one.
                if let argument = String(bytes: bytes, encoding: .utf8) { arguments.append(argument) }
                // One terminator per argv string: stepping over more would eat the next empty argument.
                if cursor < limit { cursor += 1 }
            }
            return arguments
        }

        private static func skipString(in buffer: [CChar], cursor: inout Int, limit: Int) {
            while cursor < limit && buffer[cursor] != 0 { cursor += 1 }
        }

        private static func skipNULs(in buffer: [CChar], cursor: inout Int, limit: Int) {
            while cursor < limit && buffer[cursor] == 0 { cursor += 1 }
        }
    #elseif os(Linux)
        private static func processExecutablePath(pid: Int32) -> String? {
            try? FileManager.default.destinationOfSymbolicLink(atPath: "/proc/\(pid)/exe").nilIfEmpty
        }

        private static func processArguments(pid: Int32) -> [String] {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: "/proc/\(pid)/cmdline")) else { return [] }
            return procCmdlineArguments(from: data)
        }
    #endif
}

extension String { fileprivate var nilIfEmpty: String? { isEmpty ? nil : self } }
