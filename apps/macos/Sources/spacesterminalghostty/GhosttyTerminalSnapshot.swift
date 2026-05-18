import AppKit
import Foundation
import GhosttyKit

public struct GhosttyTerminalSnapshot: Codable, Sendable, Equatable {
    public struct Cell: Codable, Sendable, Equatable {
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
    public static func captureFromSurface(_ surface: ghostty_surface_t?) -> GhosttyTerminalSnapshot? {
        guard let surface else { return nil }
        var snapshot = ghostty_terminal_snapshot_s()
        guard ghostty_surface_export_snapshot(surface, &snapshot) else { return nil }
        defer { ghostty_terminal_snapshot_free(&snapshot) }
        return makeSnapshot(from: snapshot)
    }

    public static func captureFromSession(_ session: ghostty_session_t?) -> GhosttyTerminalSnapshot? {
        guard let session else { return nil }
        var snapshot = ghostty_terminal_snapshot_s()
        guard ghostty_session_export_snapshot(session, &snapshot) else { return nil }
        defer { ghostty_terminal_snapshot_free(&snapshot) }
        return makeSnapshot(from: snapshot)
    }

    public static func captureText(from surface: ghostty_surface_t?) -> String? {
        guard let surface else { return nil }
        let size = ghostty_surface_size(surface)
        guard size.columns > 0, size.rows > 0 else { return nil }

        var text = ghostty_text_s()
        let selection = wholeSurfaceSelection(columns: size.columns, rows: size.rows)
        guard ghostty_surface_read_text(surface, selection, &text) else { return nil }
        defer { ghostty_surface_free_text(surface, &text) }
        guard let raw = text.text, text.text_len > 0 else { return "" }
        let bytes = UnsafeRawBufferPointer(start: UnsafeRawPointer(raw), count: Int(text.text_len))
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func wholeSurfaceSelection(columns: UInt16, rows: UInt16) -> ghostty_selection_s {
        let maxColumn = UInt32(max(Int(columns) - 1, 0))
        let maxRow = UInt32(max(Int(rows) - 1, 0))
        return ghostty_selection_s(
            top_left: ghostty_point_s(tag: GHOSTTY_POINT_SURFACE, coord: GHOSTTY_POINT_COORD_TOP_LEFT, x: 0, y: 0),
            bottom_right: ghostty_point_s(tag: GHOSTTY_POINT_SURFACE, coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT, x: maxColumn, y: maxRow),
            rectangle: false)
    }

    private static func makeSnapshot(from snapshot: ghostty_terminal_snapshot_s) -> GhosttyTerminalSnapshot {
        let cellCount = Int(snapshot.cell_count)
        let cells: [GhosttyTerminalSnapshot.Cell]
        if let rawCells = snapshot.cells, cellCount > 0 {
            let buffer = UnsafeBufferPointer(start: rawCells, count: cellCount)
            cells = buffer.map {
                GhosttyTerminalSnapshot.Cell(
                    codepoint: $0.codepoint, foregroundRGB: $0.foreground_rgb, backgroundRGB: $0.background_rgb, flags: $0.flags)
            }
        } else {
            cells = []
        }

        return GhosttyTerminalSnapshot(
            columns: Int(snapshot.columns), rows: Int(snapshot.rows), cursorColumn: Int(snapshot.cursor_column), cursorRow: Int(snapshot.cursor_row),
            cursorVisible: snapshot.cursor_visible, defaultForegroundRGB: snapshot.default_foreground_rgb,
            defaultBackgroundRGB: snapshot.default_background_rgb, cells: cells)
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
