import AppKit
import spacesterminalcore

/// Small view builders shared across the workspace detail, sidebar, and
/// alerts screens. Encodes the compact row vocabulary from
/// `design-mocks/workspace-detail/shared.css`: a status dot, a tinted type
/// icon tile, and a handful of chips (shortcut, project, branch).
///
/// Keep these primitives dumb and composable. Hover/selection/edit behaviors
/// live in the row container that will be introduced in Phase 2.
enum RowPrimitives {
    static let statusSlotWidth: CGFloat = 14

    // MARK: Status dot

    enum StatusKind: Sendable {
        case running
        case exited
        case idle
        case waiting
        /// Healthy and armed, but nothing running right now: a solid green dot without the running halo.
        /// Distinct from `idle`, which is the hollow dot for something switched off or never started.
        case ready
    }

    /// 14×14 view that draws an 8-point dot. `running` also paints an outer
    /// halo that matches the CSS `box-shadow: 0 0 0 3px rgba(green, 0.22)`.
    @MainActor static func statusDot(_ kind: StatusKind) -> StatusDotView { StatusDotView(kind: kind) }

    /// The compact filled/hollow status mark used by identity rows in the sidebar and dense tables.
    /// Keeping its symbol and 10-point geometry here prevents workspace and automation rows from
    /// drifting into similar-but-different status indicators.
    @MainActor static func compactStatusDot(filled: Bool, tint: NSColor, tooltip: String) -> CompactStatusDotView {
        CompactStatusDotView(filled: filled, tint: tint, tooltip: tooltip)
    }

    /// Fixed-width leading slot for a status indicator. When `content` is nil,
    /// the empty slot preserves shortcut alignment across rows.
    @MainActor static func statusSlot(_ content: NSView? = nil) -> NSView {
        let slot = NSView()
        slot.translatesAutoresizingMaskIntoConstraints = false
        slot.setContentHuggingPriority(.required, for: .horizontal)
        slot.setContentCompressionResistancePriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            slot.widthAnchor.constraint(equalToConstant: statusSlotWidth), slot.heightAnchor.constraint(greaterThanOrEqualToConstant: 14),
        ])

        guard let content else { return slot }
        content.translatesAutoresizingMaskIntoConstraints = false
        slot.addSubview(content)
        NSLayoutConstraint.activate([
            content.centerXAnchor.constraint(equalTo: slot.centerXAnchor), content.centerYAnchor.constraint(equalTo: slot.centerYAnchor),
        ])
        return slot
    }

    // MARK: Type tile

    enum TypeKind: Sendable {
        case browser
        case process
        case agent
        case project
        case port
    }

    @MainActor private static func typeColors(for kind: TypeKind) -> (background: NSColor, foreground: NSColor) {
        switch kind {
        case .browser, .project: return (Theme.iconBrowserBg, Theme.iconBrowserFg)
        case .process: return (Theme.iconProcessBg, Theme.iconProcessFg)
        case .agent: return (Theme.iconAgentBg, Theme.iconAgentFg)
        case .port: return (Theme.iconPortBg, Theme.iconPortFg)
        }
    }

    @MainActor private static func typeTileBackground(_ kind: TypeKind) -> ColoredBackgroundView {
        let tile = ColoredBackgroundView()
        tile.fillColor = typeColors(for: kind).background
        tile.cornerRadius = 5
        tile.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([tile.widthAnchor.constraint(equalToConstant: 22), tile.heightAnchor.constraint(equalToConstant: 22)])
        return tile
    }

    /// 22×22 rounded tile with a tinted background and an SF Symbol glyph.
    /// `symbol` is a system symbol name (e.g. "globe", "terminal", "cpu.fill").
    @MainActor static func typeIconTile(_ kind: TypeKind, symbol: String, accessibilityLabel: String? = nil) -> NSView {
        let fg = typeColors(for: kind).foreground
        let tile = typeTileBackground(kind)

        let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: accessibilityLabel)?.withSymbolConfiguration(config)

        let imageView = NSImageView()
        imageView.image = image
        imageView.contentTintColor = fg
        imageView.translatesAutoresizingMaskIntoConstraints = false
        tile.addSubview(imageView)

        NSLayoutConstraint.activate([
            imageView.centerXAnchor.constraint(equalTo: tile.centerXAnchor), imageView.centerYAnchor.constraint(equalTo: tile.centerYAnchor),
        ])
        return tile
    }

    /// 22×22 rounded tile with centered compact text, used when a row needs a
    /// neutral marker instead of a symbol or product logo.
    @MainActor static func typeTextTile(_ kind: TypeKind, text: String, accessibilityLabel: String? = nil) -> NSView {
        let fg = typeColors(for: kind).foreground
        let tile = typeTileBackground(kind)
        if let accessibilityLabel {
            tile.setAccessibilityElement(true)
            tile.setAccessibilityLabel(accessibilityLabel)
            tile.setAccessibilityValue(text)
        }

        let label = NSTextField(labelWithString: text)
        label.font = Typography.monoBadgeStrong
        label.textColor = fg
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.translatesAutoresizingMaskIntoConstraints = false
        tile.addSubview(label)

        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: tile.centerXAnchor), label.centerYAnchor.constraint(equalTo: tile.centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: tile.leadingAnchor, constant: 1),
            label.trailingAnchor.constraint(lessThanOrEqualTo: tile.trailingAnchor, constant: -1),
        ])
        return tile
    }

    // MARK: Chips

    /// Monospace shortcut label like "⌘1" inside a muted rounded chip.
    /// Width enforces a minimum so single-digit shortcuts don't collapse.
    @MainActor static func shortcutChip(_ text: String) -> NSView {
        makeChip(text: text, font: Typography.monoBadge, foreground: Theme.muted, minWidth: 26)
    }

    /// Plain monospace shortcut hint for dense sidebar target rows, where the
    /// indentation slot already separates the hint from the target identity.
    @MainActor static func sidebarShortcutHint(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = Typography.monoBadge
        label.textColor = Theme.muted
        label.alignment = .right
        label.lineBreakMode = .byClipping
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        return label
    }

    /// Project name chip (e.g. "Spaces") that sits next to the workspace title.
    @MainActor static func projectChip(_ text: String) -> NSView {
        makeChip(text: text, font: Typography.metadata, foreground: Theme.muted, minWidth: 0)
    }

    /// Branch name chip (e.g. "main").
    @MainActor static func branchChip(_ text: String) -> NSView {
        makeChip(text: text, font: Typography.monoMetadata, foreground: Theme.muted, minWidth: 0)
    }

    @MainActor private static func makeChip(text: String, font: NSFont, foreground: NSColor, minWidth: CGFloat) -> NSView {
        let chip = ColoredBackgroundView()
        chip.fillColor = Theme.chipBg
        chip.cornerRadius = 4
        chip.translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(labelWithString: text)
        label.font = font
        label.textColor = foreground
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        chip.addSubview(label)

        var constraints: [NSLayoutConstraint] = [
            label.leadingAnchor.constraint(equalTo: chip.leadingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: chip.trailingAnchor, constant: -6),
            label.topAnchor.constraint(equalTo: chip.topAnchor, constant: 1), label.bottomAnchor.constraint(equalTo: chip.bottomAnchor, constant: -1),
        ]
        if minWidth > 0 { constraints.append(chip.widthAnchor.constraint(greaterThanOrEqualToConstant: minWidth)) }
        NSLayoutConstraint.activate(constraints)
        return chip
    }

    // MARK: Project glyph

    /// Template image of the marketing site's project glyph: two nodes on the left
    /// merging into one on the right (the `apps/web` `ProjectIcon`). Paths are laid
    /// out in a 20×20 space and scaled to `side`. Marked as a template so callers can
    /// tint it via `contentTintColor` like an SF Symbol. `NSImage(size:flipped:drawingHandler:)`
    /// retains the drawing handler and re-invokes it per backing store rather than caching a
    /// single rasterization, so this one shared instance still redraws crisply on any display —
    /// there's no need to construct a fresh `NSImage` per row.
    static let projectGlyphImage: NSImage = {
        let side: CGFloat = 13
        let image = NSImage(size: NSSize(width: side, height: side), flipped: true) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.scaleBy(x: side / 20, y: side / 20)

            let path = NSBezierPath()
            let radius: CGFloat = 1.8
            for center in [NSPoint(x: 5, y: 5), NSPoint(x: 5, y: 15), NSPoint(x: 15, y: 10)] {
                path.appendOval(in: NSRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
            }
            // Top-left node elbows down into the right node; cubic control points
            // approximate the SVG's radius-2 quarter-circle corner.
            path.move(to: NSPoint(x: 6.8, y: 5))
            path.line(to: NSPoint(x: 11, y: 5))
            path.curve(to: NSPoint(x: 13, y: 7), controlPoint1: NSPoint(x: 12.105, y: 5), controlPoint2: NSPoint(x: 13, y: 5.895))
            path.line(to: NSPoint(x: 13, y: 8))
            // Bottom-left node elbows up into the right node.
            path.move(to: NSPoint(x: 6.8, y: 15))
            path.line(to: NSPoint(x: 11, y: 15))
            path.curve(to: NSPoint(x: 13, y: 13), controlPoint1: NSPoint(x: 12.105, y: 15), controlPoint2: NSPoint(x: 13, y: 14.105))
            path.line(to: NSPoint(x: 13, y: 12))

            path.lineWidth = 1.4
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            NSColor.black.setStroke()
            path.stroke()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Git project"
        return image
    }()
}

/// A 10×10 filled or hollow SF Symbol circle for compact identity rows.
@MainActor final class CompactStatusDotView: NSImageView {
    private(set) var isFilled: Bool

    init(filled: Bool, tint: NSColor, tooltip: String) {
        isFilled = filled
        super.init(frame: .zero)
        image = NSImage(systemSymbolName: filled ? "circle.fill" : "circle", accessibilityDescription: tooltip)
        contentTintColor = tint
        toolTip = tooltip
        imageScaling = .scaleProportionallyDown
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([widthAnchor.constraint(equalToConstant: 10), heightAnchor.constraint(equalToConstant: 10)])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) not available") }

    override var intrinsicContentSize: NSSize { NSSize(width: 10, height: 10) }
}

// MARK: - Row click helper

/// Lightweight NSObject target that holds a click closure for use with
/// NSClickGestureRecognizer on non-control views.
@MainActor final class RowClickTarget: NSObject {
    private let action: () -> Void
    init(action: @escaping () -> Void) { self.action = action }
    @objc func clicked(_ sender: NSClickGestureRecognizer) { action() }
}

/// A label whose `AXPress` accessibility action invokes a closure, for rows whose click
/// handling lives on the enclosing outline view's low-level mouse-down override (see
/// `SidebarOutlineView.onRowMouseDown`) rather than a button or table-row selection. A plain
/// `NSTextField` label reports no accessibility actions, so `AXPress` on it silently succeeds
/// without doing anything instead of throwing — VoiceOver and UI automation can locate the row
/// by its identifier but never activate it. Overriding the press action fixes both.
@MainActor final class PressableLabel: NSTextField {
    var onAccessibilityPress: (() -> Void)?

    override func accessibilityPerformPress() -> Bool {
        guard let onAccessibilityPress else { return super.accessibilityPerformPress() }
        onAccessibilityPress()
        return true
    }
}

nonisolated(unsafe) private var rowClickTargetAssocKey: UInt8 = 0

/// Attach a click action to `view` by adding an `NSClickGestureRecognizer`.
/// The `RowClickTarget` is retained via `objc_setAssociatedObject` so callers
/// don't need to store it separately.
@MainActor func attachRowClickAction(to view: NSView, action: @escaping () -> Void) {
    let target = RowClickTarget(action: action)
    let recognizer = NSClickGestureRecognizer(target: target, action: #selector(RowClickTarget.clicked(_:)))
    view.addGestureRecognizer(recognizer)
    objc_setAssociatedObject(view, &rowClickTargetAssocKey, target, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
}

/// Layer-backed view whose background tracks a dynamic `NSColor`. Using a
/// plain `NSView` + `layer.backgroundColor = color.cgColor` snapshots the
/// color at assignment and stops responding to appearance changes; this view
/// re-resolves the color inside `updateLayer()` under the view's effective
/// appearance every time AppKit asks for a redraw.
@MainActor final class ColoredBackgroundView: NSView {
    var fillColor: NSColor = .clear { didSet { needsDisplay = true } }
    var cornerRadius: CGFloat = 0 {
        didSet {
            layer?.cornerRadius = cornerRadius
            needsDisplay = true
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) not available") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance { layer?.backgroundColor = fillColor.cgColor }
        layer?.cornerRadius = cornerRadius
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

/// Draws a status dot. `running` additionally fills an outer halo so the
/// running state pops against the row background.
@MainActor final class StatusDotView: NSView {
    var kind: RowPrimitives.StatusKind { didSet { needsDisplay = true } }

    init(kind: RowPrimitives.StatusKind) {
        self.kind = kind
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([widthAnchor.constraint(equalToConstant: 14), heightAnchor.constraint(equalToConstant: 14)])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) not available") }

    override var intrinsicContentSize: NSSize { NSSize(width: 14, height: 14) }

    override func draw(_ dirtyRect: NSRect) {
        let dotRect = NSRect(x: 3, y: 3, width: 8, height: 8)
        let dotPath = NSBezierPath(ovalIn: dotRect)

        switch kind {
        case .running:
            Theme.statusRunningHalo.setFill()
            NSBezierPath(ovalIn: NSRect(x: 0, y: 0, width: 14, height: 14)).fill()
            Theme.statusRunningFill.setFill()
            dotPath.fill()
        case .exited:
            Theme.statusExitedStroke.setStroke()
            dotPath.lineWidth = 1.5
            dotPath.stroke()
        case .idle:
            Theme.statusIdleStroke.setStroke()
            dotPath.lineWidth = 1.5
            dotPath.stroke()
        case .waiting:
            Theme.statusWaitingFill.setFill()
            dotPath.fill()
        case .ready:
            Theme.statusRunningFill.setFill()
            dotPath.fill()
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
