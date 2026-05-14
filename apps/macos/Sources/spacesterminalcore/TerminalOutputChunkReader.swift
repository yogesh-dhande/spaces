import Foundation

public enum TerminalOutputChunkReader {
    public static func currentSize(path: String, fileManager: FileManager = .default) throws -> Int64 {
        guard fileManager.fileExists(atPath: path) else { return 0 }
        let attributes = try fileManager.attributesOfItem(atPath: path)
        let size = attributes[.size] as? NSNumber
        return size?.int64Value ?? 0
    }

    public static func readChunk(
        sessionID: String, path: String, offset: Int64, maximumBytes: Int, fileManager: FileManager = .default,
        createdAt: @escaping @Sendable () -> String = { ISO8601DateFormatter().string(from: Date()) }
    ) throws -> TerminalOutputChunk? {
        guard maximumBytes > 0 else { return nil }
        let startOffset = max(0, offset)
        let size = try currentSize(path: path, fileManager: fileManager)
        guard startOffset < size else { return nil }

        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(startOffset))
        let bytesToRead = Int(min(Int64(maximumBytes), size - startOffset))
        let data = try handle.read(upToCount: bytesToRead) ?? Data()
        guard !data.isEmpty else { return nil }

        return TerminalOutputChunk(
            sessionID: sessionID, offset: startOffset, lineIndex: try lineIndex(at: startOffset, path: path, fileManager: fileManager), bytes: data,
            createdAt: createdAt())
    }

    private static func lineIndex(at offset: Int64, path: String, fileManager: FileManager) throws -> Int64 {
        guard offset > 0 else { return 0 }
        guard fileManager.fileExists(atPath: path) else { return 0 }

        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? handle.close() }

        var remaining = offset
        var lineIndex: Int64 = 0
        let chunkSize = 64 * 1024
        try handle.seek(toOffset: 0)
        while remaining > 0 {
            let bytesToRead = Int(min(Int64(chunkSize), remaining))
            let data = try handle.read(upToCount: bytesToRead) ?? Data()
            if data.isEmpty { break }
            lineIndex += Int64(data.reduce(into: 0) { partialResult, byte in if byte == 0x0A { partialResult += 1 } })
            remaining -= Int64(data.count)
        }
        return lineIndex
    }
}
