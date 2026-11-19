import Foundation
import spacessessionindex

struct CorpusStats: Codable {
    var sessions = 0
    var storeBytes: Int64 = 0
    var searchableTextBytes: Int64 = 0
    var compressedCodexSessions = 0
    var note: String?
}

/// Builds a deterministic set of agent stores shaped like a real developer's: mostly Claude Code and Codex
/// transcripts whose bulk is tool output (which the readers must skip), a few opencode, Amp, Copilot and pi
/// sessions, and some Codex rollouts compressed to `.jsonl.zst`.
///
/// At scale 1 it holds about a tenth of the shape measured on a heavy user's Mac (8,658 sessions, 56 MB of
/// searchable text, 4.9 GB of store bytes); scale 10 approximates that Mac.
struct SyntheticCorpus {
    static let sessionsAtScaleOne = 870

    let locations: AgentSessionStoreLocations
    let scale: Double
    private var rng = SplitMix64(seed: 20_261_118)
    private let vocabulary = SyntheticVocabulary()
    private var toolOutputPool: [UInt8]
    private var stats = CorpusStats()
    private var compressedCandidates: [(path: String, modified: Date)] = []
    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private let timestampFormatter: ISO8601DateFormatter

    init(locations: AgentSessionStoreLocations, scale: Double) {
        self.locations = locations
        self.scale = scale
        var seedRNG = SplitMix64(seed: 99)
        toolOutputPool = vocabulary.toolOutputBlob(byteCount: 1 << 20, using: &seedRNG)
        timestampFormatter = ISO8601DateFormatter()
        timestampFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }

    /// Writes the stores under the locations' home and returns what was written.
    mutating func generate() throws -> CorpusStats {
        let total = max(10, Int(Double(Self.sessionsAtScaleOne) * scale))
        let counts: [(agent: String, count: Int)] = [
            ("claude", total * 60 / 100), ("codex", total * 30 / 100), ("opencode", max(2, total * 3 / 100)), ("amp", max(2, total * 2 / 100)),
            ("copilot", max(2, total * 3 / 100)), ("pi", max(2, total * 2 / 100)),
        ]
        for (agent, count) in counts {
            switch agent {
            case "claude": try (0..<count).forEach { try writeClaudeSession(number: $0) }
            case "codex": try (0..<count).forEach { try writeCodexRollout(number: $0) }
            case "opencode": try writeOpenCodeDatabase(sessionCount: count)
            case "amp": try (0..<count).forEach { try writeAmpThread(number: $0) }
            case "copilot": try (0..<count).forEach { try writeCopilotSession(number: $0) }
            default: try (0..<count).forEach { try writePiSession(number: $0) }
            }
        }
        try compressSomeCodexRollouts()
        return stats
    }

    /// A claude session that exists, for the incremental-append measurement.
    var firstClaudeTranscript: URL? {
        let fileManager = FileManager.default
        guard
            let projects = try? fileManager.contentsOfDirectory(at: locations.claudeCodeProjects, includingPropertiesForKeys: nil).sorted(by: {
                $0.path < $1.path
            }), let project = projects.first,
            let file = try? fileManager.contentsOfDirectory(at: project, includingPropertiesForKeys: nil).sorted(by: { $0.path < $1.path }).first(
                where: { $0.pathExtension == "jsonl" })
        else { return nil }
        return file
    }

    func claudeLine(role: String, text: String, at date: Date) -> String {
        let content = role == "user" ? "\"\(text)\"" : "[{\"type\":\"text\",\"text\":\"\(text)\"}]"
        return
            "{\"type\":\"\(role)\",\"message\":{\"role\":\"\(role)\",\"content\":\(content)},\"timestamp\":\"\(timestampFormatter.string(from: date))\",\"entrypoint\":\"cli\",\"cwd\":\"/work/app\"}"
    }

    // MARK: - Shared pieces

    private mutating func uuid() -> String {
        var bytes = (0..<16).map { _ in UInt8.random(in: 0...255, using: &rng) }
        bytes[6] = (bytes[6] & 0x0F) | 0x40
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return NSUUID(uuidBytes: bytes).uuidString.lowercased()
    }

    private mutating func timestamp(number: Int) -> Date { now.addingTimeInterval(-Double(Int.random(in: 0..<(90 * 86_400), using: &rng))) }

    private mutating func conversation() -> [(role: String, text: String)] {
        let count = 4 + Int.random(in: 0...20, using: &rng)
        var messages: [(String, String)] = []
        for index in 0..<count {
            let isUser = index % 2 == 0
            let words = isUser ? Int.random(in: 8...50, using: &rng) : Int.random(in: 30...180, using: &rng)
            let text = vocabulary.text(wordCount: words, using: &rng)
            stats.searchableTextBytes += Int64(text.utf8.count)
            messages.append((isUser ? "user" : "assistant", text))
        }
        return messages
    }

    /// A slice of the tool-output pool between 4 KB and about 200 KB (mean about 70 KB), cut at spaces so a
    /// JSON escape is never split.
    private mutating func toolOutput() -> Data {
        let length = 4_000 + Int(pow(Double.random(in: 0..<1, using: &rng), 2) * 196_000)
        var start = Int.random(in: 0..<(toolOutputPool.count - length - 200), using: &rng)
        while toolOutputPool[start] != UInt8(ascii: " ") { start += 1 }
        var end = start + length
        while toolOutputPool[end] != UInt8(ascii: " ") { end += 1 }
        return Data(toolOutputPool[start..<end])
    }

    private mutating func write(_ data: Data, to url: URL, modified: Date) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        stats.storeBytes += Int64(data.count)
    }

    private func utf8(_ string: String) -> Data { Data(string.utf8) }

    // MARK: - Claude Code

    private mutating func writeClaudeSession(number: Int) throws {
        let session = uuid()
        let start = timestamp(number: number)
        var data = Data()
        var clock = start
        for (index, message) in conversation().enumerated() {
            clock = start.addingTimeInterval(Double(index) * 20)
            if message.role == "assistant" {
                data.append(
                    utf8(
                        "{\"type\":\"assistant\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"tool_use\",\"id\":\"toolu_1\",\"name\":\"Bash\",\"input\":{\"command\":\"ls\"}}]},\"timestamp\":\"\(timestampFormatter.string(from: clock))\",\"entrypoint\":\"cli\",\"cwd\":\"/work/app\"}\n"
                    ))
                data.append(
                    utf8(
                        "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":[{\"tool_use_id\":\"toolu_1\",\"type\":\"tool_result\",\"content\":\""
                    ))
                data.append(toolOutput())
                data.append(
                    utf8(
                        "\"}]},\"timestamp\":\"\(timestampFormatter.string(from: clock))\",\"toolUseResult\":{\"stdout\":\"ok\"},\"entrypoint\":\"cli\",\"cwd\":\"/work/app\"}\n"
                    ))
            }
            data.append(utf8(claudeLine(role: message.role, text: message.text, at: clock) + "\n"))
        }
        if number % 10 < 7 { data.append(utf8("{\"type\":\"ai-title\",\"aiTitle\":\"\(vocabulary.text(wordCount: 4, using: &rng).dropLast())\"}\n")) }
        let project = locations.claudeCodeProjects.appendingPathComponent("-work-project\(number % 25)", isDirectory: true)
        try write(data, to: project.appendingPathComponent("\(session).jsonl"), modified: clock)
        stats.sessions += 1

        if number % 10 == 0 {
            var sub = Data()
            for (index, message) in conversation().prefix(4).enumerated() {
                sub.append(utf8(claudeLine(role: message.role, text: message.text, at: start.addingTimeInterval(Double(index)))))
                sub.append(utf8("\n"))
            }
            sub.append(
                utf8(
                    "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":[{\"tool_use_id\":\"toolu_2\",\"type\":\"tool_result\",\"content\":\""
                ))
            sub.append(toolOutput())
            sub.append(utf8("\"}]},\"toolUseResult\":{\"stdout\":\"ok\"}}\n"))
            try write(sub, to: project.appendingPathComponent("\(session)/subagents/agent-a1.jsonl"), modified: clock)
        }
    }

    // MARK: - Codex

    private mutating func writeCodexRollout(number: Int) throws {
        let thread = uuid()
        let start = timestamp(number: number)
        var data = Data()
        data.append(
            utf8(
                "{\"timestamp\":\"\(timestampFormatter.string(from: start))\",\"type\":\"session_meta\",\"payload\":{\"id\":\"\(thread)\",\"cwd\":\"/work/api\",\"source\":\"cli\"}}\n"
            ))
        var clock = start
        for (index, message) in conversation().enumerated() {
            clock = start.addingTimeInterval(Double(index + 1) * 20)
            let kind = message.role == "user" ? "UserMessage" : "AgentMessage"
            let blockType = message.role == "user" ? "text" : "Text"
            if message.role == "assistant" {
                data.append(
                    utf8(
                        "{\"timestamp\":\"\(timestampFormatter.string(from: clock))\",\"type\":\"event_msg\",\"payload\":{\"type\":\"item_completed\",\"item\":{\"type\":\"CommandExecution\",\"id\":\"c1\",\"command\":\"ls\",\"aggregated_output\":\""
                    ))
                data.append(toolOutput())
                data.append(utf8("\",\"exit_code\":0,\"status\":\"completed\"}}}\n"))
            }
            data.append(
                utf8(
                    "{\"timestamp\":\"\(timestampFormatter.string(from: clock))\",\"type\":\"event_msg\",\"payload\":{\"type\":\"item_completed\",\"item\":{\"type\":\"\(kind)\",\"content\":[{\"type\":\"\(blockType)\",\"text\":\"\(message.text)\"}]}}}\n"
                ))
        }
        let date = Calendar(identifier: .gregorian).dateComponents(in: TimeZone(identifier: "UTC")!, from: start)
        let directory = locations.codexSessions.appendingPathComponent(
            String(format: "%04d/%02d/%02d", date.year!, date.month!, date.day!), isDirectory: true)
        let url = directory.appendingPathComponent(
            "rollout-\(timestampFormatter.string(from: start).replacingOccurrences(of: ":", with: "-"))-\(thread).jsonl")
        try write(data, to: url, modified: clock)
        stats.sessions += 1
        if number % 7 == 0 { compressedCandidates.append((url.path, clock)) }
    }

    /// Compresses the chosen rollouts with the `zstd` command, as Codex does to finished ones. The library
    /// only decompresses, so without the command the corpus keeps them plain.
    private mutating func compressSomeCodexRollouts() throws {
        guard !compressedCandidates.isEmpty else { return }
        guard let zstd = Self.findExecutable("zstd") else {
            stats.note = "zstd command not found: Codex rollouts were left uncompressed, so the .jsonl.zst path is not exercised"
            return
        }
        let paths = compressedCandidates.map(\.path)
        for chunkStart in stride(from: 0, to: paths.count, by: 100) {
            let process = Process()
            process.executableURL = zstd
            process.arguments = ["-q", "--rm", "--"] + paths[chunkStart..<min(chunkStart + 100, paths.count)]
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw BenchError("zstd failed with status \(process.terminationStatus)") }
        }
        for candidate in compressedCandidates {
            try FileManager.default.setAttributes([.modificationDate: candidate.modified], ofItemAtPath: candidate.path + ".zst")
        }
        stats.compressedCodexSessions = compressedCandidates.count
    }

    private static func findExecutable(_ name: String) -> URL? {
        let directories = (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin").split(separator: ":").map(String.init)
        for directory in directories + ["/opt/homebrew/bin", "/usr/local/bin"] {
            let candidate = URL(fileURLWithPath: directory).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    // MARK: - Amp, Copilot, pi

    private mutating func writeAmpThread(number: Int) throws {
        let id = "T-" + uuid()
        let start = timestamp(number: number)
        var messages: [String] = []
        for (index, message) in conversation().enumerated() {
            let sentAt = Int64(start.addingTimeInterval(Double(index) * 20).timeIntervalSince1970 * 1000)
            messages.append(
                "{\"role\":\"\(message.role)\",\"messageId\":\(index),\"content\":[{\"type\":\"text\",\"text\":\"\(message.text)\"}],\"meta\":{\"sentAt\":\(sentAt)}}"
            )
            if message.role == "assistant" {
                messages.append(
                    "{\"role\":\"user\",\"content\":[{\"type\":\"tool_result\",\"toolUseID\":\"t1\",\"run\":{\"status\":\"done\",\"result\":\"\(String(decoding: toolOutput(), as: UTF8.self))\"}}]}"
                )
            }
        }
        let document =
            "{\"v\":3,\"id\":\"\(id)\",\"title\":\"\(vocabulary.text(wordCount: 4, using: &rng).dropLast())\",\"messages\":[\(messages.joined(separator: ","))],\"env\":{\"initial\":{\"trees\":[{\"uri\":\"file:///work/tools\"}]}}}"
        try write(utf8(document), to: locations.ampThreads.appendingPathComponent("\(id).json"), modified: start.addingTimeInterval(600))
        stats.sessions += 1
    }

    private mutating func writeCopilotSession(number: Int) throws {
        let session = uuid()
        let start = timestamp(number: number)
        var data = utf8(
            "{\"type\":\"session.start\",\"timestamp\":\"\(timestampFormatter.string(from: start))\",\"data\":{\"context\":{\"cwd\":\"/work/service\"}}}\n"
        )
        var clock = start
        for (index, message) in conversation().enumerated() {
            clock = start.addingTimeInterval(Double(index + 1) * 20)
            data.append(
                utf8(
                    "{\"type\":\"\(message.role).message\",\"timestamp\":\"\(timestampFormatter.string(from: clock))\",\"data\":{\"content\":\"\(message.text)\"}}\n"
                ))
            if message.role == "assistant" {
                data.append(
                    utf8(
                        "{\"type\":\"tool.execution_complete\",\"timestamp\":\"\(timestampFormatter.string(from: clock))\",\"data\":{\"result\":{\"content\":\""
                    ))
                data.append(toolOutput())
                data.append(utf8("\"}}}\n"))
            }
        }
        let directory = locations.copilotSessionState.appendingPathComponent(session, isDirectory: true)
        try write(data, to: directory.appendingPathComponent("events.jsonl"), modified: clock)
        try write(
            utf8("id: \(session)\ncwd: /work/service\nname: \"Copilot session \(number)\"\n"), to: directory.appendingPathComponent("workspace.yaml"),
            modified: clock)
        stats.sessions += 1
    }

    private mutating func writePiSession(number: Int) throws {
        let session = uuid()
        let start = timestamp(number: number)
        var data = utf8("{\"type\":\"session\",\"timestamp\":\"\(timestampFormatter.string(from: start))\",\"cwd\":\"/work/app\"}\n")
        var clock = start
        for (index, message) in conversation().enumerated() {
            clock = start.addingTimeInterval(Double(index + 1) * 20)
            data.append(
                utf8(
                    "{\"type\":\"message\",\"timestamp\":\"\(timestampFormatter.string(from: clock))\",\"message\":{\"role\":\"\(message.role)\",\"content\":[{\"type\":\"text\",\"text\":\"\(message.text)\"}]}}\n"
                ))
            if message.role == "assistant" {
                data.append(
                    utf8(
                        "{\"type\":\"message\",\"timestamp\":\"\(timestampFormatter.string(from: clock))\",\"message\":{\"role\":\"toolResult\",\"content\":[{\"type\":\"text\",\"text\":\""
                    ))
                data.append(toolOutput())
                data.append(utf8("\"}]}}\n"))
            }
        }
        let name = timestampFormatter.string(from: start).replacingOccurrences(of: ":", with: "-")
        try write(data, to: locations.piSessions.appendingPathComponent("--work-app--/\(name)_\(session).jsonl"), modified: clock)
        stats.sessions += 1
    }

    // MARK: - opencode

    private mutating func writeOpenCodeDatabase(sessionCount: Int) throws {
        var sessions: [OpenCodeSyntheticDatabase.Session] = []
        for number in 0..<sessionCount {
            let start = timestamp(number: number)
            var parts: [OpenCodeSyntheticDatabase.Part] = []
            for (index, message) in conversation().enumerated() {
                let time = Int64(start.addingTimeInterval(Double(index) * 20).timeIntervalSince1970 * 1000)
                parts.append(.init(role: message.role, text: message.text, time: time, toolOutput: nil))
                if message.role == "assistant" {
                    parts.append(
                        .init(role: message.role, text: nil, time: time + 1, toolOutput: String(decoding: toolOutput().prefix(20_000), as: UTF8.self))
                    )
                }
            }
            sessions.append(.init(id: "ses_\(uuid())", title: "opencode session \(number)", parts: parts))
        }
        let size = try OpenCodeSyntheticDatabase.write(sessions, to: locations.openCodeDatabase)
        stats.storeBytes += size
        stats.sessions += sessionCount
    }
}

struct BenchError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
