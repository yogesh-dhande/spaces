import AppKit
import spacesterminalcore
import spacesterminalui

@testable import spacesui

/// A terminal pane's content with no daemon behind it, installed through
/// `PanelCoordinator.installContentControllerForTesting` so a test can place and focus terminal panes
/// without dialing a session stream. Records `requestOwnershipIfNeeded()`/`makeContentFirstResponder()`
/// calls; every other member is a trivial stub, since the suites using it drive pane placement and focus
/// decisions, never a pane's real terminal content.
@MainActor final class RecordingTerminalPaneContentStub: TerminalPaneContentHosting {
    let descriptor: PaneContentDescriptor
    let workspaceID: String
    let sessionID: String
    var holdsOwnerAttachedSurface = false
    private(set) var requestOwnershipCallCount = 0
    private(set) var makeContentFirstResponderCallCount = 0

    var onTitleChanged: ((String) -> Void)?
    var displayTitle: String { "stub" }
    lazy var contentView: NSView = NSView()

    init(descriptor: PaneContentDescriptor, workspaceID: String, sessionID: String) {
        self.descriptor = descriptor
        self.workspaceID = workspaceID
        self.sessionID = sessionID
    }

    func activate(focus: Bool) {}
    func deactivate() {}
    func close() {}
    func closeForSessionTermination() {}

    @discardableResult func makeContentFirstResponder() -> Bool {
        makeContentFirstResponderCallCount += 1
        return true
    }

    func owns(responder: NSResponder) -> Bool { false }
    func handleKeyEvent(_ event: NSEvent) -> Bool { false }
    func handleCommandKeyEquivalent(_ event: NSEvent) -> Bool { false }

    func applyAppearance(_ appearance: ThemeAppearance) {}
    func applyTerminalTextSize(_ size: TerminalTextSize) {}
    func setAccessibilityRuntimeTargetName(_ name: String) {}
    func applyAgentBrief(_ brief: AgentBriefPresentation?) {}

    func requestOwnershipIfNeeded() { requestOwnershipCallCount += 1 }

    var canPerformFindActions: Bool { false }
    func find(_ sender: Any?) {}
    func findNext(_ sender: Any?) {}
    func findPrevious(_ sender: Any?) {}
    func useSelectionForFind(_ sender: Any?) {}

    func performShortcutForTesting(action: String, text: String?) {}
    func debugRefreshStateForTesting(skipOwnerAttach: Bool) {}
    func debugStateDump() -> TerminalSessionWindowDebugState { fatalError("not exercised by these tests") }
}
