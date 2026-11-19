import Foundation

/// A forward-only stream of bytes read in bounded chunks, so a transcript of any size is never held whole.
protocol ByteChunkSource {
    /// The next chunk, or nil at the end of the stream. A chunk may be a view of the source's own buffer:
    /// it is valid only until the next call, and a caller that keeps bytes must copy them. Reusing one
    /// buffer instead of allocating a chunk per read avoided a large share of the cost of reading a
    /// transcript, which was spent returning freed pages to the system.
    mutating func nextChunk() throws -> Data?
}

/// Raw file bytes from `offset` on.
final class FileByteChunks: ByteChunkSource {
    private let descriptor: Int32
    private var offset: Int64
    private var buffer = [UInt8](repeating: 0, count: 1 << 20)
    private let path: String

    init(path: String, offset: Int64) throws {
        let descriptor = open(path, O_RDONLY)
        guard descriptor >= 0 else { throw AgentSessionReadError.cannotOpen(path) }
        self.descriptor = descriptor
        self.offset = offset
        self.path = path
    }

    deinit { close(descriptor) }

    func nextChunk() throws -> Data? {
        let count = buffer.withUnsafeMutableBytes { pread(descriptor, $0.baseAddress, $0.count, off_t(offset)) }
        if count < 0 { throw AgentSessionReadError.cannotOpen(path) }
        if count == 0 { return nil }
        offset += Int64(count)
        return buffer.withUnsafeMutableBytes { Data(bytesNoCopy: $0.baseAddress!, count: count, deallocator: .none) }
    }
}
