import Foundation

public enum AgentSessionReadError: Error, Equatable, CustomStringConvertible {
    case cannotOpen(String)
    case zstd(String)
    case truncatedZstdStream(String)
    case sqlite(String)
    case malformedDocument(String)
    /// The caller stopped a read midway; nothing it read is to be applied.
    case cancelled

    public var description: String {
        switch self {
        case .cancelled: "read cancelled"
        case .cannotOpen(let path): "cannot open \(path)"
        case .zstd(let message): "zstd decompression failed: \(message)"
        case .truncatedZstdStream(let path): "compressed file ends mid-frame: \(path)"
        case .sqlite(let message): "sqlite: \(message)"
        case .malformedDocument(let path): "malformed JSON document: \(path)"
        }
    }
}
