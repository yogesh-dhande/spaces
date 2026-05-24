import Foundation

public enum GhosttyTerminalSnapshotVTEncoder {
    private static let boldFlag: UInt16 = 1 << 0
    private static let italicFlag: UInt16 = 1 << 1
    private static let faintFlag: UInt16 = 1 << 2
    private static let inverseFlag: UInt16 = 1 << 4
    private static let invisibleFlag: UInt16 = 1 << 5
    private static let strikeFlag: UInt16 = 1 << 6
    private static let underlineFlag: UInt16 = 1 << 7
    private static let spacerFlag: UInt16 = 1 << 10

    private struct StyleState: Equatable {
        let foregroundRGB: UInt32
        let backgroundRGB: UInt32
        let bold: Bool
        let italic: Bool
        let faint: Bool
        let inverse: Bool
        let invisible: Bool
        let strike: Bool
        let underline: Bool

        init(cell: GhosttyTerminalSnapshot.Cell, snapshot: GhosttyTerminalSnapshot) {
            foregroundRGB = cell.foregroundRGB
            backgroundRGB = cell.backgroundRGB
            bold = cell.flags & boldFlag != 0
            italic = cell.flags & italicFlag != 0
            faint = cell.flags & faintFlag != 0
            inverse = cell.flags & inverseFlag != 0
            invisible = cell.flags & invisibleFlag != 0
            strike = cell.flags & strikeFlag != 0
            underline = cell.flags & underlineFlag != 0
        }
    }

    public static func encode(_ snapshot: GhosttyTerminalSnapshot) -> Data {
        var buffer = Data()
        append("\u{1B}[?25l", to: &buffer)
        append("\u{1B}[0m", to: &buffer)
        append("\u{1B}[H", to: &buffer)
        append("\u{1B}[2J", to: &buffer)

        guard snapshot.columns > 0, snapshot.rows > 0 else { return buffer }

        let totalCells = snapshot.columns * snapshot.rows
        guard snapshot.cells.count >= totalCells else { return buffer }

        var activeStyle: StyleState?
        for row in 0..<snapshot.rows {
            append("\u{1B}[\(row + 1);1H", to: &buffer)
            let rowOffset = row * snapshot.columns
            for column in 0..<snapshot.columns {
                let cell = snapshot.cells[rowOffset + column]
                if cell.flags & spacerFlag != 0 { continue }

                let nextStyle = StyleState(cell: cell, snapshot: snapshot)
                if activeStyle != nextStyle {
                    append(styleSequence(for: nextStyle), to: &buffer)
                    activeStyle = nextStyle
                }

                append(displayString(for: cell), to: &buffer)
            }
            append("\u{1B}[K", to: &buffer)
        }

        append("\u{1B}[0m", to: &buffer)
        if snapshot.cursorVisible {
            append("\u{1B}[?25h", to: &buffer)
            append("\u{1B}[\(snapshot.cursorRow + 1);\(snapshot.cursorColumn + 1)H", to: &buffer)
        } else {
            append("\u{1B}[?25l", to: &buffer)
        }

        return buffer
    }

    private static func displayString(for cell: GhosttyTerminalSnapshot.Cell) -> String {
        if cell.flags & invisibleFlag != 0 || cell.codepoint == 0 { return " " }
        guard let scalar = UnicodeScalar(cell.codepoint) else { return "\u{FFFD}" }
        return String(scalar)
    }

    private static func styleSequence(for style: StyleState) -> String {
        let foreground = rgbComponents(style.foregroundRGB)
        let background = rgbComponents(style.backgroundRGB)
        var parts: [String] = ["0"]
        if style.bold { parts.append("1") }
        if style.faint { parts.append("2") }
        if style.italic { parts.append("3") }
        if style.underline { parts.append("4") }
        if style.inverse { parts.append("7") }
        if style.invisible { parts.append("8") }
        if style.strike { parts.append("9") }
        parts.append(contentsOf: ["38", "2", "\(foreground.red)", "\(foreground.green)", "\(foreground.blue)"])
        parts.append(contentsOf: ["48", "2", "\(background.red)", "\(background.green)", "\(background.blue)"])
        return "\u{1B}[\(parts.joined(separator: ";"))m"
    }

    private static func rgbComponents(_ rgb: UInt32) -> (red: UInt32, green: UInt32, blue: UInt32) {
        ((rgb >> 16) & 0xFF, (rgb >> 8) & 0xFF, rgb & 0xFF)
    }

    private static func append(_ string: String, to buffer: inout Data) { buffer.append(contentsOf: string.utf8) }
}
