import AppKit
import Testing
import spacesdevicecore

@testable import spacesui

/// The block an empty workspace panel offers in place of its panes: which actions it carries, what a
/// device outage does to them, and that the panel keeps its tab strip while it is showing.
@MainActor @Suite struct WorkspacePanelEmptyStateTests {
    private func state(offersStart: Bool, deviceAcceptsDaemonActions: Bool = true, name: String = "feature/login") -> WorkspacePanelEmptyState {
        WorkspacePanelEmptyState(
            workspaceName: name, directory: "~/src/spaces-feature-login", offersStart: offersStart,
            deviceAcceptsDaemonActions: deviceAcceptsDaemonActions, unreachableDeviceTooltip: deviceAcceptsDaemonActions ? nil : "Studio is offline",
            newTerminalShortcutHint: "⌘ T")
    }

    private func layout(tabID: String) -> PanelLayout {
        PanelLayoutEngine.appendTab(
            tabID: tabID, pane: Pane(id: "pane-\(tabID)", content: .terminalSession(deviceID: "device", sessionID: "sess-\(tabID)")),
            to: PanelLayout())
    }

    private func view(identifier: String, in root: NSView) -> NSView? {
        if root.accessibilityIdentifier() == identifier { return root }
        for subview in root.subviews { if let match = view(identifier: identifier, in: subview) { return match } }
        return nil
    }

    private func button(identifier: String, in root: NSView) -> NSButton? { view(identifier: identifier, in: root) as? NSButton }

    // MARK: Offered actions

    /// A stopped workspace is the case the empty panel exists for: it owes a Start, and New terminal
    /// stays beside it because Start never opens an ad hoc terminal.
    @Test func stoppedWorkspaceOffersStartAndNewTerminal() {
        let stopped = state(
            offersStart: AppKitController.workspaceLifecycleControlsOfferStart(
                projectKind: .standard, isRunning: false, missingConfiguredProcessCount: 0))
        #expect(stopped.offeredActions == [.start, .newTerminal])
    }

    /// A running workspace with every configured process up has nothing left to start, so the panel
    /// offers the one action that fills it.
    @Test func runningWorkspaceOffersNewTerminalAlone() {
        let running = state(
            offersStart: AppKitController.workspaceLifecycleControlsOfferStart(
                projectKind: .standard, isRunning: true, missingConfiguredProcessCount: 0))
        #expect(running.offeredActions == [.newTerminal])
    }

    /// `isRunning` turns true on an ad hoc terminal alone, so a running workspace can still owe a
    /// Start — the empty state follows the same rule as the footer and the sidebar row's menu.
    @Test func runningWorkspaceWithAMissingProcessStillOffersStart() {
        let running = state(
            offersStart: AppKitController.workspaceLifecycleControlsOfferStart(
                projectKind: .standard, isRunning: true, missingConfiguredProcessCount: 1))
        #expect(running.offeredActions == [.start, .newTerminal])
    }

    /// The home row has no lifecycle at all: the daemon refuses Start for it, so its empty panel offers
    /// New terminal alone whatever its run state and missing-process count read, rather than a button
    /// whose only outcome is the daemon's rejection alert.
    @Test func homeWorkspaceOffersNewTerminalAlone() {
        for isRunning in [false, true] {
            for missing in [0, 1] {
                let home = state(
                    offersStart: AppKitController.workspaceLifecycleControlsOfferStart(
                        projectKind: .home, isRunning: isRunning, missingConfiguredProcessCount: missing), name: "~")
                #expect(home.offeredActions == [.newTerminal])
            }
        }
    }

    /// An unreachable device keeps the actions listed and refuses them, the same treatment the
    /// workspace footer's controls carry, rather than leaving the pane with nothing at all.
    @Test func unreachableDeviceKeepsTheActionsButRefusesThem() {
        #expect(state(offersStart: true, deviceAcceptsDaemonActions: false).offeredActions == [.start, .newTerminal])
        #expect(!state(offersStart: true, deviceAcceptsDaemonActions: false).actionsAreEnabled)
        #expect(state(offersStart: true).actionsAreEnabled)
    }

    // MARK: The block itself

    @Test func blockRendersTheOfferedActionsAndTheWorkspaceIdentity() throws {
        let block = WorkspacePanelEmptyStateView()
        block.update(state: state(offersStart: true))

        let name = try #require(view(identifier: "workspace-panel-empty-name", in: block) as? NSTextField)
        #expect(name.stringValue == "feature/login")
        #expect((view(identifier: "workspace-panel-empty-dir", in: block) as? NSTextField)?.stringValue == "~/src/spaces-feature-login")
        #expect(button(identifier: "workspace-panel-empty-start", in: block) != nil)
        #expect(button(identifier: "workspace-panel-empty-new-terminal", in: block) != nil)

        block.update(state: state(offersStart: false))
        #expect(button(identifier: "workspace-panel-empty-start", in: block) == nil)
        #expect(button(identifier: "workspace-panel-empty-new-terminal", in: block) != nil)
    }

    @Test func blockDisablesItsActionsWhileTheDeviceCannotAct() throws {
        let block = WorkspacePanelEmptyStateView()
        block.update(state: state(offersStart: true, deviceAcceptsDaemonActions: false))

        for identifier in ["workspace-panel-empty-start", "workspace-panel-empty-new-terminal"] {
            let action = try #require(button(identifier: identifier, in: block))
            #expect(!action.isEnabled)
            #expect(action.alphaValue == AppKitController.unreachableDeviceAlpha)
            #expect(action.toolTip == "Studio is offline")
        }

        block.update(state: state(offersStart: true))
        let recovered = try #require(button(identifier: "workspace-panel-empty-start", in: block))
        #expect(recovered.isEnabled)
        #expect(recovered.alphaValue == 1)
    }

    @Test func blockButtonsFireTheirActions() throws {
        let block = WorkspacePanelEmptyStateView()
        var started = 0
        var openedTerminals = 0
        block.onStartWorkspace = { started += 1 }
        block.onNewTerminal = { openedTerminals += 1 }
        block.update(state: state(offersStart: true))

        try #require(button(identifier: "workspace-panel-empty-start", in: block)).performClick(nil)
        try #require(button(identifier: "workspace-panel-empty-new-terminal", in: block)).performClick(nil)
        #expect(started == 1)
        #expect(openedTerminals == 1)
    }

    /// Overview ticks re-apply the same state every few seconds. Rebuilding then would destroy the
    /// button under the pointer between mouse-down and mouse-up, so an unchanged state touches nothing.
    @Test func unchangedStateKeepsTheSameButtonInstances() throws {
        let block = WorkspacePanelEmptyStateView()
        block.update(state: state(offersStart: true))
        let start = try #require(button(identifier: "workspace-panel-empty-start", in: block))

        block.update(state: state(offersStart: true))
        #expect(button(identifier: "workspace-panel-empty-start", in: block) === start)

        block.update(state: state(offersStart: true, name: "feature/logout"))
        #expect(button(identifier: "workspace-panel-empty-start", in: block) !== start)
    }

    // MARK: The panel around it

    /// The empty panel keeps its tab strip, so `+` is still there to open a tab; the split buttons
    /// leave with the last pane, since a split has nothing to act on.
    @Test func emptyWorkspacePanelShowsTheBlockAndKeepsItsTabStrip() throws {
        let panel = WorkspacePanelView(scope: .workspace(deviceID: "device", workspaceID: "w1"))
        panel.apply(layout: PanelLayout(), titlesByTabID: [:], emptyState: state(offersStart: true))

        let plus = try #require(view(identifier: "panel-new-tab", in: panel))
        #expect(!plus.isHiddenOrHasHiddenAncestor)
        #expect(try #require(view(identifier: "panel-split-right", in: panel)).isHidden)
        #expect(try #require(view(identifier: "panel-split-down", in: panel)).isHidden)
        let start = try #require(button(identifier: "workspace-panel-empty-start", in: panel))
        #expect(!start.isHiddenOrHasHiddenAncestor)
    }

    @Test func aPanelWithTabsHidesTheBlockAndRestoresTheSplitActions() throws {
        let panel = WorkspacePanelView(scope: .workspace(deviceID: "device", workspaceID: "w1"))
        panel.apply(layout: PanelLayout(), titlesByTabID: [:], emptyState: state(offersStart: true))
        panel.apply(layout: layout(tabID: "tab-1"), titlesByTabID: ["tab-1": "shell"], emptyState: state(offersStart: true))

        #expect(button(identifier: "workspace-panel-empty-start", in: panel)?.isHiddenOrHasHiddenAncestor != false)
        #expect(try #require(view(identifier: "panel-split-right", in: panel)).isHidden == false)
    }

    /// A panel window closes when its last pane goes, so it never shows the block.
    @Test func globalPanelWindowShowsNoBlockWhenEmptied() {
        let panel = WorkspacePanelView(scope: .globalWindow(panelWindowID: "window-1"))
        panel.apply(layout: PanelLayout(), titlesByTabID: [:])
        #expect(button(identifier: "workspace-panel-empty-start", in: panel)?.isHiddenOrHasHiddenAncestor != false)
        #expect(button(identifier: "workspace-panel-empty-new-terminal", in: panel)?.isHiddenOrHasHiddenAncestor != false)
    }

    /// The workspace-detail fast path refreshes the block without re-rendering the layout: a workspace
    /// that finishes starting while its panel is empty drops Start there and then.
    @Test func inPlaceRefreshFollowsTheRunState() throws {
        let panel = WorkspacePanelView(scope: .workspace(deviceID: "device", workspaceID: "w1"))
        panel.apply(layout: PanelLayout(), titlesByTabID: [:], emptyState: state(offersStart: true))
        #expect(button(identifier: "workspace-panel-empty-start", in: panel) != nil)

        panel.updateEmptyState(state(offersStart: false))
        #expect(button(identifier: "workspace-panel-empty-start", in: panel) == nil)
        #expect(try #require(button(identifier: "workspace-panel-empty-new-terminal", in: panel)).isHiddenOrHasHiddenAncestor == false)
    }

    /// The same refresh on a panel that has tabs must not raise the block over them.
    @Test func inPlaceRefreshLeavesAPanelWithTabsAlone() {
        let panel = WorkspacePanelView(scope: .workspace(deviceID: "device", workspaceID: "w1"))
        panel.apply(layout: layout(tabID: "tab-1"), titlesByTabID: ["tab-1": "shell"], emptyState: state(offersStart: true))
        panel.updateEmptyState(state(offersStart: false))
        #expect(button(identifier: "workspace-panel-empty-new-terminal", in: panel)?.isHiddenOrHasHiddenAncestor != false)
    }
}
