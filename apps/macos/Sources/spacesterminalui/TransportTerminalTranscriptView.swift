import AppKit
import Carbon

@MainActor enum TransportTerminalTranscriptInput: Equatable {
    case text(String)
    case key(String)
}

@MainActor final class TransportTerminalTranscriptView: NSView {
    var terminalInputHandler: ((TransportTerminalTranscriptInput) -> Bool)?
    var terminalPasteHandler: (() -> Bool)?

    var font: NSFont = .monospacedSystemFont(ofSize: 12, weight: .regular) { didSet { invalidateLayoutAndDisplay() } }

    var textColor: NSColor = .textColor { didSet { needsDisplay = true } }

    var backgroundColor: NSColor = .textBackgroundColor { didSet { needsDisplay = true } }

    var drawsBackground = true { didSet { needsDisplay = true } }

    var textContainerInset = NSSize(width: 8, height: 10) { didSet { invalidateLayoutAndDisplay() } }

    var lineFragmentPadding: CGFloat = 5 { didSet { invalidateLayoutAndDisplay() } }

    var minSize: NSSize = .zero
    var maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)

    var string: String {
        get { plainString }
        set { setAttributedString(NSAttributedString(string: newValue, attributes: defaultTextAttributes)) }
    }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { drawsBackground }

    private var plainString = ""
    private var attributedString = NSAttributedString(string: "")
    private var selectedRangeValue = NSRange(location: 0, length: 0)

    private var defaultTextAttributes: [NSAttributedString.Key: Any] { [.font: font, .foregroundColor: textColor] }

    private var characterCellWidth: CGFloat { max(1, ("W" as NSString).size(withAttributes: [.font: font]).width) }

    private var lineHeight: CGFloat {
        let layoutManager = NSLayoutManager()
        let textStorage = NSTextStorage(string: "W", attributes: [.font: font])
        let textContainer = NSTextContainer(size: NSSize(width: 10_000, height: 10_000))
        textContainer.lineFragmentPadding = 0
        layoutManager.addTextContainer(textContainer)
        textStorage.addLayoutManager(layoutManager)
        return max(1, layoutManager.defaultLineHeight(for: font))
    }

    override func keyDown(with event: NSEvent) {
        guard handleTerminalEvent(event) else {
            super.keyDown(with: event)
            return
        }
    }

    @objc func paste(_ sender: Any?) {
        guard terminalPasteHandler?() != true else { return }
        NSSound.beep()
    }

    @objc func copy(_ sender: Any?) {
        guard selectedRangeValue.length > 0 else { return }
        let copied = substring(in: selectedRangeValue)
        guard !copied.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(copied, forType: .string)
    }

    override func selectAll(_ sender: Any?) { setSelectedRange(NSRange(location: 0, length: plainString.utf16.count)) }

    override func draw(_ dirtyRect: NSRect) {
        if drawsBackground {
            backgroundColor.setFill()
            dirtyRect.fill()
        }

        drawSelectionHighlights()
        drawContent()
    }

    func setAttributedString(_ string: NSAttributedString) {
        attributedString = string
        plainString = string.string
        clampSelection()
        invalidateLayoutAndDisplay()
    }

    func selectedRange() -> NSRange { selectedRangeValue }

    func setSelectedRange(_ range: NSRange) {
        selectedRangeValue = clampedRange(range)
        needsDisplay = true
    }

    func sizeToFit() {
        var frame = frame
        frame.size = NSSize(
            width: min(max(contentSize.width, minSize.width), maxSize.width), height: min(max(contentSize.height, minSize.height), maxSize.height))
        self.frame = frame
    }

    func scrollRangeToVisible(_ range: NSRange) {
        let rect = boundingRect(for: clampedRange(range))
        scrollToVisible(rect)
    }

    @discardableResult func handleTerminalEvent(_ event: NSEvent) -> Bool {
        guard let input = terminalInput(for: event) else { return false }
        return terminalInputHandler?(input) ?? false
    }

    var horizontalInsets: CGFloat { textContainerInset.width * 2 + lineFragmentPadding * 2 }
    var verticalInsets: CGFloat { textContainerInset.height * 2 }
    var measuredLineHeight: CGFloat { lineHeight }
    var measuredCellWidth: CGFloat { characterCellWidth }

    private var contentSize: NSSize {
        let lines = plainString.split(separator: "\n", omittingEmptySubsequences: false)
        let maxColumns = lines.map(\.count).max() ?? 0
        let width = horizontalInsets + CGFloat(maxColumns) * characterCellWidth
        let height = verticalInsets + CGFloat(max(lines.count, 1)) * lineHeight
        return NSSize(width: max(width, 1), height: max(height, 1))
    }

    private func invalidateLayoutAndDisplay() {
        needsDisplay = true
        sizeToFit()
    }

    private func clampSelection() { selectedRangeValue = clampedRange(selectedRangeValue) }

    private func clampedRange(_ range: NSRange) -> NSRange {
        let length = plainString.utf16.count
        let location = min(max(range.location, 0), length)
        let clampedLength = min(max(range.length, 0), length - location)
        return NSRange(location: location, length: clampedLength)
    }

    private func drawContent() {
        let fullRange = NSRange(location: 0, length: attributedString.length)
        let lineRanges = attributedString.string.lineRanges(for: fullRange)
        let origin = NSPoint(x: textContainerInset.width + lineFragmentPadding, y: textContainerInset.height)

        if lineRanges.isEmpty {
            attributedString.draw(at: origin)
            return
        }

        for (index, lineRange) in lineRanges.enumerated() {
            let trimmedRange = attributedString.string.rangeByTrimmingTrailingNewline(from: lineRange)
            let attributedLine = attributedString.attributedSubstring(from: trimmedRange)
            attributedLine.draw(at: NSPoint(x: origin.x, y: origin.y + CGFloat(index) * lineHeight))
        }
    }

    private func drawSelectionHighlights() {
        guard selectedRangeValue.length > 0 else { return }
        NSColor.selectedTextBackgroundColor.withAlphaComponent(0.35).setFill()
        for rect in selectionRects(for: selectedRangeValue) { rect.fill() }
    }

    private func selectionRects(for range: NSRange) -> [NSRect] {
        let lines = plainString.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard !lines.isEmpty else { return [] }

        var rects: [NSRect] = []
        var utf16Offset = 0
        for (index, line) in lines.enumerated() {
            let lineUTF16Length = line.utf16.count
            let lineStart = utf16Offset
            let lineEnd = lineStart + lineUTF16Length
            let selectionStart = max(range.location, lineStart)
            let selectionEnd = min(range.location + range.length, lineEnd)
            if selectionStart < selectionEnd {
                let startColumn = selectionStart - lineStart
                let endColumn = selectionEnd - lineStart
                let rect = NSRect(
                    x: textContainerInset.width + lineFragmentPadding + CGFloat(startColumn) * characterCellWidth,
                    y: textContainerInset.height + CGFloat(index) * lineHeight, width: CGFloat(max(endColumn - startColumn, 1)) * characterCellWidth,
                    height: lineHeight)
                rects.append(rect)
            }
            utf16Offset = lineEnd + 1
        }
        return rects
    }

    private func boundingRect(for range: NSRange) -> NSRect {
        let rects = selectionRects(for: range)
        if let union = rects.reduce(nil, { partialResult, rect in partialResult?.union(rect) ?? rect }) {
            return union.insetBy(dx: -lineFragmentPadding, dy: -2)
        }
        if range.location >= plainString.utf16.count {
            return NSRect(x: 0, y: max(0, bounds.height - lineHeight - textContainerInset.height), width: bounds.width, height: lineHeight + 4)
        }
        return NSRect(x: 0, y: 0, width: bounds.width, height: lineHeight + 4)
    }

    private func substring(in range: NSRange) -> String {
        guard let stringRange = Range(range, in: plainString) else { return "" }
        return String(plainString[stringRange])
    }

    private func terminalInput(for event: NSEvent) -> TransportTerminalTranscriptInput? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) { return nil }

        switch Int(event.keyCode) {
        case kVK_Return, kVK_ANSI_KeypadEnter: return .key("enter")
        case kVK_Tab: return .key(flags.contains(.shift) ? "backtab" : "tab")
        case kVK_Delete: return .key("backspace")
        case kVK_ForwardDelete: return .key("forwarddelete")
        case kVK_Escape: return .key("esc")
        case kVK_UpArrow: return .key("up")
        case kVK_DownArrow: return .key("down")
        case kVK_LeftArrow: return .key("left")
        case kVK_RightArrow: return .key("right")
        case kVK_Home: return .key("home")
        case kVK_End: return .key("end")
        case kVK_PageUp: return .key("pageup")
        case kVK_PageDown: return .key("pagedown")
        case kVK_F1: return .key("f1")
        case kVK_F2: return .key("f2")
        case kVK_F3: return .key("f3")
        case kVK_F4: return .key("f4")
        case kVK_F5: return .key("f5")
        case kVK_F6: return .key("f6")
        case kVK_F7: return .key("f7")
        case kVK_F8: return .key("f8")
        case kVK_F9: return .key("f9")
        case kVK_F10: return .key("f10")
        case kVK_F11: return .key("f11")
        case kVK_F12: return .key("f12")
        default: break
        }

        if flags.contains(.control), let scalar = event.charactersIgnoringModifiers?.unicodeScalars.only, scalar.properties.isAlphabetic {
            return .key("ctrl+\(String(scalar).lowercased())")
        }

        guard !flags.contains(.control) else { return nil }
        guard let text = event.characters, !text.isEmpty else { return nil }
        guard text.unicodeScalars.contains(where: { !CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return .text(text)
    }
}

extension String {
    fileprivate func lineRanges(for range: NSRange) -> [NSRange] {
        let utf16View = utf16
        var ranges: [NSRange] = []
        var location = range.location
        let upperBound = range.location + range.length
        while location < upperBound {
            let lineRange = (self as NSString).lineRange(for: NSRange(location: location, length: 0))
            ranges.append(lineRange)
            location = lineRange.location + lineRange.length
        }
        if ranges.isEmpty, !utf16View.isEmpty { ranges.append((self as NSString).lineRange(for: NSRange(location: 0, length: 0))) }
        return ranges
    }

    fileprivate func rangeByTrimmingTrailingNewline(from range: NSRange) -> NSRange {
        guard range.length > 0 else { return range }
        let nsString = self as NSString
        var trimmed = range
        while trimmed.length > 0 {
            let lastCharacter = nsString.substring(with: NSRange(location: trimmed.location + trimmed.length - 1, length: 1))
            if lastCharacter == "\n" || lastCharacter == "\r" { trimmed.length -= 1 } else { break }
        }
        return trimmed
    }
}

extension Collection { fileprivate var only: Element? { count == 1 ? first : nil } }
