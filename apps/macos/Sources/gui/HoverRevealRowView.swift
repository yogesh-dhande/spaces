import AppKit

@MainActor class HoverRevealRowView: NSView {
    private var actionButtons: [NSButton] = []
    private var trackingAreaRef: NSTrackingArea?
    private(set) var areActionButtonsVisible = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) not available") }

    func configureActionButtonsForHover(_ buttons: [NSButton]) {
        actionButtons = buttons
        setActionButtonsVisible(false, animated: false)
        updateTrackingAreas()
    }

    func setActionButtonsVisible(_ isVisible: Bool, animated: Bool) {
        areActionButtonsVisible = isVisible
        let updates = {
            for button in self.actionButtons {
                button.alphaValue = isVisible ? 1 : 0
                button.isEnabled = isVisible
            }
        }
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                context.allowsImplicitAnimation = true
                updates()
            }
        } else {
            updates()
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaRef {
            removeTrackingArea(trackingAreaRef)
            self.trackingAreaRef = nil
        }
        guard !actionButtons.isEmpty else { return }
        let trackingArea = NSTrackingArea(
            rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(trackingArea)
        trackingAreaRef = trackingArea
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        guard !actionButtons.isEmpty else { return }
        setActionButtonsVisible(true, animated: true)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        guard !actionButtons.isEmpty else { return }
        setActionButtonsVisible(false, animated: true)
    }
}
