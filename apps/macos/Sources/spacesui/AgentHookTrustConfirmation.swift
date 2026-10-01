import AppKit
import spacesterminalcore

/// What the user is shown before Spaces asks an agent to trust its hooks: the exact commands the agent
/// will run, and what trusting them means. The commands are the device's own report of the entries the
/// agent has not trusted (`AgentHookStatus.untrustedEntries`), so the list is the consent the trust
/// records, not a description of it.
struct AgentHookTrustConfirmation: Equatable {
    let title: String
    let message: String
    let entries: [AgentHookEntry]
    let caution: String
    let footnote: String
    let confirmButtonTitle: String

    init(agentName: String, deviceName: String, entries: [AgentHookEntry]) {
        let count = entries.count
        title = "Trust Spaces' hooks in \(agentName) on \(deviceName)?"
        message =
            "\(agentName) will run \(count == 1 ? "this command" : "these \(count) commands") at points in every \(agentName) session, "
            + "in every folder, so Spaces can show when an agent is working, blocked, or done."
        caution =
            "Hooks run outside \(agentName)'s sandbox. Outside a Spaces terminal each command exits without doing anything. "
            + "Hooks from other tools are left as they are."
        footnote = "You can switch these hooks off later in \(agentName). A Spaces update that changes them asks for trust again."
        confirmButtonTitle = count == 1 ? "Trust 1 Hook" : "Trust \(count) Hooks"
        self.entries = entries
    }
}

extension AgentHookTrustConfirmation {
    /// The width of the command list, which sets the sheet's width. A command is a long absolute path
    /// plus its arguments, so it wraps inside this rather than widening the sheet past the window.
    static let listWidth: CGFloat = 460
    /// The tallest the command list grows before it scrolls.
    static let maximumListHeight: CGFloat = 200
    /// The event column's width: wide enough for the longest event name an agent binds.
    private static let eventColumnWidth: CGFloat = 116
    private static let listInset: CGFloat = 10

    /// Asks as a sheet on `window`. `onConfirm` runs only when the user picks the trust button, which is
    /// the default: trusting is what the user clicked to get here, and Codex can switch the hooks off
    /// again at any time.
    @MainActor func present(on window: NSWindow, onConfirm: @escaping @MainActor () -> Void) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: confirmButtonTitle)
        alert.addButton(withTitle: "Cancel")
        alert.accessoryView = accessoryView()
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            onConfirm()
        }
    }

    /// The command list, the caution under it, and the footnote, laid out at a fixed width. `NSAlert`
    /// sizes itself from its accessory view's frame, so the frame is set from the fitted layout.
    @MainActor private func accessoryView() -> NSView {
        let list = commandList()

        let cautionLabel = NSTextField(wrappingLabelWithString: caution)
        cautionLabel.font = Typography.metadata
        cautionLabel.textColor = .secondaryLabelColor
        cautionLabel.preferredMaxLayoutWidth = Self.listWidth

        let footnoteLabel = NSTextField(wrappingLabelWithString: footnote)
        footnoteLabel.font = Typography.metadata
        footnoteLabel.textColor = Theme.mutedSecondary
        footnoteLabel.preferredMaxLayoutWidth = Self.listWidth

        let stack = NSStackView(views: [list, cautionLabel, footnoteLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.setCustomSpacing(12, after: list)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            list.widthAnchor.constraint(equalToConstant: Self.listWidth), cautionLabel.widthAnchor.constraint(equalToConstant: Self.listWidth),
            footnoteLabel.widthAnchor.constraint(equalToConstant: Self.listWidth),
        ])
        stack.layoutSubtreeIfNeeded()
        stack.frame = NSRect(origin: .zero, size: stack.fittingSize)
        stack.translatesAutoresizingMaskIntoConstraints = true
        return stack
    }

    /// Every entry as its event beside its command, on the inset surface, scrolling past
    /// `maximumListHeight`. The commands are selectable so a user can copy one to check it.
    @MainActor private func commandList() -> NSView {
        let commandWidth = Self.listWidth - Self.eventColumnWidth - 10 - Self.listInset * 2
        let rows = NSStackView()
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 8
        rows.edgeInsets = NSEdgeInsets(top: Self.listInset, left: Self.listInset, bottom: Self.listInset, right: Self.listInset)
        rows.translatesAutoresizingMaskIntoConstraints = false
        for entry in entries {
            let event = NSTextField(labelWithString: entry.eventName)
            event.font = Typography.metadata
            event.textColor = .secondaryLabelColor
            event.lineBreakMode = .byTruncatingTail

            let command = NSTextField(wrappingLabelWithString: entry.command)
            command.font = Typography.monoMetadata
            command.textColor = .labelColor
            command.isSelectable = true
            command.lineBreakMode = .byCharWrapping
            command.preferredMaxLayoutWidth = commandWidth

            let row = NSStackView(views: [event, command])
            row.orientation = .horizontal
            row.alignment = .firstBaseline
            row.spacing = 10
            NSLayoutConstraint.activate([
                event.widthAnchor.constraint(equalToConstant: Self.eventColumnWidth), command.widthAnchor.constraint(equalToConstant: commandWidth),
            ])
            rows.addArrangedSubview(row)
        }
        rows.widthAnchor.constraint(equalToConstant: Self.listWidth).isActive = true
        rows.layoutSubtreeIfNeeded()
        let rowsHeight = rows.fittingSize.height

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = rowsHeight > Self.maximumListHeight
        scroll.borderType = .noBorder
        scroll.drawsBackground = true
        scroll.backgroundColor = Theme.surface2
        scroll.wantsLayer = true
        scroll.layer?.cornerRadius = 8
        scroll.layer?.masksToBounds = true
        scroll.documentView = rows
        NSLayoutConstraint.activate([
            rows.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            rows.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            scroll.heightAnchor.constraint(equalToConstant: min(rowsHeight, Self.maximumListHeight)),
        ])
        return scroll
    }
}
