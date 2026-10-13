import AppKit
import spacesterminalcore

/// One summary card: a title with its caption beside it, and a line per device or subject. Lines are updated in
/// place, so a sample tick moves numbers and sparklines without rebuilding anything.
@MainActor final class ResourcesCardView: NSView {
    private let linesStack = NSStackView()
    private var lineViews: [String: ResourcesCardLineView] = [:]

    init(title: String, caption: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = Theme.cardCornerRadius
        layer?.borderWidth = 1
        bindAppearanceReactiveLayer(self) { view in
            view.layer?.backgroundColor = Theme.surface.cgColor
            view.layer?.borderColor = Theme.border.cgColor
        }

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = Typography.metadataTitle
        titleLabel.textColor = Theme.mutedSecondary
        let captionLabel = NSTextField(labelWithString: caption)
        captionLabel.font = Typography.caption
        captionLabel.textColor = Theme.muted

        linesStack.orientation = .vertical
        linesStack.alignment = .leading
        linesStack.spacing = 8

        let heading = NSStackView(views: [titleLabel, captionLabel])
        heading.orientation = .horizontal
        heading.alignment = .firstBaseline
        heading.spacing = 8

        let content = NSStackView(views: [heading, linesStack])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 8
        content.edgeInsets = Theme.cardContentInsets
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor), content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.topAnchor.constraint(equalTo: topAnchor), content.bottomAnchor.constraint(equalTo: bottomAnchor),
            linesStack.widthAnchor.constraint(
                equalTo: content.widthAnchor, constant: -(Theme.cardContentInsets.left + Theme.cardContentInsets.right)),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) not available") }

    func update(lines: [ResourcesCardLine]) {
        let ids = Set(lines.map(\.id))
        for (id, view) in lineViews where !ids.contains(id) {
            linesStack.removeArrangedSubview(view)
            view.removeFromSuperview()
            lineViews[id] = nil
        }
        for line in lines {
            let view =
                lineViews[line.id]
                ?? {
                    let created = ResourcesCardLineView()
                    lineViews[line.id] = created
                    return created
                }()
            view.update(line)
        }
        let ordered = lines.compactMap { lineViews[$0.id] }
        let current = linesStack.arrangedSubviews
        guard current.count != ordered.count || !zip(current, ordered).allSatisfy({ $0 === $1 }) else { return }
        // `removeArrangedSubview` throws for a view the stack does not hold, so only current views are
        // detached; a detached view keeps its superview, which is how a new line is told apart.
        for view in current { linesStack.removeArrangedSubview(view) }
        for view in ordered {
            let isNew = view.superview == nil
            linesStack.addArrangedSubview(view)
            if isNew { view.widthAnchor.constraint(equalTo: linesStack.widthAnchor).isActive = true }
        }
    }
}

/// A device's (or the app's) row inside a card: its name with muted detail inline, a sparkline, and
/// its CPU and memory. The sparkline and figures columns have fixed widths so they line up across
/// lines and cards; the name takes the rest and its detail truncates before the name does.
@MainActor final class ResourcesCardLineView: NSView {
    private static let sparklineWidth: CGFloat = 64
    /// Measured from the widest figures a device can report: CPU is a share of one core, so a busy
    /// 128-core machine reaches five digits, and memory reaches four digits of gigabytes. Wider than
    /// "Measuring…" and "Offline", so every state fits without truncating.
    private static let figuresWidth: CGFloat = ceil(
        ("88888% · 8888.8 GB" as NSString).size(withAttributes: [.font: Typography.tabularDigits(Typography.controlLabel)]).width)

    private let nameLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let figuresLabel = NSTextField(labelWithString: "")
    private let sparkline = ResourcesSparklineView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        nameLabel.font = Typography.controlLabel
        nameLabel.textColor = Theme.text
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.setContentHuggingPriority(.required, for: .horizontal)
        nameLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        detailLabel.font = Typography.monoCaption
        detailLabel.textColor = Theme.muted
        detailLabel.lineBreakMode = .byTruncatingTail
        detailLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        detailLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        figuresLabel.font = Typography.tabularDigits(Typography.controlLabel)
        figuresLabel.alignment = .right
        figuresLabel.lineBreakMode = .byTruncatingTail

        let names = NSStackView(views: [nameLabel, detailLabel])
        names.orientation = .horizontal
        names.alignment = .firstBaseline
        names.spacing = 6
        names.setContentHuggingPriority(.defaultLow, for: .horizontal)
        names.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        sparkline.translatesAutoresizingMaskIntoConstraints = false
        figuresLabel.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            sparkline.widthAnchor.constraint(equalToConstant: Self.sparklineWidth), sparkline.heightAnchor.constraint(equalToConstant: 20),
            figuresLabel.widthAnchor.constraint(equalToConstant: Self.figuresWidth),
        ])

        let row = NSStackView(views: [names, sparkline, figuresLabel])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor), row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor), row.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) not available") }

    func update(_ line: ResourcesCardLine) {
        nameLabel.stringValue = line.name
        detailLabel.stringValue = line.detail ?? ""
        detailLabel.isHidden = line.detail == nil
        figuresLabel.stringValue = line.summary
        if case .usage = line.content {
            figuresLabel.textColor = Theme.text
            sparkline.isHidden = false
            sparkline.values = line.history
        } else {
            // Measuring and offline lines have no figures to chart, and read as quiet status text.
            figuresLabel.textColor = Theme.muted
            sparkline.isHidden = true
        }
    }
}
