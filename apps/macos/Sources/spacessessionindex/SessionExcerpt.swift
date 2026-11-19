import Foundation

/// The few words of a matching turn shown under a result.
///
/// Cut in Swift from the turn's text rather than with FTS5's `snippet()`: the newest-first scan needs the
/// excerpt only for the 20 sessions on the page, and `snippet()` can run only inside the scan (once per
/// scanned row, thousands of rows for a common word when one recent session holds most of the matches) or
/// in a per-rowid re-match that seeks deep into the match list.
///
/// A turn can be hundreds of kilobytes (an agent's replies over a long tool loop), so the work that
/// scales with the turn is one pass over its unicode scalars to find the match; everything character-wise
/// (whitespace collapsing, window and word-boundary trimming) runs on a slice of a few hundred scalars
/// around it. Doing those over the whole turn made a page of results take over 100 ms.
enum SessionExcerpt {
    private static let charactersBefore = 60
    private static let charactersAfter = 140
    /// Raw scalars kept on each side of the match: more than the window needs even when whitespace collapses.
    private static let sliceBefore = 4 * charactersBefore
    private static let sliceAfter = 4 * charactersAfter

    /// A single-line window of `text` around the earliest occurrence of any of `tokens` at the start of a
    /// word (the index matches words by prefix), trimmed to word boundaries and marked with an ellipsis
    /// where it does not reach the turn's ends. Matching ignores case and diacritics, as the index does.
    static func make(from text: String, matching tokens: [String]) -> String {
        let scalars = text.unicodeScalars
        let anchor = firstWordStart(of: tokens.map(foldedScalars), in: scalars) ?? scalars.startIndex
        let sliceStart = scalars.index(anchor, offsetBy: -sliceBefore, limitedBy: scalars.startIndex) ?? scalars.startIndex
        let sliceEnd = scalars.index(anchor, offsetBy: sliceAfter, limitedBy: scalars.endIndex) ?? scalars.endIndex

        let head = collapsingWhitespace(String(scalars[sliceStart..<anchor]), keepsTrailingSpace: true)
        let line = head + collapsingWhitespace(String(scalars[anchor..<sliceEnd]), keepsTrailingSpace: false)
        let anchorInLine = line.index(line.startIndex, offsetBy: head.count)

        var lower = line.index(anchorInLine, offsetBy: -charactersBefore, limitedBy: line.startIndex) ?? line.startIndex
        var upper = line.index(anchorInLine, offsetBy: charactersAfter, limitedBy: line.endIndex) ?? line.endIndex
        let cutsBefore = lower > line.startIndex || sliceStart > scalars.startIndex
        let cutsAfter = upper < line.endIndex || sliceEnd < scalars.endIndex
        if lower > line.startIndex, let space = line[lower..<anchorInLine].firstIndex(of: " ") { lower = line.index(after: space) }
        if upper < line.endIndex, let space = line[anchorInLine..<upper].lastIndex(of: " ") { upper = space }
        return (cutsBefore ? "…" : "") + line[lower..<upper] + (cutsAfter ? "…" : "")
    }

    private static func collapsingWhitespace(_ text: String, keepsTrailingSpace: Bool) -> String {
        let collapsed = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return keepsTrailingSpace && text.last?.isWhitespace == true && !collapsed.isEmpty ? collapsed + " " : collapsed
    }

    /// The scalars of the earliest word that starts with one of `tokens` (already folded), or nil.
    private static func firstWordStart(of tokens: [[Unicode.Scalar]], in scalars: String.UnicodeScalarView) -> String.UnicodeScalarView.Index? {
        var previousIsWordCharacter = false
        var index = scalars.startIndex
        while index < scalars.endIndex {
            let scalar = scalars[index]
            if !previousIsWordCharacter, isWordCharacter(scalar), tokens.contains(where: { startsWith($0, at: index, in: scalars) }) { return index }
            previousIsWordCharacter = isWordCharacter(scalar)
            index = scalars.index(after: index)
        }
        return nil
    }

    private static func startsWith(_ token: [Unicode.Scalar], at start: String.UnicodeScalarView.Index, in scalars: String.UnicodeScalarView) -> Bool
    {
        var index = start
        var matched = 0
        while matched < token.count {
            guard index < scalars.endIndex else { return false }
            let scalar = scalars[index]
            if scalar.isASCII {
                guard token[matched] == lowercased(scalar) else { return false }
                matched += 1
            } else {
                // A non-ASCII scalar can fold to several (or none): compare each of them in turn.
                for folded in foldedScalars(of: scalar) {
                    guard matched < token.count, token[matched] == folded else { return false }
                    matched += 1
                }
            }
            index = scalars.index(after: index)
        }
        return true
    }

    private static func lowercased(_ scalar: Unicode.Scalar) -> Unicode.Scalar {
        (scalar.value >= 65 && scalar.value <= 90) ? Unicode.Scalar(scalar.value + 32)! : scalar
    }

    private static func isWordCharacter(_ scalar: Unicode.Scalar) -> Bool {
        if scalar.isASCII {
            switch scalar.value {
            case 48...57, 65...90, 97...122: return true
            default: return false
            }
        }
        return scalar.properties.isAlphabetic || scalar.properties.numericType != nil
    }

    private static func foldedScalars(of text: String) -> [Unicode.Scalar] { text.unicodeScalars.flatMap(foldedScalars(of:)) }

    private static func foldedScalars(of scalar: Unicode.Scalar) -> [Unicode.Scalar] {
        if scalar.isASCII { return [lowercased(scalar)] }
        return Array(String(scalar).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).unicodeScalars)
    }
}
