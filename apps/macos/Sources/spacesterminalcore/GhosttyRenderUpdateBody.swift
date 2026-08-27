import Foundation

public struct GhosttyRenderUpdateEncodingResult: Sendable, Equatable {
    public let byteCount: Int
    public let elapsedMS: Int
    public let succeeded: Bool

    public init(byteCount: Int, elapsedMS: Int, succeeded: Bool) {
        self.byteCount = byteCount
        self.elapsedMS = elapsedMS
        self.succeeded = succeeded
    }
}

public typealias GhosttyRenderUpdateEncodingObserver = @Sendable (GhosttyRenderUpdateEncodingResult) -> Void

/// The render update a `GhosttyRemoteSessionStatePayload` carries, held in whichever form its
/// producer already has it.
///
/// A payload that arrived over a wire or came off disk holds the encoded blob. A payload built from live
/// terminal state or materialized by a client locally holds the decoded update. Live producers can then
/// leave serialization to their per-session transport queue, while `TerminalRemoteStateReducer` can
/// apply each incoming delta to its baseline and store the resulting full frame without encoding bytes
/// no client reads. Every client-side read of that stored payload (`decodedRenderUpdate`,
/// `renderSnapshot`, `renderOwnerEpoch`, `renderText`) wants the decoded value.
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
    private let encodingObserver: GhosttyRenderUpdateEncodingObserver?
    private let lock = NSLock()
    private var encodedCache: Data?
    private var didAttemptEncoding = false

    init(encoded data: Data) {
        source = .encoded(data)
        encodingObserver = nil
        encodedCache = data
        didAttemptEncoding = true
    }

    init(materialized update: GhosttyRenderUpdate, encodingObserver: GhosttyRenderUpdateEncodingObserver? = nil) {
        source = .materialized(update)
        self.encodingObserver = encodingObserver
    }

    /// The update's kind without decoding its grid: the value's own kind for a materialized body, a
    /// header read for an encoded one (see `GhosttyRenderUpdateBinaryCodec.encodedKind(of:)`). Nil when an
    /// encoded body is not something this build can decode at all.
    var kind: GhosttyRenderUpdateKind? {
        switch source {
        case .materialized(let update): update.kind
        case .encoded(let data): GhosttyRenderUpdateBinaryCodec.encodedKind(of: data)
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
    /// fields. Client-reduced updates inherit those fields from decoded wire input; live producers use
    /// terminal grids constrained far below the same limits. Nil here means the serialized payload carries
    /// no render update, which is what eager producer and reducer encoding yielded on failure.
    var encodedData: Data? {
        lock.lock()
        if didAttemptEncoding {
            let encoded = encodedCache
            lock.unlock()
            return encoded
        }
        guard case .materialized(let update) = source else {
            lock.unlock()
            return nil
        }
        let startedAt = encodingObserver == nil ? nil : Date()
        let encoded = try? GhosttyRenderUpdateBinaryCodec.encode(update)
        encodedCache = encoded
        didAttemptEncoding = true
        let observer = encodingObserver
        let result = startedAt.map {
            GhosttyRenderUpdateEncodingResult(
                byteCount: encoded?.count ?? 0, elapsedMS: TerminalPerformance.elapsedMS(since: $0), succeeded: encoded != nil)
        }
        lock.unlock()
        if let result { observer?(result) }
        return encoded
    }

    /// Whether a materialized update is still waiting for its first wire serialization. Kept internal
    /// so focused tests can enforce the performance contract without reading `encodedData` and thereby
    /// performing the very encode they are checking was deferred.
    var isEncodingDeferred: Bool {
        lock.lock()
        defer { lock.unlock() }
        guard case .materialized = source else { return false }
        return !didAttemptEncoding
    }
}

extension GhosttyRenderUpdateBody: Equatable {
    /// Two bodies are equal when they carry the same wire bytes, which is what payload equality meant
    /// while the payload stored the blob directly. Comparing a materialized body forces its encode, so
    /// equality is deliberately not on any per-frame path.
    static func == (lhs: GhosttyRenderUpdateBody, rhs: GhosttyRenderUpdateBody) -> Bool { lhs === rhs || lhs.encodedData == rhs.encodedData }
}
