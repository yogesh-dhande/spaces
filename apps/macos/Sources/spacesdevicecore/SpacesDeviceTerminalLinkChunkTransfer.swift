import Foundation

/// Errors raised while assembling a terminal link's chunked transfer into a local file. These describe a
/// misbehaving server (wrong offset, wrong size, a stream that never terminates) distinctly from
/// transport-layer failures the caller's `readChunk` closure may throw on its own.
public enum SpacesDeviceTerminalLinkChunkTransferError: LocalizedError, Equatable {
    case invalidChunkData(linkID: String)
    case unexpectedChunkLinkID(requestedLinkID: String, receivedLinkID: String)
    case unexpectedChunkOffset(linkID: String, requestedOffset: Int64, receivedOffset: Int64)
    case chunkByteCountMismatch(linkID: String, reportedByteCount: Int, decodedByteCount: Int)
    case emptyNonFinalChunk(linkID: String, offset: Int64)
    case transferExceededExpectedByteCount(linkID: String, expectedByteCount: Int64)
    case incompleteTransfer(linkID: String, expectedByteCount: Int64, writtenByteCount: Int64)

    public var errorDescription: String? {
        switch self {
        case .invalidChunkData(let linkID): return "Terminal link '\(linkID)' transfer returned invalid data."
        case .unexpectedChunkLinkID(let requestedLinkID, let receivedLinkID):
            return "Terminal link '\(requestedLinkID)' transfer returned a chunk for '\(receivedLinkID)'."
        case .unexpectedChunkOffset(let linkID, let requestedOffset, let receivedOffset):
            return "Terminal link '\(linkID)' transfer returned chunk offset \(receivedOffset) instead of the requested offset \(requestedOffset)."
        case .chunkByteCountMismatch(let linkID, let reportedByteCount, let decodedByteCount):
            return "Terminal link '\(linkID)' transfer returned an invalid chunk size (reported \(reportedByteCount), decoded \(decodedByteCount))."
        case .emptyNonFinalChunk(let linkID, let offset):
            return "Terminal link '\(linkID)' transfer returned an empty non-final chunk at offset \(offset)."
        case .transferExceededExpectedByteCount(let linkID, let expectedByteCount):
            return "Terminal link '\(linkID)' transfer exceeded its expected size of \(expectedByteCount) bytes."
        case .incompleteTransfer(let linkID, let expectedByteCount, let writtenByteCount):
            return "Terminal link '\(linkID)' transfer ended after \(writtenByteCount) bytes instead of the expected \(expectedByteCount) bytes."
        }
    }
}

/// Assembles a terminal link's contents from server-paginated chunks into a local file. Shared between the
/// iOS bridge client (which fetches chunks over the device API) and, in a later step, the macOS remote-file
/// fetch path — both page through the same `SpacesDeviceTerminalLinkChunk` wire type, so only the transport
/// behind `readChunk` differs per platform.
public enum SpacesDeviceTerminalLinkChunkTransfer {
    /// Fetches one chunk starting at `offset`, requesting up to `limit` bytes. The server is trusted for
    /// how much it actually returns (a chunk may be smaller than `limit`); `download` reads whatever
    /// offset and byte count the chunk reports and continues from there.
    public typealias ChunkReader = @Sendable (_ offset: Int64, _ limit: Int) async throws -> SpacesDeviceTerminalLinkChunk

    /// Downloads `linkID`'s contents into `destinationURL`, replacing any existing file there. Chunks are
    /// requested serially starting at offset 0 using `SpacesDeviceTerminalLinkResolver.defaultChunkLimit`
    /// and written to disk as they arrive, so peak memory use is one chunk rather than the whole file.
    ///
    /// `expectedByteCount` is the byte count from the link's resolved metadata, when known. It bounds the
    /// transfer so a server that never sets `isFinal` cannot loop forever: the moment a chunk would push
    /// the total past `expectedByteCount`, the transfer fails. It is checked once more against the total
    /// bytes written when the server does signal `isFinal`, catching a server that stops early.
    ///
    /// On any failure — including cancellation — the partial destination file is removed before the error
    /// is rethrown, so callers never observe a truncated file at `destinationURL`.
    ///
    /// - Returns: The total number of bytes written.
    @discardableResult public static func download(linkID: String, expectedByteCount: Int64?, to destinationURL: URL, readChunk: ChunkReader)
        async throws -> Int64
    {
        try Data().write(to: destinationURL, options: .atomic)
        let handle = try FileHandle(forWritingTo: destinationURL)
        var didSucceed = false
        defer {
            try? handle.close()
            if !didSucceed { try? FileManager.default.removeItem(at: destinationURL) }
        }

        var offset: Int64 = 0
        while true {
            try Task.checkCancellation()
            let chunk = try await readChunk(offset, SpacesDeviceTerminalLinkResolver.defaultChunkLimit)
            try Task.checkCancellation()

            guard chunk.linkID == linkID else {
                throw SpacesDeviceTerminalLinkChunkTransferError.unexpectedChunkLinkID(requestedLinkID: linkID, receivedLinkID: chunk.linkID)
            }
            guard chunk.offset == offset else {
                throw SpacesDeviceTerminalLinkChunkTransferError.unexpectedChunkOffset(
                    linkID: linkID, requestedOffset: offset, receivedOffset: chunk.offset)
            }
            guard let data = Data(base64Encoded: chunk.base64Data) else {
                throw SpacesDeviceTerminalLinkChunkTransferError.invalidChunkData(linkID: linkID)
            }
            guard data.count == chunk.byteCount else {
                throw SpacesDeviceTerminalLinkChunkTransferError.chunkByteCountMismatch(
                    linkID: linkID, reportedByteCount: chunk.byteCount, decodedByteCount: data.count)
            }
            guard !data.isEmpty || chunk.isFinal else {
                throw SpacesDeviceTerminalLinkChunkTransferError.emptyNonFinalChunk(linkID: linkID, offset: offset)
            }

            let nextOffset = offset + Int64(data.count)
            if let expectedByteCount, nextOffset > expectedByteCount {
                throw SpacesDeviceTerminalLinkChunkTransferError.transferExceededExpectedByteCount(
                    linkID: linkID, expectedByteCount: expectedByteCount)
            }

            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            offset = nextOffset
            if chunk.isFinal { break }
        }

        if let expectedByteCount, offset != expectedByteCount {
            throw SpacesDeviceTerminalLinkChunkTransferError.incompleteTransfer(
                linkID: linkID, expectedByteCount: expectedByteCount, writtenByteCount: offset)
        }

        didSucceed = true
        return offset
    }
}
