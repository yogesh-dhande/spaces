import AppKit
import Foundation
import spacesterminalcore

/// What the user can answer a restore offer with. All or nothing by design: the record is one capture
/// of one moment's work, and picking through it row by row is a decision the user would have to make
/// before seeing any of the sessions again.
enum SessionRestoreAnswer: Equatable {
    case restore
    case skip
}

/// Renders a `SessionRestoreOffer`: the captured sessions grouped by workspace, with Restore all and
/// Skip. One view for both surfaces (the launch setup step, and the sheet a running app puts up), so
/// the offer looks and reads the same whenever it appears.
///
/// Held by whoever shows it: the buttons target this object, and `NSControl.target` is weak.
@MainActor final class SessionRestoreOfferView {
    /// The tallest the list grows before it starts scrolling. A record can hold as many agents as the
    /// user had running, while both surfaces that host this are fixed height, so an uncapped list would
    /// squeeze the answer buttons out of the sheet and leave the user with nothing to click.
    static let maximumListHeight: CGFloat = 240
    /// The list's width, which is also the offer's widest element and therefore what sets the layout's
    /// width. Fixed because the list lives in a scroll view, which has no width of its own to derive.
    static let listWidth: CGFloat = 520

    let view: NSView

    private let onAnswer: (SessionRestoreAnswer) -> Void
    private let restoreButton: NSButton
    private let skipButton: NSButton
    private let statusLabel: NSTextField

    init(offer: SessionRestoreOffer, host: any CodingAgentsHost, onAnswer: @escaping (SessionRestoreAnswer) -> Void) {
        self.onAnswer = onAnswer

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: "clock.arrow.circlepath", accessibilityDescription: nil)
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 40, weight: .regular)
        icon.contentTintColor = .controlAccentColor

        let title = NSTextField(labelWithString: "Pick up where you left off")
        title.font = Typography.sheetTitle
        title.alignment = .center

        let body = NSTextField(
            wrappingLabelWithString: "These coding agents were running when Spaces last stopped. Restore brings them all back where they were, "
                + "resuming the conversation each one was on, or starting a new one for the rows marked New conversation. "
                + "Skip lets them go, and Spaces does not offer them again.")
        body.font = Typography.body
        body.textColor = .secondaryLabelColor
        body.alignment = .center

        let skipButton = NSButton(title: "Skip", target: nil, action: nil)
        skipButton.bezelStyle = .rounded
        skipButton.controlSize = .large
        skipButton.setAccessibilityIdentifier("setup-restore-sessions-skip")
        self.skipButton = skipButton

        let restoreButton = NSButton(title: "Restore all", target: nil, action: nil)
        restoreButton.bezelStyle = .rounded
        restoreButton.controlSize = .large
        restoreButton.keyEquivalent = "\r"
        restoreButton.setAccessibilityIdentifier("setup-restore-sessions-restore")
        self.restoreButton = restoreButton

        // Wrapping, above the buttons rather than beside them: a device's reason for refusing an answer is
        // a sentence, not a word, and one sitting in the button row would push the buttons off the sheet.
        let statusLabel = NSTextField(wrappingLabelWithString: "")
        statusLabel.font = Typography.metadata
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.alignment = .center
        statusLabel.isHidden = true
        self.statusLabel = statusLabel

        let buttonRow = NSStackView(views: [skipButton, restoreButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 10

        let card = host.formSectionCard(
            icon: "clock.arrow.circlepath", title: "Unfinished sessions",
            subtitle: offer.rowCount == 1 ? "1 coding agent session" : "\(offer.rowCount) coding agent sessions", iconColor: nil, trailingView: nil,
            contentViews: Self.cardContents(offer: offer))
        card.translatesAutoresizingMaskIntoConstraints = false

        let list = NSScrollView()
        list.translatesAutoresizingMaskIntoConstraints = false
        list.hasVerticalScroller = true
        list.drawsBackground = false
        list.borderType = .noBorder
        list.documentView = card
        // The list takes exactly the height of its rows until it reaches the cap, at which point the cap
        // wins and the rows scroll. Everything around the list keeps its own size either way.
        let listFitsItsRows = list.heightAnchor.constraint(equalTo: card.heightAnchor)
        listFitsItsRows.priority = .defaultHigh

        let stack = NSStackView(views: [icon, title, body, list, statusLabel, buttonRow])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 14
        stack.setCustomSpacing(8, after: title)
        stack.setCustomSpacing(22, after: body)
        stack.setCustomSpacing(22, after: list)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let wrapper = NSView()
        wrapper.translatesAutoresizingMaskIntoConstraints = false
        wrapper.addSubview(stack)
        // The padding constraints sit just below required so a host shorter than the offer's own minimum
        // compresses the margins instead of breaking the layout outright.
        let topPadding = stack.topAnchor.constraint(greaterThanOrEqualTo: wrapper.topAnchor, constant: 24)
        let bottomPadding = stack.bottomAnchor.constraint(lessThanOrEqualTo: wrapper.bottomAnchor, constant: -24)
        topPadding.priority = .required - 1
        bottomPadding.priority = .required - 1
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: wrapper.centerXAnchor), stack.centerYAnchor.constraint(equalTo: wrapper.centerYAnchor),
            topPadding, bottomPadding, body.widthAnchor.constraint(lessThanOrEqualToConstant: 440),
            statusLabel.widthAnchor.constraint(lessThanOrEqualToConstant: Self.listWidth),
            list.widthAnchor.constraint(equalToConstant: Self.listWidth),
            list.heightAnchor.constraint(lessThanOrEqualToConstant: Self.maximumListHeight), listFitsItsRows,
            card.topAnchor.constraint(equalTo: list.contentView.topAnchor), card.leadingAnchor.constraint(equalTo: list.contentView.leadingAnchor),
            card.widthAnchor.constraint(equalTo: list.contentView.widthAnchor),
        ])
        view = wrapper

        skipButton.target = self
        skipButton.action = #selector(skipTapped)
        restoreButton.target = self
        restoreButton.action = #selector(restoreTapped)
    }

    /// Reports that the answer is being carried out. Both buttons go inert for the duration: the record
    /// is answered once, and the relaunch of several agents is not instant.
    func showAnswerInProgress(_ message: String) {
        statusLabel.stringValue = message
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.isHidden = false
        restoreButton.isEnabled = false
        skipButton.isEnabled = false
    }

    /// Reports an answer that never landed, and hands the offer back to the user: the buttons come alive
    /// again so they can try the same answer once the device is reachable, or Skip instead.
    func showAnswerFailed(_ message: String) {
        statusLabel.stringValue = message
        statusLabel.textColor = .systemRed
        statusLabel.isHidden = false
        restoreButton.isEnabled = true
        skipButton.isEnabled = true
    }

    @objc private func restoreTapped() { onAnswer(.restore) }

    @objc private func skipTapped() { onAnswer(.skip) }

    // MARK: - List

    private static func cardContents(offer: SessionRestoreOffer) -> [NSView] {
        var contents: [NSView] = []
        for device in offer.devices {
            if offer.namesDevices { contents.append(heading(device.deviceName, font: Typography.rowLabel)) }
            for group in device.groups {
                contents.append(heading(group.heading, font: Typography.metadata))
                for row in group.rows { contents.append(self.row(row, groupHeading: group.heading)) }
            }
        }
        return contents
    }

    private static func heading(_ text: String, font: NSFont) -> NSView {
        let label = NSTextField(labelWithString: text)
        label.font = font
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingMiddle
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }

    /// The line under a row's name, or nil when the row has nothing of its own to add. A group the client
    /// cannot name a workspace for is headed by its first row's working directory, so every row of such a
    /// group would otherwise repeat the heading verbatim.
    nonisolated static func rowCaption(_ row: SessionRestoreOffer.Row, groupHeading: String) -> String? {
        row.workingDirectory == groupHeading ? nil : row.workingDirectory
    }

    private static func row(_ row: SessionRestoreOffer.Row, groupHeading: String) -> NSView {
        let name = NSTextField(labelWithString: row.displayLabel)
        name.font = Typography.rowLabel
        name.lineBreakMode = .byTruncatingTail

        var labelViews: [NSView] = [name]
        if let caption = rowCaption(row, groupHeading: groupHeading) {
            let captionLabel = NSTextField(labelWithString: caption)
            captionLabel.font = Typography.metadata
            captionLabel.textColor = .secondaryLabelColor
            captionLabel.lineBreakMode = .byTruncatingMiddle
            labelViews.append(captionLabel)
        }

        let labels = NSStackView(views: labelViews)
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 2
        labels.setContentHuggingPriority(.defaultLow, for: .horizontal)

        var views: [NSView] = [labels, NSView()]
        if row.startsNewConversation {
            // The agent never reported a conversation id, so its relaunch cannot resume anything. Said
            // here rather than hidden behind the Restore button, because it changes what the user gets
            // back: the same command in the same place, with none of the conversation.
            let mark = NSTextField(labelWithString: "New conversation")
            mark.font = Typography.metadata
            mark.textColor = .secondaryLabelColor
            views.append(mark)
        }

        let view = NSStackView(views: views)
        view.orientation = .horizontal
        view.alignment = .centerY
        view.spacing = 12
        view.translatesAutoresizingMaskIntoConstraints = false
        // An element in its own right, so a traversal of the offer finds one node per captured session
        // carrying its identifier, rather than the loose labels a plain stack of text fields exposes.
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.group)
        view.setAccessibilityLabel(row.displayLabel)
        view.setAccessibilityIdentifier("setup-restore-sessions-row-\(row.sessionID)")
        return view
    }
}
