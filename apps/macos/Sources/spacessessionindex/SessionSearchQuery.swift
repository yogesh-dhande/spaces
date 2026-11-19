import Foundation

/// Turns what the user typed into an FTS5 MATCH expression that cannot carry FTS5 syntax.
///
/// Every bare word becomes a quoted prefix term and every double-quoted run becomes a quoted exact
/// phrase; terms are separated by a space, which FTS5 reads as AND. Only the characters the index's
/// tokenizer keeps (letters, digits and their combining marks) survive into a term, so operators, `*`,
/// `^`, `:` column filters, `NEAR`, parentheses and stray quotes are all reduced to plain words inside
/// quotes. Punctuation outside quotes separates words: "foo-bar" is the two independent prefix terms
/// foo and bar, not a phrase, so only double quotes ever require adjacency.
enum SessionSearchQuery: Equatable {
    /// Blank input: list sessions by last activity.
    case listAll
    /// Input with no letters or digits at all ("***"): nothing can match.
    case matchesNothing
    /// The MATCH expression, and the words in it, which locate the excerpt in a matching message.
    case match(expression: String, tokens: [String])

    private static let tokenCharacters = CharacterSet.alphanumerics.union(.nonBaseCharacters)

    init(_ input: String) {
        if input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            self = .listAll
            return
        }
        var terms: [String] = []
        var allTokens: [String] = []
        // Quotes alternate: odd segments are inside a pair of quotes. A final segment after an unpaired
        // opening quote has no closing quote, so it is bare words.
        let segments = input.components(separatedBy: "\"")
        for (index, segment) in segments.enumerated() {
            let isPhrase = index % 2 == 1 && index < segments.count - 1
            if isPhrase {
                let tokens = Self.tokens(in: segment)
                if !tokens.isEmpty { terms.append("\"\(tokens.joined(separator: " "))\"") }
                allTokens.append(contentsOf: tokens)
            } else {
                for word in segment.split(whereSeparator: \.isWhitespace) {
                    for token in Self.tokens(in: String(word)) {
                        terms.append("\"\(token)\"*")
                        allTokens.append(token)
                    }
                }
            }
        }
        self = terms.isEmpty ? .matchesNothing : .match(expression: terms.joined(separator: " "), tokens: allTokens)
    }

    private static func tokens(in text: String) -> [String] {
        var tokens: [String] = []
        var current = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            if tokenCharacters.contains(scalar) {
                current.append(scalar)
            } else if !current.isEmpty {
                tokens.append(String(current))
                current = String.UnicodeScalarView()
            }
        }
        if !current.isEmpty { tokens.append(String(current)) }
        return tokens
    }
}
