#if canImport(AppKit)
    import AppKit
    import Foundation

    /// Floating circular control shown over a terminal pane's mirror view whenever the pane is showing
    /// anything other than the session's live bottom row: the session's own viewport scrolled back, or the
    /// pane's client-local scrollback replay. Clicking it returns the pane to the live bottom.
    ///
    /// Owned by `GhosttyMirrorTerminalView`, which drives `setScrolledIntoScrollback` from each applied
    /// frame's own scrollbar state and from whether a replay frame is on screen, and wires `onActivate` to
    /// `RemoteGhosttySessionHost.handleJumpToBottom`, which jumps locally or asks the session.
    ///
    /// `setHasNewOutput` marks it while the session produces output the pane is not showing, which is the
    /// only way a user reading back learns something new arrived.
    @MainActor final class TerminalJumpToBottomControl: NSView {
        private static let diameter: CGFloat = 34
        private static let cornerRadius: CGFloat = 17
        private static let fadeDuration: CFTimeInterval = 0.12

        private static let newOutputMarkDiameter: CGFloat = 9

        private let iconView = NSImageView()
        private let newOutputMark = NSView()
        private let clickRecognizer = NSClickGestureRecognizer()

        var onActivate: (@MainActor () -> Void)?

        /// What the control was last told, so a repeat call with the same value is a no-op: a fade that
        /// keeps restarting under a stream of identical frames would never settle.
        private var isScrolledIntoScrollback = false
        /// What the new-output mark was last told, for the same reason.
        private var hasNewOutput = false

        init() {
            super.init(frame: .zero)
            translatesAutoresizingMaskIntoConstraints = false
            wantsLayer = true
            layer?.cornerRadius = Self.cornerRadius
            layer?.borderWidth = 1
            // `masksToBounds = false` so the shadow below isn't clipped by the circle it is cast from,
            // matching `TerminalPaneBanner`'s chrome.
            layer?.masksToBounds = false
            layer?.shadowColor = NSColor.black.cgColor
            layer?.shadowOpacity = 0.18
            layer?.shadowRadius = 8
            layer?.shadowOffset = NSSize(width: 0, height: -1)
            applyThemeColors()

            // Starts fully transparent and hidden: the first real state comes from
            // `setScrolledIntoScrollback`, called once the owning view has a frame to judge.
            alphaValue = 0
            isHidden = true

            iconView.translatesAutoresizingMaskIntoConstraints = false
            iconView.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)?.withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: 13, weight: .medium))
            iconView.contentTintColor = .activeTheme(\.text)
            iconView.imageScaling = .scaleProportionallyUpOrDown
            addSubview(iconView)

            // A filled dot on the control's upper trailing edge, outside the chevron so the control still
            // reads as one button. Hidden until there is output to come back to.
            newOutputMark.translatesAutoresizingMaskIntoConstraints = false
            newOutputMark.wantsLayer = true
            newOutputMark.layer?.cornerRadius = Self.newOutputMarkDiameter / 2
            newOutputMark.isHidden = true
            addSubview(newOutputMark)

            toolTip = "Jump to bottom"
            setAccessibilityRole(.button)
            setAccessibilityLabel("Jump to bottom")
            setAccessibilityIdentifier("terminal-jump-to-bottom")

            clickRecognizer.target = self
            clickRecognizer.action = #selector(handleClick)
            addGestureRecognizer(clickRecognizer)

            NSLayoutConstraint.activate([
                widthAnchor.constraint(equalToConstant: Self.diameter), heightAnchor.constraint(equalToConstant: Self.diameter),
                iconView.centerXAnchor.constraint(equalTo: centerXAnchor), iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
                newOutputMark.widthAnchor.constraint(equalToConstant: Self.newOutputMarkDiameter),
                newOutputMark.heightAnchor.constraint(equalToConstant: Self.newOutputMarkDiameter),
                newOutputMark.topAnchor.constraint(equalTo: topAnchor), newOutputMark.trailingAnchor.constraint(equalTo: trailingAnchor),
            ])
        }

        @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            applyThemeColors()
        }

        /// `CALayer.backgroundColor`/`borderColor` are `CGColor`s, which snapshot whichever appearance
        /// resolved them: a dynamic `NSColor` assigned once would leave a light-mode border sitting on a
        /// dark pane forever. Re-resolving on every appearance change keeps both live, the same trap
        /// `TerminalPaneBannerContainerView` guards against for its border.
        private func applyThemeColors() {
            effectiveAppearance.performAsCurrentDrawingAppearance { [self] in
                layer?.backgroundColor = NSColor.activeTheme(\.surface).cgColor
                layer?.borderColor = NSColor.activeTheme(\.borderStrong).cgColor
                newOutputMark.layer?.backgroundColor = NSColor.activeTheme(\.accent).cgColor
                newOutputMark.layer?.borderColor = NSColor.activeTheme(\.surface).cgColor
                newOutputMark.layer?.borderWidth = 1.5
            }
        }

        @objc private func handleClick() { onActivate?() }

        /// Fades the control in or out, ending hidden when not scrolled back so a fully-transparent
        /// control can never take a click. Skips the animation under reduced motion, and is a no-op
        /// when `isScrolled` already matches the current state, so neither a reduced-motion snap nor an
        /// ordinary fade ever restarts mid-flight from a stream of frames that agree.
        func setScrolledIntoScrollback(_ isScrolled: Bool) {
            guard isScrolled != isScrolledIntoScrollback else { return }
            isScrolledIntoScrollback = isScrolled

            guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
                layer?.removeAllAnimations()
                alphaValue = isScrolled ? 1 : 0
                isHidden = !isScrolled
                return
            }

            if isScrolled { isHidden = false }
            NSAnimationContext.runAnimationGroup(
                { context in
                    context.duration = Self.fadeDuration
                    animator().alphaValue = isScrolled ? 1 : 0
                },
                completionHandler: { [weak self] in
                    // Only the animation for the state that is still current gets to hide the view: a
                    // fade-out superseded by a later fade-in must not hide a control that is back on.
                    guard let self, self.isScrolledIntoScrollback == isScrolled else { return }
                    self.isHidden = !isScrolled
                })
        }

        /// Shows or hides the new-output mark. Independent of the fade above: the mark rides whatever the
        /// control is already doing, so a pane that gathers output while the user reads back does not
        /// restart the control's animation on every frame.
        func setHasNewOutput(_ hasNewOutput: Bool) {
            guard hasNewOutput != self.hasNewOutput else { return }
            self.hasNewOutput = hasNewOutput
            newOutputMark.isHidden = !hasNewOutput
        }

        // MARK: - Debug

        /// What the control is currently showing, asked of the real AppKit state rather than the
        /// last-set flag, so a test proves the view and not a mirrored bool.
        var debugIsVisible: Bool { !isHidden && alphaValue > 0 }
        var debugShowsNewOutput: Bool { !newOutputMark.isHidden }
        func debugActivate() { handleClick() }
    }
#endif
