import Foundation

/// Rejoins a file path that a program wrapped itself.
///
/// Claude Code hard-wraps long lines: it fills a row to the last column, moves the cursor down and two
/// columns in, and writes the rest. It never sets the terminal's soft-wrap flag, and a real newline
/// produces the same bytes, so Ghostty's link matcher sees only the slice of the path on the clicked
/// row and a click opens a truncated, nonexistent path. Hyperlinks (OSC 8) carry their whole target and
/// need none of this; URLs are left alone because a wrong guess there opens the wrong page, where a
/// wrong guess at a path is caught by the existence check the caller runs on each candidate.
///
/// A path that merely ends in the last column by coincidence yields a joined candidate that does not
/// exist, so the caller falls back to the link as Ghostty matched it.
public enum TerminalHardWrappedLink {
    /// What to try opening for a clicked link, best first. For a link detected in the text: the rejoined
    /// path (when the link is a hard-wrapped file path), then the link as matched, each followed by the
    /// same text without a trailing `:line` or `:line:col`. The literal text precedes its stripped form
    /// so a file whose name really ends in `:12` still opens. A hyperlink already carries its whole
    /// target, so it is its own single candidate; a click with no known cell has nothing to join against.
    public static func openCandidates(
        for link: String, isHyperlink: Bool, click: (column: Int, row: Int, snapshot: GhosttyTerminalSnapshot)?
    ) -> [String] {
        guard !isHyperlink else { return [link] }
        var bases = [link]
        if let click, let joined = joinedFilePath(link, row: click.row, column: click.column, in: click.snapshot) {
            bases.insert(joined, at: 0)
        }
        var candidates: [String] = []
        for base in bases {
            // A URL's `:8080` is its port, not a line number.
            let forms = isURL(base) ? [base] : [base, strippingLineSuffix(base)]
            for candidate in forms where !candidates.contains(candidate) { candidates.append(candidate) }
        }
        return candidates
    }

    /// `path` without a trailing `:<digits>` or `:<digits>:<digits>`, or unchanged when it has none.
    static func strippingLineSuffix(_ path: String) -> String {
        guard let range = path.range(of: #":\d+(:\d+)?$"#, options: .regularExpression), range.lowerBound > path.startIndex else { return path }
        return String(path[..<range.lowerBound])
    }

    /// The path the clicked link continues into on neighbouring rows, or nil when it is not a
    /// hard-wrapped file path (a URL, a link that does not touch the edge of its row, rows the terminal
    /// itself marked as wrapped, or no continuation text).
    ///
    /// `link` is the text Ghostty matched at (`row`, `column`). Only the exact last column counts as
    /// the row's edge.
    public static func joinedFilePath(_ link: String, row: Int, column: Int, in snapshot: GhosttyTerminalSnapshot) -> String? {
        guard !isURL(link), !link.isEmpty, snapshot.columns > 0, row >= 0, row < snapshot.rows else { return nil }
        guard let clickedRow = Glyphs(snapshot: snapshot, row: row), !clickedRow.isSoftWrapped else { return nil }
        guard let occurrence = clickedRow.occurrence(of: Array(link), coveringColumn: column) else { return nil }

        var result = link
        var joined = false

        var upRow = row
        var upGlyphs = clickedRow
        var upStart = occurrence.lowerBound
        while upStart == upGlyphs.firstNonSpaceIndex, upRow > 0 {
            guard let previous = Glyphs(snapshot: snapshot, row: upRow - 1), let last = previous.characters.last,
                isPathCharacter(last), previous.endColumns[previous.characters.count - 1] == snapshot.columns
            else { break }
            guard !previous.isSoftWrapped else { return nil }
            var runStart = previous.characters.count
            while runStart > 0, isPathCharacter(previous.characters[runStart - 1]) { runStart -= 1 }
            result = String(previous.characters[runStart...]) + result
            joined = true
            upRow -= 1
            upGlyphs = previous
            upStart = runStart
        }

        var downRow = row
        var reachesEdge = clickedRow.endColumns[occurrence.upperBound - 1] == snapshot.columns
        while reachesEdge, downRow + 1 < snapshot.rows {
            guard let next = Glyphs(snapshot: snapshot, row: downRow + 1) else { break }
            let runStart = next.firstNonSpaceIndex
            var runEnd = runStart
            while runEnd < next.characters.count, isPathCharacter(next.characters[runEnd]) { runEnd += 1 }
            guard runEnd > runStart else { break }
            guard !next.isSoftWrapped else { return nil }
            result += String(next.characters[runStart..<runEnd])
            joined = true
            downRow += 1
            reachesEdge = next.endColumns[runEnd - 1] == snapshot.columns
        }

        guard joined else { return nil }
        while let last = result.last, ".,:".contains(last) { result.removeLast() }
        // Prose or a wrapped URL's first half can sit above the continuation ("the file at:" over
        // "src/foo.swift", "https://host/a" over "aaaa/ccc.txt"); joining them makes a string that is not a
        // path, and one a URL parser reads as a scheme would not open at all.
        return result == link || isURL(result) || hasSchemePrefix(result) ? nil : result
    }

    private static func isURL(_ link: String) -> Bool { link.contains("://") || link.hasPrefix("file:") || link.hasPrefix("mailto:") }

    /// Whether a colon comes before any slash, as in `at:src/foo.swift`. A rooted, dot-relative, tilde or
    /// directory-qualified path (`/a`, `./a`, `~/a`, `a/b.swift:12`) has its slash first.
    private static func hasSchemePrefix(_ path: String) -> Bool {
        guard let colon = path.firstIndex(of: ":") else { return false }
        return !path[..<colon].contains("/")
    }

    /// The character set of Ghostty's link regex path segment (`path_chars` in `config/url.zig`), where
    /// `\w` is any letter, digit or underscore.
    private static func isPathCharacter(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first else { return false }
        if CharacterSet.alphanumerics.contains(scalar) || scalar == "_" { return true }
        return "-.~:/?#@!$&*+;=%".unicodeScalars.contains(scalar)
    }

    /// One row as text: a glyph per character with the columns it occupies, so a wide glyph (whose
    /// second cell is a spacer) keeps column positions aligned with the grid.
    private struct Glyphs {
        var characters: [Character] = []
        /// Column where each glyph starts and the column after the last one it occupies.
        var startColumns: [Int] = []
        var endColumns: [Int] = []
        let isSoftWrapped: Bool

        init?(snapshot: GhosttyTerminalSnapshot, row: Int) {
            guard snapshot.cells.count >= snapshot.columns * snapshot.rows, snapshot.columns > 0 else { return nil }
            let rowFlags = snapshot.cells[row * snapshot.columns].flags
            isSoftWrapped = rowFlags & (GhosttyTerminalSnapshotGrid.rowWrapFlag | GhosttyTerminalSnapshotGrid.rowWrapContinuationFlag) != 0
            for column in 0..<snapshot.columns {
                guard let cell = GhosttyTerminalSnapshotGrid.resolvedCell(in: snapshot, row: row, column: column) else { return nil }
                if cell.isSpacer, !characters.isEmpty {
                    endColumns[endColumns.count - 1] = column + 1
                    continue
                }
                characters.append(cell.text.first ?? " ")
                startColumns.append(column)
                endColumns.append(column + 1)
            }
        }

        var firstNonSpaceIndex: Int { characters.firstIndex { $0 != " " } ?? characters.count }

        /// The glyph range of `target` within the row that covers `column`.
        func occurrence(of target: [Character], coveringColumn column: Int) -> Range<Int>? {
            guard !target.isEmpty, characters.count >= target.count else { return nil }
            for start in 0...(characters.count - target.count) where Array(characters[start..<(start + target.count)]) == target {
                let end = start + target.count
                if startColumns[start] <= column, column < endColumns[end - 1] { return start..<end }
            }
            return nil
        }
    }
}
