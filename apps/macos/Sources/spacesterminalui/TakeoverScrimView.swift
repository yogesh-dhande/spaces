import AppKit
import spacesterminalghostty

/// Full-bleed dimming layer behind the State-B ("another client owns this session") overlay.
///
/// A `CALayer`'s `backgroundColor` is a resolved `CGColor`, not the dynamic `NSColor` that
/// `NSColor.activeTheme` returns, so assigning it once bakes in whichever appearance was active at
/// that moment. A later light/dark switch while the overlay is on screen would then leave the scrim
/// showing the wrong theme's tint until the next unrelated re-layout happened to touch the layer
/// again. Re-resolving in `viewDidChangeEffectiveAppearance` keeps the fill correct on every live
/// appearance change, matching the pattern used by `ClickableRowView` and
/// `TerminalPaneBannerContainerView` in this codebase.
@MainActor final class TakeoverScrimView: NSView {
    init() {
        super.init(frame: .zero)
        wantsLayer = true
        applyFill()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyFill()
    }

    private func applyFill() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.activeTheme(\.background).withAlphaComponent(0.72).cgColor
        }
    }
}
