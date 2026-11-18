import Testing
import spacesterminalcore

@testable import spacesui

/// Covers which sidebar row is marked as the keystroke target and how focus moves the selection.
@Suite struct SidebarFocusMarkerTests {
    private func location(
        workspace: String = "ws-a", project: String = "proj-a", collapsed: Bool = false,
        kind: AppKitController.WorkspaceRunShortcutTarget.Kind = .window
    ) -> SidebarFocusMarker.RowLocation {
        SidebarFocusMarker.RowLocation(workspaceID: workspace, projectID: project, isProjectCollapsed: collapsed, kind: kind)
    }

    @Test func aFocusedTerminalIsMarked() {
        let outcome = SidebarFocusMarker.outcome(
            previousMarkedSessionID: nil, focusedSessionID: "s1", location: location(), selectedWorkspaceID: "ws-a")
        #expect(outcome.markedSessionID == "s1")
        #expect(outcome.selectWorkspaceID == nil)
        #expect(outcome.expandProjectID == nil)
    }

    @Test func focusLeavingTerminalsKeepsTheLastMarker() {
        // A code pane, the palette, a dialog, or another app all arrive as no focused terminal.
        let outcome = SidebarFocusMarker.outcome(previousMarkedSessionID: "s1", focusedSessionID: nil, location: nil, selectedWorkspaceID: "ws-a")
        #expect(outcome.markedSessionID == "s1")
        #expect(outcome.selectWorkspaceID == nil)
        #expect(outcome.expandProjectID == nil)
    }

    @Test func aNewTerminalReplacesTheMarker() {
        let outcome = SidebarFocusMarker.outcome(
            previousMarkedSessionID: "s1", focusedSessionID: "s2", location: location(), selectedWorkspaceID: "ws-a")
        #expect(outcome.markedSessionID == "s2")
    }

    @Test func aFocusedTerminalWithoutARowMarksNothingAndLeavesSelectionAlone() {
        // The old row must not stay marked: it no longer receives the keystrokes.
        let outcome = SidebarFocusMarker.outcome(previousMarkedSessionID: "s1", focusedSessionID: "s2", location: nil, selectedWorkspaceID: "ws-a")
        #expect(outcome.markedSessionID == "s2")
        #expect(outcome.selectWorkspaceID == nil)
        #expect(!SidebarFocusMarker.marksRow(kind: .window, sessionID: "s1", markedSessionID: outcome.markedSessionID))
    }

    @Test func aClosedTerminalsRowIsNotMarkedAndNoOtherRowTakesItsPlace() {
        #expect(!SidebarFocusMarker.marksRow(kind: .window, sessionID: "s2", markedSessionID: "s1"))
        #expect(!SidebarFocusMarker.marksRow(kind: .agent, sessionID: nil, markedSessionID: "s1"))
    }

    @Test func everyTerminalBackedKindCanBeMarked() {
        for kind: AppKitController.WorkspaceRunShortcutTarget.Kind in [.agent, .process, .pinnedThread, .window] {
            #expect(SidebarFocusMarker.marksRow(kind: kind, sessionID: "s1", markedSessionID: "s1"))
        }
    }

    @Test func browserSessionsAreNeverMarked() {
        #expect(!SidebarFocusMarker.marksRow(kind: .browser, sessionID: "s1", markedSessionID: "s1"))
        let outcome = SidebarFocusMarker.outcome(
            previousMarkedSessionID: nil, focusedSessionID: "s1", location: location(workspace: "ws-b", kind: .browser), selectedWorkspaceID: "ws-a")
        #expect(outcome.selectWorkspaceID == nil)
    }

    @Test func focusInAnotherWorkspaceMovesTheSelection() {
        let outcome = SidebarFocusMarker.outcome(
            previousMarkedSessionID: "s1", focusedSessionID: "s2", location: location(workspace: "ws-b"), selectedWorkspaceID: "ws-a")
        #expect(outcome.markedSessionID == "s2")
        #expect(outcome.selectWorkspaceID == "ws-b")
        #expect(outcome.expandProjectID == nil)
    }

    @Test func focusWhileNoWorkspaceIsSelectedLeavesTheSelectionAlone() {
        // Alerts, Automations, Resources, Prompts, and a project's page all show with no workspace selected.
        let outcome = SidebarFocusMarker.outcome(
            previousMarkedSessionID: nil, focusedSessionID: "s1", location: location(workspace: "ws-b", project: "proj-b", collapsed: true),
            selectedWorkspaceID: nil)
        #expect(outcome.markedSessionID == "s1")
        #expect(outcome.selectWorkspaceID == nil)
        #expect(outcome.expandProjectID == "proj-b")
    }

    /// The selection a focus gain triggers restores the target workspace's panel while another window's
    /// terminal holds the keyboard. A `.focus` restore would activate the restored pane once its content
    /// is prepared and make the main window key, so the intent must withhold the caret, on the
    /// asynchronous preparation path too. The wiring through the outline's selection callback needs a
    /// live outline view, so only the decision is unit-tested.
    @Test func focusDrivenSelectionRestoresPanesWithoutTakingTheCaret() {
        let intent = SidebarFocusMarker.selectionFocusIntent
        #expect(intent == .withoutFocus)
        #expect(TerminalPaneService.terminalPanePreparationFocusAction(focusIntent: intent, preparedPaneHoldsKeyboardFocus: false) == .none)
    }

    @Test func aCollapsedProjectExpandsSoTheMarkedRowIsVisible() {
        let outcome = SidebarFocusMarker.outcome(
            previousMarkedSessionID: nil, focusedSessionID: "s1", location: location(workspace: "ws-b", project: "proj-b", collapsed: true),
            selectedWorkspaceID: "ws-a")
        #expect(outcome.selectWorkspaceID == "ws-b")
        #expect(outcome.expandProjectID == "proj-b")
    }
}
