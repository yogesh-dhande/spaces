import AppKit
import spacesterminalcore
import spacesterminalghostty
import spacesterminalui

@MainActor private final class TerminalPanePlaceholderView: NSView { override var acceptsFirstResponder: Bool { true } }

/// Temporary pane content shown while Device API credentials are prepared off the
/// main actor. The panel owns it exactly like live terminal content, then replaces it
/// in place once `TerminalPaneContentController` can be constructed without blocking.
@MainActor final class TerminalPanePlaceholderContentController: TerminalPaneContentHosting {
    let descriptor: PaneContentDescriptor
    let workspaceID: String
    let sessionID: String
    /// The name the session was opened under. The placeholder's own labels describe the wait, so the
    /// tab hosting it is titled from this instead.
    private let requestTitle: String
    private let rootView = TerminalPanePlaceholderView()
    private let spinner = NSProgressIndicator()
    private let titleLabel = NSTextField(labelWithString: "Preparing terminal...")
    private let detailLabel = NSTextField(labelWithString: "Preparing the terminal session.")
    private(set) var requestsOwnershipWhenReady = false

    var onTitleChanged: ((String) -> Void)?

    init(request: AppKitController.DeviceTerminalOpenRequest, deviceID: String) {
        workspaceID = request.workspaceID
        sessionID = request.sessionID
        requestTitle = request.title
        descriptor = .terminalSession(deviceID: deviceID, sessionID: request.sessionID)
        buildView(title: request.title)
    }

    var contentView: NSView { rootView }
    var displayTitle: String { requestTitle }
    var canPerformFindActions: Bool { false }

    func activate(focus: Bool) { if focus { _ = makeContentFirstResponder() } }
    func deactivate() {}
    func close() { spinner.stopAnimation(nil) }
    func closeForSessionTermination() { close() }
    func makeContentFirstResponder() -> Bool { rootView.window?.makeFirstResponder(rootView) == true }
    func handleKeyEvent(_: NSEvent) -> Bool { false }
    func handleCommandKeyEquivalent(_: NSEvent) -> Bool { false }
    func applyAppearance(_: ThemeAppearance) {}

    /// A placeholder shows no terminal content; the real pane that replaces it is created with the
    /// current size.
    func applyTerminalTextSize(_: TerminalTextSize) {}
    func requestOwnershipIfNeeded() { requestsOwnershipWhenReady = true }

    /// A placeholder has no session attachment at all — its pane is still resolving — so a re-show of it
    /// must run the full open path.
    var holdsOwnerAttachedSurface: Bool { false }
    func find(_: Any?) {}
    func findNext(_: Any?) {}
    func findPrevious(_: Any?) {}
    func useSelectionForFind(_: Any?) {}
    func performShortcutForTesting(action _: String, text _: String?) {}
    func debugRefreshStateForTesting(skipOwnerAttach _: Bool) {}

    func owns(responder: NSResponder) -> Bool {
        var current = responder as? NSView
        while let candidate = current {
            if candidate === rootView { return true }
            current = candidate.superview
        }
        return false
    }

    func setAccessibilityRuntimeTargetName(_ name: String) { rootView.setAccessibilityLabel(name) }

    func fail(error: Error) { fail(message: String(describing: error)) }

    func fail(message: String) {
        spinner.stopAnimation(nil)
        spinner.isHidden = true
        titleLabel.stringValue = "Terminal unavailable"
        detailLabel.stringValue = message
        onTitleChanged?(titleLabel.stringValue)
    }

    func debugStateDump() -> TerminalSessionWindowDebugState {
        TerminalSessionWindowDebugState(
            renderedOutput: "\(titleLabel.stringValue)\n\(detailLabel.stringValue)", visibleSurfaceOutput: nil, surfaceSelectionText: nil,
            showsTerminalSurface: false, showsTextRenderer: true, rendererSummary: "Renderer: preparing", summary: detailLabel.stringValue,
            state: titleLabel.stringValue,
            windowTitle: rootView.window?.title ?? "", didCloseWindow: false, surfaceColumns: nil, surfaceRows: nil,
            windowIsKey: rootView.window?.isKeyWindow == true, firstResponderTypeName: debugFirstResponderTypeName, searchVisible: false,
            searchQuery: "", searchTotal: nil, searchSelected: nil, attachmentMode: TerminalAttachmentMode.owner.rawValue,
            takeoverPending: requestsOwnershipWhenReady, takeoverButtonVisible: false, takeoverButtonEnabled: false, takeoverMessage: "")
    }

    private func buildView(title: String) {
        rootView.setAccessibilityIdentifier("terminal-pane-\(sessionID)")
        rootView.setAccessibilityLabel(title)
        rootView.wantsLayer = true
        bindAppearanceReactiveLayer(rootView) { view in view.layer?.backgroundColor = NSColor.activeTheme(\.terminal.background).cgColor }

        spinner.style = .spinning
        spinner.controlSize = .regular
        spinner.startAnimation(nil)
        spinner.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = Typography.sectionTitle
        titleLabel.textColor = .activeTheme(\.terminal.foreground)
        titleLabel.lineBreakMode = .byTruncatingTail

        detailLabel.font = Typography.rowDetail
        detailLabel.textColor = .activeTheme(\.terminal.foreground).withAlphaComponent(0.72)
        detailLabel.lineBreakMode = .byWordWrapping
        detailLabel.maximumNumberOfLines = 3

        let labelStack = NSStackView(views: [titleLabel, detailLabel])
        labelStack.orientation = .vertical
        labelStack.alignment = .leading
        labelStack.spacing = 3
        labelStack.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [spinner, labelStack])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false

        rootView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: rootView.centerXAnchor), stack.centerYAnchor.constraint(equalTo: rootView.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: rootView.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: rootView.trailingAnchor, constant: -24),
            labelStack.widthAnchor.constraint(lessThanOrEqualToConstant: 420),
        ])
    }

    private var debugFirstResponderTypeName: String? {
        guard let firstResponder = rootView.window?.firstResponder else { return nil }
        return String(describing: type(of: firstResponder))
    }
}
