import AppKit
import Carbon
import CoreImage
import Foundation
import spacesclientcore
import spacesdeviceapi
import spacesdevicecore
import spacesterminalcore
import spacesterminalghostty
import spacesterminalui
import systembridge
import workspacecore

/// Owns the in-window transient overlays: the operation-progress HUD shown during
/// long add-project/add-workspace/git operations, and the window-issue toast and
/// blocking modal. `AppKitController` holds a single instance and delegates these
/// overlays to it. The controller reaches back into the host for the window,
/// selection state, and shared services via `host`.
@MainActor final class TransientOverlaysController: NSObject {
    unowned let host: AppKitController

    init(host: AppKitController) {
        self.host = host
        super.init()
    }

    private var operationProgressOverlay: NSVisualEffectView?
    private var operationProgressOverlayTitleLabel: NSTextField?
    private var operationProgressOverlayDetailLabel: NSTextField?
    private var operationProgressContext: OperationProgressContext?
    private var windowIssueToastOverlay: NSView?
    private var windowIssueToastTitleLabel: NSTextField?
    private var windowIssueToastDetailLabel: NSTextField?
    private var windowIssueToastActionButton: NSButton?
    private var windowIssueToastActionHandler: (() -> Void)?
    private var windowIssueToastDismissTask: Task<Void, Never>?
    private var cycleModeHUDOverlay: NSView?
    private var cycleModeHUDTitleLabel: NSTextField?
    private var cycleModeHUDSummaryLabel: NSTextField?
    private var cycleModeHUDChordLabel: NSTextField?
    private var cycleModeHUDDismissTask: Task<Void, Never>?
    /// How long the cycling-mode HUD stays up. Long enough to read three short lines, short enough
    /// that it is gone before the next cycle press lands.
    private static let cycleModeHUDVisibleSeconds: Double = 1

    enum OperationProgressContext: Equatable {
        case workspace(String)
        case project(String)
        case global
    }

    func showOperationProgressOverlay(message: String, detail: String, context: OperationProgressContext) {
        guard let contentView = host.window?.contentView else { return }
        let overlay: NSVisualEffectView
        let titleLabel: NSTextField
        let detailLabel: NSTextField
        if let existingOverlay = operationProgressOverlay, let existingTitleLabel = operationProgressOverlayTitleLabel,
            let existingDetailLabel = operationProgressOverlayDetailLabel
        {
            overlay = existingOverlay
            titleLabel = existingTitleLabel
            detailLabel = existingDetailLabel
        } else {
            overlay = NSVisualEffectView()
            overlay.material = .hudWindow
            overlay.blendingMode = .withinWindow
            overlay.state = .active
            overlay.wantsLayer = true
            overlay.layer?.cornerRadius = UIRadius.large
            overlay.layer?.borderWidth = 1
            bindAppearanceReactiveLayer(overlay) { [unowned host] view in
                view.layer?.borderColor = host.sidebar.sidebarCardBorderColor(isSelected: false).cgColor
            }
            overlay.translatesAutoresizingMaskIntoConstraints = false

            let stack = NSStackView()
            stack.orientation = .horizontal
            stack.alignment = .top
            stack.spacing = 10
            stack.translatesAutoresizingMaskIntoConstraints = false

            let spinner = NSProgressIndicator()
            spinner.style = .spinning
            spinner.controlSize = .small
            spinner.startAnimation(nil)
            spinner.translatesAutoresizingMaskIntoConstraints = false
            spinner.setContentHuggingPriority(.required, for: .horizontal)
            stack.addArrangedSubview(spinner)

            let labelStack = NSStackView()
            labelStack.orientation = .vertical
            labelStack.alignment = .leading
            labelStack.spacing = 2
            labelStack.translatesAutoresizingMaskIntoConstraints = false

            titleLabel = NSTextField(labelWithString: "")
            titleLabel.font = Typography.compactTitle
            titleLabel.textColor = .labelColor
            titleLabel.maximumNumberOfLines = 1
            labelStack.addArrangedSubview(titleLabel)

            detailLabel = NSTextField(labelWithString: "")
            detailLabel.font = Typography.metadata
            detailLabel.textColor = .secondaryLabelColor
            detailLabel.maximumNumberOfLines = 2
            labelStack.addArrangedSubview(detailLabel)

            stack.addArrangedSubview(labelStack)
            overlay.addSubview(stack)
            contentView.addSubview(overlay)

            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: overlay.leadingAnchor, constant: 12),
                stack.trailingAnchor.constraint(equalTo: overlay.trailingAnchor, constant: -12),
                stack.topAnchor.constraint(equalTo: overlay.topAnchor, constant: 10),
                stack.bottomAnchor.constraint(equalTo: overlay.bottomAnchor, constant: -10),

                overlay.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 14),
                overlay.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
                overlay.widthAnchor.constraint(lessThanOrEqualToConstant: 360),
            ])

            operationProgressOverlay = overlay
            operationProgressOverlayTitleLabel = titleLabel
            operationProgressOverlayDetailLabel = detailLabel
        }

        titleLabel.stringValue = message
        detailLabel.stringValue = detail
        operationProgressContext = context
        updateOperationProgressOverlayVisibility()
    }

    // MARK: - Cycling-mode HUD

    /// Confirms a window-cycling mode change: the mode's name, one line saying what its set holds,
    /// and the chord that walks it, centered over the detail pane for a second.
    ///
    /// Centered rather than in the top-trailing banner slot because it confirms a change the user
    /// just made with a keystroke and has to be read at once, and because it is not about the pane
    /// underneath it: the banner slot carries facts about that pane. It is a subview of the window's
    /// content view constrained to the detail container's center rather than a child of that
    /// container, because the detail container is emptied wholesale whenever a placeholder or a block
    /// replaces its content, which would take the HUD with it mid-display.
    ///
    /// Only a mode change shows it, so it never appears at launch, and a second change while it is up
    /// replaces the text and restarts the timer instead of stacking a second overlay.
    func showCycleModeHUD(model: CycleModeRowModel) {
        // `host.window` is always the main Spaces window, and the HUD is a subview of its content
        // view, so the main window is the only place it can appear. The mode chord is an in-app
        // shortcut, so Spaces is the active app at every keystroke, but the main window still need not
        // be on screen: a press can land in a detached panel window while the main window is closed,
        // minimized, or on another Space. (The sidebar row's menu, the other way to change the mode,
        // is reachable only with the main window on screen.) Such a press is confirmed by the cycling
        // row and by where the next cycle press lands, an accepted rule. The window's on-screen state
        // is checked explicitly here rather than trusting the HUD subview to stay invisible: if the
        // window were off screen when a press arrived and then came back while the HUD's one-second
        // timer was still running, the subview would be on screen for the remainder of that second.
        // `isVisible` is false while the window is miniaturized or closed; `isOnActiveSpace` is false
        // while the window is on another Space. This guard does not hide an existing HUD: one already
        // up is hidden along with its window, and its own timer removes it when it fires.
        guard let window = host.window, window.isVisible, window.isOnActiveSpace, let contentView = window.contentView else { return }
        // The shortcut monitor that carries the cycle-mode chord is installed before the main window
        // content exists: during the setup flow, `contentView` is the setup flow's own view and
        // `detailContainer` is not yet attached to any window (it is installed in
        // `buildMainWindowContent()`). Constraining the HUD to a detail-container anchor while the two
        // views share no window would throw an AppKit auto layout exception, so skip showing anything
        // until the main content is in place.
        guard host.detailContainer.window === host.window else { return }
        let overlay: NSView
        let titleLabel: NSTextField
        let summaryLabel: NSTextField
        let chordLabel: NSTextField
        if let existingOverlay = cycleModeHUDOverlay, let existingTitleLabel = cycleModeHUDTitleLabel,
            let existingSummaryLabel = cycleModeHUDSummaryLabel, let existingChordLabel = cycleModeHUDChordLabel
        {
            overlay = existingOverlay
            titleLabel = existingTitleLabel
            summaryLabel = existingSummaryLabel
            chordLabel = existingChordLabel
        } else {
            overlay = CycleModeHUDView()
            overlay.wantsLayer = true
            overlay.translatesAutoresizingMaskIntoConstraints = false
            bindAppearanceReactiveLayer(overlay) { view in
                view.layer?.cornerRadius = UIRadius.large
                view.layer?.borderWidth = 1
                view.layer?.borderColor = Theme.border.cgColor
                view.layer?.backgroundColor = Theme.paletteSurface.cgColor
            }

            let stack = NSStackView()
            stack.orientation = .vertical
            stack.alignment = .centerX
            stack.spacing = 4
            stack.translatesAutoresizingMaskIntoConstraints = false

            titleLabel = NSTextField(labelWithString: "")
            titleLabel.font = Typography.cardTitle
            titleLabel.textColor = .labelColor
            titleLabel.maximumNumberOfLines = 1
            stack.addArrangedSubview(titleLabel)

            summaryLabel = NSTextField(labelWithString: "")
            summaryLabel.font = Typography.metadata
            summaryLabel.textColor = .secondaryLabelColor
            summaryLabel.maximumNumberOfLines = 1
            stack.addArrangedSubview(summaryLabel)

            chordLabel = NSTextField(labelWithString: "")
            chordLabel.font = Typography.caption
            chordLabel.textColor = .tertiaryLabelColor
            chordLabel.maximumNumberOfLines = 1
            stack.addArrangedSubview(chordLabel)

            overlay.addSubview(stack)
            contentView.addSubview(overlay)
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: overlay.leadingAnchor, constant: 18),
                stack.trailingAnchor.constraint(equalTo: overlay.trailingAnchor, constant: -18),
                stack.topAnchor.constraint(equalTo: overlay.topAnchor, constant: 14),
                stack.bottomAnchor.constraint(equalTo: overlay.bottomAnchor, constant: -14),

                overlay.centerXAnchor.constraint(equalTo: host.detailContainer.centerXAnchor),
                overlay.centerYAnchor.constraint(equalTo: host.detailContainer.centerYAnchor),
                overlay.widthAnchor.constraint(lessThanOrEqualTo: host.detailContainer.widthAnchor, constant: -48),
            ])

            cycleModeHUDOverlay = overlay
            cycleModeHUDTitleLabel = titleLabel
            cycleModeHUDSummaryLabel = summaryLabel
            cycleModeHUDChordLabel = chordLabel
        }

        titleLabel.stringValue = model.mode.displayName
        summaryLabel.stringValue = model.hudSummary
        chordLabel.stringValue =
            "Next \(host.shortcuts.footerShortcutHint(for: .guiNextShortcut))   Previous \(host.shortcuts.footerShortcutHint(for: .guiPreviousShortcut))"
        // A pane installed after the HUD was built would otherwise cover it.
        contentView.addSubview(overlay, positioned: .above, relativeTo: nil)
        overlay.isHidden = false

        cycleModeHUDDismissTask?.cancel()
        cycleModeHUDDismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.cycleModeHUDVisibleSeconds))
            guard !Task.isCancelled else { return }
            self?.hideCycleModeHUD()
        }
    }

    private func hideCycleModeHUD() {
        cycleModeHUDDismissTask?.cancel()
        cycleModeHUDDismissTask = nil
        cycleModeHUDOverlay?.isHidden = true
    }

    func hideOperationProgressOverlay() {
        operationProgressContext = nil
        operationProgressOverlay?.isHidden = true
    }

    func updateOperationProgressOverlayVisibility() {
        guard let overlay = operationProgressOverlay else { return }
        guard let context = operationProgressContext else {
            overlay.isHidden = true
            return
        }
        let isRelevant: Bool
        switch context {
        case .workspace(let id): isRelevant = host.selectedWorkspaceID == id
        case .project(let id): isRelevant = host.selectedProjectID == id
        case .global: isRelevant = true
        }
        overlay.isHidden = !isRelevant
    }

    func showWindowIssueToast(title: String, detail: String, actionTitle: String? = nil, action: (() -> Void)? = nil) {
        guard let contentView = host.window?.contentView else { return }
        let overlay: NSView
        let titleLabel: NSTextField
        let detailLabel: NSTextField
        let actionButton: NSButton
        if let existingOverlay = windowIssueToastOverlay, let existingTitleLabel = windowIssueToastTitleLabel,
            let existingDetailLabel = windowIssueToastDetailLabel, let existingActionButton = windowIssueToastActionButton
        {
            overlay = existingOverlay
            titleLabel = existingTitleLabel
            detailLabel = existingDetailLabel
            actionButton = existingActionButton
        } else {
            overlay = NSView()
            overlay.wantsLayer = true
            overlay.translatesAutoresizingMaskIntoConstraints = false

            let stack = NSStackView()
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 8
            stack.translatesAutoresizingMaskIntoConstraints = false

            titleLabel = NSTextField(labelWithString: "")
            titleLabel.font = Typography.compactTitle
            titleLabel.textColor = .labelColor
            titleLabel.maximumNumberOfLines = 1
            stack.addArrangedSubview(titleLabel)

            detailLabel = NSTextField(labelWithString: "")
            detailLabel.font = Typography.metadata
            detailLabel.textColor = .secondaryLabelColor
            detailLabel.maximumNumberOfLines = 2
            stack.addArrangedSubview(detailLabel)

            actionButton = NSButton(title: "", target: self, action: #selector(handleWindowIssueToastAction))
            actionButton.bezelStyle = .rounded
            actionButton.controlSize = .small
            stack.addArrangedSubview(actionButton)

            overlay.addSubview(stack)
            contentView.addSubview(overlay)

            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: overlay.leadingAnchor, constant: 12),
                stack.trailingAnchor.constraint(equalTo: overlay.trailingAnchor, constant: -12),
                stack.topAnchor.constraint(equalTo: overlay.topAnchor, constant: 10),
                stack.bottomAnchor.constraint(equalTo: overlay.bottomAnchor, constant: -10),

                overlay.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 14),
                overlay.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
                overlay.widthAnchor.constraint(lessThanOrEqualToConstant: 360),
            ])

            windowIssueToastOverlay = overlay
            windowIssueToastTitleLabel = titleLabel
            windowIssueToastDetailLabel = detailLabel
            windowIssueToastActionButton = actionButton
        }

        refreshWindowIssueToastAppearance()
        titleLabel.stringValue = title
        detailLabel.stringValue = detail
        actionButton.title = actionTitle ?? ""
        actionButton.isHidden = actionTitle == nil
        if actionTitle != nil { Theme.applyPrimaryStyle(to: actionButton) }
        windowIssueToastActionHandler = action
        overlay.isHidden = false

        windowIssueToastDismissTask?.cancel()
        let dismissAfterSeconds: Double = actionTitle == nil ? 4 : 8
        windowIssueToastDismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(dismissAfterSeconds))
            guard !Task.isCancelled else { return }
            self?.hideWindowIssueToast()
        }
    }

    func hideWindowIssueToast() {
        windowIssueToastDismissTask?.cancel()
        windowIssueToastDismissTask = nil
        windowIssueToastActionHandler = nil
        windowIssueToastOverlay?.isHidden = true
    }

    private func refreshWindowIssueToastAppearance() {
        guard let layer = windowIssueToastOverlay?.layer else { return }
        layer.cornerRadius = UIRadius.large
        layer.borderWidth = 1
        let appearance = host.window?.contentView?.effectiveAppearance ?? host.window?.effectiveAppearance ?? NSApp.effectiveAppearance
        appearance.performAsCurrentDrawingAppearance {
            layer.borderColor = NSColor.systemRed.withAlphaComponent(0.35).cgColor
            layer.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.96).cgColor
        }
    }

    @objc private func handleWindowIssueToastAction() {
        let action = windowIssueToastActionHandler
        hideWindowIssueToast()
        action?()
    }

    func showWindowIssueModal(title: String, detail: String, actionTitle: String? = nil, action: (() -> Void)? = nil) {
        hideWindowIssueToast()
        if host.commandPalette.commandPalettePanel?.isVisible == true {
            host.commandPalette.commandPaletteReturnTerminalSessionID = nil
            host.commandPalette.commandPaletteReturnCodePaneID = nil
            host.commandPalette.commandPaletteReturnApplicationProcessID = nil
            host.commandPalette.dismissCommandPalette()
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = detail

        if let actionTitle {
            let actionButton = alert.addButton(withTitle: actionTitle)
            actionButton.keyEquivalent = "r"
            actionButton.keyEquivalentModifierMask = [.command]
            let cancelButton = alert.addButton(withTitle: "Cancel (Esc)")
            cancelButton.keyEquivalent = "\u{1b}"
            cancelButton.keyEquivalentModifierMask = []
        } else {
            let okButton = alert.addButton(withTitle: "OK")
            okButton.keyEquivalent = "\r"
            okButton.keyEquivalentModifierMask = []
        }

        if let window = host.window {
            host.windowFocus.prepareWindowForActiveSpaceSummon(window)
            NSApp.unhide(nil)
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
        }
        Task { @MainActor in
            await Task.yield()
            if let window = host.window {
                host.windowFocus.prepareWindowForActiveSpaceSummon(window)
                NSApp.activate(ignoringOtherApps: true)
                window.makeKeyAndOrderFront(nil)
                window.orderFrontRegardless()
            }
            let response = alert.runModal()
            if actionTitle != nil, response == .alertFirstButtonReturn { action?() }
        }
    }

    func writeWindowIssueModalAck(to outputPath: String) {
        let url = URL(fileURLWithPath: outputPath)
        let payload = #"{"received":true}"#
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? payload.write(to: url, atomically: true, encoding: .utf8)
    }
}

/// The cycling-mode HUD's own view. It is a confirmation, not a control: every click goes to the
/// pane underneath, so a press that lands while it is up is never swallowed.
private final class CycleModeHUDView: NSView { override func hitTest(_ point: NSPoint) -> NSView? { nil } }
