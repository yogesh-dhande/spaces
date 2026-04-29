import AppKit
import Testing
import streamctl

@testable import gui

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
                id: "matched", workspaceID: "workspace", provider: .iterm2, label: "Claude", terminalTrackingID: "session-claude", codexThreadID: nil,
                windowID: 201, yabaiWindowID: 201, status: .idle, createdAt: "now", updatedAt: "now"),
            AgentWindowRecord(
                id: "adhoc", workspaceID: "workspace", provider: .ghostty, label: "reviewer", terminalTrackingID: "session-reviewer",
                codexThreadID: nil, windowID: 202, yabaiWindowID: 202, status: .spinning, createdAt: "now", updatedAt: "now"),
        ]

        #expect(section.rowCount == 3)
        #expect(section.row(at: 0)?.displayNameForTesting == "claude")
        #expect(section.row(at: 1)?.displayNameForTesting == "codex")
        #expect(section.row(at: 2)?.displayNameForTesting == "reviewer")
    }

    @Test func adHocRuntimeRowsStayReadOnly() {
        let section = AgentLaunchersSection()
        section.runtimeAgentWindows = [
            AgentWindowRecord(
                id: "adhoc", workspaceID: "workspace", provider: .iterm2, label: "reviewer", terminalTrackingID: "session-reviewer",
                codexThreadID: nil, windowID: 202, yabaiWindowID: 202, status: .waiting, createdAt: "now", updatedAt: "now")
        ]
        section.runtimeWindowTitleByAgentWindowID = ["adhoc": "review notes"]

        #expect(section.rowCount == 1)
        #expect(section.row(at: 0)?.hasEditButtonForTesting == false)
        #expect(section.row(at: 0)?.hasRemoveButtonForTesting == false)
        #expect(section.row(at: 0)?.displayDetailForTesting == "review notes")
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
    var displayNameForTesting: String { subviewsRecursiveForAgentTests().compactMap { $0 as? NSTextField }.first?.stringValue ?? "" }
    var displayDetailForTesting: String { subviewsRecursiveForAgentTests().compactMap { $0 as? NSTextField }.dropFirst().first?.stringValue ?? "" }

    var hasEditButtonForTesting: Bool {
        subviewsRecursiveForAgentTests().compactMap { $0 as? NSButton }.contains { $0.accessibilityIdentifier() == "agent-launcher-row-edit" }
    }

    var hasRemoveButtonForTesting: Bool {
        subviewsRecursiveForAgentTests().compactMap { $0 as? NSButton }.contains { $0.accessibilityIdentifier() == "agent-launcher-row-remove" }
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
