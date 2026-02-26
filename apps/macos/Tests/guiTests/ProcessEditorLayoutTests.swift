import AppKit
import Testing

@testable import gui

@MainActor @Suite struct ProcessEditorLayoutTests {
    /// The process row (name + command + remove button) must stretch to fill the editor's full width.
    /// When the editor is given a 600pt-wide container, the process row should match that width,
    /// not shrink to its intrinsic content size and float centered.
    @Test func processRowFillsContainerWidth() {
        let editor = ProcessEditor()

        // Simulate what formSectionCard does: place the container in a parent with a fixed width.
        let parent = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        parent.addSubview(editor.container)
        editor.container.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            editor.container.leadingAnchor.constraint(equalTo: parent.leadingAnchor),
            editor.container.trailingAnchor.constraint(equalTo: parent.trailingAnchor),
            editor.container.topAnchor.constraint(equalTo: parent.topAnchor),
        ])

        parent.layoutSubtreeIfNeeded()

        // The editor container should be 600pt wide (matches parent).
        #expect(editor.container.frame.width == 600, "Editor container should fill parent width")

        // Find the first process row — it's a horizontal stack inside the rowsStack.
        // The rowsStack is the second arranged subview of editor.container (after the header).
        let rowsStack = editor.container.arrangedSubviews.last!
        #expect(rowsStack.frame.width == 600, "Rows stack should fill container width, got \(rowsStack.frame.width)")

        // The process row inside rowsStack should also be 600pt wide.
        guard let processRow = rowsStack.subviews.first(where: { $0 is NSStackView }) as? NSStackView else {
            Issue.record("No process row found in rowsStack")
            return
        }
        #expect(processRow.frame.width == 600, "Process row should fill rows stack width, got \(processRow.frame.width)")
    }

    /// The status check row must include a visible command field (not compressed to zero).
    @Test func statusCheckRowShowsCommandField() {
        let editor = ProcessEditor()

        let parent = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        parent.addSubview(editor.container)
        editor.container.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            editor.container.leadingAnchor.constraint(equalTo: parent.leadingAnchor),
            editor.container.trailingAnchor.constraint(equalTo: parent.trailingAnchor),
            editor.container.topAnchor.constraint(equalTo: parent.topAnchor),
        ])

        // Set a process with a status check.
        editor.setProcessesWithChecks(
            [.init(name: "server", command: "npm start")],
            statusChecks: [.init(process: "server", command: "curl localhost", interval: 10, timeout: 2)])

        parent.layoutSubtreeIfNeeded()

        // Walk the view tree to find text fields with placeholder "command" and font size 11 (status check command field).
        let checkCommandFields = findTextFields(
            in: editor.container, matching: { field in field.placeholderString == "command" && field.font?.pointSize == 11 })
        #expect(!checkCommandFields.isEmpty, "Should find at least one status check command field")

        if let commandField = checkCommandFields.first {
            #expect(commandField.frame.width >= 50, "Status check command field should have visible width, got \(commandField.frame.width)")
        }
    }

    private func findTextFields(in view: NSView, matching predicate: (NSTextField) -> Bool) -> [NSTextField] {
        var results: [NSTextField] = []
        if let field = view as? NSTextField, predicate(field) { results.append(field) }
        for subview in view.subviews { results.append(contentsOf: findTextFields(in: subview, matching: predicate)) }
        return results
    }
}
