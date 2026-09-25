import AppKit
import spacesdevicecore
import spacesterminalcore

/// The read-only column at a terminal pane's trailing edge that shows the pane's coding agent's brief:
/// a "Brief" header with how long ago the brief was written, over the rendered markdown in a
/// selectable, scrolling text view.
@MainActor final class AgentBriefColumnView: NSView {
    static let width: CGFloat = 300
    /// How often the "Updated …" caption re-reads the clock while the column is on screen, between the
    /// overview installs that also refresh it.
    private static let captionRefreshInterval: TimeInterval = 30

    let textView: NSTextView
    private let updatedLabel = NSTextField(labelWithString: "")
    private var renderedMarkdown: String?
    private var updatedAt: Date?
    private var captionRefreshTimer: Timer?

    init() {
        let scrollView = NSTextView.scrollableTextView()
        // `scrollableTextView()` always installs an `NSTextView` as the document view.
        textView = scrollView.documentView as! NSTextView
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityIdentifier("terminal-pane-brief")
        bindAppearanceReactiveLayer(self) { view in view.layer?.backgroundColor = Theme.surface.cgColor }

        let leadingEdge = NSView()
        leadingEdge.translatesAutoresizingMaskIntoConstraints = false
        bindAppearanceReactiveLayer(leadingEdge) { view in view.layer?.backgroundColor = Theme.border.cgColor }

        let titleLabel = NSTextField(labelWithString: "Brief")
        titleLabel.font = Typography.compactTitle
        titleLabel.textColor = Theme.text
        titleLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        updatedLabel.font = Typography.metadata
        updatedLabel.textColor = Theme.muted
        updatedLabel.lineBreakMode = .byTruncatingTail
        updatedLabel.alignment = .right
        updatedLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        updatedLabel.setAccessibilityIdentifier("terminal-pane-brief-updated")

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let header = NSStackView(views: [titleLabel, spacer, updatedLabel])
        header.orientation = .horizontal
        header.alignment = .firstBaseline
        header.spacing = 8
        header.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 4, right: 12)
        header.translatesAutoresizingMaskIntoConstraints = false

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 7, height: 4)
        textView.linkTextAttributes = [.foregroundColor: Theme.accent, .cursor: NSCursor.pointingHand]
        textView.setAccessibilityIdentifier("terminal-pane-brief-text")

        addSubview(leadingEdge)
        addSubview(header)
        addSubview(scrollView)
        NSLayoutConstraint.activate([
            leadingEdge.leadingAnchor.constraint(equalTo: leadingAnchor), leadingEdge.topAnchor.constraint(equalTo: topAnchor),
            leadingEdge.bottomAnchor.constraint(equalTo: bottomAnchor), leadingEdge.widthAnchor.constraint(equalToConstant: 1),
            header.topAnchor.constraint(equalTo: topAnchor), header.leadingAnchor.constraint(equalTo: leadingEdge.trailingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor), scrollView.topAnchor.constraint(equalTo: header.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingEdge.trailingAnchor), scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { nil }

    /// Shows `markdown`, re-rendering only when the text changed so a refresh that carries the same
    /// brief keeps the reader's scroll position and selection. The caption is re-read every time.
    func update(markdown: String, updatedAt: String?) {
        if markdown != renderedMarkdown {
            textView.textStorage?.setAttributedString(AgentBriefMarkdown.attributedString(from: markdown))
            renderedMarkdown = markdown
        }
        self.updatedAt = AutomationRunFormatting.date(updatedAt)
        refreshUpdatedCaption(now: Date())
    }

    /// The header's caption for a brief written at `updatedAt`, or nil when the device reported no time.
    /// A time under a minute old, or one a skewed device clock puts ahead of this Mac's, reads as just
    /// now rather than as a count of seconds.
    nonisolated static func updatedCaption(updatedAt: Date?, now: Date) -> String? {
        guard let updatedAt else { return nil }
        guard now.timeIntervalSince(updatedAt) >= 60 else { return "Updated just now" }
        return "Updated \(AutomationRunFormatting.relativePhrase(for: updatedAt, relativeTo: now))"
    }

    private func refreshUpdatedCaption(now: Date) {
        let caption = Self.updatedCaption(updatedAt: updatedAt, now: now)
        updatedLabel.stringValue = caption ?? ""
        updatedLabel.isHidden = caption == nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        captionRefreshTimer?.invalidate()
        captionRefreshTimer = nil
        guard window != nil else { return }
        refreshUpdatedCaption(now: Date())
        captionRefreshTimer = Timer.scheduledTimer(withTimeInterval: Self.captionRefreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshUpdatedCaption(now: Date()) }
        }
    }
}
