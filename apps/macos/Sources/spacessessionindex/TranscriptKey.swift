import Foundation

/// Identifies the transcript a turn came from, so a continuation extends a turn of the same file and not
/// of another file folded into the session (a subagent's). A 64-bit FNV-1a hash of the path: a session has
/// a handful of transcripts, so a collision is not a practical concern, and the key is stable across runs.
/// A rollout Codex compresses is the same transcript under a `.zst` name, so the suffix is not part of it.
enum TranscriptKey {
    static func make(path: String) -> Int64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        let identity = path.hasSuffix(".zst") ? String(path.dropLast(".zst".count)) : path
        for byte in identity.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return Int64(bitPattern: hash)
    }
}
