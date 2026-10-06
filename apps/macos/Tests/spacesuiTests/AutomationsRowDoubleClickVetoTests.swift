import AppKit
import Testing

@testable import spacesui

@MainActor @Suite struct AutomationsRowDoubleClickVetoTests {
    private func mouseDown(at windowPoint: NSPoint, in window: NSWindow) throws -> NSEvent {
        try #require(
            NSEvent.mouseEvent(
                with: .leftMouseDown, location: windowPoint, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: 2, pressure: 1))
    }

    private func windowCenter(of view: NSView) -> NSPoint { view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil) }

    /// A row below the first sits at a non-zero origin in its stack. A veto that hands the row's own
    /// coordinates to `hitTest`, which expects the superview's, misses the control there and lets a
    /// double-click on the enable switch or next-run chip also open the editor.
    @Test func aDoubleClickOnARowsControlsNeverOpensTheEditorWhateverTheRowsPosition() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        let host = try #require(window.contentView)

        var rows: [AutomationsTableRowView] = []
        var controls: [(label: NSTextField, toggle: NSSwitch, chip: NSButton)] = []
        for index in 0..<2 {
            let row = AutomationsTableRowView {}
            row.translatesAutoresizingMaskIntoConstraints = true
            row.frame = NSRect(x: 0, y: 100 - index * 50, width: 500, height: 40)
            let label = NSTextField(labelWithString: "Nightly audit")
            label.frame = NSRect(x: 10, y: 10, width: 150, height: 20)
            let chip = NSButton(title: "in 2h", target: nil, action: nil)
            chip.frame = NSRect(x: 250, y: 8, width: 80, height: 24)
            let toggle = NSSwitch()
            toggle.frame = NSRect(x: 400, y: 8, width: 40, height: 24)
            row.addSubview(label)
            row.addSubview(chip)
            row.addSubview(toggle)
            host.addSubview(row)
            rows.append(row)
            controls.append((label, toggle, chip))
        }
        #expect(rows[1].frame.origin != .zero)

        for (row, control) in zip(rows, controls) {
            let recognizer = try #require(row.gestureRecognizers.compactMap { $0 as? NSClickGestureRecognizer }.first)

            let onToggle = try mouseDown(at: windowCenter(of: control.toggle), in: window)
            #expect(row.gestureRecognizer(recognizer, shouldAttemptToRecognizeWith: onToggle) == false, "the enable switch owns its double-click")

            let onChip = try mouseDown(at: windowCenter(of: control.chip), in: window)
            #expect(row.gestureRecognizer(recognizer, shouldAttemptToRecognizeWith: onChip) == false, "the next-run chip owns its double-click")

            let onLabel = try mouseDown(at: windowCenter(of: control.label), in: window)
            #expect(row.gestureRecognizer(recognizer, shouldAttemptToRecognizeWith: onLabel) == true, "a double-click on the label opens the editor")
        }
    }
}
