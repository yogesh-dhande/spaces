import AppKit
import systembridge

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
    /// Tracks only the hover area this view added, so `updateTrackingAreas` can replace it without
    /// touching AppKit's own tooltip tracking area (installed by setting `toolTip`). Removing every
    /// tracking area on each update, as a naive rebuild does, silently drops the tooltip on the next
    /// resize or scroll.
    private var hoverTrackingArea: NSTrackingArea?

    /// The row's two text fields, assigned by the row builder (the Alerts table's
    /// `AlertsController.alertsCombinedCell`) as it builds them. Held so a re-render that changed nothing
    /// but the strings can write into the row already on screen instead of replacing it. Which fields the
    /// row has, their fonts, and their visibility are decided at build time and stay fixed, so only the
    /// strings are writable here.
    weak var labelField: NSTextField?
    weak var detailField: NSTextField?

    /// A dense table row's non-hover background (the Alerts table's zebra striping on alternate rows).
    /// nil, the default, means no striping, so every other `ClickableRowView` use is unaffected. Hover
    /// still takes over on top of it, the same as an unstriped row.
    var zebraFill: NSColor? { didSet { updateBackgroundColor() } }

    init(isInteractive: Bool) {
        self.isInteractive = isInteractive
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = UIRadius.compact
        layer?.borderWidth = 0
        translatesAutoresizingMaskIntoConstraints = false
        updateBackgroundColor()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    /// Rewrites the row's text in place, accessibility included, leaving every view instance alone.
    func updateText(label: String, detail: String) {
        labelField?.stringValue = label
        detailField?.stringValue = detail
        setAccessibilityLabel(label)
        setAccessibilityValue(detail.isEmpty ? nil : detail)
    }

    // MARK: - Background

    // Resolve under this view's effective appearance so a live light/dark switch re-resolves
    // correctly; a bare `.cgColor` in `viewDidChangeEffectiveAppearance` keeps the old variant.
    private func updateBackgroundColor() {
        effectiveAppearance.performAsCurrentDrawingAppearance { layer?.backgroundColor = resolvedBackground().cgColor }
    }

    private func resolvedBackground() -> NSColor {
        guard isInteractive && isHovered else { return zebraFill ?? .clear }
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
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        hoverTrackingArea = nil
        guard isInteractive else { return }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        hoverTrackingArea = area
        addTrackingArea(area)
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
