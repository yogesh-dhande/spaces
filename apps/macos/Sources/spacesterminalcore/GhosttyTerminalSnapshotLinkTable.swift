import Foundation

/// Flattens a snapshot's per-cell OSC 8 link targets into the shape the Ghostty C snapshot carries: a
/// deduplicated link table (one URI per distinct target, in one contiguous byte buffer), plus the
/// 1-based table index each linked cell points at. Both mirror views build their C frame through this,
/// so a Mac pane and an iOS pane hand Ghostty identical link tables.
///
/// Deduplication is by URI bytes, which is also how the fork's exporter builds its table. Two
/// side-by-side links with the same target therefore share one page hyperlink and underline together.
///
/// A frame without links, nearly every frame, produces empty values and allocates nothing.
public enum GhosttyTerminalSnapshotLinkTable {
    /// Where one distinct target lives inside the flattened byte buffer.
    public struct Entry: Sendable, Equatable {
        public let offset: Int
        public let count: Int

        public init(offset: Int, count: Int) {
            self.offset = offset
            self.count = count
        }
    }

    public struct Flattened: Sendable, Equatable {
        /// Mutable so a caller can hand Ghostty a pointer into it: the C table's string pointers
        /// address this buffer, and it is only ever read across that call.
        public var uriBytes: [UInt8]
        /// The table, in first-appearance order by cell index.
        public let entries: [Entry]
        /// Each linked cell's 1-based index into ``entries``.
        public let cellLinkIndexes: [Int: UInt32]

        public init(uriBytes: [UInt8], entries: [Entry], cellLinkIndexes: [Int: UInt32]) {
            self.uriBytes = uriBytes
            self.entries = entries
            self.cellLinkIndexes = cellLinkIndexes
        }
    }

    /// Cells are visited in index order so a frame flattens to the same table every time.
    public static func flatten(_ snapshot: GhosttyTerminalSnapshot) -> Flattened {
        guard !snapshot.linkURLs.isEmpty else { return Flattened(uriBytes: [], entries: [], cellLinkIndexes: [:]) }
        var uriBytes: [UInt8] = []
        var entries: [Entry] = []
        // Keyed by UTF-8 bytes, not `String`: String equality is Unicode canonical equivalence, so two
        // targets that differ only in normalization ("caf\u{E9}" and "cafe\u{301}") would collapse into
        // one entry and the second label would open the first target.
        var indexByURL: [[UInt8]: UInt32] = [:]
        var cellLinkIndexes: [Int: UInt32] = [:]
        for cellIndex in snapshot.linkURLs.keys.sorted() {
            guard let url = snapshot.linkURLs[cellIndex], !url.isEmpty else { continue }
            let bytes = Array(url.utf8)
            if let existing = indexByURL[bytes] {
                cellLinkIndexes[cellIndex] = existing
                continue
            }
            entries.append(Entry(offset: uriBytes.count, count: bytes.count))
            uriBytes.append(contentsOf: bytes)
            let index = UInt32(entries.count)
            indexByURL[bytes] = index
            cellLinkIndexes[cellIndex] = index
        }
        return Flattened(uriBytes: uriBytes, entries: entries, cellLinkIndexes: cellLinkIndexes)
    }
}
