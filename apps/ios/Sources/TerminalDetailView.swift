import SwiftUI
import UIKit
import spacesmobilecore
import spacesterminalcore

struct TerminalDetailView: View {
    let session: SpacesMobileTerminalSessionSummary
    let settings: SpacesMobileConnectionSettings

    @State private var model: TerminalViewerModel

    init(session: SpacesMobileTerminalSessionSummary, settings: SpacesMobileConnectionSettings) {
        self.session = session
        self.settings = settings
        _model = State(initialValue: TerminalViewerModel(session: session, settings: settings))
    }

    var body: some View {
        VStack(spacing: 0) {
            TerminalSnapshotTextView(
                renderedSnapshot: model.snapshot.map(TerminalSnapshotAttributedRenderer.render),
                fallbackText: model.visibleText,
                acceptsInput: model.isOwner,
                isBusy: model.isBusy,
                onSendText: { text in
                    Task { await model.sendText(text) }
                },
                onSendKey: { key in
                    Task { await model.sendKey(key) }
                }
            )
            .background(Color(red: 0.10, green: 0.12, blue: 0.15))
            .overlay(alignment: .topTrailing) {
                if model.isConnecting {
                    ProgressView()
                        .controlSize(.small)
                        .padding(12)
                }
            }

            if let errorMessage = model.errorMessage {
                Divider()
                errorBanner(errorMessage)
            }
        }
        .navigationTitle(model.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !model.isOwner {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Take Over") {
                        Task { await model.takeOver() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isBusy)
                }
            }
        }
        .task { model.start() }
        .onDisappear { model.stop() }
    }

    private func errorBanner(_ message: String) -> some View {
        Text(message)
            .font(.footnote)
            .foregroundStyle(.red)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color(uiColor: .secondarySystemBackground))
    }
}

private struct TerminalSnapshotTextView: UIViewRepresentable {
    let renderedSnapshot: NSAttributedString?
    let fallbackText: String
    let acceptsInput: Bool
    let isBusy: Bool
    let onSendText: @MainActor (String) -> Void
    let onSendKey: @MainActor (String) -> Void

    func makeUIView(context: Context) -> TerminalSnapshotHostView {
        TerminalSnapshotHostView()
    }

    func updateUIView(_ hostView: TerminalSnapshotHostView, context: Context) {
        let nextValue = renderedSnapshot
            ?? NSAttributedString(
                string: fallbackText,
                attributes: TerminalSnapshotAttributedRenderer.fallbackAttributes
            )
        hostView.acceptsTerminalInput = acceptsInput && !isBusy
        hostView.onSendText = { text in
            Task { @MainActor in onSendText(text) }
        }
        hostView.onSendKey = { key in
            Task { @MainActor in onSendKey(key) }
        }
        hostView.updateSnapshot(nextValue)
    }
}

private final class TerminalSnapshotHostView: UIView, UIKeyInput {
    private let textView = UITextView()
    private lazy var activateInputRecognizer = UITapGestureRecognizer(target: self, action: #selector(handleTapToActivateInput))

    var acceptsTerminalInput = false
    var onSendText: ((String) -> Void)?
    var onSendKey: ((String) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        configureTextView()
        configureGestures()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var canBecomeFirstResponder: Bool { acceptsTerminalInput }

    var hasText: Bool { false }

    var autocorrectionType: UITextAutocorrectionType = .no
    var autocapitalizationType: UITextAutocapitalizationType = .none
    var spellCheckingType: UITextSpellCheckingType = .no
    var smartQuotesType: UITextSmartQuotesType = .no
    var smartDashesType: UITextSmartDashesType = .no
    var smartInsertDeleteType: UITextSmartInsertDeleteType = .no
    var keyboardType: UIKeyboardType = .asciiCapable
    var keyboardAppearance: UIKeyboardAppearance = .default
    var returnKeyType: UIReturnKeyType = .default
    var enablesReturnKeyAutomatically = false

    override func didMoveToWindow() {
        super.didMoveToWindow()
        syncFirstResponder()
    }

    func updateSnapshot(_ nextValue: NSAttributedString) {
        let wasNearBottom = textView.contentOffset.y >= max(textView.contentSize.height - textView.bounds.height - 40, 0)
        guard textView.attributedText != nextValue else {
            syncFirstResponder()
            return
        }
        textView.attributedText = nextValue
        if wasNearBottom {
            let bottomOffset = CGPoint(x: 0, y: max(textView.contentSize.height - textView.bounds.height, 0))
            textView.setContentOffset(bottomOffset, animated: false)
        }
        syncFirstResponder()
    }

    override var keyCommands: [UIKeyCommand]? {
        guard acceptsTerminalInput else { return [] }
        return [
            UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(handleEscape)),
            UIKeyCommand(input: "c", modifierFlags: .control, action: #selector(handleControlC)),
            UIKeyCommand(input: UIKeyCommand.inputUpArrow, modifierFlags: [], action: #selector(handleUpArrow)),
            UIKeyCommand(input: UIKeyCommand.inputDownArrow, modifierFlags: [], action: #selector(handleDownArrow)),
            UIKeyCommand(input: UIKeyCommand.inputLeftArrow, modifierFlags: [], action: #selector(handleLeftArrow)),
            UIKeyCommand(input: UIKeyCommand.inputRightArrow, modifierFlags: [], action: #selector(handleRightArrow)),
            UIKeyCommand(input: "\t", modifierFlags: [], action: #selector(handleTab)),
        ]
    }

    func insertText(_ text: String) {
        guard acceptsTerminalInput else { return }
        guard !text.isEmpty else { return }
        if text == "\n" {
            onSendKey?("enter")
        } else {
            onSendText?(text)
        }
    }

    func deleteBackward() {
        guard acceptsTerminalInput else { return }
        onSendKey?("backspace")
    }

    override func paste(_ sender: Any?) {
        guard acceptsTerminalInput else { return }
        if let pasted = UIPasteboard.general.string, !pasted.isEmpty {
            onSendText?(pasted)
        }
    }

    @objc private func handleEscape() { onSendKey?("esc") }
    @objc private func handleControlC() { onSendKey?("ctrl+c") }
    @objc private func handleUpArrow() { onSendKey?("up") }
    @objc private func handleDownArrow() { onSendKey?("down") }
    @objc private func handleLeftArrow() { onSendKey?("left") }
    @objc private func handleRightArrow() { onSendKey?("right") }
    @objc private func handleTab() { onSendKey?("tab") }

    @objc private func handleTapToActivateInput() {
        guard acceptsTerminalInput else { return }
        becomeFirstResponder()
    }

    private func configureTextView() {
        backgroundColor = TerminalSnapshotAttributedRenderer.defaultBackgroundColor
        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.isEditable = false
        textView.isSelectable = true
        textView.backgroundColor = TerminalSnapshotAttributedRenderer.defaultBackgroundColor
        textView.textContainerInset = UIEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        textView.textContainer.lineFragmentPadding = 0
        textView.alwaysBounceVertical = true
        textView.alwaysBounceHorizontal = true
        textView.showsHorizontalScrollIndicator = true
        textView.showsVerticalScrollIndicator = true
        textView.adjustsFontForContentSizeCategory = false
        textView.keyboardDismissMode = .interactive
        addSubview(textView)
        NSLayoutConstraint.activate([
            textView.leadingAnchor.constraint(equalTo: leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: trailingAnchor),
            textView.topAnchor.constraint(equalTo: topAnchor),
            textView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    private func configureGestures() {
        activateInputRecognizer.cancelsTouchesInView = false
        textView.addGestureRecognizer(activateInputRecognizer)
    }

    private func syncFirstResponder() {
        guard window != nil else { return }
        if acceptsTerminalInput {
            if !isFirstResponder { becomeFirstResponder() }
        } else if isFirstResponder {
            resignFirstResponder()
        }
    }
}

@MainActor private enum TerminalSnapshotAttributedRenderer {
    static let defaultBackgroundColor = UIColor(red: 0.10, green: 0.12, blue: 0.15, alpha: 1)
    static let defaultForegroundColor = UIColor.white
    static let fallbackAttributes: [NSAttributedString.Key: Any] = [
        .font: UIFont.monospacedSystemFont(ofSize: 13, weight: .regular),
        .foregroundColor: defaultForegroundColor,
        .backgroundColor: defaultBackgroundColor,
    ]

    static func render(_ snapshot: GhosttyTerminalSnapshot) -> NSAttributedString {
        let rendered = NSMutableAttributedString()
        let lines = GhosttyTerminalSnapshotLayout.lines(for: snapshot)
        for (lineIndex, line) in lines.enumerated() {
            for run in line.runs {
                rendered.append(NSAttributedString(string: run.text, attributes: attributes(for: run)))
            }
            if lineIndex < lines.count - 1 {
                rendered.append(NSAttributedString(string: "\n", attributes: fallbackAttributes))
            }
        }
        return rendered
    }

    private static func attributes(for run: GhosttyTerminalSnapshotDisplayRun) -> [NSAttributedString.Key: Any] {
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font(for: run),
            .foregroundColor: color(rgb: run.foregroundRGB, alpha: run.isFaint ? 0.65 : 1),
            .backgroundColor: color(rgb: run.backgroundRGB)
        ]
        if run.isUnderline {
            attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
            attributes[.underlineColor] = color(rgb: run.foregroundRGB, alpha: run.isFaint ? 0.65 : 1)
        }
        if run.isStrikethrough {
            attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            attributes[.strikethroughColor] = color(rgb: run.foregroundRGB, alpha: run.isFaint ? 0.65 : 1)
        }
        return attributes
    }

    private static func font(for run: GhosttyTerminalSnapshotDisplayRun) -> UIFont {
        if run.isBold, run.isItalic {
            return UIFont.monospacedSystemFont(ofSize: 13, weight: .bold).italicized()
        }
        if run.isBold {
            return UIFont.monospacedSystemFont(ofSize: 13, weight: .bold)
        }
        if run.isItalic {
            return UIFont.monospacedSystemFont(ofSize: 13, weight: .regular).italicized()
        }
        return UIFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    }

    private static func color(rgb: UInt32, alpha: CGFloat = 1) -> UIColor {
        UIColor(
            red: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: alpha
        )
    }
}

private extension UIFont {
    func italicized() -> UIFont {
        guard let descriptor = fontDescriptor.withSymbolicTraits([.traitItalic]) else { return self }
        return UIFont(descriptor: descriptor, size: pointSize)
    }
}
