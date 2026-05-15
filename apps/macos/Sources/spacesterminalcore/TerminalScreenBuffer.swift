import Foundation

public enum TerminalANSIColor: Equatable {
    case palette(Int)
    case rgb(UInt8, UInt8, UInt8)
}

public enum TerminalUnderlineStyle: Equatable {
    case none
    case single
    case double
}

public enum TerminalCursorStyle: Equatable {
    case block
    case underline
    case bar
}

public struct TerminalTextStyle: Equatable {
    public var foreground: TerminalANSIColor?
    public var background: TerminalANSIColor?
    public var underlineColor: TerminalANSIColor?
    public var hyperlink: String?
    public var bold = false
    public var italic = false
    public var faint = false
    public var underlineStyle: TerminalUnderlineStyle = .none
    public var inverse = false
    public var hidden = false
    public var strikethrough = false

    public init(
        foreground: TerminalANSIColor? = nil, background: TerminalANSIColor? = nil, underlineColor: TerminalANSIColor? = nil,
        hyperlink: String? = nil, bold: Bool = false, italic: Bool = false, faint: Bool = false, underlineStyle: TerminalUnderlineStyle = .none,
        inverse: Bool = false, hidden: Bool = false, strikethrough: Bool = false
    ) {
        self.foreground = foreground
        self.background = background
        self.underlineColor = underlineColor
        self.hyperlink = hyperlink
        self.bold = bold
        self.italic = italic
        self.faint = faint
        self.underlineStyle = underlineStyle
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

public enum TerminalMouseTrackingMode: Equatable {
    case disabled
    case click
    case drag
    case move
}

public struct TerminalRenderedScreen: Equatable {
    public let rows: [[TerminalRenderedCell]]
    public let cursorRow: Int
    public let cursorColumn: Int
    public let cursorVisible: Bool
    public let cursorStyle: TerminalCursorStyle
    public let title: String?
    public let workingDirectory: String?
    public let usesAlternateScreen: Bool
    public let mouseTrackingMode: TerminalMouseTrackingMode
    public let usesSGRMouseEncoding: Bool
    public let usesAlternateScrollMode: Bool
    public let usesBracketedPasteMode: Bool
    public let usesFocusReporting: Bool

    public init(
        rows: [[TerminalRenderedCell]], cursorRow: Int, cursorColumn: Int, cursorVisible: Bool, cursorStyle: TerminalCursorStyle, title: String?,
        workingDirectory: String?, usesAlternateScreen: Bool, mouseTrackingMode: TerminalMouseTrackingMode, usesSGRMouseEncoding: Bool,
        usesAlternateScrollMode: Bool, usesBracketedPasteMode: Bool, usesFocusReporting: Bool
    ) {
        self.rows = rows
        self.cursorRow = cursorRow
        self.cursorColumn = cursorColumn
        self.cursorVisible = cursorVisible
        self.cursorStyle = cursorStyle
        self.title = title
        self.workingDirectory = workingDirectory
        self.usesAlternateScreen = usesAlternateScreen
        self.mouseTrackingMode = mouseTrackingMode
        self.usesSGRMouseEncoding = usesSGRMouseEncoding
        self.usesAlternateScrollMode = usesAlternateScrollMode
        self.usesBracketedPasteMode = usesBracketedPasteMode
        self.usesFocusReporting = usesFocusReporting
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
    private static let maxScrollbackRowCount = 10_000
    private static let defaultTabStopColumns = stride(from: 8, to: maxColumnCount, by: 8).map { $0 }

    private struct Cell: Equatable {
        var character: Character
        var style: TerminalTextStyle
    }

    private struct StoredScreenState {
        var rows: [[Cell]]
        var scrollbackRows: [[Cell]]
        var cursorRow: Int
        var cursorColumn: Int
        var savedCursorRow: Int
        var savedCursorColumn: Int
        var scrollRegionTop: Int
        var scrollRegionBottom: Int?
    }

    private var rows: [[Cell]] = [[]]
    private var scrollbackRows: [[Cell]] = []
    private var cursorRow = 0
    private var cursorColumn = 0
    private var savedCursorRow = 0
    private var savedCursorColumn = 0
    private var primaryScreenState: StoredScreenState?
    private var currentStyle = TerminalTextStyle()
    private var cursorVisible = true
    private var cursorStyle = TerminalCursorStyle.block
    private var currentTitle: String?
    private var currentWorkingDirectory: String?
    private var isUsingAlternateScreen = false
    private var mouseTrackingMode = TerminalMouseTrackingMode.disabled
    private var usesSGRMouseEncoding = false
    private var usesAlternateScrollMode = false
    private var usesBracketedPasteMode = false
    private var usesFocusReporting = false
    private var scrollRegionTop = 0
    private var scrollRegionBottom: Int?
    private var tabStops = Set(Self.defaultTabStopColumns)

    public init() {}

    public mutating func reset() {
        rows = [[]]
        scrollbackRows = []
        cursorRow = 0
        cursorColumn = 0
        savedCursorRow = 0
        savedCursorColumn = 0
        primaryScreenState = nil
        currentStyle = TerminalTextStyle()
        cursorVisible = true
        cursorStyle = .block
        currentTitle = nil
        currentWorkingDirectory = nil
        isUsingAlternateScreen = false
        mouseTrackingMode = .disabled
        usesSGRMouseEncoding = false
        usesAlternateScrollMode = false
        usesBracketedPasteMode = false
        usesFocusReporting = false
        scrollRegionTop = 0
        scrollRegionBottom = nil
        tabStops = Set(Self.defaultTabStopColumns)
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
                moveCursor(column: nextTabStop(after: cursorColumn))
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
            rows: renderedRows().map { $0.map { TerminalRenderedCell(character: $0.character, style: $0.style) } }, cursorRow: renderedCursorRow(),
            cursorColumn: cursorColumn, cursorVisible: cursorVisible, cursorStyle: cursorStyle, title: currentTitle,
            workingDirectory: currentWorkingDirectory, usesAlternateScreen: isUsingAlternateScreen, mouseTrackingMode: mouseTrackingMode,
            usesSGRMouseEncoding: usesSGRMouseEncoding, usesAlternateScrollMode: usesAlternateScrollMode,
            usesBracketedPasteMode: usesBracketedPasteMode, usesFocusReporting: usesFocusReporting)
    }

    private mutating func consumeEscapeSequence(_ scalars: [UnicodeScalar], startingAt index: Int) -> Int {
        let nextIndex = index + 1
        guard nextIndex < scalars.count else { return scalars.count }
        let introducer = scalars[nextIndex]
        switch introducer.value {
        case 0x5B: return consumeCSI(scalars, startingAt: nextIndex + 1)
        case 0x5D: return consumeOSC(scalars, startingAt: nextIndex + 1)
        case 0x48:
            setTabStop(at: cursorColumn)
            return nextIndex + 1
        case 0x4D:
            reverseIndex()
            return nextIndex + 1
        case 0x63:
            reset()
            return nextIndex + 1
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
        while current < scalars.count, (0x30...0x3F).contains(scalars[current].value) {
            parameterBuffer.unicodeScalars.append(scalars[current])
            current += 1
        }
        var intermediateBuffer = ""
        while current < scalars.count, (0x20...0x2F).contains(scalars[current].value) {
            intermediateBuffer.unicodeScalars.append(scalars[current])
            current += 1
        }
        guard current < scalars.count else { return current }
        let scalar = scalars[current]
        if scalar.value >= 0x40 && scalar.value <= 0x7E {
            applyCSI(final: scalar, parameters: parameterBuffer, intermediate: intermediateBuffer)
            return current + 1
        }
        return current
    }

    private mutating func consumeOSC(_ scalars: [UnicodeScalar], startingAt index: Int) -> Int {
        var current = index
        var oscContent = ""
        while current < scalars.count {
            let scalar = scalars[current]
            if scalar.value == 0x07 {
                applyOSC(oscContent)
                return current + 1
            }
            if scalar.value == 0x1B, current + 1 < scalars.count, scalars[current + 1].value == 0x5C {
                applyOSC(oscContent)
                return current + 2
            }
            oscContent.unicodeScalars.append(scalar)
            current += 1
        }
        return current
    }

    private mutating func applyOSC(_ content: String) {
        let components = content.split(separator: ";", maxSplits: 2, omittingEmptySubsequences: false)
        guard let command = components.first else { return }
        switch command {
        case "0", "1", "2":
            guard components.count >= 2 else {
                currentTitle = nil
                return
            }
            let title = String(components.last ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            currentTitle = title.isEmpty ? nil : title
        case "7":
            guard components.count >= 2 else {
                currentWorkingDirectory = nil
                return
            }
            let payload = String(components.last ?? "")
            guard let url = URL(string: payload), url.isFileURL else {
                currentWorkingDirectory = nil
                return
            }
            currentWorkingDirectory = url.path.isEmpty ? nil : url.path
        case "8":
            guard components.count == 3 else { return }
            let uri = String(components[2])
            currentStyle.hyperlink = uri.isEmpty ? nil : uri
        default: break
        }
    }

    private mutating func applyCSI(final: UnicodeScalar, parameters: String, intermediate: String) {
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
        case 0x49: moveCursor(column: nextTabStop(after: cursorColumn, count: max(values.first ?? 0, 1)))
        case 0x64:
            let row = max((values.first ?? 1) - 1, 0)
            moveCursor(row: row)
        case 0x5A: moveCursor(column: previousTabStop(before: cursorColumn, count: max(values.first ?? 0, 1)))
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
        case 0x67: clearTabStops(values.first ?? 0)
        case 0x6D: applySGR(values)
        case 0x68: applyMode(values, enabled: true)
        case 0x6C: applyMode(values, enabled: false)
        case 0x72: setScrollRegion(values)
        case 0x71: if intermediate == " " { applyCursorStyle(values.first ?? 0) }
        case 0x70: if intermediate == "!" { softReset() }
        default: break
        }
    }

    private mutating func applyCursorStyle(_ value: Int) {
        switch value {
        case 3, 4: cursorStyle = .underline
        case 5, 6: cursorStyle = .bar
        default: cursorStyle = .block
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
            case 4: currentStyle.underlineStyle = .single
            case 7: currentStyle.inverse = true
            case 8: currentStyle.hidden = true
            case 9: currentStyle.strikethrough = true
            case 22:
                currentStyle.bold = false
                currentStyle.faint = false
            case 21: currentStyle.underlineStyle = .double
            case 23: currentStyle.italic = false
            case 24: currentStyle.underlineStyle = .none
            case 27: currentStyle.inverse = false
            case 28: currentStyle.hidden = false
            case 29: currentStyle.strikethrough = false
            case 30...37: currentStyle.foreground = .palette(value - 30)
            case 39: currentStyle.foreground = nil
            case 40...47: currentStyle.background = .palette(value - 40)
            case 49: currentStyle.background = nil
            case 90...97: currentStyle.foreground = .palette(value - 90 + 8)
            case 100...107: currentStyle.background = .palette(value - 100 + 8)
            case 38: index = applyExtendedColor(params, startingAt: index, colorTarget: .foreground)
            case 48: index = applyExtendedColor(params, startingAt: index, colorTarget: .background)
            case 58: index = applyExtendedColor(params, startingAt: index, colorTarget: .underline)
            case 59: currentStyle.underlineColor = nil
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
            case 1048: if enabled { saveCursor() } else { restoreCursor() }
            case 1000: mouseTrackingMode = enabled ? .click : .disabled
            case 1002: mouseTrackingMode = enabled ? .drag : .disabled
            case 1003: mouseTrackingMode = enabled ? .move : .disabled
            case 1006: usesSGRMouseEncoding = enabled
            case 1007: usesAlternateScrollMode = enabled
            case 1004: usesFocusReporting = enabled
            case 2004: usesBracketedPasteMode = enabled
            default: break
            }
        }
    }

    private mutating func setAlternateScreen(_ enabled: Bool) {
        if enabled {
            guard !isUsingAlternateScreen else { return }
            primaryScreenState = captureCurrentScreenState()
            resetCurrentScreenState()
            isUsingAlternateScreen = true
        } else {
            guard isUsingAlternateScreen else { return }
            if let primaryScreenState { restoreScreenState(primaryScreenState) } else { resetCurrentScreenState() }
            primaryScreenState = nil
            isUsingAlternateScreen = false
        }
    }

    private func captureCurrentScreenState() -> StoredScreenState {
        StoredScreenState(
            rows: rows, scrollbackRows: scrollbackRows, cursorRow: cursorRow, cursorColumn: cursorColumn, savedCursorRow: savedCursorRow,
            savedCursorColumn: savedCursorColumn, scrollRegionTop: scrollRegionTop, scrollRegionBottom: scrollRegionBottom)
    }

    private mutating func restoreScreenState(_ state: StoredScreenState) {
        rows = state.rows
        scrollbackRows = state.scrollbackRows
        cursorRow = state.cursorRow
        cursorColumn = state.cursorColumn
        savedCursorRow = state.savedCursorRow
        savedCursorColumn = state.savedCursorColumn
        scrollRegionTop = state.scrollRegionTop
        scrollRegionBottom = state.scrollRegionBottom
    }

    private mutating func resetCurrentScreenState() {
        rows = [[]]
        scrollbackRows = []
        cursorRow = 0
        cursorColumn = 0
        savedCursorRow = 0
        savedCursorColumn = 0
        scrollRegionTop = 0
        scrollRegionBottom = nil
    }

    private enum ExtendedColorTarget {
        case foreground
        case background
        case underline
    }

    private mutating func applyExtendedColor(_ params: [Int], startingAt index: Int, colorTarget: ExtendedColorTarget) -> Int {
        let markerIndex = index + 1
        guard markerIndex < params.count else { return index }
        switch params[markerIndex] {
        case 5:
            let paletteIndex = markerIndex + 1
            guard paletteIndex < params.count else { return markerIndex }
            setColor(.palette(max(0, min(params[paletteIndex], 255))), target: colorTarget)
            return paletteIndex
        case 2:
            let blueIndex = markerIndex + 3
            guard blueIndex < params.count else { return markerIndex }
            let color = TerminalANSIColor.rgb(
                UInt8(clamping: params[markerIndex + 1]), UInt8(clamping: params[markerIndex + 2]), UInt8(clamping: params[blueIndex]))
            setColor(color, target: colorTarget)
            return blueIndex
        default: return markerIndex
        }
    }

    private mutating func setColor(_ color: TerminalANSIColor, target: ExtendedColorTarget) {
        switch target {
        case .foreground: currentStyle.foreground = color
        case .background: currentStyle.background = color
        case .underline: currentStyle.underlineColor = color
        }
    }

    private mutating func write(_ character: Character) {
        ensurePosition()
        rows[cursorRow][cursorColumn] = Cell(character: character, style: currentStyle)
        cursorColumn = min(cursorColumn + 1, Self.maxColumnCount - 1)
    }

    private mutating func newline() {
        if hasExplicitScrollRegion, cursorRow == activeScrollRegionBottom { scrollUpWithinRegion(1) } else { cursorRow += 1 }
        cursorColumn = 0
        ensurePosition()
    }

    private mutating func carriageReturn() { cursorColumn = 0 }

    private mutating func reverseIndex() {
        if hasExplicitScrollRegion, cursorRow == scrollRegionTop { scrollDownWithinRegion(1) } else { cursorRow = max(0, cursorRow - 1) }
        ensurePosition()
    }

    private mutating func moveCursor(row: Int? = nil, column: Int? = nil) {
        if let row { cursorRow = max(row, 0) }
        if let column { cursorColumn = max(min(column, Self.maxColumnCount - 1), 0) }
        ensurePosition()
    }

    private mutating func clearDisplay() {
        rows = [[]]
        cursorRow = 0
        cursorColumn = 0
        scrollRegionTop = 0
        scrollRegionBottom = nil
    }

    private mutating func softReset() {
        currentStyle = TerminalTextStyle()
        cursorVisible = true
        cursorStyle = .block
        mouseTrackingMode = .disabled
        usesSGRMouseEncoding = false
        usesAlternateScrollMode = false
        usesBracketedPasteMode = false
        usesFocusReporting = false
        scrollRegionTop = 0
        scrollRegionBottom = nil
        savedCursorRow = 0
        savedCursorColumn = 0
    }

    private mutating func saveCursor() {
        savedCursorRow = cursorRow
        savedCursorColumn = cursorColumn
    }

    private mutating func restoreCursor() { moveCursor(row: savedCursorRow, column: savedCursorColumn) }

    private mutating func setTabStop(at column: Int) {
        guard column >= 0, column < Self.maxColumnCount else { return }
        tabStops.insert(column)
    }

    private mutating func clearTabStops(_ mode: Int) {
        switch mode {
        case 0: tabStops.remove(cursorColumn)
        case 3: tabStops.removeAll()
        default: break
        }
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
        if !hasExplicitScrollRegion {
            rows.insert(contentsOf: repeatElement([], count: count), at: cursorRow)
            return
        }
        let lowerBound = max(scrollRegionTop, min(cursorRow, activeScrollRegionBottom))
        let upperBound = activeScrollRegionBottom
        let insertionCount = min(count, upperBound - lowerBound + 1)
        guard insertionCount > 0 else { return }
        ensureRowExists(upperBound)
        rows.insert(contentsOf: repeatElement([], count: insertionCount), at: lowerBound)
        rows.removeSubrange((upperBound + 1)...(upperBound + insertionCount))
    }

    private mutating func deleteLines(_ count: Int) {
        guard count > 0 else { return }
        if !hasExplicitScrollRegion {
            ensureRowExists(cursorRow)
            let deletionCount = min(count, rows.count - cursorRow)
            guard deletionCount > 0 else { return }
            rows.removeSubrange(cursorRow..<(cursorRow + deletionCount))
            cursorRow = min(cursorRow, max(rows.count - 1, 0))
            cursorColumn = min(cursorColumn, max(rows[cursorRow].count - 1, 0))
            return
        }
        let lowerBound = max(scrollRegionTop, min(cursorRow, activeScrollRegionBottom))
        let upperBound = activeScrollRegionBottom
        guard lowerBound <= upperBound else { return }
        ensureRowExists(upperBound)
        let deletionCount = min(count, upperBound - lowerBound + 1)
        rows.removeSubrange(lowerBound..<(lowerBound + deletionCount))
        rows.insert(contentsOf: repeatElement([], count: deletionCount), at: upperBound - deletionCount + 1)
        cursorRow = min(cursorRow, max(rows.count - 1, 0))
        cursorColumn = min(cursorColumn, max(rows[cursorRow].count - 1, 0))
    }

    private mutating func scrollUp(_ count: Int) {
        guard count > 0, !rows.isEmpty else { return }
        let amount = min(count, rows.count)
        appendToScrollback(rows.prefix(amount))
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

    private mutating func setScrollRegion(_ values: [Int]) {
        if values.isEmpty || (values.count == 1 && values[0] == 0) {
            scrollRegionTop = 0
            scrollRegionBottom = nil
            moveCursor(row: 0, column: 0)
            return
        }

        let top = max((values.first ?? 1) - 1, 0)
        let requestedBottom = values.count > 1 && values[1] > 0 ? values[1] - 1 : top
        let bottom = max(requestedBottom, top)
        scrollRegionTop = top
        scrollRegionBottom = bottom
        ensureRowExists(bottom)
        moveCursor(row: 0, column: 0)
    }

    private var activeScrollRegionBottom: Int { max(scrollRegionTop, scrollRegionBottom ?? max(rows.count - 1, scrollRegionTop)) }

    private var hasExplicitScrollRegion: Bool { scrollRegionBottom != nil }

    private mutating func scrollUpWithinRegion(_ count: Int) {
        let top = scrollRegionTop
        let bottom = activeScrollRegionBottom
        guard count > 0, top <= bottom else { return }
        ensureRowExists(bottom)
        let amount = min(count, bottom - top + 1)
        if shouldAppendRegionScrollToScrollback() { appendToScrollback(rows[top..<(top + amount)]) }
        rows.removeSubrange(top..<(top + amount))
        rows.insert(contentsOf: repeatElement([], count: amount), at: bottom - amount + 1)
    }

    private mutating func scrollDownWithinRegion(_ count: Int) {
        let top = scrollRegionTop
        let bottom = activeScrollRegionBottom
        guard count > 0, top <= bottom else { return }
        ensureRowExists(bottom)
        let amount = min(count, bottom - top + 1)
        rows.insert(contentsOf: repeatElement([], count: amount), at: top)
        rows.removeSubrange((bottom + 1)...(bottom + amount))
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

    private func renderedRows() -> [[Cell]] { isUsingAlternateScreen ? rows : scrollbackRows + rows }

    private func renderedCursorRow() -> Int { isUsingAlternateScreen ? cursorRow : scrollbackRows.count + cursorRow }

    private func shouldAppendRegionScrollToScrollback() -> Bool { !isUsingAlternateScreen }

    private mutating func appendToScrollback<S: Sequence>(_ cells: S) where S.Element == [Cell] {
        guard !isUsingAlternateScreen else { return }
        scrollbackRows.append(contentsOf: cells)
        if scrollbackRows.count > Self.maxScrollbackRowCount { scrollbackRows.removeFirst(scrollbackRows.count - Self.maxScrollbackRowCount) }
    }

    private mutating func trimTrailingSpaces(on row: Int) {
        guard rows.indices.contains(row) else { return }
        while rows[row].last?.character == " " { rows[row].removeLast() }
    }

    private func nextTabStop(after column: Int, count: Int = 1) -> Int {
        var currentColumn = column
        var remaining = max(count, 1)
        while remaining > 0 {
            if let next = tabStops.sorted().first(where: { $0 > currentColumn }) {
                currentColumn = next
            } else {
                currentColumn = min(Self.maxColumnCount - 1, currentColumn + 1)
            }
            remaining -= 1
        }
        return currentColumn
    }

    private func previousTabStop(before column: Int, count: Int = 1) -> Int {
        var currentColumn = column
        var remaining = max(count, 1)
        while remaining > 0 {
            if let previous = tabStops.sorted().last(where: { $0 < currentColumn }) { currentColumn = previous } else { currentColumn = 0 }
            remaining -= 1
        }
        return currentColumn
    }
}
