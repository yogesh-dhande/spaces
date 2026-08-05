import Foundation

#if os(macOS)
    import Darwin
#endif

public struct TerminalForegroundProcessSnapshot: Codable, Sendable, Equatable {
    public let pid: Int32
    public let executablePath: String?
    public let executableName: String
    public let argv: [String]

    public init(pid: Int32, executablePath: String?, executableName: String? = nil, argv: [String]) {
        self.pid = pid
        self.executablePath = executablePath
        self.executableName =
            executableName?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? executablePath.flatMap(Self.basename) ?? argv.first.flatMap(
                Self.basename) ?? ""
        self.argv = TerminalForegroundProcessInspector.boundedArguments(argv)
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

    public init(
        process: TerminalForegroundProcessSnapshot, detectedAgentKind: TerminalDetectedAgentKind, displayLabel: String, displayCommand: String
    ) {
        self.process = process
        self.detectedAgentKind = detectedAgentKind
        self.displayLabel = displayLabel
        self.displayCommand = displayCommand
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
        let argv = boundedArguments(process.argv)
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
        if start < data.endIndex { appendProcArgument(data[start..<data.endIndex], to: &arguments) }
        return boundedArguments(arguments)
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
            displayCommand: displayCommand(for: process.argv, definition: definition, matchedArgumentIndex: matchedArgumentIndex))
    }

    private static func displayCommand(for argv: [String], definition: CodingAgentDetectionVariant, matchedArgumentIndex: Int?) -> String {
        let bounded = boundedArguments(argv)
        let trailingArguments: ArraySlice<String>
        if let matchedArgumentIndex, matchedArgumentIndex < bounded.count {
            trailingArguments = bounded.dropFirst(matchedArgumentIndex + 1)
        } else if !bounded.isEmpty {
            trailingArguments = bounded.dropFirst()
        } else {
            trailingArguments = []
        }
        return ([definition.commandName] + trailingArguments.map(renderArgument)).joined(separator: " ")
    }

    private static func renderArgument(_ argument: String) -> String {
        guard !argument.isEmpty else { return "''" }
        let needsQuoting = argument.rangeOfCharacter(from: .whitespacesAndNewlines) != nil || argument.contains("'") || argument.contains("\"")
        guard needsQuoting else { return argument }
        return "'\(argument.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

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

    private static func appendProcArgument(_ bytes: Data.SubSequence, to arguments: inout [String]) {
        guard !bytes.isEmpty, let argument = String(bytes: bytes, encoding: .utf8), !argument.isEmpty else { return }
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
            let argc = buffer.withUnsafeBytes { $0.load(as: Int32.self) }
            guard argc > 0 else { return [] }

            var cursor = MemoryLayout<Int32>.size
            skipString(in: buffer, cursor: &cursor, limit: size)
            skipNULs(in: buffer, cursor: &cursor, limit: size)

            var arguments: [String] = []
            for _ in 0..<argc {
                guard cursor < size else { break }
                let start = cursor
                skipString(in: buffer, cursor: &cursor, limit: size)
                if cursor > start {
                    let bytes = buffer[start..<cursor].map { UInt8(bitPattern: $0) }
                    if let argument = String(bytes: bytes, encoding: .utf8), !argument.isEmpty { arguments.append(argument) }
                }
                skipNULs(in: buffer, cursor: &cursor, limit: size)
            }
            return boundedArguments(arguments)
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
