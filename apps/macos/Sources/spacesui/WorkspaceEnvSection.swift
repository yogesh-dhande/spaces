import AppKit
import spacesterminalcore

/// Read-only card in the workspace settings dialog listing the environment variables the daemon
/// injects into every process and terminal of the workspace. The values are authoritative (computed
/// by the owning daemon and carried on the workspace summary), rendered as a selectable, wrapping
/// monospaced `KEY=value` block the user can select to copy. There is no `onCommit`: this section
/// only reports what processes receive, it does not edit configuration.
@MainActor final class WorkspaceEnvSection {
    let view: NSView

    init(environment: [String: String]) {
        // Sort by name for a stable, scannable order across refreshes.
        let block = environment.keys.sorted().map { key in "\(key)=\(environment[key] ?? "")" }.joined(separator: "\n")

        let titleLabel = NSTextField(labelWithString: "Environment")
        titleLabel.font = Typography.sectionTitle
        titleLabel.textColor = Theme.text

        let subtitleLabel = NSTextField(labelWithString: "Injected into every process and terminal in this workspace.")
        subtitleLabel.font = Typography.metadata
        subtitleLabel.textColor = Theme.muted
        subtitleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let titleStack = NSStackView(views: [titleLabel, subtitleLabel])
        titleStack.orientation = .vertical
        titleStack.alignment = .leading
        titleStack.spacing = 2
        titleStack.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 0, right: 14)

        let body = NSTextField(labelWithString: block.isEmpty ? "(none)" : block)
        body.font = Typography.monoMetadata
        body.textColor = block.isEmpty ? Theme.mutedSecondary : Theme.muted
        body.isSelectable = true
        body.maximumNumberOfLines = 0
        body.lineBreakMode = .byCharWrapping
        body.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        body.setAccessibilityIdentifier("workspace-env-values")

        let bodyRow = NSStackView(views: [body])
        bodyRow.orientation = .horizontal
        bodyRow.alignment = .top
        bodyRow.edgeInsets = NSEdgeInsets(top: 8, left: 14, bottom: 10, right: 14)

        let stack = NSStackView(views: [titleStack, bodyRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false

        let card = ColoredBackgroundView()
        card.fillColor = .clear
        card.cornerRadius = Theme.cardCornerRadius
        card.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor), stack.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            stack.topAnchor.constraint(equalTo: card.topAnchor), stack.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            titleStack.widthAnchor.constraint(equalTo: stack.widthAnchor), bodyRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            // Bound the value block to the card width (minus the row's 14pt insets) so long values wrap
            // instead of stretching the dialog, and the label reports the right multi-line height.
            body.widthAnchor.constraint(equalTo: bodyRow.widthAnchor, constant: -28),
        ])
        self.view = card
    }
}
