import Foundation

/// Accumulates raw transport bytes and yields complete 0x0A-delimited lines.
/// Bytes after the last newline stay buffered for the next append (pipelining).
public struct LineFrameBuffer: Sendable {
    private var buffer = Data()
    /// Bytes from `buffer.startIndex` already returned via `popLine`/`drainRemainder`.
    private var consumedCount = 0
    /// Bytes from `buffer.startIndex` already scanned for a newline and found to have none.
    /// Lets `popLine` resume scanning at the first never-scanned byte instead of rescanning
    /// the whole buffer on every call, which is what made large lines delivered across many
    /// small appends (e.g. a multi-hundred-KB state line over pinned TLS) O(n^2).
    private var scannedCount = 0

    /// Drop already-consumed bytes from the front once this many have piled up, so a
    /// long-lived connection doesn't retain an ever-growing buffer between compactions.
    private static let compactionThreshold = 64 * 1024

    public init() {}

    public var isEmpty: Bool { consumedCount >= buffer.count }

    public mutating func append(_ data: Data) { buffer.append(data) }

    /// Next complete line with its trailing newline removed, or nil if none is buffered.
    public mutating func popLine() -> Data? {
        let scanStart = buffer.index(buffer.startIndex, offsetBy: scannedCount)
        guard let newlineIndex = buffer[scanStart...].firstIndex(of: 0x0A) else {
            scannedCount = buffer.count
            return nil
        }
        let consumedStart = buffer.index(buffer.startIndex, offsetBy: consumedCount)
        let line = Data(buffer[consumedStart..<newlineIndex])
        consumedCount += buffer.distance(from: consumedStart, to: newlineIndex) + 1
        scannedCount = consumedCount
        compactIfNeeded()
        return line
    }

    /// Everything still buffered (a final unterminated frame at EOF); empties the buffer.
    public mutating func drainRemainder() -> Data {
        let consumedStart = buffer.index(buffer.startIndex, offsetBy: consumedCount)
        let remainder = Data(buffer[consumedStart...])
        buffer.removeAll(keepingCapacity: true)
        consumedCount = 0
        scannedCount = 0
        return remainder
    }

    private mutating func compactIfNeeded() {
        guard consumedCount > 0,
            consumedCount >= buffer.count || consumedCount >= Self.compactionThreshold
        else { return }
        let consumedStart = buffer.index(buffer.startIndex, offsetBy: consumedCount)
        buffer.removeSubrange(buffer.startIndex..<consumedStart)
        scannedCount -= consumedCount
        consumedCount = 0
    }
}
