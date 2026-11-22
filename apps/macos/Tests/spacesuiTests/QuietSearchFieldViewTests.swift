import AppKit
import Testing

@testable import spacesui

@MainActor @Suite struct QuietSearchFieldViewTests {
    private func host() -> (NSWindow, QuietSearchFieldView) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        let view = QuietSearchFieldView(placeholder: "Search")
        window.contentView?.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 20),
            view.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -20),
            view.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 20),
        ])
        window.contentView?.layoutSubtreeIfNeeded()
        return (window, view)
    }

    /// Where the first typed glyph lands, in field coordinates, versus the right edge of the magnifier.
    private func assertTypedTextClearsMagnifier(_ view: QuietSearchFieldView, sourceLocation: SourceLocation = #_sourceLocation) {
        let field = view.field
        let cell = field.cell as! NSSearchFieldCell
        let magnifierMaxX = cell.searchButtonRect(forBounds: field.bounds).maxX
        guard let editor = field.currentEditor() as? NSTextView, let container = editor.textContainer else {
            Issue.record("field is not editing", sourceLocation: sourceLocation)
            return
        }
        let glyphX = editor.textContainerOrigin.x + container.lineFragmentPadding
        let glyphMinX = field.convert(NSPoint(x: glyphX, y: 0), from: editor).x
        #expect(glyphMinX >= magnifierMaxX, "text starts at \(glyphMinX), magnifier ends at \(magnifierMaxX)", sourceLocation: sourceLocation)
    }

    private func clickEvent(in window: NSWindow, at point: NSPoint) -> NSEvent {
        NSEvent.mouseEvent(
            with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
            eventNumber: 1, clickCount: 1, pressure: 1)!
    }

    @Test func wrapperClickKeepsTypedTextRightOfTheMagnifier() {
        let (window, view) = host()
        view.mouseDown(with: clickEvent(in: window, at: .zero))
        view.field.currentEditor()?.insertText("fae")
        window.contentView?.layoutSubtreeIfNeeded()
        assertTypedTextClearsMagnifier(view)
    }

    @Test func selectTextKeepsTypedTextRightOfTheMagnifier() {
        let (window, view) = host()
        view.field.selectText(nil)
        view.field.currentEditor()?.insertText("fae")
        window.contentView?.layoutSubtreeIfNeeded()
        assertTypedTextClearsMagnifier(view)
    }

    /// A click inside the field reaches the cell through `edit(withFrame:...)`. Driving a real mouse-down
    /// blocks in AppKit's tracking loop, so the test calls the cell entry point the click uses.
    @Test func editingStartedByAClickKeepsTypedTextRightOfTheMagnifier() {
        let (window, view) = host()
        let field = view.field
        let editor = window.fieldEditor(true, for: field)!
        field.cell!.edit(withFrame: field.bounds, in: field, editor: editor, delegate: field, event: nil)
        editor.insertText("fae")
        window.contentView?.layoutSubtreeIfNeeded()
        assertTypedTextClearsMagnifier(view)
    }

    @Test func cancelButtonClearsTheField() {
        let (_, view) = host()
        view.field.stringValue = "fae"
        let cancel = (view.field.cell as! NSSearchFieldCell).cancelButtonCell!
        cancel.performClick(view.field)
        #expect(view.field.stringValue.isEmpty)
    }
}
