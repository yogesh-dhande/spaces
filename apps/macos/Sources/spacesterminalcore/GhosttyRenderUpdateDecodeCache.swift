import Foundation

/// Memoizes `GhosttyRenderUpdateBinaryCodec.decode` for a small set of recent render-update
/// blobs. The decoded update is exposed through `GhosttyRemoteSessionStatePayload`'s computed
/// accessors (`decodedRenderUpdate`, `renderSnapshot`, `renderOwnerEpoch`, …), and a payload that
/// arrived over a wire or came off disk is read through them repeatedly: a bootstrap payload's grid,
/// owner epoch, and text are separate reads of one blob. Caching by blob identity collapses those to
/// one decode per distinct payload. A payload a client materialized carries the decoded update
/// directly and never reaches this cache.
///
/// `NSCache` is thread-safe and available in swift-corelibs-foundation, so this stays
/// Foundation-only for the Linux build. Keys are `Data as NSData`: CFData's hash covers the
/// header bytes (which carry per-frame revisions), and NSCache resolves any hash collision with a
/// full `isEqual:` (memcmp), so distinct blobs never alias. `countLimit` is deliberately tiny —
/// each entry is a full grid snapshot that can reach hundreds of KB.
public enum GhosttyRenderUpdateDecodeCache {
    private final class Box {
        let update: GhosttyRenderUpdate
        init(_ update: GhosttyRenderUpdate) { self.update = update }
    }

    nonisolated(unsafe) private static let cache: NSCache<NSData, Box> = {
        let cache = NSCache<NSData, Box>()
        cache.countLimit = 8
        return cache
    }()

    /// Returns the decoded update for `data`, decoding on a miss. Decode failures return nil and
    /// are not cached (the blob is malformed and will not become valid on retry).
    public static func decodedUpdate(for data: Data) -> GhosttyRenderUpdate? {
        let key = data as NSData
        if let cached = cache.object(forKey: key) { return cached.update }
        guard let update = try? GhosttyRenderUpdateBinaryCodec.decode(data) else { return nil }
        cache.setObject(Box(update), forKey: key)
        return update
    }
}
