import AppKit
import Foundation
import spacesterminalcore
import spacesterminalghostty

/// The seam pane collaborators drive to surface banner state. Kept as a protocol so
/// `TerminalLinkOpenCoordinator`'s unit tests can inject a recording fake without building an
/// AppKit view tree.
@MainActor public protocol TerminalPaneBannerPresenting: AnyObject {
    /// Shows an indeterminate progress banner with a spinner and a Cancel affordance. Replaces any
    /// currently shown transient banner.
    func showProgress(message: String, onCancel: @escaping @MainActor () -> Void)
    /// Shows a transient error banner that auto-dismisses after a few seconds.
    func showError(_ message: String)
    /// Shows a transient notice banner (dismisses on click or after a few seconds).
    func showNotice(_ message: String)
    /// Clears the transient banner, falling back to the persistent notice when one is set.
    func dismiss()
    /// Sets the pane's persistent notice — shown whenever no transient banner is up, and never
    /// auto-dismissed. Replaces any previous persistent notice.
    func showPersistent(message: String)
    /// Clears the persistent notice, hiding the banner when no transient banner is up.
    func clearPersistent()
    /// Draws attention to the banner without changing what it says. Used when the user acts on a
    /// pane the banner has already declared non-interactive.
    func flash()
}

/// Compact, unobtrusive single-line overlay pinned to the top-trailing corner of a terminal pane's
/// view. One instance per pane, owned by the pane and shared with that pane's
/// `TerminalLinkOpenCoordinator`.
///
/// The banner holds two independent layers of state:
/// - a *persistent* notice describing the pane itself (today: the session ended or failed), which
///   stays until the pane clears it, and
/// - a *transient* banner describing the pane's current action (link fetch progress, an error, a
///   notice), which auto-dismisses.
///
/// A transient banner visually overrides the persistent one for as long as it is up; dismissing it
/// restores the persistent notice rather than hiding the banner. One banner per pane means the two
/// can never overlap in the same corner, and precedence is decided here instead of by z-order.
///
/// The material and neutral text come from system-dynamic values, and the stopped-state accent from
/// the active theme's `statusFailed` token — the same one the sidebar tints an exited runtime target
/// with — so the pane and the sidebar can never disagree about the state they both report.
@MainActor public final class TerminalPaneBanner: TerminalPaneBannerPresenting {
    private enum TransientMode { case progress, error, notice }

    private static let autoDismissDelay: Duration = .seconds(6)

    private let container = NSVisualEffectView()
    private let spinner = NSProgressIndicator()
    private let iconView = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let cancelButton = NSButton()
    private let clickRecognizer = NSClickGestureRecognizer()

    private var transientMode: TransientMode?
    private var persistentMessage: String?
    private var onCancel: (@MainActor () -> Void)?
    private var autoDismissTask: Task<Void, Never>?

    public init(hostView: NSView) { buildUI(in: hostView) }

    deinit { MainActor.assumeIsolated { autoDismissTask?.cancel() } }

    // MARK: - TerminalPaneBannerPresenting

    public func showProgress(message: String, onCancel: @escaping @MainActor () -> Void) {
        self.onCancel = onCancel
        presentTransient(.progress, message: message)
    }

    public func showError(_ message: String) {
        onCancel = nil
        presentTransient(.error, message: message)
        scheduleAutoDismiss()
    }

    public func showNotice(_ message: String) {
        onCancel = nil
        presentTransient(.notice, message: message)
        scheduleAutoDismiss()
    }

    public func dismiss() {
        autoDismissTask?.cancel()
        autoDismissTask = nil
        onCancel = nil
        transientMode = nil
        render()
    }

    public func showPersistent(message: String) {
        guard persistentMessage != message else { return }
        persistentMessage = message
        render()
    }

    public func clearPersistent() {
        guard persistentMessage != nil else { return }
        persistentMessage = nil
        render()
    }

    public func flash() {
        guard !container.isHidden else { return }
        // The banner is already legible; the pulse is pure emphasis, so reduced-motion users lose
        // nothing by skipping it.
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let pulse = CABasicAnimation(keyPath: "transform.scale")
        pulse.fromValue = 1.0
        pulse.toValue = 1.05
        pulse.duration = 0.1
        pulse.autoreverses = true
        pulse.timingFunction = CAMediaTimingFunction(name: .easeOut)
        container.layer?.add(pulse, forKey: "flash")
    }

    // MARK: - Presentation

    private func presentTransient(_ mode: TransientMode, message: String) {
        autoDismissTask?.cancel()
        autoDismissTask = nil
        transientMode = mode
        render(transientMessage: message)
    }

    /// Single render path for both state layers: a transient banner wins while it is up, otherwise
    /// the persistent notice shows, otherwise the banner hides.
    private func render(transientMessage: String? = nil) {
        if let transientMode {
            if let transientMessage { label.stringValue = transientMessage }
            applyTransientChrome(transientMode)
            container.isHidden = false
            return
        }
        guard let persistentMessage else {
            spinner.stopAnimation(nil)
            container.isHidden = true
            return
        }
        label.stringValue = persistentMessage
        applyPersistentChrome()
        container.isHidden = false
    }

    private func applyTransientChrome(_ mode: TransientMode) {
        let showsSpinner = mode == .progress
        spinner.isHidden = !showsSpinner
        if showsSpinner { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        iconView.isHidden = showsSpinner
        switch mode {
        case .progress: break
        case .error: applyIcon("exclamationmark.triangle.fill", description: "Error", tint: .activeTheme(\.statusFailed))
        case .notice: applyIcon("info.circle.fill", description: "Notice", tint: .secondaryLabelColor)
        }
        cancelButton.isHidden = mode != .progress
    }

    /// One chrome for every stopped state. The sidebar draws a cleanly-exited target and a crashed
    /// one in the same tint, so the pane says the same thing rather than inventing a distinction the
    /// rest of the app does not make; the message carries which one it was. A warning glyph, not a
    /// stop/pause mark — a filled square in a circle reads as a button on a pane where nothing is
    /// clickable.
    private func applyPersistentChrome() {
        spinner.stopAnimation(nil)
        spinner.isHidden = true
        iconView.isHidden = false
        applyIcon("exclamationmark.triangle.fill", description: "Session stopped", tint: .activeTheme(\.statusFailed))
        // A persistent notice has no action to cancel and no timer to wait out; the pane clears it.
        cancelButton.isHidden = true
    }

    private func applyIcon(_ symbolName: String, description: String, tint: NSColor) {
        iconView.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: description)
        iconView.contentTintColor = tint
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
        // Only a transient notice dismisses on click: a progress banner's only click target is
        // Cancel, an error clears itself on its timer, and a persistent notice describes the pane's
        // own state, so clicking it away would hide a fact that is still true.
        guard transientMode == .notice else { return }
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
        label.setAccessibilityIdentifier("terminal-pane-banner-label")

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
        cancelButton.setAccessibilityIdentifier("terminal-pane-banner-cancel")

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

        // Pinned to the top-trailing corner. The leading constraint keeps a long message from
        // overflowing a narrow pane: it shrinks and truncates instead of running past the edge.
        let leading = container.leadingAnchor.constraint(greaterThanOrEqualTo: hostView.leadingAnchor, constant: 12)
        leading.priority = .defaultHigh
        NSLayoutConstraint.activate([
            container.topAnchor.constraint(equalTo: hostView.topAnchor, constant: 12),
            container.trailingAnchor.constraint(equalTo: hostView.trailingAnchor, constant: -12), leading,
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 6),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -6),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            iconView.widthAnchor.constraint(equalToConstant: 15), iconView.heightAnchor.constraint(equalToConstant: 15),
            cancelButton.widthAnchor.constraint(equalToConstant: 20), cancelButton.heightAnchor.constraint(equalToConstant: 20),
        ])
    }

    // MARK: - Debug

    var debugIsVisible: Bool { !container.isHidden }
    var debugMessage: String { container.isHidden ? "" : label.stringValue }
    var debugHasPersistentNotice: Bool { persistentMessage != nil }
}
