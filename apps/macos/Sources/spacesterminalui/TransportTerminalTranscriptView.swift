import AppKit
import Carbon
import spacesterminalcore

@MainActor enum TransportTerminalTranscriptInput: Equatable {
    case text(String)
    case key(String)
}

@MainActor struct TransportTerminalTranscriptMouseInput: Equatable {
    let action: TerminalMouseAction
    let button: TerminalMouseButton
    let column: Int
    let row: Int
    let shift: Bool
    let option: Bool
    let control: Bool
}

@MainActor final class TransportTerminalTranscriptView: NSView {
    var terminalInputHandler: ((TransportTerminalTranscriptInput) -> Bool)?
    var terminalPasteHandler: (() -> Bool)?
    var terminalMouseHandler: ((TransportTerminalTranscriptMouseInput) -> Bool)?

    var font: NSFont = .monospacedSystemFont(ofSize: 12, weight: .regular) {
        didSet {
            syncCompositionProxy()
            invalidateLayoutAndDisplay()
        }
    }
    var textColor: NSColor = .textColor {
        didSet {
            syncCompositionProxy()
            needsDisplay = true
        }
    }
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
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var plainString = ""
    private var attributedString = NSAttributedString(string: "")
    private var markedTextValue = NSAttributedString(string: "")
    private var markedSelectionRange = NSRange(location: 0, length: 0)
    private var selectedRangeValue = NSRange(location: 0, length: 0)
    private var selectionAnchorLocation: Int?
    private var trackingAreaRef: NSTrackingArea?
    private let compositionProxy = TransportTerminalTranscriptCompositionProxy(frame: .zero)

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

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    override func keyDown(with event: NSEvent) {
        if handleImmediateTerminalEvent(event) { return }
        if compositionProxy.handle(event) { return }
        if handleTerminalEvent(event) { return }
        super.keyDown(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        if handleTerminalMouseEvent(event, action: .press, button: .left) { return }
        let location = window != nil ? convert(event.locationInWindow, from: nil) : event.locationInWindow
        let index = characterIndex(at: location)
        if event.clickCount >= 3 {
            let range = lineSelectionRange(at: index)
            selectionAnchorLocation = range.location
            setSelectedRange(range)
        } else if event.clickCount == 2 {
            let range = wordSelectionRange(at: index)
            selectionAnchorLocation = range.location
            setSelectedRange(range)
        } else if event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.shift), let anchor = selectionAnchorLocation {
            setSelectedRange(selectionRange(from: anchor, to: index))
        } else {
            selectionAnchorLocation = index
            setSelectedRange(NSRange(location: index, length: 0))
        }
        window?.makeFirstResponder(self)
    }

    override func mouseDragged(with event: NSEvent) {
        if handleTerminalMouseEvent(event, action: .move, button: .left) { return }
        guard let anchor = selectionAnchorLocation else { return }
        let location = window != nil ? convert(event.locationInWindow, from: nil) : event.locationInWindow
        setSelectedRange(selectionRange(from: anchor, to: characterIndex(at: location)))
    }

    override func rightMouseDown(with event: NSEvent) {
        if handleTerminalMouseEvent(event, action: .press, button: .right) { return }
        super.rightMouseDown(with: event)
    }

    override func rightMouseDragged(with event: NSEvent) {
        if handleTerminalMouseEvent(event, action: .move, button: .right) { return }
        super.rightMouseDragged(with: event)
    }

    override func rightMouseUp(with event: NSEvent) {
        if handleTerminalMouseEvent(event, action: .release, button: .right) { return }
        super.rightMouseUp(with: event)
    }

    override func otherMouseDown(with event: NSEvent) {
        if handleTerminalMouseEvent(event, action: .press, button: .middle) { return }
        super.otherMouseDown(with: event)
    }

    override func otherMouseDragged(with event: NSEvent) {
        if handleTerminalMouseEvent(event, action: .move, button: .middle) { return }
        super.otherMouseDragged(with: event)
    }

    override func otherMouseUp(with event: NSEvent) {
        if handleTerminalMouseEvent(event, action: .release, button: .middle) { return }
        super.otherMouseUp(with: event)
    }

    override func mouseMoved(with event: NSEvent) {
        if handleTerminalMouseEvent(event, action: .move, button: .none) { return }
        super.mouseMoved(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        if handleTerminalMouseEvent(event, action: .release, button: .left) { return }
        super.mouseUp(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        if event.scrollingDeltaY > 0, handleTerminalMouseEvent(event, action: .scrollUp, button: .none) { return }
        if event.scrollingDeltaY < 0, handleTerminalMouseEvent(event, action: .scrollDown, button: .none) { return }
        super.scrollWheel(with: event)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaRef { removeTrackingArea(trackingAreaRef) }
        let options: NSTrackingArea.Options = [.activeInKeyWindow, .mouseMoved, .inVisibleRect, .enabledDuringMouseDrag]
        let trackingArea = NSTrackingArea(rect: .zero, options: options, owner: self, userInfo: nil)
        addTrackingArea(trackingArea)
        trackingAreaRef = trackingArea
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

    func setAttributedString(_ string: NSAttributedString) { setRenderedOutput(plainText: string.string, attributedText: string) }

    func setRenderedOutput(plainText: String, attributedText: NSAttributedString) {
        self.plainString = plainText
        self.attributedString = attributedText
        clampSelection()
        invalidateLayoutAndDisplay()
    }

    func attributedStringValue() -> NSAttributedString { attributedString }
    func selectedRange() -> NSRange { selectedRangeValue }

    func setSelectedRange(_ range: NSRange) {
        selectedRangeValue = clampedRange(range)
        needsDisplay = true
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        let text = attributedText(from: string)
        markedTextValue = text
        let length = text.string.utf16.count
        let location = min(max(selectedRange.location, 0), length)
        let markedLength = min(max(selectedRange.length, 0), length - location)
        markedSelectionRange = NSRange(location: location, length: markedLength)
        invalidateLayoutAndDisplay()
    }

    func insertText(_ insertString: Any, replacementRange: NSRange) {
        let text = plainText(from: insertString)
        guard !text.isEmpty else { return }
        clearMarkedText()
        _ = terminalInputHandler?(.text(text))
    }

    func hasMarkedText() -> Bool { markedTextValue.length > 0 }
    func markedRange() -> NSRange {
        hasMarkedText() ? NSRange(location: plainString.utf16.count, length: markedTextValue.length) : NSRange(location: NSNotFound, length: 0)
    }
    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        let clamped = clampedRange(range)
        actualRange?.pointee = clamped
        guard clamped.length > 0, let stringRange = Range(clamped, in: plainString) else { return nil }
        return NSAttributedString(string: String(plainString[stringRange]), attributes: defaultTextAttributes)
    }

    func markedTextScreenRect() -> NSRect {
        guard let window else { return markedTextRect() }
        return window.convertToScreen(convert(markedTextRect(), to: nil))
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
        let lines = displayedPlainString.split(separator: "\n", omittingEmptySubsequences: false)
        let maxColumns = lines.map(\.count).max() ?? 0
        let width = horizontalInsets + CGFloat(maxColumns) * characterCellWidth
        let height = verticalInsets + CGFloat(max(lines.count, 1)) * lineHeight
        return NSSize(width: max(width, 1), height: max(height, 1))
    }

    private var displayedPlainString: String { plainString + markedTextValue.string }

    private var displayedAttributedString: NSAttributedString {
        guard hasMarkedText() else { return attributedString }
        let rendered = NSMutableAttributedString(attributedString: attributedString)
        let marked = NSMutableAttributedString(attributedString: markedTextValue)
        if marked.length > 0 {
            marked.addAttributes(
                [.font: font, .underlineStyle: NSUnderlineStyle.single.rawValue], range: NSRange(location: 0, length: marked.length))
        }
        rendered.append(marked)
        return rendered
    }

    private func commonInit() {
        addSubview(compositionProxy)
        compositionProxy.isHidden = true
        compositionProxy.commitTextHandler = { [weak self] text in self?.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
        }
        compositionProxy.markedTextHandler = { [weak self] text, selectedRange in
            self?.setMarkedText(text, selectedRange: selectedRange, replacementRange: NSRange(location: NSNotFound, length: 0))
        }
        compositionProxy.unmarkTextHandler = { [weak self] in self?.clearMarkedText() }
        syncCompositionProxy()
    }

    private func syncCompositionProxy() {
        compositionProxy.font = font
        compositionProxy.textColor = textColor
        compositionProxy.insertionPointColor = textColor
        compositionProxy.backgroundColor = .clear
        compositionProxy.frame = markedTextRect()
    }

    private func invalidateLayoutAndDisplay() {
        syncCompositionProxy()
        needsDisplay = true
        sizeToFit()
    }

    private func clearMarkedText() {
        markedTextValue = NSAttributedString(string: "")
        markedSelectionRange = NSRange(location: 0, length: 0)
        invalidateLayoutAndDisplay()
    }

    private func clampSelection() { selectedRangeValue = clampedRange(selectedRangeValue) }

    private func clampedRange(_ range: NSRange) -> NSRange {
        let length = plainString.utf16.count
        let location = min(max(range.location, 0), length)
        let clampedLength = min(max(range.length, 0), length - location)
        return NSRange(location: location, length: clampedLength)
    }

    private func drawContent() {
        let displayed = displayedAttributedString
        let fullRange = NSRange(location: 0, length: displayed.length)
        let lineRanges = displayed.string.lineRanges(for: fullRange)
        let origin = NSPoint(x: textContainerInset.width + lineFragmentPadding, y: textContainerInset.height)

        if lineRanges.isEmpty {
            displayed.draw(at: origin)
            return
        }

        for (index, lineRange) in lineRanges.enumerated() {
            let trimmedRange = displayed.string.rangeByTrimmingTrailingNewline(from: lineRange)
            let attributedLine = displayed.attributedSubstring(from: trimmedRange)
            attributedLine.draw(at: NSPoint(x: origin.x, y: origin.y + CGFloat(index) * lineHeight))
        }
    }

    private func drawSelectionHighlights() {
        guard selectedRangeValue.length > 0 else { return }
        NSColor.selectedTextBackgroundColor.withAlphaComponent(0.35).setFill()
        for rect in selectionRects(for: selectedRangeValue) { rect.fill() }
    }

    func characterIndex(at point: NSPoint) -> Int {
        let lines = plainString.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard !lines.isEmpty else { return 0 }

        let contentY = max(0, point.y - textContainerInset.height)
        let lineIndex = min(max(Int(floor(contentY / lineHeight)), 0), max(lines.count - 1, 0))
        let line = lines[lineIndex]
        let contentX = max(0, point.x - textContainerInset.width - lineFragmentPadding)
        let lineColumn = min(max(Int(floor(contentX / characterCellWidth)), 0), line.utf16.count)

        var location = 0
        for index in 0..<lineIndex { location += lines[index].utf16.count + 1 }
        return min(location + lineColumn, plainString.utf16.count)
    }

    private func selectionRange(from anchor: Int, to current: Int) -> NSRange {
        let lowerBound = min(anchor, current)
        let upperBound = max(anchor, current)
        return NSRange(location: lowerBound, length: upperBound - lowerBound)
    }

    private func wordSelectionRange(at index: Int) -> NSRange {
        guard !plainString.isEmpty else { return NSRange(location: 0, length: 0) }
        let clamped = min(max(index, 0), plainString.utf16.count)
        guard clamped < plainString.utf16.count else { return NSRange(location: plainString.utf16.count, length: 0) }
        guard let scalarIndex = String.Index(utf16Offset: clamped, in: plainString).samePosition(in: plainString.unicodeScalars) else {
            return NSRange(location: clamped, length: 0)
        }
        let scalars = plainString.unicodeScalars
        let target = scalars[scalarIndex]
        guard isWordScalar(target) else { return NSRange(location: clamped, length: 1) }

        var lower = scalarIndex
        while lower > scalars.startIndex {
            let previous = scalars.index(before: lower)
            guard isWordScalar(scalars[previous]) else { break }
            lower = previous
        }

        var upper = scalars.index(after: scalarIndex)
        while upper < scalars.endIndex, isWordScalar(scalars[upper]) { upper = scalars.index(after: upper) }

        let lowerOffset = lower.utf16Offset(in: plainString)
        let upperOffset = upper.utf16Offset(in: plainString)
        return NSRange(location: lowerOffset, length: upperOffset - lowerOffset)
    }

    private func lineSelectionRange(at index: Int) -> NSRange {
        let clamped = min(max(index, 0), plainString.utf16.count)
        let nsString = plainString as NSString
        if clamped >= plainString.utf16.count {
            let lineRange = nsString.lineRange(for: NSRange(location: max(plainString.utf16.count - 1, 0), length: 0))
            return plainString.rangeByTrimmingTrailingNewline(from: lineRange)
        }
        let lineRange = nsString.lineRange(for: NSRange(location: clamped, length: 0))
        return plainString.rangeByTrimmingTrailingNewline(from: lineRange)
    }

    private func isWordScalar(_ scalar: UnicodeScalar) -> Bool {
        CharacterSet.alphanumerics.contains(scalar) || scalar == "_" || scalar == "-" || scalar == "."
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

    private func caretRect() -> NSRect {
        let lines = displayedPlainString.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let lineIndex = max(lines.count - 1, 0)
        let lineLength = lines.last?.utf16.count ?? 0
        return NSRect(
            x: textContainerInset.width + lineFragmentPadding + CGFloat(lineLength) * characterCellWidth,
            y: textContainerInset.height + CGFloat(lineIndex) * lineHeight, width: max(characterCellWidth, 2), height: lineHeight)
    }

    private func markedTextRect() -> NSRect {
        let base = caretRect()
        return NSRect(x: base.minX, y: base.minY, width: CGFloat(max(markedTextValue.length, 1)) * characterCellWidth, height: lineHeight)
    }

    private func substring(in range: NSRange) -> String {
        guard let stringRange = Range(range, in: plainString) else { return "" }
        return String(plainString[stringRange])
    }

    private func handleImmediateTerminalEvent(_ event: NSEvent) -> Bool {
        guard let input = immediateTerminalInput(for: event) else { return false }
        return terminalInputHandler?(input) ?? false
    }

    private func immediateTerminalInput(for event: NSEvent) -> TransportTerminalTranscriptInput? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) { return nil }
        if let modifiedNamedKey = modifiedNamedKey(for: event, flags: flags) { return .key(modifiedNamedKey) }

        switch Int(event.keyCode) {
        case kVK_Return: return .key("enter")
        case kVK_ANSI_KeypadEnter: return .key("kpenter")
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
        case kVK_F13: return .key("f13")
        case kVK_F14: return .key("f14")
        case kVK_F15: return .key("f15")
        case kVK_F16: return .key("f16")
        case kVK_F17: return .key("f17")
        case kVK_F18: return .key("f18")
        case kVK_F19: return .key("f19")
        case kVK_F20: return .key("f20")
        case kVK_ANSI_KeypadClear: return .key("kpclear")
        case kVK_Help: return .key("insert")
        default: break
        }

        if flags.contains(.control), let scalar = event.charactersIgnoringModifiers?.unicodeScalars.only, scalar.properties.isAlphabetic {
            return .key("ctrl+\(String(scalar).lowercased())")
        }

        if flags.contains(.option) || flags.contains(.control) { return terminalInput(for: event) }
        return nil
    }

    private func terminalInput(for event: NSEvent) -> TransportTerminalTranscriptInput? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) { return nil }

        if let modifiedNamedKey = modifiedNamedKey(for: event, flags: flags) { return .key(modifiedNamedKey) }

        switch Int(event.keyCode) {
        case kVK_Return: return .key("enter")
        case kVK_ANSI_KeypadEnter: return .key("kpenter")
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
        case kVK_F13: return .key("f13")
        case kVK_F14: return .key("f14")
        case kVK_F15: return .key("f15")
        case kVK_F16: return .key("f16")
        case kVK_F17: return .key("f17")
        case kVK_F18: return .key("f18")
        case kVK_F19: return .key("f19")
        case kVK_F20: return .key("f20")
        case kVK_ANSI_KeypadClear: return .key("kpclear")
        case kVK_Help: return .key("insert")
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

    private func modifiedNamedKey(for event: NSEvent, flags: NSEvent.ModifierFlags) -> String? {
        let modifiers = keyModifiers(for: flags)
        guard !modifiers.isEmpty else { return nil }
        guard let keyName = namedKeyForModifiedSequence(keyCode: Int(event.keyCode), shift: flags.contains(.shift)) else { return nil }
        return (modifiers + [keyName]).joined(separator: "+")
    }

    private func keyModifiers(for flags: NSEvent.ModifierFlags) -> [String] {
        var parts: [String] = []
        if flags.contains(.shift) { parts.append("shift") }
        if flags.contains(.option) { parts.append("alt") }
        if flags.contains(.control) { parts.append("ctrl") }
        return parts
    }

    private func namedKeyForModifiedSequence(keyCode: Int, shift: Bool) -> String? {
        switch keyCode {
        case kVK_UpArrow: return "up"
        case kVK_DownArrow: return "down"
        case kVK_RightArrow: return "right"
        case kVK_LeftArrow: return "left"
        case kVK_Home: return "home"
        case kVK_End: return "end"
        case kVK_PageUp: return "pageup"
        case kVK_PageDown: return "pagedown"
        case kVK_ForwardDelete: return "forwarddelete"
        case kVK_Help: return "insert"
        case kVK_F1: return "f1"
        case kVK_F2: return "f2"
        case kVK_F3: return "f3"
        case kVK_F4: return "f4"
        case kVK_F5: return "f5"
        case kVK_F6: return "f6"
        case kVK_F7: return "f7"
        case kVK_F8: return "f8"
        case kVK_F9: return "f9"
        case kVK_F10: return "f10"
        case kVK_F11: return "f11"
        case kVK_F12: return "f12"
        case kVK_F13: return "f13"
        case kVK_F14: return "f14"
        case kVK_F15: return "f15"
        case kVK_F16: return "f16"
        case kVK_F17: return "f17"
        case kVK_F18: return "f18"
        case kVK_F19: return "f19"
        case kVK_F20: return "f20"
        default: return nil
        }
    }

    private func plainText(from string: Any) -> String {
        if let attributedString = string as? NSAttributedString { return attributedString.string }
        if let string = string as? String { return string }
        return "\(string)"
    }

    private func attributedText(from string: Any) -> NSAttributedString {
        if let attributedString = string as? NSAttributedString { return attributedString }
        return NSAttributedString(string: plainText(from: string), attributes: defaultTextAttributes)
    }

    private func handleTerminalMouseEvent(_ event: NSEvent, action: TerminalMouseAction, button: TerminalMouseButton) -> Bool {
        guard let input = terminalMouseInput(for: event, action: action, button: button) else { return false }
        return terminalMouseHandler?(input) ?? false
    }

    private func terminalMouseInput(for event: NSEvent, action: TerminalMouseAction, button: TerminalMouseButton)
        -> TransportTerminalTranscriptMouseInput?
    {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let location = convert(event.locationInWindow, from: nil)
        let column = max(1, Int(floor((location.x - textContainerInset.width - lineFragmentPadding) / characterCellWidth)) + 1)
        let row = max(1, Int(floor((location.y - textContainerInset.height) / lineHeight)) + 1)
        return TransportTerminalTranscriptMouseInput(
            action: action, button: button, column: column, row: row, shift: flags.contains(.shift), option: flags.contains(.option),
            control: flags.contains(.control))
    }
}

private final class TransportTerminalTranscriptCompositionProxy: NSTextView {
    var commitTextHandler: ((String) -> Void)?
    var markedTextHandler: ((NSAttributedString, NSRange) -> Void)?
    var unmarkTextHandler: (() -> Void)?
    private var didHandleInput = false

    override init(frame frameRect: NSRect) {
        let textStorage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        let textContainer = NSTextContainer(size: NSSize(width: 1, height: 1))
        textContainer.lineFragmentPadding = 0
        layoutManager.addTextContainer(textContainer)
        textStorage.addLayoutManager(layoutManager)
        super.init(frame: frameRect, textContainer: textContainer)
        isEditable = true
        isSelectable = false
        drawsBackground = false
        textContainerInset = .zero
        string = ""
    }

    required init?(coder: NSCoder) { nil }

    func handle(_ event: NSEvent) -> Bool {
        didHandleInput = false
        interpretKeyEvents([event])
        return didHandleInput
    }

    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        didHandleInput = true
        commitTextHandler?(plainText(from: insertString))
    }

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        didHandleInput = true
        markedTextHandler?(attributedText(from: string), selectedRange)
    }

    override func unmarkText() {
        didHandleInput = true
        unmarkTextHandler?()
    }

    private func plainText(from string: Any) -> String {
        if let attributedString = string as? NSAttributedString { return attributedString.string }
        if let string = string as? String { return string }
        return "\(string)"
    }

    private func attributedText(from string: Any) -> NSAttributedString {
        if let attributedString = string as? NSAttributedString { return attributedString }
        return NSAttributedString(string: plainText(from: string))
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
