import AppKit
import Foundation
import GhosttyKit

public struct GhosttyTerminalSnapshot: Equatable {
    public struct Cell: Equatable {
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

    public let columns: Int
    public let rows: Int
    public let cursorColumn: Int
    public let cursorRow: Int
    public let cursorVisible: Bool
    public let defaultForegroundRGB: UInt32
    public let defaultBackgroundRGB: UInt32
    public let cells: [Cell]

    public init(
        columns: Int, rows: Int, cursorColumn: Int, cursorRow: Int, cursorVisible: Bool, defaultForegroundRGB: UInt32, defaultBackgroundRGB: UInt32,
        cells: [Cell]
    ) {
        self.columns = columns
        self.rows = rows
        self.cursorColumn = cursorColumn
        self.cursorRow = cursorRow
        self.cursorVisible = cursorVisible
        self.defaultForegroundRGB = defaultForegroundRGB
        self.defaultBackgroundRGB = defaultBackgroundRGB
        self.cells = cells
    }
}

public enum GhosttyTerminalSnapshotCapture {
    public static func capture(from surface: ghostty_surface_t?) -> GhosttyTerminalSnapshot? {
        guard let surface else { return nil }
        var raw = ghostty_cells_s()
        guard ghostty_surface_read_cells(surface, &raw) else { return nil }
        defer { ghostty_surface_free_cells(surface, &raw) }
        guard let rawCells = raw.cells, raw.cols > 0, raw.rows > 0 else { return nil }

        let count = Int(raw.cells_len)
        let buffer = UnsafeBufferPointer(start: rawCells, count: count)
        let cells = buffer.map { cell in
            GhosttyTerminalSnapshot.Cell(codepoint: cell.codepoint, foregroundRGB: cell.fg_rgb, backgroundRGB: cell.bg_rgb, flags: cell.flags)
        }

        return GhosttyTerminalSnapshot(
            columns: Int(raw.cols), rows: Int(raw.rows), cursorColumn: Int(raw.cursor_x), cursorRow: Int(raw.cursor_y),
            cursorVisible: raw.cursor_visible, defaultForegroundRGB: raw.default_fg, defaultBackgroundRGB: raw.default_bg, cells: cells)
    }
}

public enum GhosttyTerminalSnapshotRenderer {
    private static let boldFlag: UInt16 = 1 << 0
    private static let italicFlag: UInt16 = 1 << 1
    private static let faintFlag: UInt16 = 1 << 2
    private static let inverseFlag: UInt16 = 1 << 4
    private static let invisibleFlag: UInt16 = 1 << 5
    private static let strikeFlag: UInt16 = 1 << 6
    private static let underlineFlag: UInt16 = 1 << 7
    private static let spacerFlag: UInt16 = 1 << 10

    public static func render(_ snapshot: GhosttyTerminalSnapshot, defaultBackgroundOverride: NSColor? = nil) -> NSAttributedString {
        let rendered = NSMutableAttributedString()
        let columns = max(0, snapshot.columns)
        let rows = max(0, snapshot.rows)
        guard columns > 0, rows > 0, snapshot.cells.count >= columns * rows else { return rendered }

        let baseFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let defaultForeground = color(rgb: snapshot.defaultForegroundRGB)
        let defaultBackground = defaultBackgroundOverride ?? color(rgb: snapshot.defaultBackgroundRGB)

        for row in 0..<rows {
            let rowStart = row * columns
            let rowEnd = rowStart + columns
            let rowCells = Array(snapshot.cells[rowStart..<rowEnd])
            let lastColumn = visibleColumn(in: rowCells, row: row, snapshot: snapshot)
            if lastColumn >= 0 {
                for column in 0...lastColumn {
                    let cell = rowCells[column]
                    let character = displayCharacter(for: cell)
                    let isCursor = snapshot.cursorVisible && row == snapshot.cursorRow && column == snapshot.cursorColumn
                    let attributes = textAttributes(
                        for: cell, defaultBackgroundRGB: snapshot.defaultBackgroundRGB, baseFont: baseFont, defaultForeground: defaultForeground,
                        defaultBackground: defaultBackground, invertForCursor: isCursor)
                    rendered.append(NSAttributedString(string: character, attributes: attributes))
                }
            }
            if row < rows - 1 { rendered.append(NSAttributedString(string: "\n")) }
        }

        return rendered
    }

    public static func plainText(_ snapshot: GhosttyTerminalSnapshot) -> String {
        let columns = max(0, snapshot.columns)
        let rows = max(0, snapshot.rows)
        guard columns > 0, rows > 0, snapshot.cells.count >= columns * rows else { return "" }

        var lines: [String] = []
        lines.reserveCapacity(rows)
        for row in 0..<rows {
            let rowStart = row * columns
            let rowEnd = rowStart + columns
            let rowCells = Array(snapshot.cells[rowStart..<rowEnd])
            var line = ""
            for column in rowCells.indices {
                let cell = rowCells[column]
                if shouldKeep(cell: cell, defaultForegroundRGB: snapshot.defaultForegroundRGB, defaultBackgroundRGB: snapshot.defaultBackgroundRGB) {
                    line.append(displayCharacter(for: cell))
                } else if !line.isEmpty {
                    line.append(displayCharacter(for: cell))
                }
            }
            while line.last == " " { line.removeLast() }
            lines.append(line)
        }

        guard let firstNonEmptyIndex = lines.firstIndex(where: { !$0.isEmpty }), let lastNonEmptyIndex = lines.lastIndex(where: { !$0.isEmpty })
        else { return "" }
        return lines[firstNonEmptyIndex...lastNonEmptyIndex].joined(separator: "\n")
    }

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

    private static func displayCharacter(for cell: GhosttyTerminalSnapshot.Cell) -> String {
        if cell.flags & spacerFlag != 0 || cell.flags & invisibleFlag != 0 { return " " }
        guard cell.codepoint != 0 else { return " " }
        guard let scalar = UnicodeScalar(cell.codepoint) else { return "\u{FFFD}" }
        return String(scalar)
    }

    private static func textAttributes(
        for cell: GhosttyTerminalSnapshot.Cell, defaultBackgroundRGB: UInt32, baseFont: NSFont, defaultForeground: NSColor,
        defaultBackground: NSColor, invertForCursor: Bool
    ) -> [NSAttributedString.Key: Any] {
        var foreground = color(rgb: cell.foregroundRGB)
        var background = cell.backgroundRGB == defaultBackgroundRGB ? defaultBackground : color(rgb: cell.backgroundRGB)
        if cell.codepoint == 0 {
            foreground = defaultForeground
            background = defaultBackground
        }
        if cell.flags & inverseFlag != 0 || invertForCursor { swap(&foreground, &background) }
        let font = resolvedFont(from: baseFont, flags: cell.flags)
        var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: foreground, .backgroundColor: background]
        if cell.flags & faintFlag != 0 { attributes[.foregroundColor] = foreground.withAlphaComponent(0.65) }
        if cell.flags & underlineFlag != 0 {
            attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
            attributes[.underlineColor] = foreground
        }
        if cell.flags & strikeFlag != 0 {
            attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            attributes[.strikethroughColor] = foreground
        }
        return attributes
    }

    private static func resolvedFont(from baseFont: NSFont, flags: UInt16) -> NSFont {
        var traits: NSFontTraitMask = []
        if flags & boldFlag != 0 { traits.insert(.boldFontMask) }
        if flags & italicFlag != 0 { traits.insert(.italicFontMask) }
        return NSFontManager.shared.convert(baseFont, toHaveTrait: traits)
    }

    private static func color(rgb: UInt32) -> NSColor {
        NSColor(red: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255, blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
    }
}
