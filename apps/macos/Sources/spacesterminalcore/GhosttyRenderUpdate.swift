import Foundation

public enum GhosttyRenderUpdateKind: String, Codable, Sendable, Equatable {
    case full
    case delta
    case resyncRequired
}

public enum GhosttyRenderUpdateMode: String, Sendable, Equatable {
    public static let environmentKey = "SPACES_TERMINAL_RENDER_UPDATE_MODE"

    case full
    case delta
    case auto

    public static func resolved(environment: [String: String] = ProcessInfo.processInfo.environment) -> Self {
        guard let rawValue = environment[environmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !rawValue.isEmpty else {
            return .auto
        }
        return Self(rawValue: rawValue) ?? .auto
    }
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

    public init(row: Int, column: Int, cells: [GhosttyTerminalSnapshot.Cell]) {
        self.row = row
        self.column = column
        self.cells = cells
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
    public let scrollRects: [GhosttyRenderScrollRectOperation]
    public let replaceCellRuns: [GhosttyRenderCellRun]
    public let changedCellCount: Int

    public init(
        baseRevision: UInt64?, targetRevision: UInt64?, ownerEpoch: UInt64, columns: Int, rows: Int, cursorColumn: Int, cursorRow: Int,
        cursorVisible: Bool, defaultForegroundRGB: UInt32, defaultBackgroundRGB: UInt32, scrollRects: [GhosttyRenderScrollRectOperation] = [],
        replaceCellRuns: [GhosttyRenderCellRun] = [], changedCellCount: Int
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
        self.scrollRects = scrollRects
        self.replaceCellRuns = replaceCellRuns
        self.changedCellCount = changedCellCount
    }
}

public struct GhosttyRenderUpdate: Codable, Sendable, Equatable {
    public static let currentVersion = 2
    public static let binaryEncoding = "spaces.terminal.render-update.v2.binary"

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

        var cells = Array(baseline.cells.prefix(baseline.columns * baseline.rows))
        for operation in delta.scrollRects {
            try applyScrollRect(operation, to: &cells, columns: baseline.columns, rows: baseline.rows, blank: blankCell(for: delta))
        }
        for run in delta.replaceCellRuns { try applyCellRun(run, to: &cells, columns: baseline.columns, rows: baseline.rows) }
        return GhosttyTerminalSnapshot(
            columns: delta.columns, rows: delta.rows, cursorColumn: delta.cursorColumn, cursorRow: delta.cursorRow,
            cursorVisible: delta.cursorVisible, defaultForegroundRGB: delta.defaultForegroundRGB, defaultBackgroundRGB: delta.defaultBackgroundRGB,
            cells: cells)
    }

    private static func applyScrollRect(
        _ operation: GhosttyRenderScrollRectOperation, to cells: inout [GhosttyTerminalSnapshot.Cell], columns: Int, rows: Int,
        blank: GhosttyTerminalSnapshot.Cell
    ) throws {
        guard operation.rowStart >= 0, operation.rowCount >= 0, operation.columnStart >= 0, operation.columnCount >= 0 else {
            throw GhosttyRenderUpdateApplyError.invalidOperation
        }
        guard operation.rowStart + operation.rowCount <= rows, operation.columnStart + operation.columnCount <= columns else {
            throw GhosttyRenderUpdateApplyError.invalidOperation
        }
        guard operation.rowCount > 0, operation.columnCount > 0 else { return }

        let original = cells
        for row in operation.rowStart..<(operation.rowStart + operation.rowCount) {
            for column in operation.columnStart..<(operation.columnStart + operation.columnCount) {
                cells[index(row: row, column: column, columns: columns)] = blank
            }
        }
        for sourceRow in operation.rowStart..<(operation.rowStart + operation.rowCount) {
            for sourceColumn in operation.columnStart..<(operation.columnStart + operation.columnCount) {
                let destinationRow = sourceRow + operation.deltaRows
                let destinationColumn = sourceColumn + operation.deltaColumns
                guard destinationRow >= operation.rowStart, destinationRow < operation.rowStart + operation.rowCount,
                    destinationColumn >= operation.columnStart, destinationColumn < operation.columnStart + operation.columnCount
                else { continue }
                cells[index(row: destinationRow, column: destinationColumn, columns: columns)] =
                    original[index(row: sourceRow, column: sourceColumn, columns: columns)]
            }
        }
    }

    private static func applyCellRun(_ run: GhosttyRenderCellRun, to cells: inout [GhosttyTerminalSnapshot.Cell], columns: Int, rows: Int) throws {
        guard run.row >= 0, run.row < rows, run.column >= 0, run.column + run.cells.count <= columns else {
            throw GhosttyRenderUpdateApplyError.invalidOperation
        }
        let start = index(row: run.row, column: run.column, columns: columns)
        cells.replaceSubrange(start..<(start + run.cells.count), with: run.cells)
    }

    private static func blankCell(for delta: GhosttyRenderDeltaFrame) -> GhosttyTerminalSnapshot.Cell {
        GhosttyTerminalSnapshot.Cell(codepoint: 0, foregroundRGB: delta.defaultForegroundRGB, backgroundRGB: delta.defaultBackgroundRGB, flags: 0)
    }

    private static func index(row: Int, column: Int, columns: Int) -> Int { row * columns + column }
}

public enum GhosttyRenderUpdateFactory {
    public static func makeUpdate(
        target frame: GhosttyRenderFrame, baseline: GhosttyRenderUpdateBaseline?, mode: GhosttyRenderUpdateMode = .auto,
        nativeScrollRects: [GhosttyRenderScrollRectOperation] = []
    ) -> GhosttyRenderUpdate {
        guard mode != .full else { return .full(frame, fallbackReason: "mode_full") }
        guard let baseline else { return .full(frame, fallbackReason: "missing_baseline") }
        guard canDelta(from: baseline, to: frame) else { return .full(frame, fallbackReason: "baseline_mismatch") }
        guard validGrid(frame.snapshot), validGrid(baseline.snapshot) else { return .full(frame, fallbackReason: "invalid_grid") }
        guard let scrollRects = validatedScrollRects(nativeScrollRects, columns: frame.columns, rows: frame.rows) else {
            return .full(frame, fallbackReason: "invalid_scroll_rect")
        }

        let delta = makeDelta(from: baseline, to: frame, scrollRects: scrollRects)
        let update = GhosttyRenderUpdate.delta(delta)
        guard mode == .auto else { return update }
        guard let deltaBytes = try? GhosttyRenderUpdateBinaryCodec.encode(update),
            let fullBytes = try? GhosttyRenderUpdateBinaryCodec.encode(.full(frame, fallbackReason: "delta_larger_than_full"))
        else { return update }
        guard deltaBytes.count < fullBytes.count else { return .full(frame, fallbackReason: "delta_larger_than_full") }
        return update
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
        let scrolledCells = scrollRects.reduce(previous.cells) { cells, operation in
            var next = cells
            applyScrollRectForDiff(operation, to: &next, snapshot: target)
            return next
        }
        let runs = changedRuns(from: scrolledCells, to: target.cells, columns: target.columns, rows: target.rows)
        return GhosttyRenderDeltaFrame(
            baseRevision: baseline.sessionRevision, targetRevision: frame.sessionRevision, ownerEpoch: frame.ownerEpoch, columns: target.columns,
            rows: target.rows, cursorColumn: target.cursorColumn, cursorRow: target.cursorRow, cursorVisible: target.cursorVisible,
            defaultForegroundRGB: target.defaultForegroundRGB, defaultBackgroundRGB: target.defaultBackgroundRGB, scrollRects: scrollRects,
            replaceCellRuns: runs, changedCellCount: runs.reduce(0) { $0 + $1.cells.count })
    }

    private static func normalized(_ snapshot: GhosttyTerminalSnapshot) -> GhosttyTerminalSnapshot {
        let requiredCount = max(snapshot.columns * snapshot.rows, 0)
        guard snapshot.cells.count != requiredCount else { return snapshot }
        let blank = GhosttyTerminalSnapshot.Cell(
            codepoint: 0, foregroundRGB: snapshot.defaultForegroundRGB, backgroundRGB: snapshot.defaultBackgroundRGB, flags: 0)
        let cells = Array(snapshot.cells.prefix(requiredCount)) + Array(repeating: blank, count: max(requiredCount - snapshot.cells.count, 0))
        return GhosttyTerminalSnapshot(
            columns: snapshot.columns, rows: snapshot.rows, cursorColumn: snapshot.cursorColumn, cursorRow: snapshot.cursorRow,
            cursorVisible: snapshot.cursorVisible, defaultForegroundRGB: snapshot.defaultForegroundRGB,
            defaultBackgroundRGB: snapshot.defaultBackgroundRGB, cells: cells)
    }

    private static func applyScrollRectForDiff(
        _ operation: GhosttyRenderScrollRectOperation, to cells: inout [GhosttyTerminalSnapshot.Cell], snapshot: GhosttyTerminalSnapshot
    ) {
        let blank = GhosttyTerminalSnapshot.Cell(
            codepoint: 0, foregroundRGB: snapshot.defaultForegroundRGB, backgroundRGB: snapshot.defaultBackgroundRGB, flags: 0)
        let original = cells
        for row in operation.rowStart..<(operation.rowStart + operation.rowCount) {
            for column in operation.columnStart..<(operation.columnStart + operation.columnCount) {
                cells[index(row: row, column: column, columns: snapshot.columns)] = blank
            }
        }
        for sourceRow in operation.rowStart..<(operation.rowStart + operation.rowCount) {
            for sourceColumn in operation.columnStart..<(operation.columnStart + operation.columnCount) {
                let destinationRow = sourceRow + operation.deltaRows
                let destinationColumn = sourceColumn + operation.deltaColumns
                guard destinationRow >= operation.rowStart, destinationRow < operation.rowStart + operation.rowCount,
                    destinationColumn >= operation.columnStart, destinationColumn < operation.columnStart + operation.columnCount
                else { continue }
                cells[index(row: destinationRow, column: destinationColumn, columns: snapshot.columns)] =
                    original[index(row: sourceRow, column: sourceColumn, columns: snapshot.columns)]
            }
        }
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

    private static func changedRuns(
        from previousCells: [GhosttyTerminalSnapshot.Cell], to targetCells: [GhosttyTerminalSnapshot.Cell], columns: Int, rows: Int
    ) -> [GhosttyRenderCellRun] {
        var runs: [GhosttyRenderCellRun] = []
        for row in 0..<rows {
            var column = 0
            while column < columns {
                let cellIndex = index(row: row, column: column, columns: columns)
                guard previousCells[cellIndex] != targetCells[cellIndex] else {
                    column += 1
                    continue
                }
                let runStart = column
                var runCells: [GhosttyTerminalSnapshot.Cell] = []
                while column < columns {
                    let index = index(row: row, column: column, columns: columns)
                    guard previousCells[index] != targetCells[index] else { break }
                    runCells.append(targetCells[index])
                    column += 1
                }
                runs.append(GhosttyRenderCellRun(row: row, column: runStart, cells: runCells))
            }
        }
        return runs
    }

    private static func index(row: Int, column: Int, columns: Int) -> Int { row * columns + column }
}

public enum GhosttyRenderUpdateBinaryCodec {
    private static let magic: [UInt8] = [0x47, 0x52, 0x54, 0x55]
    private static let nilRevision = UInt64.max

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
        var reader = BinaryReader(data: data)
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
    }

    private struct BinaryWriter {
        var data = Data()

        mutating func appendBytes(_ bytes: [UInt8]) { data.append(contentsOf: bytes) }
        mutating func appendUInt8(_ value: UInt8) { data.append(value) }

        mutating func appendUInt16(_ value: UInt16) {
            var littleEndian = value.littleEndian
            withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
        }

        mutating func appendUInt32(_ value: UInt32) {
            var littleEndian = value.littleEndian
            withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
        }

        mutating func appendUInt64(_ value: UInt64) {
            var littleEndian = value.littleEndian
            withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
        }

        mutating func appendInt32(_ value: Int32) {
            var littleEndian = value.littleEndian
            withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
        }

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

        mutating func appendCell(_ cell: GhosttyTerminalSnapshot.Cell) {
            appendUInt32(cell.codepoint)
            appendUInt32(cell.foregroundRGB)
            appendUInt32(cell.backgroundRGB)
            appendUInt16(cell.flags)
        }

        mutating func appendSnapshot(_ snapshot: GhosttyTerminalSnapshot) throws {
            try appendUInt16Clamped(snapshot.cursorColumn)
            try appendUInt16Clamped(snapshot.cursorRow)
            appendUInt8(snapshot.cursorVisible ? 1 : 0)
            appendUInt32(snapshot.defaultForegroundRGB)
            appendUInt32(snapshot.defaultBackgroundRGB)
            try appendUInt32Clamped(snapshot.cells.count)
            for cell in snapshot.cells { appendCell(cell) }
        }

        mutating func appendDelta(_ delta: GhosttyRenderDeltaFrame) throws {
            try appendUInt16Clamped(delta.cursorColumn)
            try appendUInt16Clamped(delta.cursorRow)
            appendUInt8(delta.cursorVisible ? 1 : 0)
            appendUInt32(delta.defaultForegroundRGB)
            appendUInt32(delta.defaultBackgroundRGB)
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
                for cell in run.cells { appendCell(cell) }
            }
        }
    }

    private struct BinaryReader {
        let data: Data
        var offset = 0

        mutating func readBytes(count: Int) throws -> [UInt8] {
            guard count >= 0, offset + count <= data.count else { throw BinaryCodecError.truncated }
            defer { offset += count }
            return Array(data[offset..<(offset + count)])
        }

        mutating func readUInt8() throws -> UInt8 {
            guard offset < data.count else { throw BinaryCodecError.truncated }
            defer { offset += 1 }
            return data[offset]
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
            let bytes = try readBytes(count: count)
            guard let value = String(bytes: bytes, encoding: .utf8) else { throw BinaryCodecError.invalidUTF8 }
            return value
        }

        mutating func readCell() throws -> GhosttyTerminalSnapshot.Cell {
            GhosttyTerminalSnapshot.Cell(
                codepoint: try readUInt32(), foregroundRGB: try readUInt32(), backgroundRGB: try readUInt32(), flags: try readUInt16())
        }

        mutating func readSnapshot(columns: Int, rows: Int) throws -> GhosttyTerminalSnapshot {
            let cursorColumn = Int(try readUInt16())
            let cursorRow = Int(try readUInt16())
            let cursorVisible = try readUInt8() != 0
            let defaultForegroundRGB = try readUInt32()
            let defaultBackgroundRGB = try readUInt32()
            let cellCount = Int(try readUInt32())
            var cells: [GhosttyTerminalSnapshot.Cell] = []
            cells.reserveCapacity(cellCount)
            for _ in 0..<cellCount { cells.append(try readCell()) }
            return GhosttyTerminalSnapshot(
                columns: columns, rows: rows, cursorColumn: cursorColumn, cursorRow: cursorRow, cursorVisible: cursorVisible,
                defaultForegroundRGB: defaultForegroundRGB, defaultBackgroundRGB: defaultBackgroundRGB, cells: cells)
        }

        mutating func readDelta(baseRevision: UInt64?, targetRevision: UInt64?, ownerEpoch: UInt64, columns: Int, rows: Int) throws
            -> GhosttyRenderDeltaFrame
        {
            let cursorColumn = Int(try readUInt16())
            let cursorRow = Int(try readUInt16())
            let cursorVisible = try readUInt8() != 0
            let defaultForegroundRGB = try readUInt32()
            let defaultBackgroundRGB = try readUInt32()
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
                var cells: [GhosttyTerminalSnapshot.Cell] = []
                cells.reserveCapacity(cellCount)
                for _ in 0..<cellCount { cells.append(try readCell()) }
                runs.append(GhosttyRenderCellRun(row: row, column: column, cells: cells))
            }
            return GhosttyRenderDeltaFrame(
                baseRevision: baseRevision, targetRevision: targetRevision, ownerEpoch: ownerEpoch, columns: columns, rows: rows,
                cursorColumn: cursorColumn, cursorRow: cursorRow, cursorVisible: cursorVisible, defaultForegroundRGB: defaultForegroundRGB,
                defaultBackgroundRGB: defaultBackgroundRGB, scrollRects: scrollRects, replaceCellRuns: runs, changedCellCount: changedCellCount)
        }

        private mutating func readFixedWidthInteger<T: FixedWidthInteger>() throws -> T {
            let size = MemoryLayout<T>.size
            guard offset + size <= data.count else { throw BinaryCodecError.truncated }
            var value: T = 0
            _ = withUnsafeMutableBytes(of: &value) { buffer in data.copyBytes(to: buffer, from: offset..<(offset + size)) }
            offset += size
            return value
        }
    }
}
