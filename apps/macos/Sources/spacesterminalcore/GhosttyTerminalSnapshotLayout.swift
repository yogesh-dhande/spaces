import Foundation

public struct GhosttyTerminalSnapshotDisplayRun: Sendable, Equatable {
    public let text: String
    public let foregroundRGB: UInt32
    public let backgroundRGB: UInt32
    public let isBold: Bool
    public let isItalic: Bool
    public let isFaint: Bool
    public let isUnderline: Bool
    public let isStrikethrough: Bool

    public init(
        text: String, foregroundRGB: UInt32, backgroundRGB: UInt32, isBold: Bool, isItalic: Bool, isFaint: Bool, isUnderline: Bool,
        isStrikethrough: Bool
    ) {
        self.text = text
        self.foregroundRGB = foregroundRGB
        self.backgroundRGB = backgroundRGB
        self.isBold = isBold
        self.isItalic = isItalic
        self.isFaint = isFaint
        self.isUnderline = isUnderline
        self.isStrikethrough = isStrikethrough
    }
}

public struct GhosttyTerminalSnapshotDisplayLine: Sendable, Equatable {
    public let runs: [GhosttyTerminalSnapshotDisplayRun]

    public init(runs: [GhosttyTerminalSnapshotDisplayRun]) { self.runs = runs }

    public var text: String { runs.map(\.text).joined() }
}

public enum GhosttyTerminalSnapshotLayout {
    private static let boldFlag: UInt16 = 1 << 0
    private static let italicFlag: UInt16 = 1 << 1
    private static let faintFlag: UInt16 = 1 << 2
    private static let inverseFlag: UInt16 = 1 << 4
    private static let invisibleFlag: UInt16 = 1 << 5
    private static let strikeFlag: UInt16 = 1 << 6
    private static let underlineFlag: UInt16 = 1 << 7
    private static let spacerFlag: UInt16 = 1 << 10

    public static func lines(for snapshot: GhosttyTerminalSnapshot) -> [GhosttyTerminalSnapshotDisplayLine] {
        let columns = max(0, snapshot.columns)
        let rows = max(0, snapshot.rows)
        guard columns > 0, rows > 0, snapshot.cells.count >= columns * rows else { return [] }

        return (0..<rows).map { row in
            let rowStart = row * columns
            let rowEnd = rowStart + columns
            let rowCells = Array(snapshot.cells[rowStart..<rowEnd])
            let lastColumn = visibleColumn(in: rowCells, row: row, snapshot: snapshot)
            guard lastColumn >= 0 else { return GhosttyTerminalSnapshotDisplayLine(runs: []) }

            var runs: [GhosttyTerminalSnapshotDisplayRun] = []
            for column in 0...lastColumn {
                let cell = rowCells[column]
                let isCursor = snapshot.cursorVisible && row == snapshot.cursorRow && column == snapshot.cursorColumn
                let resolved = resolveRun(cell: cell, at: rowStart + column, snapshot: snapshot, invertForCursor: isCursor)
                if let last = runs.last, last.foregroundRGB == resolved.foregroundRGB, last.backgroundRGB == resolved.backgroundRGB,
                    last.isBold == resolved.isBold, last.isItalic == resolved.isItalic, last.isFaint == resolved.isFaint,
                    last.isUnderline == resolved.isUnderline, last.isStrikethrough == resolved.isStrikethrough
                {
                    runs[runs.count - 1] = GhosttyTerminalSnapshotDisplayRun(
                        text: last.text + resolved.text, foregroundRGB: last.foregroundRGB, backgroundRGB: last.backgroundRGB, isBold: last.isBold,
                        isItalic: last.isItalic, isFaint: last.isFaint, isUnderline: last.isUnderline, isStrikethrough: last.isStrikethrough)
                } else {
                    runs.append(resolved)
                }
            }
            return GhosttyTerminalSnapshotDisplayLine(runs: runs)
        }
    }

    public static func plainText(for snapshot: GhosttyTerminalSnapshot) -> String { lines(for: snapshot).map(\.text).joined(separator: "\n") }

    private static func visibleColumn(in rowCells: [GhosttyTerminalSnapshot.Cell], row: Int, snapshot: GhosttyTerminalSnapshot) -> Int {
        var lastVisible = -1
        for column in rowCells.indices
        where shouldKeep(
            cell: rowCells[column], defaultForegroundRGB: snapshot.defaultForegroundRGB, defaultBackgroundRGB: snapshot.defaultBackgroundRGB)
        { lastVisible = column }
        if snapshot.cursorVisible && row == snapshot.cursorRow { lastVisible = max(lastVisible, min(snapshot.cursorColumn, snapshot.columns - 1)) }
        return lastVisible
    }

    private static func shouldKeep(cell: GhosttyTerminalSnapshot.Cell, defaultForegroundRGB: UInt32, defaultBackgroundRGB: UInt32) -> Bool {
        if cell.flags & spacerFlag != 0 { return cell.backgroundRGB != defaultBackgroundRGB }
        if cell.flags & invisibleFlag != 0 { return cell.backgroundRGB != defaultBackgroundRGB }
        if cell.codepoint != 0, cell.codepoint != 32 { return true }
        if cell.foregroundRGB != defaultForegroundRGB || cell.backgroundRGB != defaultBackgroundRGB { return true }
        let styleMask = boldFlag | italicFlag | faintFlag | inverseFlag | strikeFlag | underlineFlag
        return cell.flags & styleMask != 0
    }

    private static func resolveRun(cell: GhosttyTerminalSnapshot.Cell, at index: Int, snapshot: GhosttyTerminalSnapshot, invertForCursor: Bool)
        -> GhosttyTerminalSnapshotDisplayRun
    {
        var foreground = cell.codepoint == 0 ? snapshot.defaultForegroundRGB : cell.foregroundRGB
        var background = cell.backgroundRGB
        if cell.flags & inverseFlag != 0 || invertForCursor { swap(&foreground, &background) }
        return GhosttyTerminalSnapshotDisplayRun(
            text: GhosttyTerminalSnapshotCellText.displayText(for: cell, cluster: snapshot.clusters[index]), foregroundRGB: foreground,
            backgroundRGB: background, isBold: cell.flags & boldFlag != 0, isItalic: cell.flags & italicFlag != 0,
            isFaint: cell.flags & faintFlag != 0, isUnderline: cell.flags & underlineFlag != 0, isStrikethrough: cell.flags & strikeFlag != 0)
    }
}
