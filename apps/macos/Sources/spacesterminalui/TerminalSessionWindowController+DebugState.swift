import AppKit
import Foundation
import spacesterminalcore
import spacesterminalghostty

/// Debug/testing accessors preserved on the window controller so existing callers
/// and tests keep working through the shell; session-content accessors forward to
/// the embedded pane, window-level accessors stay implemented here.
extension TerminalSessionWindowController {
    public func debugRefreshStateForTesting(skipOwnerAttach: Bool = false) { pane.debugRefreshStateForTesting(skipOwnerAttach: skipOwnerAttach) }

    public func debugStateDump() -> TerminalSessionWindowDebugState { pane.debugStateDump() }

    var debugRenderedOutput: String { pane.debugRenderedOutput }
    var debugShowsTerminalSurface: Bool { pane.debugShowsTerminalSurface }
    var debugShowsTextRenderer: Bool { pane.debugShowsTextRenderer }
    var debugRendererSummary: String { pane.debugRendererSummary }
    var debugSummary: String { pane.debugSummary }
    var debugState: String { pane.debugState }
    var debugWindowTitle: String { window?.title ?? "" }
    var debugWindowRepresentedPath: String? { window?.representedURL?.path }
    var debugWindowFrame: NSRect { window?.frame ?? .zero }
    func debugShouldDeferInitialOwnerPresentationInProduction(wasVisible: Bool = false) -> Bool {
        pane.shouldDeferInitialOwnerPresentation(wasVisible: wasVisible, runningUnderXCTest: false)
    }
    public var attachmentMode: TerminalAttachmentMode { pane.attachmentMode }
    public var didClose: Bool { pane.didCloseWindow }
    public var terminalSessionID: String { pane.sessionID }
    var debugDidCloseWindow: Bool { pane.debugDidCloseWindow }
    func debugForceRefresh() { pane.debugForceRefresh() }
    func debugForceRefreshSkippingOwnerAttach() { pane.debugForceRefreshSkippingOwnerAttach() }
    func debugAttachLocalClientIfNeeded() { pane.debugAttachLocalClientIfNeeded() }
    func debugFlushPendingWindowFramePersistence() async { await pendingWindowFramePersistTask?.value }
    public var clientID: String { pane.clientID }
    var lastObservedRuntimeState: TerminalSessionRuntimeState? { pane.lastObservedRuntimeState }
    var debugTakeoverPending: Bool { pane.debugTakeoverPending }
    func debugSetTakeoverTaskStartedAt(_ date: Date?) { pane.debugSetTakeoverTaskStartedAt(date) }
    var debugShowsInlineControls: Bool { pane.debugShowsInlineControls }
    var debugShowsTakeoverButton: Bool { pane.debugShowsTakeoverButton }
    var debugInlineInputEnabled: Bool { pane.debugInlineInputEnabled }
    var debugTakeoverEnabled: Bool { pane.debugTakeoverEnabled }
    var debugShowsRendererLabel: Bool { pane.debugShowsRendererLabel }
    var debugShowsTitleLabel: Bool { pane.debugShowsTitleLabel }
    var debugShowsSummaryLabel: Bool { pane.debugShowsSummaryLabel }
    var debugShowsStateLabel: Bool { pane.debugShowsStateLabel }
    var debugShowsHeader: Bool { pane.debugShowsHeader }
    var debugRuntimeToolbarTitle: String { pane.debugRuntimeToolbarTitle }
    var debugShowsRuntimeToolbarTitle: Bool { pane.debugShowsRuntimeToolbarTitle }
    var debugShowsRuntimeToolbar: Bool { pane.debugShowsRuntimeToolbar }
    var debugShowsRuntimeRunButton: Bool { pane.debugShowsRuntimeRunButton }
    var debugShowsRuntimeStopButton: Bool { pane.debugShowsRuntimeStopButton }
    var debugShowsRuntimeRestartButton: Bool { pane.debugShowsRuntimeRestartButton }
    var debugRuntimeToolbarTrailingGap: CGFloat { pane.debugRuntimeToolbarTrailingGap }
    func debugRunRuntimeToolbarAction() { pane.debugRunRuntimeToolbarAction() }
    func debugStopRuntimeToolbarAction() { pane.debugStopRuntimeToolbarAction() }
    func debugRestartRuntimeToolbarAction() { pane.debugRestartRuntimeToolbarAction() }
    var debugShowsTakeoverMessage: Bool { pane.debugShowsTakeoverMessage }
    var debugTakeoverMessage: String { pane.debugTakeoverMessage }
    var debugInputStatus: String { pane.debugInputStatus }
    var debugShowsInputStatus: Bool { pane.debugShowsInputStatus }
    func debugSubmitInput() { pane.debugSubmitInput() }
    var debugInputFieldValue: String { pane.debugInputFieldValue }
    func debugSimulateApplicationDidBecomeActive() { pane.debugSimulateApplicationDidBecomeActive() }
    func debugSimulateApplicationDidResignActive() { pane.debugSimulateApplicationDidResignActive() }
    func debugSimulateAttachmentStateDidChange() { pane.debugSimulateAttachmentStateDidChange() }
    func debugSimulateSessionMetadataDidChange() { pane.debugSimulateSessionMetadataDidChange() }
    func debugSimulateRuntimeStateDidChange() { pane.debugSimulateRuntimeStateDidChange() }
    func debugSimulateOutputDidChange() { pane.debugSimulateOutputDidChange() }
    func debugSelectRenderedRange(_ range: NSRange) { pane.debugSelectRenderedRange(range) }
    var debugSelectedRange: NSRange { pane.debugSelectedRange }
    func debugScrollOutputToOffsetFromBottom(_ offset: CGFloat) { pane.debugScrollOutputToOffsetFromBottom(offset) }
    var debugOutputOffsetFromBottom: CGFloat { pane.debugOutputOffsetFromBottom }
    func debugScrollOutputHorizontally(to offset: CGFloat) { pane.debugScrollOutputHorizontally(to: offset) }
    var debugOutputHorizontalOffset: CGFloat { pane.debugOutputHorizontalOffset }
    var debugContentWidth: CGFloat { window?.contentView?.frame.width ?? 0 }
    var debugTerminalContainerWidth: CGFloat { pane.debugTerminalContainerWidth }
    var debugBodyWidth: CGFloat { pane.debugBodyWidth }
    var debugTakeoverContainerWidth: CGFloat { pane.debugTakeoverContainerWidth }
    var debugFirstResponderTypeName: String? { pane.debugFirstResponderTypeName }
    var debugFirstResponderTargetsInputField: Bool { pane.debugFirstResponderTargetsInputField }
    var debugFirstResponderTargetsOutputView: Bool { pane.debugFirstResponderTargetsOutputView }
    @discardableResult func debugSendGhosttyScroll(horizontal: CGFloat = 0, vertical: CGFloat) -> Bool {
        pane.debugSendGhosttyScroll(horizontal: horizontal, vertical: vertical)
    }
    var debugGhosttyHasRenderableSurface: Bool { pane.debugGhosttyHasRenderableSurface }
    var debugGhosttySurfaceRefreshRequestCount: Int { pane.debugGhosttySurfaceRefreshRequestCount }
    var debugTerminalSearchState: GhosttyTerminalSearchDebugState { pane.debugTerminalSearchState }
    var debugTerminalSearchVisible: Bool { pane.debugTerminalSearchVisible }
    var debugTerminalSearchQuery: String { pane.debugTerminalSearchQuery }
    var debugOutputDisablesSmartSubstitutions: Bool { pane.debugOutputDisablesSmartSubstitutions }
}
