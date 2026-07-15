#if canImport(AppKit)
    import AppKit

    /// The seam `TerminalLinkOpenCoordinator` drives to surface link activity. Kept as a protocol so
    /// coordinator unit tests can inject a recording fake without building an AppKit view tree.
    @MainActor protocol TerminalLinkActivityBannerPresenting: AnyObject {
        /// Shows an indeterminate progress banner with a spinner and a Cancel affordance. Replaces any
        /// currently shown banner.
        func showProgress(message: String, onCancel: @escaping @MainActor () -> Void)
        /// Shows a transient error banner that auto-dismisses after a few seconds.
        func showError(_ message: String)
        /// Shows a transient notice banner (dismisses on click or after a few seconds).
        func showNotice(_ message: String)
        /// Hides whatever banner is currently shown.
        func dismiss()
    }

    /// Compact, unobtrusive single-line overlay pinned to the top edge of a terminal pane's view. One
    /// instance per pane, owned by that pane's `TerminalLinkOpenCoordinator`. It shows three variants —
    /// a fetch-in-progress spinner with a Cancel button, a transient error, and a loopback/notice line —
    /// and stays hidden when idle. Colors and material come from system-dynamic values so the banner
    /// tracks light/dark automatically.
    @MainActor final class TerminalLinkActivityBanner: TerminalLinkActivityBannerPresenting {
        private enum Mode { case progress, error, notice }

        private static let autoDismissDelay: Duration = .seconds(6)

        private let container = NSVisualEffectView()
        private let spinner = NSProgressIndicator()
        private let iconView = NSImageView()
        private let label = NSTextField(labelWithString: "")
        private let cancelButton = NSButton()
        private let clickRecognizer = NSClickGestureRecognizer()

        private var mode: Mode = .notice
        private var onCancel: (@MainActor () -> Void)?
        private var autoDismissTask: Task<Void, Never>?

        init(hostView: NSView) { buildUI(in: hostView) }

        deinit { MainActor.assumeIsolated { autoDismissTask?.cancel() } }

        // MARK: - TerminalLinkActivityBannerPresenting

        func showProgress(message: String, onCancel: @escaping @MainActor () -> Void) {
            self.onCancel = onCancel
            present(mode: .progress, message: message)
        }

        func showError(_ message: String) {
            onCancel = nil
            present(mode: .error, message: message)
            scheduleAutoDismiss()
        }

        func showNotice(_ message: String) {
            onCancel = nil
            present(mode: .notice, message: message)
            scheduleAutoDismiss()
        }

        func dismiss() {
            autoDismissTask?.cancel()
            autoDismissTask = nil
            onCancel = nil
            spinner.stopAnimation(nil)
            container.isHidden = true
        }

        // MARK: - Presentation

        private func present(mode: Mode, message: String) {
            autoDismissTask?.cancel()
            autoDismissTask = nil
            self.mode = mode
            label.stringValue = message

            let showsSpinner = mode == .progress
            spinner.isHidden = !showsSpinner
            if showsSpinner { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }

            iconView.isHidden = showsSpinner
            switch mode {
            case .progress: break
            case .error:
                iconView.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "Error")
                iconView.contentTintColor = .systemRed
            case .notice:
                iconView.image = NSImage(systemSymbolName: "info.circle.fill", accessibilityDescription: "Notice")
                iconView.contentTintColor = .secondaryLabelColor
            }

            cancelButton.isHidden = mode != .progress
            container.isHidden = false
        }

        private func scheduleAutoDismiss() {
            autoDismissTask?.cancel()
            autoDismissTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: Self.autoDismissDelay)
                guard let self, !Task.isCancelled else { return }
                self.dismiss()
            }
        }

        @objc private func cancelAction() { onCancel?() }

        @objc private func handleClick() {
            // Only a notice dismisses on click; a progress banner's only click target is Cancel and an
            // error clears itself on its timer.
            guard mode == .notice else { return }
            dismiss()
        }

        // MARK: - Layout

        private func buildUI(in hostView: NSView) {
            container.translatesAutoresizingMaskIntoConstraints = false
            container.material = .hudWindow
            container.blendingMode = .withinWindow
            container.state = .active
            container.wantsLayer = true
            container.layer?.cornerRadius = 8
            container.layer?.masksToBounds = false
            container.layer?.borderWidth = 0.5
            container.layer?.borderColor = NSColor.separatorColor.cgColor
            container.layer?.shadowColor = NSColor.black.cgColor
            container.layer?.shadowOpacity = 0.18
            container.layer?.shadowRadius = 8
            container.layer?.shadowOffset = NSSize(width: 0, height: -1)
            container.isHidden = true

            spinner.translatesAutoresizingMaskIntoConstraints = false
            spinner.style = .spinning
            spinner.controlSize = .small
            spinner.isIndeterminate = true
            spinner.isDisplayedWhenStopped = false

            iconView.translatesAutoresizingMaskIntoConstraints = false
            iconView.imageScaling = .scaleProportionallyUpOrDown
            iconView.setContentHuggingPriority(.required, for: .horizontal)

            label.translatesAutoresizingMaskIntoConstraints = false
            label.font = .systemFont(ofSize: 12)
            label.textColor = .labelColor
            label.lineBreakMode = .byTruncatingTail
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            label.setAccessibilityIdentifier("terminal-link-activity-label")

            cancelButton.translatesAutoresizingMaskIntoConstraints = false
            cancelButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Cancel")
            cancelButton.imagePosition = .imageOnly
            cancelButton.isBordered = false
            cancelButton.contentTintColor = .secondaryLabelColor
            cancelButton.target = self
            cancelButton.action = #selector(cancelAction)
            cancelButton.toolTip = "Cancel"
            cancelButton.setButtonType(.momentaryPushIn)
            cancelButton.setContentHuggingPriority(.required, for: .horizontal)
            cancelButton.setAccessibilityIdentifier("terminal-link-activity-cancel")

            let stack = NSStackView(views: [spinner, iconView, label, cancelButton])
            stack.translatesAutoresizingMaskIntoConstraints = false
            stack.orientation = .horizontal
            stack.alignment = .centerY
            stack.spacing = 8
            stack.detachesHiddenViews = true

            clickRecognizer.target = self
            clickRecognizer.action = #selector(handleClick)
            container.addGestureRecognizer(clickRecognizer)

            container.addSubview(stack)
            hostView.addSubview(container)

            let leading = container.leadingAnchor.constraint(greaterThanOrEqualTo: hostView.leadingAnchor, constant: 12)
            leading.priority = .defaultHigh
            NSLayoutConstraint.activate([
                container.topAnchor.constraint(equalTo: hostView.topAnchor, constant: 12),
                container.centerXAnchor.constraint(equalTo: hostView.centerXAnchor), leading,
                container.trailingAnchor.constraint(lessThanOrEqualTo: hostView.trailingAnchor, constant: -12),
                stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 6),
                stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -6),
                stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
                stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
                iconView.widthAnchor.constraint(equalToConstant: 15), iconView.heightAnchor.constraint(equalToConstant: 15),
                cancelButton.widthAnchor.constraint(equalToConstant: 20), cancelButton.heightAnchor.constraint(equalToConstant: 20),
            ])
        }
    }
#endif
