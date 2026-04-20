import AppKit

/// A rounded row view that stays visually flat until hover indicates interactivity.
/// Use `isInteractive = true` when a click action is attached; hover effects are skipped otherwise.
final class ClickableRowView: NSView {
    var isInteractive: Bool {
        didSet {
            updateBackgroundColor()
            updateTrackingAreas()
        }
    }

    private var isHovered = false

    init(isInteractive: Bool) {
        self.isInteractive = isInteractive
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.borderWidth = 0
        translatesAutoresizingMaskIntoConstraints = false
        updateBackgroundColor()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    // MARK: - Background

    private func updateBackgroundColor() { layer?.backgroundColor = resolvedBackground().cgColor }

    private func resolvedBackground() -> NSColor {
        guard isInteractive && isHovered else { return .clear }
        return NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return isDark ? NSColor(white: 1.0, alpha: 0.08) : NSColor(white: 0.0, alpha: 0.05)
        }
    }

    // MARK: - Appearance changes

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBackgroundColor()
    }

    // MARK: - Tracking area

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        guard isInteractive else { return }
        addTrackingArea(
            NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil))
    }

    // MARK: - Hover events

    override func mouseEntered(with event: NSEvent) {
        guard isInteractive else { return }
        isHovered = true
        updateBackgroundColor()
        NSCursor.pointingHand.push()
    }

    override func mouseExited(with event: NSEvent) {
        guard isInteractive else { return }
        isHovered = false
        updateBackgroundColor()
        NSCursor.pop()
    }

    override func resetCursorRects() {
        guard isInteractive else {
            super.resetCursorRects()
            return
        }
        addCursorRect(bounds, cursor: .pointingHand)
    }
}
