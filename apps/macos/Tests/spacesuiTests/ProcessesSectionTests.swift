import AppKit
import Testing
import workspacecore

@testable import spacesui

@MainActor @Suite struct ProcessesSectionTests {
    // MARK: Initial rendering

    @Test func rendersOneRowPerProcess() {
        let section = ProcessesSection(processes: [
            ProcessTemplate(name: "api", command: "bun run dev", onExit: .none),
            ProcessTemplate(name: "worker", command: "bun run worker", onExit: .restart),
        ])
        #expect(section.rowCount == 2)
    }

    @Test func rendersEmptySectionWhenGivenNoProcesses() {
        let section = ProcessesSection()
        #expect(section.rowCount == 0)
    }

    @Test func supplementalRuntimeRowsRenderAlongsideConfiguredProcesses() {
        let section = ProcessesSection(processes: [ProcessTemplate(name: "api", command: "bun run dev")])
        section.supplementalRows = [
            .init(id: "window-1", label: "shell-1", detail: "~/projects/frontend-demo", shortcut: "⌘2", status: .idle, onFocus: nil)
        ]

        #expect(section.rowCount == 2)
    }

    @Test func supplementalRuntimeRowsRenderRunningStatusDot() {
        let section = ProcessesSection()
        section.supplementalRows = [
            .init(id: "window-1", label: "shell-1", detail: "~/projects/frontend-demo", shortcut: "⌘2", status: .running, onFocus: nil)
        ]

        #expect(section.row(at: 0)?.statusDotForTesting?.kind == .running)
    }

    @Test func collapsedIsTheDefaultState() {
        let section = ProcessesSection(processes: [ProcessTemplate(name: "api", command: "bun run dev")])
        #expect(section.isEditing(at: 0) == false)
    }

    // MARK: Row lifecycle

    @Test func addAppendsBlankProcessInEditingState() {
        let section = ProcessesSection(processes: [ProcessTemplate(name: "api", command: "bun run dev")])
        var commitCount = 0
        section.onCommit = { _ in commitCount += 1 }

        // Exercise the same path the + add button triggers.
        section.performAdd()

        #expect(section.rowCount == 2)
        #expect(section.isEditing(at: 1))
        #expect(commitCount == 0, "+add must defer commit until Save so the orchestrator does not validate an empty placeholder")
    }

    @Test func cancelOnANewlyAddedRowDropsTheDraftWithoutCommitting() {
        let section = ProcessesSection(processes: [ProcessTemplate(name: "api", command: "bun run dev")])
        var commitCount = 0
        section.onCommit = { _ in commitCount += 1 }

        section.performAdd()
        section.row(at: 1)?.onCancel?()

        #expect(section.rowCount == 1, "Cancelling a never-saved draft should drop the row")
        #expect(commitCount == 0)
    }

    @Test func reloadReplacesRows() {
        let section = ProcessesSection(processes: [ProcessTemplate(name: "api", command: "bun run dev")])
        section.reload(processes: [
            ProcessTemplate(name: "worker-1", command: "bun run worker-1"), ProcessTemplate(name: "worker-2", command: "bun run worker-2"),
            ProcessTemplate(name: "worker-3", command: "bun run worker-3"),
        ])
        #expect(section.rowCount == 3)
    }

    @Test func reloadPreservesEditingStateAcrossSameProcessList() {
        let process = ProcessTemplate(name: "api", command: "bun run dev")
        let section = ProcessesSection(processes: [process])
        // Simulate what the host would do when status updates arrive.
        section.row(at: 0)?.enterEditing(prefill: nil, animated: false)
        #expect(section.isEditing(at: 0))

        section.reload(processes: [process])
        #expect(section.isEditing(at: 0), "Editing state should survive a no-op reload")
    }

    @Test func replaceClearsDraftStateBeforeLoadingImportedProcesses() {
        let section = ProcessesSection(processes: [ProcessTemplate(name: "api", command: "bun run dev")])
        section.performAdd()
        #expect(section.isEditing(at: 1))

        section.replace(processes: [ProcessTemplate(name: "imported", command: "npm run imported")])

        var presentedFor: ProcessTemplate?
        section.presentRemoveConfirmation = { process, decide in
            presentedFor = process
            decide(false)
        }
        section.row(at: 0)?.triggerRemove()

        #expect(section.rowCount == 1)
        #expect(section.currentProcesses.map(\.name) == ["imported"])
        #expect(presentedFor?.name == "imported")
        #expect(!section.isEditing(at: 0))
    }

    @Test func browserSessionReplaceClearsDraftStateBeforeLoadingImportedSessions() {
        let section = BrowserSessionsSection(sessions: [BrowserSession(name: "docs", url: "https://example.com/docs")])
        section.performAdd()
        #expect(section.isEditing(at: 1))

        section.replace(sessions: [BrowserSession(name: "imported", url: "https://example.com/imported")])

        var presentedFor: BrowserSession?
        section.presentRemoveConfirmation = { session, decide in
            presentedFor = session
            decide(false)
        }
        section.browserRow(at: 0)?.onRemove?()

        #expect(section.rowCount == 1)
        #expect(section.currentSessions.map(\.name) == ["imported"])
        #expect(presentedFor?.name == "imported")
        #expect(!section.isEditing(at: 0))
    }

    // MARK: Status + shortcut maps

    @Test func statusByNameDrivesTheStatusDot() {
        let section = ProcessesSection(processes: [ProcessTemplate(name: "api", command: "bun run dev")])
        section.statusByName = ["api": .running]
        let dot = section.row(at: 0)?.statusDotForTesting
        #expect(dot?.kind == .running)
    }

    @Test func shortcutsByNameAssignsChipText() {
        let section = ProcessesSection(processes: [ProcessTemplate(name: "api", command: "bun run dev")])
        section.shortcutsByName = ["api": "⌘3"]
        let hasChip = section.row(at: 0)?.collapsedHasShortcutChip ?? false
        #expect(hasChip, "Setting shortcutsByName should rebuild rows and display the chip")
    }

    @Test func shortcutChipsAlignAcrossProcessAndBrowserRows() {
        let processRow = ProcessRowView(process: ProcessTemplate(name: "api", command: "bun run dev"), shortcut: "⌘1", status: .running)
        let browserRow = BrowserSessionRowView(session: BrowserSession(name: "docs", url: "https://example.com"), shortcut: "⌘2")

        let stack = NSStackView(views: [processRow, browserRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false

        let host = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 180))
        host.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: host.leadingAnchor), stack.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            stack.topAnchor.constraint(equalTo: host.topAnchor),
        ])
        processRow.widthAnchor.constraint(equalToConstant: 640).isActive = true
        browserRow.widthAnchor.constraint(equalToConstant: 640).isActive = true
        host.layoutSubtreeIfNeeded()

        let processX = processRow.shortcutChipMinXForTesting(shortcut: "⌘1")
        let browserX = browserRow.shortcutChipMinXForTesting(shortcut: "⌘2")

        #expect(processX != nil)
        #expect(browserX != nil)
        #expect(abs((processX ?? 0) - (browserX ?? 0)) < 0.5)
    }

    @Test func rowHoverVisibilityTogglesActionButtons() {
        let row = ProcessRowView(process: ProcessTemplate(name: "api", command: "bun run dev"), shortcut: nil, status: .running)

        #expect(row.areActionButtonsVisible == false)
        #expect(row.actionButtonAlphaValuesForTesting == [0, 0, 0, 0, 0])

        row.setActionButtonsVisible(true, animated: false)

        #expect(row.areActionButtonsVisible)
        #expect(row.actionButtonAlphaValuesForTesting == [1, 1, 1, 1, 1])
    }

    @Test func runningRowsShowStopAndRestartBeforeEditAndDelete() {
        let row = ProcessRowView(process: ProcessTemplate(name: "api", command: "bun run dev"), shortcut: nil, status: .running)
        #expect(row.visibleActionButtonIDsForTesting == ["process-row-stop", "process-row-restart", "process-row-edit", "process-row-remove"])
    }

    @Test func idleRowsShowRunBeforeEditAndDelete() {
        let row = ProcessRowView(process: ProcessTemplate(name: "api", command: "bun run dev"), shortcut: nil, status: .idle)
        #expect(row.visibleActionButtonIDsForTesting == ["process-row-run", "process-row-edit", "process-row-remove"])
    }

    @Test func browserSessionCollapsedRowShowsResolvedURLButEditFormKeepsRawTemplate() {
        let section = BrowserSessionsSection(
            sessions: [BrowserSession(name: "frontend url", url: "http://localhost:$FRONTEND_PORT")], collapsedDisplayURLs: ["http://localhost:3000"])

        let row = section.browserRow(at: 0)!
        #expect(row.collapsedPrimaryTextForTesting == "frontend url")
        #expect(row.collapsedDetailTextForTesting == "http://localhost:3000")

        row.enterEditing(prefill: nil, animated: false)
        #expect(row.editingURLValueForTesting == "http://localhost:$FRONTEND_PORT")
    }

    @Test func browserSessionEditFormUsesPlainActionLabels() {
        let row = BrowserSessionRowView(session: BrowserSession(name: "docs", url: "https://example.com"))
        row.enterEditing(prefill: nil, animated: false)

        let cancelButton = row.buttonForTesting(accessibilityID: "browser-session-row-edit-cancel")
        let saveButton = row.buttonForTesting(accessibilityID: "browser-session-row-edit-save")

        #expect(cancelButton?.title == "Cancel")
        #expect(saveButton?.title == "Save")
    }

    // MARK: Edit + Save + Cancel mechanics

    @Test func enterEditingSwapsTheRowSubtreeToAForm() {
        let section = ProcessesSection(processes: [ProcessTemplate(name: "api", command: "bun run dev", onExit: .restart)])
        let row = section.row(at: 0)!
        row.enterEditing(prefill: nil, animated: false)
        #expect(row.isEditing)
        #expect(row.formContainsField(accessibilityID: "process-row-edit-name"))
        #expect(row.formContainsField(accessibilityID: "process-row-edit-command"))
        #expect(row.formContainsField(accessibilityID: "process-row-edit-on-exit"))
    }

    @Test func cancelRevertsToCollapsedState() {
        let section = ProcessesSection(processes: [ProcessTemplate(name: "api", command: "bun run dev")])
        let row = section.row(at: 0)!
        row.enterEditing(prefill: nil, animated: false)
        row.exitEditing(animated: false)
        #expect(row.isEditing == false)
    }

    @Test func saveCommitsEditedTemplate() {
        let section = ProcessesSection(processes: [ProcessTemplate(name: "api", command: "bun run dev", onExit: .none)])
        var committed: [ProcessTemplate] = []
        section.onCommit = { committed = $0 }

        let row = section.row(at: 0)!
        row.enterEditing(prefill: nil, animated: false)
        row.setEditingFormValues(name: "api", command: "bun run dev --verbose", onExit: .restart)
        row.triggerSave()

        #expect(committed.count == 1)
        #expect(committed.first?.command == "bun run dev --verbose")
        #expect(committed.first?.onExit == .restart)
        #expect(row.isEditing == false)
    }

    @Test func processEditFormUsesPlainActionLabels() {
        let row = ProcessRowView(process: ProcessTemplate(name: "api", command: "bun run dev"), shortcut: nil, status: .idle)
        row.enterEditing(prefill: nil, animated: false)

        let cancelButton = row.buttonForTesting(accessibilityID: "process-row-edit-cancel")
        let saveButton = row.buttonForTesting(accessibilityID: "process-row-edit-save")

        #expect(cancelButton?.title == "Cancel")
        #expect(saveButton?.title == "Save")
    }

    @Test func invalidSavePresentsErrorAndKeepsEditing() {
        let section = ProcessesSection(processes: [ProcessTemplate(name: "api", command: "bun run dev", onExit: .none)])
        var commitCount = 0
        var presentedError: String?
        section.onCommit = { _ in commitCount += 1 }
        section.validateProcess = { process in throw WorkspaceError.invalidArgument(message: "Invalid process command: \(process.command)") }
        section.presentValidationError = { error in presentedError = error.localizedDescription }

        let row = section.row(at: 0)!
        row.enterEditing(prefill: nil, animated: false)
        row.setEditingFormValues(name: "api", command: "PORT=$FRONTEND_PORT npm run dev", onExit: .none)
        row.triggerSave()

        #expect(commitCount == 0)
        #expect(presentedError == "Invalid argument: Invalid process command: PORT=$FRONTEND_PORT npm run dev")
        #expect(row.isEditing)
    }

    @Test func removeAsksForConfirmationAndProceedsOnApproval() {
        let section = ProcessesSection(processes: [
            ProcessTemplate(name: "api", command: "bun run dev"), ProcessTemplate(name: "worker", command: "bun run worker"),
        ])
        var committed: [ProcessTemplate] = []
        section.onCommit = { committed = $0 }
        var presentedFor: ProcessTemplate?
        section.presentRemoveConfirmation = { template, decide in
            presentedFor = template
            decide(true)
        }

        section.row(at: 0)?.triggerRemove()

        #expect(presentedFor?.name == "api", "Confirmation should be presented before any destructive action")
        #expect(section.rowCount == 1)
        #expect(committed.map { $0.name } == ["worker"])
    }

    @Test func removeIsCancelledWhenConfirmationDeclines() {
        let section = ProcessesSection(processes: [
            ProcessTemplate(name: "api", command: "bun run dev"), ProcessTemplate(name: "worker", command: "bun run worker"),
        ])
        var commitCount = 0
        section.onCommit = { _ in commitCount += 1 }
        section.presentRemoveConfirmation = { _, decide in decide(false) }

        section.row(at: 0)?.triggerRemove()

        #expect(section.rowCount == 2, "Declining the confirmation must keep the row")
        #expect(commitCount == 0)
    }

    @Test func removeOnAnUnsavedDraftSkipsConfirmation() {
        let section = ProcessesSection(processes: [ProcessTemplate(name: "api", command: "bun run dev")])
        var commitCount = 0
        section.onCommit = { _ in commitCount += 1 }
        var presented = false
        section.presentRemoveConfirmation = { _, _ in presented = true }

        section.performAdd()
        section.row(at: 1)?.triggerRemove()

        #expect(presented == false, "Drafts have no committed state; remove should skip the modal")
        #expect(section.rowCount == 1)
        #expect(commitCount == 0)
    }

    @Test func runStopAndRestartCallbacksReceiveTheRowProcess() {
        let process = ProcessTemplate(name: "api", command: "bun run dev")
        let section = ProcessesSection(processes: [process])
        var ranName: String?
        var stoppedName: String?
        var restartedName: String?
        section.onRunProcess = { ranName = $0.name }
        section.onStopProcess = { stoppedName = $0.name }
        section.onRestartProcess = { restartedName = $0.name }

        let row = section.row(at: 0)!
        row.onRun?()
        row.onStop?()
        row.onRestart?()

        #expect(ranName == "api")
        #expect(stoppedName == "api")
        #expect(restartedName == "api")
    }
}

// MARK: Test hooks (internal surface used only by this test target)

extension ProcessesSection {
    func row(at index: Int) -> ProcessRowView? {
        guard index >= 0, index < rowCount else { return nil }
        return rowsStackForTesting.arrangedSubviews.compactMap { $0 as? ProcessRowView }[safe: index]
    }

    fileprivate var rowsStackForTesting: NSStackView {
        // The section's rowsStack is private; reach into the view hierarchy to
        // retrieve it without exposing the field publicly.
        let outer = view.subviews.compactMap({ $0 as? NSStackView }).first
        return outer?.arrangedSubviews.compactMap({ $0 as? NSStackView }).last ?? NSStackView()
    }

    func performAdd() { handleAdd(NSButton()) }
}

extension ProcessRowView {
    var statusDotForTesting: StatusDotView? { subviews.flatMap { $0.subviewsRecursive() }.compactMap { $0 as? StatusDotView }.first }

    var actionButtonAlphaValuesForTesting: [CGFloat] {
        subviews.flatMap { $0.subviewsRecursive() }.compactMap { $0 as? NSButton }.filter { id in
            let identifier = id.accessibilityIdentifier()
            return identifier == "process-row-run" || identifier == "process-row-stop" || identifier == "process-row-restart"
                || identifier == "process-row-edit" || identifier == "process-row-remove"
        }.map(\.alphaValue)
    }

    var visibleActionButtonIDsForTesting: [String] {
        subviews.flatMap { $0.subviewsRecursive() }.compactMap { $0 as? NSButton }.filter { !$0.isHidden }.compactMap { $0.accessibilityIdentifier() }
            .filter { identifier in
                identifier == "process-row-run" || identifier == "process-row-stop" || identifier == "process-row-restart"
                    || identifier == "process-row-edit" || identifier == "process-row-remove"
            }
    }

    var collapsedHasShortcutChip: Bool {
        // Prototype check: the shortcut chip is created at init if a shortcut
        // was provided; since we don't expose the chip directly, look for a
        // ColoredBackgroundView whose height matches a chip.
        subviews.flatMap { $0.subviewsRecursive() }.contains { ($0 as? ColoredBackgroundView)?.cornerRadius == 4 }
    }

    func formContainsField(accessibilityID: String) -> Bool {
        subviews.flatMap { $0.subviewsRecursive() }.contains { $0.accessibilityIdentifier() == accessibilityID }
    }

    func setEditingFormValues(name: String, command: String, onExit: ProcessExitAction) {
        let allFields = subviews.flatMap { $0.subviewsRecursive() }
        if let nameField = allFields.compactMap({ $0 as? NSTextField }).first(where: { $0.accessibilityIdentifier() == "process-row-edit-name" }) {
            nameField.stringValue = name
        }
        if let commandField = allFields.compactMap({ $0 as? NSTextField }).first(where: { $0.accessibilityIdentifier() == "process-row-edit-command" }
        ) {
            commandField.stringValue = command
        }
        if let onExitSegmented = allFields.compactMap({ $0 as? NSSegmentedControl }).first(where: {
            $0.accessibilityIdentifier() == "process-row-edit-on-exit"
        }), let idx = ProcessExitAction.allCases.firstIndex(of: onExit) {
            onExitSegmented.selectedSegment = idx
        }
    }

    func triggerSave() {
        let allFields = subviews.flatMap { $0.subviewsRecursive() }
        if let saveButton = allFields.compactMap({ $0 as? NSButton }).first(where: { $0.accessibilityIdentifier() == "process-row-edit-save" }) {
            _ = saveButton.target?.perform(saveButton.action, with: saveButton)
        }
    }

    func triggerRemove() { onRemove?() }

    func shortcutChipMinXForTesting(shortcut: String) -> CGFloat? { shortcutChipFrameForTesting(shortcut: shortcut)?.minX }

    func textFieldForTesting(accessibilityID: String) -> NSTextField? {
        subviews.flatMap { $0.subviewsRecursive() }.compactMap { $0 as? NSTextField }.first { $0.accessibilityIdentifier() == accessibilityID }
    }

    func buttonForTesting(accessibilityID: String) -> NSButton? {
        subviews.flatMap { $0.subviewsRecursive() }.compactMap { $0 as? NSButton }.first { $0.accessibilityIdentifier() == accessibilityID }
    }
}

extension BrowserSessionRowView {
    func shortcutChipMinXForTesting(shortcut: String) -> CGFloat? { shortcutChipFrameForTesting(shortcut: shortcut)?.minX }

    func textFieldForTesting(accessibilityID: String) -> NSTextField? {
        subviews.flatMap { $0.subviewsRecursive() }.compactMap { $0 as? NSTextField }.first { $0.accessibilityIdentifier() == accessibilityID }
    }

    func buttonForTesting(accessibilityID: String) -> NSButton? {
        subviews.flatMap { $0.subviewsRecursive() }.compactMap { $0 as? NSButton }.first { $0.accessibilityIdentifier() == accessibilityID }
    }
}

extension BrowserSessionsSection {
    func performAdd() { handleAdd(NSButton()) }

    func browserRow(at index: Int) -> BrowserSessionRowView? {
        guard index >= 0, index < rowCount else { return nil }
        return rowsStackForTesting.arrangedSubviews.compactMap { $0 as? BrowserSessionRowView }[safe: index]
    }

    fileprivate var rowsStackForTesting: NSStackView {
        let outer = view.subviews.compactMap({ $0 as? NSStackView }).first
        return outer?.arrangedSubviews.compactMap({ $0 as? NSStackView }).last ?? NSStackView()
    }
}

extension NSView {
    fileprivate func subviewsRecursive() -> [NSView] {
        var all: [NSView] = [self]
        for sub in subviews { all.append(contentsOf: sub.subviewsRecursive()) }
        return all
    }

    fileprivate func shortcutChipFrameForTesting(shortcut: String) -> NSRect? {
        let chip = subviewsRecursive().compactMap { $0 as? ColoredBackgroundView }.first { view in
            view.subviews.compactMap { $0 as? NSTextField }.contains { $0.stringValue == shortcut }
        }
        guard let chip else { return nil }
        return convert(chip.bounds, from: chip)
    }
}

extension Array { fileprivate subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil } }
