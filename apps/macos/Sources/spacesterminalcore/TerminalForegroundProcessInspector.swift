import Foundation

#if os(macOS)
    import Darwin
#endif

public enum TerminalDetectedAgentKind: String, Codable, Sendable, Equatable {
    case codex
    case claude
    case claudeCode = "claude-code"
    case opencode

    public var displayLabel: String {
        switch self {
        case .codex: "codex"
        case .claude: "claude"
        case .claudeCode: "claude-code"
        case .opencode: "opencode"
        }
    }

    var commandName: String {
        switch self {
        case .codex: "codex"
        case .claude: "claude"
        case .claudeCode: "claude-code"
        case .opencode: "opencode"
        }
    }
}

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
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return URL(fileURLWithPath: trimmed).lastPathComponent.nilIfEmpty
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
    private struct AgentDefinition {
        let kind: TerminalDetectedAgentKind
        let executableNames: Set<String>
        let nodeScriptNames: Set<String>
        let nodePathFragments: [String]

        var commandName: String { kind.commandName }
        var displayLabel: String { kind.displayLabel }
    }

    private struct CommandNameCandidate {
        let name: String
        let matchedArgumentIndex: Int?
    }

    private static let maxArgumentCount = 16
    private static let maxArgumentLength = 160
    private static let nodeExecutableNames: Set<String> = ["node", "nodejs"]
    private static let definitions: [AgentDefinition] = [
        AgentDefinition(
            kind: .codex, executableNames: ["codex"], nodeScriptNames: ["codex", "codex.js"],
            nodePathFragments: ["/@openai/codex/", "/codex/bin/codex.js", "/codex/bin/codex"]),
        AgentDefinition(
            kind: .claudeCode, executableNames: ["claude-code"], nodeScriptNames: ["claude-code", "claude-code.js"], nodePathFragments: []),
        AgentDefinition(kind: .claude, executableNames: ["claude"], nodeScriptNames: ["claude", "claude.js"], nodePathFragments: []),
        // The `opencode-ai` npm package installs the selected Darwin binary at
        // `bin/opencode.exe`; npm exposes it to users as `opencode`.
        AgentDefinition(
            kind: .opencode, executableNames: ["opencode", "opencode.exe"], nodeScriptNames: ["opencode", "opencode.js"],
            nodePathFragments: ["/opencode-ai/", "/opencode/bin/opencode"]),
    ]

    public static func inspect(pid: Int32) -> TerminalForegroundProcessSnapshot? {
        guard pid > 0 else { return nil }
        #if os(macOS)
            let executablePath = processExecutablePath(pid: pid)
            let argv = processArguments(pid: pid)
            let executableName = executablePath.flatMap { URL(fileURLWithPath: $0).lastPathComponent.nilIfEmpty }
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

    private static func snapshot(for process: TerminalForegroundProcessSnapshot, definition: AgentDefinition, matchedArgumentIndex: Int?)
        -> TerminalForegroundAgentSnapshot
    {
        TerminalForegroundAgentSnapshot(
            process: process, detectedAgentKind: definition.kind, displayLabel: definition.displayLabel,
            displayCommand: displayCommand(for: process.argv, definition: definition, matchedArgumentIndex: matchedArgumentIndex))
    }

    private static func displayCommand(for argv: [String], definition: AgentDefinition, matchedArgumentIndex: Int?) -> String {
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

    private static func matchesNodeScript(_ argument: String, definition: AgentDefinition) -> Bool {
        let basename = normalizedBasename(argument)
        if definition.nodeScriptNames.contains(basename) || definition.executableNames.contains(basename) { return true }
        let normalizedPath = argument.replacingOccurrences(of: "\\", with: "/").lowercased()
        return definition.nodePathFragments.contains { normalizedPath.contains($0) }
    }

    private static func normalizedBasename(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        return URL(fileURLWithPath: trimmed).lastPathComponent.lowercased()
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
    #endif
}

extension String { fileprivate var nilIfEmpty: String? { isEmpty ? nil : self } }
