import Foundation

public enum TerminalOutputTail {
    public static func tail(path: String, lineCount: Int) throws -> String {
        guard lineCount > 0 else { return "" }
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? handle.close() }

        let fileSize = try handle.seekToEnd()
        if fileSize == 0 { return "" }

        let chunkSize = 4096
        var offset = Int64(fileSize)
        var newlineCount = 0
        var collected = Data()

        while offset > 0 && newlineCount <= lineCount {
            let readSize = min(chunkSize, Int(offset))
            offset -= Int64(readSize)
            try handle.seek(toOffset: UInt64(offset))
            let data = try handle.read(upToCount: readSize) ?? Data()
            collected.insert(contentsOf: data, at: 0)
            newlineCount += data.reduce(into: 0) { count, byte in if byte == 0x0A { count += 1 } }
        }

        guard let text = String(data: collected, encoding: .utf8) else { return "" }
        let hadTrailingNewline = text.last == "\n"
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if hadTrailingNewline, !lines.isEmpty { lines.removeLast() }
        return lines.suffix(lineCount).joined(separator: "\n")
    }
}
