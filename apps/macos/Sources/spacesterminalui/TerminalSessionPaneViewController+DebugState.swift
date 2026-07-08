import AppKit
import Foundation
import spacesterminalcore
import spacesterminalghostty

/// Snapshot of a pane's rendered/debug state for the dump IPC and tests. The name and
/// field set predate the pane hosting model (panes once lived in their own windows);
/// the shape is a parsed E2E surface, so it stays stable.
public struct TerminalSessionWindowDebugState: Sendable, Codable, Equatable {
    public let renderedOutput: String
    public let visibleSurfaceOutput: String?
    public let showsTerminalSurface: Bool
    public let showsTextRenderer: Bool
    public let rendererSummary: String
    public let summary: String
    public let state: String
    public let windowTitle: String
    public let didCloseWindow: Bool
    public let surfaceColumns: Int?
    public let surfaceRows: Int?
    public let windowIsKey: Bool
    public let firstResponderTypeName: String?
    public let searchVisible: Bool
    public let searchQuery: String
    public let searchTotal: Int?
    public let searchSelected: Int?
    public let attachmentMode: String
    public let takeoverPending: Bool
    public let takeoverButtonVisible: Bool
    public let takeoverButtonEnabled: Bool
    public let takeoverMessage: String

    public init(
        renderedOutput: String, visibleSurfaceOutput: String?, showsTerminalSurface: Bool, showsTextRenderer: Bool, rendererSummary: String,
        summary: String, state: String, windowTitle: String, didCloseWindow: Bool, surfaceColumns: Int?, surfaceRows: Int?, windowIsKey: Bool,
        firstResponderTypeName: String?, searchVisible: Bool, searchQuery: String, searchTotal: Int?, searchSelected: Int?, attachmentMode: String,
        takeoverPending: Bool, takeoverButtonVisible: Bool, takeoverButtonEnabled: Bool, takeoverMessage: String
    ) {
        self.renderedOutput = renderedOutput
        self.visibleSurfaceOutput = visibleSurfaceOutput
        self.showsTerminalSurface = showsTerminalSurface
        self.showsTextRenderer = showsTextRenderer
        self.rendererSummary = rendererSummary
        self.summary = summary
        self.state = state
        self.windowTitle = windowTitle
        self.didCloseWindow = didCloseWindow
        self.surfaceColumns = surfaceColumns
        self.surfaceRows = surfaceRows
        self.windowIsKey = windowIsKey
        self.firstResponderTypeName = firstResponderTypeName
        self.searchVisible = searchVisible
        self.searchQuery = searchQuery
        self.searchTotal = searchTotal
        self.searchSelected = searchSelected
        self.attachmentMode = attachmentMode
        self.takeoverPending = takeoverPending
        self.takeoverButtonVisible = takeoverButtonVisible
        self.takeoverButtonEnabled = takeoverButtonEnabled
        self.takeoverMessage = takeoverMessage
    }
}

extension TerminalSessionPaneViewController {
    public func debugRefreshStateForTesting(skipOwnerAttach: Bool = false) {
        if skipOwnerAttach { debugForceRefreshSkippingOwnerAttach() } else { debugForceRefresh() }
    }

    public func debugStateDump() -> TerminalSessionWindowDebugState {
        let renderedOutput: String
        let visibleSurfaceOutput = !terminalContainer.isHidden ? ghosttyRendererHost?.debugVisibleSurfaceText() : nil
        if !terminalContainer.isHidden { ghosttyRendererHost?.prepareRenderStateExport() }
        let surfaceSnapshot = ghosttyRendererHost?.snapshot() ?? ghosttyRendererHost?.sessionSnapshot()
        if !terminalContainer.isHidden, let surfaceSnapshot,
            TerminalRemoteSessionStatePolicy.hasVisibleScreenContent(snapshot: surfaceSnapshot, snapshotText: nil)
        {
            renderedOutput = GhosttyTerminalSnapshotGrid.fullPlainText(for: surfaceSnapshot)
        } else if !terminalContainer.isHidden, let visibleText = visibleSurfaceOutput, !visibleText.isEmpty {
            renderedOutput = visibleText
        } else if !terminalContainer.isHidden, let sessionSnapshotText = ghosttyRendererHost?.sessionSnapshotText(), !sessionSnapshotText.isEmpty {
            renderedOutput = sessionSnapshotText
        } else {
            renderedOutput = outputView.string
        }
        let searchState = debugTerminalSearchState
        return .init(
            renderedOutput: renderedOutput, visibleSurfaceOutput: visibleSurfaceOutput, showsTerminalSurface: !terminalContainer.isHidden,
            showsTextRenderer: !outputScrollView.isHidden, rendererSummary: rendererLabel.stringValue, summary: summaryLabel.stringValue,
            state: stateLabel.stringValue, windowTitle: window?.title ?? "", didCloseWindow: didCloseWindow, surfaceColumns: surfaceSnapshot?.columns,
            surfaceRows: surfaceSnapshot?.rows, windowIsKey: window?.isKeyWindow == true, firstResponderTypeName: debugFirstResponderTypeName,
            searchVisible: searchState.isVisible, searchQuery: searchState.query, searchTotal: searchState.total,
            searchSelected: searchState.selected, attachmentMode: preferredAttachmentMode.rawValue, takeoverPending: takeoverTask != nil,
            takeoverButtonVisible: !takeoverButton.isHidden, takeoverButtonEnabled: takeoverButton.isEnabled,
            takeoverMessage: takeoverMessageLabel.stringValue)
    }

    var debugRenderedOutput: String { outputView.string }
    var debugShowsTerminalSurface: Bool { !terminalContainer.isHidden }
    var debugShowsTextRenderer: Bool { !outputScrollView.isHidden }
    var debugRendererSummary: String { rendererLabel.stringValue }
    var debugSummary: String { summaryLabel.stringValue }
    var debugState: String { stateLabel.stringValue }
    public var attachmentMode: TerminalAttachmentMode { preferredAttachmentMode }
    var debugDidCloseWindow: Bool { didCloseWindow }
    func debugForceRefresh() { refreshNow() }
    func debugForceRefreshSkippingOwnerAttach() { refreshNow(allowGhosttyOwnerAttach: false) }
    func debugAttachLocalClientIfNeeded() { attachLocalClientIfNeeded() }
    public var clientID: String { client.id }
    var debugTakeoverPending: Bool { takeoverTask != nil }
    func debugSetTakeoverTaskStartedAt(_ date: Date?) { takeoverTaskStartedAt = date }
    var debugShowsInlineControls: Bool { !inputRowStackView.isHidden }
    var debugShowsTakeoverButton: Bool { !takeoverButton.isHidden }
    var debugInlineInputEnabled: Bool { inputField.isEnabled }
    var debugTakeoverEnabled: Bool { takeoverButton.isEnabled }
    var debugShowsRendererLabel: Bool { !rendererLabel.isHidden }
    var debugShowsTitleLabel: Bool { !titleLabel.isHidden }
    var debugShowsSummaryLabel: Bool { !summaryLabel.isHidden }
    var debugShowsStateLabel: Bool { !stateLabel.isHidden }
    var debugShowsHeader: Bool { !headerStackView.isHidden }
    var debugShowsTakeoverMessage: Bool { !takeoverMessageLabel.isHidden }
    var debugTakeoverMessage: String { takeoverMessageLabel.stringValue }
    var debugInputStatus: String { inputStatusLabel.stringValue }
    var debugShowsInputStatus: Bool { !inputStatusLabel.isHidden }
    func debugSubmitInput() { submitInput() }
    var debugInputFieldValue: String { inputField.stringValue }
    func debugSimulateApplicationDidBecomeActive() { NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp) }
    func debugSimulateApplicationDidResignActive() { NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp) }
    func debugSimulateAttachmentStateDidChange() {
        TerminalSessionNotification.post(.spacesTerminalAttachmentStateDidChange, sessionID: sessionID)
    }
    func debugSimulateSessionMetadataDidChange() {
        TerminalSessionNotification.post(.spacesTerminalSessionMetadataDidChange, sessionID: sessionID)
    }
    func debugSimulateRuntimeStateDidChange() {
        TerminalSessionNotification.post(.spacesTerminalRuntimeStateDidChange, sessionID: sessionID)
    }
    func debugSimulateOutputDidChange() {
        TerminalSessionNotification.post(.spacesTerminalOutputDidChange, sessionID: sessionID)
        refreshNow()
    }
    func debugSelectRenderedRange(_ range: NSRange) { outputView.setSelectedRange(range) }
    var debugSelectedRange: NSRange { outputView.selectedRange() }
    func debugScrollOutputToOffsetFromBottom(_ offset: CGFloat) {
        guard let documentView = outputScrollView.documentView else { return }
        let visibleRect = outputScrollView.contentView.documentVisibleRect
        let maxOriginY = max(0, documentView.bounds.height - visibleRect.height)
        let targetOriginY = max(0, maxOriginY - offset)
        outputScrollView.contentView.scroll(to: NSPoint(x: 0, y: min(targetOriginY, maxOriginY)))
        outputScrollView.reflectScrolledClipView(outputScrollView.contentView)
    }
    var debugOutputOffsetFromBottom: CGFloat {
        let visibleRect = outputScrollView.contentView.documentVisibleRect
        return max(0, outputView.bounds.height - visibleRect.maxY)
    }
    func debugScrollOutputHorizontally(to offset: CGFloat) {
        guard let documentView = outputScrollView.documentView else { return }
        let visibleRect = outputScrollView.contentView.documentVisibleRect
        let maxOriginX = max(0, documentView.bounds.width - visibleRect.width)
        outputScrollView.contentView.scroll(to: NSPoint(x: max(0, min(offset, maxOriginX)), y: visibleRect.minY))
        outputScrollView.reflectScrolledClipView(outputScrollView.contentView)
    }
    var debugOutputHorizontalOffset: CGFloat { outputScrollView.contentView.documentVisibleRect.minX }
    var debugTerminalContainerWidth: CGFloat { terminalContainer.frame.width }
    var debugBodyWidth: CGFloat { bodyStackView.frame.width }
    var debugTakeoverContainerWidth: CGFloat { takeoverContainerView.frame.width }
    var debugFirstResponderTypeName: String? {
        guard let firstResponder = window?.firstResponder else { return nil }
        return String(describing: type(of: firstResponder))
    }
    var debugFirstResponderTargetsInputField: Bool {
        guard let fieldEditor = inputField.currentEditor() else { return false }
        return window?.firstResponder === fieldEditor
    }
    var debugFirstResponderTargetsOutputView: Bool { window?.firstResponder === outputView }
    @discardableResult func debugSendGhosttyScroll(horizontal: CGFloat = 0, vertical: CGFloat) -> Bool {
        ghosttyRendererHost?.sendScroll(horizontal: horizontal, vertical: vertical) ?? false
    }
    var debugGhosttyHasRenderableSurface: Bool { ghosttyRendererHost?.hasRenderableSurface() ?? false }
    var debugGhosttySurfaceRefreshRequestCount: Int { ghosttyRendererHost?.debugSurfaceRefreshRequestCount ?? 0 }
    var debugTerminalSearchState: GhosttyTerminalSearchDebugState {
        ghosttyRendererHost?.debugSearchState ?? .init(isVisible: false, query: "", total: nil, selected: nil)
    }
    var debugTerminalSearchVisible: Bool { debugTerminalSearchState.isVisible }
    var debugTerminalSearchQuery: String { debugTerminalSearchState.query }
    var debugOutputDisablesSmartSubstitutions: Bool {
        !outputView.isAutomaticQuoteSubstitutionEnabled && !outputView.isAutomaticDashSubstitutionEnabled
            && !outputView.isAutomaticTextReplacementEnabled && !outputView.isAutomaticSpellingCorrectionEnabled
            && !outputView.isContinuousSpellCheckingEnabled && !outputView.isGrammarCheckingEnabled && !outputView.isAutomaticTextCompletionEnabled
    }
}
