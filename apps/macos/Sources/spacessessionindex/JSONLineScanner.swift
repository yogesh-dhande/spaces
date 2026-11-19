import Foundation

/// Splits a byte stream into newline-terminated lines and reports how far the complete lines reach.
///
/// A trailing fragment without a newline is a record its writer has not finished, so it is neither
/// delivered nor counted in the returned offset; the next read starts at that offset and sees the whole
/// line once it is complete. A compressed file is immutable, so its final line is complete even without a
/// newline (`acceptsUnterminatedFinalLine`).
///
/// Lines are handed to the caller as views into the chunk being scanned, with no copy: transcripts are
/// mostly tool output that the caller rejects after a substring test, so copying every line would be the
/// largest cost of reading one. A line that spans chunks is assembled in a buffer first. The view is only
/// valid during the call.
struct JSONLineScanner {
    let startOffset: Int64
    let acceptsUnterminatedFinalLine: Bool

    private static let newline = Int32(UInt8(ascii: "\n"))

    init(startOffset: Int64, acceptsUnterminatedFinalLine: Bool = false) {
        self.startOffset = startOffset
        self.acceptsUnterminatedFinalLine = acceptsUnterminatedFinalLine
    }

    /// Calls `body` with each non-blank line and returns the offset just past the last line delivered.
    /// `isCancelled` is checked between chunks, so a read of a very large transcript stops promptly with
    /// `AgentSessionReadError.cancelled`.
    func scan<Source: ByteChunkSource>(_ source: inout Source, isCancelled: () -> Bool = { false }, body: (UnsafeRawBufferPointer) throws -> Void)
        throws -> Int64
    {
        var carry: [UInt8] = []
        var consumed = startOffset
        while let chunk = try source.nextChunk() {
            if isCancelled() { throw AgentSessionReadError.cancelled }
            try chunk.withUnsafeBytes { bytes in
                guard let base = bytes.baseAddress else { return }
                var position = 0
                while position < bytes.count {
                    guard let found = memchr(base + position, Self.newline, bytes.count - position) else { break }
                    let lineEnd = base.distance(to: UnsafeRawPointer(found))
                    let tail = UnsafeRawBufferPointer(start: base + position, count: lineEnd - position)
                    if carry.isEmpty {
                        if !tail.isEmpty { try body(tail) }
                        consumed += Int64(tail.count + 1)
                    } else {
                        carry.append(contentsOf: tail)
                        consumed += Int64(carry.count + 1)
                        try carry.withUnsafeBytes(body)
                        // A line of tens of megabytes must not leave its buffer behind.
                        carry = []
                    }
                    position = lineEnd + 1
                }
                if position < bytes.count { carry.append(contentsOf: UnsafeRawBufferPointer(start: base + position, count: bytes.count - position)) }
            }
        }
        if acceptsUnterminatedFinalLine, !carry.isEmpty {
            consumed += Int64(carry.count)
            try carry.withUnsafeBytes(body)
        }
        return consumed
    }
}
