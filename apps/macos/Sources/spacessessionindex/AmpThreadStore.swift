import Foundation
import spacesterminalcore

/// Amp's store: one whole-file JSON document per thread, `threads/T-<id>.json`, rewritten in place as the
/// thread grows, so a changed thread is read entirely.
///
/// Read: `messages[]` entries whose `role` is `user` or `assistant` (their `text` blocks), the thread
/// `title`, and the first workspace tree in `env.initial.trees` as the working directory. Amp threads
/// carry no one-shot marker: `amp -x` runs leave no local thread file.
public enum AmpThreadStore {
    public static func discover(threadsRoot: URL) throws -> [AgentSessionSource] {
        try discover(threadsRoot: threadsRoot, fileSystem: SessionStoreFileSystem())
    }

    static func discover(threadsRoot: URL, fileSystem: SessionStoreFileSystem) throws -> [AgentSessionSource] {
        try fileSystem.list(threadsRoot).filter { !$0.isDirectory && $0.name.hasSuffix(".json") && $0.name.hasPrefix("T-") }.map { entry in
            let threadID = String(entry.name.dropLast(".json".count))
            return AgentSessionSource(
                agent: .amp, id: threadID, sessionKey: threadID,
                files: [try fileSystem.stat(threadsRoot.appendingPathComponent(entry.name), kind: .wholeFileDocument)])
        }
    }

    public static func read(_ file: AgentSessionFile) throws -> AgentSessionReadResult {
        guard let data = FileManager.default.contents(atPath: file.path) else { throw AgentSessionReadError.cannotOpen(file.path) }
        guard let thread = (try? JSONSerialization.jsonObject(with: data)) as? JSONObject else {
            throw AgentSessionReadError.malformedDocument(file.path)
        }
        var accumulator = SessionReadAccumulator()
        if let title = thread.string("title"), !title.isEmpty { accumulator.metadata.title = title }
        if let uri = thread.object("env")?.object("initial")?.array("trees")?.compactMap({ $0 as? JSONObject }).first?.string("uri"),
            let url = URL(string: uri), url.isFileURL
        {
            accumulator.metadata.workingDirectory = url.path
        }
        for case let message as JSONObject in thread.array("messages") ?? [] {
            guard let role = AgentSessionMessage.Role(rawValue: message.string("role") ?? "") else { continue }
            let sentAt = AgentSessionTimestamp.date(epochMilliseconds: message.object("meta")?.int64("sentAt"))
            accumulator.addMessage(role, text: message.textBlocks("content").joined(separator: "\n\n"), timestamp: sentAt)
        }
        return accumulator.result(nextState: .complete)
    }
}
