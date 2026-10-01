import Dispatch
import Foundation

/// One line-oriented connection to a running `codex app-server`.
protocol AgentHookCodexAppServerTransport: AnyObject {
    /// Writes one message line (without its newline), waiting no later than `deadline` (monotonic
    /// nanoseconds) for room to write it.
    func send(_ line: Data, deadline: UInt64) throws
    /// The next line the server wrote, without its newline, waiting no later than `deadline`.
    func receiveLine(deadline: UInt64) throws -> Data
    /// Ends the server: closes its input, which it reads as the end of the session, and reaps it,
    /// killing it if it does not exit promptly. Safe to call more than once.
    func close()
}

/// A short session with Codex's own `codex app-server`, which is how Spaces reads and records the trust
/// Codex keeps for each hook.
///
/// Codex skips every user hook nobody has trusted and records a trust as the hash of the exact hook it
/// approved (`[hooks.state."<hooks.json>:<event>:<group>:<hook>"] trusted_hash` in `config.toml`). The
/// hash scheme is Codex's own, so Spaces never computes one and never writes that table itself: it asks
/// `hooks/list` for each hook's key, current hash, and trust status, and records a trust by handing that
/// same key and hash back through `config/batchWrite`, which is the write Codex's own review screen makes.
/// Both methods exist with these fields in every Codex this integration supports (0.146 onward), and
/// neither needs an experimental opt-in.
///
/// The protocol is newline-delimited JSON-RPC over the server's stdio: `initialize`, the `initialized`
/// notification, then requests. Everything the server says that is not the reply being waited for
/// (notifications such as `remoteControl/status/changed`) is skipped. The input stays open until the
/// last reply is in, because the server ends the session at end of input without answering what is
/// still queued.
///
/// One deadline covers the whole session, launch included, so a wedged or very slow Codex costs the
/// caller a bounded wait rather than a hung Device API lane.
final class AgentHookCodexAppServer {
    typealias Launcher = (_ executablePath: String, _ codexHome: URL) throws -> any AgentHookCodexAppServerTransport

    enum Failure: LocalizedError, Equatable {
        /// The server could not be started at all.
        case launch(String)
        /// The server exited before answering. `detail` is the first line it wrote to stderr.
        case exited(status: Int32, detail: String)
        /// The server did not answer before the session's deadline.
        case timedOut
        /// Codex answered a request with an error.
        case rejected(method: String, message: String)
        /// Codex answered with something other than the reply its protocol documents.
        case unreadable(method: String)

        var errorDescription: String? {
            switch self {
            case .launch(let detail): "codex app-server could not start (\(detail))"
            case .exited(let status, let detail):
                detail.isEmpty ? "codex app-server exited with status \(status)" : "codex app-server exited with status \(status) (\(detail))"
            case .timedOut: "codex app-server did not answer in time"
            case .rejected(let method, let message): "Codex refused \(method) (\(message))"
            case .unreadable(let method): "Codex answered \(method) with a reply Spaces could not read"
            }
        }
    }

    /// The cwd `hooks/list` is asked about. The user hooks file is listed for every cwd; the filesystem
    /// root is one no project config can sit above, so nothing project-scoped joins the listing.
    static let listedWorkingDirectory = "/"

    private let transport: any AgentHookCodexAppServerTransport
    private let deadline: UInt64
    private var nextRequestID = 1

    private init(transport: any AgentHookCodexAppServerTransport, deadline: UInt64) {
        self.transport = transport
        self.deadline = deadline
    }

    /// Starts `codex app-server` for `codexHome`, completes the handshake, runs `body`, and ends the
    /// server whatever `body` does.
    static func withSession<Result>(
        executablePath: String, codexHome: URL, timeoutSeconds: TimeInterval, launcher: Launcher, _ body: (AgentHookCodexAppServer) throws -> Result
    ) throws -> Result {
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(max(0, timeoutSeconds) * 1_000_000_000)
        let transport = try launcher(executablePath, codexHome)
        defer { transport.close() }
        let session = AgentHookCodexAppServer(transport: transport, deadline: deadline)
        _ = try session.request("initialize", params: ["clientInfo": ["name": "spaces", "version": "hooks-v\(AgentHookCommand.hookVersion)"]])
        try session.send(["method": "initialized"])
        return try body(session)
    }

    /// Every hook Codex would consider for a session, whatever its source, as `hooks/list` reports it.
    func listHooks() throws -> [AgentHookCodexListedHook] {
        let method = "hooks/list"
        let result = try request(method, params: ["cwds": [Self.listedWorkingDirectory]])
        guard let data = result["data"] as? [[String: Any]] else { throw Failure.unreadable(method: method) }
        let hooks = data.first?["hooks"] ?? []
        guard let entries = hooks as? [[String: Any]] else { throw Failure.unreadable(method: method) }
        return try entries.map { entry in
            guard let hook = AgentHookCodexListedHook(json: entry) else { throw Failure.unreadable(method: method) }
            return hook
        }
    }

    /// Records Codex's trust in `hooks`, each at the hash `hooks/list` reported for it. `upsert` merges
    /// into each hook's existing table, so an `enabled` the user set there is left as it is.
    func recordTrust(_ hooks: [AgentHookCodexListedHook]) throws {
        var trusts: [String: Any] = [:]
        for hook in hooks { trusts[hook.key] = ["trusted_hash": hook.currentHash] }
        _ = try request(
            "config/batchWrite",
            params: ["edits": [["keyPath": "hooks.state", "value": trusts, "mergeStrategy": "upsert"]], "reloadUserConfig": true])
    }

    // MARK: - JSON-RPC

    private func request(_ method: String, params: [String: Any]) throws -> [String: Any] {
        let id = nextRequestID
        nextRequestID += 1
        try send(["id": id, "method": method, "params": params])
        while true {
            let line = try transport.receiveLine(deadline: deadline)
            guard let message = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { continue }
            // Notifications and the server's own requests carry a method; only a reply lacks one.
            guard message["method"] == nil, (message["id"] as? Int) == id else { continue }
            if let error = message["error"] as? [String: Any] {
                throw Failure.rejected(method: method, message: Self.summary(error["message"] as? String ?? ""))
            }
            guard let result = message["result"] as? [String: Any] else { throw Failure.unreadable(method: method) }
            return result
        }
    }

    private func send(_ message: [String: Any]) throws {
        try transport.send(JSONSerialization.data(withJSONObject: message, options: [.withoutEscapingSlashes]), deadline: deadline)
    }

    /// One line of what Codex said, bounded: an unknown-method error lists every method the server has,
    /// which is thousands of characters no caption can show.
    static func summary(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).lazy.map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? ""
        let limit = 200
        return line.count > limit ? String(line.prefix(limit)) + "…" : line
    }
}

/// One hook as Codex's `hooks/list` reports it.
struct AgentHookCodexListedHook: Equatable {
    /// Codex's name for the hook, which is also the `hooks.state` table that records its trust.
    let key: String
    /// The event, in the camel case Codex reports it in (`preToolUse`).
    let eventName: String
    /// The shell command, for a command hook.
    let command: String?
    /// The file the hook was read from, as Codex names it.
    let sourcePath: String?
    /// Which configuration layer the hook came from: `user` for the user's own hooks file.
    let source: String
    let enabled: Bool
    let currentHash: String
    /// `trusted`, `untrusted`, `modified` (trusted at a different hash), or `managed`.
    let trustStatus: String

    init(
        key: String, eventName: String, command: String?, sourcePath: String?, source: String, enabled: Bool, currentHash: String, trustStatus: String
    ) {
        self.key = key
        self.eventName = eventName
        self.command = command
        self.sourcePath = sourcePath
        self.source = source
        self.enabled = enabled
        self.currentHash = currentHash
        self.trustStatus = trustStatus
    }

    init?(json: [String: Any]) {
        guard let key = json["key"] as? String, let eventName = json["eventName"] as? String, let source = json["source"] as? String,
            let enabled = json["enabled"] as? Bool, let currentHash = json["currentHash"] as? String, let trustStatus = json["trustStatus"] as? String
        else { return nil }
        self.init(
            key: key, eventName: eventName, command: json["command"] as? String, sourcePath: json["sourcePath"] as? String, source: source,
            enabled: enabled, currentHash: currentHash, trustStatus: trustStatus)
    }

    var isTrusted: Bool { trustStatus == "trusted" }
}
