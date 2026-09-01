import AppKit
import Carbon
import spacesterminalcore
import systembridge

/// Stateless AppKit view factories shared by the settings, project, workspace, and automation
/// forms. Each builds a view tree purely from its parameters — no stored host state — so a
/// button's `target` and any host-owned color (the sidebar's theme-reactive card colors) are
/// passed in explicitly rather than reached for through a host reference.

/// A titled control row: a name label, an optional wrapping hint, then the control itself,
/// stacked vertically and constrained to the stack's width.
@MainActor func settingsLabeledField(name: String, hint: String, control: NSView) -> NSView {
    let nameLabel = NSTextField(labelWithString: name)
    nameLabel.font = Typography.rowLabel

    control.translatesAutoresizingMaskIntoConstraints = false
    control.setContentHuggingPriority(.defaultLow, for: .horizontal)

    let stack = NSStackView()
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 6
    stack.addArrangedSubview(nameLabel)
    if !hint.isEmpty {
        let hintLabel = NSTextField(labelWithString: hint)
        hintLabel.font = Typography.metadata
        hintLabel.textColor = .secondaryLabelColor
        hintLabel.lineBreakMode = .byWordWrapping
        hintLabel.maximumNumberOfLines = 2
        hintLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        stack.addArrangedSubview(hintLabel)
    }
    stack.addArrangedSubview(control)
    control.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    return stack
}

/// A form section card: an optional icon, a title/subtitle header, an optional trailing view,
/// the given content views, and a bottom divider.
///
/// `defaultAccentColor` and `dividerColor` are the sidebar's theme-reactive colors
/// (`sidebarThemeColor`/`sidebarCardBorderColor`), resolved by the caller and passed in as plain
/// `NSColor` values rather than as a host reference. Both colors carry their own dynamic
/// light/dark provider (see `SidebarController.sidebarThemeColor`), so capturing the already-
/// resolved `NSColor` instance in the divider's appearance-reactive closure below still re-derives
/// the correct `CGColor` on every appearance change — only a `CGColor` captured at assignment time
/// would go stale.
@MainActor func formSectionCard(
    icon: String?, title: String, subtitle: String = "", iconColor: NSColor? = nil, trailingView: NSView? = nil, contentViews: [NSView],
    defaultAccentColor: NSColor, dividerColor: NSColor
) -> NSView {
    let section = NSView()
    section.translatesAutoresizingMaskIntoConstraints = false
    section.setContentHuggingPriority(.required, for: .vertical)

    let accentColor = iconColor ?? defaultAccentColor

    let titleLabel = NSTextField(labelWithString: title)
    titleLabel.font = Typography.cardTitle
    titleLabel.textColor = .labelColor

    let subtitleLabel = NSTextField(labelWithString: subtitle)
    subtitleLabel.font = Typography.rowDetail
    subtitleLabel.textColor = .secondaryLabelColor
    subtitleLabel.lineBreakMode = .byWordWrapping
    subtitleLabel.maximumNumberOfLines = 2
    subtitleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

    let titleStack = NSStackView()
    titleStack.orientation = .vertical
    titleStack.alignment = .leading
    titleStack.spacing = 2
    titleStack.addArrangedSubview(titleLabel)
    if !subtitle.isEmpty { titleStack.addArrangedSubview(subtitleLabel) }
    titleStack.setContentHuggingPriority(.defaultLow, for: .horizontal)

    let headerRow = NSStackView()
    headerRow.orientation = .horizontal
    headerRow.alignment = .top
    headerRow.spacing = 10
    if let icon {
        let iconView = NSImageView()
        if let img = NSImage(systemSymbolName: icon, accessibilityDescription: title) {
            let config = NSImage.SymbolConfiguration(paletteColors: [accentColor])
            iconView.image = img.withSymbolConfiguration(config)
        }
        iconView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([iconView.widthAnchor.constraint(equalToConstant: 20), iconView.heightAnchor.constraint(equalToConstant: 20)])
        headerRow.addArrangedSubview(iconView)
    }
    headerRow.addArrangedSubview(titleStack)
    if let trailing = trailingView {
        trailing.setContentHuggingPriority(.required, for: .horizontal)
        headerRow.addArrangedSubview(trailing)
    }

    let innerStack = NSStackView()
    innerStack.orientation = .vertical
    innerStack.alignment = .leading
    innerStack.spacing = 12
    innerStack.translatesAutoresizingMaskIntoConstraints = false
    innerStack.addArrangedSubview(headerRow)
    for view in contentViews { innerStack.addArrangedSubview(view) }

    let divider = NSView()
    divider.translatesAutoresizingMaskIntoConstraints = false
    divider.wantsLayer = true
    bindAppearanceReactiveLayer(divider) { view in view.layer?.backgroundColor = dividerColor.withAlphaComponent(0.55).cgColor }

    section.addSubview(innerStack)
    section.addSubview(divider)
    NSLayoutConstraint.activate([
        innerStack.leadingAnchor.constraint(equalTo: section.leadingAnchor),
        innerStack.trailingAnchor.constraint(equalTo: section.trailingAnchor),
        innerStack.topAnchor.constraint(equalTo: section.topAnchor, constant: 4),

        divider.leadingAnchor.constraint(equalTo: section.leadingAnchor), divider.trailingAnchor.constraint(equalTo: section.trailingAnchor),
        divider.topAnchor.constraint(equalTo: innerStack.bottomAnchor, constant: 18), divider.heightAnchor.constraint(equalToConstant: 1),
        divider.bottomAnchor.constraint(equalTo: section.bottomAnchor),
    ])
    headerRow.translatesAutoresizingMaskIntoConstraints = false
    headerRow.widthAnchor.constraint(equalTo: innerStack.widthAnchor).isActive = true
    for view in contentViews {
        view.translatesAutoresizingMaskIntoConstraints = false
        view.widthAnchor.constraint(equalTo: innerStack.widthAnchor).isActive = true
    }

    return section
}

/// A form window's header row: symbol, title, and a trailing close button. `target` is the
/// close button's action target — every caller passes the host that owns `closeAction`.
@MainActor func buildFormWindowHeader(symbol: String, title: String, closeAction: Selector, target: AnyObject?) -> NSView {
    let header = NSView()

    let iconView = NSImageView()
    iconView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
    iconView.contentTintColor = .secondaryLabelColor
    iconView.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([iconView.widthAnchor.constraint(equalToConstant: 18), iconView.heightAnchor.constraint(equalToConstant: 18)])

    let titleLabel = NSTextField(labelWithString: title)
    titleLabel.font = Typography.sheetTitle
    titleLabel.textColor = .labelColor

    let closeButton = iconButton(symbol: "xmark", tooltip: "Close", action: closeAction, target: target)
    closeButton.keyEquivalent = "\u{1b}"

    let stack = NSStackView(views: [iconView, titleLabel, NSView(), closeButton])
    stack.orientation = .horizontal
    stack.alignment = .centerY
    stack.spacing = 10
    stack.edgeInsets = NSEdgeInsets(top: 0, left: 18, bottom: 0, right: 14)
    stack.translatesAutoresizingMaskIntoConstraints = false

    header.addSubview(stack)
    NSLayoutConstraint.activate([
        stack.leadingAnchor.constraint(equalTo: header.leadingAnchor), stack.trailingAnchor.constraint(equalTo: header.trailingAnchor),
        stack.topAnchor.constraint(equalTo: header.topAnchor), stack.bottomAnchor.constraint(equalTo: header.bottomAnchor),
    ])
    return header
}

@MainActor func helpTextLabel(_ text: String) -> NSTextField {
    let label = NSTextField(labelWithString: text)
    label.font = Typography.metadata
    label.textColor = .tertiaryLabelColor
    label.lineBreakMode = .byWordWrapping
    label.maximumNumberOfLines = 0
    // Without lowered horizontal compression resistance the label's intrinsic width becomes a hard
    // floor, so a long unbreakable token (e.g. a file path in an error message) forces the whole
    // container — and the resizable settings window — wider. Let it shrink and wrap instead.
    label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    return label
}

@MainActor func iconButton(symbol: String, tooltip: String, action: Selector, target: AnyObject?) -> NSButton {
    let button = NSButton(title: "", target: target, action: action)
    button.bezelStyle = .texturedRounded
    button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)
    button.toolTip = tooltip
    return button
}

@MainActor func actionButton(title: String, symbol: String?, tooltip: String, action: Selector, primary: Bool, target: AnyObject?) -> NSButton {
    let button = NSButton(title: title, target: target, action: action)
    button.bezelStyle = primary ? .rounded : .texturedRounded
    if let symbol {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)
        button.imagePosition = .imageLeading
        button.imageHugsTitle = true
    }
    button.toolTip = tooltip
    if primary { stylePrimaryActionButton(button, title: title) }
    return button
}

@MainActor private func stylePrimaryActionButton(_ button: NSButton, title: String) {
    Theme.applyPrimaryStyle(to: button)
    if let image = button.image { button.image = image.withSymbolConfiguration(.init(paletteColors: [Theme.primaryButtonText])) }
}

@MainActor func constrainFormFieldToFillWidth(_ view: NSView, in stack: NSStackView) {
    view.translatesAutoresizingMaskIntoConstraints = false
    view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
}

@MainActor func labeledInputRow(label text: String, input: NSView, labelWidth: CGFloat = 108) -> NSStackView {
    let row = NSStackView()
    row.orientation = .horizontal
    row.alignment = .centerY
    row.spacing = 12
    let labelField = NSTextField(labelWithString: text)
    labelField.font = Typography.compactTitle
    labelField.textColor = .secondaryLabelColor
    labelField.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([labelField.widthAnchor.constraint(equalToConstant: labelWidth)])
    labelField.setContentHuggingPriority(.required, for: .horizontal)
    labelField.setContentCompressionResistancePriority(.required, for: .horizontal)
    input.setContentHuggingPriority(.defaultLow, for: .horizontal)
    input.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    row.addArrangedSubview(labelField)
    row.addArrangedSubview(input)
    return row
}

/// Embeds `stack` in a vertically scrolling container filling `container`. `container` was
/// previously an optional that fell back to the host's `detailContainer`; callers that relied on
/// that default now pass it explicitly.
@MainActor func showScrollableDetailStack(_ stack: NSStackView, in container: NSView) {
    let scroll = NSScrollView()
    scroll.translatesAutoresizingMaskIntoConstraints = false
    scroll.hasVerticalScroller = true
    scroll.hasHorizontalScroller = false
    scroll.autohidesScrollers = true
    scroll.borderType = .noBorder
    scroll.drawsBackground = false
    scroll.contentView.drawsBackground = false

    let contentView = NSView()
    contentView.translatesAutoresizingMaskIntoConstraints = false
    scroll.documentView = contentView
    contentView.addSubview(stack)

    container.addSubview(scroll)
    NSLayoutConstraint.activate([
        scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        scroll.topAnchor.constraint(equalTo: container.topAnchor), scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor),

        contentView.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
        contentView.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
        contentView.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
        contentView.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        contentView.bottomAnchor.constraint(greaterThanOrEqualTo: scroll.contentView.bottomAnchor),

        stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
        stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
        stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 20),
        stack.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -20),
    ])
}

/// A bordered, tinted scroll view wrapping `textView`. `inputBackgroundColor` and `borderColor`
/// are the sidebar's theme-reactive colors, resolved by the caller (see `formSectionCard` above
/// for why passing the resolved `NSColor` still keeps the border reactive to appearance changes).
@MainActor func scrollableTextView(_ textView: NSTextView, height: CGFloat, inputBackgroundColor: NSColor, borderColor: NSColor) -> NSScrollView {
    let scroll = NSScrollView()
    scroll.hasVerticalScroller = true
    scroll.hasHorizontalScroller = false
    scroll.autohidesScrollers = true
    scroll.borderType = .noBorder
    let inputBg = inputBackgroundColor
    scroll.drawsBackground = true
    scroll.backgroundColor = inputBg
    scroll.contentView.drawsBackground = true
    scroll.contentView.backgroundColor = inputBg
    scroll.wantsLayer = true
    scroll.layer?.cornerRadius = UIRadius.compact
    scroll.layer?.borderWidth = 1
    bindAppearanceReactiveLayer(scroll) { view in view.layer?.borderColor = borderColor.cgColor }
    textView.drawsBackground = true
    textView.backgroundColor = inputBg
    textView.textColor = .textColor
    textView.textContainerInset = NSSize(width: 6, height: 6)
    textView.minSize = NSSize(width: 0, height: height)
    textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    textView.isVerticallyResizable = true
    textView.isHorizontallyResizable = false
    textView.autoresizingMask = [.width]
    textView.textContainer?.widthTracksTextView = true
    scroll.documentView = textView
    scroll.translatesAutoresizingMaskIntoConstraints = false
    scroll.heightAnchor.constraint(equalToConstant: height).isActive = true
    return scroll
}

/// Text view backing the workspace notes inline editor: ⌘↩ saves, Escape cancels.
final class InlineWorkspaceEditorTextView: NSTextView {
    var onSave: (() -> Void)?
    var onCancel: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        switch Int(event.keyCode) {
        case kVK_Escape:
            onCancel?()
            return
        case kVK_Return, kVK_ANSI_KeypadEnter:
            if flags == .command {
                onSave?()
                return
            }
        default: break
        }
        super.keyDown(with: event)
    }

    override func doCommand(by selector: Selector) {
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            onCancel?()
            return
        }
        super.doCommand(by: selector)
    }
}

@MainActor func makeEditableTextView() -> InlineWorkspaceEditorTextView {
    let textView = InlineWorkspaceEditorTextView()
    textView.isEditable = true
    textView.isSelectable = true
    textView.isRichText = false
    textView.allowsUndo = true
    textView.font = Typography.monoBody
    textView.textContainerInset = NSSize(width: 6, height: 6)
    textView.isVerticallyResizable = true
    textView.isHorizontallyResizable = false
    textView.textContainer?.widthTracksTextView = true
    textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
    return textView
}
