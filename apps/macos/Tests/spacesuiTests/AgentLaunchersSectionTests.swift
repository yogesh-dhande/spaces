import AppKit
import Testing
import workspacecore

@testable import spacesui

@MainActor @Suite struct AgentLaunchersSectionTests {
    @Test func addFromEmptySectionShowsEditableDraftRow() {
        let section = AgentLaunchersSection()

        #expect(section.rowCount == 0)

        section.performAdd()

        #expect(section.rowCount == 1)
        #expect(section.isEditing(at: 0))
    }

    @Test func codingAgentsSectionRendersMatchedAndAdHocRuntimeRows() {
        let section = AgentLaunchersSection(launchers: [
            AgentLauncher(name: "claude", command: "claude"), AgentLauncher(name: "codex", command: "codex"),
        ])

        section.runtimeAgentWindows = [
            AgentWindowRecord(
                id: "matched", workspaceID: "workspace", provider: .spaces, label: "Claude", terminalTrackingID: "session-claude", codexThreadID: nil,
                windowID: 201, yabaiWindowID: 201, status: .idle, createdAt: "now", updatedAt: "now"),
            AgentWindowRecord(
                id: "adhoc", workspaceID: "workspace", provider: .spaces, label: "reviewer", terminalTrackingID: "session-reviewer",
                codexThreadID: nil, windowID: 202, yabaiWindowID: 202, status: .spinning, createdAt: "now", updatedAt: "now"),
        ]

        #expect(section.rowCount == 3)
        #expect(section.row(at: 0)?.displayNameForTesting == "claude")
        #expect(section.row(at: 1)?.displayNameForTesting == "codex")
        #expect(section.row(at: 2)?.displayNameForTesting == "reviewer")
    }

    @Test func codingAgentsSectionMatchesRenamedLaunchersByID() {
        let section = AgentLaunchersSection(launchers: [AgentLauncher(id: "launcher-codex", name: "Codex Renamed", command: "codex")])
        section.runtimeAgentWindows = [
            AgentWindowRecord(
                id: "codex-runtime", workspaceID: "workspace", provider: .spaces, label: "Codex",
                terminalTarget: TerminalTargetRecord(windowID: 201, trackingID: "session-codex"), claimedLauncherID: "launcher-codex",
                claimedLauncherName: "Codex", status: .idle, createdAt: "now", updatedAt: "now")
        ]

        #expect(section.rowCount == 1)
        #expect(section.row(at: 0)?.displayNameForTesting == "Codex Renamed")
        #expect(section.row(at: 0)?.visibleActionButtonIDsForTesting.contains("agent-launcher-row-stop") == true)
    }

    @Test func codingAgentsSectionKeepsStaleClaimedIDAsUnmatchedRuntimeRow() {
        let section = AgentLaunchersSection(launchers: [AgentLauncher(id: "launcher-codex-new", name: "Codex", command: "codex")])
        section.runtimeAgentWindows = [
            AgentWindowRecord(
                id: "codex-runtime", workspaceID: "workspace", provider: .spaces, label: "Codex",
                terminalTarget: TerminalTargetRecord(trackingID: "session-codex"), claimedLauncherID: "launcher-codex-old",
                claimedLauncherName: "Codex", status: .idle, createdAt: "now", updatedAt: "now")
        ]

        #expect(section.rowCount == 2)
        #expect(section.row(at: 0)?.displayNameForTesting == "Codex")
        #expect(
            section.row(at: 0)?.visibleActionButtonIDsForTesting == [
                "agent-launcher-row-run", "agent-launcher-row-edit", "agent-launcher-row-remove",
            ])
        #expect(section.row(at: 1)?.displayNameForTesting == "Codex")
        #expect(section.row(at: 1)?.visibleActionButtonIDsForTesting == ["agent-launcher-row-stop"])
    }

    @Test func adHocRuntimeRowsStayReadOnly() {
        let section = AgentLaunchersSection()
        section.runtimeAgentWindows = [
            AgentWindowRecord(
                id: "adhoc", workspaceID: "workspace", provider: .spaces, label: "reviewer", terminalTrackingID: "session-reviewer",
                codexThreadID: nil, windowID: 202, yabaiWindowID: 202, status: .waiting, createdAt: "now", updatedAt: "now")
        ]
        section.runtimeWindowTitleByAgentWindowID = ["adhoc": "review notes"]

        #expect(section.rowCount == 1)
        #expect(section.row(at: 0)?.hasEditButtonForTesting == false)
        #expect(section.row(at: 0)?.hasRemoveButtonForTesting == false)
        #expect(section.row(at: 0)?.displayDetailForTesting == "review notes")
    }

    @Test func unlabeledRuntimeRowsUseFallbackDisplayName() {
        let section = AgentLaunchersSection()
        section.runtimeAgentWindows = [
            AgentWindowRecord(
                id: "adhoc", workspaceID: "workspace", provider: .spaces, label: nil, terminalTrackingID: "ghostty-hook-1",
                terminalNativeID: "ghostty-terminal-1", codexThreadID: nil, windowID: 202, yabaiWindowID: 202, status: .waiting, createdAt: "now",
                updatedAt: "now")
        ]
        section.runtimeWindowTitleByAgentWindowID = ["adhoc": "shell-1"]

        #expect(section.rowCount == 1)
        #expect(section.row(at: 0)?.displayNameForTesting == "Coding Agent shell-1")
    }

    @Test func agentRowsUseNeutralTileTextForKnownAgents() {
        let rows = [
            AgentLauncherRowView(launcher: AgentLauncher(name: "Codex CLI", command: "codex")),
            AgentLauncherRowView(launcher: AgentLauncher(name: "claude code cli", command: "claude")),
            AgentLauncherRowView(launcher: AgentLauncher(name: "Reviewer", command: "OPENCODE run")),
        ]

        #expect(rows.map(\.agentTileTextForTesting) == ["CX", "CL", "OC"])
    }

    @Test func agentRowsUseDisplayNameLettersForCustomTileText() {
        let row = AgentLauncherRowView(launcher: AgentLauncher(name: "review-bot", command: "review notes"))

        #expect(row.agentTileTextForTesting == "RE")
    }

    @Test func rebindUpdatesAgentTileText() {
        let row = AgentLauncherRowView(launcher: AgentLauncher(name: "review-bot", command: "review notes"))

        row.rebindCollapsedContent(from: AgentLauncher(name: "Codex", command: "codex"))

        #expect(row.agentTileTextForTesting == "CX")
    }

    @Test func launcherEditFormUsesPlainActionLabels() {
        let row = AgentLauncherRowView(launcher: AgentLauncher(name: "claude", command: "claude"))
        row.enterEditing(prefill: nil, animated: false)

        let cancelButton = row.buttonForTesting(accessibilityID: "agent-launcher-row-edit-cancel")
        let saveButton = row.buttonForTesting(accessibilityID: "agent-launcher-row-edit-save")

        #expect(cancelButton?.title == "Cancel")
        #expect(saveButton?.title == "Save")
    }

    @Test func configuredIdleRowsShowRunBeforeEditAndRemove() {
        let row = AgentLauncherRowView(launcher: AgentLauncher(name: "claude", command: "claude"))
        #expect(row.visibleActionButtonIDsForTesting == ["agent-launcher-row-run", "agent-launcher-row-edit", "agent-launcher-row-remove"])
    }

    @Test func configurationOnlySectionsHideRuntimeControls() {
        let section = AgentLaunchersSection(launchers: [AgentLauncher(name: "claude", command: "claude")], showsRuntimeControls: false)

        #expect(section.row(at: 0)?.visibleActionButtonIDsForTesting == ["agent-launcher-row-edit", "agent-launcher-row-remove"])
    }

    @Test func configuredLiveRowsShowStopAndRestartBeforeEditAndRemove() {
        let row = AgentLauncherRowView(launcher: AgentLauncher(name: "claude", command: "claude"), status: .idle, isRunning: true, canRestart: true)
        #expect(
            row.visibleActionButtonIDsForTesting == [
                "agent-launcher-row-stop", "agent-launcher-row-restart", "agent-launcher-row-edit", "agent-launcher-row-remove",
            ])
    }

    @Test func unconfiguredRuntimeRowsShowStopWithoutRestart() {
        let row = AgentLauncherRowView(
            launcher: AgentLauncher(name: "reviewer", command: "review notes"), status: .spinning, isEditable: false, isRunning: true,
            canRestart: false)
        #expect(row.visibleActionButtonIDsForTesting == ["agent-launcher-row-stop"])
    }

    @Test func runStopAndRestartCallbacksReceiveConfiguredAndRuntimeRows() {
        let section = AgentLaunchersSection(launchers: [AgentLauncher(name: "claude", command: "claude")])
        section.runtimeAgentWindows = [
            AgentWindowRecord(
                id: "claude-runtime", workspaceID: "workspace", provider: .spaces, label: "claude", terminalTrackingID: "session-claude",
                codexThreadID: nil, windowID: 101, yabaiWindowID: 101, status: .idle, createdAt: "now", updatedAt: "now")
        ]
        var stoppedID: String?
        var restartedID: String?
        section.onStopAgentWindow = { stoppedID = $0.id }
        section.onRestartAgentWindow = { restartedID = $0.id }

        section.row(at: 0)?.onStop?()
        section.row(at: 0)?.onRestart?()

        #expect(stoppedID == "claude-runtime")
        #expect(restartedID == "claude-runtime")

        let idleSection = AgentLaunchersSection(launchers: [AgentLauncher(name: "codex", command: "codex")])
        var ranName: String?
        idleSection.onRunLauncher = { ranName = $0.name }
        idleSection.row(at: 0)?.onRun?()
        #expect(ranName == "codex")
    }
}

extension AgentLaunchersSection {
    func performAdd() { handleAdd(NSButton()) }

    func row(at index: Int) -> AgentLauncherRowView? {
        guard index >= 0, index < rowCount else { return nil }
        return rowsStackForTesting.arrangedSubviews.compactMap { $0 as? AgentLauncherRowView }[agentTestsSafe: index]
    }

    fileprivate var rowsStackForTesting: NSStackView {
        let outer = view.subviews.compactMap({ $0 as? NSStackView }).first
        return outer?.arrangedSubviews.compactMap({ $0 as? NSStackView }).last ?? NSStackView()
    }
}

extension AgentLauncherRowView {
    var displayNameForTesting: String { textFieldForTesting(accessibilityID: "agent-launcher-row-name")?.stringValue ?? "" }
    var displayDetailForTesting: String { textFieldForTesting(accessibilityID: "agent-launcher-row-detail")?.stringValue ?? "" }
    var agentTileTextForTesting: String { textFieldForTesting(accessibilityID: "agent-launcher-row-tile")?.stringValue ?? "" }

    var hasEditButtonForTesting: Bool {
        subviewsRecursiveForAgentTests().compactMap { $0 as? NSButton }.contains { $0.accessibilityIdentifier() == "agent-launcher-row-edit" }
    }

    var hasRemoveButtonForTesting: Bool {
        subviewsRecursiveForAgentTests().compactMap { $0 as? NSButton }.contains { $0.accessibilityIdentifier() == "agent-launcher-row-remove" }
    }

    func textFieldForTesting(accessibilityID: String) -> NSTextField? {
        subviewsRecursiveForAgentTests().compactMap { $0 as? NSTextField }.first { $0.accessibilityIdentifier() == accessibilityID }
    }

    func buttonForTesting(accessibilityID: String) -> NSButton? {
        subviewsRecursiveForAgentTests().compactMap { $0 as? NSButton }.first { $0.accessibilityIdentifier() == accessibilityID }
    }

    var visibleActionButtonIDsForTesting: [String] {
        subviewsRecursiveForAgentTests().compactMap { $0 as? NSButton }.compactMap { button in
            guard !button.isHidden else { return nil }
            return button.accessibilityIdentifier()
        }
    }
}

extension NSView {
    fileprivate func subviewsRecursiveForAgentTests() -> [NSView] {
        var all: [NSView] = [self]
        for subview in subviews { all.append(contentsOf: subview.subviewsRecursiveForAgentTests()) }
        return all
    }
}

extension Array { fileprivate subscript(agentTestsSafe index: Int) -> Element? { indices.contains(index) ? self[index] : nil } }
