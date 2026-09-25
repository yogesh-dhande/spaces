import AppKit
import Testing

@testable import spacesui

/// A global panel window has no footer and no ⋯ menu, so its identity strip carries the brief glyph for
/// the pane it shows, drawn from the identity the coordinator computes.
@MainActor @Suite struct PanelWindowIdentityStripBriefTests {
    private func panel(brief: AgentBriefToggleState) -> WorkspacePanelView {
        let panel = WorkspacePanelView(scope: .globalWindow(panelWindowID: "panel-1"))
        panel.apply(
            layout: PanelLayoutEngine.appendTab(
                tabID: "tab-1", pane: Pane(id: "pane-1", content: .terminalSession(deviceID: "device", sessionID: "sess-1")), to: PanelLayout()),
            titlesByTabID: ["tab-1": "claude"], identity: identity(brief: brief))
        return panel
    }

    private func identity(brief: AgentBriefToggleState) -> PanelWindowIdentity {
        PanelWindowIdentity(workspaceLabel: "feature", paneTitle: "claude", followsSidebar: false, brief: brief)
    }

    private func briefButton(in root: NSView) -> NSButton? {
        if let button = root as? NSButton, button.accessibilityIdentifier() == "panel-window-brief-toggle" { return button }
        for subview in root.subviews { if let found = briefButton(in: subview) { return found } }
        return nil
    }

    @Test func theGlyphFollowsTheShownPanesBriefState() throws {
        let panel = panel(brief: .shown)
        let button = try #require(briefButton(in: panel))
        #expect(!button.isHidden)
        #expect(button.toolTip == "Hide Brief")

        panel.updateIdentity(identity(brief: .hidden))
        #expect(!button.isHidden)
        #expect(button.toolTip == "Show Brief")

        panel.updateIdentity(identity(brief: .unavailable))
        #expect(button.isHidden, "a pane with no brief shows no glyph")
    }

    @Test func clickingTheGlyphAsksThePanelToToggleTheBrief() throws {
        let panel = panel(brief: .shown)
        var toggles = 0
        panel.onToggleBrief = { toggles += 1 }
        try #require(briefButton(in: panel)).performClick(nil)
        #expect(toggles == 1)
    }
}
