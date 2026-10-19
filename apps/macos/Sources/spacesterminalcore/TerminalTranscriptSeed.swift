import Foundation

/// The transcript a new session starts from, and the grid it was recorded at. The core replays `bytes` at
/// that grid before the shell starts, so wrapping and reflow match what the lost shell showed.
public struct TerminalTranscriptSeed: Sendable, Equatable {
    public let bytes: Data
    public let columns: Int
    public let rows: Int

    public init(bytes: Data, columns: Int, rows: Int) {
        self.bytes = bytes
        self.columns = columns
        self.rows = rows
    }
}

extension TerminalSessionPaths {
    /// Records the seed in the session's directory where the daemon's core finds it: the bytes become the
    /// session's `output.log`, and the grid goes beside it.
    public func writeSeedTranscript(_ seed: TerminalTranscriptSeed) throws {
        try ensureDirectories()
        try seed.bytes.write(to: URL(fileURLWithPath: outputPath))
        try "\(seed.columns)x\(seed.rows)".write(toFile: seedGridPath, atomically: true, encoding: .utf8)
    }

    /// The grid to replay `output.log` at when this session starts from a seed transcript, or nil for an
    /// ordinary session. The grid file is written after the bytes, so its presence marks a complete seed.
    public func seedTranscriptGrid() -> (columns: Int, rows: Int)? {
        guard let text = try? String(contentsOfFile: seedGridPath, encoding: .utf8) else { return nil }
        let parts = text.split(separator: "x")
        guard parts.count == 2, let columns = Int(parts[0]), let rows = Int(parts[1]), columns > 0, rows > 0 else { return nil }
        return (columns, rows)
    }

    private var seedGridPath: String { URL(fileURLWithPath: rootDirectory).appendingPathComponent("seed-grid").path }
}
