import Foundation

public struct TerminalScreenBuffer {
    private static let maxColumnCount = 240

    private var rows: [[Character]] = [[]]
    private var cursorRow = 0
    private var cursorColumn = 0

    public init() {}

    public mutating func reset() {
        rows = [[]]
        cursorRow = 0
        cursorColumn = 0
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

    public func renderedText() -> String {
        let trimmedLines = rows.map { row in String(row).replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression) }
        guard let firstNonEmptyIndex = trimmedLines.firstIndex(where: { !$0.isEmpty }) else { return "" }
        guard let lastNonEmptyIndex = trimmedLines.lastIndex(where: { !$0.isEmpty }) else { return "" }
        return trimmedLines[firstNonEmptyIndex...lastNonEmptyIndex].joined(separator: "\n")
    }

    private mutating func consumeEscapeSequence(_ scalars: [UnicodeScalar], startingAt index: Int) -> Int {
        let nextIndex = index + 1
        guard nextIndex < scalars.count else { return scalars.count }
        let introducer = scalars[nextIndex]
        switch introducer.value {
        case 0x5B: return consumeCSI(scalars, startingAt: nextIndex + 1)
        case 0x5D: return consumeOSC(scalars, startingAt: nextIndex + 1)
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
        case 0x48, 0x66:
            let row = max((values.count > 0 ? values[0] : 1) - 1, 0)
            let column = max((values.count > 1 ? values[1] : 1) - 1, 0)
            moveCursor(row: row, column: column)
        case 0x47:
            let column = max((values.first ?? 1) - 1, 0)
            moveCursor(column: column)
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
        case 0x6D, 0x68, 0x6C, 0x72, 0x75, 0x73: break
        default: break
        }
    }

    private mutating func write(_ character: Character) {
        ensurePosition()
        rows[cursorRow][cursorColumn] = character
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
        for index in cursorColumn..<rows[cursorRow].count { rows[cursorRow][index] = " " }
        trimTrailingSpaces(on: cursorRow)
    }

    private mutating func clearLineFromStartToCursor() {
        ensurePosition()
        guard !rows[cursorRow].isEmpty else { return }
        let upperBound = min(cursorColumn, rows[cursorRow].count - 1)
        if upperBound >= 0 { for index in 0...upperBound { rows[cursorRow][index] = " " } }
        trimTrailingSpaces(on: cursorRow)
    }

    private mutating func ensurePosition() {
        ensureRowExists(cursorRow)
        if rows[cursorRow].count <= cursorColumn {
            rows[cursorRow].append(contentsOf: repeatElement(" ", count: cursorColumn - rows[cursorRow].count + 1))
        }
    }

    private mutating func ensureRowExists(_ row: Int) {
        guard row >= rows.count else { return }
        rows.append(contentsOf: repeatElement([], count: row - rows.count + 1))
    }

    private mutating func trimTrailingSpaces(on row: Int) {
        guard rows.indices.contains(row) else { return }
        while rows[row].last == " " { rows[row].removeLast() }
    }
}
