import Foundation

public enum TerminalOutputTail {
    public static func tail(path: String, lineCount: Int) throws -> String {
        guard lineCount > 0 else { return "" }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        guard !data.isEmpty else { return "" }
        guard let text = String(data: data, encoding: .utf8) else { return "" }
        let rendered = TerminalTranscriptRenderer.render(text)
        let hadTrailingNewline = rendered.last == "\n"
        var lines = rendered.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if hadTrailingNewline, !lines.isEmpty { lines.removeLast() }
        return lines.suffix(lineCount).joined(separator: "\n")
    }
}
