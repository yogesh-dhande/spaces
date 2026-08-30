import AppKit
import Testing

@testable import spacesui

/// A `.globalWindow` panel's identity strip shows the current workspace label alongside the pane
/// title. A workspace rename (e.g. a git branch rename) reaches this client only through an
/// overview update, and `PanelCoordinator`'s lightweight title-refresh path (the one an overview
/// tick drives, which skips a full `apply(layout:...)` re-render) must recompute that label fresh
/// rather than carrying the last-rendered one forward — see `PanelCoordinator.refreshTabTitles`'s
/// `.globalWindow` branch and `WorkspacePanelView.updateIdentity(_:)`.
@MainActor @Suite struct WorkspacePanelIdentityRefreshTests {
    private func layout(tabID: String, sessionID: String) -> PanelLayout {
        PanelLayoutEngine.appendTab(
            tabID: tabID, pane: Pane(id: "pane-\(tabID)", content: .terminalSession(deviceID: "device", sessionID: sessionID)), to: PanelLayout())
    }

    private func textFieldStringValues(in root: NSView) -> [String] {
        var values: [String] = []
        func walk(_ view: NSView) {
            if let field = view as? NSTextField { values.append(field.stringValue) }
            for sub in view.subviews { walk(sub) }
        }
        walk(root)
        return values
    }

    @Test func updateIdentityReplacesTheWorkspaceLabelRatherThanCarryingItForward() {
        let panel = WorkspacePanelView(scope: .globalWindow(panelWindowID: "panel-1"))
        panel.apply(
            layout: layout(tabID: "tab-1", sessionID: "sess-1"), titlesByTabID: ["tab-1": "zsh"],
            identity: PanelWindowIdentity(workspaceLabel: "old-branch-name", paneTitle: "zsh", followsSidebar: false))
        #expect(textFieldStringValues(in: panel).contains("old-branch-name"))

        // The lightweight title-refresh path calls both of these on an overview tick: `updateTabTitle`
        // for the tab's title bookkeeping, then `updateIdentity` with a freshly computed identity — see
        // `PanelCoordinator.refreshTabTitles`. Neither should leave the stale label on screen.
        panel.updateTabTitle("zsh", forTabID: "tab-1")
        panel.updateIdentity(PanelWindowIdentity(workspaceLabel: "renamed-branch", paneTitle: "zsh", followsSidebar: false))

        let values = textFieldStringValues(in: panel)
        #expect(values.contains("renamed-branch"))
        #expect(!values.contains("old-branch-name"))
    }

    @Test func workspacePanelHasNoIdentityStripToUpdate() {
        // `.workspace` scope has a tab bar, not an identity strip: `updateIdentity` must be a
        // harmless no-op there rather than assuming the strip exists.
        let panel = WorkspacePanelView(scope: .workspace(deviceID: "device", workspaceID: "workspace-1"))
        panel.apply(layout: layout(tabID: "tab-1", sessionID: "sess-1"), titlesByTabID: ["tab-1": "zsh"])
        panel.updateIdentity(PanelWindowIdentity(workspaceLabel: "renamed-branch", paneTitle: "zsh", followsSidebar: false))
        #expect(!textFieldStringValues(in: panel).contains("renamed-branch"))
    }
}
