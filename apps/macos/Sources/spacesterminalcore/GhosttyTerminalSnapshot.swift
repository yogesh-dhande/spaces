import Foundation

public struct GhosttyTerminalSnapshot: Codable, Sendable, Equatable {
    /// Plain old data: four fixed-width fields and no reference. The render pipeline copies whole cell
    /// arrays on nearly every frame — decode, delta apply, viewport crop — and an array of trivial
    /// elements copies with a memcpy, while a single reference-holding field turns each of those into an
    /// element-wise retain/release pass. Text that does not fit in a codepoint rides the snapshot's
    /// `clusters` and `linkURLs` tables instead of the cell.
    public struct Cell: Codable, Sendable, Equatable {
        /// The cluster's base codepoint, and the whole of the cell's text for the overwhelming majority
        /// of cells. It stays populated even when the cell has a cluster entry, so a consumer that
        /// renders one scalar still shows the base glyph.
        public let codepoint: UInt32
        public let foregroundRGB: UInt32
        public let backgroundRGB: UInt32
        public let flags: UInt16

        public init(codepoint: UInt32, foregroundRGB: UInt32, backgroundRGB: UInt32, flags: UInt16) {
            self.codepoint = codepoint
            self.foregroundRGB = foregroundRGB
            self.backgroundRGB = backgroundRGB
            self.flags = flags
        }
    }

    /// A cluster carries at most this many codepoints. Producers that see a longer run (combining mark
    /// spam, which no legitimate glyph needs) degrade the cell to its base codepoint alone, which bounds
    /// both the per-cell copy in the producer and the payload the decoder accepts.
    public static let maximumClusterCodepointCount = 16
    public static let maximumClusterUTF8ByteCount = maximumClusterCodepointCount * 4

    public let columns: Int
    public let rows: Int
    public let cursorColumn: Int
    public let cursorRow: Int
    public let cursorVisible: Bool
    public let defaultForegroundRGB: UInt32
    public let defaultBackgroundRGB: UInt32
    public let cells: [Cell]
    /// The full grapheme cluster (base codepoint plus combining marks, ZWJ members, variation selectors,
    /// or regional indicators) of each cell that holds more than its base codepoint alone, keyed by the
    /// cell's index into `cells`. Empty for a frame of plain text, which is the fast path the wire format
    /// and the cell array are both built around.
    public let clusters: [Int: String]
    /// The OSC 8 hyperlink target of each cell that belongs to a link, keyed by the cell's index into
    /// `cells`. Empty for a frame with no links.
    public let linkURLs: [Int: String]
    /// True when the exporting terminal has a mouse tracking mode enabled. Clients arbitrate a pane
    /// click against this: while it is set the click belongs to the application, not to selection.
    public let mouseReportingActive: Bool
    /// The exporting terminal's shift-capture request as 0 = unset, 1 = false, 2 = true.
    public let mouseShiftCapture: UInt8
    /// The shared terminal selection, projected into this snapshot's viewport by the daemon. Nil when
    /// there is no selection or the selection does not intersect this viewport at all.
    public let selection: GhosttyTerminalSelectionRange?
    /// Total rows in the terminal's screen plus scrollback, as of this snapshot.
    public let scrollbarTotal: UInt32
    /// Index of this viewport's top row within `scrollbarTotal`, where 0 is the oldest row.
    public let scrollbarOffset: UInt32

    public static let mouseShiftCaptureUnset: UInt8 = 0
    public static let mouseShiftCaptureDisabled: UInt8 = 1
    public static let mouseShiftCaptureEnabled: UInt8 = 2

    public init(
        columns: Int, rows: Int, cursorColumn: Int, cursorRow: Int, cursorVisible: Bool, defaultForegroundRGB: UInt32, defaultBackgroundRGB: UInt32,
        cells: [Cell], clusters: [Int: String] = [:], linkURLs: [Int: String] = [:], mouseReportingActive: Bool = false, mouseShiftCapture: UInt8 = 0,
        selection: GhosttyTerminalSelectionRange? = nil, scrollbarTotal: UInt32 = 0, scrollbarOffset: UInt32 = 0
    ) {
        self.columns = columns
        self.rows = rows
        self.cursorColumn = cursorColumn
        self.cursorRow = cursorRow
        self.cursorVisible = cursorVisible
        self.defaultForegroundRGB = defaultForegroundRGB
        self.defaultBackgroundRGB = defaultBackgroundRGB
        self.cells = cells
        self.clusters = Self.normalizedClusters(clusters, cellCount: cells.count)
        self.linkURLs = Self.normalizedLinkURLs(linkURLs, cellCount: cells.count)
        self.mouseReportingActive = mouseReportingActive
        self.mouseShiftCapture = mouseShiftCapture
        self.selection = selection
        self.scrollbarTotal = scrollbarTotal
        self.scrollbarOffset = scrollbarOffset
    }

    /// Records `cluster` as cell `index`'s text, or clears the cell's entry when the cluster is one the
    /// wire format cannot carry: the encoder marks a payload-bearing cell with a flag bit and the decoder
    /// refuses an empty or over-cap payload, so an empty string and an over-cap cluster both degrade the
    /// cell to its base codepoint alone — the same degradation the producers apply. Every producer and
    /// the decoder insert through here, so no representable snapshot encodes to a frame its own decoder
    /// rejects.
    public static func setCluster(_ cluster: String?, forCell index: Int, in clusters: inout [Int: String]) {
        guard let cluster, isEncodableCluster(cluster) else {
            clusters[index] = nil
            return
        }
        clusters[index] = cluster
    }

    /// Records `linkURL` as cell `index`'s hyperlink target, or clears the cell's entry when there is
    /// none. An empty target is absence, for the same reason an empty cluster is: the decoder refuses a
    /// zero-length payload from a cell whose flag bit promised one.
    public static func setLinkURL(_ linkURL: String?, forCell index: Int, in linkURLs: inout [Int: String]) {
        guard let linkURL, !linkURL.isEmpty else {
            linkURLs[index] = nil
            return
        }
        linkURLs[index] = linkURL
    }

    /// Drops entries a cell block cannot carry: one naming a cell outside the block, and one whose
    /// cluster the decoder would reject. Both tables are empty on the overwhelming majority of frames,
    /// so the guard is the whole cost there.
    static func normalizedClusters(_ clusters: [Int: String], cellCount: Int) -> [Int: String] {
        guard !clusters.isEmpty else { return clusters }
        return clusters.filter { $0.key >= 0 && $0.key < cellCount && isEncodableCluster($0.value) }
    }

    /// The longest link target a cell may carry, comfortably past any real URL (browsers cap around
    /// 2,083 characters). The bound exists because the wire repeats a link's bytes on every cell of
    /// its run and encodes each entry's length as UInt16 — an unbounded URI would first inflate
    /// frames and eventually make the encoder throw, which the daemon export paths swallow, silencing
    /// render updates entirely while the link stays visible.
    public static let maximumLinkURLUTF8ByteCount = 2_048

    static func normalizedLinkURLs(_ linkURLs: [Int: String], cellCount: Int) -> [Int: String] {
        guard !linkURLs.isEmpty else { return linkURLs }
        return linkURLs.filter { $0.key >= 0 && $0.key < cellCount && !$0.value.isEmpty && $0.value.utf8.count <= maximumLinkURLUTF8ByteCount }
    }

    static func isEncodableCluster(_ cluster: String) -> Bool {
        !cluster.isEmpty && cluster.unicodeScalars.count <= maximumClusterCodepointCount && cluster.utf8.count <= maximumClusterUTF8ByteCount
    }
}

public struct GhosttyRenderFrame: Codable, Sendable, Equatable {
    public static let currentVersion = 1

    /// Upper bound any accumulator of `scrollRects` across frames applies before falling back to the
    /// overflowed state: content that moved through this many rects has scrolled far past any local
    /// anchor worth carrying, and an unbounded accumulation (a stalled main actor coalescing frames, a
    /// view that cannot apply for a while) would otherwise grow without limit. Shared by the reduction
    /// pipeline's coalesce merge and the mirror view's drag-carry buffer so the two bounds cannot drift.
    public static let maxAccumulatedScrollRects = 512

    public let version: Int
    public let sessionRevision: UInt64?
    public let ownerEpoch: UInt64
    public let columns: Int
    public let rows: Int
    public let snapshot: GhosttyTerminalSnapshot
    /// How the terminal's content moved to produce this frame from the previously materialized one, so a
    /// mirror view can carry a local drag-selection anchor across the repaint. Empty for a frame that is
    /// not a delta continuation (an initial baseline, a full re-baseline, or a resync) — see
    /// `scrollRectsOverflowed` for why those still need a value here.
    public let scrollRects: [GhosttyRenderScrollRectOperation]
    /// True when `scrollRects` cannot be trusted to fully describe how content moved since the previous
    /// frame: either the producing delta's own scroll-rect ring buffer overflowed, or this frame is not a
    /// delta continuation at all (a full/re-baseline frame carries the whole grid, not a diff, so it has
    /// no scroll rects to report). A consumer accumulating rects across skipped frames must poison its
    /// buffer whenever this is true. Defaults to true so that only a construction site that positively
    /// knows how content moved since the previous frame (the delta materializer) can claim a trustworthy
    /// carry; every other frame (baselines, replay repaints, daemon-side frames whose carry fields are
    /// never read) is untrusted by default.
    public let scrollRectsOverflowed: Bool

    public init(
        version: Int = Self.currentVersion, sessionRevision: UInt64?, ownerEpoch: UInt64, snapshot: GhosttyTerminalSnapshot,
        scrollRects: [GhosttyRenderScrollRectOperation] = [], scrollRectsOverflowed: Bool = true
    ) {
        self.version = version
        self.sessionRevision = sessionRevision
        self.ownerEpoch = ownerEpoch
        self.columns = snapshot.columns
        self.rows = snapshot.rows
        self.snapshot = snapshot
        self.scrollRects = scrollRects
        self.scrollRectsOverflowed = scrollRectsOverflowed
    }

    public static func encode(_ frame: GhosttyRenderFrame) throws -> Data { try JSONEncoder().encode(frame) }

    public static func decode(_ data: Data) throws -> GhosttyRenderFrame { try JSONDecoder().decode(GhosttyRenderFrame.self, from: data) }
}
