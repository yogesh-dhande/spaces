import AppKit

/// Shared scaffolding for the workspace-detail "section" views (Processes,
/// Coding Agents, Browser Sessions, Ports). Each renders a header with a title,
/// a live count, an optional subtitle, and a trailing "+ add" button; the only
/// per-section differences are the title text and the add button's
/// accessibility identifier.
enum RowSectionHeader {
    static func make(title: String, addButtonAccessibilityIdentifier: String, countLabel: NSTextField, subtitle: String? = nil) -> NSStackView {
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = Theme.text

        countLabel.font = .systemFont(ofSize: 11, weight: .medium)
        countLabel.textColor = Theme.muted

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let addButton = NSButton(title: "+ add", target: nil, action: nil)
        addButton.bezelStyle = .inline
        addButton.isBordered = false
        addButton.contentTintColor = Theme.muted
        addButton.font = .systemFont(ofSize: 11.5, weight: .medium)
        addButton.setAccessibilityIdentifier(addButtonAccessibilityIdentifier)

        if let subtitle {
            // Count sits inline with the title; subtitle goes below the title row.
            let titleRow = NSStackView(views: [titleLabel, countLabel])
            titleRow.orientation = .horizontal
            titleRow.alignment = .firstBaseline
            titleRow.spacing = 6
            titleRow.setContentHuggingPriority(.defaultLow, for: .horizontal)

            let subtitleLabel = NSTextField(labelWithString: subtitle)
            subtitleLabel.font = .systemFont(ofSize: 11, weight: .regular)
            subtitleLabel.textColor = Theme.muted
            subtitleLabel.lineBreakMode = .byTruncatingTail
            subtitleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

            let titleStack = NSStackView(views: [titleRow, subtitleLabel])
            titleStack.orientation = .vertical
            titleStack.alignment = .leading
            titleStack.spacing = 2
            titleStack.setContentHuggingPriority(.defaultLow, for: .horizontal)

            let header = NSStackView(views: [titleStack, spacer, addButton])
            header.orientation = .horizontal
            header.alignment = .centerY
            header.spacing = 8
            header.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 14)
            header.translatesAutoresizingMaskIntoConstraints = false
            return header
        }

        let header = NSStackView(views: [titleLabel, countLabel, spacer, addButton])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 8
        header.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 14)
        header.translatesAutoresizingMaskIntoConstraints = false
        return header
    }
}

extension Array {
    /// Bounds-checked subscript shared by the row-section views.
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

/// Wraps a section's content in the standard transparent rounded "card" used
/// across the workspace-detail sections.
@MainActor enum RowSectionCard {
    private static var ownerKey: UInt8 = 0

    /// Pins `content` to the edges of a fresh card view and returns the card.
    static func wrap(_ content: NSView) -> NSView {
        let card = ColoredBackgroundView()
        card.fillColor = .clear
        card.cornerRadius = 10
        card.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: card.leadingAnchor), content.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            content.topAnchor.constraint(equalTo: card.topAnchor), content.bottomAnchor.constraint(equalTo: card.bottomAnchor),
        ])
        return card
    }

    /// Associates `owner` with `card` so the section object stays alive while
    /// its view is in the hierarchy. Call once the section is fully initialized.
    static func retain(_ owner: AnyObject, in card: NSView) {
        objc_setAssociatedObject(card, &ownerKey, owner, .OBJC_ASSOCIATION_RETAIN)
    }
}

extension NSStackView {
    /// Removes and detaches every arranged subview. Shared by the row sections
    /// when they re-render their rows stack.
    func removeAllArrangedSubviews() {
        for arrangedSubview in arrangedSubviews {
            removeArrangedSubview(arrangedSubview)
            arrangedSubview.removeFromSuperview()
        }
    }
}
