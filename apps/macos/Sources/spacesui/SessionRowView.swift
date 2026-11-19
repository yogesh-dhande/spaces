import AppKit
import spacesterminalcore
import systembridge

/// One result of the Sessions pane: the title with the matched excerpt under it, then where the
/// conversation opens, its agent and size, with last active on the right.
///
/// A click resumes (or focuses) the conversation. A conversation that cannot be resumed says why
/// and shows its id in a field the user can select and copy; that field takes its own clicks.
/// Rows carry no borders and only the selected row a fill, and state is plain text in muted gray: only
/// a failed resume is colored.
@MainActor final class SessionRowView: NSView {
    private enum Layout {
        static let ageWidth: CGFloat = 96
        static let horizontalInset: CGFloat = 12
        static let verticalInset: CGFloat = 9
        static let columnGap: CGFloat = 12
    }

    let key: String
    private let isSelected: Bool
    private let onActivate: () -> Void

    init(row: SessionsPaneModel.Row, query: String, isSelected: Bool, statusText: String?, statusIsError: Bool, onActivate: @escaping () -> Void) {
        key = row.key
        self.isSelected = isSelected
        self.onActivate = onActivate
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = UIRadius.regular
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityElement(true)
        setAccessibilityRole(.row)
        setAccessibilityLabel("\(row.agentName) \(row.title)")
        setAccessibilityIdentifier("sessions-row-\(row.key)")
        setAccessibilitySelected(isSelected)

        let middle = NSStackView()
        middle.orientation = .vertical
        middle.alignment = .leading
        middle.spacing = 2
        middle.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        middle.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        var lines: [NSView] = [Self.titleLabel(row)]
        if let excerpt = row.excerpt { lines.append(Self.excerptLabel(excerpt, query: query)) }
        lines.append(Self.detailLine(row))
        if let statusText { lines.append(Self.label(statusText, font: Typography.metadata, color: statusIsError ? Theme.red : Theme.muted)) }
        for line in lines {
            middle.addArrangedSubview(line)
            line.widthAnchor.constraint(lessThanOrEqualTo: middle.widthAnchor).isActive = true
        }

        let age = Self.label(row.ageText, font: Typography.metadata, color: Theme.muted)
        age.alignment = .right
        age.setContentCompressionResistancePriority(.required, for: .horizontal)

        // Pinned to both edges rather than stacked, so the text column always takes the width the time
        // leaves and the time lines up at the right edge on every row.
        for view in [middle, age] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            middle.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Layout.horizontalInset),
            middle.trailingAnchor.constraint(equalTo: age.leadingAnchor, constant: -Layout.columnGap),
            middle.topAnchor.constraint(equalTo: topAnchor, constant: Layout.verticalInset),
            middle.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Layout.verticalInset),
            age.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Layout.horizontalInset),
            age.firstBaselineAnchor.constraint(equalTo: lines[0].firstBaselineAnchor), age.widthAnchor.constraint(equalToConstant: Layout.ageWidth),
        ])
        updateBackground()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) not available") }

    override func mouseDown(with event: NSEvent) { onActivate() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBackground()
    }

    private func updateBackground() {
        effectiveAppearance.performAsCurrentDrawingAppearance { layer?.backgroundColor = (isSelected ? Theme.rowSelected : NSColor.clear).cgColor }
    }

    // MARK: - Lines

    private static func label(_ text: String, font: NSFont, color: NSColor) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = font
        label.textColor = color
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.cell?.wraps = false
        label.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        return label
    }

    /// An attributed value replaces the cell's own line break mode, so a run without this paragraph style
    /// wraps onto as many lines as it needs instead of truncating to one.
    private static let singleLine: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        return style
    }()

    /// The title (or the pin's name, behind a muted pin mark), then " · Running" in muted gray.
    private static func titleLabel(_ row: SessionsPaneModel.Row) -> NSTextField {
        let text = NSMutableAttributedString()
        if row.isPinned, let pin = NSImage(systemSymbolName: "pin.fill", accessibilityDescription: "Pinned") {
            let attachment = NSTextAttachment()
            attachment.image = pin.withSymbolConfiguration(.init(pointSize: 10, weight: .medium).applying(.init(paletteColors: [Theme.muted])))
            text.append(NSAttributedString(attachment: attachment))
            text.append(NSAttributedString(string: " ", attributes: [.font: Typography.rowLabel]))
        }
        text.append(NSAttributedString(string: row.title, attributes: [.font: Typography.rowLabel, .foregroundColor: NSColor.labelColor]))
        if row.isRunning {
            text.append(NSAttributedString(string: " · Running", attributes: [.font: Typography.rowDetail, .foregroundColor: Theme.muted]))
        }
        text.addAttribute(.paragraphStyle, value: singleLine, range: NSRange(location: 0, length: text.length))
        let label = label("", font: Typography.rowLabel, color: .labelColor)
        label.attributedStringValue = text
        return label
    }

    /// The excerpt in secondary color with the query's words in full-strength semibold, no background.
    private static func excerptLabel(_ excerpt: String, query: String) -> NSTextField {
        let text = NSMutableAttributedString(
            string: excerpt, attributes: [.font: Typography.rowDetail, .foregroundColor: NSColor.secondaryLabelColor])
        let matched = NSFont.systemFont(ofSize: Typography.rowDetail.pointSize, weight: .semibold)
        for range in SessionQueryHighlight.ranges(in: excerpt, query: query) {
            text.addAttributes([.font: matched, .foregroundColor: NSColor.labelColor], range: NSRange(range, in: excerpt))
        }
        text.addAttribute(.paragraphStyle, value: singleLine, range: NSRange(location: 0, length: text.length))
        let label = label("", font: Typography.rowDetail, color: .secondaryLabelColor)
        label.attributedStringValue = text
        return label
    }

    /// "place · Agent · size", with the reason and the id appended when the conversation cannot be resumed.
    private static func detailLine(_ row: SessionsPaneModel.Row) -> NSView {
        var detail = "\(row.placeText) · \(row.agentName) · \(row.sizeText)"
        guard let id = row.cannotResumeID else { return label(detail, font: Typography.metadata, color: Theme.muted) }
        detail += " · Folder no longer exists, can't resume · id"
        let message = label(detail, font: Typography.metadata, color: Theme.muted)
        message.setContentHuggingPriority(.required, for: .horizontal)
        let idField = label(id, font: Typography.monoMetadata, color: Theme.muted)
        idField.isSelectable = true
        idField.setAccessibilityIdentifier("sessions-row-id")
        let stack = NSStackView(views: [message, idField])
        stack.orientation = .horizontal
        stack.spacing = 4
        return stack
    }
}
