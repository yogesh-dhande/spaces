import AppKit
import Testing

@testable import spacesui

/// A terminal pane's content view hosts the agent's brief column beside the terminal: present only
/// while there is a brief to show, taking its width from the terminal, and counting as part of the pane
/// for focus.
@MainActor @Suite struct AgentBriefPaneContainerViewTests {
    private let brief = AgentBriefPresentation(agentKey: "agent-1", markdown: "# Waiting on review\n\n- [ ] merge", updatedAt: "2026-09-25T10:00:00Z")

    /// A container in a borderless window, laid out at `width`, so frames and first responders are real.
    private func hostedContainer(width: CGFloat = 900) -> (container: AgentBriefPaneContainerView, terminal: NSView, window: NSWindow) {
        let terminal = NSView()
        let container = AgentBriefPaneContainerView(terminalView: terminal)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 500), styleMask: [.borderless], backing: .buffered, defer: false)
        let root = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 500))
        window.contentView = root
        root.addSubview(container)
        NSLayoutConstraint.activate([
            container.topAnchor.constraint(equalTo: root.topAnchor), container.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            container.leadingAnchor.constraint(equalTo: root.leadingAnchor), container.trailingAnchor.constraint(equalTo: root.trailingAnchor),
        ])
        return (container, terminal, window)
    }

    @Test func aPaneWithoutABriefHasNoColumnAndTheTerminalTakesTheWholeWidth() {
        let (container, terminal, window) = hostedContainer()
        container.apply(nil)
        window.contentView?.layoutSubtreeIfNeeded()
        #expect(container.briefColumn == nil)
        #expect(!container.subviews.contains { $0 is AgentBriefColumnView }, "the column is absent, not hidden")
        #expect(terminal.frame.width == 900)
        #expect(container.briefDebugState.visible == false)
        #expect(container.briefDebugState.summary == nil)
    }

    @Test func aBriefSitsBesideTheTerminalAtTheTrailingEdge() throws {
        let (container, terminal, window) = hostedContainer()
        container.apply(brief)
        window.contentView?.layoutSubtreeIfNeeded()
        let column = try #require(container.briefColumn)
        #expect(column.frame.width == AgentBriefColumnView.width)
        #expect(column.frame.maxX == 900)
        #expect(terminal.frame.width == 900 - AgentBriefColumnView.width, "the terminal gives up the column's width")
        #expect(column.textView.string.contains("Waiting on review"))
        #expect(container.briefDebugState.visible)
        #expect(container.briefDebugState.summary == "Waiting on review")
    }

    @Test func removingTheBriefRemovesTheColumnAndGivesTheWidthBack() {
        let (container, terminal, window) = hostedContainer()
        container.apply(brief)
        container.apply(nil)
        window.contentView?.layoutSubtreeIfNeeded()
        #expect(container.briefColumn == nil)
        #expect(!container.subviews.contains { $0 is AgentBriefColumnView })
        #expect(terminal.frame.width == 900)
    }

    @Test func aViewInsideTheColumnBelongsToTheBriefColumn() throws {
        let (container, terminal, _) = hostedContainer()
        container.apply(brief)
        let column = try #require(container.briefColumn)
        #expect(container.briefColumnOwns(column.textView))
        #expect(!container.briefColumnOwns(terminal))
        #expect(!container.briefColumnOwns(nil))
    }

    @Test func removingAColumnThatHeldFocusReportsItSoFocusCanReturnToTheTerminal() throws {
        let (container, _, window) = hostedContainer()
        container.apply(brief)
        let column = try #require(container.briefColumn)
        #expect(window.makeFirstResponder(column.textView))
        #expect(container.apply(nil), "the column held the first responder")

        container.apply(brief)
        #expect(!container.apply(nil), "a column that did not hold focus reports nothing to hand back")
    }

    @Test func reapplyingTheSameBriefKeepsTheReadersSelection() throws {
        let (container, _, _) = hostedContainer()
        container.apply(brief)
        let column = try #require(container.briefColumn)
        column.textView.setSelectedRange(NSRange(location: 2, length: 5))
        container.apply(brief)
        #expect(column.textView.selectedRange() == NSRange(location: 2, length: 5))

        container.apply(AgentBriefPresentation(agentKey: "agent-1", markdown: "# Merged", updatedAt: brief.updatedAt))
        #expect(column.textView.string == "Merged")
    }

    @Test func theCaptionSaysHowLongAgoTheBriefWasWritten() throws {
        let written = try #require(ISO8601DateFormatter().date(from: "2026-09-25T10:00:00Z"))
        #expect(AgentBriefColumnView.updatedCaption(updatedAt: nil, now: written) == nil)
        #expect(AgentBriefColumnView.updatedCaption(updatedAt: written, now: written.addingTimeInterval(20)) == "Updated just now")
        #expect(
            AgentBriefColumnView.updatedCaption(updatedAt: written, now: written.addingTimeInterval(-30)) == "Updated just now",
            "a device clock ahead of this Mac's never reads as a time in the future")
        let later = try #require(AgentBriefColumnView.updatedCaption(updatedAt: written, now: written.addingTimeInterval(120)))
        #expect(later.hasPrefix("Updated "))
        #expect(later != "Updated just now")
    }
}
