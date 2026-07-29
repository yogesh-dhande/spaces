import Foundation

/// Flattens a snapshot's per-cell grapheme clusters into the shape the Ghostty C snapshot carries: one
/// contiguous codepoint buffer, plus the slice of it each cluster-bearing cell points at. Both mirror
/// views build their C frame through this, so a Mac pane and an iOS pane hand Ghostty identical
/// clusters.
///
/// The cell's base codepoint travels in the C cell itself, so only the codepoints after the first are
/// flattened here. A frame whose cells are all single-codepoint — nearly every frame — produces two
/// empty arrays and allocates nothing.
public enum GhosttyTerminalSnapshotClusterExtras {
    /// Where one cell's extra codepoints live inside the flattened buffer.
    public struct Placement: Sendable, Equatable {
        public let cellIndex: Int
        public let offset: Int
        public let count: Int

        public init(cellIndex: Int, offset: Int, count: Int) {
            self.cellIndex = cellIndex
            self.offset = offset
            self.count = count
        }
    }

    public struct Flattened: Sendable, Equatable {
        /// Mutable so a caller can hand Ghostty a pointer into it: the C cell's cluster field is a
        /// mutable pointer, and the buffer is only ever read across that call.
        public var codepoints: [UInt32]
        public let placements: [Placement]

        public init(codepoints: [UInt32], placements: [Placement]) {
            self.codepoints = codepoints
            self.placements = placements
        }
    }

    /// The extra codepoints one cell may contribute. A cluster carries at most
    /// `maximumClusterCodepointCount` codepoints including its base, and the C snapshot documents the
    /// same bound; clamping here keeps a cluster that reached this process without going through the
    /// snapshot's normalization inside what Ghostty accepts.
    public static let maximumExtraCodepointCount = GhosttyTerminalSnapshot.maximumClusterCodepointCount - 1

    /// Cells are visited in index order so a frame flattens to the same buffer every time, which is what
    /// lets the mirror compare one flattened frame against another.
    public static func flatten(_ snapshot: GhosttyTerminalSnapshot) -> Flattened {
        guard !snapshot.clusters.isEmpty else { return Flattened(codepoints: [], placements: []) }
        var codepoints: [UInt32] = []
        var placements: [Placement] = []
        for index in snapshot.clusters.keys.sorted() {
            guard let cluster = snapshot.clusters[index] else { continue }
            let extras = cluster.unicodeScalars.dropFirst().prefix(maximumExtraCodepointCount).map(\.value)
            guard !extras.isEmpty else { continue }
            placements.append(Placement(cellIndex: index, offset: codepoints.count, count: extras.count))
            codepoints.append(contentsOf: extras)
        }
        return Flattened(codepoints: codepoints, placements: placements)
    }
}
