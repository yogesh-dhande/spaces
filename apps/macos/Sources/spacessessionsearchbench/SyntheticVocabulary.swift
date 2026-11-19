import Foundation

/// Words and text for the synthetic corpus: a Zipf-like word distribution headed by very common words
/// ("the", "test"), so queries on common words match a large share of messages as they do in real stores.
/// Every word is letters only, so generated text needs no JSON escaping.
struct SyntheticVocabulary {
    private let words: [String]

    private static let head = [
        "the", "a", "to", "of", "and", "test", "in", "is", "for", "error", "it", "this", "that", "with", "file", "fix", "on", "add", "function",
        "failing", "database", "migration", "schema", "unit", "handling", "update", "run", "code", "use", "build", "server", "client", "request",
        "response", "config", "branch", "merge", "commit", "refactor", "authentication", "token", "session", "retry", "upload", "queue", "cache",
        "index", "query", "handler", "module", "package", "release", "deploy", "log", "debug", "type", "value", "return", "async", "thread", "worker",
        "timeout", "network", "socket", "stream", "buffer", "parser", "render", "layout", "color", "button", "dialog", "settings", "profile",
        "workspace", "project", "terminal", "command", "script", "path",
    ]

    private static let syllables = [
        "ba", "ko", "ri", "ta", "mu", "le", "so", "ni", "da", "ve", "pi", "zo", "ra", "ke", "lu", "mo", "ti", "sa", "ne", "po", "fu", "gi", "ha",
        "jo", "wa", "xe", "yu", "qui", "tron", "dex", "ply", "ford",
    ]

    init(extraWords: Int = 4000, seed: UInt64 = 7) {
        var rng = SplitMix64(seed: seed)
        var generated = Set(Self.head)
        var words = Self.head
        while words.count < Self.head.count + extraWords {
            let word = (0..<Int.random(in: 2...4, using: &rng)).map { _ in Self.syllables.randomElement(using: &rng)! }.joined()
            if generated.insert(word).inserted { words.append(word) }
        }
        self.words = words
    }

    /// A word drawn with a heavy bias toward the front of the list.
    func word(using rng: inout SplitMix64) -> String {
        let u = Double.random(in: 0..<1, using: &rng)
        return words[min(words.count - 1, Int(u * u * u * Double(words.count)))]
    }

    private static let phrases = ["unit test", "database migration", "error handling", "merge conflict", "failing test", "schema change"]

    /// A sentence-like run of `count` words, occasionally carrying one of the queried phrases.
    func text(wordCount count: Int, using rng: inout SplitMix64) -> String {
        var parts: [String] = []
        while parts.count < count {
            if Int.random(in: 0..<100, using: &rng) < 3 {
                parts.append(Self.phrases.randomElement(using: &rng)!)
            } else {
                parts.append(word(using: &rng))
            }
        }
        var text = parts.joined(separator: " ")
        text.append(Int.random(in: 0..<4, using: &rng) == 0 ? "?" : ".")
        return text.prefix(1).uppercased() + text.dropFirst()
    }

    /// Text standing in for tool output: long, with JSON-escaped newlines, and made of the same words so
    /// that skipping it, not failing to match it, is what keeps it out of the index.
    func toolOutputBlob(byteCount: Int, using rng: inout SplitMix64) -> [UInt8] {
        var blob: [UInt8] = []
        blob.reserveCapacity(byteCount + 64)
        while blob.count < byteCount {
            blob.append(contentsOf: word(using: &rng).utf8)
            if Int.random(in: 0..<12, using: &rng) == 0 {
                blob.append(contentsOf: [UInt8(ascii: "\\"), UInt8(ascii: "n")])
            } else {
                blob.append(UInt8(ascii: " "))
            }
        }
        return blob
    }
}
