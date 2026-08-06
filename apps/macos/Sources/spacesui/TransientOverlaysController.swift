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
                view.layer?.borderColor = host.sidebarCardBorderColor(isSelected: false).cgColor
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
            host.prepareWindowForActiveSpaceSummon(window)
            NSApp.unhide(nil)
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
        }
        Task { @MainActor in
            await Task.yield()
            if let window = host.window {
                host.prepareWindowForActiveSpaceSummon(window)
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
