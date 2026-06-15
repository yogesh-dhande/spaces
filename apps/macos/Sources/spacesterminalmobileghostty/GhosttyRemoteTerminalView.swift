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
        private static let directPanSensitivity: CGFloat = 0.5
        private static let momentumSensitivity: CGFloat = 0.35
        private static let minimumMomentumVelocity: CGFloat = 8
        private static let maximumMomentumVelocity: CGFloat = 6_000
        private static let maximumMomentumFrameDelta: CGFloat = 120

        static func scrollDelta(forPanDelta panDelta: CGPoint, scaleFactor: Double) -> CGPoint {
            let scale = CGFloat(scaleFactor) * directPanSensitivity
            return CGPoint(x: -panDelta.x * scale, y: panDelta.y * scale)
        }

        static func clampedMomentumVelocity(_ velocity: CGPoint) -> CGPoint {
            CGPoint(
                x: min(max(velocity.x, -maximumMomentumVelocity), maximumMomentumVelocity),
                y: min(max(velocity.y, -maximumMomentumVelocity), maximumMomentumVelocity))
        }

        static func momentumFrameDelta(velocity: CGPoint, elapsed: TimeInterval, scaleFactor: Double) -> CGPoint {
            let elapsed = max(0, elapsed)
            let scale = CGFloat(scaleFactor) * momentumSensitivity
            return CGPoint(
                x: min(max(-velocity.x * elapsed * scale, -maximumMomentumFrameDelta), maximumMomentumFrameDelta),
                y: min(max(velocity.y * elapsed * scale, -maximumMomentumFrameDelta), maximumMomentumFrameDelta))
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
        public let onSendScroll: @MainActor (Double, Double, Int32) -> Void
        public let onOpenLink: @MainActor (String) -> Void

        public init(
            ownerEpoch: GhosttyRemoteTerminalOwnerEpoch? = nil, endedRender: GhosttyRemoteTerminalEndedRender? = nil, fallbackText: String,
            isVisible: Bool, acceptsInput: Bool, isBusy: Bool, onInputReadinessChanged: @escaping @MainActor (Bool) -> Void = { _ in },
            onScrollGestureApplied: (@MainActor () -> Void)? = nil, onRenderedTextChanged: (@MainActor (String) -> Void)? = nil,
            onViewportSizeChanged: @escaping @MainActor (Int, Int) -> Void, onSendText: @escaping @MainActor (String) -> Void,
            onSendKey: @escaping @MainActor (String) -> Void, onSendScroll: @escaping @MainActor (Double, Double, Int32) -> Void = { _, _, _ in },
            onOpenLink: @escaping @MainActor (String) -> Void = { _ in }
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
            self.onOpenLink = onOpenLink
        }

        public func makeUIView(context: Context) -> GhosttyRemoteTerminalHostView { GhosttyRemoteTerminalHostView() }

        public func updateUIView(_ hostView: GhosttyRemoteTerminalHostView, context: Context) {
            hostView.onInputReadinessChanged = { ready in _ = Task { @MainActor in onInputReadinessChanged(ready) } }
            hostView.onScrollGestureApplied = onScrollGestureApplied.map { callback in { _ = Task { @MainActor in callback() } } }
            hostView.onViewportSizeChanged = { columns, rows in _ = Task { @MainActor in onViewportSizeChanged(columns, rows) } }
            hostView.onSendText = { text in _ = Task { @MainActor in onSendText(text) } }
            hostView.onSendKey = { key in _ = Task { @MainActor in onSendKey(key) } }
            hostView.onSendScroll = { horizontal, vertical, scrollMods in _ = Task { @MainActor in onSendScroll(horizontal, vertical, scrollMods) } }
            hostView.onOpenLink = { link in _ = Task { @MainActor in onOpenLink(link) } }
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

        private struct RetiredMirror: @unchecked Sendable {
            let mirror: ghostty_mirror_t
            let retainedHostView: UIView
        }

        private enum AccessoryModifier: String, CaseIterable {
            case control = "ctrl"
            case command = "cmd"
            case option = "opt"

            var accessibilityLabel: String {
                switch self {
                case .control: return "Control"
                case .command: return "Command"
                case .option: return "Option"
                }
            }
        }

        enum TapActivationResult: String, Equatable {
            case ignored
            case openedLink
            case focused
        }

        struct AccessoryToolbarButtonLabels: Equatable {
            let scrollable: [String]
            let pinned: [String]
        }

        struct AccessoryToolbarLayoutFrames: Equatable {
            let scrollView: CGRect
            let scrollContentSize: CGSize
            let joystickButton: CGRect
            let keyboardButton: CGRect
        }

        struct AccessoryToolbarButtonWidths: Equatable {
            let scrollable: [CGFloat]
            let pinned: [CGFloat]
        }

        private static let defaultFontSize: CGFloat = 11
        private static let contentInsets = GhosttyRemoteTerminalViewport.contentInsets
        private static let accessoryToolbarHeight: CGFloat = 46

        nonisolated(unsafe) static var sessionFreeHandlerForTesting: @Sendable (UnsafeRawPointer?) -> Void = { _ in }
        nonisolated(unsafe) static var nativeMirrorEnabledForTesting = true
        nonisolated(unsafe) private static var retiredMirrors: [RetiredMirror] = []

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
        private var snapshotScrollRemainderRows: CGFloat = 0
        private var lastReportedViewportSize: (columns: Int, rows: Int)?
        private var lastRenderedText = ""
        private var lastReportedInputReadiness = false
        private var emittedHostRenderEvents = Set<String>()
        private var mirrorCreationTask: Task<Void, Never>?
        private var isTerminalVisible = true
        private var fallbackText = ""
        private var lastScrollTranslation = CGPoint.zero
        private var didScrollDuringCurrentPan = false
        private var scrollInteractionDepth = 0
        private var deferredViewportSizeReport = false
        private var momentumDisplayLink: CADisplayLink?
        private var momentumVelocity = CGPoint.zero
        private var lastMomentumTimestamp: CFTimeInterval = 0
        private var pendingAccessoryModifiers: Set<AccessoryModifier> = []
        private var suppressesSoftwareKeyboard = false
        private var tapLinkProbeDepth = 0
        private var openedLinkDuringTapProbe = false
        private var surfaceViewportSizeOverrideForTesting: (columns: Int, rows: Int)?
        var userInterfaceIdiomOverrideForTesting: UIUserInterfaceIdiom?
        private var keyboardOccludedHeightOverrideForTesting: CGFloat?
        private let suppressedSoftwareKeyboardInputView = UIView(frame: .zero)
        private lazy var activateInputRecognizer = UITapGestureRecognizer(target: self, action: #selector(handleTapToActivateInput(_:)))
        private lazy var scrollPanRecognizer = UIPanGestureRecognizer(target: self, action: #selector(handleScrollPan))
        private lazy var terminalAccessoryView = TerminalAccessoryToolbar(
            onText: { [weak self] text in self?.sendAccessoryText(text) }, onKey: { [weak self] key in self?.sendAccessoryKey(key) },
            onModifier: { [weak self] modifier in self?.toggleAccessoryModifier(modifier) },
            onKeyboardToggle: { [weak self] in self?.toggleAccessorySoftwareKeyboard() })
        var debugTapLinkHandlerForTesting: ((CGPoint) -> Bool)?

        public private(set) var acceptsTerminalInput = false
        public var onInputReadinessChanged: ((Bool) -> Void)?
        public var onScrollGestureApplied: (() -> Void)?
        public var onViewportSizeChanged: ((Int, Int) -> Void)?
        public var onSendText: ((String) -> Void)?
        public var onSendKey: ((String) -> Void)?
        public var onSendScroll: ((Double, Double, Int32) -> Void)?
        public var onOpenLink: ((String) -> Void)?
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
        public override var inputAccessoryView: UIView? { acceptsTerminalInput ? terminalAccessoryView : nil }

        var inputAssistantIsSuppressedForTesting: Bool {
            inputAssistantItem.leadingBarButtonGroups.isEmpty && inputAssistantItem.trailingBarButtonGroups.isEmpty
        }

        var accessoryToolbarButtonAccessibilityLabelsForTesting: AccessoryToolbarButtonLabels {
            terminalAccessoryView.buttonAccessibilityLabelsForTesting
        }

        func accessoryToolbarLayoutFramesForTesting(width: CGFloat, userInterfaceIdiom: UIUserInterfaceIdiom) -> AccessoryToolbarLayoutFrames {
            terminalAccessoryView.layoutFramesForTesting(width: width, userInterfaceIdiom: userInterfaceIdiom)
        }

        func accessoryToolbarButtonWidthsForTesting(width: CGFloat, userInterfaceIdiom: UIUserInterfaceIdiom) -> AccessoryToolbarButtonWidths {
            terminalAccessoryView.buttonWidthsForTesting(width: width, userInterfaceIdiom: userInterfaceIdiom)
        }

        func accessoryToolbarJoystickDirectionForTesting(point: CGPoint, bounds: CGRect) -> String? {
            DirectionalPadButton.direction(for: point, in: bounds)
        }

        func accessoryToolbarJoystickAcceptsReleaseForTesting(point: CGPoint, bounds: CGRect) -> Bool {
            DirectionalPadButton.acceptsRelease(at: point, in: bounds)
        }

        func accessoryToolbarJoystickAcceptsActivationForTesting(point: CGPoint, bounds: CGRect) -> Bool {
            DirectionalPadButton.acceptsActivation(at: point, in: bounds)
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
                if let mirror { retireMirror(mirror) }
            }
        }

        public override func didMoveToWindow() {
            super.didMoveToWindow()
            if window == nil {
                prepareForDismantle()
            } else {
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
            mirrorCreationTask?.cancel()
            mirrorCreationTask = nil
            latestRenderFrame = nil
            latestSnapshot = nil
            currentRenderedSnapshot = nil
            lastSurfaceGeometry = nil
            if let mirror {
                if let surface = ghostty_mirror_surface(mirror) { GhosttyMobileAppService.shared.unregisterActionHandler(for: surface) }
                retireMirror(mirror)
                self.mirror = nil
            }
            reportInputReadinessIfNeeded(force: true)
            if hadRenderedSnapshot {
                let handler = Self.sessionFreeHandlerForTesting
                _ = Task.detached(priority: .utility) { handler(nil) }
            }
        }

        private func retireMirror(_ mirror: ghostty_mirror_t) {
            if let surface = ghostty_mirror_surface(mirror) {
                GhosttyMobileAppService.shared.unregisterActionHandler(for: surface)
                ghostty_surface_set_focus(surface, false)
                ghostty_surface_set_occlusion(surface, false)
            }
            // GhosttyKit can block indefinitely while freeing iOS mirror
            // surfaces because free rebinds the renderer host during teardown.
            // Retiring keeps navigation responsive and lets process exit reclaim
            // the native mirror resources.
            Self.retiredMirrors.append(RetiredMirror(mirror: mirror, retainedHostView: surfaceHostView))
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
            if accepts {
                terminalAccessoryView.isKeyboardVisible = !suppressesSoftwareKeyboard
                scheduleFirstResponderRequest()
            } else {
                clearAccessoryModifiers()
                resignFirstResponder()
            }
            reloadInputViews()
            reportInputReadinessIfNeeded(force: true)
        }

        public func setSoftwareKeyboardVisible(_ visible: Bool) {
            guard acceptsTerminalInput else { return }
            let shouldSuppress = !visible
            terminalAccessoryView.isKeyboardVisible = visible
            guard suppressesSoftwareKeyboard != shouldSuppress else { return }
            suppressesSoftwareKeyboard = shouldSuppress
            if isFirstResponder { reloadInputViews() } else { becomeFirstResponder() }
            scheduleKeyboardViewportRefresh()
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
                snapshotScrollRemainderRows = 0
                lastRenderKey = nextKey
            }
            latestSnapshot = nextSnapshot
            renderLatestSnapshot()
            reportInputReadinessIfNeeded()
        }

        public override func layoutSubviews() {
            super.layoutSubviews()
            reportViewportSizeIfNeeded()
            renderLatestSnapshot()
        }

        public override func draw(_ rect: CGRect) {
            UIColor.black.setFill()
            UIRectFill(bounds)
        }

        public func insertText(_ text: String) {
            guard acceptsTerminalInput, !text.isEmpty else { return }
            if sendPendingAccessoryModifiersIfNeeded(for: text) { return }
            if text == "\n" || text == "\r" { onSendKey?("enter") } else { onSendText?(text) }
        }

        public func deleteBackward() { sendAccessoryKey("backspace") }

        public override var keyCommands: [UIKeyCommand]? {
            [
                UIKeyCommand(input: UIKeyCommand.inputUpArrow, modifierFlags: [], action: #selector(sendArrowUp)),
                UIKeyCommand(input: UIKeyCommand.inputDownArrow, modifierFlags: [], action: #selector(sendArrowDown)),
                UIKeyCommand(input: UIKeyCommand.inputLeftArrow, modifierFlags: [], action: #selector(sendArrowLeft)),
                UIKeyCommand(input: UIKeyCommand.inputRightArrow, modifierFlags: [], action: #selector(sendArrowRight)),
                UIKeyCommand(input: UIKeyCommand.inputLeftArrow, modifierFlags: .command, action: #selector(sendCommandArrowLeft)),
                UIKeyCommand(input: UIKeyCommand.inputRightArrow, modifierFlags: .command, action: #selector(sendCommandArrowRight)),
                UIKeyCommand(input: UIKeyCommand.inputLeftArrow, modifierFlags: .alternate, action: #selector(sendOptionArrowLeft)),
                UIKeyCommand(input: UIKeyCommand.inputRightArrow, modifierFlags: .alternate, action: #selector(sendOptionArrowRight)),
                UIKeyCommand(input: "k", modifierFlags: .command, action: #selector(sendCommandK)),
                UIKeyCommand(input: "\t", modifierFlags: [], action: #selector(sendTab)),
                UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(sendEscape)),
            ]
        }

        public func capturedSnapshotForTesting() -> GhosttyTerminalSnapshot? { currentRenderedSnapshot }
        public var hasActiveSessionForTesting: Bool { currentRenderedSnapshot != nil }
        public var hasMirrorSurfaceForTesting: Bool { mirrorSurface() != nil }
        public static var retiredMirrorCountForTesting: Int { retiredMirrors.count }
        public var hasRetainedSessionStandardInputWriteDescriptorForTesting: Bool { false }

        @discardableResult public func debugSendScrollForTesting(
            horizontal: CGFloat, vertical: CGFloat, location: CGPoint? = nil, hasPreciseDeltas: Bool = false,
            momentumState: UIGestureRecognizer.State = .changed
        ) -> Bool {
            sendScroll(
                horizontal: horizontal, vertical: vertical,
                scrollMods: Self.makeScrollMods(hasPreciseDeltas: hasPreciseDeltas, momentumState: momentumState))
        }

        public static func makeScrollMods(hasPreciseDeltas: Bool, momentumState: UIGestureRecognizer.State) -> Int32 {
            var mods: Int32 = 0
            if hasPreciseDeltas { mods |= 0b0000_0001 }
            switch momentumState {
            case .possible: mods |= 6 << 1
            case .ended: mods |= 4 << 1
            case .cancelled, .failed: mods |= 5 << 1
            default: mods |= 3 << 1
            }
            return mods
        }

        @objc private func handleTapToActivateInput(_ recognizer: UITapGestureRecognizer) {
            _ = handleTapToActivateInput(at: recognizer.location(in: self))
        }

        @discardableResult private func handleTapToActivateInput(at location: CGPoint) -> TapActivationResult {
            if openTerminalLink(at: location) { return .openedLink }
            guard acceptsTerminalInput else { return .ignored }
            becomeFirstResponder()
            return .focused
        }

        @objc private func handleScrollPan(_ recognizer: UIPanGestureRecognizer) {
            switch recognizer.state {
            case .began:
                didScrollDuringCurrentPan = false
                lastScrollTranslation = recognizer.translation(in: self)
                stopMomentum()
                beginScrollInteraction()
            case .changed:
                let translation = recognizer.translation(in: self)
                let delta = CGPoint(x: translation.x - lastScrollTranslation.x, y: translation.y - lastScrollTranslation.y)
                lastScrollTranslation = translation
                let scrollDelta = GhosttyRemoteTerminalScrollMapper.scrollDelta(forPanDelta: delta, scaleFactor: Double(window?.screen.scale ?? 1))
                let scrollMods = Self.makeScrollMods(hasPreciseDeltas: true, momentumState: .changed)
                if sendScroll(horizontal: scrollDelta.x, vertical: scrollDelta.y, scrollMods: scrollMods) { didScrollDuringCurrentPan = true }
            case .ended:
                if didScrollDuringCurrentPan {
                    _ = sendScroll(horizontal: 0, vertical: 0, scrollMods: Self.makeScrollMods(hasPreciseDeltas: true, momentumState: .ended))
                }
                if didScrollDuringCurrentPan { onScrollGestureApplied?() }
                let velocity = GhosttyRemoteTerminalScrollMapper.clampedMomentumVelocity(recognizer.velocity(in: self))
                if GhosttyRemoteTerminalScrollMapper.shouldContinueMomentum(velocity: velocity) {
                    startMomentum(velocity: velocity)
                } else {
                    endScrollInteraction()
                }
            case .cancelled, .failed:
                if didScrollDuringCurrentPan {
                    _ = sendScroll(horizontal: 0, vertical: 0, scrollMods: Self.makeScrollMods(hasPreciseDeltas: true, momentumState: .cancelled))
                }
                if didScrollDuringCurrentPan { onScrollGestureApplied?() }
                stopMomentum()
                endScrollInteraction()
            default: break
            }
        }

        @objc private func handleMomentumFrame(_ displayLink: CADisplayLink) {
            let timestamp = displayLink.timestamp
            let elapsed = lastMomentumTimestamp > 0 ? timestamp - lastMomentumTimestamp : displayLink.duration
            lastMomentumTimestamp = timestamp
            let delta = GhosttyRemoteTerminalScrollMapper.momentumFrameDelta(
                velocity: momentumVelocity, elapsed: elapsed, scaleFactor: Double(window?.screen.scale ?? 1))
            _ = sendScroll(horizontal: delta.x, vertical: delta.y, scrollMods: Self.makeScrollMods(hasPreciseDeltas: true, momentumState: .changed))
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
            let hadMomentum = momentumDisplayLink != nil
            if hadMomentum {
                _ = sendScroll(horizontal: 0, vertical: 0, scrollMods: Self.makeScrollMods(hasPreciseDeltas: true, momentumState: .ended))
            }
            momentumDisplayLink?.invalidate()
            momentumDisplayLink = nil
            momentumVelocity = .zero
            lastMomentumTimestamp = 0
            if hadMomentum { endScrollInteraction() }
        }

        private func beginScrollInteraction() { scrollInteractionDepth += 1 }

        private func endScrollInteraction() {
            guard scrollInteractionDepth > 0 else { return }
            scrollInteractionDepth -= 1
            guard scrollInteractionDepth == 0, deferredViewportSizeReport else { return }
            deferredViewportSizeReport = false
            reportViewportSizeIfNeeded()
        }

        @objc private func sendArrowUp() { sendAccessoryKey("up") }
        @objc private func sendArrowDown() { sendAccessoryKey("down") }
        @objc private func sendArrowLeft() { sendAccessoryKey("left") }
        @objc private func sendArrowRight() { sendAccessoryKey("right") }
        @objc private func sendCommandArrowLeft() { sendAccessoryKey("cmd+left") }
        @objc private func sendCommandArrowRight() { sendAccessoryKey("cmd+right") }
        @objc private func sendOptionArrowLeft() { sendAccessoryKey("opt+left") }
        @objc private func sendOptionArrowRight() { sendAccessoryKey("opt+right") }
        @objc private func sendCommandK() { sendAccessoryKey("cmd+k") }
        @objc private func sendTab() { sendAccessoryKey("tab") }
        @objc private func sendEscape() { sendAccessoryKey("esc") }

        private func scheduleFirstResponderRequest() {
            Task { @MainActor [weak self] in
                await Task.yield()
                guard let self, self.acceptsTerminalInput, self.window != nil else { return }
                self.becomeFirstResponder()
            }
        }

        private func scheduleKeyboardViewportRefresh() {
            for delayMS in [0, 120, 320] {
                Task { @MainActor [weak self] in
                    if delayMS == 0 { await Task.yield() } else { try? await Task.sleep(for: .milliseconds(delayMS)) }
                    guard let self else { return }
                    self.setNeedsLayout()
                    self.layoutIfNeeded()
                    self.reportViewportSizeIfNeeded()
                    self.renderLatestSnapshot()
                }
            }
        }

        private func reportViewportSizeIfNeeded() {
            guard scrollInteractionDepth == 0 else {
                deferredViewportSizeReport = true
                return
            }
            let size = viewportSize()
            guard size.columns > 0, size.rows > 0 else { return }
            guard lastReportedViewportSize?.columns != size.columns || lastReportedViewportSize?.rows != size.rows else { return }
            lastReportedViewportSize = size
            onViewportSizeChanged?(size.columns, size.rows)
        }

        private func reportInputReadinessIfNeeded(force: Bool = false) {
            let hasRenderableSurface = currentRenderedSnapshot != nil && (mirror != nil || !Self.nativeMirrorEnabledForTesting)
            let ready = isTerminalVisible && acceptsTerminalInput && hasRenderableSurface
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
            emitHostRenderEvent("host_view_render_begin", dedupeKey: lastRenderKey)
            scheduleMirrorCreationIfNeeded()
            let window = viewportWindow(for: latestSnapshot)
            let cropped = GhosttyTerminalSnapshotViewport.crop(latestSnapshot, window: window)
            currentRenderedSnapshot = cropped
            emitHostRenderEvent(
                "host_view_snapshot_ready", dedupeKey: lastRenderKey,
                attributes: ["snapshot_columns": "\(cropped.columns)", "snapshot_rows": "\(cropped.rows)"])
            if mirror != nil {
                updateSurfaceGeometry()
                emitHostRenderEvent("host_view_after_geometry", dedupeKey: lastRenderKey)
                applyLatestRenderFrameIfPossible()
            } else {
                setNeedsDisplay()
            }
            emitRenderedTextIfNeeded(force: false)
            reportInputReadinessIfNeeded()
            emitHostRenderEvent("host_view_render_end", dedupeKey: lastRenderKey)
        }

        private func scheduleMirrorCreationIfNeeded() {
            guard mirror == nil, mirrorCreationTask == nil, window != nil else { return }
            let renderBounds = visibleRenderBounds()
            guard renderBounds.width > 0, renderBounds.height > 0 else { return }
            guard Self.nativeMirrorEnabledForTesting else { return }
            emitHostRenderEvent("host_view_mirror_create_scheduled", dedupeKey: lastRenderKey)
            mirrorCreationTask = Task { @MainActor [weak self] in
                await Task.yield()
                guard let self, !Task.isCancelled else { return }
                self.mirrorCreationTask = nil
                self.createMirrorIfNeeded()
                self.renderLatestSnapshot()
            }
        }

        private func createMirrorIfNeeded() {
            guard mirror == nil, window != nil else { return }
            guard Self.nativeMirrorEnabledForTesting else { return }
            do {
                emitHostRenderEvent("host_view_mirror_service_start_begin", dedupeKey: lastRenderKey)
                try GhosttyMobileAppService.shared.startIfNeeded()
                emitHostRenderEvent("host_view_mirror_service_start_end", dedupeKey: lastRenderKey)
                guard let app = GhosttyMobileAppService.shared.app else { throw GhosttyMobileAppServiceError.configuration("ghostty app missing") }
                var host = makeSurfaceHost()
                var config = ghostty_session_config_new()
                config.surface.platform_tag = host.platform_tag
                config.surface.platform = host.platform
                config.surface.scale_factor = host.scale_factor
                config.surface.context = GHOSTTY_SURFACE_CONTEXT_WINDOW
                config.surface.backend = GHOSTTY_SURFACE_IO_BACKEND_HOST_MANAGED
                config.surface.font_size = Float(Self.defaultFontSize)
                config.parked_host = host
                emitHostRenderEvent("host_view_mirror_new_begin", dedupeKey: lastRenderKey)
                mirror = ghostty_mirror_new(app, &host, &config)
                emitHostRenderEvent("host_view_mirror_new_end", dedupeKey: lastRenderKey)
                guard mirror != nil else { throw GhosttyMobileAppServiceError.configuration("ghostty_mirror_new failed") }
                lastSurfaceGeometry = nil
                updateSurfaceGeometry()
                if let surface = mirrorSurface() {
                    GhosttyMobileAppService.shared.registerActionHandler(for: surface) { [weak self] event in self?.handleActionEvent(event) }
                }
                emitHostRenderEvent("host_view_mirror_create_end", dedupeKey: lastRenderKey)
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

        private func handleActionEvent(_ event: GhosttyMobileActionEvent) {
            switch event {
            case .openURL(_, let value):
                if tapLinkProbeDepth > 0 { openedLinkDuringTapProbe = true }
                onOpenLink?(value)
            case .mouseOverLink: return
            }
        }

        private func openTerminalLink(at location: CGPoint) -> Bool {
            if let debugTapLinkHandlerForTesting { return debugTapLinkHandlerForTesting(location) }
            guard let surface = mirrorSurface() else { return false }
            guard !ghostty_surface_mouse_captured(surface) else { return false }
            let position = Self.ghosttyMousePosition(for: location)
            let mods = Self.linkActivationMouseModifiers()
            tapLinkProbeDepth += 1
            openedLinkDuringTapProbe = false
            defer { tapLinkProbeDepth -= 1 }
            ghostty_surface_mouse_pos(surface, position.x, position.y, mods)
            _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, mods)
            _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, mods)
            ghostty_surface_refresh(surface)
            GhosttyMobileAppService.shared.tick()
            let openedLink = openedLinkDuringTapProbe
            openedLinkDuringTapProbe = false
            return openedLink
        }

        private static func ghosttyMousePosition(for location: CGPoint) -> (x: Double, y: Double) {
            (Double(max(location.x, 0)), Double(max(location.y, 0)))
        }

        private static func linkActivationMouseModifiers() -> ghostty_input_mods_e { ghostty_input_mods_e(GHOSTTY_MODS_SUPER.rawValue) }

        private func updateSurfaceGeometry() {
            guard let mirror, let surface = mirrorSurface() else { return }
            let scale = Double(window?.screen.scale ?? UIScreen.main.scale)
            let renderBounds = visibleRenderBounds()
            let width = UInt32(max(Int(floor(renderBounds.width * CGFloat(scale))), 1))
            let height = UInt32(max(Int(floor(renderBounds.height * CGFloat(scale))), 1))
            let geometry = SurfaceGeometry(width: width, height: height, scale: scale)
            guard geometry != lastSurfaceGeometry else { return }
            var host = makeSurfaceHost()
            let geometryKey = "\(lastRenderKey)|\(geometry.width)x\(geometry.height)@\(geometry.scale)"
            emitHostRenderEvent("host_view_geometry_set_host_begin", dedupeKey: geometryKey)
            _ = ghostty_mirror_set_host(mirror, &host)
            emitHostRenderEvent("host_view_geometry_set_host_end", dedupeKey: geometryKey)
            ghostty_surface_set_content_scale(surface, scale, scale)
            ghostty_surface_set_size(surface, width, height)
            ghostty_surface_set_occlusion(surface, isTerminalVisible && window != nil)
            ghostty_surface_refresh(surface)
            lastSurfaceGeometry = geometry
            emitHostRenderEvent("host_view_geometry_end", dedupeKey: geometryKey)
        }

        private func emitHostRenderEvent(_ name: String, dedupeKey: String? = nil, attributes: [String: String] = [:]) {
            guard let ownerEpoch = activeOwnerEpoch else { return }
            if let dedupeKey {
                let eventKey = "\(name)|\(dedupeKey)"
                guard emittedHostRenderEvents.insert(eventKey).inserted else { return }
            }
            var eventAttributes = attributes
            eventAttributes["owner_epoch"] = "\(ownerEpoch.ownerEpoch)"
            eventAttributes["render_key"] = lastRenderKey
            eventAttributes["mirror"] = mirror == nil ? "0" : "1"
            eventAttributes["visible"] = isTerminalVisible ? "1" : "0"
            eventAttributes["accepts_input"] = acceptsTerminalInput ? "1" : "0"
            eventAttributes["bounds"] = "\(Int(bounds.width))x\(Int(bounds.height))"
            let renderBounds = visibleRenderBounds()
            eventAttributes["render_bounds"] = "\(Int(renderBounds.width))x\(Int(renderBounds.height))"
            SpacesMobileTerminalPerformanceLogger.emit(
                .init(sessionID: ownerEpoch.sessionID, source: "ios-host-view", name: name, attributes: eventAttributes))
        }

        private func applyLatestRenderFrameIfPossible() {
            guard let mirror, let frame = mirrorRenderFrame() else {
                setNeedsDisplay()
                return
            }
            let applyStartedAt = Date()
            let applied = withCFrame(frame) { cFrame in ghostty_mirror_apply_render_frame(mirror, cFrame) }
            let applyMS = TerminalPerformance.elapsedMS(since: applyStartedAt)
            if let sessionID = activeOwnerEpoch?.sessionID {
                let attributes = GhosttyRenderFrameMetrics.attributes(
                    frame: frame, dropped: !applied, dropReason: applied ? nil : "mirror_apply_failed", renderMode: "ghostty-mirror",
                    targetRevision: frame.sessionRevision, appliedRevision: applied ? frame.sessionRevision : nil, applyMS: applyMS)
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

        private func mirrorRenderFrame() -> GhosttyRenderFrame? {
            guard let frame = latestRenderFrame, let snapshot = currentRenderedSnapshot else { return latestRenderFrame }
            guard frame.snapshot != snapshot else { return frame }
            return GhosttyRenderFrame(
                version: frame.version, sessionRevision: frame.sessionRevision, ownerEpoch: frame.ownerEpoch, snapshot: snapshot)
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
            let renderBounds = visibleRenderBounds()
            if let surfaceSize = surfaceViewportSize(renderBounds: renderBounds) {
                return GhosttyRemoteTerminalViewport.reportedSize(
                    rawColumns: surfaceSize.columns, rawRows: surfaceSize.rows, bounds: renderBounds, idiom: terminalUserInterfaceIdiom)
            }
            let metrics = cellMetrics()
            let content = renderBounds.inset(by: Self.contentInsets)
            let rawColumns = max(Int(floor(max(content.width, 1) / metrics.width)), 1)
            let rawRows = max(Int(floor(max(content.height, 1) / metrics.height)), 1)
            return GhosttyRemoteTerminalViewport.reportedSize(
                rawColumns: rawColumns, rawRows: rawRows, bounds: renderBounds, idiom: terminalUserInterfaceIdiom)
        }

        private func surfaceViewportSize(renderBounds: CGRect) -> (columns: Int, rows: Int)? {
            if let surfaceViewportSizeOverrideForTesting {
                return (columns: max(surfaceViewportSizeOverrideForTesting.columns, 1), rows: max(surfaceViewportSizeOverrideForTesting.rows, 1))
            }
            guard mirror != nil else { return nil }
            updateSurfaceGeometry()
            guard let surface = mirrorSurface() else { return nil }
            let size = ghostty_surface_size(surface)
            guard size.columns > 0, size.rows > 0 else { return nil }
            let columns = Int(size.columns)
            let rows = Int(size.rows)
            guard size.cell_height_px > 0 else { return (columns: columns, rows: rows) }

            let scale = CGFloat(window?.screen.scale ?? UIScreen.main.scale)
            let visiblePixelHeight = max(floor(renderBounds.height * scale), 1)
            let visibleRows = max(Int(floor(visiblePixelHeight / CGFloat(size.cell_height_px))), 1)
            return (columns: columns, rows: min(rows, visibleRows))
        }

        @discardableResult private func sendScroll(horizontal: CGFloat, vertical: CGFloat, scrollMods: Int32) -> Bool {
            onSendScroll?(Double(horizontal), Double(vertical), scrollMods)
            return horizontal != 0 || vertical != 0
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

        private func sendPendingAccessoryModifiersIfNeeded(for text: String) -> Bool {
            guard !pendingAccessoryModifiers.isEmpty else { return false }
            defer { clearAccessoryModifiers() }
            guard text.count == 1, let scalar = text.unicodeScalars.first, scalar.properties.isAlphabetic else { return false }
            guard let keySpec = modifiedKeySpec(for: String(scalar).lowercased()) else { return false }
            onSendKey?(keySpec)
            return true
        }

        private func sendAccessoryText(_ text: String) {
            guard acceptsTerminalInput, !text.isEmpty else { return }
            if sendPendingAccessoryModifiersIfNeeded(for: text) { return }
            clearAccessoryModifiers()
            onSendText?(text)
        }

        private func sendAccessoryKey(_ key: String) {
            guard acceptsTerminalInput else { return }
            let keySpec = modifiedKeySpec(for: key) ?? key
            clearAccessoryModifiers()
            onSendKey?(keySpec)
        }

        private func modifiedKeySpec(for key: String) -> String? {
            guard !pendingAccessoryModifiers.isEmpty else { return nil }
            let modifierPrefix = AccessoryModifier.allCases.filter { pendingAccessoryModifiers.contains($0) }.map(\.rawValue).joined(separator: "+")
            let spec = "\(modifierPrefix)+\(key)"
            guard TerminalKeyInput.isSupportedSpec(spec) else { return nil }
            return spec
        }

        private func toggleAccessoryModifier(_ modifier: AccessoryModifier) {
            guard acceptsTerminalInput else { return }
            if pendingAccessoryModifiers.contains(modifier) {
                pendingAccessoryModifiers.remove(modifier)
            } else {
                pendingAccessoryModifiers.insert(modifier)
            }
            terminalAccessoryView.pendingModifiers = pendingAccessoryModifiers
        }

        private func clearAccessoryModifiers() {
            guard !pendingAccessoryModifiers.isEmpty else { return }
            pendingAccessoryModifiers.removeAll()
            terminalAccessoryView.pendingModifiers = []
        }

        private func toggleAccessorySoftwareKeyboard() { setSoftwareKeyboardVisible(suppressesSoftwareKeyboard) }

        private func visibleRenderBounds() -> CGRect {
            guard bounds.width > 0, bounds.height > 0 else { return bounds }
            let occludedHeight = keyboardAndAccessoryOccludedHeight()
            guard occludedHeight > 0 else { return bounds }
            let clampedOcclusion = min(max(occludedHeight, 0), bounds.height)
            return CGRect(x: 0, y: 0, width: bounds.width, height: max(bounds.height - clampedOcclusion, 1))
        }

        private func keyboardAndAccessoryOccludedHeight() -> CGFloat {
            let occludingFrames = keyboardAndAccessoryOccludingFrames()
            guard !occludingFrames.isEmpty else { return 0 }
            let top = occludingFrames.map(\.minY).min() ?? bounds.maxY
            return max(bounds.maxY - top, 0)
        }

        private func keyboardAndAccessoryOccludingFrames() -> [CGRect] {
            guard bounds.width > 0, bounds.height > 0 else { return [] }
            var frames: [CGRect] = []
            let keyboardFrame = keyboardOccludingFrame()
            if let keyboardFrame { frames.append(keyboardFrame) }
            if let accessoryFrame = accessoryOccludingFrame() { frames.append(accessoryFrame) }
            if let fallbackAccessoryFrame = fallbackAccessoryOccludingFrame(keyboardFrame: keyboardFrame, existingFrames: frames) {
                frames.append(fallbackAccessoryFrame)
            }
            return frames
        }

        private func keyboardOccludingFrame() -> CGRect? {
            if let keyboardOccludedHeightOverrideForTesting {
                let height = min(max(keyboardOccludedHeightOverrideForTesting, 0), bounds.height)
                guard height > 0 else { return nil }
                return CGRect(x: 0, y: bounds.maxY - height, width: bounds.width, height: height)
            }
            guard window != nil else { return nil }
            let keyboardFrame = keyboardLayoutGuide.layoutFrame
            guard keyboardFrame.height > 0, bounds.intersects(keyboardFrame) else { return nil }
            let intersection = bounds.intersection(keyboardFrame)
            guard intersection.height > 0 else { return nil }
            return intersection
        }

        private func accessoryOccludingFrame() -> CGRect? {
            guard acceptsTerminalInput else { return nil }
            if terminalAccessoryView.window != nil, !terminalAccessoryView.bounds.isEmpty {
                let frame = terminalAccessoryView.convert(terminalAccessoryView.bounds, to: self)
                if bounds.intersects(frame) {
                    let intersection = bounds.intersection(frame)
                    if intersection.height > 0 { return intersection }
                }
            }
            return nil
        }

        private func fallbackAccessoryOccludingFrame(keyboardFrame: CGRect?, existingFrames: [CGRect]) -> CGRect? {
            guard acceptsTerminalInput else { return nil }
            guard isFirstResponder || keyboardFrame != nil || keyboardOccludedHeightOverrideForTesting != nil else { return nil }
            guard existingFrames.allSatisfy({ abs($0.height - Self.accessoryToolbarHeight) > 1 }) else { return nil }
            let maxY = keyboardFrame?.minY ?? bounds.maxY
            guard maxY > 0, maxY <= bounds.maxY else { return nil }
            let height = min(Self.accessoryToolbarHeight, maxY)
            guard height > 0 else { return nil }
            return CGRect(x: 0, y: maxY - height, width: bounds.width, height: height)
        }

        func setKeyboardOccludedHeightForTesting(_ height: CGFloat?) {
            keyboardOccludedHeightOverrideForTesting = height
            setNeedsLayout()
            reportViewportSizeIfNeeded()
            renderLatestSnapshot()
        }

        func setSurfaceViewportSizeForTesting(columns: Int, rows: Int) {
            surfaceViewportSizeOverrideForTesting = (columns: columns, rows: rows)
            reportViewportSizeIfNeeded()
            renderLatestSnapshot()
        }

        func viewportSizeForTesting() -> (columns: Int, rows: Int) { viewportSize() }

        func visibleRenderBoundsForTesting() -> CGRect { visibleRenderBounds() }

        private var terminalUserInterfaceIdiom: UIUserInterfaceIdiom { userInterfaceIdiomOverrideForTesting ?? traitCollection.userInterfaceIdiom }

        func surfaceHostFrameForTesting() -> CGRect { surfaceHostView.frame }

        func debugTapToActivateInputForTesting(at location: CGPoint = CGPoint(x: 1, y: 1)) -> TapActivationResult {
            handleTapToActivateInput(at: location)
        }

        func debugApplyActionEventForTesting(_ event: GhosttyMobileActionEvent) { handleActionEvent(event) }

        @discardableResult func debugApplyActionEventsDuringTapProbeForTesting(_ events: [GhosttyMobileActionEvent]) -> Bool {
            tapLinkProbeDepth += 1
            openedLinkDuringTapProbe = false
            defer { tapLinkProbeDepth -= 1 }
            for event in events { handleActionEvent(event) }
            let openedLink = openedLinkDuringTapProbe
            openedLinkDuringTapProbe = false
            return openedLink
        }

        private final class TerminalAccessoryToolbar: UIView {
            private static let toolbarHeight = GhosttyRemoteTerminalHostView.accessoryToolbarHeight

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
                    horizontalInset: 10, verticalInset: 6, spacing: 6, textButtonWidth: 58, iconButtonWidth: 48, buttonHeight: 34, cornerRadius: 7,
                    fontSize: 15)
                static let phone = Metrics(
                    horizontalInset: 6, verticalInset: 6, spacing: 5, textButtonWidth: 44, iconButtonWidth: 40, buttonHeight: 34, cornerRadius: 6,
                    fontSize: 14)
            }

            var pendingModifiers: Set<AccessoryModifier> = [] { didSet { updateModifierButtonAppearances() } }
            var isKeyboardVisible = true { didSet { updateKeyboardButtonImage() } }

            private let onText: (String) -> Void
            private let onKey: (String) -> Void
            private let onModifier: (AccessoryModifier) -> Void
            private let onKeyboardToggle: () -> Void
            private let toolbarStackView = UIStackView()
            private let scrollView = UIScrollView()
            private let contentStackView = UIStackView()
            private let pinnedStackView = UIStackView()
            private var modifierButtons: [AccessoryModifier: UIButton] = [:]
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
                onText: @escaping (String) -> Void, onKey: @escaping (String) -> Void, onModifier: @escaping (AccessoryModifier) -> Void,
                onKeyboardToggle: @escaping () -> Void
            ) {
                self.onText = onText
                self.onKey = onKey
                self.onModifier = onModifier
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
                addModifierButton(.control)
                addModifierButton(.command)
                addModifierButton(.option)

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

            private func addModifierButton(_ modifier: AccessoryModifier) {
                let button = UIButton(type: .system)
                configureButton(button, title: modifier.rawValue)
                button.accessibilityLabel = modifier.accessibilityLabel
                button.addAction(UIAction { [weak self] _ in self?.onModifier(modifier) }, for: .touchUpInside)
                modifierButtons[modifier] = button
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

            private func updateModifierButtonAppearances() {
                for (modifier, button) in modifierButtons {
                    let isPending = pendingModifiers.contains(modifier)
                    button.backgroundColor = isPending ? .white : UIColor.white.withAlphaComponent(0.13)
                    button.setTitleColor(isPending ? .black : .white, for: .normal)
                    button.layer.borderColor = UIColor.white.withAlphaComponent(isPending ? 0 : 0.14).cgColor
                }
            }

            private func updateKeyboardButtonImage() {
                let imageName = isKeyboardVisible ? "keyboard.chevron.compact.down" : "keyboard"
                keyboardButton.setImage(UIImage(systemName: imageName), for: .normal)
                keyboardButton.accessibilityLabel = isKeyboardVisible ? "Hide keyboard" : "Show keyboard"
            }

            var buttonAccessibilityLabelsForTesting: AccessoryToolbarButtonLabels {
                AccessoryToolbarButtonLabels(scrollable: buttonLabels(in: contentStackView), pinned: buttonLabels(in: pinnedStackView))
            }

            func layoutFramesForTesting(width: CGFloat, userInterfaceIdiom: UIUserInterfaceIdiom) -> AccessoryToolbarLayoutFrames {
                prepareLayoutForTesting(width: width, userInterfaceIdiom: userInterfaceIdiom)
                return AccessoryToolbarLayoutFrames(
                    scrollView: scrollView.frame,
                    scrollContentSize: CGSize(
                        width: max(scrollView.contentSize.width, contentStackView.bounds.width),
                        height: max(scrollView.contentSize.height, contentStackView.bounds.height)),
                    joystickButton: joystickButton.convert(joystickButton.bounds, to: self),
                    keyboardButton: keyboardButton.convert(keyboardButton.bounds, to: self))
            }

            func buttonWidthsForTesting(width: CGFloat, userInterfaceIdiom: UIUserInterfaceIdiom) -> AccessoryToolbarButtonWidths {
                prepareLayoutForTesting(width: width, userInterfaceIdiom: userInterfaceIdiom)
                return AccessoryToolbarButtonWidths(scrollable: buttonWidths(in: contentStackView), pinned: buttonWidths(in: pinnedStackView))
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

    }

#endif
