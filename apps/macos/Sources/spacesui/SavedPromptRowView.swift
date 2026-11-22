import AppKit
import spacesterminalcore
import systembridge

/// One line of the Prompts table: title, one-line preview, device, age, and the Copy button.
///
/// Clicking anywhere on the line except the Copy button and the title field opens or closes the prompt's
/// editor. The open prompt's line hosts the editor's title field in its Title cell, leaves the Prompt cell
/// empty (the full text is in the editor), and shares the editor's fill, so the two read as one surface.
@MainActor final class SavedPromptRowView: NSView {
    static let rowHeight: CGFloat = 34

    /// Stateless and shared by every row's click recognizer; it vetoes clicks that land on a control.
    private static let gestureDelegate = RowControlGestureDelegate()

    /// Lets the Copy button and the open row's title field take their own clicks instead of toggling the row.
    @MainActor private final class RowControlGestureDelegate: NSObject, NSGestureRecognizerDelegate {
        func gestureRecognizer(_ gestureRecognizer: NSGestureRecognizer, shouldAttemptToRecognizeWith event: NSEvent) -> Bool {
            guard let view = gestureRecognizer.view else { return true }
            var hit = view.deepestView(at: event)
            while let candidate = hit, candidate !== view {
                if candidate is NSButton || (candidate as? NSTextField)?.isEditable == true { return false }
                hit = candidate.superview
            }
            return true
        }
    }

    private var hoverTrackingArea: NSTrackingArea?
    private let isExpanded: Bool
    private var copyButton = NSButton()
    private let usedLabel = NSTextField(labelWithString: "")
    private var isHovered = false {
        didSet {
            guard isHovered != oldValue else { return }
            updateBackground()
        }
    }

    /// `titleField` is the open prompt's editable title and is required exactly when `row.isExpanded`.
    init(row: SavedPromptsPaneModel.Row, grid: TableGrid, titleField: NSTextField?, onClick: @escaping () -> Void, onCopy: @escaping () -> Void) {
        isExpanded = row.isExpanded
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = UIRadius.compact
        // The editor below carries the bottom corners.
        if isExpanded { layer?.maskedCorners = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner] }
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(row.title)
        setAccessibilityIdentifier("prompts-row-\(row.key)")

        let titleCell: NSView
        if let titleField {
            titleCell = titleField
        } else {
            let titleLabel = NSTextField(labelWithString: row.title)
            titleLabel.font = Typography.rowLabel
            titleLabel.textColor = .labelColor
            titleLabel.lineBreakMode = .byTruncatingTail
            titleCell = titleLabel
        }

        let previewLabel = NSTextField(labelWithString: row.preview)
        previewLabel.font = Typography.rowDetail
        previewLabel.textColor = .secondaryLabelColor
        previewLabel.lineBreakMode = .byTruncatingTail

        var columns: [NSView] = [titleCell, previewLabel]
        if let deviceText = row.deviceText {
            let deviceLabel = NSTextField(labelWithString: deviceText)
            deviceLabel.font = Typography.metadata
            deviceLabel.textColor = .secondaryLabelColor
            deviceLabel.lineBreakMode = .byTruncatingTail
            columns.append(deviceLabel)
        }
        usedLabel.stringValue = row.usedText
        usedLabel.font = Typography.metadata
        usedLabel.textColor = Theme.muted
        usedLabel.alignment = .right
        usedLabel.lineBreakMode = .byClipping
        columns.append(usedLabel)

        copyButton = QuietButton(title: row.copyTitle, target: self, action: #selector(copyClicked))
        copyButton.setAccessibilityIdentifier(row.isExpanded ? "prompts-editor-copy" : "prompts-row-copy")
        copyButton.toolTip = "Copy prompt"
        Self.setCopyContent(copyButton, title: row.copyTitle, showsCopied: row.showsCopied)
        self.onCopy = onCopy
        columns.append(copyButton)

        let line = grid.makeRowLine(columns)
        addSubview(line)
        NSLayoutConstraint.activate([
            line.leadingAnchor.constraint(equalTo: leadingAnchor), line.trailingAnchor.constraint(equalTo: trailingAnchor),
            line.centerYAnchor.constraint(equalTo: centerYAnchor), heightAnchor.constraint(equalToConstant: Self.rowHeight),
        ])

        let recognizer = NSClickGestureRecognizer(target: self, action: #selector(rowClicked))
        recognizer.delegate = Self.gestureDelegate
        addGestureRecognizer(recognizer)
        self.onClick = onClick
        updateBackground()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) not available") }

    /// Retitles Copy without rebuilding the line, so typing in the open row's title field keeps its caret.
    func updateCopyButton(title: String, showsCopied: Bool) { Self.setCopyContent(copyButton, title: title, showsCopied: showsCopied) }

    func updateUsed(_ text: String) { usedLabel.stringValue = text }

    private var onClick: (() -> Void)?
    private var onCopy: (() -> Void)?

    @objc private func rowClicked() { onClick?() }
    @objc private func copyClicked() { onCopy?() }

    /// The Copy button's content: `title`, plus a check while the "Copied" confirmation shows. It runs on every
    /// keystroke in the open row, so it sets only content; the button's fill and size are fixed when it is built.
    private static func setCopyContent(_ button: NSButton, title: String, showsCopied: Bool) {
        button.image = showsCopied ? NSImage(systemSymbolName: "checkmark", accessibilityDescription: "Copied") : nil
        button.imagePosition = showsCopied ? .imageLeading : .noImage
        button.attributedTitle = NSAttributedString(
            string: title, attributes: [.foregroundColor: NSColor.labelColor, .font: Typography.secondaryButtonLabel])
    }

    // MARK: - Background

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        hoverTrackingArea = area
        addTrackingArea(area)
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBackground()
    }

    // Resolved under this view's appearance so a live light/dark switch re-resolves the fill.
    private func updateBackground() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let fill: NSColor = isExpanded ? Theme.rowHover : (isHovered ? Theme.rowHover : .clear)
            layer?.backgroundColor = fill.cgColor
        }
    }
}
