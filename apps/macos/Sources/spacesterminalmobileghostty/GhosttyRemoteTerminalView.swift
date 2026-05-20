import Foundation

#if canImport(UIKit)
    import GhosttyKit
    import SwiftUI
    import UIKit
    import spacesterminalcore

    public struct GhosttyRemoteTerminalView: UIViewRepresentable {
        public let snapshot: GhosttyTerminalSnapshot?
        public let replayStateKey: String
        public let fallbackText: String
        public let acceptsInput: Bool
        public let isBusy: Bool
        public let onRenderedTextChanged: @MainActor (String) -> Void
        public let onViewportSizeChanged: @MainActor (Int, Int) -> Void
        public let onSendText: @MainActor (String) -> Void
        public let onSendKey: @MainActor (String) -> Void

        public init(
            snapshot: GhosttyTerminalSnapshot?, replayStateKey: String, fallbackText: String, acceptsInput: Bool, isBusy: Bool,
            onRenderedTextChanged: @escaping @MainActor (String) -> Void = { _ in }, onViewportSizeChanged: @escaping @MainActor (Int, Int) -> Void,
            onSendText: @escaping @MainActor (String) -> Void, onSendKey: @escaping @MainActor (String) -> Void
        ) {
            self.snapshot = snapshot
            self.replayStateKey = replayStateKey
            self.fallbackText = fallbackText
            self.acceptsInput = acceptsInput
            self.isBusy = isBusy
            self.onRenderedTextChanged = onRenderedTextChanged
            self.onViewportSizeChanged = onViewportSizeChanged
            self.onSendText = onSendText
            self.onSendKey = onSendKey
        }

        public func makeUIView(context: Context) -> GhosttyRemoteTerminalHostView { GhosttyRemoteTerminalHostView() }

        public func updateUIView(_ hostView: GhosttyRemoteTerminalHostView, context: Context) {
            hostView.acceptsTerminalInput = acceptsInput && !isBusy
            hostView.onViewportSizeChanged = { columns, rows in Task { @MainActor in onViewportSizeChanged(columns, rows) } }
            hostView.onSendText = { text in Task { @MainActor in onSendText(text) } }
            hostView.onSendKey = { key in Task { @MainActor in onSendKey(key) } }
            hostView.onRenderedTextChanged = { text in Task { @MainActor in onRenderedTextChanged(text) } }
            hostView.update(snapshot: snapshot, replayStateKey: replayStateKey, fallbackText: fallbackText)
        }
    }

    @MainActor public final class GhosttyRemoteTerminalHostView: UIView, UIKeyInput, UITextInputTraits {
        private static let carrierCommand = "direct:/bin/cat"
        private static let defaultFontSize: Float = 13
        private static let contentInsets = UIEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)
        private var session: ghostty_session_t?
        private var lastSnapshot: GhosttyTerminalSnapshot?
        private var lastViewportSnapshot: GhosttyTerminalSnapshot?
        private var lastReplayPixelSize = CGSize.zero
        private var lastReplayStateKey: String?
        private let fallbackLabel = UILabel()
        private lazy var activateInputRecognizer = UITapGestureRecognizer(target: self, action: #selector(handleTapToActivateInput))
        private lazy var scrollPanRecognizer = UIPanGestureRecognizer(target: self, action: #selector(handleScrollPan))
        private var lastScrollTranslation = CGPoint.zero
        private var lastEmittedRenderedText: String?

        public var acceptsTerminalInput = false
        public var onViewportSizeChanged: ((Int, Int) -> Void)?
        public var onSendText: ((String) -> Void)?
        public var onSendKey: ((String) -> Void)?
        public var onRenderedTextChanged: ((String) -> Void)?
        public var autocorrectionType: UITextAutocorrectionType = .no
        public var autocapitalizationType: UITextAutocapitalizationType = .none
        public var spellCheckingType: UITextSpellCheckingType = .no
        public var smartQuotesType: UITextSmartQuotesType = .no
        public var smartDashesType: UITextSmartDashesType = .no
        public var smartInsertDeleteType: UITextSmartInsertDeleteType = .no
        public var keyboardType: UIKeyboardType = .asciiCapable
        public var keyboardAppearance: UIKeyboardAppearance = .dark
        public var returnKeyType: UIReturnKeyType = .default
        public var enablesReturnKeyAutomatically = false
        public override var canBecomeFirstResponder: Bool { acceptsTerminalInput }
        public var hasText: Bool { false }

        public override init(frame: CGRect) {
            super.init(frame: frame)
            backgroundColor = UIColor(red: 0.10, green: 0.12, blue: 0.15, alpha: 1)
            isOpaque = true
            isAccessibilityElement = true
            accessibilityIdentifier = "terminal.surface"
            accessibilityLabel = "Terminal surface"
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

        public func update(snapshot: GhosttyTerminalSnapshot?, replayStateKey: String, fallbackText: String) {
            ensureSession()
            if let lastReplayStateKey, lastReplayStateKey != replayStateKey {
                lastViewportSnapshot = nil
                lastReplayPixelSize = .zero
            }
            fallbackLabel.text = snapshot == nil ? fallbackText : nil
            fallbackLabel.isHidden = snapshot != nil
            syncFirstResponder()

            guard let session, let snapshot else {
                emitRenderedTextIfNeeded()
                return
            }
            let viewportSnapshot = viewportSnapshot(for: snapshot, session: session)
            guard lastViewportSnapshot != viewportSnapshot || lastReplayPixelSize != currentPixelSize else {
                emitRenderedTextIfNeeded()
                return
            }
            replay(snapshot: viewportSnapshot, into: session)
            lastSnapshot = snapshot
            lastViewportSnapshot = viewportSnapshot
            lastReplayPixelSize = currentPixelSize
            lastReplayStateKey = replayStateKey
            emitRenderedTextIfNeeded()
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

        @objc private func handleScrollPan(_ recognizer: UIPanGestureRecognizer) {
            switch recognizer.state {
            case .began:
                lastScrollTranslation = recognizer.translation(in: self)
                if acceptsTerminalInput { becomeFirstResponder() }
            case .changed:
                let translation = recognizer.translation(in: self)
                let deltaX = translation.x - lastScrollTranslation.x
                let deltaY = translation.y - lastScrollTranslation.y
                lastScrollTranslation = translation
                guard abs(deltaX) > 0.5 || abs(deltaY) > 0.5 else { return }
                _ = sendScroll(horizontal: -deltaX * 2, vertical: -deltaY * 2)
            default: lastScrollTranslation = .zero
            }
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
            scrollPanRecognizer.cancelsTouchesInView = false
            if #available(iOS 13.4, *) { scrollPanRecognizer.allowedScrollTypesMask = [.continuous, .discrete] }
            addGestureRecognizer(scrollPanRecognizer)
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
            sessionConfig.surface.font_size = Self.defaultFontSize
            sessionConfig.surface.use_login_shell = false
            let createdSession = Self.carrierCommand.withCString { commandPointer in
                sessionConfig.surface.command = commandPointer
                return ghostty_session_new(app, &sessionConfig)
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
            requestSurfaceRefresh()
        }

        private func syncSessionState() {
            guard let session else { return }
            let scale = scaleFactor
            let pixelSize = currentPixelSize
            ghostty_session_set_content_scale(session, scale, scale)
            ghostty_session_set_focus(session, isFirstResponder)
            ghostty_session_set_occlusion(session, window != nil && !isHidden && alpha > 0.001)
            ghostty_session_set_size(session, UInt32(max(pixelSize.width, 1)), UInt32(max(pixelSize.height, 1)))
            requestSurfaceRefresh()
            notifyViewportSizeIfChanged()
            if let lastSnapshot, pixelSize.width > 1, pixelSize.height > 1, lastReplayPixelSize != pixelSize {
                let viewportSnapshot = viewportSnapshot(for: lastSnapshot, session: session)
                replay(snapshot: viewportSnapshot, into: session)
                lastViewportSnapshot = viewportSnapshot
                lastReplayPixelSize = pixelSize
            }
            syncFirstResponder()
        }

        @discardableResult private func sendScroll(horizontal: CGFloat, vertical: CGFloat) -> Bool {
            guard let session else { return false }
            let surface = ghostty_session_surface(session)
            ghostty_surface_mouse_scroll(surface, Double(horizontal), Double(vertical), 0)
            requestSurfaceRefresh()
            return true
        }

        private func requestSurfaceRefresh() {
            guard let session else { return }
            ghostty_session_refresh(session)
            GhosttyMobileAppService.shared.tick()
            setNeedsDisplay()
            layer.setNeedsDisplay()
        }

        private func syncFirstResponder() {
            guard window != nil else { return }
            if acceptsTerminalInput { if !isFirstResponder { becomeFirstResponder() } } else if isFirstResponder { resignFirstResponder() }
        }

        private func viewportSnapshot(for snapshot: GhosttyTerminalSnapshot, session: ghostty_session_t) -> GhosttyTerminalSnapshot {
            let localSize = ghostty_session_size(session)
            let localColumns = Int(localSize.columns)
            let localRows = Int(localSize.rows)
            guard localColumns > 0, localRows > 0 else { return snapshot }
            return GhosttyTerminalSnapshotViewport.crop(snapshot, columns: localColumns, rows: localRows, horizontalAlignment: .leading)
        }

        private var scaleFactor: Double { Double(window?.screen.scale ?? UIScreen.main.scale) }
        private var currentPixelSize: CGSize {
            let insetBounds = bounds.inset(by: Self.contentInsets)
            return CGSize(width: max(insetBounds.width * scaleFactor, 1), height: max(insetBounds.height * scaleFactor, 1))
        }

        private func notifyViewportSizeIfChanged() {
            guard let session else { return }
            let size = ghostty_session_size(session)
            guard size.columns > 0, size.rows > 0 else { return }
            onViewportSizeChanged?(Int(size.columns), Int(size.rows))
        }

        func capturedSnapshotForTesting() -> GhosttyTerminalSnapshot? {
            guard let session else { return nil }
            var snapshot = ghostty_terminal_snapshot_s()
            guard ghostty_session_export_snapshot(session, &snapshot) else { return nil }
            defer { ghostty_terminal_snapshot_free(&snapshot) }

            let cells: [GhosttyTerminalSnapshot.Cell]
            if let rawCells = snapshot.cells, snapshot.cell_count > 0 {
                let buffer = UnsafeBufferPointer(start: rawCells, count: Int(snapshot.cell_count))
                cells = buffer.map {
                    GhosttyTerminalSnapshot.Cell(
                        codepoint: $0.codepoint, foregroundRGB: $0.foreground_rgb, backgroundRGB: $0.background_rgb, flags: $0.flags)
                }
            } else {
                cells = []
            }

            return GhosttyTerminalSnapshot(
                columns: Int(snapshot.columns), rows: Int(snapshot.rows), cursorColumn: Int(snapshot.cursor_column),
                cursorRow: Int(snapshot.cursor_row), cursorVisible: snapshot.cursor_visible, defaultForegroundRGB: snapshot.default_foreground_rgb,
                defaultBackgroundRGB: snapshot.default_background_rgb, cells: cells)
        }

        private func emitRenderedTextIfNeeded() {
            let renderedText =
                if let snapshot = capturedSnapshotForTesting() { GhosttyTerminalSnapshotLayout.plainText(for: snapshot) } else {
                    fallbackLabel.text ?? ""
                }
            guard renderedText != lastEmittedRenderedText else { return }
            lastEmittedRenderedText = renderedText
            onRenderedTextChanged?(renderedText)
        }
    }
#endif
