import AppKit
import spacesdevicecore
import spacesterminalcore

/// The palette's "Prompts" section label. It is a row of the table but never selectable.
@MainActor final class CommandPaletteHeaderCellView: NSTableCellView {
    static let height: CGFloat = 26

    init(title: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let label = NSTextField(labelWithString: title)
        label.font = Typography.captionTitle
        label.textColor = Theme.muted
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10), label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) not available") }
}

/// A saved prompt in the palette: its title, a one-line preview, the device when several are paired, and
/// the Return-to-copy hint on the selected row. Styled like a target row, which it sits beside.
@MainActor final class CommandPalettePromptCellView: NSTableCellView {
    private let iconView = NSImageView()
    private let titleField = NSTextField(labelWithString: "")
    private let previewField = NSTextField(labelWithString: "")
    private let deviceField = NSTextField(labelWithString: "")
    private let hintField = NSTextField(labelWithString: "\u{21A9} Copy")
    private let content = NSStackView()
    private var onClick: (() -> Void)?

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 7

        iconView.image = NSImage(systemSymbolName: "text.quote", accessibilityDescription: "Saved prompt")?.withSymbolConfiguration(
            .init(pointSize: 12, weight: .medium))
        iconView.setContentHuggingPriority(.required, for: .horizontal)

        titleField.font = Typography.sectionTitle
        titleField.textColor = Theme.text
        titleField.lineBreakMode = .byTruncatingTail
        titleField.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)

        previewField.font = Typography.rowDetail
        previewField.textColor = .secondaryLabelColor
        previewField.lineBreakMode = .byTruncatingTail
        previewField.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(100), for: .horizontal)

        deviceField.font = Typography.captionTitle
        deviceField.textColor = .secondaryLabelColor
        deviceField.setContentHuggingPriority(.required, for: .horizontal)
        deviceField.setContentCompressionResistancePriority(.required, for: .horizontal)

        hintField.font = Typography.monoBadge
        hintField.textColor = Theme.accent
        hintField.setContentHuggingPriority(.required, for: .horizontal)
        hintField.setContentCompressionResistancePriority(.required, for: .horizontal)

        content.setViews([iconView, titleField, previewField, deviceField, hintField], in: .leading)
        content.orientation = .horizontal
        content.alignment = .centerY
        content.spacing = 8
        content.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)
        content.detachesHiddenViews = true
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor), content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.topAnchor.constraint(equalTo: topAnchor), content.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        attachRowClickAction(to: self) { [weak self] in self?.onClick?() }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) not available") }

    func update(entry: SavedPromptLibrary.Entry, showsDevice: Bool, isSelected: Bool, onClick: @escaping () -> Void) {
        self.onClick = onClick
        titleField.stringValue = entry.prompt.title
        previewField.stringValue = SavedPromptsPaneModel.preview(entry.prompt.text)
        deviceField.stringValue = entry.deviceName
        deviceField.isHidden = !showsDevice
        hintField.isHidden = !isSelected
        iconView.contentTintColor = isSelected ? Theme.accent : .secondaryLabelColor
        layer?.borderWidth = isSelected ? 1 : 0
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = (isSelected ? Theme.rowSelectedCard : .clear).cgColor
            layer?.borderColor = (isSelected ? Theme.rowSelectedCardBorder : NSColor.clear).cgColor
        }
        setAccessibilityLabel("Saved prompt \(entry.prompt.title)")
    }
}
