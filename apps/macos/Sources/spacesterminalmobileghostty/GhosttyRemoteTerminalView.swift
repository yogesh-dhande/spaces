import Darwin
import Foundation

#if canImport(UIKit)
    import GhosttyKit
    import SwiftUI
    import UIKit
    import spacesterminalcore

    private let ghosttyRemoteTerminalTraceEnabled = ProcessInfo.processInfo.environment["SPACES_MOBILE_TERMINAL_TRACE"] == "1"

    private func ghosttyRemoteTerminalTrace(_ message: @autoclosure () -> String) {
        guard ghosttyRemoteTerminalTraceEnabled else { return }
        fputs("spaces-mobile-terminal-trace t=\(ghosttyRemoteTerminalTraceSeconds()) ios-terminal \(message())\n", stderr)
        fflush(stderr)
    }

    private func ghosttyRemoteTerminalTraceSeconds() -> String { String(format: "%.3f", Date().timeIntervalSince1970) }

    struct GhosttyRemoteTerminalScrollMapper {
        private static let minimumMomentumVelocity: CGFloat = 8
        private static let maximumMomentumVelocity: CGFloat = 6_000
        private static let maximumMomentumFrameDelta: CGFloat = 240

        static func scrollDelta(forPanDelta panDelta: CGPoint, scaleFactor: Double) -> CGPoint {
            let scale = CGFloat(scaleFactor)
            return CGPoint(x: -panDelta.x * scale, y: panDelta.y * scale)
        }

        static func clampedMomentumVelocity(_ velocity: CGPoint) -> CGPoint {
            CGPoint(
                x: min(max(velocity.x, -maximumMomentumVelocity), maximumMomentumVelocity),
                y: min(max(velocity.y, -maximumMomentumVelocity), maximumMomentumVelocity))
        }

        static func momentumFrameDelta(velocity: CGPoint, elapsed: TimeInterval, scaleFactor: Double) -> CGPoint {
            let elapsed = max(0, elapsed)
            let pointDelta = CGPoint(
                x: min(max(velocity.x * elapsed, -maximumMomentumFrameDelta), maximumMomentumFrameDelta),
                y: min(max(velocity.y * elapsed, -maximumMomentumFrameDelta), maximumMomentumFrameDelta))
            return scrollDelta(forPanDelta: pointDelta, scaleFactor: scaleFactor)
        }

        static func decayedMomentumVelocity(_ velocity: CGPoint, elapsed: TimeInterval, decelerationRate: CGFloat) -> CGPoint {
            let decay = pow(decelerationRate, CGFloat(max(0, elapsed) * 1_000))
            return CGPoint(x: velocity.x * decay, y: velocity.y * decay)
        }

        static func shouldContinueMomentum(velocity: CGPoint) -> Bool {
            abs(velocity.x) >= minimumMomentumVelocity || abs(velocity.y) >= minimumMomentumVelocity
        }
    }

    public struct GhosttyRemoteTerminalOwnerEpoch: Equatable {
        public let sessionID: String
        public let id: String
        public let ownerEpoch: UInt64
        public let bootstrapSnapshot: GhosttyTerminalSnapshot?

        public init(sessionID: String, id: String, ownerEpoch: UInt64 = 0, bootstrapSnapshot: GhosttyTerminalSnapshot?) {
            self.sessionID = sessionID
            self.id = id
            self.ownerEpoch = ownerEpoch
            self.bootstrapSnapshot = bootstrapSnapshot
        }
    }

    public struct GhosttyRemoteTerminalEndedRender: Equatable {
        public let id: String
        public let snapshot: GhosttyTerminalSnapshot

        public init(id: String, snapshot: GhosttyTerminalSnapshot) {
            self.id = id
            self.snapshot = snapshot
        }
    }

    public struct GhosttyRemoteTerminalView: UIViewRepresentable {
        public let ownerEpoch: GhosttyRemoteTerminalOwnerEpoch?
        public let endedRender: GhosttyRemoteTerminalEndedRender?
        public let fallbackText: String
        public let isVisible: Bool
        public let acceptsInput: Bool
        public let isBusy: Bool
        public let onInputReadinessChanged: @MainActor (Bool) -> Void
        public let onScrollGestureApplied: (@MainActor () -> Void)?
        public let onRenderedTextChanged: (@MainActor (String) -> Void)?
        public let onViewportSizeChanged: @MainActor (Int, Int) -> Void
        public let onSendText: @MainActor (String) -> Void
        public let onSendKey: @MainActor (String) -> Void
        public let onSendScroll: @MainActor (Double, Double) -> Void

        public init(
            ownerEpoch: GhosttyRemoteTerminalOwnerEpoch? = nil, endedRender: GhosttyRemoteTerminalEndedRender? = nil, fallbackText: String,
            isVisible: Bool, acceptsInput: Bool, isBusy: Bool, onInputReadinessChanged: @escaping @MainActor (Bool) -> Void = { _ in },
            onScrollGestureApplied: (@MainActor () -> Void)? = nil, onRenderedTextChanged: (@MainActor (String) -> Void)? = nil,
            onViewportSizeChanged: @escaping @MainActor (Int, Int) -> Void, onSendText: @escaping @MainActor (String) -> Void,
            onSendKey: @escaping @MainActor (String) -> Void, onSendScroll: @escaping @MainActor (Double, Double) -> Void = { _, _ in }
        ) {
            self.ownerEpoch = ownerEpoch
            self.endedRender = endedRender
            self.fallbackText = fallbackText
            self.isVisible = isVisible
            self.acceptsInput = acceptsInput
            self.isBusy = isBusy
            self.onInputReadinessChanged = onInputReadinessChanged
            self.onScrollGestureApplied = onScrollGestureApplied
            self.onRenderedTextChanged = onRenderedTextChanged
            self.onViewportSizeChanged = onViewportSizeChanged
            self.onSendText = onSendText
            self.onSendKey = onSendKey
            self.onSendScroll = onSendScroll
        }

        public func makeUIView(context: Context) -> GhosttyRemoteTerminalHostView { GhosttyRemoteTerminalHostView() }

        public func updateUIView(_ hostView: GhosttyRemoteTerminalHostView, context: Context) {
            hostView.onInputReadinessChanged = { ready in _ = Task { @MainActor in onInputReadinessChanged(ready) } }
            hostView.onScrollGestureApplied = onScrollGestureApplied.map { callback in { _ = Task { @MainActor in callback() } } }
            hostView.onViewportSizeChanged = { columns, rows in _ = Task { @MainActor in onViewportSizeChanged(columns, rows) } }
            hostView.onSendText = { text in _ = Task { @MainActor in onSendText(text) } }
            hostView.onSendKey = { key in _ = Task { @MainActor in onSendKey(key) } }
            hostView.onSendScroll = { horizontal, vertical in _ = Task { @MainActor in onSendScroll(horizontal, vertical) } }
            hostView.onRenderedTextChanged = onRenderedTextChanged.map { callback in { text in _ = Task { @MainActor in callback(text) } } }
            hostView.setTerminalVisible(isVisible)
            hostView.setAcceptsTerminalInput(acceptsInput && !isBusy)
            hostView.update(ownerEpoch: ownerEpoch, endedRender: endedRender, fallbackText: fallbackText)
        }

        public static func dismantleUIView(_ hostView: GhosttyRemoteTerminalHostView, coordinator: ()) { hostView.prepareForDismantle() }
    }

    @MainActor public final class GhosttyRemoteTerminalHostView: UIView, UIKeyInput, UITextInputTraits {
        private struct CellMetrics: Equatable {
            let width: CGFloat
            let height: CGFloat
        }

        private struct SurfaceGeometry: Equatable {
            let width: UInt32
            let height: UInt32
            let scale: Double
        }

        struct AccessoryToolbarButtonLabels: Equatable {
            let scrollable: [String]
            let pinned: [String]
        }

        struct AccessoryToolbarLayoutFrames: Equatable {
            let scrollView: CGRect
            let joystickButton: CGRect
            let keyboardButton: CGRect
        }

        struct AccessoryToolbarButtonWidths: Equatable { let scrollable: [CGFloat] }

        private static let defaultFontSize: CGFloat = 11
        private static let contentInsets = GhosttyRemoteTerminalViewport.contentInsets

        nonisolated(unsafe) static var sessionFreeHandlerForTesting: @Sendable (UnsafeRawPointer?) -> Void = { _ in }

        private let surfaceHostView = UIView(frame: .zero)
        private var mirror: ghostty_mirror_t?
        private var activeOwnerEpoch: GhosttyRemoteTerminalOwnerEpoch?
        private var activeEndedRender: GhosttyRemoteTerminalEndedRender?
        private var latestRenderFrame: GhosttyRenderFrame?
        private var latestSnapshot: GhosttyTerminalSnapshot?
        private var currentRenderedSnapshot: GhosttyTerminalSnapshot?
        private var lastRenderKey = ""
        private var lastSurfaceGeometry: SurfaceGeometry?
        private var snapshotScrollOffsetRows: Int?
        private var lastReportedViewportSize: (columns: Int, rows: Int)?
        private var lastRenderedText = ""
        private var lastReportedInputReadiness = false
        private var isTerminalVisible = true
        private var fallbackText = ""
        private var lastScrollTranslation = CGPoint.zero
        private var didScrollDuringCurrentPan = false
        private var momentumDisplayLink: CADisplayLink?
        private var momentumVelocity = CGPoint.zero
        private var lastMomentumTimestamp: CFTimeInterval = 0
        private var accessoryControlModifierPending = false
        private var suppressesSoftwareKeyboard = false
        var userInterfaceIdiomOverrideForTesting: UIUserInterfaceIdiom?
        private let suppressedSoftwareKeyboardInputView = UIView(frame: .zero)
        private lazy var activateInputRecognizer = UITapGestureRecognizer(target: self, action: #selector(handleTapToActivateInput))
        private lazy var scrollPanRecognizer = UIPanGestureRecognizer(target: self, action: #selector(handleScrollPan))
        private lazy var terminalAccessoryView = makeTerminalAccessoryView()

        public private(set) var acceptsTerminalInput = false
        public var onInputReadinessChanged: ((Bool) -> Void)?
        public var onScrollGestureApplied: (() -> Void)?
        public var onViewportSizeChanged: ((Int, Int) -> Void)?
        public var onSendText: ((String) -> Void)?
        public var onSendKey: ((String) -> Void)?
        public var onSendScroll: ((Double, Double) -> Void)?
        public var onRenderedTextChanged: ((String) -> Void)? {
            didSet {
                guard onRenderedTextChanged == nil else {
                    if currentRenderedSnapshot != nil { emitRenderedTextIfNeeded(force: true) }
                    return
                }
                lastRenderedText = ""
            }
        }

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
        public var textContentType: UITextContentType?

        public override var canBecomeFirstResponder: Bool { acceptsTerminalInput }
        public var hasText: Bool { false }
        public override var inputView: UIView? { suppressesSoftwareKeyboard ? suppressedSoftwareKeyboardInputView : nil }
        public override var inputAccessoryView: UIView? { terminalAccessoryView }

        var inputAssistantIsSuppressedForTesting: Bool {
            inputAssistantItem.leadingBarButtonGroups.isEmpty && inputAssistantItem.trailingBarButtonGroups.isEmpty
        }

        var accessoryToolbarButtonAccessibilityLabelsForTesting: AccessoryToolbarButtonLabels {
            AccessoryToolbarButtonLabels(
                scrollable: ["tab", "/", "~", "|", "-", "_", "esc", "Control"],
                pinned: ["Arrow key joystick", suppressesSoftwareKeyboard ? "Show keyboard" : "Hide keyboard"])
        }

        func accessoryToolbarLayoutFramesForTesting(width: CGFloat, userInterfaceIdiom: UIUserInterfaceIdiom) -> AccessoryToolbarLayoutFrames {
            let metrics = accessoryToolbarMetrics(for: userInterfaceIdiom)
            let keyboardButton = CGRect(x: width - metrics.sideInset - metrics.pinnedButtonWidth, y: 11, width: metrics.pinnedButtonWidth, height: 36)
            let joystickButton = CGRect(
                x: keyboardButton.minX - metrics.gap - metrics.pinnedButtonWidth, y: 11, width: metrics.pinnedButtonWidth, height: 36)
            let scrollView = CGRect(x: metrics.sideInset, y: 8, width: max(0, joystickButton.minX - metrics.gap - metrics.sideInset), height: 42)
            return AccessoryToolbarLayoutFrames(scrollView: scrollView, joystickButton: joystickButton, keyboardButton: keyboardButton)
        }

        func accessoryToolbarButtonWidthsForTesting(width _: CGFloat, userInterfaceIdiom: UIUserInterfaceIdiom) -> AccessoryToolbarButtonWidths {
            let width = accessoryToolbarMetrics(for: userInterfaceIdiom).scrollableButtonWidth
            return AccessoryToolbarButtonWidths(scrollable: Array(repeating: width, count: 8))
        }

        func accessoryToolbarJoystickDirectionForTesting(point: CGPoint, bounds: CGRect) -> String? {
            let dx = point.x - bounds.midX
            let dy = point.y - bounds.midY
            guard max(abs(dx), abs(dy)) >= 10 else { return nil }
            if abs(dx) >= abs(dy) { return dx > 0 ? "right" : "left" }
            return dy > 0 ? "down" : "up"
        }

        func accessoryToolbarJoystickAcceptsReleaseForTesting(point: CGPoint, bounds: CGRect) -> Bool {
            bounds.insetBy(dx: -100, dy: -100).contains(point)
        }

        func accessoryToolbarJoystickAcceptsActivationForTesting(point: CGPoint, bounds: CGRect) -> Bool {
            bounds.insetBy(dx: -12, dy: -12).contains(point)
        }

        public override init(frame: CGRect) {
            super.init(frame: frame)
            isOpaque = true
            backgroundColor = .black
            surfaceHostView.translatesAutoresizingMaskIntoConstraints = false
            surfaceHostView.backgroundColor = .black
            surfaceHostView.isUserInteractionEnabled = false
            insertSubview(surfaceHostView, at: 0)
            NSLayoutConstraint.activate([
                surfaceHostView.topAnchor.constraint(equalTo: topAnchor), surfaceHostView.leadingAnchor.constraint(equalTo: leadingAnchor),
                surfaceHostView.trailingAnchor.constraint(equalTo: trailingAnchor), surfaceHostView.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
            inputAssistantItem.leadingBarButtonGroups = []
            inputAssistantItem.trailingBarButtonGroups = []
            addGestureRecognizer(activateInputRecognizer)
            scrollPanRecognizer.maximumNumberOfTouches = 2
            addGestureRecognizer(scrollPanRecognizer)
        }

        @available(*, unavailable) required init?(coder: NSCoder) { nil }

        deinit {
            MainActor.assumeIsolated {
                momentumDisplayLink?.invalidate()
                if let mirror { ghostty_mirror_free(mirror) }
            }
        }

        public override func didMoveToWindow() {
            super.didMoveToWindow()
            if window == nil {
                prepareForDismantle()
            } else {
                ensureMirrorIfNeeded()
                updateSurfaceGeometry()
                reportViewportSizeIfNeeded()
                renderLatestSnapshot()
            }
        }

        public func prepareForDismantle() {
            let hadRenderedSnapshot = currentRenderedSnapshot != nil
            momentumDisplayLink?.invalidate()
            momentumDisplayLink = nil
            resignFirstResponder()
            activeOwnerEpoch = nil
            activeEndedRender = nil
            latestRenderFrame = nil
            latestSnapshot = nil
            currentRenderedSnapshot = nil
            lastSurfaceGeometry = nil
            if let mirror {
                ghostty_mirror_free(mirror)
                self.mirror = nil
            }
            reportInputReadinessIfNeeded(force: true)
            if hadRenderedSnapshot {
                let handler = Self.sessionFreeHandlerForTesting
                _ = Task.detached(priority: .utility) { handler(nil) }
            }
        }

        public func setTerminalVisible(_ visible: Bool) {
            guard isTerminalVisible != visible else { return }
            isTerminalVisible = visible
            if !visible { resignFirstResponder() }
            setNeedsDisplay()
            reportInputReadinessIfNeeded(force: true)
        }

        public func setAcceptsTerminalInput(_ accepts: Bool) {
            guard acceptsTerminalInput != accepts else {
                reportInputReadinessIfNeeded()
                return
            }
            acceptsTerminalInput = accepts
            if accepts { scheduleFirstResponderRequest() } else { resignFirstResponder() }
            reportInputReadinessIfNeeded(force: true)
        }

        public func setSoftwareKeyboardVisible(_ visible: Bool) {
            let shouldSuppress = !visible
            guard suppressesSoftwareKeyboard != shouldSuppress else { return }
            suppressesSoftwareKeyboard = shouldSuppress
            reloadInputViews()
        }

        public func update(ownerEpoch: GhosttyRemoteTerminalOwnerEpoch?, endedRender: GhosttyRemoteTerminalEndedRender?, fallbackText: String) {
            self.fallbackText = fallbackText
            activeOwnerEpoch = ownerEpoch
            activeEndedRender = endedRender
            let nextSnapshot = ownerEpoch?.bootstrapSnapshot ?? endedRender?.snapshot
            latestRenderFrame =
                ownerEpoch.flatMap { ownerEpoch in
                    ownerEpoch.bootstrapSnapshot.map { GhosttyRenderFrame(sessionRevision: nil, ownerEpoch: ownerEpoch.ownerEpoch, snapshot: $0) }
                } ?? endedRender.map { GhosttyRenderFrame(sessionRevision: nil, ownerEpoch: 0, snapshot: $0.snapshot) }
            let nextKey = ownerEpoch.map { "owner|\($0.id)" } ?? endedRender.map { "ended|\($0.id)" } ?? "status|\(fallbackText)"
            if nextKey != lastRenderKey {
                snapshotScrollOffsetRows = nil
                lastRenderKey = nextKey
            }
            latestSnapshot = nextSnapshot
            renderLatestSnapshot()
            reportInputReadinessIfNeeded()
        }

        public override func layoutSubviews() {
            super.layoutSubviews()
            ensureMirrorIfNeeded()
            updateSurfaceGeometry()
            reportViewportSizeIfNeeded()
            renderLatestSnapshot()
        }

        public override func draw(_ rect: CGRect) {
            UIColor.black.setFill()
            UIRectFill(bounds)
        }

        public func insertText(_ text: String) {
            guard acceptsTerminalInput, !text.isEmpty else { return }
            if sendPendingControlModifierIfNeeded(for: text) { return }
            if text == "\n" || text == "\r" { onSendKey?("enter") } else { onSendText?(text) }
        }

        public func deleteBackward() {
            guard acceptsTerminalInput else { return }
            onSendKey?("backspace")
        }

        public override var keyCommands: [UIKeyCommand]? {
            [
                UIKeyCommand(input: UIKeyCommand.inputUpArrow, modifierFlags: [], action: #selector(sendArrowUp)),
                UIKeyCommand(input: UIKeyCommand.inputDownArrow, modifierFlags: [], action: #selector(sendArrowDown)),
                UIKeyCommand(input: UIKeyCommand.inputLeftArrow, modifierFlags: [], action: #selector(sendArrowLeft)),
                UIKeyCommand(input: UIKeyCommand.inputRightArrow, modifierFlags: [], action: #selector(sendArrowRight)),
                UIKeyCommand(input: "\t", modifierFlags: [], action: #selector(sendTab)),
                UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(sendEscape)),
            ]
        }

        public func capturedSnapshotForTesting() -> GhosttyTerminalSnapshot? { currentRenderedSnapshot }
        public var hasActiveSessionForTesting: Bool { currentRenderedSnapshot != nil }
        public var hasMirrorSurfaceForTesting: Bool { mirrorSurface() != nil }
        public var hasRetainedSessionStandardInputWriteDescriptorForTesting: Bool { false }

        @discardableResult public func debugSendScrollForTesting(
            horizontal: CGFloat, vertical: CGFloat, location: CGPoint? = nil, hasPreciseDeltas: Bool = false,
            momentumState: UIGestureRecognizer.State = .changed
        ) -> Bool { sendScroll(horizontal: horizontal, vertical: vertical) }

        public static func makeScrollMods(hasPreciseDeltas: Bool, momentumState: UIGestureRecognizer.State) -> Int32 {
            var mods: Int32 = 0
            if hasPreciseDeltas { mods |= 0b0000_0111 }
            switch momentumState {
            case .possible: mods |= 0b0000_1100
            case .ended, .cancelled, .failed: mods |= 0b0000_1000
            default: mods |= 0b0000_0100
            }
            return mods
        }

        @objc private func handleTapToActivateInput() {
            guard acceptsTerminalInput else { return }
            becomeFirstResponder()
        }

        @objc private func handleScrollPan(_ recognizer: UIPanGestureRecognizer) {
            switch recognizer.state {
            case .began:
                didScrollDuringCurrentPan = false
                lastScrollTranslation = recognizer.translation(in: self)
                stopMomentum()
            case .changed:
                let translation = recognizer.translation(in: self)
                let delta = CGPoint(x: translation.x - lastScrollTranslation.x, y: translation.y - lastScrollTranslation.y)
                lastScrollTranslation = translation
                let scrollDelta = GhosttyRemoteTerminalScrollMapper.scrollDelta(forPanDelta: delta, scaleFactor: Double(window?.screen.scale ?? 1))
                if sendScroll(horizontal: scrollDelta.x, vertical: scrollDelta.y) { didScrollDuringCurrentPan = true }
            case .ended:
                if didScrollDuringCurrentPan { onScrollGestureApplied?() }
                let velocity = GhosttyRemoteTerminalScrollMapper.clampedMomentumVelocity(recognizer.velocity(in: self))
                if GhosttyRemoteTerminalScrollMapper.shouldContinueMomentum(velocity: velocity) { startMomentum(velocity: velocity) }
            case .cancelled, .failed:
                if didScrollDuringCurrentPan { onScrollGestureApplied?() }
                stopMomentum()
            default: break
            }
        }

        @objc private func handleMomentumFrame(_ displayLink: CADisplayLink) {
            let timestamp = displayLink.timestamp
            let elapsed = lastMomentumTimestamp > 0 ? timestamp - lastMomentumTimestamp : displayLink.duration
            lastMomentumTimestamp = timestamp
            let delta = GhosttyRemoteTerminalScrollMapper.momentumFrameDelta(
                velocity: momentumVelocity, elapsed: elapsed, scaleFactor: Double(window?.screen.scale ?? 1))
            _ = sendScroll(horizontal: delta.x, vertical: delta.y)
            momentumVelocity = GhosttyRemoteTerminalScrollMapper.decayedMomentumVelocity(
                momentumVelocity, elapsed: elapsed, decelerationRate: UIScrollView.DecelerationRate.normal.rawValue)
            if !GhosttyRemoteTerminalScrollMapper.shouldContinueMomentum(velocity: momentumVelocity) { stopMomentum() }
        }

        private func startMomentum(velocity: CGPoint) {
            momentumVelocity = velocity
            lastMomentumTimestamp = 0
            momentumDisplayLink?.invalidate()
            let displayLink = CADisplayLink(target: self, selector: #selector(handleMomentumFrame))
            displayLink.add(to: .main, forMode: .common)
            momentumDisplayLink = displayLink
        }

        private func stopMomentum() {
            momentumDisplayLink?.invalidate()
            momentumDisplayLink = nil
            momentumVelocity = .zero
            lastMomentumTimestamp = 0
        }

        @objc private func sendArrowUp() { onSendKey?("up") }
        @objc private func sendArrowDown() { onSendKey?("down") }
        @objc private func sendArrowLeft() { onSendKey?("left") }
        @objc private func sendArrowRight() { onSendKey?("right") }
        @objc private func sendTab() { onSendKey?("tab") }
        @objc private func sendEscape() { onSendKey?("esc") }
        @objc private func sendSlash() { onSendText?("/") }
        @objc private func sendTilde() { onSendText?("~") }
        @objc private func sendPipe() { onSendText?("|") }
        @objc private func sendDash() { onSendText?("-") }
        @objc private func sendUnderscore() { onSendText?("_") }
        @objc private func toggleControlModifier() { accessoryControlModifierPending.toggle() }
        @objc private func toggleSoftwareKeyboard() { setSoftwareKeyboardVisible(suppressesSoftwareKeyboard) }

        private func makeTerminalAccessoryView() -> UIView {
            let container = UIView(frame: CGRect(x: 0, y: 0, width: 0, height: 58))
            container.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            container.backgroundColor = UIColor(red: 0.07, green: 0.09, blue: 0.10, alpha: 1)

            let stackView = UIStackView(arrangedSubviews: [
                accessoryButton(title: "tab", action: #selector(sendTab)), accessoryButton(title: "/", action: #selector(sendSlash)),
                accessoryButton(title: "~", action: #selector(sendTilde)), accessoryButton(title: "|", action: #selector(sendPipe)),
                accessoryButton(title: "-", action: #selector(sendDash)), accessoryButton(title: "_", action: #selector(sendUnderscore)),
                accessoryButton(title: "esc", action: #selector(sendEscape)),
                accessoryButton(title: "Control", action: #selector(toggleControlModifier)),
                accessoryButton(title: "↑", accessibilityLabel: "Arrow key joystick", action: #selector(sendArrowUp)),
                accessoryButton(title: "⌨", accessibilityLabel: "Hide keyboard", action: #selector(toggleSoftwareKeyboard)),
            ])
            stackView.axis = .horizontal
            stackView.alignment = .center
            stackView.spacing = 6
            stackView.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(stackView)
            NSLayoutConstraint.activate([
                stackView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
                stackView.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -8),
                stackView.centerYAnchor.constraint(equalTo: container.centerYAnchor), stackView.heightAnchor.constraint(equalToConstant: 42),
            ])
            return FixedHeightInputAccessoryView(contentView: container, height: 58)
        }

        private func accessoryButton(title: String, accessibilityLabel: String? = nil, action: Selector) -> UIButton {
            let button = UIButton(type: .system)
            button.setTitle(title, for: .normal)
            button.titleLabel?.font = .monospacedSystemFont(ofSize: 13, weight: .semibold)
            button.tintColor = .white
            button.backgroundColor = UIColor.white.withAlphaComponent(0.12)
            button.layer.cornerRadius = 7
            button.accessibilityLabel = accessibilityLabel ?? title
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: 42).isActive = true
            button.heightAnchor.constraint(equalToConstant: 36).isActive = true
            button.addTarget(self, action: action, for: .touchUpInside)
            return button
        }

        private func accessoryToolbarMetrics(for userInterfaceIdiom: UIUserInterfaceIdiom) -> (
            sideInset: CGFloat, gap: CGFloat, pinnedButtonWidth: CGFloat, scrollableButtonWidth: CGFloat
        ) {
            if userInterfaceIdiom == .pad { return (sideInset: 12, gap: 8, pinnedButtonWidth: 56, scrollableButtonWidth: 64) }
            return (sideInset: 8, gap: 6, pinnedButtonWidth: 46, scrollableButtonWidth: 50)
        }

        private func scheduleFirstResponderRequest() {
            Task { @MainActor [weak self] in
                await Task.yield()
                guard let self, self.acceptsTerminalInput, self.window != nil else { return }
                self.becomeFirstResponder()
            }
        }

        private func reportViewportSizeIfNeeded() {
            let size = viewportSize()
            guard size.columns > 0, size.rows > 0 else { return }
            guard lastReportedViewportSize?.columns != size.columns || lastReportedViewportSize?.rows != size.rows else { return }
            lastReportedViewportSize = size
            onViewportSizeChanged?(size.columns, size.rows)
        }

        private func reportInputReadinessIfNeeded(force: Bool = false) {
            let ready = isTerminalVisible && acceptsTerminalInput && currentRenderedSnapshot != nil
            guard force || ready != lastReportedInputReadiness else { return }
            lastReportedInputReadiness = ready
            onInputReadinessChanged?(ready)
        }

        private func renderLatestSnapshot() {
            guard let latestSnapshot else {
                currentRenderedSnapshot = nil
                latestRenderFrame = nil
                setNeedsDisplay()
                emitRenderedTextIfNeeded(force: false)
                reportInputReadinessIfNeeded()
                return
            }
            ensureMirrorIfNeeded()
            updateSurfaceGeometry()
            let window = viewportWindow(for: latestSnapshot)
            let cropped = GhosttyTerminalSnapshotViewport.crop(latestSnapshot, window: window)
            currentRenderedSnapshot = cropped
            applyLatestRenderFrameIfPossible()
            emitRenderedTextIfNeeded(force: false)
            reportInputReadinessIfNeeded()
        }

        private func ensureMirrorIfNeeded() {
            guard mirror == nil, window != nil else { return }
            do {
                try GhosttyMobileAppService.shared.startIfNeeded()
                guard let app = GhosttyMobileAppService.shared.app else { throw GhosttyMobileAppServiceError.configuration("ghostty app missing") }
                var host = makeSurfaceHost()
                var config = ghostty_session_config_new()
                config.surface.platform_tag = host.platform_tag
                config.surface.platform = host.platform
                config.surface.scale_factor = host.scale_factor
                config.surface.context = GHOSTTY_SURFACE_CONTEXT_WINDOW
                config.surface.backend = GHOSTTY_SURFACE_IO_BACKEND_HOST_MANAGED
                config.parked_host = host
                mirror = ghostty_mirror_new(app, &host, &config)
                guard mirror != nil else { throw GhosttyMobileAppServiceError.configuration("ghostty_mirror_new failed") }
                lastSurfaceGeometry = nil
                updateSurfaceGeometry()
            } catch { ghosttyRemoteTerminalTrace("mirror_create_failed error=\(error)") }
        }

        private func makeSurfaceHost() -> ghostty_surface_host_s {
            var host = ghostty_surface_host_s()
            host.platform_tag = GHOSTTY_PLATFORM_IOS
            host.platform = ghostty_platform_u(ios: ghostty_platform_ios_s(uiview: Unmanaged.passUnretained(surfaceHostView).toOpaque()))
            host.scale_factor = Double(window?.screen.scale ?? UIScreen.main.scale)
            return host
        }

        private func mirrorSurface() -> ghostty_surface_t? {
            guard let mirror else { return nil }
            return ghostty_mirror_surface(mirror)
        }

        private func updateSurfaceGeometry() {
            guard let mirror, let surface = mirrorSurface() else { return }
            let scale = Double(window?.screen.scale ?? UIScreen.main.scale)
            let width = UInt32(max(Int(floor(bounds.width * CGFloat(scale))), 1))
            let height = UInt32(max(Int(floor(bounds.height * CGFloat(scale))), 1))
            let geometry = SurfaceGeometry(width: width, height: height, scale: scale)
            guard geometry != lastSurfaceGeometry else { return }
            var host = makeSurfaceHost()
            _ = ghostty_mirror_set_host(mirror, &host)
            ghostty_surface_set_content_scale(surface, scale, scale)
            ghostty_surface_set_size(surface, width, height)
            ghostty_surface_set_occlusion(surface, isTerminalVisible && window != nil)
            ghostty_surface_refresh(surface)
            lastSurfaceGeometry = geometry
        }

        private func applyLatestRenderFrameIfPossible() {
            guard let mirror, let frame = latestRenderFrame else {
                setNeedsDisplay()
                return
            }
            let applyStartedAt = Date()
            let applied = withCFrame(frame) { cFrame in ghostty_mirror_apply_render_frame(mirror, cFrame) }
            let applyMS = TerminalPerformance.elapsedMS(since: applyStartedAt)
            if let sessionID = activeOwnerEpoch?.sessionID {
                var attributes = GhosttyRenderFrameMetrics.attributes(
                    frame: frame, dropped: !applied, dropReason: applied ? nil : "mirror_apply_failed", renderMode: "ghostty-mirror")
                attributes["apply_ms"] = String(applyMS)
                SpacesMobileTerminalPerformanceLogger.emit(
                    .init(sessionID: sessionID, source: "ios-mirror", name: "render_frame_mirror_apply", elapsedMS: applyMS, attributes: attributes))
            }
            if applied {
                if let surface = mirrorSurface() { ghostty_surface_refresh(surface) }
            } else {
                ghosttyRemoteTerminalTrace("mirror_apply_failed")
                setNeedsDisplay()
            }
        }

        private func withCFrame(_ frame: GhosttyRenderFrame, _ body: (UnsafePointer<ghostty_render_frame_s>) -> Bool) -> Bool {
            guard frame.version == GhosttyRenderFrame.currentVersion else { return false }
            let snapshot = frame.snapshot
            guard snapshot.columns > 0, snapshot.rows > 0, snapshot.columns <= Int(UInt16.max), snapshot.rows <= Int(UInt16.max) else { return false }
            var cells = snapshot.cells.map { cell in
                ghostty_terminal_snapshot_cell_s(
                    codepoint: cell.codepoint, foreground_rgb: cell.foregroundRGB, background_rgb: cell.backgroundRGB, flags: cell.flags)
            }
            return cells.withUnsafeMutableBufferPointer { buffer in
                var cSnapshot = ghostty_terminal_snapshot_s()
                cSnapshot.columns = UInt16(snapshot.columns)
                cSnapshot.rows = UInt16(snapshot.rows)
                cSnapshot.cursor_column = UInt16(clamping: snapshot.cursorColumn)
                cSnapshot.cursor_row = UInt16(clamping: snapshot.cursorRow)
                cSnapshot.cursor_visible = snapshot.cursorVisible
                cSnapshot.default_foreground_rgb = snapshot.defaultForegroundRGB
                cSnapshot.default_background_rgb = snapshot.defaultBackgroundRGB
                cSnapshot.cell_count = buffer.count
                cSnapshot.cells = buffer.baseAddress

                var cFrame = ghostty_render_frame_s()
                cFrame.version = UInt32(frame.version)
                cFrame.session_revision = frame.sessionRevision ?? 0
                cFrame.owner_epoch = frame.ownerEpoch
                cFrame.columns = UInt16(snapshot.columns)
                cFrame.rows = UInt16(snapshot.rows)
                cFrame.snapshot = cSnapshot
                return withUnsafePointer(to: &cFrame, body)
            }
        }

        private func viewportWindow(for snapshot: GhosttyTerminalSnapshot) -> GhosttyTerminalSnapshotViewport.Window {
            let size = viewportSize()
            let base = GhosttyTerminalSnapshotViewport.window(for: snapshot, columns: size.columns, rows: size.rows, horizontalAlignment: .leading)
            let rowOffset = min(max(snapshotScrollOffsetRows ?? base.rowOffset, 0), max(snapshot.rows - base.rows, 0))
            return GhosttyTerminalSnapshotViewport.Window(
                columnOffset: base.columnOffset, rowOffset: rowOffset, columns: base.columns, rows: base.rows)
        }

        private func viewportSize() -> (columns: Int, rows: Int) {
            let metrics = cellMetrics()
            let content = bounds.inset(by: Self.contentInsets)
            let rawColumns = max(Int(floor(max(content.width, 1) / metrics.width)), 1)
            let rawRows = max(Int(floor(max(content.height, 1) / metrics.height)), 1)
            return GhosttyRemoteTerminalViewport.reportedSize(
                rawColumns: rawColumns, rawRows: rawRows, bounds: bounds,
                idiom: userInterfaceIdiomOverrideForTesting ?? traitCollection.userInterfaceIdiom)
        }

        @discardableResult private func sendScroll(horizontal: CGFloat, vertical: CGFloat) -> Bool {
            let locallyScrolled = scrollLocalSnapshot(vertical: vertical)
            onSendScroll?(Double(horizontal), Double(vertical))
            return locallyScrolled || horizontal != 0 || vertical != 0
        }

        private func scrollLocalSnapshot(vertical: CGFloat) -> Bool {
            guard let latestSnapshot else { return false }
            let size = viewportSize()
            guard latestSnapshot.rows > size.rows else { return false }
            let base = GhosttyTerminalSnapshotViewport.window(
                for: latestSnapshot, columns: size.columns, rows: size.rows, horizontalAlignment: .leading)
            let currentOffset = snapshotScrollOffsetRows ?? base.rowOffset
            let lineDelta = max(Int((abs(vertical) / 12).rounded(.up)), 1)
            let proposed = currentOffset + (vertical < 0 ? -lineDelta : lineDelta)
            let next = min(max(proposed, 0), max(latestSnapshot.rows - size.rows, 0))
            guard next != currentOffset else { return false }
            snapshotScrollOffsetRows = next
            renderLatestSnapshot()
            return true
        }

        private func emitRenderedTextIfNeeded(force: Bool) {
            guard let onRenderedTextChanged else { return }
            let text = currentRenderedSnapshot.map(GhosttyTerminalSnapshotGrid.fullPlainText) ?? ""
            guard force || text != lastRenderedText else { return }
            lastRenderedText = text
            onRenderedTextChanged(text)
        }

        private func cellMetrics() -> CellMetrics {
            let font = UIFont.monospacedSystemFont(ofSize: Self.defaultFontSize, weight: .regular)
            let width = ceil(("W" as NSString).size(withAttributes: [.font: font]).width)
            let height = ceil(font.lineHeight)
            return CellMetrics(width: max(width, 1), height: max(height, 1))
        }

        private func sendPendingControlModifierIfNeeded(for text: String) -> Bool {
            guard accessoryControlModifierPending else { return false }
            defer { accessoryControlModifierPending = false }
            guard text.count == 1, let scalar = text.unicodeScalars.first, scalar.properties.isAlphabetic else { return false }
            onSendKey?("ctrl+\(String(scalar).lowercased())")
            return true
        }
    }

    private final class FixedHeightInputAccessoryView: UIView {
        private let height: CGFloat

        init(contentView: UIView, height: CGFloat) {
            self.height = height
            super.init(frame: CGRect(x: 0, y: 0, width: 0, height: height))
            autoresizingMask = [.flexibleWidth, .flexibleHeight]
            contentView.translatesAutoresizingMaskIntoConstraints = false
            addSubview(contentView)
            NSLayoutConstraint.activate([
                contentView.leadingAnchor.constraint(equalTo: leadingAnchor), contentView.trailingAnchor.constraint(equalTo: trailingAnchor),
                contentView.topAnchor.constraint(equalTo: topAnchor), contentView.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
        }

        @available(*, unavailable) required init?(coder: NSCoder) { nil }

        override var intrinsicContentSize: CGSize { CGSize(width: UIView.noIntrinsicMetric, height: height) }
        override func sizeThatFits(_ size: CGSize) -> CGSize { CGSize(width: size.width, height: height) }
    }

#endif
