import Foundation

#if canImport(Compression)
    import Compression
#endif
#if canImport(CZlib)
    import CZlib
#endif

/// Raw DEFLATE over a render update's body bytes, shared by every platform that speaks the render wire
/// format.
///
/// The stream is raw DEFLATE (windowBits -15: no zlib header, no trailer, no checksum) because that is
/// the one framing both back ends agree on without extra bytes: Darwin's `COMPRESSION_ZLIB` emits and
/// accepts exactly it, and zlib does the same when initialized with negative window bits. A Linux daemon
/// streaming to an iPhone therefore needs no format negotiation.
///
/// The compressed bytes carry no length of their own, so `inflate` is told the uncompressed size the
/// codec recorded next to them. Both directions run in a single pass and insist on a clean end of
/// stream, so a truncated or over-long stream fails rather than yielding a short buffer the codec's
/// reader would then misparse.
public enum GhosttyRenderUpdateBodyCompression {
    public enum CompressionError: Error, Sendable, Equatable {
        /// The platform back end could not produce a stream.
        case deflateFailed
        /// The bytes are not a raw DEFLATE stream that inflates to exactly the recorded length: truncated,
        /// corrupt, or disagreeing with the length prefix.
        case inflateFailed
    }

    /// A render update body always carries at least its fixed header fields, so empty input is malformed
    /// rather than a stream to produce.
    public static func deflate(_ source: Data) throws -> Data {
        guard !source.isEmpty else { throw CompressionError.deflateFailed }
        #if canImport(Compression)
            return try darwinDeflate(source)
        #elseif canImport(CZlib)
            return try zlibDeflate(source)
        #else
            preconditionFailure("GhosttyRenderUpdateBodyCompression requires a DEFLATE back end.")
        #endif
    }

    /// Absolute ceiling on the length a body may claim to inflate to, independent of the ratio bound
    /// below.
    ///
    /// The length prefix `inflate` is handed is a peer-controlled `UInt32` read straight out of the codec
    /// header, before a single compressed byte is validated: `Data(count: expectedLength)` allocates on
    /// the strength of that prefix alone. DEFLATE's 1032:1 maximum expansion bounds it relative to the
    /// compressed size, but that ratio is no help against a small payload with a large claim: 512 KB of
    /// compressed bytes can claim just over 528 MB and still pass the ratio check, sizing an allocation no
    /// legitimate render update would ever need. This cap sizes the allocation to what the wire format
    /// can actually hold instead.
    ///
    /// A render update body costs 14 fixed bytes per cell (codepoint, foreground/background RGB, flags)
    /// plus, for a cell carrying a grapheme cluster, a sparse entry of up to 70 bytes (4-byte offset,
    /// 2-byte length, up to `GhosttyTerminalSnapshot.maximumClusterUTF8ByteCount` bytes of text) and, for
    /// a linked cell, a sparse entry of up to 2,054 bytes (the same framing around a URL of up to
    /// `GhosttyTerminalSnapshot.maximumLinkURLUTF8ByteCount`). A grid far past anything the product
    /// renders, 1000 columns by 500 rows with every cell clustered, costs about 40 MiB by that math, and
    /// the same grid with every cell carrying a typical few-hundred-byte link stays well under 64 MiB.
    /// 64 MiB is a round number comfortably past those ceilings while staying far below what a hostile
    /// or corrupt peer's length prefix could otherwise force this client to allocate.
    ///
    /// Accepted risk: the theoretical worst case, a URL near the 2 KB limit painted across every cell of
    /// a grid of more than about 32,000 cells, encodes past this cap and is then refused by every decoder.
    /// Raising the cap to cover it (about 256 MiB for the largest grids a Mac pane reaches) would turn the
    /// guard back into an allocation a phone cannot survive, so the cap stays sized to real screens.
    public static let maximumInflatedByteCount = 64 * 1024 * 1024

    public static func inflate(_ source: Data, expectedLength: Int) throws -> Data {
        guard !source.isEmpty, expectedLength > 0, expectedLength <= maximumInflatedByteCount,
            expectedLength <= maximumInflatedLength(forCompressedByteCount: source.count)
        else {
            throw CompressionError.inflateFailed
        }
        #if canImport(Compression)
            return try darwinInflate(source, expectedLength: expectedLength)
        #elseif canImport(CZlib)
            return try zlibInflate(source, expectedLength: expectedLength)
        #else
            preconditionFailure("GhosttyRenderUpdateBodyCompression requires a DEFLATE back end.")
        #endif
    }

    /// DEFLATE's maximum expansion is 1032:1 (a 258-byte match encoded in as little as two bits), so a
    /// stream of `count` bytes cannot inflate past this. The codec reads the length prefix before it
    /// examines a single compressed byte, and corruption or a hostile peer controls that prefix, so the
    /// bound turns it into an allocation the input already pays for rather than a claimed 4 GB buffer.
    private static func maximumInflatedLength(forCompressedByteCount count: Int) -> Int {
        count.multipliedReportingOverflow(by: 1032).overflow ? Int.max : count * 1032
    }

    /// zlib's `deflateBound` for a raw stream: room for the pathological case where every block is stored
    /// verbatim, so one pass always reaches the end of the stream and no growth loop is needed.
    private static func deflateBound(forSourceByteCount count: Int) -> Int { count + ((count + 7) >> 3) + ((count + 63) >> 6) + 5 + 64 }

    #if canImport(Compression)
        /// `COMPRESSION_ZLIB` takes no level: the Compression framework picks its own, in the middle of
        /// zlib's range. The two platforms need not emit identical bytes, only mutually readable ones,
        /// which raw DEFLATE guarantees.
        private static func darwinDeflate(_ source: Data) throws -> Data {
            // compression_stream's members are non-optional pointers, so the struct cannot be built from
            // Swift; compression_stream_init fills the allocation in.
            let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
            defer { stream.deallocate() }
            guard compression_stream_init(stream, COMPRESSION_STREAM_ENCODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
                throw CompressionError.deflateFailed
            }
            defer { compression_stream_destroy(stream) }

            var destination = Data(count: deflateBound(forSourceByteCount: source.count))
            let written: Int = try destination.withUnsafeMutableBytes { destinationRaw in
                try source.withUnsafeBytes { sourceRaw in
                    stream.pointee.dst_ptr = destinationRaw.bindMemory(to: UInt8.self).baseAddress!
                    stream.pointee.dst_size = destinationRaw.count
                    stream.pointee.src_ptr = sourceRaw.bindMemory(to: UInt8.self).baseAddress!
                    stream.pointee.src_size = sourceRaw.count
                    guard compression_stream_process(stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue)) == COMPRESSION_STATUS_END else {
                        throw CompressionError.deflateFailed
                    }
                    return destinationRaw.count - stream.pointee.dst_size
                }
            }
            destination.removeSubrange(written..<destination.count)
            return destination
        }

        private static func darwinInflate(_ source: Data, expectedLength: Int) throws -> Data {
            let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
            defer { stream.deallocate() }
            guard compression_stream_init(stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
                throw CompressionError.inflateFailed
            }
            defer { compression_stream_destroy(stream) }

            var destination = Data(count: expectedLength)
            try destination.withUnsafeMutableBytes { destinationRaw in
                try source.withUnsafeBytes { sourceRaw in
                    stream.pointee.dst_ptr = destinationRaw.bindMemory(to: UInt8.self).baseAddress!
                    stream.pointee.dst_size = destinationRaw.count
                    stream.pointee.src_ptr = sourceRaw.bindMemory(to: UInt8.self).baseAddress!
                    stream.pointee.src_size = sourceRaw.count
                    // END with the destination exactly filled is the only acceptable outcome: a truncated
                    // stream stops at OK or ERROR without reaching the end marker, and one that decodes past
                    // the recorded length runs the destination out and reports OK rather than END.
                    let status = compression_stream_process(stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                    guard status == COMPRESSION_STATUS_END, stream.pointee.dst_size == 0 else { throw CompressionError.inflateFailed }
                }
            }
            return destination
        }
    #elseif canImport(CZlib)
        private static func zlibDeflate(_ source: Data) throws -> Data {
            var stream = z_stream()
            guard spaces_deflate_init_raw(&stream, Z_DEFAULT_COMPRESSION) == Z_OK else { throw CompressionError.deflateFailed }
            defer { deflateEnd(&stream) }

            var destination = Data(count: Int(CZlib.deflateBound(&stream, uLong(source.count))))
            let written: Int = try destination.withUnsafeMutableBytes { destinationRaw in
                try source.withUnsafeBytes { sourceRaw in
                    stream.next_out = destinationRaw.bindMemory(to: UInt8.self).baseAddress!
                    stream.avail_out = uInt(destinationRaw.count)
                    stream.next_in = UnsafeMutablePointer(mutating: sourceRaw.bindMemory(to: UInt8.self).baseAddress!)
                    stream.avail_in = uInt(sourceRaw.count)
                    guard CZlib.deflate(&stream, Z_FINISH) == Z_STREAM_END else { throw CompressionError.deflateFailed }
                    return Int(stream.total_out)
                }
            }
            destination.removeSubrange(written..<destination.count)
            return destination
        }

        private static func zlibInflate(_ source: Data, expectedLength: Int) throws -> Data {
            var stream = z_stream()
            guard spaces_inflate_init_raw(&stream) == Z_OK else { throw CompressionError.inflateFailed }
            defer { inflateEnd(&stream) }

            var destination = Data(count: expectedLength)
            try destination.withUnsafeMutableBytes { destinationRaw in
                try source.withUnsafeBytes { sourceRaw in
                    stream.next_out = destinationRaw.bindMemory(to: UInt8.self).baseAddress!
                    stream.avail_out = uInt(destinationRaw.count)
                    stream.next_in = UnsafeMutablePointer(mutating: sourceRaw.bindMemory(to: UInt8.self).baseAddress!)
                    stream.avail_in = uInt(sourceRaw.count)
                    // Z_STREAM_END with the destination exactly filled is the only acceptable outcome, for
                    // the same reasons as the Darwin back end: a truncated stream never reaches the end
                    // marker, and an over-long one exhausts avail_out first.
                    guard CZlib.inflate(&stream, Z_FINISH) == Z_STREAM_END, stream.total_out == uLong(expectedLength) else {
                        throw CompressionError.inflateFailed
                    }
                }
            }
            return destination
        }
    #endif
}
