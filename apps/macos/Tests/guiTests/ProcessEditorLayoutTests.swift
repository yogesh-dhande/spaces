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

    // Tests currentProcesses returns the templates that were set via setProcesses.
    @Test func currentProcessesReturnsSetProcesses() {
        let editor = ProcessEditor()
        editor.setProcesses([.init(name: "server", command: "npm start")])
        let processes = editor.currentProcesses()
        #expect(processes.count == 1)
        #expect(processes[0].name == "server")
        #expect(processes[0].command == "npm start")
    }

    // Tests currentProcesses filters out rows that have an empty command field.
    @Test func currentProcessesFiltersRowsWithEmptyCommand() {
        let editor = ProcessEditor()
        // Editor starts with one empty row; no command so nothing is returned.
        let processes = editor.currentProcesses()
        #expect(processes.isEmpty)
    }

    // Tests currentProcesses preserves an empty name so save-time validation can reject it explicitly.
    @Test func currentProcessesPreservesEmptyNameForValidation() {
        let editor = ProcessEditor()
        editor.setProcesses([.init(name: nil, command: "echo hello")])
        let processes = editor.currentProcesses()
        #expect(processes.count == 1)
        #expect(processes[0].name == "")
    }

    // Tests currentStatusChecks returns checks associated with a named process.
    @Test func currentStatusChecksReturnsChecksForNamedProcess() {
        let editor = ProcessEditor()
        editor.setProcessesWithChecks(
            [.init(name: "api", command: "run api")], statusChecks: [.init(process: "api", command: "curl localhost", interval: 30, timeout: 5)])
        let checks = editor.currentStatusChecks()
        #expect(checks.count == 1)
        #expect(checks[0].process == "api")
        #expect(checks[0].command == "curl localhost")
    }

    // Tests currentStatusChecks skips process rows that have no name.
    @Test func currentStatusChecksSkipsUnnamedProcessRows() {
        let editor = ProcessEditor()
        editor.setProcesses([.init(name: nil, command: "run api")])
        let checks = editor.currentStatusChecks()
        #expect(checks.isEmpty)
    }

    // Tests processNames returns a sorted, deduplicated list of non-empty process names.
    @Test func processNamesReturnsSortedUniqueNames() {
        let editor = ProcessEditor()
        editor.setProcesses([.init(name: "zebra", command: "run z"), .init(name: "apple", command: "run a"), .init(name: "zebra", command: "run z2")])
        let names = editor.processNames()
        #expect(names == ["apple", "zebra"])
    }

    // Tests setProcesses with an empty array results in no current processes returned.
    @Test func setProcessesWithEmptyArrayProducesNoCurrentProcesses() {
        let editor = ProcessEditor()
        editor.setProcesses([.init(name: "server", command: "npm start")])
        editor.setProcesses([])
        let processes = editor.currentProcesses()
        #expect(processes.isEmpty)
    }

    // Tests the onDirty callback fires after setProcesses is called.
    @Test func onDirtyCallbackFiresAfterSetProcesses() {
        let editor = ProcessEditor()
        var callCount = 0
        editor.onDirty = { callCount += 1 }
        editor.setProcesses([.init(name: "server", command: "npm start")])
        #expect(callCount > 0)
    }

    // Tests that setProcessesWithChecks called a second time replaces existing rows and their status checks.
    @Test func setProcessesWithChecksReplacesExistingRowsOnSecondCall() {
        let editor = ProcessEditor()
        editor.setProcessesWithChecks(
            [.init(name: "api", command: "run api")], statusChecks: [.init(process: "api", command: "curl localhost", interval: 30, timeout: 5)])

        // Second call replaces the rows.
        editor.setProcessesWithChecks([.init(name: "server", command: "npm start")], statusChecks: [])

        let processes = editor.currentProcesses()
        #expect(processes.count == 1)
        #expect(processes[0].name == "server")
        // No status checks on the new row.
        let checks = editor.currentStatusChecks()
        #expect(checks.isEmpty)
    }

    // Tests that processNames returns an empty list when all process rows have empty names.
    @Test func processNamesReturnsEmptyWhenAllNamesAreEmpty() {
        let editor = ProcessEditor()
        editor.setProcesses([.init(name: nil, command: "run something")])
        let names = editor.processNames()
        #expect(names.isEmpty)
    }

    // Tests that the header add button triggers addRowFromButton, adding a new row to the rows stack.
    @Test func headerAddButtonAddsNewRow() {
        let editor = ProcessEditor()
        editor.setProcesses([.init(name: "server", command: "npm start")])
        let rowsStack = editor.container.arrangedSubviews.last as! NSStackView
        let initialCount = rowsStack.arrangedSubviews.count

        let header = editor.container.arrangedSubviews.first as! NSStackView
        let addButton = header.arrangedSubviews.last as! NSButton
        _ = (addButton.target as AnyObject?)?.perform(addButton.action)

        #expect(rowsStack.arrangedSubviews.count > initialCount, "Add button should append a new row to the rows stack")
    }

    // Tests that clicking the remove button on a process row triggers the onDirty callback (covers the onRemove closure).
    @Test func removeButtonTriggersDirtyCallback() {
        let editor = ProcessEditor()
        editor.setProcesses([.init(name: "server", command: "npm start")])
        var dirtyCount = 0
        editor.onDirty = { dirtyCount += 1 }

        let rowsStack = editor.container.arrangedSubviews.last as! NSStackView
        let processRow = rowsStack.arrangedSubviews.first as! NSStackView
        let removeButton = processRow.arrangedSubviews.last as! NSButton
        let prevCount = dirtyCount
        _ = (removeButton.target as AnyObject?)?.perform(removeButton.action)

        #expect(dirtyCount > prevCount, "Remove button should fire onDirty callback")
    }

    // Tests that the add-check button within a process row triggers addCheckRow, adding to the checks stack (covers lines 279-283).
    @Test func addCheckButtonAddsCheckRow() {
        let editor = ProcessEditor()
        editor.setProcesses([.init(name: "api", command: "run api")])

        let rowsStack = editor.container.arrangedSubviews.last as! NSStackView
        let checksSection = rowsStack.arrangedSubviews[1] as! NSStackView
        let innerStack = checksSection.arrangedSubviews[1] as! NSStackView
        let checksHeader = innerStack.arrangedSubviews[0] as! NSStackView
        let checksStack = innerStack.arrangedSubviews[2] as! NSStackView
        let addCheckButton = checksHeader.arrangedSubviews[2] as! NSButton

        let prevCount = checksStack.arrangedSubviews.count
        _ = (addCheckButton.target as AnyObject?)?.perform(addCheckButton.action)

        #expect(checksStack.arrangedSubviews.count > prevCount, "Add-check button should append a new check row")
    }
}
