import Foundation

/// Accumulates raw transport bytes and yields complete 0x0A-delimited lines.
/// Bytes after the last newline stay buffered for the next append (pipelining).
public struct LineFrameBuffer: Sendable {
    private var buffer = Data()

    public init() {}

    public var isEmpty: Bool { buffer.isEmpty }

    public mutating func append(_ data: Data) { buffer.append(data) }

    /// Next complete line with its trailing newline removed, or nil if none is buffered.
    public mutating func popLine() -> Data? {
        guard let newlineIndex = buffer.firstIndex(of: 0x0A) else { return nil }
        let line = Data(buffer.prefix(upTo: newlineIndex))
        buffer.removeSubrange(buffer.startIndex...newlineIndex)
        return line
    }

    /// Everything still buffered (a final unterminated frame at EOF); empties the buffer.
    public mutating func drainRemainder() -> Data {
        let remainder = buffer
        buffer.removeAll(keepingCapacity: true)
        return remainder
    }
}
