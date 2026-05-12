import Foundation

enum TerminalTranscriptRenderer {
    static func render(_ text: String) -> String {
        let hasEscapeSequences = text.unicodeScalars.contains("\u{001B}")
        let hasControlCharacters = text.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x08, 0x0D: return true
            default: return false
            }
        }
        guard hasEscapeSequences || hasControlCharacters else { return text }

        var state = State()
        let scalars = Array(text.unicodeScalars)
        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            switch scalar.value {
            case 0x1B: index = consumeEscapeSequence(scalars, startingAt: index, state: &state)
            case 0x08:
                state.moveCursor(column: max(0, state.cursorColumn - 1))
                index += 1
            case 0x09:
                let nextTabStop = ((state.cursorColumn / 8) + 1) * 8
                state.moveCursor(column: nextTabStop)
                index += 1
            case 0x0A:
                state.newline()
                index += 1
            case 0x0D:
                state.carriageReturn()
                index += 1
            case 0x07: index += 1
            default:
                state.write(Character(scalar))
                index += 1
            }
        }

        return state.renderedText()
    }

    private static func consumeEscapeSequence(_ scalars: [UnicodeScalar], startingAt index: Int, state: inout State) -> Int {
        let nextIndex = index + 1
        guard nextIndex < scalars.count else { return scalars.count }
        let introducer = scalars[nextIndex]
        switch introducer.value {
        case 0x5B: return consumeCSI(scalars, startingAt: nextIndex + 1, state: &state)
        case 0x5D: return consumeOSC(scalars, startingAt: nextIndex + 1)
        default: return nextIndex + 1
        }
    }

    private static func consumeCSI(_ scalars: [UnicodeScalar], startingAt index: Int, state: inout State) -> Int {
        var current = index
        var parameterBuffer = ""
        while current < scalars.count {
            let scalar = scalars[current]
            if scalar.value >= 0x40 && scalar.value <= 0x7E {
                applyCSI(final: scalar, parameters: parameterBuffer, state: &state)
                return current + 1
            }
            parameterBuffer.unicodeScalars.append(scalar)
            current += 1
        }
        return current
    }

    private static func consumeOSC(_ scalars: [UnicodeScalar], startingAt index: Int) -> Int {
        var current = index
        while current < scalars.count {
            let scalar = scalars[current]
            if scalar.value == 0x07 { return current + 1 }
            if scalar.value == 0x1B, current + 1 < scalars.count, scalars[current + 1].value == 0x5C { return current + 2 }
            current += 1
        }
        return current
    }

    private static func applyCSI(final: UnicodeScalar, parameters: String, state: inout State) {
        let cleaned = parameters.replacingOccurrences(of: "?", with: "")
        let values = cleaned.split(separator: ";", omittingEmptySubsequences: false).map { Int($0) ?? 0 }

        switch final.value {
        case 0x41: state.moveCursor(row: max(0, state.cursorRow - max(values.first ?? 0, 1)))
        case 0x42: state.moveCursor(row: state.cursorRow + max(values.first ?? 0, 1))
        case 0x43: state.moveCursor(column: state.cursorColumn + max(values.first ?? 0, 1))
        case 0x44: state.moveCursor(column: max(0, state.cursorColumn - max(values.first ?? 0, 1)))
        case 0x48, 0x66:
            let row = max((values.count > 0 ? values[0] : 1) - 1, 0)
            let column = max((values.count > 1 ? values[1] : 1) - 1, 0)
            state.moveCursor(row: row, column: column)
        case 0x47:
            let column = max((values.first ?? 1) - 1, 0)
            state.moveCursor(column: column)
        case 0x4A:
            switch values.first ?? 0 {
            case 0: state.clearFromCursorToDisplayEnd()
            case 1: state.clearFromDisplayStartToCursor()
            case 2, 3: state.clearDisplay()
            default: break
            }
        case 0x4B:
            switch values.first ?? 0 {
            case 0: state.clearLineFromCursorToEnd()
            case 1: state.clearLineFromStartToCursor()
            case 2: state.clearCurrentLine()
            default: break
            }
        case 0x6D, 0x68, 0x6C, 0x72, 0x75, 0x73: break
        default: break
        }
    }
}

private struct State {
    private static let maxColumnCount = 240

    var rows: [[Character]] = [[]]
    var cursorRow = 0
    var cursorColumn = 0

    mutating func write(_ character: Character) {
        ensurePosition()
        rows[cursorRow][cursorColumn] = character
        cursorColumn = min(cursorColumn + 1, Self.maxColumnCount - 1)
    }

    mutating func newline() {
        cursorRow += 1
        cursorColumn = 0
        ensurePosition()
    }

    mutating func carriageReturn() { cursorColumn = 0 }

    mutating func moveCursor(row: Int? = nil, column: Int? = nil) {
        if let row { cursorRow = max(row, 0) }
        if let column { cursorColumn = max(min(column, Self.maxColumnCount - 1), 0) }
        ensurePosition()
    }

    mutating func clearDisplay() {
        rows = [[]]
        cursorRow = 0
        cursorColumn = 0
    }

    mutating func clearFromCursorToDisplayEnd() {
        clearLineFromCursorToEnd()
        guard cursorRow + 1 < rows.count else { return }
        for index in (cursorRow + 1)..<rows.count { rows[index] = [] }
    }

    mutating func clearFromDisplayStartToCursor() {
        guard !rows.isEmpty else { return }
        if cursorRow > 0 { for index in 0..<min(cursorRow, rows.count) { rows[index] = [] } }
        clearLineFromStartToCursor()
    }

    mutating func clearCurrentLine() {
        ensureRowExists(cursorRow)
        rows[cursorRow] = []
    }

    mutating func clearLineFromCursorToEnd() {
        ensurePosition()
        for index in cursorColumn..<rows[cursorRow].count { rows[cursorRow][index] = " " }
        trimTrailingSpaces(on: cursorRow)
    }

    mutating func clearLineFromStartToCursor() {
        ensurePosition()
        guard !rows[cursorRow].isEmpty else { return }
        let upperBound = min(cursorColumn, rows[cursorRow].count - 1)
        if upperBound >= 0 { for index in 0...upperBound { rows[cursorRow][index] = " " } }
        trimTrailingSpaces(on: cursorRow)
    }

    mutating func renderedText() -> String {
        let trimmedLines = rows.map { row in String(row).replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression) }
        guard let firstNonEmptyIndex = trimmedLines.firstIndex(where: { !$0.isEmpty }) else { return "" }
        guard let lastNonEmptyIndex = trimmedLines.lastIndex(where: { !$0.isEmpty }) else { return "" }
        return trimmedLines[firstNonEmptyIndex...lastNonEmptyIndex].joined(separator: "\n")
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
