import AppKit
import Foundation
import spacesterminalcore
import spacesterminalghostty

/// A single labeled recovery action a persistent notice can carry: one fact, one way to act on it.
/// `TerminalPaneBanner` renders it as a small text button in the trailing slot the transient banner's
/// Cancel button uses, so the two are never both on screen at once.
public struct TerminalPaneBannerAction: Sendable {
    public let title: String
    public let handler: @MainActor () -> Void

    public init(title: String, handler: @escaping @MainActor () -> Void) {
        self.title = title
        self.handler = handler
    }
}

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
    /// auto-dismissed. Replaces any previous persistent notice and action.
    ///
    /// `action`, when non-nil, is the notice's one recovery action (e.g. Retry for
    /// `TerminalPaneBannerNotice.unreachable`), drawn as a small text button. Nil for a notice with no
    /// single recovery step, such as `.disconnected`, which is already retrying on its own.
    func showPersistent(_ notice: TerminalPaneBannerNotice, action: TerminalPaneBannerAction?)
    /// Clears the persistent notice and action, hiding the banner when no transient banner is up.
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
/// - a *persistent* notice describing the pane itself (the session ended or failed, or the client
///   lost its state subscription to the owning device), which stays until the pane clears it, and
/// - a *transient* banner describing the pane's current action (link fetch progress, an error, a
///   notice), which auto-dismisses.
///
/// A transient banner visually overrides the persistent one for as long as it is up; dismissing it
/// restores the persistent notice rather than hiding the banner. One banner per pane means the two
/// can never overlap in the same corner, and precedence is decided here instead of by z-order.
///
/// The material and neutral text come from system-dynamic values, and the stopped-state accent from
/// the active theme's `statusFailed` token. The operational sidebar uses the stronger `red` token
/// for an exited process so it wins the workspace attention rollup unambiguously.
/// The banner's chrome view. Owns its own border color because a `CALayer`'s `borderColor` is a
/// `CGColor`, which snapshots whichever appearance resolved it — a dynamic `NSColor` assigned once
/// would leave a light-mode border sitting on a dark pane forever. `spacesui`'s
/// `bindAppearanceReactiveLayer` solves this app-side, but it lives above this module, so the
/// re-resolve happens here instead.
@MainActor private final class TerminalPaneBannerContainerView: NSVisualEffectView {
    var borderColor: NSColor = .separatorColor { didSet { applyBorderColor() } }

    /// What a click landing in the banner's footprint reaches. `passThrough`: nothing, the terminal
    /// underneath gets it. `controlsOnly`: only the listed controls (Retry, Cancel); the label and the
    /// chrome around them stay transparent, so a click beside the button still reaches the terminal.
    /// `whole`: the entire banner, for a transient notice that dismisses on click. Set by
    /// `TerminalPaneBanner.render` from what the banner is actually showing.
    enum ClickPolicy { case passThrough, controlsOnly([NSView]), whole }
    var clickPolicy: ClickPolicy = .passThrough

    override func hitTest(_ point: NSPoint) -> NSView? {
        switch clickPolicy {
        case .whole: return super.hitTest(point)
        case .passThrough: return nil
        case .controlsOnly(let controls):
            guard let hit = super.hitTest(point), controls.contains(where: { hit.isDescendant(of: $0) }) else { return nil }
            return hit
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyBorderColor()
    }

    func applyBorderColor() { effectiveAppearance.performAsCurrentDrawingAppearance { [self] in layer?.borderColor = borderColor.cgColor } }
}

@MainActor public final class TerminalPaneBanner: TerminalPaneBannerPresenting {
    private enum TransientMode { case progress, error, notice }

    /// Thin hairline for the ordinary banner; the stopped-state banner gets a full point of tinted
    /// border, since it is competing with a whole terminal surface for the eye.
    private static let idleBorderWidth: CGFloat = 0.5
    private static let stoppedBorderWidth: CGFloat = 1

    private static let autoDismissDelay: Duration = .seconds(6)

    private let container = TerminalPaneBannerContainerView()
    private let spinner = NSProgressIndicator()
    private let iconView = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let actionButton = NSButton()
    private let cancelButton = NSButton()
    private let clickRecognizer = NSClickGestureRecognizer()

    private var transientMode: TransientMode?
    private var persistentNotice: TerminalPaneBannerNotice?
    private var persistentAction: TerminalPaneBannerAction?
    private var onCancel: (@MainActor () -> Void)?
    // `nonisolated(unsafe)` so deinit can cancel without asserting main-actor isolation: the last
    // release of a banner (via its owning pane controller) can land on a background thread when an
    // async task holds the final reference. `Task.cancel()` is thread-safe and deinit has
    // exclusive access to self, so the opt-out is sound; every other access stays on the main actor.
    private nonisolated(unsafe) var autoDismissTask: Task<Void, Never>?
    // An extra retain on the banner's view-hierarchy root, dropped on the main queue by deinit so an
    // off-main last release of the banner cannot deallocate AppKit objects on a background thread.
    // The root suffices — it transitively retains every subview and the gesture recognizer, so
    // releasing the stored properties off-main drops none of them to zero, and views added later
    // are covered without touching this.
    private nonisolated(unsafe) var mainThreadReleaseBag: [AnyObject] = []

    public init(hostView: NSView) {
        buildUI(in: hostView)
        mainThreadReleaseBag = [container]
    }

    deinit {
        autoDismissTask?.cancel()
        MainThreadRelease.release(mainThreadReleaseBag)
    }

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

    public func showPersistent(_ notice: TerminalPaneBannerNotice, action: TerminalPaneBannerAction?) {
        // The pane calls this on every state or connection notification, so the closure is always
        // refreshed (a later tap must call the current handler) but the view re-renders only when
        // something visible changed: the notice, or the action's presence or title.
        let actionTitleChanged = persistentAction?.title != action?.title
        persistentAction = action
        guard persistentNotice != notice || actionTitleChanged else { return }
        persistentNotice = notice
        render()
    }

    public func clearPersistent() {
        persistentAction = nil
        guard persistentNotice != nil else { return }
        persistentNotice = nil
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
            applyClickPolicy()
            return
        }
        guard let persistentNotice else {
            spinner.stopAnimation(nil)
            container.isHidden = true
            return
        }
        label.stringValue = persistentNotice.message
        applyPersistentChrome(persistentNotice.kind)
        applyPersistentAction(persistentAction)
        container.isHidden = false
        applyClickPolicy()
    }

    /// The banner takes clicks only on the control that does something with them: Cancel on a
    /// progress banner, Retry on an unreachable notice. Anywhere else on those banners, including the
    /// label and the chrome around the button, clicks fall through to the terminal underneath. The one
    /// exception is a transient notice, which dismisses on a click anywhere in its footprint
    /// (`handleClick`), so it takes the whole banner.
    private func applyClickPolicy() {
        if transientMode == .notice {
            container.clickPolicy = .whole
            return
        }
        let controls = [actionButton, cancelButton].filter { !$0.isHidden }
        container.clickPolicy = controls.isEmpty ? .passThrough : .controlsOnly(controls)
    }

    private func applyTransientChrome(_ mode: TransientMode) {
        applyBorder(emphasized: false)
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
        // A transient banner's only action is Cancel; a persistent notice's action button lives in the
        // same trailing slot (see `buildUI`), so the two are never shown together.
        actionButton.isHidden = true
    }

    /// One chrome for every stopped state. The sidebar draws a cleanly-exited target and a crashed
    /// one in the same tint, so the pane says the same thing rather than inventing a distinction the
    /// rest of the app does not make; the message carries which one it was. A warning glyph, not a
    /// stop/pause mark — a filled square in a circle reads as a button on a pane where nothing is
    /// clickable.
    ///
    /// A stage 1 dropped connection is drawn as an ordinary notice instead: neutral glyph, neutral
    /// tint, hairline border. It is not yet a failure, it is expected to resolve itself on reconnect,
    /// and the sidebar likewise dims a still-retrying device rather than tinting it like a crash.
    ///
    /// A stage 2 unreachable connection gets the same emphasized chrome as a stopped session: every
    /// candidate address has refused to dial, which is worth the eye the way a crash is, but keeps the
    /// connection glyph (not the warning triangle) so it still reads as a link problem, not a process
    /// death, matching `TerminalPaneBannerNotice.resolve`'s precedence.
    private func applyPersistentChrome(_ kind: TerminalPaneBannerNotice.Kind) {
        spinner.stopAnimation(nil)
        spinner.isHidden = true
        iconView.isHidden = false
        switch kind {
        case .stopped:
            applyBorder(emphasized: true)
            applyIcon("exclamationmark.triangle.fill", description: "Session stopped", tint: .activeTheme(\.statusFailed))
        case .disconnected:
            applyBorder(emphasized: false)
            applyIcon("antenna.radiowaves.left.and.right.slash", description: "Connection lost", tint: .secondaryLabelColor)
        case .unreachable:
            applyBorder(emphasized: true)
            applyIcon("antenna.radiowaves.left.and.right.slash", description: "Device unreachable", tint: .activeTheme(\.statusFailed))
        }
        // A persistent notice has no timer to wait out; the pane clears it (or its action redials it).
        cancelButton.isHidden = true
    }

    /// Shows the notice's one recovery action, when it has one, as a small text button in the trailing
    /// slot the transient banner's Cancel button uses.
    private func applyPersistentAction(_ action: TerminalPaneBannerAction?) {
        actionButton.title = action?.title ?? ""
        actionButton.isHidden = action == nil
    }

    /// The stopped banner outlines itself in the same tint as its glyph, so it separates from the
    /// terminal behind it instead of reading as one more HUD. Every other banner keeps the hairline.
    private func applyBorder(emphasized: Bool) {
        container.layer?.borderWidth = emphasized ? Self.stoppedBorderWidth : Self.idleBorderWidth
        container.borderColor = emphasized ? .activeTheme(\.statusFailed) : .separatorColor
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

    @objc private func persistentActionTapped() { persistentAction?.handler() }

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
        container.layer?.borderWidth = Self.idleBorderWidth
        container.borderColor = .separatorColor
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
        label.font = Typography.rowDetail
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.setAccessibilityIdentifier("terminal-pane-banner-label")

        actionButton.translatesAutoresizingMaskIntoConstraints = false
        actionButton.bezelStyle = .inline
        actionButton.isBordered = false
        actionButton.font = Typography.rowDetail
        actionButton.contentTintColor = .controlAccentColor
        actionButton.target = self
        actionButton.action = #selector(persistentActionTapped)
        actionButton.setButtonType(.momentaryPushIn)
        actionButton.setContentHuggingPriority(.required, for: .horizontal)
        actionButton.setAccessibilityIdentifier("terminal-pane-banner-action")
        actionButton.isHidden = true

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

        // `detachesHiddenViews` collapses whichever of `actionButton`/`cancelButton` is hidden, so the
        // trailing-most visible one always sits at the stack's end: the two never occupy the slot at
        // once (see `applyTransientChrome`/`applyPersistentAction`).
        let stack = NSStackView(views: [spinner, iconView, label, actionButton, cancelButton])
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
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8), iconView.widthAnchor.constraint(equalToConstant: 15),
            iconView.heightAnchor.constraint(equalToConstant: 15), cancelButton.widthAnchor.constraint(equalToConstant: 20),
            cancelButton.heightAnchor.constraint(equalToConstant: 20),
        ])
    }

    // MARK: - Debug

    var debugIsVisible: Bool { !container.isHidden }
    var debugMessage: String { container.isHidden ? "" : label.stringValue }
    var debugHasPersistentNotice: Bool { persistentNotice != nil }
    var debugActionTitle: String? { actionButton.isHidden ? nil : actionButton.title }

    /// Whether a click on the label would reach the view underneath it rather than the banner, asked
    /// of the real `hitTest` so the test proves the AppKit seam and not a flag.
    var debugClickOnLabelPassesThrough: Bool { debugHitTest(on: label) == nil }
    /// Whether a click on the action (Retry) button reaches that button, asked of the real `hitTest`.
    var debugClickOnActionReachesButton: Bool { debugHitTest(on: actionButton)?.isDescendant(of: actionButton) == true }

    /// Runs the real `hitTest` at the center of `view`'s laid-out frame, converted into the container's
    /// superview coordinate space (what `hitTest(_:)` takes). Forces layout first so a stale zero-size
    /// frame can't make either seam vacuous.
    private func debugHitTest(on view: NSView) -> NSView? {
        container.superview?.layoutSubtreeIfNeeded()
        guard let superview = view.superview, let containerSuperview = container.superview else { return nil }
        let point = superview.convert(NSPoint(x: view.frame.midX, y: view.frame.midY), to: containerSuperview)
        return container.hitTest(point)
    }

    func debugTapAction() { persistentActionTapped() }
}
