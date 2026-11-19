import Foundation

typealias JSONObject = [String: Any]

extension Dictionary where Key == String, Value == Any {
    func string(_ key: String) -> String? { self[key] as? String }
    func object(_ key: String) -> JSONObject? { self[key] as? JSONObject }
    func array(_ key: String) -> [Any]? { self[key] as? [Any] }
    func bool(_ key: String) -> Bool? { self[key] as? Bool }

    /// Integer-valued JSON numbers (epoch milliseconds, ids) however the decoder boxed them.
    func int64(_ key: String) -> Int64? { (self[key] as? NSNumber)?.int64Value }

    /// The `text` of every `text`-typed block, for a message whose content is a block array. Block types are
    /// compared case-insensitively because Codex spells its agent blocks `Text` and its user blocks `text`.
    func textBlocks(_ key: String) -> [String] {
        (array(key) ?? []).compactMap { $0 as? JSONObject }.compactMap { block in
            guard block.string("type")?.lowercased() == "text" else { return nil }
            return block.string("text")
        }
    }
}

enum JSONLine {
    /// The object a line decodes to; a line that is not a JSON object (a corrupt record) yields nil and is
    /// skipped rather than failing the read.
    static func object(_ line: Data) -> JSONObject? { (try? JSONSerialization.jsonObject(with: line)) as? JSONObject }

    /// The object a line view decodes to, without copying the line.
    static func object(_ line: UnsafeRawBufferPointer) -> JSONObject? {
        guard let base = line.baseAddress else { return nil }
        return object(Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: base), count: line.count, deallocator: .none))
    }
}

enum AgentSessionTimestamp {
    private static let iso8601 = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    /// An ISO 8601 timestamp with fractional seconds (`2026-11-18T17:54:08.563Z`), as every JSONL
    /// transcript writes them.
    static func parse(iso8601 text: String?) -> Date? {
        guard let text else { return nil }
        return try? Date(text, strategy: iso8601)
    }

    static func date(epochMilliseconds: Int64?) -> Date? { epochMilliseconds.map { Date(timeIntervalSince1970: Double($0) / 1000) } }
}
