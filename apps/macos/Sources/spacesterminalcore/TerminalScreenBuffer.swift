import Foundation

public enum TerminalANSIColor: Equatable {
    case palette(Int)
    case rgb(UInt8, UInt8, UInt8)
}

public struct TerminalTextStyle: Equatable {
    public var foreground: TerminalANSIColor?
    public var background: TerminalANSIColor?
    public var bold = false
    public var italic = false
    public var faint = false
    public var underline = false
    public var inverse = false
    public var hidden = false
    public var strikethrough = false

    public init(
        foreground: TerminalANSIColor? = nil, background: TerminalANSIColor? = nil, bold: Bool = false, italic: Bool = false, faint: Bool = false,
        underline: Bool = false, inverse: Bool = false, hidden: Bool = false, strikethrough: Bool = false
    ) {
        self.foreground = foreground
        self.background = background
        self.bold = bold
        self.italic = italic
        self.faint = faint
        self.underline = underline
        self.inverse = inverse
        self.hidden = hidden
        self.strikethrough = strikethrough
    }
}

public struct TerminalRenderedCell: Equatable {
    public let character: Character
    public let style: TerminalTextStyle

    public init(character: Character, style: TerminalTextStyle) {
        self.character = character
        self.style = style
    }
}

public struct TerminalRenderedScreen: Equatable {
    public let rows: [[TerminalRenderedCell]]
    public let cursorRow: Int
    public let cursorColumn: Int
    public let cursorVisible: Bool

    public init(rows: [[TerminalRenderedCell]], cursorRow: Int, cursorColumn: Int, cursorVisible: Bool) {
        self.rows = rows
        self.cursorRow = cursorRow
        self.cursorColumn = cursorColumn
        self.cursorVisible = cursorVisible
    }

    public var plainText: String {
        let trimmedLines = rows.map { row in
            let visibleCells = row.reversed().drop(while: { $0.character == " " }).reversed()
            return String(visibleCells.map(\.character))
        }
        guard let firstNonEmptyIndex = trimmedLines.firstIndex(where: { !$0.isEmpty }) else { return "" }
        guard let lastNonEmptyIndex = trimmedLines.lastIndex(where: { !$0.isEmpty }) else { return "" }
        return trimmedLines[firstNonEmptyIndex...lastNonEmptyIndex].joined(separator: "\n")
    }
}

public struct TerminalScreenBuffer {
    private static let maxColumnCount = 240

    private struct Cell: Equatable {
        var character: Character
        var style: TerminalTextStyle
    }

    private var rows: [[Cell]] = [[]]
    private var cursorRow = 0
    private var cursorColumn = 0
    private var savedCursorRow = 0
    private var savedCursorColumn = 0
    private var primaryRows: [[Cell]]?
    private var primaryCursorRow = 0
    private var primaryCursorColumn = 0
    private var currentStyle = TerminalTextStyle()
    private var cursorVisible = true
    private var isUsingAlternateScreen = false

    public init() {}

    public mutating func reset() {
        rows = [[]]
        cursorRow = 0
        cursorColumn = 0
        savedCursorRow = 0
        savedCursorColumn = 0
        primaryRows = nil
        primaryCursorRow = 0
        primaryCursorColumn = 0
        currentStyle = TerminalTextStyle()
        cursorVisible = true
        isUsingAlternateScreen = false
    }

    public mutating func ingest(_ text: String) {
        let scalars = Array(text.unicodeScalars)
        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            switch scalar.value {
            case 0x1B: index = consumeEscapeSequence(scalars, startingAt: index)
            case 0x08:
                moveCursor(column: max(0, cursorColumn - 1))
                index += 1
            case 0x09:
                let nextTabStop = ((cursorColumn / 8) + 1) * 8
                moveCursor(column: nextTabStop)
                index += 1
            case 0x0A:
                newline()
                index += 1
            case 0x0D:
                carriageReturn()
                index += 1
            case 0x07: index += 1
            default:
                write(Character(scalar))
                index += 1
            }
        }
    }

    public func renderedText() -> String { renderedScreen().plainText }

    public func renderedScreen() -> TerminalRenderedScreen {
        TerminalRenderedScreen(
            rows: rows.map { $0.map { TerminalRenderedCell(character: $0.character, style: $0.style) } }, cursorRow: cursorRow,
            cursorColumn: cursorColumn, cursorVisible: cursorVisible)
    }

    private mutating func consumeEscapeSequence(_ scalars: [UnicodeScalar], startingAt index: Int) -> Int {
        let nextIndex = index + 1
        guard nextIndex < scalars.count else { return scalars.count }
        let introducer = scalars[nextIndex]
        switch introducer.value {
        case 0x5B: return consumeCSI(scalars, startingAt: nextIndex + 1)
        case 0x5D: return consumeOSC(scalars, startingAt: nextIndex + 1)
        case 0x37:
            saveCursor()
            return nextIndex + 1
        case 0x38:
            restoreCursor()
            return nextIndex + 1
        default: return nextIndex + 1
        }
    }

    private mutating func consumeCSI(_ scalars: [UnicodeScalar], startingAt index: Int) -> Int {
        var current = index
        var parameterBuffer = ""
        while current < scalars.count {
            let scalar = scalars[current]
            if scalar.value >= 0x40 && scalar.value <= 0x7E {
                applyCSI(final: scalar, parameters: parameterBuffer)
                return current + 1
            }
            parameterBuffer.unicodeScalars.append(scalar)
            current += 1
        }
        return current
    }

    private func consumeOSC(_ scalars: [UnicodeScalar], startingAt index: Int) -> Int {
        var current = index
        while current < scalars.count {
            let scalar = scalars[current]
            if scalar.value == 0x07 { return current + 1 }
            if scalar.value == 0x1B, current + 1 < scalars.count, scalars[current + 1].value == 0x5C { return current + 2 }
            current += 1
        }
        return current
    }

    private mutating func applyCSI(final: UnicodeScalar, parameters: String) {
        let cleaned = parameters.replacingOccurrences(of: "?", with: "")
        let values = cleaned.split(separator: ";", omittingEmptySubsequences: false).map { Int($0) ?? 0 }

        switch final.value {
        case 0x41: moveCursor(row: max(0, cursorRow - max(values.first ?? 0, 1)))
        case 0x42: moveCursor(row: cursorRow + max(values.first ?? 0, 1))
        case 0x43: moveCursor(column: cursorColumn + max(values.first ?? 0, 1))
        case 0x44: moveCursor(column: max(0, cursorColumn - max(values.first ?? 0, 1)))
        case 0x45: moveCursor(row: cursorRow + max(values.first ?? 0, 1), column: 0)
        case 0x46: moveCursor(row: max(0, cursorRow - max(values.first ?? 0, 1)), column: 0)
        case 0x48, 0x66:
            let row = max((values.count > 0 ? values[0] : 1) - 1, 0)
            let column = max((values.count > 1 ? values[1] : 1) - 1, 0)
            moveCursor(row: row, column: column)
        case 0x47:
            let column = max((values.first ?? 1) - 1, 0)
            moveCursor(column: column)
        case 0x64:
            let row = max((values.first ?? 1) - 1, 0)
            moveCursor(row: row)
        case 0x4A:
            switch values.first ?? 0 {
            case 0: clearFromCursorToDisplayEnd()
            case 1: clearFromDisplayStartToCursor()
            case 2, 3: clearDisplay()
            default: break
            }
        case 0x4B:
            switch values.first ?? 0 {
            case 0: clearLineFromCursorToEnd()
            case 1: clearLineFromStartToCursor()
            case 2: clearCurrentLine()
            default: break
            }
        case 0x40: insertCharacters(max(values.first ?? 0, 1))
        case 0x50: deleteCharacters(max(values.first ?? 0, 1))
        case 0x58: eraseCharacters(max(values.first ?? 0, 1))
        case 0x4C: insertLines(max(values.first ?? 0, 1))
        case 0x4D: deleteLines(max(values.first ?? 0, 1))
        case 0x53: scrollUp(max(values.first ?? 0, 1))
        case 0x54: scrollDown(max(values.first ?? 0, 1))
        case 0x73: saveCursor()
        case 0x75: restoreCursor()
        case 0x6D: applySGR(values)
        case 0x68: applyMode(values, enabled: true)
        case 0x6C: applyMode(values, enabled: false)
        case 0x72: break
        default: break
        }
    }

    private mutating func applySGR(_ values: [Int]) {
        let params = values.isEmpty ? [0] : values
        var index = 0
        while index < params.count {
            let value = params[index]
            switch value {
            case 0: currentStyle = TerminalTextStyle()
            case 1: currentStyle.bold = true
            case 2: currentStyle.faint = true
            case 3: currentStyle.italic = true
            case 4: currentStyle.underline = true
            case 7: currentStyle.inverse = true
            case 8: currentStyle.hidden = true
            case 9: currentStyle.strikethrough = true
            case 22:
                currentStyle.bold = false
                currentStyle.faint = false
            case 23: currentStyle.italic = false
            case 24: currentStyle.underline = false
            case 27: currentStyle.inverse = false
            case 28: currentStyle.hidden = false
            case 29: currentStyle.strikethrough = false
            case 30...37: currentStyle.foreground = .palette(value - 30)
            case 39: currentStyle.foreground = nil
            case 40...47: currentStyle.background = .palette(value - 40)
            case 49: currentStyle.background = nil
            case 90...97: currentStyle.foreground = .palette(value - 90 + 8)
            case 100...107: currentStyle.background = .palette(value - 100 + 8)
            case 38: index = applyExtendedColor(params, startingAt: index, isForeground: true)
            case 48: index = applyExtendedColor(params, startingAt: index, isForeground: false)
            default: break
            }
            index += 1
        }
    }

    private mutating func applyMode(_ values: [Int], enabled: Bool) {
        for value in values {
            switch value {
            case 25: cursorVisible = enabled
            case 47, 1047, 1049: setAlternateScreen(enabled)
            default: break
            }
        }
    }

    private mutating func setAlternateScreen(_ enabled: Bool) {
        if enabled {
            guard !isUsingAlternateScreen else { return }
            primaryRows = rows
            primaryCursorRow = cursorRow
            primaryCursorColumn = cursorColumn
            rows = [[]]
            cursorRow = 0
            cursorColumn = 0
            savedCursorRow = 0
            savedCursorColumn = 0
            isUsingAlternateScreen = true
        } else {
            guard isUsingAlternateScreen else { return }
            rows = primaryRows ?? [[]]
            cursorRow = primaryCursorRow
            cursorColumn = primaryCursorColumn
            primaryRows = nil
            primaryCursorRow = 0
            primaryCursorColumn = 0
            isUsingAlternateScreen = false
        }
    }

    private mutating func applyExtendedColor(_ params: [Int], startingAt index: Int, isForeground: Bool) -> Int {
        let markerIndex = index + 1
        guard markerIndex < params.count else { return index }
        switch params[markerIndex] {
        case 5:
            let paletteIndex = markerIndex + 1
            guard paletteIndex < params.count else { return markerIndex }
            setColor(.palette(max(0, min(params[paletteIndex], 255))), isForeground: isForeground)
            return paletteIndex
        case 2:
            let blueIndex = markerIndex + 3
            guard blueIndex < params.count else { return markerIndex }
            let color = TerminalANSIColor.rgb(
                UInt8(clamping: params[markerIndex + 1]), UInt8(clamping: params[markerIndex + 2]), UInt8(clamping: params[blueIndex]))
            setColor(color, isForeground: isForeground)
            return blueIndex
        default: return markerIndex
        }
    }

    private mutating func setColor(_ color: TerminalANSIColor, isForeground: Bool) {
        if isForeground { currentStyle.foreground = color } else { currentStyle.background = color }
    }

    private mutating func write(_ character: Character) {
        ensurePosition()
        rows[cursorRow][cursorColumn] = Cell(character: character, style: currentStyle)
        cursorColumn = min(cursorColumn + 1, Self.maxColumnCount - 1)
    }

    private mutating func newline() {
        cursorRow += 1
        cursorColumn = 0
        ensurePosition()
    }

    private mutating func carriageReturn() { cursorColumn = 0 }

    private mutating func moveCursor(row: Int? = nil, column: Int? = nil) {
        if let row { cursorRow = max(row, 0) }
        if let column { cursorColumn = max(min(column, Self.maxColumnCount - 1), 0) }
        ensurePosition()
    }

    private mutating func clearDisplay() {
        rows = [[]]
        cursorRow = 0
        cursorColumn = 0
    }

    private mutating func saveCursor() {
        savedCursorRow = cursorRow
        savedCursorColumn = cursorColumn
    }

    private mutating func restoreCursor() { moveCursor(row: savedCursorRow, column: savedCursorColumn) }

    private mutating func clearFromCursorToDisplayEnd() {
        clearLineFromCursorToEnd()
        guard cursorRow + 1 < rows.count else { return }
        for index in (cursorRow + 1)..<rows.count { rows[index] = [] }
    }

    private mutating func clearFromDisplayStartToCursor() {
        guard !rows.isEmpty else { return }
        if cursorRow > 0 { for index in 0..<min(cursorRow, rows.count) { rows[index] = [] } }
        clearLineFromStartToCursor()
    }

    private mutating func clearCurrentLine() {
        ensureRowExists(cursorRow)
        rows[cursorRow] = []
    }

    private mutating func clearLineFromCursorToEnd() {
        ensurePosition()
        for index in cursorColumn..<rows[cursorRow].count { rows[cursorRow][index] = Cell(character: " ", style: currentStyle) }
        trimTrailingSpaces(on: cursorRow)
    }

    private mutating func clearLineFromStartToCursor() {
        ensurePosition()
        guard !rows[cursorRow].isEmpty else { return }
        let upperBound = min(cursorColumn, rows[cursorRow].count - 1)
        if upperBound >= 0 { for index in 0...upperBound { rows[cursorRow][index] = Cell(character: " ", style: currentStyle) } }
        trimTrailingSpaces(on: cursorRow)
    }

    private mutating func insertCharacters(_ count: Int) {
        guard count > 0 else { return }
        ensurePosition()
        let insertionCount = min(count, Self.maxColumnCount - cursorColumn)
        guard insertionCount > 0 else { return }
        let blank = Cell(character: " ", style: currentStyle)
        rows[cursorRow].insert(contentsOf: repeatElement(blank, count: insertionCount), at: cursorColumn)
        if rows[cursorRow].count > Self.maxColumnCount { rows[cursorRow].removeLast(rows[cursorRow].count - Self.maxColumnCount) }
        trimTrailingSpaces(on: cursorRow)
    }

    private mutating func deleteCharacters(_ count: Int) {
        guard count > 0 else { return }
        ensurePosition()
        guard cursorColumn < rows[cursorRow].count else { return }
        let upperBound = min(cursorColumn + count, rows[cursorRow].count)
        rows[cursorRow].removeSubrange(cursorColumn..<upperBound)
        trimTrailingSpaces(on: cursorRow)
    }

    private mutating func eraseCharacters(_ count: Int) {
        guard count > 0 else { return }
        ensurePosition()
        let upperBound = min(cursorColumn + count, rows[cursorRow].count)
        guard cursorColumn < upperBound else { return }
        for index in cursorColumn..<upperBound { rows[cursorRow][index] = Cell(character: " ", style: currentStyle) }
        trimTrailingSpaces(on: cursorRow)
    }

    private mutating func insertLines(_ count: Int) {
        guard count > 0 else { return }
        ensureRowExists(cursorRow)
        rows.insert(contentsOf: repeatElement([], count: count), at: cursorRow)
    }

    private mutating func deleteLines(_ count: Int) {
        guard count > 0, cursorRow < rows.count else { return }
        let upperBound = min(cursorRow + count, rows.count)
        rows.removeSubrange(cursorRow..<upperBound)
        if rows.isEmpty {
            rows = [[]]
            cursorRow = 0
            cursorColumn = 0
            return
        }
        cursorRow = min(cursorRow, rows.count - 1)
        cursorColumn = min(cursorColumn, max(rows[cursorRow].count - 1, 0))
    }

    private mutating func scrollUp(_ count: Int) {
        guard count > 0, !rows.isEmpty else { return }
        let amount = min(count, rows.count)
        rows.removeFirst(amount)
        rows.append(contentsOf: repeatElement([], count: amount))
        cursorRow = min(cursorRow, max(rows.count - 1, 0))
    }

    private mutating func scrollDown(_ count: Int) {
        guard count > 0, !rows.isEmpty else { return }
        let amount = min(count, rows.count)
        rows.insert(contentsOf: repeatElement([], count: amount), at: 0)
        if rows.count > Self.maxColumnCount { rows.removeLast(rows.count - Self.maxColumnCount) }
        cursorRow = min(cursorRow + amount, max(rows.count - 1, 0))
    }

    private mutating func ensurePosition() {
        ensureRowExists(cursorRow)
        if rows[cursorRow].count <= cursorColumn {
            rows[cursorRow].append(
                contentsOf: repeatElement(Cell(character: " ", style: currentStyle), count: cursorColumn - rows[cursorRow].count + 1))
        }
    }

    private mutating func ensureRowExists(_ row: Int) {
        guard row >= rows.count else { return }
        rows.append(contentsOf: repeatElement([], count: row - rows.count + 1))
    }

    private mutating func trimTrailingSpaces(on row: Int) {
        guard rows.indices.contains(row) else { return }
        while rows[row].last?.character == " " { rows[row].removeLast() }
    }
}
