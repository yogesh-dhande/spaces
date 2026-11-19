import Foundation

/// Finds the parts of a result excerpt to highlight for a Sessions query.
///
/// The device matches words by prefix, ignoring case, in any order, and a quoted phrase as consecutive
/// words. The client repeats that match on the excerpt it was sent, so what is marked is what matched.
/// Words are runs of letters and digits, which is how the device's index splits text.
enum SessionQueryHighlight {
    /// An excerpt on one line: result rows show it truncated, and a newline would break the row.
    static func displayExcerpt(_ excerpt: String) -> String {
        excerpt.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// The ranges of `text` to mark, in order and never overlapping.
    static func ranges(in text: String, query: String) -> [Range<String.Index>] {
        let terms = terms(from: query)
        guard !terms.isEmpty else { return [] }
        let words = words(in: text)
        var found: [Range<String.Index>] = []
        for term in terms {
            var start = 0
            while start + term.count <= words.count {
                if term.indices.allSatisfy({ words[start + $0].folded.hasPrefix(term[$0]) }) {
                    found.append(words[start].range.lowerBound..<words[start + term.count - 1].range.upperBound)
                }
                start += 1
            }
        }
        return merged(found)
    }

    /// Each term is the folded words that must match consecutively: one word for a plain term, several for
    /// a quoted phrase.
    static func terms(from query: String) -> [[String]] {
        var terms: [[String]] = []
        var inQuotes = false
        var segment = ""
        func flush() {
            let folded = words(in: segment).map(\.folded)
            if inQuotes { if !folded.isEmpty { terms.append(folded) } } else { terms.append(contentsOf: folded.map { [$0] }) }
            segment = ""
        }
        for character in query {
            if character == "\"" {
                flush()
                inQuotes.toggle()
            } else {
                segment.append(character)
            }
        }
        flush()
        return terms
    }

    private struct Word {
        let folded: String
        let range: Range<String.Index>
    }

    private static func words(in text: String) -> [Word] {
        var words: [Word] = []
        var start: String.Index?
        var index = text.startIndex
        func close(at end: String.Index) {
            guard let begin = start else { return }
            let range = begin..<end
            words.append(Word(folded: fold(String(text[range])), range: range))
            start = nil
        }
        while index < text.endIndex {
            if isWordCharacter(text[index]) { if start == nil { start = index } } else { close(at: index) }
            index = text.index(after: index)
        }
        close(at: text.endIndex)
        return words
    }

    /// A character is judged by its first scalar, so an accented letter written as a base plus a combining
    /// mark stays inside its word.
    private static func isWordCharacter(_ character: Character) -> Bool {
        character.unicodeScalars.first.map { CharacterSet.alphanumerics.contains($0) } ?? false
    }

    private static func fold(_ word: String) -> String { word.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) }

    private static func merged(_ ranges: [Range<String.Index>]) -> [Range<String.Index>] {
        var result: [Range<String.Index>] = []
        for range in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = result.last, range.lowerBound <= last.upperBound {
                result[result.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else {
                result.append(range)
            }
        }
        return result
    }
}
