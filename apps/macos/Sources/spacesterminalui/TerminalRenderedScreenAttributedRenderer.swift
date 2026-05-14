import AppKit
import spacesterminalcore

enum TerminalRenderedScreenAttributedRenderer {
    private static let ansiPalette: [NSColor] = [
        .init(calibratedRed: 0.12, green: 0.14, blue: 0.16, alpha: 1), .init(calibratedRed: 0.86, green: 0.24, blue: 0.21, alpha: 1),
        .init(calibratedRed: 0.30, green: 0.64, blue: 0.27, alpha: 1), .init(calibratedRed: 0.77, green: 0.62, blue: 0.20, alpha: 1),
        .init(calibratedRed: 0.28, green: 0.49, blue: 0.85, alpha: 1), .init(calibratedRed: 0.67, green: 0.37, blue: 0.74, alpha: 1),
        .init(calibratedRed: 0.19, green: 0.63, blue: 0.71, alpha: 1), .init(calibratedRed: 0.77, green: 0.79, blue: 0.82, alpha: 1),
        .init(calibratedRed: 0.32, green: 0.35, blue: 0.39, alpha: 1), .init(calibratedRed: 0.95, green: 0.39, blue: 0.34, alpha: 1),
        .init(calibratedRed: 0.46, green: 0.77, blue: 0.36, alpha: 1), .init(calibratedRed: 0.91, green: 0.78, blue: 0.33, alpha: 1),
        .init(calibratedRed: 0.47, green: 0.66, blue: 0.96, alpha: 1), .init(calibratedRed: 0.81, green: 0.56, blue: 0.89, alpha: 1),
        .init(calibratedRed: 0.33, green: 0.75, blue: 0.82, alpha: 1), .init(calibratedRed: 0.94, green: 0.95, blue: 0.96, alpha: 1),
    ]

    static func render(
        _ screen: TerminalRenderedScreen, defaultForeground: NSColor = .textColor, defaultBackground: NSColor = .textBackgroundColor,
        font: NSFont = .monospacedSystemFont(ofSize: 12, weight: .regular)
    ) -> NSAttributedString {
        let rendered = NSMutableAttributedString()
        let visibleRowRange = visibleRows(in: screen)
        guard let visibleRowRange else { return rendered }

        for rowIndex in visibleRowRange {
            let row = screen.rows[rowIndex]
            let lastVisibleColumn = visibleColumn(in: row, rowIndex: rowIndex, screen: screen)
            if lastVisibleColumn >= 0 {
                for column in 0...lastVisibleColumn {
                    let cell = column < row.count ? row[column] : TerminalRenderedCell(character: " ", style: TerminalTextStyle())
                    let isCursor = screen.cursorVisible && rowIndex == screen.cursorRow && column == screen.cursorColumn
                    rendered.append(
                        NSAttributedString(
                            string: String(cell.character),
                            attributes: attributes(
                                for: cell.style, defaultForeground: defaultForeground, defaultBackground: defaultBackground, baseFont: font,
                                invertForCursor: isCursor)))
                }
            }
            if rowIndex < visibleRowRange.upperBound - 1 { rendered.append(NSAttributedString(string: "\n")) }
        }

        return rendered
    }

    private static func visibleRows(in screen: TerminalRenderedScreen) -> Range<Int>? {
        var firstVisibleRow: Int?
        var lastVisibleRow: Int?
        for (rowIndex, row) in screen.rows.enumerated() where row.contains(where: { $0.character != " " }) {
            if firstVisibleRow == nil { firstVisibleRow = rowIndex }
            lastVisibleRow = rowIndex
        }
        if screen.cursorVisible, screen.rows.indices.contains(screen.cursorRow) {
            firstVisibleRow = min(firstVisibleRow ?? screen.cursorRow, screen.cursorRow)
            lastVisibleRow = max(lastVisibleRow ?? screen.cursorRow, screen.cursorRow)
        }
        guard let firstVisibleRow, let lastVisibleRow else { return nil }
        return firstVisibleRow..<(lastVisibleRow + 1)
    }

    private static func visibleColumn(in row: [TerminalRenderedCell], rowIndex: Int, screen: TerminalRenderedScreen) -> Int {
        var lastVisibleColumn = -1
        for (column, cell) in row.enumerated() where shouldKeep(cell: cell) { lastVisibleColumn = column }
        if screen.cursorVisible, rowIndex == screen.cursorRow { lastVisibleColumn = max(lastVisibleColumn, screen.cursorColumn) }
        return lastVisibleColumn
    }

    private static func shouldKeep(cell: TerminalRenderedCell) -> Bool {
        if cell.character != " " { return true }
        let style = cell.style
        return style.foreground != nil || style.background != nil || style.bold || style.italic || style.faint || style.underline || style.inverse
            || style.hidden || style.strikethrough
    }

    private static func attributes(
        for style: TerminalTextStyle, defaultForeground: NSColor, defaultBackground: NSColor, baseFont: NSFont, invertForCursor: Bool
    ) -> [NSAttributedString.Key: Any] {
        var foreground = resolveColor(style.foreground, fallback: defaultForeground)
        var background = resolveColor(style.background, fallback: defaultBackground)
        if style.inverse || invertForCursor { swap(&foreground, &background) }
        if style.hidden { foreground = background }
        if style.faint { foreground = foreground.withAlphaComponent(0.7) }

        var traits: NSFontTraitMask = []
        if style.bold { traits.insert(.boldFontMask) }
        if style.italic { traits.insert(.italicFontMask) }
        let font = NSFontManager.shared.convert(baseFont, toHaveTrait: traits)

        var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: foreground, .backgroundColor: background]
        if style.underline {
            attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
            attributes[.underlineColor] = foreground
        }
        if style.strikethrough {
            attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            attributes[.strikethroughColor] = foreground
        }
        return attributes
    }

    private static func resolveColor(_ color: TerminalANSIColor?, fallback: NSColor) -> NSColor {
        guard let color else { return fallback }
        switch color {
        case .palette(let index): return ansiPalette.indices.contains(index) ? ansiPalette[index] : fallback
        case .rgb(let red, let green, let blue):
            return NSColor(calibratedRed: CGFloat(red) / 255, green: CGFloat(green) / 255, blue: CGFloat(blue) / 255, alpha: 1)
        }
    }
}
