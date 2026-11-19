import Foundation

/// One file that belongs to a session, with the stat facts a refresh uses to decide whether it changed
/// without opening it. A file whose inode differs, or whose size is below the offset already read, was
/// replaced or rewritten and is read again from the start.
public struct AgentSessionFile: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        /// The session's own append-only JSONL transcript.
        case transcript
        /// A zstd-compressed JSONL transcript. It is immutable once compressed, so it is read once.
        case compressedTranscript
        /// A whole-file JSON document that its agent rewrites in place; it is read entirely each time.
        case wholeFileDocument
        /// A subagent (sidechain) JSONL transcript folded into its parent session.
        case subagentTranscript
        /// A sidecar that carries only session metadata (a title), read entirely each time.
        case metadata
    }

    public let path: String
    public let kind: Kind
    public let size: Int64
    public let modifiedAt: Date
    public let inode: UInt64

    public init(path: String, kind: Kind, size: Int64, modifiedAt: Date, inode: UInt64) {
        self.path = path
        self.kind = kind
        self.size = size
        self.modifiedAt = modifiedAt
        self.inode = inode
    }

    /// Stats `url` without following a symlink, so a link into another store is not indexed twice.
    /// A direct `lstat`: every refresh pass stats every session file (about 17,000 on a heavy user's
    /// Mac), and `FileManager.attributesOfItem` builds a dictionary of boxed values per call.
    static func stat(_ url: URL, kind: Kind) throws -> AgentSessionFile { try stat(path: url.path, kind: kind) }

    static func stat(path: String, kind: Kind) throws -> AgentSessionFile {
        var info = Foundation.stat()
        guard lstat(path, &info) == 0 else { throw AgentSessionReadError.cannotOpen(path) }
        #if os(Linux)
            let modified = info.st_mtim
        #else
            let modified = info.st_mtimespec
        #endif
        return AgentSessionFile(
            path: path, kind: kind, size: Int64(info.st_size),
            modifiedAt: Date(timeIntervalSince1970: Double(modified.tv_sec) + Double(modified.tv_nsec) / 1_000_000_000), inode: UInt64(info.st_ino))
    }
}
