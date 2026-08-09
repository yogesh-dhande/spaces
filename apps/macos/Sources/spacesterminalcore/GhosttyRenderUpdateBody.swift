import Foundation

/// The render update a `GhosttyRemoteSessionStatePayload` carries, held in whichever form its
/// producer already has it.
///
/// A payload that arrived over a wire, came off disk, or was exported by a session core holds the
/// encoded blob. A payload a client materialized locally holds the decoded update: `TerminalRemoteStateReducer`
/// applies each incoming delta to its baseline and stores the resulting full frame, and every read the
/// client then makes of that stored payload (`decodedRenderUpdate`, `renderSnapshot`, `renderOwnerEpoch`,
/// `renderText`) wants the decoded value. Serializing the materialized frame back to bytes on the spot
/// cost a full grid encode per applied update per session under streaming output, for bytes no client
/// read.
///
/// The bytes themselves are unchanged: `encodedData` runs the same binary codec, so a materialized
/// payload that is JSON-encoded for a device subscriber or written to disk puts exactly the blob on the
/// wire that an eager encode put there. It runs at most once per body, and copies of a payload share the
/// body, so a payload that fans out to several destinations pays for one encode.
final class GhosttyRenderUpdateBody: @unchecked Sendable {
    private enum Source {
        case encoded(Data)
        case materialized(GhosttyRenderUpdate)
    }

    private let source: Source
    private let lock = NSLock()
    private var encodedCache: Data?

    init(encoded data: Data) {
        source = .encoded(data)
        encodedCache = data
    }

    init(materialized update: GhosttyRenderUpdate) { source = .materialized(update) }

    /// The update's kind without decoding its grid: the value's own kind for a materialized body, a
    /// header read for an encoded one (see `GhosttyRenderUpdateBinaryCodec.encodedKind(of:)`). Nil when an
    /// encoded body is not something this build can decode at all.
    var kind: GhosttyRenderUpdateKind? {
        switch source {
        case .materialized(let update): update.kind
        case .encoded(let data): GhosttyRenderUpdateBinaryCodec.encodedKind(of: data)
        }
    }

    /// A full frame's session revision and owner epoch without decoding its grid; nil for anything that is
    /// not a classifiable full frame. See `GhosttyRenderUpdateBinaryCodec.encodedFrameOrdering(of:)`.
    var fullFrameOrdering: (sessionRevision: UInt64?, ownerEpoch: UInt64)? {
        switch source {
        case .materialized(let update): update.fullFrame.map { ($0.sessionRevision, $0.ownerEpoch) }
        case .encoded(let data): GhosttyRenderUpdateBinaryCodec.encodedFrameOrdering(of: data)
        }
    }

    /// The decoded update: the value itself for a materialized body, a memoized binary decode for an
    /// encoded one (see `GhosttyRenderUpdateDecodeCache`).
    var decodedUpdate: GhosttyRenderUpdate? {
        switch source {
        case .materialized(let update): update
        case .encoded(let data): GhosttyRenderUpdateDecodeCache.decodedUpdate(for: data)
        }
    }

    /// The wire bytes, encoding a materialized update on first read.
    ///
    /// Encoding can only fail on a frame whose dimensions or cell count overflow the wire's fixed-width
    /// fields. A materialized update is always a full frame built by applying decoded wire input to a
    /// decoded baseline, so every one of those fields already came through the same fixed-width wire and
    /// is in range: nil here means the payload carries no render update, which is what the reducer
    /// produced when it encoded eagerly and the encode failed.
    var encodedData: Data? {
        lock.lock()
        defer { lock.unlock() }
        if let encodedCache { return encodedCache }
        guard case .materialized(let update) = source else { return nil }
        let encoded = try? GhosttyRenderUpdateBinaryCodec.encode(update)
        encodedCache = encoded
        return encoded
    }
}

extension GhosttyRenderUpdateBody: Equatable {
    /// Two bodies are equal when they carry the same wire bytes, which is what payload equality meant
    /// while the payload stored the blob directly. Comparing a materialized body forces its encode, so
    /// equality is deliberately not on any per-frame path.
    static func == (lhs: GhosttyRenderUpdateBody, rhs: GhosttyRenderUpdateBody) -> Bool { lhs === rhs || lhs.encodedData == rhs.encodedData }
}
