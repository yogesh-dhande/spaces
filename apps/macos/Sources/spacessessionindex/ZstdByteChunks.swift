import CZstd
import Foundation

/// The decompressed bytes of a `.zst` file, streamed in bounded chunks. Concatenated frames decode as one
/// stream, as the zstd CLI does.
final class ZstdByteChunks: ByteChunkSource {
    private let path: String
    private let descriptor: Int32
    private let stream: OpaquePointer
    private var compressed = [UInt8](repeating: 0, count: ZSTD_DStreamInSize())
    private var inputSize = 0
    private var inputPos = 0
    private var decoded = [UInt8](repeating: 0, count: ZSTD_DStreamOutSize())
    /// True while a frame has started and its end has not been reached.
    private var frameOpen = false

    /// Decompressed bytes still to be dropped before the first chunk is returned.
    private var bytesToSkip: Int

    /// `skippingBytes` starts the stream that far into the decompressed content: a transcript indexed
    /// while it was still plain JSONL resumes from the offset already read after Codex compresses it.
    init(path: String, skippingBytes: Int64 = 0) throws {
        bytesToSkip = Int(skippingBytes)
        let descriptor = open(path, O_RDONLY)
        guard descriptor >= 0 else { throw AgentSessionReadError.cannotOpen(path) }
        guard let stream = ZSTD_createDStream() else {
            close(descriptor)
            throw AgentSessionReadError.zstd("cannot allocate a decompression stream")
        }
        self.path = path
        self.descriptor = descriptor
        self.stream = stream
    }

    deinit {
        ZSTD_freeDStream(stream)
        close(descriptor)
    }

    func nextChunk() throws -> Data? {
        while let chunk = try nextDecodedChunk() {
            if bytesToSkip == 0 { return chunk }
            if chunk.count <= bytesToSkip {
                bytesToSkip -= chunk.count
                continue
            }
            let rest = chunk.dropFirst(bytesToSkip)
            bytesToSkip = 0
            return Data(rest)
        }
        return nil
    }

    private func nextDecodedChunk() throws -> Data? {
        while true {
            if inputPos == inputSize {
                let count = compressed.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
                if count < 0 { throw AgentSessionReadError.cannotOpen(path) }
                if count == 0 {
                    if frameOpen { throw AgentSessionReadError.truncatedZstdStream(path) }
                    return nil
                }
                inputSize = count
                inputPos = 0
            }
            var produced = 0
            var hint = 0
            var position = inputPos
            let available = inputSize
            let dctx = stream
            compressed.withUnsafeBytes { input in
                decoded.withUnsafeMutableBytes { output in
                    var inBuffer = ZSTD_inBuffer(src: input.baseAddress, size: available, pos: position)
                    var outBuffer = ZSTD_outBuffer(dst: output.baseAddress, size: output.count, pos: 0)
                    hint = ZSTD_decompressStream(dctx, &outBuffer, &inBuffer)
                    position = inBuffer.pos
                    produced = outBuffer.pos
                }
            }
            if ZSTD_isError(hint) != 0 { throw AgentSessionReadError.zstd(String(cString: ZSTD_getErrorName(hint))) }
            inputPos = position
            frameOpen = hint != 0
            if produced > 0 { return decoded.withUnsafeMutableBytes { Data(bytesNoCopy: $0.baseAddress!, count: produced, deallocator: .none) } }
        }
    }
}
