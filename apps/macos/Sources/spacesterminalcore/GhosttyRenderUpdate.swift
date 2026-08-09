import Foundation

public enum GhosttyRenderUpdateKind: String, Codable, Sendable, Equatable {
    case full
    case delta
    case resyncRequired
}

public struct GhosttyRenderScrollRectOperation: Codable, Sendable, Equatable {
    public let rowStart: Int
    public let rowCount: Int
    public let columnStart: Int
    public let columnCount: Int
    public let deltaRows: Int
    public let deltaColumns: Int

    public init(rowStart: Int, rowCount: Int, columnStart: Int, columnCount: Int, deltaRows: Int, deltaColumns: Int) {
        self.rowStart = rowStart
        self.rowCount = rowCount
        self.columnStart = columnStart
        self.columnCount = columnCount
        self.deltaRows = deltaRows
        self.deltaColumns = deltaColumns
    }
}

public struct GhosttyRenderCellRun: Codable, Sendable, Equatable {
    public let row: Int
    public let column: Int
    public let cells: [GhosttyTerminalSnapshot.Cell]
    /// The run's grapheme clusters and OSC 8 targets, keyed by index *within `cells`* rather than into
    /// the grid, so a run is positioned by its own `row`/`column` alone. Applying the run rebases them
    /// onto the destination cells.
    public let clusters: [Int: String]
    public let linkURLs: [Int: String]

    public init(row: Int, column: Int, cells: [GhosttyTerminalSnapshot.Cell], clusters: [Int: String] = [:], linkURLs: [Int: String] = [:]) {
        self.row = row
        self.column = column
        self.cells = cells
        self.clusters = GhosttyTerminalSnapshot.normalizedClusters(clusters, cellCount: cells.count)
        self.linkURLs = GhosttyTerminalSnapshot.normalizedLinkURLs(linkURLs, cellCount: cells.count)
    }
}

public struct GhosttyRenderDeltaFrame: Codable, Sendable, Equatable {
    public let baseRevision: UInt64?
    public let targetRevision: UInt64?
    public let ownerEpoch: UInt64
    public let columns: Int
    public let rows: Int
    public let cursorColumn: Int
    public let cursorRow: Int
    public let cursorVisible: Bool
    public let defaultForegroundRGB: UInt32
    public let defaultBackgroundRGB: UInt32
    /// Mouse-reporting state of the target frame. Deltas carry it alongside the cursor state so a
    /// client's arbitration tracks an application enabling or disabling mouse tracking mid-stream,
    /// which is a screen change that never forces a full frame.
    public let mouseReportingActive: Bool
    public let mouseShiftCapture: UInt8
    public let scrollRects: [GhosttyRenderScrollRectOperation]
    public let replaceCellRuns: [GhosttyRenderCellRun]
    public let changedCellCount: Int

    public init(
        baseRevision: UInt64?, targetRevision: UInt64?, ownerEpoch: UInt64, columns: Int, rows: Int, cursorColumn: Int, cursorRow: Int,
        cursorVisible: Bool, defaultForegroundRGB: UInt32, defaultBackgroundRGB: UInt32, mouseReportingActive: Bool = false,
        mouseShiftCapture: UInt8 = 0, scrollRects: [GhosttyRenderScrollRectOperation] = [], replaceCellRuns: [GhosttyRenderCellRun] = [],
        changedCellCount: Int
    ) {
        self.baseRevision = baseRevision
        self.targetRevision = targetRevision
        self.ownerEpoch = ownerEpoch
        self.columns = columns
        self.rows = rows
        self.cursorColumn = cursorColumn
        self.cursorRow = cursorRow
        self.cursorVisible = cursorVisible
        self.defaultForegroundRGB = defaultForegroundRGB
        self.defaultBackgroundRGB = defaultBackgroundRGB
        self.mouseReportingActive = mouseReportingActive
        self.mouseShiftCapture = mouseShiftCapture
        self.scrollRects = scrollRects
        self.replaceCellRuns = replaceCellRuns
        self.changedCellCount = changedCellCount
    }
}

public struct GhosttyRenderUpdate: Codable, Sendable, Equatable {
    // Version 4 added the sparse per-cell grapheme cluster and OSC 8 link payloads to both binary
    // bodies. The version byte is the only guard for payloads that outlive a build (persisted final
    // frames, demo recordings), so any layout change must bump it — decoders reject other versions
    // rather than misread offsets. There is deliberately no decoder for older versions: pre-release,
    // a persisted final frame from an earlier build rendering as "no final frame" once is accepted
    // over carrying a compatibility path, and live sessions re-export at the current version on the
    // next frame.
    public static let currentVersion = 4

    public let version: Int
    public let kind: GhosttyRenderUpdateKind
    public let sessionRevision: UInt64?
    public let baseRevision: UInt64?
    public let targetRevision: UInt64?
    public let ownerEpoch: UInt64
    public let columns: Int
    public let rows: Int
    public let fullFrame: GhosttyRenderFrame?
    public let delta: GhosttyRenderDeltaFrame?
    public let fallbackReason: String?

    public init(
        version: Int = Self.currentVersion, kind: GhosttyRenderUpdateKind, sessionRevision: UInt64?, baseRevision: UInt64?, targetRevision: UInt64?,
        ownerEpoch: UInt64, columns: Int, rows: Int, fullFrame: GhosttyRenderFrame?, delta: GhosttyRenderDeltaFrame?, fallbackReason: String? = nil
    ) {
        self.version = version
        self.kind = kind
        self.sessionRevision = sessionRevision
        self.baseRevision = baseRevision
        self.targetRevision = targetRevision
        self.ownerEpoch = ownerEpoch
        self.columns = columns
        self.rows = rows
        self.fullFrame = fullFrame
        self.delta = delta
        self.fallbackReason = fallbackReason
    }

    public static func full(_ frame: GhosttyRenderFrame, fallbackReason: String? = nil) -> Self {
        .init(
            kind: .full, sessionRevision: frame.sessionRevision, baseRevision: nil, targetRevision: frame.sessionRevision,
            ownerEpoch: frame.ownerEpoch, columns: frame.columns, rows: frame.rows, fullFrame: frame, delta: nil, fallbackReason: fallbackReason)
    }

    public static func delta(_ delta: GhosttyRenderDeltaFrame) -> Self {
        .init(
            kind: .delta, sessionRevision: delta.targetRevision, baseRevision: delta.baseRevision, targetRevision: delta.targetRevision,
            ownerEpoch: delta.ownerEpoch, columns: delta.columns, rows: delta.rows, fullFrame: nil, delta: delta)
    }

    public static func resyncRequired(sessionRevision: UInt64?, ownerEpoch: UInt64, columns: Int, rows: Int, fallbackReason: String? = nil) -> Self {
        .init(
            kind: .resyncRequired, sessionRevision: sessionRevision, baseRevision: nil, targetRevision: sessionRevision, ownerEpoch: ownerEpoch,
            columns: columns, rows: rows, fullFrame: nil, delta: nil, fallbackReason: fallbackReason)
    }

    public var frameKindMetricValue: String { kind == .resyncRequired ? "resync_required" : kind.rawValue }
    public var operationCount: Int { (delta?.replaceCellRuns.count ?? 0) + (delta?.scrollRects.count ?? 0) }
    public var changedCellCount: Int { delta?.changedCellCount ?? fullFrame?.snapshot.cells.count ?? 0 }
    public var scrollOperationCount: Int { delta?.scrollRects.count ?? 0 }
}

public struct GhosttyRenderUpdateBaseline: Sendable, Equatable {
    public let snapshot: GhosttyTerminalSnapshot
    public let sessionRevision: UInt64?
    public let ownerEpoch: UInt64

    public init(snapshot: GhosttyTerminalSnapshot, sessionRevision: UInt64?, ownerEpoch: UInt64) {
        self.snapshot = snapshot
        self.sessionRevision = sessionRevision
        self.ownerEpoch = ownerEpoch
    }

    public init(frame: GhosttyRenderFrame) {
        self.init(snapshot: frame.snapshot, sessionRevision: frame.sessionRevision, ownerEpoch: frame.ownerEpoch)
    }
}

public enum GhosttyRenderUpdateApplyError: Error, Sendable, Equatable {
    case missingBaseline
    case versionMismatch
    case missingFullFrame
    case missingDelta
    case resyncRequired
    case baseRevisionMismatch(expected: UInt64?, actual: UInt64?)
    case ownerEpochMismatch(expected: UInt64, actual: UInt64)
    case dimensionMismatch
    case invalidOperation
}

/// A grid of cells together with the sparse cluster/link tables that name cells inside it. Both the
/// delta applier and the delta producer shift rectangles of cells around the grid, and a cell's text has
/// to travel with it — the tables are keyed by cell index, so every move rekeys them. Keeping the three
/// in one value is what stops the two scroll implementations from drifting apart.
struct GhosttyRenderCellGrid {
    var cells: [GhosttyTerminalSnapshot.Cell]
    var clusters: [Int: String]
    var linkURLs: [Int: String]
    let columns: Int

    /// Blanks the rect and then moves its previous contents by the operation's delta, dropping whatever
    /// falls outside the rect. Callers validate the rect against the grid's bounds first.
    mutating func scroll(_ operation: GhosttyRenderScrollRectOperation, blank: GhosttyTerminalSnapshot.Cell) {
        guard operation.rowCount > 0, operation.columnCount > 0 else { return }
        let rows = operation.rowStart..<(operation.rowStart + operation.rowCount)
        let columnRange = operation.columnStart..<(operation.columnStart + operation.columnCount)

        let originalCells = cells
        for row in rows { for column in columnRange { cells[row * columns + column] = blank } }
        for sourceRow in rows {
            for sourceColumn in columnRange {
                guard let destination = destination(ofRow: sourceRow, column: sourceColumn, operation: operation) else { continue }
                cells[destination] = originalCells[sourceRow * columns + sourceColumn]
            }
        }

        // The text tables move the same way, in their own pass so a grid with no cluster or link — every
        // frame of plain output — pays only this guard for the whole rect.
        guard !clusters.isEmpty || !linkURLs.isEmpty else { return }
        let originalClusters = clusters
        let originalLinkURLs = linkURLs
        for row in rows {
            for column in columnRange {
                clusters[row * columns + column] = nil
                linkURLs[row * columns + column] = nil
            }
        }
        for sourceRow in rows {
            for sourceColumn in columnRange {
                guard let destination = destination(ofRow: sourceRow, column: sourceColumn, operation: operation) else { continue }
                let source = sourceRow * columns + sourceColumn
                clusters[destination] = originalClusters[source]
                linkURLs[destination] = originalLinkURLs[source]
            }
        }
    }

    /// Where a cell of the rect lands, or nil when the delta carries it out of the rect entirely.
    private func destination(ofRow row: Int, column: Int, operation: GhosttyRenderScrollRectOperation) -> Int? {
        let destinationRow = row + operation.deltaRows
        let destinationColumn = column + operation.deltaColumns
        guard destinationRow >= operation.rowStart, destinationRow < operation.rowStart + operation.rowCount,
            destinationColumn >= operation.columnStart, destinationColumn < operation.columnStart + operation.columnCount
        else { return nil }
        return destinationRow * columns + destinationColumn
    }
}

public enum GhosttyRenderUpdateApplier {
    public static func apply(_ update: GhosttyRenderUpdate, to baseline: GhosttyRenderUpdateBaseline?) throws -> GhosttyRenderUpdateBaseline {
        guard update.version == GhosttyRenderUpdate.currentVersion else { throw GhosttyRenderUpdateApplyError.versionMismatch }
        switch update.kind {
        case .full:
            guard let fullFrame = update.fullFrame else { throw GhosttyRenderUpdateApplyError.missingFullFrame }
            return GhosttyRenderUpdateBaseline(frame: fullFrame)
        case .resyncRequired: throw GhosttyRenderUpdateApplyError.resyncRequired
        case .delta:
            guard let delta = update.delta else { throw GhosttyRenderUpdateApplyError.missingDelta }
            guard let baseline else { throw GhosttyRenderUpdateApplyError.missingBaseline }
            guard baseline.sessionRevision == delta.baseRevision else {
                throw GhosttyRenderUpdateApplyError.baseRevisionMismatch(expected: delta.baseRevision, actual: baseline.sessionRevision)
            }
            guard baseline.ownerEpoch == delta.ownerEpoch else {
                throw GhosttyRenderUpdateApplyError.ownerEpochMismatch(expected: delta.ownerEpoch, actual: baseline.ownerEpoch)
            }
            guard baseline.snapshot.columns == delta.columns, baseline.snapshot.rows == delta.rows else {
                throw GhosttyRenderUpdateApplyError.dimensionMismatch
            }
            let snapshot = try apply(delta, to: baseline.snapshot)
            return GhosttyRenderUpdateBaseline(snapshot: snapshot, sessionRevision: delta.targetRevision, ownerEpoch: delta.ownerEpoch)
        }
    }

    public static func apply(_ delta: GhosttyRenderDeltaFrame, to baseline: GhosttyTerminalSnapshot) throws -> GhosttyTerminalSnapshot {
        guard baseline.columns == delta.columns, baseline.rows == delta.rows else { throw GhosttyRenderUpdateApplyError.dimensionMismatch }
        guard baseline.cells.count >= baseline.columns * baseline.rows else { throw GhosttyRenderUpdateApplyError.invalidOperation }

        var grid = GhosttyRenderCellGrid(
            cells: Array(baseline.cells.prefix(baseline.columns * baseline.rows)), clusters: baseline.clusters, linkURLs: baseline.linkURLs,
            columns: baseline.columns)
        for operation in delta.scrollRects {
            guard operation.rowStart >= 0, operation.rowCount >= 0, operation.columnStart >= 0, operation.columnCount >= 0 else {
                throw GhosttyRenderUpdateApplyError.invalidOperation
            }
            guard operation.rowStart + operation.rowCount <= baseline.rows, operation.columnStart + operation.columnCount <= baseline.columns else {
                throw GhosttyRenderUpdateApplyError.invalidOperation
            }
            grid.scroll(operation, blank: blankCell(for: delta))
        }
        for run in delta.replaceCellRuns { try applyCellRun(run, to: &grid, rows: baseline.rows) }
        return GhosttyTerminalSnapshot(
            columns: delta.columns, rows: delta.rows, cursorColumn: delta.cursorColumn, cursorRow: delta.cursorRow,
            cursorVisible: delta.cursorVisible, defaultForegroundRGB: delta.defaultForegroundRGB, defaultBackgroundRGB: delta.defaultBackgroundRGB,
            cells: grid.cells, clusters: grid.clusters, linkURLs: grid.linkURLs, mouseReportingActive: delta.mouseReportingActive,
            mouseShiftCapture: delta.mouseShiftCapture)
    }

    /// Writes the run's cells at its start index, then rebases the run's own cluster/link entries — keyed
    /// within the run — onto the destination indices. The rebase pass writes every index the run covers,
    /// including the ones the run has no entry for, so an ASCII cell landing on a cluster cell clears it.
    private static func applyCellRun(_ run: GhosttyRenderCellRun, to grid: inout GhosttyRenderCellGrid, rows: Int) throws {
        guard run.row >= 0, run.row < rows, run.column >= 0, run.column + run.cells.count <= grid.columns else {
            throw GhosttyRenderUpdateApplyError.invalidOperation
        }
        let start = run.row * grid.columns + run.column
        grid.cells.replaceSubrange(start..<(start + run.cells.count), with: run.cells)
        guard !grid.clusters.isEmpty || !grid.linkURLs.isEmpty || !run.clusters.isEmpty || !run.linkURLs.isEmpty else { return }
        for offset in 0..<run.cells.count {
            grid.clusters[start + offset] = run.clusters[offset]
            grid.linkURLs[start + offset] = run.linkURLs[offset]
        }
    }

    private static func blankCell(for delta: GhosttyRenderDeltaFrame) -> GhosttyTerminalSnapshot.Cell {
        GhosttyTerminalSnapshot.Cell(codepoint: 0, foregroundRGB: delta.defaultForegroundRGB, backgroundRGB: delta.defaultBackgroundRGB, flags: 0)
    }
}

public enum GhosttyRenderUpdateFactory {
    public static func makeUpdate(
        target frame: GhosttyRenderFrame, baseline: GhosttyRenderUpdateBaseline?, forceFull: Bool = false,
        forceFullReason: String = "initial_baseline", nativeScrollRects: [GhosttyRenderScrollRectOperation] = []
    ) -> GhosttyRenderUpdate {
        guard !forceFull else { return .full(frame, fallbackReason: forceFullReason) }
        guard let baseline else { return .full(frame, fallbackReason: "missing_baseline") }
        guard canDelta(from: baseline, to: frame) else { return .full(frame, fallbackReason: "baseline_mismatch") }
        guard validGrid(frame.snapshot), validGrid(baseline.snapshot) else { return .full(frame, fallbackReason: "invalid_grid") }
        guard let scrollRects = validatedScrollRects(nativeScrollRects, columns: frame.columns, rows: frame.rows) else {
            return .full(frame, fallbackReason: "invalid_scroll_rect")
        }

        let delta = makeDelta(from: baseline, to: frame, scrollRects: scrollRects)
        return GhosttyRenderUpdate.delta(delta)
    }

    private static func canDelta(from baseline: GhosttyRenderUpdateBaseline, to frame: GhosttyRenderFrame) -> Bool {
        baseline.ownerEpoch == frame.ownerEpoch && baseline.snapshot.columns == frame.snapshot.columns
            && baseline.snapshot.rows == frame.snapshot.rows
    }

    private static func validGrid(_ snapshot: GhosttyTerminalSnapshot) -> Bool {
        snapshot.columns > 0 && snapshot.rows > 0 && snapshot.cells.count >= snapshot.columns * snapshot.rows
    }

    private static func makeDelta(
        from baseline: GhosttyRenderUpdateBaseline, to frame: GhosttyRenderFrame, scrollRects: [GhosttyRenderScrollRectOperation]
    ) -> GhosttyRenderDeltaFrame {
        let previous = normalized(baseline.snapshot)
        let target = normalized(frame.snapshot)
        // The producer scrolls its copy of the baseline exactly as the client's applier will, text
        // tables included, so the diff below only reports what the scroll rects did not already deliver.
        var scrolled = GhosttyRenderCellGrid(cells: previous.cells, clusters: previous.clusters, linkURLs: previous.linkURLs, columns: target.columns)
        let blank = GhosttyTerminalSnapshot.Cell(
            codepoint: 0, foregroundRGB: target.defaultForegroundRGB, backgroundRGB: target.defaultBackgroundRGB, flags: 0)
        for operation in scrollRects { scrolled.scroll(operation, blank: blank) }
        let runs = changedRuns(from: scrolled, to: target)
        return GhosttyRenderDeltaFrame(
            baseRevision: baseline.sessionRevision, targetRevision: frame.sessionRevision, ownerEpoch: frame.ownerEpoch, columns: target.columns,
            rows: target.rows, cursorColumn: target.cursorColumn, cursorRow: target.cursorRow, cursorVisible: target.cursorVisible,
            defaultForegroundRGB: target.defaultForegroundRGB, defaultBackgroundRGB: target.defaultBackgroundRGB,
            mouseReportingActive: target.mouseReportingActive, mouseShiftCapture: target.mouseShiftCapture, scrollRects: scrollRects,
            replaceCellRuns: runs, changedCellCount: runs.reduce(0) { $0 + $1.cells.count })
    }

    private static func normalized(_ snapshot: GhosttyTerminalSnapshot) -> GhosttyTerminalSnapshot {
        let requiredCount = max(snapshot.columns * snapshot.rows, 0)
        guard snapshot.cells.count != requiredCount else { return snapshot }
        let blank = GhosttyTerminalSnapshot.Cell(
            codepoint: 0, foregroundRGB: snapshot.defaultForegroundRGB, backgroundRGB: snapshot.defaultBackgroundRGB, flags: 0)
        let cells = Array(snapshot.cells.prefix(requiredCount)) + Array(repeating: blank, count: max(requiredCount - snapshot.cells.count, 0))
        // Padding blanks carry no text, and the snapshot's own init drops entries naming a cell past the
        // truncated end, so the tables need no separate trim here.
        return GhosttyTerminalSnapshot(
            columns: snapshot.columns, rows: snapshot.rows, cursorColumn: snapshot.cursorColumn, cursorRow: snapshot.cursorRow,
            cursorVisible: snapshot.cursorVisible, defaultForegroundRGB: snapshot.defaultForegroundRGB,
            defaultBackgroundRGB: snapshot.defaultBackgroundRGB, cells: cells, clusters: snapshot.clusters, linkURLs: snapshot.linkURLs,
            mouseReportingActive: snapshot.mouseReportingActive, mouseShiftCapture: snapshot.mouseShiftCapture)
    }

    private static func validatedScrollRects(_ scrollRects: [GhosttyRenderScrollRectOperation], columns: Int, rows: Int)
        -> [GhosttyRenderScrollRectOperation]?
    {
        guard columns > 0, rows > 0 else { return nil }
        for operation in scrollRects {
            guard operation.rowStart >= 0, operation.rowCount > 0, operation.columnStart >= 0, operation.columnCount > 0 else { return nil }
            guard operation.rowCount <= rows, operation.columnCount <= columns else { return nil }
            guard operation.rowStart <= rows - operation.rowCount, operation.columnStart <= columns - operation.columnCount else { return nil }
            guard operation.deltaRows != 0 || operation.deltaColumns != 0 else { return nil }
            guard operation.deltaRows > -operation.rowCount, operation.deltaRows < operation.rowCount else { return nil }
            guard operation.deltaColumns > -operation.columnCount, operation.deltaColumns < operation.columnCount else { return nil }
        }
        return scrollRects
    }

    /// The runs of cells that differ between the scrolled baseline and the target. A cell's text lives
    /// beside it, so two identical cells whose clusters or links differ are still a change — the
    /// skin-tone case, where the base codepoint is the same glyph. Comparing the tables is gated on
    /// either side holding any entry at all, so a frame of plain output compares exactly the four
    /// fixed-width fields it did before clusters existed.
    private static func changedRuns(from previous: GhosttyRenderCellGrid, to target: GhosttyTerminalSnapshot) -> [GhosttyRenderCellRun] {
        let columns = target.columns
        let previousCells = previous.cells
        let targetCells = target.cells
        let comparesText = !previous.clusters.isEmpty || !previous.linkURLs.isEmpty || !target.clusters.isEmpty || !target.linkURLs.isEmpty

        var runs: [GhosttyRenderCellRun] = []
        for row in 0..<target.rows {
            var column = 0
            while column < columns {
                let cellIndex = row * columns + column
                guard
                    previousCells[cellIndex] != targetCells[cellIndex]
                        || (comparesText
                            && (previous.clusters[cellIndex] != target.clusters[cellIndex]
                                || previous.linkURLs[cellIndex] != target.linkURLs[cellIndex]))
                else {
                    column += 1
                    continue
                }
                let runStart = column
                var runCells: [GhosttyTerminalSnapshot.Cell] = []
                var runClusters: [Int: String] = [:]
                var runLinkURLs: [Int: String] = [:]
                while column < columns {
                    let index = row * columns + column
                    guard
                        previousCells[index] != targetCells[index]
                            || (comparesText
                                && (previous.clusters[index] != target.clusters[index] || previous.linkURLs[index] != target.linkURLs[index]))
                    else { break }
                    if comparesText {
                        if let cluster = target.clusters[index] { runClusters[runCells.count] = cluster }
                        if let linkURL = target.linkURLs[index] { runLinkURLs[runCells.count] = linkURL }
                    }
                    runCells.append(targetCells[index])
                    column += 1
                }
                runs.append(GhosttyRenderCellRun(row: row, column: runStart, cells: runCells, clusters: runClusters, linkURLs: runLinkURLs))
            }
        }
        return runs
    }
}

public enum GhosttyRenderUpdateBinaryCodec {
    private static let magic: [UInt8] = [0x47, 0x52, 0x54, 0x55]
    private static let nilRevision = UInt64.max

    // The two high bits of a cell's wire flags word are reserved by the codec to mark that the cell is
    // followed by a text payload in its block's sparse section. Style flags occupy bits 0-10 (see
    // GhosttyTerminalSnapshotGrid), never these, so the encoder writes them from the block's cluster and
    // link tables and the decoder strips them back off before rebuilding the cell.
    private static let clusterPayloadFlag: UInt16 = 1 << 15
    private static let linkPayloadFlag: UInt16 = 1 << 14
    private static let payloadFlagMask: UInt16 = clusterPayloadFlag | linkPayloadFlag

    public static func encode(_ update: GhosttyRenderUpdate) throws -> Data {
        var writer = BinaryWriter()
        writer.appendBytes(magic)
        writer.appendUInt8(UInt8(GhosttyRenderUpdate.currentVersion))
        writer.appendUInt8(kindByte(update.kind))
        writer.appendUInt16(0)
        writer.appendOptionalRevision(update.sessionRevision)
        writer.appendOptionalRevision(update.baseRevision)
        writer.appendOptionalRevision(update.targetRevision)
        writer.appendUInt64(update.ownerEpoch)
        try writer.appendUInt16Clamped(update.columns)
        try writer.appendUInt16Clamped(update.rows)
        try writer.appendString(update.fallbackReason ?? "")

        switch update.kind {
        case .full:
            guard let frame = update.fullFrame else { throw BinaryCodecError.missingBody }
            try writer.appendSnapshot(frame.snapshot)
        case .delta:
            guard let delta = update.delta else { throw BinaryCodecError.missingBody }
            try writer.appendDelta(delta)
        case .resyncRequired: break
        }
        return writer.data
    }

    public static func decode(_ data: Data) throws -> GhosttyRenderUpdate {
        // Decode the whole frame inside a single withUnsafeBytes so fixed-width integer reads use
        // loadUnaligned over a raw pointer, avoiding the per-integer generic copyBytes churn that
        // dominated main-thread CPU on grid-sized (columns×rows cells × 4 reads) snapshots.
        try data.withUnsafeBytes { raw in
            var reader = BinaryReader(raw: raw)
            guard try reader.readBytes(count: magic.count) == magic else { throw BinaryCodecError.invalidMagic }
            let version = Int(try reader.readUInt8())
            guard version == GhosttyRenderUpdate.currentVersion else { throw BinaryCodecError.unsupportedVersion }
            let kind = try kind(for: reader.readUInt8())
            _ = try reader.readUInt16()
            let sessionRevision = try reader.readOptionalRevision()
            let baseRevision = try reader.readOptionalRevision()
            let targetRevision = try reader.readOptionalRevision()
            let ownerEpoch = try reader.readUInt64()
            let columns = Int(try reader.readUInt16())
            let rows = Int(try reader.readUInt16())
            let fallbackReason = try reader.readString()
            switch kind {
            case .full:
                let snapshot = try reader.readSnapshot(columns: columns, rows: rows)
                let frame = GhosttyRenderFrame(
                    version: GhosttyRenderFrame.currentVersion, sessionRevision: sessionRevision, ownerEpoch: ownerEpoch, snapshot: snapshot)
                return .full(frame, fallbackReason: fallbackReason.isEmpty ? nil : fallbackReason)
            case .delta:
                let delta = try reader.readDelta(
                    baseRevision: baseRevision, targetRevision: targetRevision, ownerEpoch: ownerEpoch, columns: columns, rows: rows)
                return .delta(delta)
            case .resyncRequired:
                return .resyncRequired(
                    sessionRevision: sessionRevision, ownerEpoch: ownerEpoch, columns: columns, rows: rows,
                    fallbackReason: fallbackReason.isEmpty ? nil : fallbackReason)
            }
        }
    }

    /// The kind of update an encoded blob carries, read from its fixed header alone.
    ///
    /// A caller that only needs to classify a render update — is this a full frame, or a delta that is
    /// useless without one? — would otherwise pay a whole columns×rows cell decode for a question the
    /// first six bytes answer. That decode is exactly the work the off-main reduction pipeline exists to
    /// keep off the main actor, so the classification paths (`GhosttyRemoteSessionStatePayload.renderUpdateKind`)
    /// read the header instead.
    ///
    /// Returns nil for anything this build would refuse to decode — wrong magic, wrong version, unknown
    /// kind byte, or too short to hold the header — so an unclassifiable blob is never mistaken for a full
    /// frame. Callers treat nil as "not a full frame".
    public static func encodedKind(of data: Data) -> GhosttyRenderUpdateKind? {
        guard data.count >= magic.count + 2 else { return nil }
        return data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> GhosttyRenderUpdateKind? in
            guard (0..<magic.count).allSatisfy({ raw[$0] == magic[$0] }) else { return nil }
            guard Int(raw[magic.count]) == GhosttyRenderUpdate.currentVersion else { return nil }
            return try? kind(for: raw[magic.count + 1])
        }
    }

    /// The ordering fields a full frame carries — the session revision it describes and the owner epoch it
    /// belongs to — read from the fixed header, with no grid decode. Nil unless the blob is a decodable
    /// full frame long enough to hold those fields, so a caller that cannot order a response leaves it
    /// alone rather than guessing. Every field here is fixed-width and written before the variable-length
    /// body (see `encode`), which is what makes the offsets constant.
    public static func encodedFrameOrdering(of data: Data) -> (sessionRevision: UInt64?, ownerEpoch: UInt64)? {
        guard encodedKind(of: data) == .full else { return nil }
        let sessionRevisionOffset = magic.count + 2 + MemoryLayout<UInt16>.size
        let ownerEpochOffset = sessionRevisionOffset + 3 * MemoryLayout<UInt64>.size
        guard data.count >= ownerEpochOffset + MemoryLayout<UInt64>.size else { return nil }
        return data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> (sessionRevision: UInt64?, ownerEpoch: UInt64)? in
            let sessionRevision = UInt64(littleEndian: raw.loadUnaligned(fromByteOffset: sessionRevisionOffset, as: UInt64.self))
            let ownerEpoch = UInt64(littleEndian: raw.loadUnaligned(fromByteOffset: ownerEpochOffset, as: UInt64.self))
            return (sessionRevision == nilRevision ? nil : sessionRevision, ownerEpoch)
        }
    }

    private static func kindByte(_ kind: GhosttyRenderUpdateKind) -> UInt8 {
        switch kind {
        case .full: 1
        case .delta: 2
        case .resyncRequired: 3
        }
    }

    private static func kind(for byte: UInt8) throws -> GhosttyRenderUpdateKind {
        switch byte {
        case 1: .full
        case 2: .delta
        case 3: .resyncRequired
        default: throw BinaryCodecError.invalidKind
        }
    }

    public enum BinaryCodecError: Error, Sendable, Equatable {
        case invalidMagic
        case unsupportedVersion
        case invalidKind
        case missingBody
        case valueOutOfRange
        case truncated
        case invalidUTF8
        /// A sparse cell-text entry that does not describe the cell the flag bits promised: an offset
        /// that is not the flagged cell's, an empty payload, or a cluster longer than the cap.
        case invalidCellPayload
    }

    private struct BinaryWriter {
        var data = Data()

        mutating func appendBytes(_ bytes: [UInt8]) { data.append(contentsOf: bytes) }
        mutating func appendUInt8(_ value: UInt8) { data.append(value) }

        // Append the little-endian bytes via Data's pointer overload, which memcpys instead of
        // walking the raw buffer byte-wise through the Sequence path.
        private mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
            var littleEndian = value.littleEndian
            withUnsafeBytes(of: &littleEndian) { data.append($0.baseAddress!.assumingMemoryBound(to: UInt8.self), count: $0.count) }
        }

        mutating func appendUInt16(_ value: UInt16) { appendLittleEndian(value) }
        mutating func appendUInt32(_ value: UInt32) { appendLittleEndian(value) }
        mutating func appendUInt64(_ value: UInt64) { appendLittleEndian(value) }
        mutating func appendInt32(_ value: Int32) { appendLittleEndian(value) }

        mutating func appendOptionalRevision(_ revision: UInt64?) { appendUInt64(revision ?? nilRevision) }

        mutating func appendUInt16Clamped(_ value: Int) throws {
            guard value >= 0, value <= Int(UInt16.max) else { throw BinaryCodecError.valueOutOfRange }
            appendUInt16(UInt16(value))
        }

        mutating func appendUInt32Clamped(_ value: Int) throws {
            guard value >= 0, value <= Int(UInt32.max) else { throw BinaryCodecError.valueOutOfRange }
            appendUInt32(UInt32(value))
        }

        mutating func appendInt32Clamped(_ value: Int) throws {
            guard value >= Int(Int32.min), value <= Int(Int32.max) else { throw BinaryCodecError.valueOutOfRange }
            appendInt32(Int32(value))
        }

        mutating func appendString(_ value: String) throws {
            let bytes = Array(value.utf8)
            try appendUInt16Clamped(bytes.count)
            appendBytes(bytes)
        }

        private mutating func appendCell(_ cell: GhosttyTerminalSnapshot.Cell, payloadFlags: UInt16) {
            appendUInt32(cell.codepoint)
            appendUInt32(cell.foregroundRGB)
            appendUInt32(cell.backgroundRGB)
            appendUInt16((cell.flags & ~payloadFlagMask) | payloadFlags)
        }

        /// Writes one block of cells followed by its sparse text section: for every cell that carries a
        /// grapheme cluster or a link, in cell order and cluster before link, an entry of
        /// `(UInt32 offset within the block, UInt16 utf8 byte count, bytes)`. The tables are keyed by
        /// exactly that offset. The section is described entirely by the payload flag bits the cells just
        /// wrote, so a block with no such cell emits nothing at all and an all-ASCII frame costs exactly
        /// the fixed 14 bytes per cell.
        mutating func appendCellBlock(_ cells: [GhosttyTerminalSnapshot.Cell], clusters: [Int: String], linkURLs: [Int: String]) throws {
            guard !clusters.isEmpty || !linkURLs.isEmpty else {
                for cell in cells { appendCell(cell, payloadFlags: 0) }
                return
            }
            var payloads: [(offset: Int, text: String)] = []
            for (offset, cell) in cells.enumerated() {
                let cluster = clusters[offset]
                let linkURL = linkURLs[offset]
                appendCell(cell, payloadFlags: (cluster == nil ? 0 : clusterPayloadFlag) | (linkURL == nil ? 0 : linkPayloadFlag))
                if let cluster { payloads.append((offset, cluster)) }
                if let linkURL { payloads.append((offset, linkURL)) }
            }
            for payload in payloads {
                try appendUInt32Clamped(payload.offset)
                try appendString(payload.text)
            }
        }

        mutating func appendSnapshot(_ snapshot: GhosttyTerminalSnapshot) throws {
            // Snapshot header is 19 bytes; each cell is 14 bytes (see appendCell). Cells carrying a
            // cluster or link add a sparse entry each after the block, which the reservation does not
            // size for: they are rare enough that sizing for them would over-reserve every frame.
            data.reserveCapacity(data.count + 19 + snapshot.cells.count * 14)
            try appendUInt16Clamped(snapshot.cursorColumn)
            try appendUInt16Clamped(snapshot.cursorRow)
            appendUInt8(snapshot.cursorVisible ? 1 : 0)
            appendUInt32(snapshot.defaultForegroundRGB)
            appendUInt32(snapshot.defaultBackgroundRGB)
            appendUInt8(snapshot.mouseReportingActive ? 1 : 0)
            appendUInt8(snapshot.mouseShiftCapture)
            try appendUInt32Clamped(snapshot.cells.count)
            try appendCellBlock(snapshot.cells, clusters: snapshot.clusters, linkURLs: snapshot.linkURLs)
        }

        mutating func appendDelta(_ delta: GhosttyRenderDeltaFrame) throws {
            // Header 23 bytes, each scroll rect 16 bytes, run-count 4 bytes, each run header 6 bytes,
            // each cell 14 bytes (see appendCell), plus each run's sparse cell-text section (see
            // appendCellBlock) which the reservation deliberately does not size for.
            let runCells = delta.replaceCellRuns.reduce(0) { $0 + $1.cells.count }
            data.reserveCapacity(data.count + 23 + delta.scrollRects.count * 16 + 4 + delta.replaceCellRuns.count * 6 + runCells * 14)
            try appendUInt16Clamped(delta.cursorColumn)
            try appendUInt16Clamped(delta.cursorRow)
            appendUInt8(delta.cursorVisible ? 1 : 0)
            appendUInt32(delta.defaultForegroundRGB)
            appendUInt32(delta.defaultBackgroundRGB)
            appendUInt8(delta.mouseReportingActive ? 1 : 0)
            appendUInt8(delta.mouseShiftCapture)
            try appendUInt32Clamped(delta.changedCellCount)
            try appendUInt32Clamped(delta.scrollRects.count)
            for scrollRect in delta.scrollRects {
                try appendUInt16Clamped(scrollRect.rowStart)
                try appendUInt16Clamped(scrollRect.rowCount)
                try appendUInt16Clamped(scrollRect.columnStart)
                try appendUInt16Clamped(scrollRect.columnCount)
                try appendInt32Clamped(scrollRect.deltaRows)
                try appendInt32Clamped(scrollRect.deltaColumns)
            }
            try appendUInt32Clamped(delta.replaceCellRuns.count)
            for run in delta.replaceCellRuns {
                try appendUInt16Clamped(run.row)
                try appendUInt16Clamped(run.column)
                try appendUInt16Clamped(run.cells.count)
                try appendCellBlock(run.cells, clusters: run.clusters, linkURLs: run.linkURLs)
            }
        }
    }

    /// One decoded cell block: the cells plus the sparse text that followed them, keyed by offset within
    /// the block — the shape a snapshot or a run stores directly.
    private struct CellBlock {
        let cells: [GhosttyTerminalSnapshot.Cell]
        let clusters: [Int: String]
        let linkURLs: [Int: String]
    }

    // Reads over a raw buffer (already relative to the sliced Data's start, so it is slice-correct
    // regardless of the source Data's startIndex).
    private struct BinaryReader {
        let raw: UnsafeRawBufferPointer
        var offset = 0

        mutating func readBytes(count: Int) throws -> [UInt8] {
            guard count >= 0, offset + count <= raw.count else { throw BinaryCodecError.truncated }
            defer { offset += count }
            return Array(raw[offset..<(offset + count)])
        }

        mutating func readUInt8() throws -> UInt8 {
            guard offset < raw.count else { throw BinaryCodecError.truncated }
            defer { offset += 1 }
            return raw[offset]
        }

        mutating func readUInt16() throws -> UInt16 { UInt16(littleEndian: try readFixedWidthInteger()) }
        mutating func readUInt32() throws -> UInt32 { UInt32(littleEndian: try readFixedWidthInteger()) }
        mutating func readUInt64() throws -> UInt64 { UInt64(littleEndian: try readFixedWidthInteger()) }
        mutating func readInt32() throws -> Int32 { Int32(littleEndian: try readFixedWidthInteger()) }

        mutating func readOptionalRevision() throws -> UInt64? {
            let value = try readUInt64()
            return value == nilRevision ? nil : value
        }

        mutating func readString() throws -> String {
            let count = Int(try readUInt16())
            guard count >= 0, offset + count <= raw.count else { throw BinaryCodecError.truncated }
            defer { offset += count }
            // String(bytes:encoding:) validates UTF-8 and returns nil on failure, preserving .invalidUTF8.
            guard let value = String(bytes: raw[offset..<(offset + count)], encoding: .utf8) else { throw BinaryCodecError.invalidUTF8 }
            return value
        }

        /// Reads one cell block and the sparse cell-text section that follows it (see
        /// `BinaryWriter.appendCellBlock`). The payload flag bits tell the reader exactly which entries
        /// to expect and in what order, so a block whose cells are all plain reads nothing extra; each
        /// entry must name the cell that promised it, or the frame is malformed.
        mutating func readCellBlock(count: Int) throws -> CellBlock {
            var cells: [GhosttyTerminalSnapshot.Cell] = []
            cells.reserveCapacity(count)
            var flagged: [(index: Int, flags: UInt16)] = []
            for index in 0..<count {
                let codepoint = try readUInt32()
                let foregroundRGB = try readUInt32()
                let backgroundRGB = try readUInt32()
                let flags = try readUInt16()
                cells.append(
                    GhosttyTerminalSnapshot.Cell(
                        codepoint: codepoint, foregroundRGB: foregroundRGB, backgroundRGB: backgroundRGB, flags: flags & ~payloadFlagMask))
                if flags & payloadFlagMask != 0 { flagged.append((index, flags)) }
            }
            var clusters: [Int: String] = [:]
            var linkURLs: [Int: String] = [:]
            for entry in flagged {
                if entry.flags & clusterPayloadFlag != 0 {
                    GhosttyTerminalSnapshot.setCluster(try readClusterText(expectedOffset: entry.index), forCell: entry.index, in: &clusters)
                }
                if entry.flags & linkPayloadFlag != 0 {
                    GhosttyTerminalSnapshot.setLinkURL(
                        try readCellText(expectedOffset: entry.index, maximumByteCount: GhosttyTerminalSnapshot.maximumLinkURLUTF8ByteCount),
                        forCell: entry.index, in: &linkURLs)
                }
            }
            return CellBlock(cells: cells, clusters: clusters, linkURLs: linkURLs)
        }

        /// A cluster payload, held to the producer-side cap. The byte cap bounds the read before the
        /// string is materialized; the codepoint count is the cap that actually defines a cluster, and
        /// a payload past it did not come from a producer this build trusts.
        private mutating func readClusterText(expectedOffset: Int) throws -> String {
            let text = try readCellText(expectedOffset: expectedOffset, maximumByteCount: GhosttyTerminalSnapshot.maximumClusterUTF8ByteCount)
            guard text.unicodeScalars.count <= GhosttyTerminalSnapshot.maximumClusterCodepointCount else { throw BinaryCodecError.invalidCellPayload }
            return text
        }

        private mutating func readCellText(expectedOffset: Int, maximumByteCount: Int) throws -> String {
            guard Int(try readUInt32()) == expectedOffset else { throw BinaryCodecError.invalidCellPayload }
            let count = Int(try readUInt16())
            guard count > 0, count <= maximumByteCount else { throw BinaryCodecError.invalidCellPayload }
            guard offset + count <= raw.count else { throw BinaryCodecError.truncated }
            defer { offset += count }
            guard let value = String(bytes: raw[offset..<(offset + count)], encoding: .utf8) else { throw BinaryCodecError.invalidUTF8 }
            return value
        }

        mutating func readSnapshot(columns: Int, rows: Int) throws -> GhosttyTerminalSnapshot {
            let cursorColumn = Int(try readUInt16())
            let cursorRow = Int(try readUInt16())
            let cursorVisible = try readUInt8() != 0
            let defaultForegroundRGB = try readUInt32()
            let defaultBackgroundRGB = try readUInt32()
            let mouseReportingActive = try readUInt8() != 0
            let mouseShiftCapture = try readUInt8()
            let cellCount = Int(try readUInt32())
            let block = try readCellBlock(count: cellCount)
            return GhosttyTerminalSnapshot(
                columns: columns, rows: rows, cursorColumn: cursorColumn, cursorRow: cursorRow, cursorVisible: cursorVisible,
                defaultForegroundRGB: defaultForegroundRGB, defaultBackgroundRGB: defaultBackgroundRGB, cells: block.cells, clusters: block.clusters,
                linkURLs: block.linkURLs, mouseReportingActive: mouseReportingActive, mouseShiftCapture: mouseShiftCapture)
        }

        mutating func readDelta(baseRevision: UInt64?, targetRevision: UInt64?, ownerEpoch: UInt64, columns: Int, rows: Int) throws
            -> GhosttyRenderDeltaFrame
        {
            let cursorColumn = Int(try readUInt16())
            let cursorRow = Int(try readUInt16())
            let cursorVisible = try readUInt8() != 0
            let defaultForegroundRGB = try readUInt32()
            let defaultBackgroundRGB = try readUInt32()
            let mouseReportingActive = try readUInt8() != 0
            let mouseShiftCapture = try readUInt8()
            let changedCellCount = Int(try readUInt32())
            let scrollRectCount = Int(try readUInt32())
            var scrollRects: [GhosttyRenderScrollRectOperation] = []
            scrollRects.reserveCapacity(scrollRectCount)
            for _ in 0..<scrollRectCount {
                scrollRects.append(
                    GhosttyRenderScrollRectOperation(
                        rowStart: Int(try readUInt16()), rowCount: Int(try readUInt16()), columnStart: Int(try readUInt16()),
                        columnCount: Int(try readUInt16()), deltaRows: Int(try readInt32()), deltaColumns: Int(try readInt32())))
            }
            let runCount = Int(try readUInt32())
            var runs: [GhosttyRenderCellRun] = []
            runs.reserveCapacity(runCount)
            for _ in 0..<runCount {
                let row = Int(try readUInt16())
                let column = Int(try readUInt16())
                let cellCount = Int(try readUInt16())
                let block = try readCellBlock(count: cellCount)
                runs.append(GhosttyRenderCellRun(row: row, column: column, cells: block.cells, clusters: block.clusters, linkURLs: block.linkURLs))
            }
            return GhosttyRenderDeltaFrame(
                baseRevision: baseRevision, targetRevision: targetRevision, ownerEpoch: ownerEpoch, columns: columns, rows: rows,
                cursorColumn: cursorColumn, cursorRow: cursorRow, cursorVisible: cursorVisible, defaultForegroundRGB: defaultForegroundRGB,
                defaultBackgroundRGB: defaultBackgroundRGB, mouseReportingActive: mouseReportingActive, mouseShiftCapture: mouseShiftCapture,
                scrollRects: scrollRects, replaceCellRuns: runs, changedCellCount: changedCellCount)
        }

        private mutating func readFixedWidthInteger<T: FixedWidthInteger>() throws -> T {
            let size = MemoryLayout<T>.size
            guard offset + size <= raw.count else { throw BinaryCodecError.truncated }
            defer { offset += size }
            return raw.loadUnaligned(fromByteOffset: offset, as: T.self)
        }
    }
}
