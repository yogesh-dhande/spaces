import AppKit
import spacesterminalcore

/// A filter pop-up in the quiet control style: no bezel or border, the control fill, and a small chevron.
///
/// It wraps an `NSPopUpButton` rather than restyling one, because a bezel-less popup's title sits flush
/// against its edge and has nowhere to put padding or a chevron. The wrapper supplies both, and
/// forwards clicks on its padding to the popup so the whole pill opens the menu. Callers fill and read
/// `popUp` exactly as they would a bare pop-up.
@MainActor final class QuietPopUpView: NSView {
    static let height: CGFloat = 26

    let popUp = NSPopUpButton()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.required, for: .horizontal)
        wantsLayer = true
        layer?.cornerRadius = PaneLayout.controlRadius
        bindAppearanceReactiveLayer(self) { view in view.layer?.backgroundColor = Theme.controlFill.cgColor }

        popUp.isBordered = false
        popUp.font = Typography.rowDetail
        (popUp.cell as? NSPopUpButtonCell)?.arrowPosition = .noArrow
        popUp.translatesAutoresizingMaskIntoConstraints = false
        popUp.setContentHuggingPriority(.required, for: .horizontal)

        let chevron = NSImageView()
        chevron.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold))
        chevron.contentTintColor = Theme.mutedSecondary
        chevron.translatesAutoresizingMaskIntoConstraints = false
        chevron.setContentHuggingPriority(.required, for: .horizontal)

        addSubview(popUp)
        addSubview(chevron)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),
            popUp.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            popUp.centerYAnchor.constraint(equalTo: centerYAnchor),
            chevron.leadingAnchor.constraint(equalTo: popUp.trailingAnchor, constant: 4),
            chevron.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            chevron.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) not available") }

    override func mouseDown(with event: NSEvent) { popUp.performClick(nil) }
}
