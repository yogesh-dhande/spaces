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
        fputs("spaces-mobile-terminal-trace t=\(ghosttyRemoteTerminalTraceSeconds()) ios-ghostty \(message())\n", stderr)
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

    public struct GhosttyRemoteTerminalOutputBatch: Equatable {
        public let id: String
        public let data: Data

        public init(id: String, data: Data) {
            self.id = id
            self.data = data
        }
    }

    public struct GhosttyRemoteTerminalOwnerEpoch: Equatable {
        public let sessionID: String
        public let id: String
        public let bootstrapSnapshot: GhosttyTerminalSnapshot?
        public let historySeed: GhosttyRemoteTerminalOutputBatch?
        public let pendingOutputs: [GhosttyRemoteTerminalOutputBatch]

        public init(
            sessionID: String, id: String, bootstrapSnapshot: GhosttyTerminalSnapshot?, historySeed: GhosttyRemoteTerminalOutputBatch? = nil,
            pendingOutputs: [GhosttyRemoteTerminalOutputBatch] = []
        ) {
            self.sessionID = sessionID
            self.id = id
            self.bootstrapSnapshot = bootstrapSnapshot
            self.historySeed = historySeed
            self.pendingOutputs = pendingOutputs
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
        public let onOutputBatchApplied: (@MainActor (String) -> Void)?
        public let onHistorySeedApplied: (@MainActor (String) -> Void)?
        public let onScrollGestureApplied: (@MainActor () -> Void)?
        public let onRenderedTextChanged: (@MainActor (String) -> Void)?
        public let onViewportSizeChanged: @MainActor (Int, Int) -> Void
        public let onSendText: @MainActor (String) -> Void
        public let onSendKey: @MainActor (String) -> Void

        public init(
            ownerEpoch: GhosttyRemoteTerminalOwnerEpoch? = nil, endedRender: GhosttyRemoteTerminalEndedRender? = nil, fallbackText: String,
            isVisible: Bool, acceptsInput: Bool, isBusy: Bool, onInputReadinessChanged: @escaping @MainActor (Bool) -> Void = { _ in },
            onOutputBatchApplied: (@MainActor (String) -> Void)? = nil, onHistorySeedApplied: (@MainActor (String) -> Void)? = nil,
            onScrollGestureApplied: (@MainActor () -> Void)? = nil, onRenderedTextChanged: (@MainActor (String) -> Void)? = nil,
            onViewportSizeChanged: @escaping @MainActor (Int, Int) -> Void, onSendText: @escaping @MainActor (String) -> Void,
            onSendKey: @escaping @MainActor (String) -> Void
        ) {
            self.ownerEpoch = ownerEpoch
            self.endedRender = endedRender
            self.fallbackText = fallbackText
            self.isVisible = isVisible
            self.acceptsInput = acceptsInput
            self.isBusy = isBusy
            self.onInputReadinessChanged = onInputReadinessChanged
            self.onOutputBatchApplied = onOutputBatchApplied
            self.onHistorySeedApplied = onHistorySeedApplied
            self.onScrollGestureApplied = onScrollGestureApplied
            self.onRenderedTextChanged = onRenderedTextChanged
            self.onViewportSizeChanged = onViewportSizeChanged
            self.onSendText = onSendText
            self.onSendKey = onSendKey
        }

        public func makeUIView(context: Context) -> GhosttyRemoteTerminalHostView { GhosttyRemoteTerminalHostView() }

        public func updateUIView(_ hostView: GhosttyRemoteTerminalHostView, context: Context) {
            hostView.onInputReadinessChanged = { ready in Task { @MainActor in onInputReadinessChanged(ready) } }
            if let onOutputBatchApplied {
                hostView.onOutputBatchApplied = { batchID in Task { @MainActor in onOutputBatchApplied(batchID) } }
            } else {
                hostView.onOutputBatchApplied = nil
            }
            if let onHistorySeedApplied {
                hostView.onHistorySeedApplied = { batchID in Task { @MainActor in onHistorySeedApplied(batchID) } }
            } else {
                hostView.onHistorySeedApplied = nil
            }
            if let onScrollGestureApplied {
                hostView.onScrollGestureApplied = { Task { @MainActor in onScrollGestureApplied() } }
            } else {
                hostView.onScrollGestureApplied = nil
            }
            hostView.onViewportSizeChanged = { columns, rows in Task { @MainActor in onViewportSizeChanged(columns, rows) } }
            hostView.onSendText = { text in Task { @MainActor in onSendText(text) } }
            hostView.onSendKey = { key in Task { @MainActor in onSendKey(key) } }
            if let onRenderedTextChanged {
                hostView.onRenderedTextChanged = { text in Task { @MainActor in onRenderedTextChanged(text) } }
            } else {
                hostView.onRenderedTextChanged = nil
            }
            hostView.setTerminalVisible(isVisible)
            hostView.setAcceptsTerminalInput(acceptsInput && !isBusy)
            hostView.update(ownerEpoch: ownerEpoch, endedRender: endedRender, fallbackText: fallbackText)
        }

        public static func dismantleUIView(_ hostView: GhosttyRemoteTerminalHostView, coordinator: ()) { hostView.prepareForDismantle() }
    }

    @MainActor public final class GhosttyRemoteTerminalHostView: UIView, UIKeyInput, UITextInputTraits {
        private struct DetachedGhosttySession: @unchecked Sendable { let rawValue: ghostty_session_t }

        nonisolated(unsafe) static var sessionFreeHandlerForTesting: @Sendable (ghostty_session_t) -> Void = { session in
            ghostty_session_free(session)
        }
        nonisolated(unsafe) private static let hostManagedReceiveBufferCallback: ghostty_surface_receive_buffer_cb = { userdata, ptr, len in
            guard ptr != nil, len > 0 else { return }
            let hostView = userdata.map { Unmanaged<GhosttyRemoteTerminalHostView>.fromOpaque($0).takeUnretainedValue() }
            ghosttyRemoteTerminalTrace("host_managed_output_ignored len=\(len) has_host=\(hostView != nil)")
        }
        nonisolated(unsafe) private static let hostManagedResizeCallback: ghostty_surface_receive_resize_cb = {
            userdata, columns, rows, widthPixels, heightPixels in
            let hostView = userdata.map { Unmanaged<GhosttyRemoteTerminalHostView>.fromOpaque($0).takeUnretainedValue() }
            Task { @MainActor in hostView?.handleHostManagedResize(columns: columns, rows: rows, widthPixels: widthPixels, heightPixels: heightPixels)
            }
        }

        private static let defaultFontSize: Float = 11
        private static let contentInsets = GhosttyRemoteTerminalViewport.contentInsets
        private static let sessionResetSequence = Data("\u{001B}c".utf8)
        private static let promptEOLMarkStartSequence = Data("\u{001B}[1m\u{001B}[7m%".utf8)
        private static let promptEOLMarkEndSequence = Data("\r \r\r\u{001B}[0m\u{001B}[27m\u{001B}[24m\u{001B}[J".utf8)
        private var session: ghostty_session_t?
        private var retainedSessionStandardInputWriteDescriptor: Int32?
        private var activeOwnerEpoch: GhosttyRemoteTerminalOwnerEpoch?
        private var activeEndedRender: GhosttyRemoteTerminalEndedRender?
        private var lastAppliedOwnerEpochID: String?
        private var lastAppliedHistorySeedID: String?
        private var appliedOutputBatchIDs: Set<String> = []
        private var lastAppliedEndedRenderID: String?
        private var ownerBootstrapStartedAt: Date?
        private var ownerBootstrapEpochID: String?
        private var firstNonBlankOwnerEpochID: String?
        private var lastStaticRenderPixelSize = CGSize.zero
        private let fallbackLabel = UILabel()
        private let suppressedSoftwareKeyboardInputView = UIView(frame: .zero)
        private lazy var terminalAccessoryView = TerminalAccessoryToolbar(
            onText: { [weak self] text in self?.sendAccessoryText(text) }, onKey: { [weak self] key in self?.sendAccessoryKey(key) },
            onControl: { [weak self] in self?.toggleAccessoryControlModifier() },
            onKeyboardToggle: { [weak self] in self?.toggleAccessorySoftwareKeyboard() })
        private lazy var activateInputRecognizer = UITapGestureRecognizer(target: self, action: #selector(handleTapToActivateInput))
        private lazy var scrollPanRecognizer = UIPanGestureRecognizer(target: self, action: #selector(handleScrollPan))
        private var lastScrollTranslation = CGPoint.zero
        private var currentRenderedText = ""
        private var lastEmittedRenderedText: String?
        private var lastReportedInputReadiness = false
        private var lastReportedViewportSize: (columns: Int, rows: Int)?
        private var lastSyncedBasePixelSize = CGSize.zero
        private var lastSyncedPixelSize = CGSize.zero
        private var lastSyncedScaleFactor: Double = 0
        private var lastSyncedFocus = false
        private var lastSyncedOcclusion = false
        private var lastSyncedUserInterfaceIdiom: UIUserInterfaceIdiom?
        private var firstResponderRequestScheduled = false
        private var accessoryControlModifierPending = false
        private var suppressesSoftwareKeyboard = false
        private var postRefreshEmissionScheduled = false
        private var scrollSettledEmissionGeneration: UInt64 = 0
        private var scrollSettledEmissionTasks: [Task<Void, Never>] = []
        private var didScrollDuringCurrentPan = false
        private var momentumDisplayLink: CADisplayLink?
        private var momentumVelocity = CGPoint.zero
        private var lastMomentumTimestamp: CFTimeInterval = 0
        private var isTerminalVisible = true

        public private(set) var acceptsTerminalInput = false
        public var onInputReadinessChanged: ((Bool) -> Void)?
        public var onOutputBatchApplied: ((String) -> Void)?
        public var onHistorySeedApplied: ((String) -> Void)?
        public var onScrollGestureApplied: (() -> Void)?
        public var onViewportSizeChanged: ((Int, Int) -> Void)?
        public var onSendText: ((String) -> Void)?
        public var onSendKey: ((String) -> Void)?
        public var onRenderedTextChanged: ((String) -> Void)? {
            didSet {
                guard onRenderedTextChanged == nil else { return }
                currentRenderedText = ""
                lastEmittedRenderedText = nil
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
        public override var inputView: UIView? { suppressesSoftwareKeyboard ? suppressedSoftwareKeyboardInputView : nil }
        public override var inputAccessoryView: UIView? { acceptsTerminalInput ? terminalAccessoryView : nil }
        public override var canBecomeFirstResponder: Bool { acceptsTerminalInput }
        public var hasText: Bool { false }
        var userInterfaceIdiomOverrideForTesting: UIUserInterfaceIdiom?

        public override init(frame: CGRect) {
            super.init(frame: frame)
            backgroundColor = UIColor(red: 0.10, green: 0.12, blue: 0.15, alpha: 1)
            isOpaque = true
            isAccessibilityElement = true
            accessibilityIdentifier = "terminal.surface"
            accessibilityLabel = "Terminal surface"
            configureInputAssistant()
            configureFallbackLabel()
            configureGestures()
        }

        @available(*, unavailable) required init?(coder: NSCoder) { nil }

        deinit { MainActor.assumeIsolated { teardownSession() } }

        public override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil else {
                stopScrollMomentum(finishedScroll: didScrollDuringCurrentPan)
                teardownSession()
                reportInputReadinessIfNeeded()
                return
            }
            ensureSession()
            requestFirstResponderIfNeeded()
            syncSessionState()
            reportInputReadinessIfNeeded()
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
            guard canProcessKeyboardInput else { return [] }
            return [
                UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(handleEscape)),
                UIKeyCommand(input: "c", modifierFlags: .control, action: #selector(handleControlC)),
                UIKeyCommand(input: UIKeyCommand.inputUpArrow, modifierFlags: [], action: #selector(handleUpArrow)),
                UIKeyCommand(input: UIKeyCommand.inputDownArrow, modifierFlags: [], action: #selector(handleDownArrow)),
                UIKeyCommand(input: UIKeyCommand.inputLeftArrow, modifierFlags: [], action: #selector(handleLeftArrow)),
                UIKeyCommand(input: UIKeyCommand.inputRightArrow, modifierFlags: [], action: #selector(handleRightArrow)),
                UIKeyCommand(input: "\t", modifierFlags: [], action: #selector(handleTab)),
                UIKeyCommand(input: "\t", modifierFlags: .shift, action: #selector(handleBackTab)),
                UIKeyCommand(input: UIKeyCommand.inputPageUp, modifierFlags: [], action: #selector(handlePageUp)),
                UIKeyCommand(input: UIKeyCommand.inputPageDown, modifierFlags: [], action: #selector(handlePageDown)),
                UIKeyCommand(input: UIKeyCommand.inputHome, modifierFlags: [], action: #selector(handleHome)),
                UIKeyCommand(input: UIKeyCommand.inputEnd, modifierFlags: [], action: #selector(handleEnd)),
            ]
        }

        public func update(ownerEpoch: GhosttyRemoteTerminalOwnerEpoch?, endedRender: GhosttyRemoteTerminalEndedRender?, fallbackText: String) {
            if window != nil { ensureSession() }
            ghosttyRemoteTerminalTrace(
                "update owner_epoch=\(ownerEpoch?.id ?? "nil") ended=\(endedRender?.id ?? "nil") pending_output_count=\(ownerEpoch?.pendingOutputs.count ?? 0) pending_output_last=\(ownerEpoch?.pendingOutputs.last?.id ?? "nil")"
            )
            fallbackLabel.text = ownerEpoch == nil && endedRender == nil ? fallbackText : nil
            fallbackLabel.isHidden = ownerEpoch != nil || endedRender != nil
            syncFirstResponder()

            guard let session else {
                updateRenderedTextSource(ownerEpoch: ownerEpoch, endedRender: endedRender, fallbackText: fallbackText, session: nil)
                emitRenderedTextIfNeeded()
                reportInputReadinessIfNeeded()
                return
            }
            if let ownerEpoch {
                applyOwnerEpoch(ownerEpoch, into: session)
                emitRenderedTextIfNeeded()
                reportInputReadinessIfNeeded()
                return
            }
            if let endedRender {
                applyEndedRender(endedRender, into: session)
                emitRenderedTextIfNeeded()
                reportInputReadinessIfNeeded()
                return
            }
            activeOwnerEpoch = nil
            activeEndedRender = nil
            updateRenderedTextSource(ownerEpoch: nil, endedRender: nil, fallbackText: fallbackText, session: session)
            emitRenderedTextIfNeeded()
            reportInputReadinessIfNeeded()
        }

        public func insertText(_ text: String) {
            guard canProcessKeyboardInput else {
                syncFirstResponder()
                reportInputReadinessIfNeeded()
                return
            }
            guard !text.isEmpty else { return }
            if sendPendingControlModifierIfNeeded(for: text) { return }
            if text == "\n" { onSendKey?("enter") } else { onSendText?(text) }
        }

        public func deleteBackward() {
            guard canProcessKeyboardInput else {
                syncFirstResponder()
                reportInputReadinessIfNeeded()
                return
            }
            clearAccessoryControlModifier()
            onSendKey?("backspace")
        }

        public override func paste(_ sender: Any?) {
            guard canProcessKeyboardInput else {
                syncFirstResponder()
                reportInputReadinessIfNeeded()
                return
            }
            guard let pasted = UIPasteboard.general.string, !pasted.isEmpty else { return }
            clearAccessoryControlModifier()
            onSendText?(pasted)
        }

        @discardableResult public override func becomeFirstResponder() -> Bool {
            let becameFirstResponder = super.becomeFirstResponder()
            if becameFirstResponder { scheduleKeyboardVisibilityRefresh() }
            reportInputReadinessIfNeeded()
            return becameFirstResponder
        }

        @discardableResult public override func resignFirstResponder() -> Bool {
            let resignedFirstResponder = super.resignFirstResponder()
            if resignedFirstResponder { scheduleKeyboardVisibilityRefresh() }
            reportInputReadinessIfNeeded()
            return resignedFirstResponder
        }

        @objc private func handleTapToActivateInput() {
            guard acceptsTerminalInput else { return }
            becomeFirstResponder()
        }

        @objc private func handleScrollPan(_ recognizer: UIPanGestureRecognizer) {
            switch recognizer.state {
            case .began:
                stopScrollMomentum(finishedScroll: false)
                lastScrollTranslation = recognizer.translation(in: self)
                didScrollDuringCurrentPan = false
                _ = sendMousePosition(at: recognizer.location(in: self))
                if acceptsTerminalInput { becomeFirstResponder() }
            case .changed:
                let translation = recognizer.translation(in: self)
                let deltaX = translation.x - lastScrollTranslation.x
                let deltaY = translation.y - lastScrollTranslation.y
                lastScrollTranslation = translation
                guard abs(deltaX) > 0.5 || abs(deltaY) > 0.5 else { return }
                didScrollDuringCurrentPan = true
                applyHistorySeedIfNeededBeforeScroll()
                _ = sendMousePosition(at: recognizer.location(in: self))
                let scrollDelta = GhosttyRemoteTerminalScrollMapper.scrollDelta(forPanDelta: CGPoint(x: deltaX, y: deltaY), scaleFactor: scaleFactor)
                _ = sendScroll(
                    horizontal: scrollDelta.x, vertical: scrollDelta.y,
                    mods: Self.makeScrollMods(hasPreciseDeltas: true, momentumState: recognizer.state))
            case .ended:
                lastScrollTranslation = .zero
                guard didScrollDuringCurrentPan else { return }
                let velocity = GhosttyRemoteTerminalScrollMapper.clampedMomentumVelocity(recognizer.velocity(in: self))
                if GhosttyRemoteTerminalScrollMapper.shouldContinueMomentum(velocity: velocity) {
                    startScrollMomentum(velocity: velocity)
                } else {
                    finishScrollGesture()
                }
            default:
                lastScrollTranslation = .zero
                stopScrollMomentum(finishedScroll: false)
                if didScrollDuringCurrentPan { finishScrollGesture() }
            }
        }

        private func startScrollMomentum(velocity: CGPoint) {
            stopScrollMomentum(finishedScroll: false)
            momentumVelocity = velocity
            lastMomentumTimestamp = 0
            let displayLink = CADisplayLink(target: self, selector: #selector(handleScrollMomentumFrame))
            displayLink.add(to: .main, forMode: .common)
            momentumDisplayLink = displayLink
        }

        @objc private func handleScrollMomentumFrame(_ displayLink: CADisplayLink) {
            guard isTerminalVisible, window != nil else {
                stopScrollMomentum(finishedScroll: didScrollDuringCurrentPan)
                return
            }
            if lastMomentumTimestamp == 0 {
                lastMomentumTimestamp = displayLink.timestamp
                return
            }
            let elapsed = displayLink.timestamp - lastMomentumTimestamp
            lastMomentumTimestamp = displayLink.timestamp
            let scrollDelta = GhosttyRemoteTerminalScrollMapper.momentumFrameDelta(
                velocity: momentumVelocity, elapsed: elapsed, scaleFactor: scaleFactor)
            if abs(scrollDelta.x) > 0 || abs(scrollDelta.y) > 0 {
                _ = sendScroll(
                    horizontal: scrollDelta.x, vertical: scrollDelta.y, mods: Self.makeScrollMods(hasPreciseDeltas: true, momentumState: .changed))
            }
            momentumVelocity = GhosttyRemoteTerminalScrollMapper.decayedMomentumVelocity(
                momentumVelocity, elapsed: elapsed, decelerationRate: UIScrollView.DecelerationRate.normal.rawValue)
            guard GhosttyRemoteTerminalScrollMapper.shouldContinueMomentum(velocity: momentumVelocity) else {
                stopScrollMomentum(finishedScroll: didScrollDuringCurrentPan)
                return
            }
        }

        private func stopScrollMomentum(finishedScroll: Bool) {
            momentumDisplayLink?.invalidate()
            momentumDisplayLink = nil
            momentumVelocity = .zero
            lastMomentumTimestamp = 0
            if finishedScroll { finishScrollGesture() }
        }

        private func finishScrollGesture() {
            scheduleScrollSettledEmissions()
            onScrollGestureApplied?()
            didScrollDuringCurrentPan = false
        }

        @objc private func handleEscape() { sendAccessoryKey("esc") }
        @objc private func handleControlC() {
            if canProcessKeyboardInput {
                clearAccessoryControlModifier()
                onSendKey?("ctrl+c")
            }
        }
        @objc private func handleUpArrow() { sendAccessoryKey("up") }
        @objc private func handleDownArrow() { sendAccessoryKey("down") }
        @objc private func handleLeftArrow() { sendAccessoryKey("left") }
        @objc private func handleRightArrow() { sendAccessoryKey("right") }
        @objc private func handleTab() { sendAccessoryKey("tab") }
        @objc private func handleBackTab() { sendAccessoryKey("backtab") }
        @objc private func handlePageUp() { sendAccessoryKey("pageup") }
        @objc private func handlePageDown() { sendAccessoryKey("pagedown") }
        @objc private func handleHome() { sendAccessoryKey("home") }
        @objc private func handleEnd() { sendAccessoryKey("end") }

        private func sendAccessoryText(_ text: String) {
            guard canProcessKeyboardInput, !text.isEmpty else { return }
            if sendPendingControlModifierIfNeeded(for: text) { return }
            clearAccessoryControlModifier()
            onSendText?(text)
        }

        private func sendAccessoryKey(_ key: String) {
            guard canProcessKeyboardInput else { return }
            clearAccessoryControlModifier()
            onSendKey?(key)
        }

        private func toggleAccessoryControlModifier() {
            guard canProcessKeyboardInput else { return }
            accessoryControlModifierPending.toggle()
            terminalAccessoryView.isControlPending = accessoryControlModifierPending
        }

        private func clearAccessoryControlModifier() {
            guard accessoryControlModifierPending else { return }
            accessoryControlModifierPending = false
            terminalAccessoryView.isControlPending = false
        }

        private func sendPendingControlModifierIfNeeded(for text: String) -> Bool {
            guard accessoryControlModifierPending else { return false }
            defer { clearAccessoryControlModifier() }
            guard text.count == 1, let scalar = text.unicodeScalars.first, scalar.properties.isAlphabetic else { return false }
            onSendKey?("ctrl+\(String(scalar).lowercased())")
            return true
        }

        private func toggleAccessorySoftwareKeyboard() { setSoftwareKeyboardVisible(suppressesSoftwareKeyboard) }

        private final class TerminalAccessoryToolbar: UIView {
            private static let toolbarHeight: CGFloat = 58
            private struct Metrics {
                let horizontalInset: CGFloat
                let verticalInset: CGFloat
                let spacing: CGFloat
                let textButtonWidth: CGFloat
                let iconButtonWidth: CGFloat
                let buttonHeight: CGFloat
                let cornerRadius: CGFloat
                let fontSize: CGFloat

                static let regular = Metrics(
                    horizontalInset: 12, verticalInset: 10, spacing: 8, textButtonWidth: 64, iconButtonWidth: 56, buttonHeight: 38, cornerRadius: 8,
                    fontSize: 17)
                static let phone = Metrics(
                    horizontalInset: 8, verticalInset: 10, spacing: 6, textButtonWidth: 50, iconButtonWidth: 46, buttonHeight: 36, cornerRadius: 7,
                    fontSize: 16)
            }

            var isControlPending = false { didSet { updateControlButtonAppearance() } }
            var isKeyboardVisible = true { didSet { updateKeyboardButtonImage() } }

            private let onText: (String) -> Void
            private let onKey: (String) -> Void
            private let onControl: () -> Void
            private let onKeyboardToggle: () -> Void
            private let toolbarStackView = UIStackView()
            private let scrollView = UIScrollView()
            private let contentStackView = UIStackView()
            private let pinnedStackView = UIStackView()
            private let controlButton = UIButton(type: .system)
            private let joystickButton = DirectionalPadButton(type: .system)
            private let keyboardButton = UIButton(type: .system)
            private var metrics = TerminalAccessoryToolbar.metrics(for: UIDevice.current.userInterfaceIdiom)
            private var toolbarLeadingConstraint: NSLayoutConstraint?
            private var toolbarTrailingConstraint: NSLayoutConstraint?
            private var toolbarTopConstraint: NSLayoutConstraint?
            private var toolbarBottomConstraint: NSLayoutConstraint?
            private var textButtonWidthConstraints: [NSLayoutConstraint] = []
            private var iconButtonWidthConstraints: [NSLayoutConstraint] = []
            private var buttonHeightConstraints: [NSLayoutConstraint] = []
            private var configuredButtons: [UIButton] = []

            override var intrinsicContentSize: CGSize { CGSize(width: UIView.noIntrinsicMetric, height: Self.toolbarHeight) }

            override func sizeThatFits(_ size: CGSize) -> CGSize { CGSize(width: size.width, height: Self.toolbarHeight) }

            init(
                onText: @escaping (String) -> Void, onKey: @escaping (String) -> Void, onControl: @escaping () -> Void,
                onKeyboardToggle: @escaping () -> Void
            ) {
                self.onText = onText
                self.onKey = onKey
                self.onControl = onControl
                self.onKeyboardToggle = onKeyboardToggle
                super.init(frame: CGRect(x: 0, y: 0, width: 0, height: Self.toolbarHeight))
                configureView()
            }

            @available(*, unavailable) required init?(coder: NSCoder) { nil }

            private func configureView() {
                backgroundColor = UIColor(red: 0.10, green: 0.12, blue: 0.15, alpha: 1)
                autoresizingMask = [.flexibleWidth, .flexibleHeight]
                insetsLayoutMarginsFromSafeArea = false
                layoutMargins = .zero
                preservesSuperviewLayoutMargins = false

                toolbarStackView.translatesAutoresizingMaskIntoConstraints = false
                toolbarStackView.axis = .horizontal
                toolbarStackView.alignment = .center
                toolbarStackView.spacing = metrics.spacing
                addSubview(toolbarStackView)

                scrollView.translatesAutoresizingMaskIntoConstraints = false
                scrollView.alwaysBounceHorizontal = true
                scrollView.contentInsetAdjustmentBehavior = .never
                scrollView.showsHorizontalScrollIndicator = false
                scrollView.setContentHuggingPriority(.defaultLow, for: .horizontal)
                scrollView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
                toolbarStackView.addArrangedSubview(scrollView)

                contentStackView.translatesAutoresizingMaskIntoConstraints = false
                contentStackView.axis = .horizontal
                contentStackView.alignment = .center
                contentStackView.spacing = metrics.spacing
                scrollView.addSubview(contentStackView)

                pinnedStackView.translatesAutoresizingMaskIntoConstraints = false
                pinnedStackView.axis = .horizontal
                pinnedStackView.alignment = .center
                pinnedStackView.spacing = metrics.spacing
                pinnedStackView.setContentHuggingPriority(.required, for: .horizontal)
                pinnedStackView.setContentCompressionResistancePriority(.required, for: .horizontal)
                toolbarStackView.addArrangedSubview(pinnedStackView)

                let leadingConstraint = toolbarStackView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: metrics.horizontalInset)
                let trailingConstraint = toolbarStackView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -metrics.horizontalInset)
                let topConstraint = toolbarStackView.topAnchor.constraint(equalTo: topAnchor, constant: metrics.verticalInset)
                let bottomConstraint = toolbarStackView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -metrics.verticalInset)
                toolbarLeadingConstraint = leadingConstraint
                toolbarTrailingConstraint = trailingConstraint
                toolbarTopConstraint = topConstraint
                toolbarBottomConstraint = bottomConstraint

                NSLayoutConstraint.activate([
                    heightAnchor.constraint(equalToConstant: Self.toolbarHeight), leadingConstraint, trailingConstraint, topConstraint,
                    bottomConstraint, scrollView.heightAnchor.constraint(equalTo: toolbarStackView.heightAnchor),
                    contentStackView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
                    contentStackView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
                    contentStackView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
                    contentStackView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
                    contentStackView.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor),
                ])

                addTextButton("tab") { [weak self] in self?.onKey("tab") }
                addTextButton("/") { [weak self] in self?.onText("/") }
                addTextButton("~") { [weak self] in self?.onText("~") }
                addTextButton("|") { [weak self] in self?.onText("|") }
                addTextButton("-") { [weak self] in self?.onText("-") }
                addTextButton("_") { [weak self] in self?.onText("_") }
                addTextButton("esc") { [weak self] in self?.onKey("esc") }
                configureButton(controlButton, title: "ctrl")
                controlButton.accessibilityLabel = "Control"
                controlButton.addAction(UIAction { [weak self] _ in self?.onControl() }, for: .touchUpInside)
                contentStackView.addArrangedSubview(controlButton)
                configureButton(joystickButton, imageName: "arrow.up.and.down.and.arrow.left.and.right")
                joystickButton.accessibilityIdentifier = "terminal.accessory.arrow-joystick"
                joystickButton.accessibilityLabel = "Arrow key joystick"
                joystickButton.accessibilityHint = "Tap or drag toward an edge to send an arrow key."
                joystickButton.onDirection = { [weak self] direction in self?.onKey(direction) }
                joystickButton.accessibilityCustomActions = [
                    UIAccessibilityCustomAction(name: "Up arrow") { [weak self] _ in
                        self?.onKey("up")
                        return true
                    },
                    UIAccessibilityCustomAction(name: "Down arrow") { [weak self] _ in
                        self?.onKey("down")
                        return true
                    },
                    UIAccessibilityCustomAction(name: "Left arrow") { [weak self] _ in
                        self?.onKey("left")
                        return true
                    },
                    UIAccessibilityCustomAction(name: "Right arrow") { [weak self] _ in
                        self?.onKey("right")
                        return true
                    },
                ]
                pinnedStackView.addArrangedSubview(joystickButton)

                configureButton(keyboardButton, imageName: "keyboard.chevron.compact.down")
                keyboardButton.accessibilityIdentifier = "terminal.accessory.keyboard-toggle"
                keyboardButton.accessibilityLabel = "Hide keyboard"
                keyboardButton.addAction(UIAction { [weak self] _ in self?.onKeyboardToggle() }, for: .touchUpInside)
                pinnedStackView.addArrangedSubview(keyboardButton)
            }

            private func addTextButton(_ title: String, action: @escaping () -> Void) {
                let button = UIButton(type: .system)
                configureButton(button, title: title)
                button.accessibilityLabel = title
                button.addAction(UIAction { _ in action() }, for: .touchUpInside)
                contentStackView.addArrangedSubview(button)
            }

            private func configureButton(_ button: UIButton, title: String? = nil, imageName: String? = nil) {
                button.translatesAutoresizingMaskIntoConstraints = false
                button.backgroundColor = UIColor.white.withAlphaComponent(0.13)
                button.tintColor = .white
                button.layer.cornerRadius = metrics.cornerRadius
                button.layer.cornerCurve = .continuous
                button.layer.borderWidth = 1
                button.layer.borderColor = UIColor.white.withAlphaComponent(0.14).cgColor
                button.titleLabel?.font = .monospacedSystemFont(ofSize: metrics.fontSize, weight: .semibold)
                button.setTitleColor(.white, for: .normal)
                configuredButtons.append(button)
                if let title {
                    button.setTitle(title, for: .normal)
                    let widthConstraint = button.widthAnchor.constraint(equalToConstant: metrics.textButtonWidth)
                    widthConstraint.isActive = true
                    textButtonWidthConstraints.append(widthConstraint)
                }
                if let imageName {
                    button.setImage(UIImage(systemName: imageName) ?? UIImage(systemName: "arrow.up.and.down"), for: .normal)
                    let widthConstraint = button.widthAnchor.constraint(equalToConstant: metrics.iconButtonWidth)
                    widthConstraint.isActive = true
                    iconButtonWidthConstraints.append(widthConstraint)
                }
                let heightConstraint = button.heightAnchor.constraint(equalToConstant: metrics.buttonHeight)
                heightConstraint.isActive = true
                buttonHeightConstraints.append(heightConstraint)
            }

            private static func metrics(for userInterfaceIdiom: UIUserInterfaceIdiom) -> Metrics { userInterfaceIdiom == .phone ? .phone : .regular }

            private func applyMetrics(for userInterfaceIdiom: UIUserInterfaceIdiom) {
                let nextMetrics = Self.metrics(for: userInterfaceIdiom)
                metrics = nextMetrics
                toolbarLeadingConstraint?.constant = nextMetrics.horizontalInset
                toolbarTrailingConstraint?.constant = -nextMetrics.horizontalInset
                toolbarTopConstraint?.constant = nextMetrics.verticalInset
                toolbarBottomConstraint?.constant = -nextMetrics.verticalInset
                toolbarStackView.spacing = nextMetrics.spacing
                contentStackView.spacing = nextMetrics.spacing
                pinnedStackView.spacing = nextMetrics.spacing
                superview?.setNeedsLayout()
                textButtonWidthConstraints.forEach { $0.constant = nextMetrics.textButtonWidth }
                iconButtonWidthConstraints.forEach { $0.constant = nextMetrics.iconButtonWidth }
                buttonHeightConstraints.forEach { $0.constant = nextMetrics.buttonHeight }
                configuredButtons.forEach { button in
                    button.layer.cornerRadius = nextMetrics.cornerRadius
                    button.titleLabel?.font = .monospacedSystemFont(ofSize: nextMetrics.fontSize, weight: .semibold)
                    button.invalidateIntrinsicContentSize()
                }
                setNeedsLayout()
                invalidateIntrinsicContentSize()
            }

            private func updateControlButtonAppearance() {
                controlButton.backgroundColor = isControlPending ? .white : UIColor.white.withAlphaComponent(0.13)
                controlButton.setTitleColor(isControlPending ? .black : .white, for: .normal)
                controlButton.layer.borderColor = UIColor.white.withAlphaComponent(isControlPending ? 0 : 0.14).cgColor
            }

            private func updateKeyboardButtonImage() {
                let imageName = isKeyboardVisible ? "keyboard.chevron.compact.down" : "keyboard"
                keyboardButton.setImage(UIImage(systemName: imageName), for: .normal)
                keyboardButton.accessibilityLabel = isKeyboardVisible ? "Hide keyboard" : "Show keyboard"
            }

            var buttonAccessibilityLabelsForTesting: (scrollable: [String], pinned: [String]) {
                (buttonLabels(in: contentStackView), buttonLabels(in: pinnedStackView))
            }

            func layoutFramesForTesting(width: CGFloat, userInterfaceIdiom: UIUserInterfaceIdiom = UIDevice.current.userInterfaceIdiom) -> (
                scrollView: CGRect, joystickButton: CGRect, keyboardButton: CGRect
            ) {
                prepareLayoutForTesting(width: width, userInterfaceIdiom: userInterfaceIdiom)
                return (
                    scrollView: scrollView.frame, joystickButton: joystickButton.convert(joystickButton.bounds, to: self),
                    keyboardButton: keyboardButton.convert(keyboardButton.bounds, to: self)
                )
            }

            func buttonWidthsForTesting(width: CGFloat, userInterfaceIdiom: UIUserInterfaceIdiom = UIDevice.current.userInterfaceIdiom) -> (
                scrollable: [CGFloat], pinned: [CGFloat]
            ) {
                prepareLayoutForTesting(width: width, userInterfaceIdiom: userInterfaceIdiom)
                return (buttonWidths(in: contentStackView), buttonWidths(in: pinnedStackView))
            }

            private func prepareLayoutForTesting(width: CGFloat, userInterfaceIdiom: UIUserInterfaceIdiom) {
                applyMetrics(for: userInterfaceIdiom)
                frame = CGRect(x: 0, y: 0, width: width, height: Self.toolbarHeight)
                setNeedsLayout()
                layoutIfNeeded()
            }

            private func buttonLabels(in stackView: UIStackView) -> [String] { stackView.arrangedSubviews.compactMap { $0.accessibilityLabel } }

            private func buttonWidths(in stackView: UIStackView) -> [CGFloat] { stackView.arrangedSubviews.map { $0.bounds.width } }
        }

        private final class DirectionalPadButton: UIButton {
            private static let activationHorizontalMargin: CGFloat = 8
            private static let activationVerticalMargin: CGFloat = 12
            private static let releaseMargin: CGFloat = 100
            private static let centerDeadZone: CGFloat = 4

            var onDirection: ((String) -> Void)?

            override func point(inside point: CGPoint, with event: UIEvent?) -> Bool { Self.acceptsActivation(at: point, in: bounds) }

            override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
                isHighlighted = true
                return true
            }

            override func continueTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
                isHighlighted = Self.acceptsRelease(at: touch.location(in: self), in: bounds)
                return true
            }

            override func endTracking(_ touch: UITouch?, with event: UIEvent?) {
                defer { isHighlighted = false }
                guard let touch else { return }
                let point = touch.location(in: self)
                guard Self.acceptsRelease(at: point, in: bounds), let direction = Self.direction(for: point, in: bounds) else { return }
                onDirection?(direction)
            }

            override func cancelTracking(with event: UIEvent?) { isHighlighted = false }

            static func acceptsActivation(at point: CGPoint, in bounds: CGRect) -> Bool {
                bounds.insetBy(dx: -activationHorizontalMargin, dy: -activationVerticalMargin).contains(point)
            }

            static func acceptsRelease(at point: CGPoint, in bounds: CGRect) -> Bool {
                bounds.insetBy(dx: -releaseMargin, dy: -releaseMargin).contains(point)
            }

            static func direction(for point: CGPoint, in bounds: CGRect) -> String? {
                let dx = point.x - bounds.midX
                let dy = point.y - bounds.midY
                guard abs(dx) > centerDeadZone || abs(dy) > centerDeadZone else { return nil }
                if abs(dx) > abs(dy) { return dx < 0 ? "left" : "right" }
                return dy < 0 ? "up" : "down"
            }
        }

        private func configureInputAssistant() {
            inputAssistantItem.leadingBarButtonGroups = []
            inputAssistantItem.trailingBarButtonGroups = []
            inputAssistantItem.allowsHidingShortcuts = true
        }

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

        func setAcceptsTerminalInput(_ enabled: Bool) {
            guard acceptsTerminalInput != enabled else { return }
            acceptsTerminalInput = enabled
            ghosttyRemoteTerminalTrace("set_accepts_input enabled=\(enabled ? 1 : 0)")
            if enabled { requestFirstResponderIfNeeded() } else { syncFirstResponder() }
            reportInputReadinessIfNeeded()
        }

        func setSoftwareKeyboardVisible(_ visible: Bool) {
            guard acceptsTerminalInput else {
                reportInputReadinessIfNeeded()
                return
            }
            suppressesSoftwareKeyboard = !visible
            terminalAccessoryView.isKeyboardVisible = visible
            if visible {
                if isFirstResponder { reloadInputViews() } else { becomeFirstResponder() }
            } else if isFirstResponder {
                reloadInputViews()
            } else {
                becomeFirstResponder()
            }
            scheduleKeyboardVisibilityRefresh()
            reportInputReadinessIfNeeded()
        }

        func setTerminalVisible(_ visible: Bool) {
            guard isTerminalVisible != visible else { return }
            isTerminalVisible = visible
            ghosttyRemoteTerminalTrace("set_visible visible=\(visible ? 1 : 0)")
            if visible {
                lastEmittedRenderedText = nil
                currentRenderedText = ""
            } else {
                stopScrollMomentum(finishedScroll: didScrollDuringCurrentPan)
                currentRenderedText = ""
            }
            isHidden = !visible
            accessibilityElementsHidden = !visible
            syncSessionState()
            reportInputReadinessIfNeeded()
        }

        func prepareForDismantle() {
            stopScrollMomentum(finishedScroll: didScrollDuringCurrentPan)
            teardownSession()
        }

        var hasActiveSessionForTesting: Bool { session != nil }
        var hasRetainedSessionStandardInputWriteDescriptorForTesting: Bool { retainedSessionStandardInputWriteDescriptor != nil }

        private func ensureSession() {
            guard session == nil else { return }
            do {
                try GhosttyMobileAppService.shared.startIfNeeded()
                guard let app = GhosttyMobileAppService.shared.app else { return }
                ghosttyRemoteTerminalTrace("ensure_session begin bounds=\(Int(bounds.width))x\(Int(bounds.height))")
                session = createSession(app: app)
                ghosttyRemoteTerminalTrace("ensure_session end created=\(session == nil ? 0 : 1)")
                syncSessionState()
            } catch {
                fallbackLabel.text = error.localizedDescription
                fallbackLabel.isHidden = false
                ghosttyRemoteTerminalTrace("ensure_session failure error=\(error.localizedDescription.replacingOccurrences(of: "\n", with: "\\n"))")
            }
        }

        private func teardownSession() {
            stopScrollMomentum(finishedScroll: didScrollDuringCurrentPan)
            guard let session else { return }
            ghosttyRemoteTerminalTrace("teardown_session")
            if isFirstResponder { resignFirstResponder() }
            if let retainedSessionStandardInputWriteDescriptor {
                _ = close(retainedSessionStandardInputWriteDescriptor)
                self.retainedSessionStandardInputWriteDescriptor = nil
            }
            self.session = nil
            activeOwnerEpoch = nil
            activeEndedRender = nil
            lastAppliedOwnerEpochID = nil
            lastAppliedHistorySeedID = nil
            appliedOutputBatchIDs.removeAll()
            lastAppliedEndedRenderID = nil
            ownerBootstrapStartedAt = nil
            ownerBootstrapEpochID = nil
            firstNonBlankOwnerEpochID = nil
            lastStaticRenderPixelSize = .zero
            lastReportedViewportSize = nil
            lastSyncedBasePixelSize = .zero
            lastSyncedPixelSize = .zero
            lastSyncedScaleFactor = 0
            lastSyncedFocus = false
            lastSyncedOcclusion = false
            lastSyncedUserInterfaceIdiom = nil
            firstResponderRequestScheduled = false
            currentRenderedText = ""
            lastReportedInputReadiness = false
            cancelScrollSettledEmissionTasks()
            didScrollDuringCurrentPan = false

            let detachedSession = DetachedGhosttySession(rawValue: session)
            ghosttyRemoteTerminalTrace("teardown_session free_scheduled")
            Task.detached(priority: .utility) {
                Self.terminateCarrierProcessIfNeeded(for: detachedSession.rawValue)
                ghosttyRemoteTerminalTrace("teardown_session free_begin")
                Self.sessionFreeHandlerForTesting(detachedSession.rawValue)
                ghosttyRemoteTerminalTrace("teardown_session free_end")
            }
        }

        private nonisolated static func terminateCarrierProcessIfNeeded(for session: ghostty_session_t) {
            let foregroundPID = Int32(ghostty_session_foreground_pid(session))
            guard foregroundPID > 0 else { return }

            let currentProcessGroupID = getpgrp()
            let foregroundProcessGroupID = getpgid(foregroundPID)
            if foregroundProcessGroupID > 0, foregroundProcessGroupID != currentProcessGroupID { _ = kill(-foregroundProcessGroupID, SIGHUP) }

            _ = kill(foregroundPID, SIGHUP)
            usleep(50_000)
            if kill(foregroundPID, 0) == 0 { _ = kill(foregroundPID, SIGKILL) }
        }

        private func createSession(app: ghostty_app_t) -> ghostty_session_t? {
            var sessionConfig = ghostty_session_config_new()
            sessionConfig.surface.platform_tag = GHOSTTY_PLATFORM_IOS
            sessionConfig.surface.platform = ghostty_platform_u(ios: ghostty_platform_ios_s(uiview: Unmanaged.passUnretained(self).toOpaque()))
            sessionConfig.surface.backend = GHOSTTY_SURFACE_IO_BACKEND_HOST_MANAGED
            sessionConfig.surface.receive_userdata = Unmanaged.passUnretained(self).toOpaque()
            sessionConfig.surface.receive_buffer = Self.hostManagedReceiveBufferCallback
            sessionConfig.surface.receive_resize = Self.hostManagedResizeCallback
            sessionConfig.surface.scale_factor = scaleFactor
            sessionConfig.surface.font_size = Self.defaultFontSize
            sessionConfig.surface.use_login_shell = false
            let createdSession = ghostty_session_new(app, &sessionConfig)

            guard let createdSession else { return nil }
            return createdSession
        }

        private func handleHostManagedResize(columns: UInt16, rows: UInt16, widthPixels: UInt32, heightPixels: UInt32) {
            ghosttyRemoteTerminalTrace("host_managed_resize columns=\(columns) rows=\(rows) pixels=\(widthPixels)x\(heightPixels)")
            guard columns > 0, rows > 0 else { return }
            let viewport = GhosttyRemoteTerminalViewport.reportedSize(
                rawColumns: Int(columns), rawRows: Int(rows), bounds: bounds, idiom: terminalUserInterfaceIdiom)
            guard lastReportedViewportSize?.columns != viewport.columns || lastReportedViewportSize?.rows != viewport.rows else { return }
            lastReportedViewportSize = viewport
            onViewportSizeChanged?(viewport.columns, viewport.rows)
        }

        private func replay(snapshot: GhosttyTerminalSnapshot, into session: ghostty_session_t) {
            let vt = GhosttyTerminalSnapshotVTEncoder.encode(snapshot)
            vt.withUnsafeBytes { rawBuffer in
                guard let baseAddress = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return }
                ghostty_session_process_output(session, baseAddress, UInt(vt.count))
            }
            requestSurfaceRefresh()
        }

        private func applyOutput(_ outputData: Data, into session: ghostty_session_t) {
            let renderData = renderableOutputData(from: outputData)
            guard !renderData.isEmpty else { return }
            renderData.withUnsafeBytes { rawBuffer in
                guard let baseAddress = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return }
                ghostty_session_process_output(session, baseAddress, UInt(renderData.count))
            }
            requestSurfaceRefresh()
        }

        private func syncSessionState() {
            guard let session else { return }
            let scale = scaleFactor
            let pixelSize = currentPixelSize
            let idiom = terminalUserInterfaceIdiom
            let hasIdiomChanged = lastSyncedUserInterfaceIdiom != idiom
            let hasSizeChanged = pixelSize != lastSyncedBasePixelSize || hasIdiomChanged
            let hasScaleChanged = scale != lastSyncedScaleFactor
            let isFocused = isFirstResponder
            let hasFocusChanged = isFocused != lastSyncedFocus
            let isOccluded = window == nil || !isTerminalVisible || alpha <= 0.001
            let hasOcclusionChanged = isOccluded != lastSyncedOcclusion
            if hasScaleChanged {
                ghostty_session_set_content_scale(session, scale, scale)
                lastSyncedScaleFactor = scale
            }
            if hasFocusChanged {
                ghostty_session_set_focus(session, isFocused)
                lastSyncedFocus = isFocused
            }
            if hasOcclusionChanged {
                ghostty_session_set_occlusion(session, isOccluded)
                lastSyncedOcclusion = isOccluded
            }
            if hasSizeChanged {
                ghostty_session_set_size(session, UInt32(max(pixelSize.width, 1)), UInt32(max(pixelSize.height, 1)))
                lastSyncedBasePixelSize = pixelSize
                lastSyncedPixelSize = pixelSize
                lastSyncedUserInterfaceIdiom = idiom
            }
            let hasPhoneGridChanged = reconcilePhoneLocalCellGridIfNeeded(session: session, basePixelSize: pixelSize, idiom: idiom)
            ghosttyRemoteTerminalTrace(
                "sync_state visible=\(isTerminalVisible ? 1 : 0) accepts_input=\(acceptsTerminalInput ? 1 : 0) first_responder=\(isFirstResponder ? 1 : 0) pixel=\(Int(activePixelSize.width))x\(Int(activePixelSize.height)) owner_epoch=\(activeOwnerEpoch?.id ?? "nil") ended=\(activeEndedRender?.id ?? "nil")"
            )
            if let endedRender = activeEndedRender, pixelSize.width > 1, pixelSize.height > 1,
                lastAppliedEndedRenderID == endedRender.id && lastStaticRenderPixelSize != activePixelSize
            {
                replay(snapshot: viewportSnapshot(for: endedRender.snapshot, session: session), into: session)
                lastStaticRenderPixelSize = activePixelSize
            }
            if hasSizeChanged || hasScaleChanged || hasFocusChanged || hasOcclusionChanged || hasPhoneGridChanged { requestSurfaceRefresh() }
            if hasSizeChanged || hasScaleChanged || hasPhoneGridChanged { notifyViewportSizeIfChanged() }
            reportInputReadinessIfNeeded()
        }

        @discardableResult private func reconcilePhoneLocalCellGridIfNeeded(
            session: ghostty_session_t, basePixelSize: CGSize, idiom: UIUserInterfaceIdiom
        ) -> Bool {
            guard idiom == .phone else { return false }
            let baseSize = ghostty_session_size(session)
            guard baseSize.columns > 0, baseSize.rows > 0 else { return false }
            let target = GhosttyRemoteTerminalViewport.reportedSize(
                rawColumns: Int(baseSize.columns), rawRows: Int(baseSize.rows), bounds: bounds, idiom: idiom)
            guard target.columns != Int(baseSize.columns) || target.rows != Int(baseSize.rows) else { return false }

            var changed = false
            for _ in 0..<4 {
                let measuredSize = ghostty_session_size(session)
                guard measuredSize.columns > 0, measuredSize.rows > 0 else { break }
                guard Int(measuredSize.columns) != target.columns || Int(measuredSize.rows) != target.rows else { break }

                let currentWidth = measuredSize.width_px > 0 ? CGFloat(measuredSize.width_px) : max(lastSyncedPixelSize.width, basePixelSize.width)
                let currentHeight =
                    measuredSize.height_px > 0 ? CGFloat(measuredSize.height_px) : max(lastSyncedPixelSize.height, basePixelSize.height)
                let widthScale = CGFloat(target.columns) / CGFloat(max(Int(measuredSize.columns), 1))
                let heightScale = CGFloat(target.rows) / CGFloat(max(Int(measuredSize.rows), 1))
                let nextPixelSize = CGSize(
                    width: max((currentWidth * widthScale).rounded(), 1), height: max((currentHeight * heightScale).rounded(), 1))
                guard nextPixelSize != lastSyncedPixelSize else { break }
                ghostty_session_set_size(session, UInt32(nextPixelSize.width), UInt32(nextPixelSize.height))
                lastSyncedPixelSize = nextPixelSize
                changed = true
                ghostty_session_refresh(session)
                GhosttyMobileAppService.shared.tick()
            }
            return changed
        }

        @discardableResult private func sendScroll(horizontal: CGFloat, vertical: CGFloat, mods: ghostty_input_scroll_mods_t = 0) -> Bool {
            guard let session else { return false }
            let surface = ghostty_session_surface(session)
            ghosttyRemoteTerminalTrace(
                "scroll horizontal=\(String(format: "%.1f", horizontal)) vertical=\(String(format: "%.1f", vertical)) mods=\(mods)")
            ghostty_surface_mouse_scroll(surface, Double(horizontal), Double(vertical), mods)
            requestSurfaceRefresh()
            return true
        }

        @discardableResult func debugSendScrollForTesting(
            horizontal: CGFloat, vertical: CGFloat, location: CGPoint? = nil, hasPreciseDeltas: Bool = true,
            momentumState: UIGestureRecognizer.State = .changed
        ) -> Bool {
            if let location { _ = sendMousePosition(at: location) }
            applyHistorySeedIfNeededBeforeScroll()
            return sendScroll(
                horizontal: horizontal, vertical: -vertical,
                mods: Self.makeScrollMods(hasPreciseDeltas: hasPreciseDeltas, momentumState: momentumState))
        }

        private func requestSurfaceRefresh() {
            guard let session else { return }
            ghostty_session_refresh(session)
            GhosttyMobileAppService.shared.tick()
            setNeedsDisplay()
            layer.setNeedsDisplay()
            schedulePostRefreshEmission()
        }

        private func scheduleKeyboardVisibilityRefresh() {
            for delayMS in [0, 120, 320] {
                Task { @MainActor [weak self] in
                    if delayMS == 0 { await Task.yield() } else { try? await Task.sleep(for: .milliseconds(delayMS)) }
                    guard let self else { return }
                    self.syncSessionState()
                    self.requestSurfaceRefresh()
                }
            }
        }

        private func schedulePostRefreshEmission() {
            guard !postRefreshEmissionScheduled else { return }
            postRefreshEmissionScheduled = true
            Task { @MainActor [weak self] in
                await Task.yield()
                guard let self else { return }
                self.postRefreshEmissionScheduled = false
                self.performRenderedTextEmissionPass()
            }
        }

        private func scheduleScrollSettledEmissions() {
            scrollSettledEmissionGeneration &+= 1
            let generation = scrollSettledEmissionGeneration
            cancelScrollSettledEmissionTasks()
            for delay in [Duration.milliseconds(60), .milliseconds(180), .milliseconds(320)] {
                let task = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: delay)
                    guard let self else { return }
                    guard !Task.isCancelled, self.scrollSettledEmissionGeneration == generation else { return }
                    self.performRenderedTextEmissionPass()
                }
                scrollSettledEmissionTasks.append(task)
            }
        }

        private func cancelScrollSettledEmissionTasks() {
            scrollSettledEmissionTasks.forEach { $0.cancel() }
            scrollSettledEmissionTasks.removeAll(keepingCapacity: false)
        }

        private func performRenderedTextEmissionPass() {
            GhosttyMobileAppService.shared.tick()
            emitRenderedTextIfNeeded()
            reportInputReadinessIfNeeded()
        }

        private func syncFirstResponder() {
            guard window != nil else { return }
            if !acceptsTerminalInput, isFirstResponder { resignFirstResponder() }
        }

        private func requestFirstResponderIfNeeded() {
            guard acceptsTerminalInput, window != nil, !isFirstResponder, !firstResponderRequestScheduled else { return }
            firstResponderRequestScheduled = true
            Task { @MainActor [weak self] in
                await Task.yield()
                guard let self else { return }
                self.firstResponderRequestScheduled = false
                guard self.acceptsTerminalInput, self.window != nil, !self.isFirstResponder else {
                    self.reportInputReadinessIfNeeded()
                    return
                }
                _ = self.becomeFirstResponder()
            }
        }

        private var isInputSurfaceReady: Bool { acceptsTerminalInput && session != nil && window != nil }
        private var canProcessKeyboardInput: Bool { acceptsTerminalInput && isFirstResponder && session != nil && window != nil }

        private func sendMousePosition(at point: CGPoint, mods: ghostty_input_mods_e = GHOSTTY_MODS_NONE) -> Bool {
            guard let session else { return false }
            let surface = ghostty_session_surface(session)
            let x = max(0, min(point.x, bounds.width))
            let y = max(0, min(Self.ghosttyMouseY(point.y, boundsHeight: bounds.height), bounds.height))
            ghostty_surface_mouse_pos(surface, Double(x), Double(y), mods)
            return true
        }

        private func reportInputReadinessIfNeeded() {
            let isReady = isInputSurfaceReady
            guard lastReportedInputReadiness != isReady else { return }
            lastReportedInputReadiness = isReady
            ghosttyRemoteTerminalTrace("input_readiness value=\(isReady ? 1 : 0)")
            onInputReadinessChanged?(isReady)
        }

        private func viewportSnapshot(for snapshot: GhosttyTerminalSnapshot, session: ghostty_session_t) -> GhosttyTerminalSnapshot {
            let localSize = ghostty_session_size(session)
            let viewport = GhosttyRemoteTerminalViewport.reportedSize(
                rawColumns: Int(localSize.columns), rawRows: Int(localSize.rows), bounds: bounds, idiom: terminalUserInterfaceIdiom)
            guard viewport.columns > 0, viewport.rows > 0 else { return snapshot }
            return GhosttyTerminalSnapshotViewport.crop(snapshot, columns: viewport.columns, rows: viewport.rows, horizontalAlignment: .leading)
        }

        static func makeScrollMods(hasPreciseDeltas: Bool, momentumState: UIGestureRecognizer.State) -> ghostty_input_scroll_mods_t {
            var mods: Int32 = hasPreciseDeltas ? 0b0000_0001 : 0
            mods |= Int32(momentumRawValue(for: momentumState)) << 1
            return ghostty_input_scroll_mods_t(mods)
        }

        private static func momentumRawValue(for state: UIGestureRecognizer.State) -> UInt8 {
            switch state {
            case .began: UInt8(GHOSTTY_MOUSE_MOMENTUM_BEGAN.rawValue)
            case .changed: UInt8(GHOSTTY_MOUSE_MOMENTUM_CHANGED.rawValue)
            case .ended: UInt8(GHOSTTY_MOUSE_MOMENTUM_ENDED.rawValue)
            case .cancelled, .failed: UInt8(GHOSTTY_MOUSE_MOMENTUM_CANCELLED.rawValue)
            case .possible: UInt8(GHOSTTY_MOUSE_MOMENTUM_MAY_BEGIN.rawValue)
            @unknown default: UInt8(GHOSTTY_MOUSE_MOMENTUM_NONE.rawValue)
            }
        }

        private static func ghosttyMouseY(_ localY: CGFloat, boundsHeight: CGFloat) -> CGFloat { boundsHeight - localY }

        private var scaleFactor: Double { Double(window?.screen.scale ?? UIScreen.main.scale) }
        private var terminalUserInterfaceIdiom: UIUserInterfaceIdiom { userInterfaceIdiomOverrideForTesting ?? traitCollection.userInterfaceIdiom }
        private var activePixelSize: CGSize { lastSyncedPixelSize == .zero ? currentPixelSize : lastSyncedPixelSize }
        private var currentPixelSize: CGSize {
            let insetBounds = bounds.inset(by: Self.contentInsets)
            return CGSize(width: max(insetBounds.width * scaleFactor, 1), height: max(insetBounds.height * scaleFactor, 1))
        }

        private func notifyViewportSizeIfChanged() {
            guard let session else { return }
            let size = ghostty_session_size(session)
            guard size.columns > 0, size.rows > 0 else { return }
            let resolved = GhosttyRemoteTerminalViewport.reportedSize(
                rawColumns: Int(size.columns), rawRows: Int(size.rows), bounds: bounds, idiom: terminalUserInterfaceIdiom)
            guard lastReportedViewportSize?.columns != resolved.columns || lastReportedViewportSize?.rows != resolved.rows else { return }
            lastReportedViewportSize = resolved
            ghosttyRemoteTerminalTrace("viewport_callback columns=\(size.columns) rows=\(size.rows)")
            onViewportSizeChanged?(resolved.columns, resolved.rows)
        }

        // Unit tests may inspect an idle local surface directly, but live owner render
        // dumps must not export the iOS surface after output churn.
        func capturedSnapshotForTesting() -> GhosttyTerminalSnapshot? {
            guard let session else { return nil }
            return exportedSnapshot(from: session)
        }

        var inputAssistantIsSuppressedForTesting: Bool {
            inputAssistantItem.leadingBarButtonGroups.isEmpty && inputAssistantItem.trailingBarButtonGroups.isEmpty
                && inputAssistantItem.allowsHidingShortcuts
        }

        var accessoryToolbarButtonAccessibilityLabelsForTesting: (scrollable: [String], pinned: [String]) {
            terminalAccessoryView.buttonAccessibilityLabelsForTesting
        }

        func accessoryToolbarLayoutFramesForTesting(width: CGFloat, userInterfaceIdiom: UIUserInterfaceIdiom = UIDevice.current.userInterfaceIdiom)
            -> (scrollView: CGRect, joystickButton: CGRect, keyboardButton: CGRect)
        { terminalAccessoryView.layoutFramesForTesting(width: width, userInterfaceIdiom: userInterfaceIdiom) }

        func accessoryToolbarButtonWidthsForTesting(width: CGFloat, userInterfaceIdiom: UIUserInterfaceIdiom = UIDevice.current.userInterfaceIdiom)
            -> (scrollable: [CGFloat], pinned: [CGFloat])
        { terminalAccessoryView.buttonWidthsForTesting(width: width, userInterfaceIdiom: userInterfaceIdiom) }

        func accessoryToolbarJoystickDirectionForTesting(point: CGPoint, bounds: CGRect) -> String? {
            DirectionalPadButton.direction(for: point, in: bounds)
        }

        func accessoryToolbarJoystickAcceptsReleaseForTesting(point: CGPoint, bounds: CGRect) -> Bool {
            DirectionalPadButton.acceptsRelease(at: point, in: bounds)
        }

        func accessoryToolbarJoystickAcceptsActivationForTesting(point: CGPoint, bounds: CGRect) -> Bool {
            DirectionalPadButton.acceptsActivation(at: point, in: bounds)
        }

        private func exportedSnapshot(from session: ghostty_session_t) -> GhosttyTerminalSnapshot? {
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

        private func updateRenderedTextSource(
            ownerEpoch: GhosttyRemoteTerminalOwnerEpoch?, endedRender: GhosttyRemoteTerminalEndedRender?, fallbackText: String,
            session: ghostty_session_t?
        ) {
            guard onRenderedTextChanged != nil else {
                currentRenderedText = ""
                return
            }
            guard isTerminalVisible else {
                currentRenderedText = ""
                return
            }
            if let ownerEpoch, activeOwnerEpoch?.id == ownerEpoch.id, !currentRenderedText.isEmpty { return }
            if let endedRender, activeEndedRender?.id == endedRender.id, !currentRenderedText.isEmpty { return }
            if let endedRender {
                currentRenderedText = GhosttyTerminalSnapshotLayout.plainText(
                    for: session.map { viewportSnapshot(for: endedRender.snapshot, session: $0) } ?? endedRender.snapshot)
                return
            }
            if let ownerEpoch, let bootstrapSnapshot = ownerEpoch.bootstrapSnapshot {
                let snapshot = session.map { viewportSnapshot(for: bootstrapSnapshot, session: $0) } ?? bootstrapSnapshot
                currentRenderedText = GhosttyTerminalSnapshotLayout.plainText(for: snapshot)
                return
            }
            currentRenderedText = fallbackText
        }

        private func applyOwnerEpoch(_ ownerEpoch: GhosttyRemoteTerminalOwnerEpoch, into session: ghostty_session_t) {
            let previousOwnerEpoch = activeOwnerEpoch
            activeOwnerEpoch = ownerEpoch
            activeEndedRender = nil
            let bootstrapSnapshot = ownerEpoch.bootstrapSnapshot.map { viewportSnapshot(for: $0, session: session) }
            let isFirstOwnerEpoch = lastAppliedOwnerEpochID == nil
            let preservesExistingRenderedHistory =
                ownerEpoch.pendingOutputs.isEmpty && ownerEpoch.historySeed == nil && bootstrapSnapshot != nil
                && previousOwnerEpoch?.bootstrapSnapshot == ownerEpoch.bootstrapSnapshot && lastAppliedOwnerEpochID != nil
            if preservesExistingRenderedHistory {
                updateRenderedTextSource(ownerEpoch: ownerEpoch, endedRender: nil, fallbackText: fallbackLabel.text ?? "", session: session)
                return
            }
            if lastAppliedOwnerEpochID != ownerEpoch.id {
                ownerBootstrapStartedAt = Date()
                ownerBootstrapEpochID = ownerEpoch.id
                logPerformanceEvent(
                    sessionID: ownerEpoch.sessionID, name: "local_owner_bootstrap_begin",
                    attributes: ["epoch_id": ownerEpoch.id, "snapshot": ownerEpoch.bootstrapSnapshot == nil ? "0" : "1"])
                resetSessionForFreshRender(into: session, preserveRenderedText: false)
                lastAppliedOwnerEpochID = ownerEpoch.id
                lastAppliedHistorySeedID = nil
                appliedOutputBatchIDs.removeAll()
                lastAppliedEndedRenderID = nil
                if let bootstrapSnapshot {
                    replay(snapshot: bootstrapSnapshot, into: session)
                    lastStaticRenderPixelSize = activePixelSize
                }
                currentRenderedText =
                    exportedSnapshot(from: session).map(GhosttyTerminalSnapshotLayout.plainText) ?? bootstrapSnapshot.map(
                        GhosttyTerminalSnapshotLayout.plainText) ?? ""
                if ownerBootstrapEpochID == ownerEpoch.id, let ownerBootstrapStartedAt {
                    logPerformanceEvent(
                        sessionID: ownerEpoch.sessionID, name: "local_owner_bootstrap_end",
                        elapsedMS: max(Int(Date().timeIntervalSince(ownerBootstrapStartedAt) * 1000), 0),
                        attributes: ["epoch_id": ownerEpoch.id, "snapshot": ownerEpoch.bootstrapSnapshot == nil ? "0" : "1"])
                    self.ownerBootstrapStartedAt = nil
                    self.ownerBootstrapEpochID = nil
                }
            }
            let appliedFullHistorySeed = applyHistorySeedIfNeeded(for: ownerEpoch, into: session, trigger: "bootstrap", preserveRenderedText: false)
            var appliedOutput = appliedFullHistorySeed
            for pendingOutput in ownerEpoch.pendingOutputs where !appliedOutputBatchIDs.contains(pendingOutput.id) {
                if isFirstOwnerEpoch, ownerEpoch.id.hasPrefix("owner|"), bootstrapSnapshot != nil {
                    appliedOutputBatchIDs.insert(pendingOutput.id)
                    onOutputBatchApplied?(pendingOutput.id)
                    continue
                }
                applyOutput(pendingOutput.data, into: session)
                appliedOutput = true
                appliedOutputBatchIDs.insert(pendingOutput.id)
                onOutputBatchApplied?(pendingOutput.id)
            }
            if !appliedOutput {
                updateRenderedTextSource(ownerEpoch: ownerEpoch, endedRender: nil, fallbackText: fallbackLabel.text ?? "", session: session)
            }
        }

        private func applyEndedRender(_ endedRender: GhosttyRemoteTerminalEndedRender, into session: ghostty_session_t) {
            activeOwnerEpoch = nil
            activeEndedRender = endedRender
            let pixelSize = activePixelSize
            if lastAppliedEndedRenderID != endedRender.id || lastStaticRenderPixelSize != pixelSize {
                resetSessionForFreshRender(into: session, preserveRenderedText: false)
                replay(snapshot: viewportSnapshot(for: endedRender.snapshot, session: session), into: session)
                lastAppliedEndedRenderID = endedRender.id
                lastAppliedOwnerEpochID = nil
                lastAppliedHistorySeedID = nil
                appliedOutputBatchIDs.removeAll()
                lastStaticRenderPixelSize = pixelSize
            }
            updateRenderedTextSource(ownerEpoch: nil, endedRender: endedRender, fallbackText: fallbackLabel.text ?? "", session: session)
        }

        @discardableResult private func applyHistorySeedIfNeededBeforeScroll() -> Bool {
            guard let session, let activeOwnerEpoch else { return false }
            return applyHistorySeedIfNeeded(for: activeOwnerEpoch, into: session, trigger: "scroll", preserveRenderedText: true)
        }

        @discardableResult private func applyHistorySeedIfNeeded(
            for ownerEpoch: GhosttyRemoteTerminalOwnerEpoch, into session: ghostty_session_t, trigger: String, preserveRenderedText: Bool
        ) -> Bool {
            guard let historySeed = ownerEpoch.historySeed, !historySeed.data.isEmpty else { return false }
            guard lastAppliedHistorySeedID != historySeed.id else { return false }
            let preparedHistorySeed = historySeed.data
            logPerformanceEvent(
                sessionID: ownerEpoch.sessionID, name: "owner_history_seed_apply_begin", count: preparedHistorySeed.count,
                attributes: ["epoch_id": ownerEpoch.id, "history_seed_id": historySeed.id, "trigger": trigger])
            let startedAt = Date()
            resetSessionForFreshRender(into: session, preserveRenderedText: preserveRenderedText)
            applyOutput(preparedHistorySeed, into: session)
            lastAppliedHistorySeedID = historySeed.id
            onHistorySeedApplied?(historySeed.id)
            logPerformanceEvent(
                sessionID: ownerEpoch.sessionID, name: "owner_history_seed_apply_end",
                elapsedMS: max(Int(Date().timeIntervalSince(startedAt) * 1000), 0), count: preparedHistorySeed.count,
                attributes: ["epoch_id": ownerEpoch.id, "history_seed_id": historySeed.id, "trigger": trigger])
            return true
        }

        private func strippedPromptEOLMarkArtifacts(from outputData: Data) -> Data {
            var sanitized = Data()
            var searchStart = outputData.startIndex
            while searchStart < outputData.endIndex, let startRange = outputData[searchStart...].range(of: Self.promptEOLMarkStartSequence) {
                sanitized.append(outputData[searchStart..<startRange.lowerBound])
                guard let endRange = outputData[startRange.lowerBound...].range(of: Self.promptEOLMarkEndSequence) else {
                    sanitized.append(outputData[startRange.lowerBound...])
                    return sanitized
                }
                searchStart = endRange.upperBound
            }
            if searchStart < outputData.endIndex { sanitized.append(outputData[searchStart...]) }
            return sanitized
        }

        private func resetSessionForFreshRender(into session: ghostty_session_t, preserveRenderedText: Bool) {
            ghosttyRemoteTerminalTrace("reset_session_for_fresh_render")
            Self.sessionResetSequence.withUnsafeBytes { rawBuffer in
                guard let baseAddress = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return }
                ghostty_session_process_output(session, baseAddress, UInt(Self.sessionResetSequence.count))
            }
            if !preserveRenderedText {
                currentRenderedText = ""
                lastEmittedRenderedText = nil
            }
            lastStaticRenderPixelSize = .zero
        }

        private func renderableOutputData(from outputData: Data) -> Data { normalizeBareLineFeeds(strippedPromptEOLMarkArtifacts(from: outputData)) }

        private func normalizeBareLineFeeds(_ data: Data) -> Data {
            guard data.contains(0x0A) else { return data }
            var normalized = Data()
            normalized.reserveCapacity(data.count)
            var previousByte: UInt8?
            for byte in data {
                if byte == 0x0A, previousByte != 0x0D { normalized.append(0x0D) }
                normalized.append(byte)
                previousByte = byte
            }
            return normalized
        }

        private func emitRenderedTextIfNeeded() {
            guard let onRenderedTextChanged else {
                lastEmittedRenderedText = nil
                return
            }
            guard currentRenderedText != lastEmittedRenderedText else { return }
            lastEmittedRenderedText = currentRenderedText
            if let activeOwnerEpoch, firstNonBlankOwnerEpochID != activeOwnerEpoch.id,
                currentRenderedText.contains(where: { !$0.isWhitespace && !$0.isNewline })
            {
                firstNonBlankOwnerEpochID = activeOwnerEpoch.id
                logPerformanceEvent(
                    sessionID: activeOwnerEpoch.sessionID, name: "owner_first_nonblank_render", attributes: ["epoch_id": activeOwnerEpoch.id])
            }
            onRenderedTextChanged(currentRenderedText)
        }

        private func logPerformanceEvent(
            sessionID: String, name: String, elapsedMS: Int? = nil, count: Int? = nil, attributes: [String: String] = [:]
        ) {
            SpacesMobileTerminalPerformanceLogger.emit(
                .init(sessionID: sessionID, source: "ios-ghostty", name: name, elapsedMS: elapsedMS, count: count, attributes: attributes))
        }
    }
#endif
