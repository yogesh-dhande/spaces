import Foundation

/// The one-line headline of a coding agent's brief: what `agent list`/`agent status`, the Device API
/// agent-session rows, and the blocked/done notification block show in the slot the full markdown document
/// would not fit.
///
/// It is the brief's first line that still has text once its leading markdown block markers (heading `#`,
/// list `-` or `*`, quote `>`, numbered `1.`) and surrounding whitespace are removed, capped at `maxLength`
/// characters, the last of which is an ellipsis when the line had to be cut. Tabs become spaces so the
/// headline stays one field of the tab-separated `agent list` row.
///
/// The daemon derives the headline and ships it on the orchestration rows rather than the document, so an
/// orchestrator polling `agent list` reads one line per agent and every surface words it the same way. It
/// lives in this module, which the clients share, so a client holding the full text (the overview's
/// coding-agent row) derives the identical headline.
public enum AgentBriefSummary {
    /// The most characters a headline has, its trailing ellipsis included.
    public static let maxLength = 120

    /// The headline of `brief`, or nil when it has no line with text (or there is no brief).
    public static func summary(of brief: String?) -> String? {
        guard let brief else { return nil }
        for line in brief.split(whereSeparator: \.isNewline) {
            let headline = strippingLeadingMarkers(line.replacingOccurrences(of: "\t", with: " "))
            guard !headline.isEmpty else { continue }
            guard headline.count > maxLength else { return headline }
            return String(headline.prefix(maxLength - 1)).trimmingCharacters(in: .whitespaces) + "…"
        }
        return nil
    }

    /// `line` without its leading block markers, which nest (`> - item`), and without surrounding whitespace.
    private static func strippingLeadingMarkers(_ line: String) -> String {
        var rest = line.trimmingCharacters(in: .whitespaces)
        while let markerLength = leadingMarkerLength(rest) { rest = String(rest.dropFirst(markerLength)).trimmingCharacters(in: .whitespaces) }
        return rest
    }

    /// How many characters of block marker `line` starts with, or nil when it starts with none. A heading,
    /// list, or numbered marker counts only when whitespace or the end of the line follows it, the way
    /// markdown reads one, so a line such as `**Status:** green` or `-3 flaky tests` keeps its first
    /// characters. A quote marker needs no space after it.
    private static func leadingMarkerLength(_ line: String) -> Int? {
        guard let first = line.first else { return nil }
        let length: Int
        switch first {
        case ">": return 1
        case "#": length = line.prefix(while: { $0 == "#" }).count
        case "-", "*": length = 1
        default:
            let digits = line.prefix(while: { $0.isASCII && $0.isNumber }).count
            guard digits > 0, line.dropFirst(digits).first == "." else { return nil }
            length = digits + 1
        }
        guard let next = line.dropFirst(length).first else { return length }
        return next.isWhitespace ? length : nil
    }
}
