import Foundation

/// Finds the words of a search query inside a hit's excerpt, the way the device matched them: every word
/// is a case- and diacritic-insensitive prefix of a word in the text, and a quoted phrase is one unit
/// whose words follow each other.
enum SessionSearchHighlight {
    /// One query term: a single word, or the words of a quoted phrase.
    struct Term: Equatable { let words: [String] }

    static func terms(in query: String) -> [Term] {
        var terms: [Term] = []
        var phrase: [String]?
        var current = ""
        func endWord() {
            guard !current.isEmpty else { return }
            if phrase != nil { phrase?.append(current) } else { terms.append(Term(words: [current])) }
            current = ""
        }
        for character in query {
            if character == "\"" {
                endWord()
                if let words = phrase {
                    if !words.isEmpty { terms.append(Term(words: words)) }
                    phrase = nil
                } else {
                    phrase = []
                }
            } else if isWordCharacter(character) {
                current.append(character)
            } else {
                endWord()
            }
        }
        endWord()
        // An unterminated quote still searches its words together.
        if let words = phrase, !words.isEmpty { terms.append(Term(words: words)) }
        return terms
    }

    /// The ranges of `text` to emphasize: for each term, every place its words start consecutive words.
    static func ranges(in text: String, query: String) -> [Range<String.Index>] {
        let terms = terms(in: query)
        guard !terms.isEmpty else { return [] }
        let words = textWords(in: text)
        var ranges: [Range<String.Index>] = []
        for term in terms {
            let folded = term.words.map(fold)
            var index = 0
            while index + folded.count <= words.count {
                let window = words[index..<(index + folded.count)]
                if zip(window, folded).allSatisfy({ $0.folded.hasPrefix($1) }) {
                    let last = window.last!
                    let lastEnd =
                        text.index(last.range.lowerBound, offsetBy: folded.last!.count, limitedBy: last.range.upperBound) ?? last.range.upperBound
                    // A single word highlights just the typed prefix; a phrase spans from its first word.
                    ranges.append(window.first!.range.lowerBound..<(folded.count == 1 ? lastEnd : last.range.upperBound))
                    index += folded.count
                } else {
                    index += 1
                }
            }
        }
        return merged(ranges)
    }

    private struct TextWord {
        let range: Range<String.Index>
        let folded: String
    }

    private static func textWords(in text: String) -> [TextWord] {
        var words: [TextWord] = []
        var start: String.Index?
        var index = text.startIndex
        while index < text.endIndex {
            let isWord = isWordCharacter(text[index])
            if isWord, start == nil { start = index }
            if !isWord, let begin = start {
                words.append(TextWord(range: begin..<index, folded: fold(String(text[begin..<index]))))
                start = nil
            }
            index = text.index(after: index)
        }
        if let begin = start { words.append(TextWord(range: begin..<text.endIndex, folded: fold(String(text[begin...])))) }
        return words
    }

    private static func isWordCharacter(_ character: Character) -> Bool { character.isLetter || character.isNumber }

    private static func fold(_ word: String) -> String { word.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) }

    /// Overlapping ranges (two terms matching the same word) become one.
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
