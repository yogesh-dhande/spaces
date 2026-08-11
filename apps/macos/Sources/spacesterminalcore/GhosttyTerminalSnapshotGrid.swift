import Foundation

public struct GhosttyTerminalResolvedCell: Sendable, Equatable {
    public let text: String
    public let foregroundRGB: UInt32
    public let backgroundRGB: UInt32
    public let isBold: Bool
    public let isItalic: Bool
    public let isFaint: Bool
    public let isUnderline: Bool
    public let isStrikethrough: Bool
    public let isSpacer: Bool
    public let isCursor: Bool

    public init(
        text: String, foregroundRGB: UInt32, backgroundRGB: UInt32, isBold: Bool, isItalic: Bool, isFaint: Bool, isUnderline: Bool,
        isStrikethrough: Bool, isSpacer: Bool, isCursor: Bool
    ) {
        self.text = text
        self.foregroundRGB = foregroundRGB
        self.backgroundRGB = backgroundRGB
        self.isBold = isBold
        self.isItalic = isItalic
        self.isFaint = isFaint
        self.isUnderline = isUnderline
        self.isStrikethrough = isStrikethrough
        self.isSpacer = isSpacer
        self.isCursor = isCursor
    }
}

public enum GhosttyTerminalSnapshotGrid {
    public static let boldFlag: UInt16 = 1 << 0
    public static let italicFlag: UInt16 = 1 << 1
    public static let faintFlag: UInt16 = 1 << 2
    public static let inverseFlag: UInt16 = 1 << 4
    public static let invisibleFlag: UInt16 = 1 << 5
    public static let strikeFlag: UInt16 = 1 << 6
    public static let underlineFlag: UInt16 = 1 << 7
    public static let spacerFlag: UInt16 = 1 << 10
    /// Row metadata is carried on every cell so a renderer can rebuild the row even if its trailing
    /// cells are default-filled. The embedded Ghostty apply path reads the flags from column zero.
    public static let rowWrapFlag: UInt16 = 1 << 11
    public static let rowWrapContinuationFlag: UInt16 = 1 << 12

    public static func resolvedCell(in snapshot: GhosttyTerminalSnapshot, row: Int, column: Int) -> GhosttyTerminalResolvedCell? {
        guard row >= 0, column >= 0, row < snapshot.rows, column < snapshot.columns else { return nil }
        let index = row * snapshot.columns + column
        guard index >= 0, index < snapshot.cells.count else { return nil }
        let cell = snapshot.cells[index]
        let isCursor = snapshot.cursorVisible && row == snapshot.cursorRow && column == snapshot.cursorColumn
        return resolvedCell(cell, at: index, snapshot: snapshot, isCursor: isCursor)
    }

    public static func fullPlainText(for snapshot: GhosttyTerminalSnapshot) -> String {
        guard snapshot.columns > 0, snapshot.rows > 0, snapshot.cells.count >= snapshot.columns * snapshot.rows else { return "" }
        var lines: [String] = []
        lines.reserveCapacity(snapshot.rows)
        for row in 0..<snapshot.rows {
            var line = ""
            line.reserveCapacity(snapshot.columns)
            for column in 0..<snapshot.columns { line += resolvedCell(in: snapshot, row: row, column: column)?.text ?? " " }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    public static func containsVisibleContent(_ snapshot: GhosttyTerminalSnapshot) -> Bool {
        guard snapshot.columns > 0, snapshot.rows > 0, snapshot.cells.count >= snapshot.columns * snapshot.rows else { return false }
        for row in 0..<snapshot.rows {
            for column in 0..<snapshot.columns {
                guard let cell = resolvedCell(in: snapshot, row: row, column: column) else { continue }
                if cell.text.contains(where: { !$0.isWhitespace && !$0.isNewline }) { return true }
                if cell.backgroundRGB != snapshot.defaultBackgroundRGB { return true }
                if cell.isCursor { return true }
            }
        }
        return false
    }

    private static func resolvedCell(_ cell: GhosttyTerminalSnapshot.Cell, at index: Int, snapshot: GhosttyTerminalSnapshot, isCursor: Bool)
        -> GhosttyTerminalResolvedCell
    {
        var foreground = cell.codepoint == 0 ? snapshot.defaultForegroundRGB : cell.foregroundRGB
        var background = cell.backgroundRGB
        if cell.flags & inverseFlag != 0 || isCursor { swap(&foreground, &background) }
        return GhosttyTerminalResolvedCell(
            text: GhosttyTerminalSnapshotCellText.displayText(for: cell, cluster: snapshot.clusters[index]), foregroundRGB: foreground,
            backgroundRGB: background, isBold: cell.flags & boldFlag != 0, isItalic: cell.flags & italicFlag != 0,
            isFaint: cell.flags & faintFlag != 0, isUnderline: cell.flags & underlineFlag != 0, isStrikethrough: cell.flags & strikeFlag != 0,
            isSpacer: cell.flags & spacerFlag != 0, isCursor: isCursor)
    }
}
