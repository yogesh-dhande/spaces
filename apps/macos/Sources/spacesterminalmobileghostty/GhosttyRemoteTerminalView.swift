import Foundation

#if canImport(UIKit)
    import GhosttyKit
    import SwiftUI
    import UIKit
    import spacesterminalcore

    public struct GhosttyRemoteTerminalView: UIViewRepresentable {
        public let snapshot: GhosttyTerminalSnapshot?
        public let fallbackText: String
        public let acceptsInput: Bool
        public let isBusy: Bool
        public let onSendText: @MainActor (String) -> Void
        public let onSendKey: @MainActor (String) -> Void

        public init(
            snapshot: GhosttyTerminalSnapshot?, fallbackText: String, acceptsInput: Bool, isBusy: Bool,
            onSendText: @escaping @MainActor (String) -> Void, onSendKey: @escaping @MainActor (String) -> Void
        ) {
            self.snapshot = snapshot
            self.fallbackText = fallbackText
            self.acceptsInput = acceptsInput
            self.isBusy = isBusy
            self.onSendText = onSendText
            self.onSendKey = onSendKey
        }

        public func makeUIView(context: Context) -> GhosttyRemoteTerminalHostView { GhosttyRemoteTerminalHostView() }

        public func updateUIView(_ hostView: GhosttyRemoteTerminalHostView, context: Context) {
            hostView.acceptsTerminalInput = acceptsInput && !isBusy
            hostView.onSendText = { text in Task { @MainActor in onSendText(text) } }
            hostView.onSendKey = { key in Task { @MainActor in onSendKey(key) } }
            hostView.update(snapshot: snapshot, fallbackText: fallbackText)
        }
    }

    @MainActor public final class GhosttyRemoteTerminalHostView: UIView, UIKeyInput {
        private var session: ghostty_session_t?
        private var lastSnapshot: GhosttyTerminalSnapshot?
        private let fallbackLabel = UILabel()
        private lazy var activateInputRecognizer = UITapGestureRecognizer(target: self, action: #selector(handleTapToActivateInput))

        public var acceptsTerminalInput = false
        public var onSendText: ((String) -> Void)?
        public var onSendKey: ((String) -> Void)?

        public override class var layerClass: AnyClass { CAMetalLayer.self }
        public override var canBecomeFirstResponder: Bool { acceptsTerminalInput }

        public var hasText: Bool { false }
        public var autocorrectionType: UITextAutocorrectionType = .no
        public var autocapitalizationType: UITextAutocapitalizationType = .none
        public var spellCheckingType: UITextSpellCheckingType = .no
        public var smartQuotesType: UITextSmartQuotesType = .no
        public var smartDashesType: UITextSmartDashesType = .no
        public var smartInsertDeleteType: UITextSmartInsertDeleteType = .no
        public var keyboardType: UIKeyboardType = .asciiCapable
        public var keyboardAppearance: UIKeyboardAppearance = .default
        public var returnKeyType: UIReturnKeyType = .default
        public var enablesReturnKeyAutomatically = false

        public override init(frame: CGRect) {
            super.init(frame: frame)
            backgroundColor = UIColor(red: 0.10, green: 0.12, blue: 0.15, alpha: 1)
            isOpaque = true
            configureFallbackLabel()
            configureGestures()
        }

        @available(*, unavailable) required init?(coder: NSCoder) { nil }

        deinit { MainActor.assumeIsolated { if let session { ghostty_session_free(session) } } }

        public override func didMoveToWindow() {
            super.didMoveToWindow()
            ensureSession()
            syncSessionState()
        }

        public override func layoutSubviews() {
            super.layoutSubviews()
            syncSessionState()
        }

        public override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
            super.traitCollectionDidChange(previousTraitCollection)
            syncSessionState()
        }

        public override var keyCommands: [UIKeyCommand]? {
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

        public func update(snapshot: GhosttyTerminalSnapshot?, fallbackText: String) {
            ensureSession()
            fallbackLabel.text = snapshot == nil ? fallbackText : nil
            fallbackLabel.isHidden = snapshot != nil
            syncFirstResponder()

            guard let session, let snapshot, snapshot != lastSnapshot else { return }
            replay(snapshot: snapshot, into: session)
            lastSnapshot = snapshot
        }

        public func insertText(_ text: String) {
            guard acceptsTerminalInput else { return }
            guard !text.isEmpty else { return }
            if text == "\n" { onSendKey?("enter") } else { onSendText?(text) }
        }

        public func deleteBackward() {
            guard acceptsTerminalInput else { return }
            onSendKey?("backspace")
        }

        public override func paste(_ sender: Any?) {
            guard acceptsTerminalInput else { return }
            guard let pasted = UIPasteboard.general.string, !pasted.isEmpty else { return }
            onSendText?(pasted)
        }

        @objc private func handleTapToActivateInput() {
            guard acceptsTerminalInput else { return }
            becomeFirstResponder()
        }

        @objc private func handleEscape() { onSendKey?("esc") }
        @objc private func handleControlC() { onSendKey?("ctrl+c") }
        @objc private func handleUpArrow() { onSendKey?("up") }
        @objc private func handleDownArrow() { onSendKey?("down") }
        @objc private func handleLeftArrow() { onSendKey?("left") }
        @objc private func handleRightArrow() { onSendKey?("right") }
        @objc private func handleTab() { onSendKey?("tab") }

        private func configureFallbackLabel() {
            fallbackLabel.translatesAutoresizingMaskIntoConstraints = false
            fallbackLabel.numberOfLines = 0
            fallbackLabel.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
            fallbackLabel.textColor = .white
            addSubview(fallbackLabel)
            NSLayoutConstraint.activate([
                fallbackLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
                fallbackLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),
                fallbackLabel.topAnchor.constraint(equalTo: topAnchor, constant: 16),
            ])
        }

        private func configureGestures() {
            activateInputRecognizer.cancelsTouchesInView = false
            addGestureRecognizer(activateInputRecognizer)
        }

        private func ensureSession() {
            guard session == nil else { return }
            do {
                try GhosttyMobileAppService.shared.startIfNeeded()
                guard let app = GhosttyMobileAppService.shared.app else { return }
                session = createSession(app: app)
                syncSessionState()
            } catch {
                fallbackLabel.text = error.localizedDescription
                fallbackLabel.isHidden = false
            }
        }

        private func createSession(app: ghostty_app_t) -> ghostty_session_t? {
            var sessionConfig = ghostty_session_config_new()
            sessionConfig.surface.platform_tag = GHOSTTY_PLATFORM_IOS
            sessionConfig.surface.platform = ghostty_platform_u(ios: ghostty_platform_ios_s(uiview: Unmanaged.passUnretained(self).toOpaque()))
            sessionConfig.surface.scale_factor = scaleFactor
            sessionConfig.surface.font_size = 0

            var createdSession: ghostty_session_t?
            "cat".withCString { commandCString in
                sessionConfig.surface.command = commandCString
                createdSession = ghostty_session_new(app, &sessionConfig)
            }

            guard let createdSession else { return nil }
            return createdSession
        }

        private func replay(snapshot: GhosttyTerminalSnapshot, into session: ghostty_session_t) {
            let vt = GhosttyTerminalSnapshotVTEncoder.encode(snapshot)
            vt.withUnsafeBytes { rawBuffer in
                guard let baseAddress = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return }
                ghostty_session_process_output(session, baseAddress, UInt(vt.count))
            }
            ghostty_session_refresh(session)
            GhosttyMobileAppService.shared.tick()
        }

        private func syncSessionState() {
            guard let session else { return }
            let scale = scaleFactor
            ghostty_session_set_content_scale(session, scale, scale)
            ghostty_session_set_focus(session, isFirstResponder)
            ghostty_session_set_occlusion(session, window != nil && !isHidden && alpha > 0.001)
            ghostty_session_set_size(session, UInt32(max(bounds.width * scale, 1)), UInt32(max(bounds.height * scale, 1)))
            GhosttyMobileAppService.shared.tick()
            syncFirstResponder()
        }

        private func syncFirstResponder() {
            guard window != nil else { return }
            if acceptsTerminalInput { if !isFirstResponder { becomeFirstResponder() } } else if isFirstResponder { resignFirstResponder() }
        }

        private var scaleFactor: Double { Double(window?.screen.scale ?? UIScreen.main.scale) }
    }
#endif
