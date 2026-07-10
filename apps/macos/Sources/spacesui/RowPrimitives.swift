import AppKit

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
    }

    /// 14×14 view that draws an 8-point dot. `running` also paints an outer
    /// halo that matches the CSS `box-shadow: 0 0 0 3px rgba(green, 0.22)`.
    @MainActor static func statusDot(_ kind: StatusKind) -> StatusDotView { StatusDotView(kind: kind) }

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
        label.font = .monospacedSystemFont(ofSize: 9.5, weight: .semibold)
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
        makeChip(text: text, font: .monospacedSystemFont(ofSize: 10.5, weight: .medium), foreground: Theme.muted, minWidth: 26)
    }

    /// Plain monospace shortcut hint for dense sidebar target rows, where the
    /// indentation slot already separates the hint from the target identity.
    @MainActor static func sidebarShortcutHint(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .monospacedSystemFont(ofSize: 10.5, weight: .medium)
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
        makeChip(text: text, font: .systemFont(ofSize: 11, weight: .regular), foreground: Theme.muted, minWidth: 0)
    }

    /// Branch name chip (e.g. "main").
    @MainActor static func branchChip(_ text: String) -> NSView {
        makeChip(text: text, font: .monospacedSystemFont(ofSize: 11, weight: .regular), foreground: Theme.muted, minWidth: 0)
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
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
