import Foundation

public enum TerminalReplayOutputHistory {
    public static let defaultMaxByteCount = 2 * 1024 * 1024

    public static func load(path: String, maxByteCount: Int = defaultMaxByteCount) -> (data: Data?, totalByteCount: Int)? {
        let outputURL = URL(fileURLWithPath: path)
        guard let fileHandle = try? FileHandle(forReadingFrom: outputURL) else { return nil }
        defer { try? fileHandle.close() }

        do {
            let fileSize = try fileHandle.seekToEnd()
            let totalByteCount = clampedInt(fileSize)
            guard fileSize > 0 else { return (Data(), 0) }
            guard fileSize <= UInt64(max(maxByteCount, 0)) else { return (nil, totalByteCount) }

            try fileHandle.seek(toOffset: 0)
            let outputData = try fileHandle.read(upToCount: totalByteCount) ?? Data()
            return (outputData, totalByteCount)
        } catch { return nil }
    }

    private static func clampedInt(_ value: UInt64) -> Int {
        guard value <= UInt64(Int.max) else { return Int.max }
        return Int(value)
    }
}
