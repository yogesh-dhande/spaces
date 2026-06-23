import AppKit
import systembridge

/// A selectable row used in the settings detail's left navigation panel.
/// Shows a persistent highlight when selected and a subtle hover highlight otherwise.
final class SettingsSidebarRowView: NSView {
    var isSelected: Bool { didSet { updateBackgroundColor() } }

    var selectedBackgroundColor: NSColor = .clear { didSet { updateBackgroundColor() } }

    private var isHovered = false

    init() {
        isSelected = false
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = UIRadius.compact
        translatesAutoresizingMaskIntoConstraints = false
        updateBackgroundColor()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    private func updateBackgroundColor() { layer?.backgroundColor = resolvedBackground().cgColor }

    private func resolvedBackground() -> NSColor {
        if isSelected { return selectedBackgroundColor }
        guard isHovered else { return .clear }
        return NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return isDark ? NSColor(white: 1.0, alpha: 0.08) : NSColor(white: 0.0, alpha: 0.05)
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBackgroundColor()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(
            NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        updateBackgroundColor()
        NSCursor.pointingHand.push()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        updateBackgroundColor()
        NSCursor.pop()
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}
