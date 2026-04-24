import AppKit
import Testing
import streamctl

@testable import gui

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
        let section = ProcessesSection(processes: [ProcessTemplate(name: "api", command: "bun run dev")])
        // Simulate what the host would do when status updates arrive.
        section.row(at: 0)?.enterEditing(prefill: nil, animated: false)
        #expect(section.isEditing(at: 0))

        section.reload(processes: [ProcessTemplate(name: "api", command: "bun run dev")])
        #expect(section.isEditing(at: 0), "Editing state should survive a no-op reload")
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

    @Test func shortcutChipsAlignAcrossProcessBrowserAndAgentRows() {
        let processRow = ProcessRowView(process: ProcessTemplate(name: "api", command: "bun run dev"), shortcut: "⌘1", status: .running)
        let browserRow = BrowserSessionRowView(session: BrowserSession(name: "docs", url: "https://example.com"), shortcut: "⌘2")
        let agentRow = AgentLauncherRowView(launcher: AgentLauncher(name: "claude", command: "claude"), shortcut: "⌘3")

        let stack = NSStackView(views: [processRow, browserRow, agentRow])
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
        agentRow.widthAnchor.constraint(equalToConstant: 640).isActive = true
        host.layoutSubtreeIfNeeded()

        let processX = processRow.shortcutChipMinXForTesting(shortcut: "⌘1")
        let browserX = browserRow.shortcutChipMinXForTesting(shortcut: "⌘2")
        let agentX = agentRow.shortcutChipMinXForTesting(shortcut: "⌘3")

        #expect(processX != nil)
        #expect(browserX != nil)
        #expect(agentX != nil)
        #expect(abs((processX ?? 0) - (browserX ?? 0)) < 0.5)
        #expect(abs((browserX ?? 0) - (agentX ?? 0)) < 0.5)
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
        if let onExitPopup = allFields.compactMap({ $0 as? NSPopUpButton }).first(where: {
            $0.accessibilityIdentifier() == "process-row-edit-on-exit"
        }) {
            onExitPopup.selectItem(withTitle: onExit.rawValue)
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
}

extension BrowserSessionRowView {
    func shortcutChipMinXForTesting(shortcut: String) -> CGFloat? { shortcutChipFrameForTesting(shortcut: shortcut)?.minX }
}

extension AgentLauncherRowView {
    func shortcutChipMinXForTesting(shortcut: String) -> CGFloat? { shortcutChipFrameForTesting(shortcut: shortcut)?.minX }
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
