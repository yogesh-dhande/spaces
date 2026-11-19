import Foundation
import spacesterminalcore

/// A session as the index remembers it between refresh passes.
struct StoredSession {
    struct Key: Hashable {
        let agent: CodingAgent
        let sourceID: String
    }

    /// What was true of one source file when it was last read.
    struct File {
        let path: String
        let size: Int64
        let modifiedAt: Double
        let inode: Int64
        /// Where the next read of an append-only transcript starts; nil for a file read in full.
        let readOffset: Int64?

        func matches(_ file: AgentSessionFile) -> Bool {
            size == file.size && modifiedAt == file.modifiedAt.timeIntervalSince1970 && inode == Int64(bitPattern: file.inode)
        }
    }

    let id: Int64
    let metadata: AgentSessionMetadata
    /// Rows (turns) this session has in the full-text index.
    let turnCount: Int
    var files: [String: File]
}
