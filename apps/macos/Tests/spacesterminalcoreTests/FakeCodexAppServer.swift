import Foundation

@testable import spacesterminalcore

#if os(Linux)
    import Glibc
#else
    import Darwin
#endif

/// An in-process stand-in for `codex app-server`, so no unit test spawns a real Codex.
///
/// It behaves the way codex-cli 0.159 was observed to: `hooks/list` reports every command hook of the
/// codex home's `hooks.json` under `source` `user`, keyed `<home resolved>/hooks.json:<snake event>:<group>:<hook>`,
/// with a `trustStatus` read from the `[hooks.state."<key>"]` tables of `config.toml` (`trusted` when the
/// table's `trusted_hash` is the hook's current hash, `modified` when it is another hash, `untrusted`
/// without one) and `enabled` read from the same table. `config/batchWrite` upserts `trusted_hash` into
/// those tables in `config.toml`, so trust survives from one session to the next exactly as it does on
/// disk, and a record left behind by a rewrite reads `modified` the way Codex reads it.
///
/// The hash is the fake's own, derived from the command text, which keeps "the text changed" visible
/// as a different hash without the fake claiming to know Codex's scheme.
final class FakeCodexAppServer: @unchecked Sendable {
    enum Behavior: Sendable {
        /// Answers as Codex does.
        case answers
        /// The server cannot be started at all.
        case failsToLaunch(String)
        /// The server exits before answering anything.
        case exitsImmediately(status: Int32, detail: String)
        /// The server never answers, so every read reaches the session's deadline.
        case neverAnswers
        /// Codex answers `method` with a JSON-RPC error.
        case rejects(method: String, message: String)
        /// `config/batchWrite` reports success without recording anything.
        case dropsTrustWrites
    }

    var behavior: Behavior
    /// Hooks reported beside the ones read from `hooks.json`, standing in for other configuration layers.
    var extraListedHooks: [AgentHookCodexListedHook] = []

    private let lock = NSLock()
    private var recordedMethods: [String] = []
    private var launches = 0

    init(behavior: Behavior = .answers) { self.behavior = behavior }

    var launcher: AgentHookCodexAppServer.Launcher { { [self] _, codexHome in try launch(codexHome: codexHome) } }

    /// Every JSON-RPC method and notification received, across every session, in order.
    var methods: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recordedMethods
    }

    /// How many servers were started.
    var launchCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return launches
    }

    /// The fake's hash of a hook's text.
    static func hash(of command: String) -> String {
        var value: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in command.utf8 {
            value ^= UInt64(byte)
            value = value &* 0x100_0000_01b3
        }
        return "sha256:" + String(value, radix: 16)
    }

    /// `path` with every symlink resolved, as `realpath(3)` reports it and as Codex names its home.
    static func realPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// The name Codex gives the hooks file of `codexHome`.
    static func hooksFileKeyPath(codexHome: URL) -> String { realPath(codexHome.path) + "/hooks.json" }

    /// `[hooks.state."<key>"]` tables trusting `commandsByKey` at their current text, for seeding a
    /// `config.toml` the way Codex leaves it after the user trusts those hooks.
    static func trustTables(_ commandsByKey: [String: String], enabled: Bool? = nil) -> String {
        commandsByKey.keys.sorted().map { key in
            var table = "\n[hooks.state.\"\(key)\"]\n"
            if let enabled { table += "enabled = \(enabled)\n" }
            return table + "trusted_hash = \"\(hash(of: commandsByKey[key] ?? ""))\"\n"
        }.joined()
    }

    private var dropsTrustWrites: Bool { if case .dropsTrustWrites = behavior { true } else { false } }

    private func launch(codexHome: URL) throws -> any AgentHookCodexAppServerTransport {
        lock.lock()
        launches += 1
        lock.unlock()
        if case .failsToLaunch(let detail) = behavior { throw AgentHookCodexAppServer.Failure.launch(detail) }
        return Connection(server: self, codexHome: codexHome)
    }

    private func record(_ method: String) {
        lock.lock()
        recordedMethods.append(method)
        lock.unlock()
    }

    // MARK: - Codex's behavior

    private func listedHooks(codexHome: URL) -> [[String: Any]] {
        let hooksFileURL = codexHome.appendingPathComponent("hooks.json")
        let keyPath = Self.hooksFileKeyPath(codexHome: codexHome)
        let states = Self.hookStates(configURL: codexHome.appendingPathComponent("config.toml"))
        var listed: [[String: Any]] = []
        if let data = try? Data(contentsOf: hooksFileURL), let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let hooks = root["hooks"] as? [String: Any]
        {
            for eventName in hooks.keys.sorted() {
                for (groupIndex, group) in ((hooks[eventName] as? [[String: Any]]) ?? []).enumerated() {
                    for (hookIndex, entry) in ((group["hooks"] as? [[String: Any]]) ?? []).enumerated() {
                        guard let command = entry["command"] as? String else { continue }
                        let key = "\(keyPath):\(Self.snakeCased(eventName)):\(groupIndex):\(hookIndex)"
                        let state = states[key]
                        let currentHash = Self.hash(of: command)
                        let trustStatus =
                            switch state?.trustedHash {
                            case nil: "untrusted"
                            case currentHash: "trusted"
                            default: "modified"
                            }
                        listed.append([
                            "key": key, "eventName": eventName.prefix(1).lowercased() + eventName.dropFirst(), "handlerType": "command",
                            "command": command, "sourcePath": keyPath, "source": "user", "enabled": state?.enabled ?? true, "isManaged": false,
                            "currentHash": currentHash, "trustStatus": trustStatus,
                        ])
                    }
                }
            }
        }
        for hook in extraListedHooks {
            var entry: [String: Any] = [
                "key": hook.key, "eventName": hook.eventName, "handlerType": "command", "source": hook.source, "enabled": hook.enabled,
                "isManaged": false, "currentHash": hook.currentHash, "trustStatus": hook.trustStatus,
            ]
            entry["command"] = hook.command
            entry["sourcePath"] = hook.sourcePath
            listed.append(entry)
        }
        return listed
    }

    /// Upserts `trusted_hash` into each named table, appending a table that does not exist yet and
    /// leaving every other line, `enabled` included, as it was.
    private func recordTrust(_ trusts: [String: String], codexHome: URL) {
        let configURL = codexHome.appendingPathComponent("config.toml")
        var lines = ((try? String(contentsOf: configURL, encoding: .utf8)) ?? "").components(separatedBy: "\n")
        for key in trusts.keys.sorted() {
            let header = "[hooks.state.\"\(key)\"]"
            let hashLine = "trusted_hash = \"\(trusts[key] ?? "")\""
            guard let headerIndex = lines.firstIndex(of: header) else {
                lines += ["", header, hashLine]
                continue
            }
            var index = headerIndex + 1
            var replaced = false
            while index < lines.count, !lines[index].hasPrefix("[") {
                if lines[index].hasPrefix("trusted_hash") {
                    lines[index] = hashLine
                    replaced = true
                }
                index += 1
            }
            if !replaced { lines.insert(hashLine, at: headerIndex + 1) }
        }
        try? lines.joined(separator: "\n").write(to: configURL, atomically: true, encoding: .utf8)
    }

    private struct HookState {
        var enabled: Bool?
        var trustedHash: String?
    }

    private static func hookStates(configURL: URL) -> [String: HookState] {
        guard let contents = try? String(contentsOf: configURL, encoding: .utf8) else { return [:] }
        var states: [String: HookState] = [:]
        var current: String?
        for rawLine in contents.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                let prefix = "[hooks.state.\""
                current = line.hasPrefix(prefix) && line.hasSuffix("\"]") ? String(line.dropFirst(prefix.count).dropLast(2)) : nil
                if let current, states[current] == nil { states[current] = HookState() }
                continue
            }
            guard let current else { continue }
            if line.hasPrefix("enabled") { states[current]?.enabled = line.hasSuffix("true") }
            if line.hasPrefix("trusted_hash"), let start = line.firstIndex(of: "\""), let end = line.lastIndex(of: "\""), start < end {
                states[current]?.trustedHash = String(line[line.index(after: start)..<end])
            }
        }
        return states
    }

    private static func snakeCased(_ eventName: String) -> String {
        eventName.reduce(into: "") { result, character in
            if character.isUppercase, !result.isEmpty { result.append("_") }
            result.append(contentsOf: character.lowercased())
        }
    }

    // MARK: - One session

    private final class Connection: AgentHookCodexAppServerTransport {
        private let server: FakeCodexAppServer
        private let codexHome: URL
        private var pending: [Data] = []

        init(server: FakeCodexAppServer, codexHome: URL) {
            self.server = server
            self.codexHome = codexHome
        }

        func send(_ line: Data, deadline: UInt64) throws {
            guard let message = try JSONSerialization.jsonObject(with: line) as? [String: Any], let method = message["method"] as? String else {
                return
            }
            server.record(method)
            guard let id = message["id"] else { return }  // a notification needs no reply
            // Codex announces things of its own between replies; the session has to read past them.
            reply(["method": "remoteControl/status/changed", "params": ["status": "disabled"]])
            if case .rejects(let rejected, let text) = server.behavior, rejected == method {
                reply(["id": id, "error": ["code": -32600, "message": text]])
                return
            }
            switch method {
            case "initialize": reply(["id": id, "result": ["userAgent": "fake-codex/0.0.0"]])
            case "hooks/list": reply(["id": id, "result": ["data": [["cwd": "/", "hooks": server.listedHooks(codexHome: codexHome)]]]])
            case "config/batchWrite":
                if !server.dropsTrustWrites {
                    let params = message["params"] as? [String: Any]
                    let edits = (params?["edits"] as? [[String: Any]]) ?? []
                    var trusts: [String: String] = [:]
                    for edit in edits where edit["keyPath"] as? String == "hooks.state" {
                        for (key, value) in (edit["value"] as? [String: Any]) ?? [:] {
                            if let hash = (value as? [String: Any])?["trusted_hash"] as? String { trusts[key] = hash }
                        }
                    }
                    server.recordTrust(trusts, codexHome: codexHome)
                }
                reply(["id": id, "result": ["status": "ok", "version": "1", "filePath": codexHome.appendingPathComponent("config.toml").path]])
            default: reply(["id": id, "error": ["code": -32601, "message": "unknown method \(method)"]])
            }
        }

        func receiveLine(deadline: UInt64) throws -> Data {
            switch server.behavior {
            case .exitsImmediately(let status, let detail): throw AgentHookCodexAppServer.Failure.exited(status: status, detail: detail)
            case .neverAnswers: throw AgentHookCodexAppServer.Failure.timedOut
            default: break
            }
            guard !pending.isEmpty else { throw AgentHookCodexAppServer.Failure.exited(status: 0, detail: "") }
            return pending.removeFirst()
        }

        func close() {}

        private func reply(_ message: [String: Any]) {
            if let data = try? JSONSerialization.data(withJSONObject: message, options: [.withoutEscapingSlashes]) { pending.append(data) }
        }
    }
}
