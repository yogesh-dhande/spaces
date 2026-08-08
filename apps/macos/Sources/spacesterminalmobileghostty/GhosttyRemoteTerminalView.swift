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
        public let fontSize: TerminalFontSize
        public let onInputReadinessChanged: @MainActor (Bool) -> Void
        public let onScrollGestureApplied: (@MainActor () -> Void)?
        public let onRenderedTextChanged: (@MainActor (String) -> Void)?
        public let onViewportSizeChanged: @MainActor (Int, Int) -> Void
        public let onSendText: @MainActor (String, Bool) -> Void
        public let onSendKey: @MainActor (String) -> Void
        public let onSendScroll: @MainActor (Double, Double, Int32, TerminalScrollPointerPosition?) -> Void
        public let onSendMouseButton: @MainActor (UInt8, Bool, TerminalScrollPointerPosition?) -> Void
        public let onOpenLink: @MainActor (String) -> Void
        public let onOpenComposer: (@MainActor () -> Void)?
        public let onPasteClipboardImage: (@MainActor () -> Bool)?

        public init(
            ownerEpoch: GhosttyRemoteTerminalOwnerEpoch? = nil, endedRender: GhosttyRemoteTerminalEndedRender? = nil, fallbackText: String,
            isVisible: Bool, acceptsInput: Bool, isBusy: Bool, fontSize: TerminalFontSize,
            onInputReadinessChanged: @escaping @MainActor (Bool) -> Void = { _ in }, onScrollGestureApplied: (@MainActor () -> Void)? = nil,
            onRenderedTextChanged: (@MainActor (String) -> Void)? = nil, onViewportSizeChanged: @escaping @MainActor (Int, Int) -> Void,
            onSendText: @escaping @MainActor (String, Bool) -> Void, onSendKey: @escaping @MainActor (String) -> Void,
            onSendScroll: @escaping @MainActor (Double, Double, Int32, TerminalScrollPointerPosition?) -> Void = { _, _, _, _ in },
            onSendMouseButton: @escaping @MainActor (UInt8, Bool, TerminalScrollPointerPosition?) -> Void = { _, _, _ in },
            onOpenLink: @escaping @MainActor (String) -> Void = { _ in }, onOpenComposer: (@MainActor () -> Void)? = nil,
            onPasteClipboardImage: (@MainActor () -> Bool)? = nil
        ) {
            self.ownerEpoch = ownerEpoch
            self.endedRender = endedRender
            self.fallbackText = fallbackText
            self.isVisible = isVisible
            self.acceptsInput = acceptsInput
            self.isBusy = isBusy
            self.fontSize = fontSize
            self.onInputReadinessChanged = onInputReadinessChanged
            self.onScrollGestureApplied = onScrollGestureApplied
            self.onRenderedTextChanged = onRenderedTextChanged
            self.onViewportSizeChanged = onViewportSizeChanged
            self.onSendText = onSendText
            self.onSendKey = onSendKey
            self.onSendScroll = onSendScroll
            self.onSendMouseButton = onSendMouseButton
            self.onOpenLink = onOpenLink
            self.onOpenComposer = onOpenComposer
            self.onPasteClipboardImage = onPasteClipboardImage
        }

        public func makeUIView(context: Context) -> GhosttyRemoteTerminalHostView { GhosttyRemoteTerminalHostView() }

        public func updateUIView(_ hostView: GhosttyRemoteTerminalHostView, context: Context) {
            hostView.onInputReadinessChanged = { ready in _ = Task { @MainActor in onInputReadinessChanged(ready) } }
            hostView.onScrollGestureApplied = onScrollGestureApplied.map { callback in { _ = Task { @MainActor in callback() } } }
            hostView.onViewportSizeChanged = { columns, rows in _ = Task { @MainActor in onViewportSizeChanged(columns, rows) } }
            hostView.onSendText = { text, asPaste in _ = Task { @MainActor in onSendText(text, asPaste) } }
            hostView.onSendKey = { key in _ = Task { @MainActor in onSendKey(key) } }
            hostView.onSendScroll = { horizontal, vertical, scrollMods, pointerPosition in
                _ = Task { @MainActor in onSendScroll(horizontal, vertical, scrollMods, pointerPosition) }
            }
            // Synchronous on purpose, unlike the Task-hopping callbacks around it: a tap sends a
            // press immediately followed by a release, and two independent unstructured Tasks have
            // no ordering guarantee — a reordered pair would deliver a release-before-press to the
            // application. UIKit fires the gesture on the main thread, so assuming isolation holds.
            hostView.onSendMouseButton = { button, pressed, pointerPosition in
                MainActor.assumeIsolated { onSendMouseButton(button, pressed, pointerPosition) }
            }
            hostView.onOpenLink = { link in _ = Task { @MainActor in onOpenLink(link) } }
            hostView.onOpenComposer = onOpenComposer.map { callback in { _ = Task { @MainActor in callback() } } }
            // Synchronous, unlike the Task-hopping callbacks around it: the paste routes need the
            // handler's answer (did the clipboard image claim this paste?) before deciding whether to
            // fall through to the text paste. UIKit delivers the paste on the main thread.
            hostView.onPasteClipboardImage = onPasteClipboardImage.map { callback in { MainActor.assumeIsolated { callback() } } }
            hostView.onRenderedTextChanged = onRenderedTextChanged.map { callback in { text in _ = Task { @MainActor in callback(text) } } }
            hostView.setTerminalVisible(isVisible)
            hostView.setAcceptsTerminalInput(acceptsInput && !isBusy)
            hostView.setTerminalFontSize(fontSize)
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

        /// Everything that decides what a mirror render-frame apply would write into the surface.
        /// `acceptsTerminalInput` belongs here because the applied frame's mouse-capture flags are derived
        /// from it, so the same snapshot applies differently to an interactive owner and a read-only pane.
        private struct AppliedRenderFrameIdentity: Equatable {
            let renderKey: String
            let version: Int
            let sessionRevision: UInt64?
            let ownerEpoch: UInt64
            let acceptsTerminalInput: Bool
            let snapshot: GhosttyTerminalSnapshot
        }

        private enum AccessoryModifier: String, CaseIterable {
            case shift
            case control = "ctrl"
            case command = "cmd"
            case option = "opt"

            var accessibilityLabel: String {
                switch self {
                case .shift: return "Shift"
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
            case sentClick
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

        private static let contentInsets = GhosttyRemoteTerminalViewport.contentInsets
        private static let accessoryToolbarHeight: CGFloat = 46

        nonisolated(unsafe) static var sessionFreeHandlerForTesting: @Sendable (UnsafeRawPointer?) -> Void = { _ in }
        nonisolated(unsafe) static var nativeMirrorEnabledForTesting = true

        private var mirror: ghostty_mirror_t?
        private var fontSize: TerminalFontSize = .default
        private var activeOwnerEpoch: GhosttyRemoteTerminalOwnerEpoch?
        private var activeEndedRender: GhosttyRemoteTerminalEndedRender?
        private var latestRenderFrame: GhosttyRenderFrame?
        private var latestSnapshot: GhosttyTerminalSnapshot?
        private var currentRenderedSnapshot: GhosttyTerminalSnapshot?
        private var lastRenderKey = ""
        /// What the mirror surface currently holds. SwiftUI re-runs `updateUIView` and UIKit re-runs
        /// `layoutSubviews` for reasons that have nothing to do with the terminal's content — a title
        /// change, a keyboard frame, a sibling view's update — and each of those reaches
        /// `applyLatestRenderFrameIfPossible`. Applying a frame the surface already shows costs a
        /// full-grid cell copy and a full-grid surface write, so a byte-identical frame is skipped
        /// instead. Cleared wherever the surface this describes goes away or is rebound, so
        /// a fresh surface always re-applies, and also in `setTerminalFontSize(_:)`: a font retune changes
        /// what the surface should show without changing anything this identity tracks (a font decrease
        /// leaves the cropped frame byte-identical), so it is cleared there too rather than skipped as a
        /// no-op.
        private var lastAppliedRenderFrameIdentity: AppliedRenderFrameIdentity?
        private var lastSurfaceGeometry: SurfaceGeometry?
        private var lastReportedViewportSize: (columns: Int, rows: Int)?
        private var lastRenderedText = ""
        private var lastReportedInputReadiness = false
        private var emittedHostRenderEvents = Set<String>()
        private var mirrorAcquisitionTask: Task<Void, Never>?
        private var didSurrenderSharedMirror = false
        private var isTerminalVisible = true
        private var fallbackText = ""
        private var lastScrollTranslation = CGPoint.zero
        private var didScrollDuringCurrentPan = false
        private var scrollInteractionDepth = 0
        private var deferredViewportSizeReport = false
        private var momentumDisplayLink: CADisplayLink?
        private var momentumVelocity = CGPoint.zero
        private var lastMomentumTimestamp: CFTimeInterval = 0
        private var lastScrollPointerPosition: TerminalScrollPointerPosition?
        private var pendingAccessoryModifiers: Set<AccessoryModifier> = []
        /// Clipboard read seams: production reads the system pasteboard, tests substitute the contents so
        /// the paste paths can be exercised without mutating the device pasteboard. The image probe reads
        /// declared pasteboard types only, so it costs no paste prompt on the common text-only path.
        private var clipboardTextReader: () -> String? = { UIPasteboard.general.string }
        private var clipboardHasImageReader: () -> Bool = { UIPasteboard.general.hasImages }
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
            onComposer: { [weak self] in self?.onOpenComposer?() }, onPaste: { [weak self] in self?.pasteFromClipboard() },
            onText: { [weak self] text in self?.sendAccessoryText(text) }, onKey: { [weak self] key in self?.sendAccessoryKey(key) },
            onModifier: { [weak self] modifier in self?.toggleAccessoryModifier(modifier) },
            onKeyboardToggle: { [weak self] in self?.toggleAccessorySoftwareKeyboard() })
        var debugTapLinkHandlerForTesting: ((CGPoint) -> Bool)?
        /// Stands in for the live mirror surface's mouse-capture state, which only exists once a real
        /// surface has applied a frame.
        var debugMouseCapturedForTesting: Bool?

        public private(set) var acceptsTerminalInput = false
        public var onInputReadinessChanged: ((Bool) -> Void)?
        public var onScrollGestureApplied: (() -> Void)?
        public var onViewportSizeChanged: ((Int, Int) -> Void)?
        public var onSendText: ((String, Bool) -> Void)?
        public var onSendKey: ((String) -> Void)?
        public var onSendScroll: ((Double, Double, Int32, TerminalScrollPointerPosition?) -> Void)?
        public var onSendMouseButton: ((UInt8, Bool, TerminalScrollPointerPosition?) -> Void)?
        public var onOpenLink: ((String) -> Void)?
        public var onOpenComposer: (() -> Void)?
        /// Handles a paste whose clipboard declares an image. The app layer reads and validates the image
        /// (types this layer cannot see) and returns whether it claimed the paste; `false` means the
        /// declared image carried nothing readable, so the text paste runs instead.
        public var onPasteClipboardImage: (() -> Bool)?
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

        func accessoryToolbarJoystickDirectionForTesting(translationX: CGFloat, translationY: CGFloat) -> String? {
            DirectionalPadButton.direction(forTranslationX: translationX, y: translationY)
        }

        func accessoryToolbarJoystickAcceptsReleaseForTesting(point: CGPoint, bounds: CGRect) -> Bool {
            DirectionalPadButton.acceptsRelease(at: point, in: bounds)
        }

        func accessoryToolbarJoystickAcceptsActivationForTesting(point: CGPoint, bounds: CGRect) -> Bool {
            DirectionalPadButton.acceptsActivation(at: point, in: bounds)
        }

        func accessoryToolbarBeginJoystickTrackingForTesting(at point: CGPoint, bounds: CGRect, initialDelay: Duration, interval: Duration) {
            terminalAccessoryView.beginJoystickTrackingForTesting(at: point, bounds: bounds, initialDelay: initialDelay, interval: interval)
        }

        func accessoryToolbarMoveJoystickTrackingForTesting(to point: CGPoint) { terminalAccessoryView.moveJoystickTrackingForTesting(to: point) }

        func accessoryToolbarEndJoystickTrackingForTesting() { terminalAccessoryView.endJoystickTrackingForTesting() }

        public override init(frame: CGRect) {
            super.init(frame: frame)
            isOpaque = true
            backgroundColor = .black
            inputAssistantItem.leadingBarButtonGroups = []
            inputAssistantItem.trailingBarButtonGroups = []
            addGestureRecognizer(activateInputRecognizer)
            scrollPanRecognizer.maximumNumberOfTouches = 2
            addGestureRecognizer(scrollPanRecognizer)
        }

        @available(*, unavailable) required init?(coder: NSCoder) { nil }

        // The shared mirror needs nothing here: leaving the window and SwiftUI's dismantle both run
        // `prepareForDismantle()`, and a holder that somehow deallocates without releasing is parked
        // by the next view's acquisition, which never touches the deallocated one.
        deinit { MainActor.assumeIsolated { momentumDisplayLink?.invalidate() } }

        public override func didMoveToWindow() {
            super.didMoveToWindow()
            if window == nil {
                prepareForDismantle()
            } else {
                // Entering a window is what makes this view the terminal on screen, so it is also
                // what re-entitles it to the shared mirror after a newer view took it over.
                didSurrenderSharedMirror = false
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
            mirrorAcquisitionTask?.cancel()
            mirrorAcquisitionTask = nil
            latestRenderFrame = nil
            latestSnapshot = nil
            currentRenderedSnapshot = nil
            lastSurfaceGeometry = nil
            releaseSharedMirror()
            reportInputReadinessIfNeeded(force: true)
            if hadRenderedSnapshot {
                let handler = Self.sessionFreeHandlerForTesting
                _ = Task.detached(priority: .utility) { handler(nil) }
            }
        }

        /// Gives the shared mirror back when this view stops rendering. The mirror itself stays
        /// alive and parked for the next terminal view; freeing it here is the blocking call
        /// ``GhosttySharedTerminalMirror`` exists to keep off navigation paths.
        private func releaseSharedMirror() {
            mirror = nil
            lastSurfaceGeometry = nil
            lastAppliedRenderFrameIdentity = nil
            GhosttySharedTerminalMirror.shared.release(from: self)
        }

        /// Called when another terminal view takes the shared mirror over. This view drops back to
        /// its own black background and stops asking for the mirror while the newcomer holds it, so
        /// an outgoing view still in the hierarchy during a navigation transition cannot trade the
        /// mirror back and forth with the incoming one.
        ///
        /// The latch lifts on exactly two edges, and both mean "this view is entitled to the mirror
        /// again": re-entering a window, which is what makes this the terminal on screen after a
        /// route change; and being offered the mirror back once it is parked with no holder at all,
        /// which is what happens when the view that took it over goes away while this one stayed
        /// parented — a terminal in a sheet or a non-fullscreen cover over another terminal, or two
        /// terminals side by side in a split layout. Neither edge can fire while another view holds
        /// the mirror, which is what keeps the latch doing its job.
        func surrenderSharedMirror() {
            mirror = nil
            lastSurfaceGeometry = nil
            lastAppliedRenderFrameIdentity = nil
            didSurrenderSharedMirror = true
            setNeedsDisplay()
            reportInputReadinessIfNeeded()
        }

        /// Takes the shared mirror back after the view that took it over gave it up, reporting
        /// whether this view actually took it. Being in a window with something to render is the
        /// same entitlement every other acquisition goes through, so a view with nothing on screen
        /// declines and the offer moves on to the view beneath it.
        ///
        /// The hand-back completes here, synchronously, rather than lifting the latch and letting
        /// the render path schedule an acquisition: an entitlement checked when the offer is made
        /// but acted on a turn later is no entitlement at all. A terminal that mounted in the same
        /// update has its own acquisition already queued, and once that lands it is the terminal the
        /// user is looking at — a deferred hand-back would take the mirror straight off it. Because
        /// nothing suspends between the mirror parking and this call returning, an acquisition can
        /// only run before the offer (and then there is a holder, so no offer is made) or after it
        /// (and then it is an ordinary takeover by the newer view).
        func reclaimSurrenderedSharedMirror() -> Bool {
            guard didSurrenderSharedMirror, window != nil else { return false }
            didSurrenderSharedMirror = false
            acquireMirrorIfNeeded()
            renderLatestSnapshot()
            reportViewportSizeIfNeeded()
            return mirror != nil
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
            // The capture flags applied to the mirror are gated on this property, so a pane whose
            // latest frame carries them must re-apply when it flips (e.g. the session just ended).
            if latestRenderFrame?.snapshot.mouseReportingActive == true { applyLatestRenderFrameIfPossible() }
            reloadInputViews()
            reportInputReadinessIfNeeded(force: true)
        }

        /// Applies a new terminal font size, retuning the live mirror in place. The render state
        /// (`latestSnapshot`, `latestRenderFrame`, owner epoch) is deliberately kept — unlike
        /// `prepareForDismantle()` — so the terminal re-renders its current content at the new size
        /// instead of blanking until the daemon sends the next frame. The new grid is reported after
        /// the re-render so the daemon resizes to the surface's own cell metrics rather than the
        /// `cellMetrics()` estimate a mirror-less viewport would produce.
        public func setTerminalFontSize(_ newFontSize: TerminalFontSize) {
            guard fontSize != newFontSize else { return }
            fontSize = newFontSize
            guard mirror != nil else { return }
            GhosttySharedTerminalMirror.shared.setFontSize(newFontSize, from: self)
            // The identity below has no notion of font size, so a retune that leaves the cropped frame
            // byte-identical (a font decrease is the common case: it never changes what a fixed viewport
            // can crop from the snapshot) would otherwise be skipped as a no-op re-apply, leaving Ghostty's
            // own reflow of the old-sized grid on screen until the next real frame lands. Clearing here
            // forces `applyLatestRenderFrameIfPossible()` to apply regardless of whether the frame changed.
            lastAppliedRenderFrameIdentity = nil
            renderLatestSnapshot()
            reportViewportSizeIfNeeded()
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
            if nextKey != lastRenderKey { lastRenderKey = nextKey }
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
            // Return reaches `insertText` as plain text with no modifier information, so a pending
            // accessory modifier is the only way to reach Shift+Enter without a hardware keyboard. It has
            // to be applied here, before the text path below clears the pending modifiers.
            if text == "\n" || text == "\r" {
                sendAccessoryKey("enter")
                return
            }
            if sendPendingAccessoryModifiersIfNeeded(for: text) { return }
            onSendText?(text, false)
        }

        public override func paste(_ sender: Any?) { pasteFromClipboard() }

        /// Pastes the clipboard, image first: an image belongs in the composer as an attachment the user
        /// then sends deliberately, never in the terminal as bytes, so `onPasteClipboardImage` takes the
        /// paste when the clipboard holds one. Text is sent as a bracketed paste. Shared by the system
        /// Paste command, the accessory Paste button, and the accessory cmd+v chord so all three behave
        /// identically.
        private func pasteFromClipboard() {
            guard acceptsTerminalInput else { return }
            if clipboardHasImageReader(), onPasteClipboardImage?() == true { return }
            guard let text = clipboardTextReader() else { return }
            pasteText(text)
        }

        func pasteTextForTesting(_ text: String) {
            guard acceptsTerminalInput else { return }
            pasteText(text)
        }

        func setClipboardTextForTesting(_ text: String?) { clipboardTextReader = { text } }

        func setClipboardHasImageForTesting(_ hasImage: Bool) { clipboardHasImageReader = { hasImage } }

        private func pasteText(_ text: String) {
            guard !text.isEmpty else { return }
            clearAccessoryModifiers()
            onSendText?(text, true)
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
                // Modified Return has to be claimed explicitly: an unmodified Return arrives through
                // `insertText`, which cannot see modifier flags at all.
                UIKeyCommand(input: "\r", modifierFlags: .shift, action: #selector(sendShiftEnter)),
                UIKeyCommand(input: "\r", modifierFlags: .control, action: #selector(sendControlEnter)),
                UIKeyCommand(input: "\r", modifierFlags: .alternate, action: #selector(sendOptionEnter)),
                UIKeyCommand(input: "\t", modifierFlags: [], action: #selector(sendTab)),
                UIKeyCommand(input: "\t", modifierFlags: .shift, action: #selector(sendShiftTab)),
                UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(sendEscape)),
            ]
        }

        /// How many frames have actually reached the mirror apply. The skip that the applied-frame
        /// identity performs is invisible from the outside — the surface shows the same
        /// pixels either way — so this is what lets a test see that a repeat layout or a title-only
        /// payload costs no apply.
        public private(set) var renderFrameApplyCountForTesting = 0

        public func capturedSnapshotForTesting() -> GhosttyTerminalSnapshot? { currentRenderedSnapshot }
        public var hasActiveSessionForTesting: Bool { currentRenderedSnapshot != nil }
        public var hasMirrorSurfaceForTesting: Bool { mirrorSurface() != nil }
        public var hasRetainedSessionStandardInputWriteDescriptorForTesting: Bool { false }

        @discardableResult public func debugSendScrollForTesting(
            horizontal: CGFloat, vertical: CGFloat, location: CGPoint? = nil, hasPreciseDeltas: Bool = false,
            momentumState: UIGestureRecognizer.State = .changed
        ) -> Bool {
            sendScroll(
                horizontal: horizontal, vertical: vertical,
                scrollMods: Self.makeScrollMods(hasPreciseDeltas: hasPreciseDeltas, momentumState: momentumState),
                pointerPosition: location.flatMap(scrollPointerPosition))
        }

        public static func makeScrollMods(hasPreciseDeltas: Bool, momentumState: UIGestureRecognizer.State) -> Int32 {
            TerminalScrollModifiers.make(hasPreciseDeltas: hasPreciseDeltas, momentumPhase: scrollMomentumPhase(for: momentumState))
        }

        private static func scrollMomentumPhase(for state: UIGestureRecognizer.State) -> TerminalScrollMomentumPhase {
            switch state {
            case .possible: return .mayBegin
            case .ended: return .ended
            case .cancelled, .failed: return .cancelled
            default: return .changed
            }
        }

        @objc private func handleTapToActivateInput(_ recognizer: UITapGestureRecognizer) {
            _ = handleTapToActivateInput(at: recognizer.location(in: self))
        }

        @discardableResult private func handleTapToActivateInput(at location: CGPoint) -> TapActivationResult {
            if sendMouseButtonClickIfCaptured(at: location) {
                // A tap that drives the application still needs the keyboard: without this, tapping
                // vim's mouse=a on a phone would move the cursor while leaving nothing to type with.
                if acceptsTerminalInput, !isFirstResponder { becomeFirstResponder() }
                return .sentClick
            }
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
                lastScrollPointerPosition = scrollPointerPosition(for: recognizer.location(in: self))
                beginScrollInteraction()
            case .changed:
                let translation = recognizer.translation(in: self)
                let delta = CGPoint(x: translation.x - lastScrollTranslation.x, y: translation.y - lastScrollTranslation.y)
                lastScrollTranslation = translation
                let scrollDelta = GhosttyRemoteTerminalScrollMapper.scrollDelta(forPanDelta: delta, scaleFactor: Double(window?.screen.scale ?? 1))
                let scrollMods = Self.makeScrollMods(hasPreciseDeltas: true, momentumState: .changed)
                lastScrollPointerPosition = scrollPointerPosition(for: recognizer.location(in: self))
                if sendScroll(horizontal: scrollDelta.x, vertical: scrollDelta.y, scrollMods: scrollMods, pointerPosition: lastScrollPointerPosition)
                {
                    didScrollDuringCurrentPan = true
                }
            case .ended:
                lastScrollPointerPosition = scrollPointerPosition(for: recognizer.location(in: self)) ?? lastScrollPointerPosition
                if didScrollDuringCurrentPan {
                    _ = sendScroll(
                        horizontal: 0, vertical: 0, scrollMods: Self.makeScrollMods(hasPreciseDeltas: true, momentumState: .ended),
                        pointerPosition: lastScrollPointerPosition)
                }
                if didScrollDuringCurrentPan { onScrollGestureApplied?() }
                let velocity = GhosttyRemoteTerminalScrollMapper.clampedMomentumVelocity(recognizer.velocity(in: self))
                if GhosttyRemoteTerminalScrollMapper.shouldContinueMomentum(velocity: velocity) {
                    startMomentum(velocity: velocity)
                } else {
                    lastScrollPointerPosition = nil
                    endScrollInteraction()
                }
            case .cancelled, .failed:
                if didScrollDuringCurrentPan {
                    _ = sendScroll(
                        horizontal: 0, vertical: 0, scrollMods: Self.makeScrollMods(hasPreciseDeltas: true, momentumState: .cancelled),
                        pointerPosition: lastScrollPointerPosition)
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
            _ = sendScroll(
                horizontal: delta.x, vertical: delta.y, scrollMods: Self.makeScrollMods(hasPreciseDeltas: true, momentumState: .changed),
                pointerPosition: lastScrollPointerPosition)
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
                _ = sendScroll(
                    horizontal: 0, vertical: 0, scrollMods: Self.makeScrollMods(hasPreciseDeltas: true, momentumState: .ended),
                    pointerPosition: lastScrollPointerPosition)
            }
            momentumDisplayLink?.invalidate()
            momentumDisplayLink = nil
            momentumVelocity = .zero
            lastMomentumTimestamp = 0
            lastScrollPointerPosition = nil
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
        @objc private func sendShiftEnter() { sendAccessoryKey("shift+enter") }
        @objc private func sendControlEnter() { sendAccessoryKey("ctrl+enter") }
        @objc private func sendOptionEnter() { sendAccessoryKey("opt+enter") }
        @objc private func sendTab() { sendAccessoryKey("tab") }
        @objc private func sendShiftTab() { sendAccessoryKey("shift+tab") }
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
            scheduleMirrorAcquisitionIfNeeded()
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

        /// Whether this view may take the shared mirror right now: it is the terminal on screen, it
        /// is not latched out by a newer holder, and it has somewhere to render. The render area has
        /// to be non-empty because Ghostty sizes its render target from the host layer's bounds and a
        /// layer bound at zero size never grows back. Checked again at acquisition rather than only
        /// when one is scheduled, since a view can lose any of this in between.
        private var isEntitledToSharedMirror: Bool {
            guard mirror == nil, window != nil, !didSurrenderSharedMirror else { return false }
            guard Self.nativeMirrorEnabledForTesting else { return false }
            let renderBounds = visibleRenderBounds()
            return renderBounds.width > 0 && renderBounds.height > 0
        }

        private func scheduleMirrorAcquisitionIfNeeded() {
            guard mirrorAcquisitionTask == nil, isEntitledToSharedMirror else { return }
            emitHostRenderEvent("host_view_mirror_acquire_scheduled", dedupeKey: lastRenderKey)
            mirrorAcquisitionTask = Task { @MainActor [weak self] in
                await Task.yield()
                guard let self, !Task.isCancelled else { return }
                self.acquireMirrorIfNeeded()
                // Cleared after acquisition, not before, so the layout pass the acquisition itself
                // triggers cannot schedule a second, redundant acquisition task.
                self.mirrorAcquisitionTask = nil
                self.renderLatestSnapshot()
                // A live surface measures the grid with its own font, which the pre-mirror
                // `cellMetrics()` estimate only approximates, so re-report now that it exists. The
                // report dedupes, so this is a no-op when the estimate already matched.
                self.reportViewportSizeIfNeeded()
            }
        }

        private func acquireMirrorIfNeeded() {
            guard isEntitledToSharedMirror else { return }
            do {
                emitHostRenderEvent("host_view_mirror_acquire_begin", dedupeKey: lastRenderKey)
                let acquired = try GhosttySharedTerminalMirror.shared.acquire(
                    for: self, fontSize: fontSize, scaleFactor: Double(window?.screen.scale ?? UIScreen.main.scale))
                mirror = acquired
                // A rebind reuses a surface that is already sized and occluded from its previous
                // holder, so the cached geometry has to be dropped for `updateSurfaceGeometry()` to
                // re-apply this view's size, scale, and occlusion rather than skip as unchanged. The
                // applied-frame identity goes with it: the acquired surface holds the previous holder's
                // cells, so this view's next frame has to be applied even if it matches its own last one.
                lastSurfaceGeometry = nil
                lastAppliedRenderFrameIdentity = nil
                updateSurfaceGeometry()
                if let surface = mirrorSurface() {
                    GhosttyMobileAppService.shared.registerActionHandler(for: surface) { [weak self] event in self?.handleActionEvent(event) }
                }
                emitHostRenderEvent("host_view_mirror_acquire_end", dedupeKey: lastRenderKey)
            } catch { ghosttyRemoteTerminalTrace("mirror_acquire_failed error=\(error)") }
        }

        private func makeSurfaceHost() -> ghostty_surface_host_s {
            GhosttySharedTerminalMirror.shared.makeSurfaceHost(scaleFactor: Double(window?.screen.scale ?? UIScreen.main.scale))
        }

        private func mirrorSurface() -> ghostty_surface_t? {
            guard let mirror else { return nil }
            return ghostty_mirror_surface(mirror)
        }

        private var mirrorCapturesMouse: Bool {
            if let debugMouseCapturedForTesting { return debugMouseCapturedForTesting }
            guard let surface = mirrorSurface() else { return false }
            return ghostty_surface_mouse_captured(surface)
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

        /// Forwards a tap as a left-button press followed by a release when the session's own terminal
        /// is tracking the mouse (`ghostty_surface_mouse_captured`), so a mouse-aware application there
        /// receives the tap as a click instead of Spaces treating it as a link probe or a focus request.
        private func sendMouseButtonClickIfCaptured(at location: CGPoint) -> Bool {
            // Only an owner of a live session can deliver a click; an ended or read-only session's
            // final frame can still carry tracking flags (a crash never disables them), and
            // intercepting those taps would swallow them with no application left to click.
            guard acceptsTerminalInput, mirrorCapturesMouse else { return false }
            let pointerPosition = scrollPointerPosition(for: location)
            onSendMouseButton?(UInt8(GHOSTTY_MOUSE_LEFT.rawValue), true, pointerPosition)
            onSendMouseButton?(UInt8(GHOSTTY_MOUSE_LEFT.rawValue), false, pointerPosition)
            return true
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
            SpacesDeviceTerminalPerformanceLogger.emit(
                .init(sessionID: ownerEpoch.sessionID, source: "ios-host-view", name: name, attributes: eventAttributes))
        }

        private func applyLatestRenderFrameIfPossible() {
            guard let mirror, let frame = mirrorRenderFrame() else {
                lastAppliedRenderFrameIdentity = nil
                setNeedsDisplay()
                return
            }
            let identity = appliedRenderFrameIdentity(for: frame)
            guard identity != lastAppliedRenderFrameIdentity else { return }
            let applyStartedAt = Date()
            // The draw-free apply: the `ghostty_surface_refresh` below is what wakes the render thread
            // to build and present this frame, so a synchronous draw here would only block on the swap
            // chain to re-present the cells built for the previous one.
            let applied = withCFrame(frame) { cFrame in ghostty_mirror_apply_render_frame_no_draw(mirror, cFrame) }
            let applyMS = TerminalPerformance.elapsedMS(since: applyStartedAt)
            renderFrameApplyCountForTesting += 1
            // Built only when something is listening: this runs once per applied frame, and the dictionary
            // costs more than the apply it describes.
            if SpacesDeviceTerminalPerformanceLogger.isEnabled(), let sessionID = activeOwnerEpoch?.sessionID {
                let attributes = GhosttyRenderFrameMetrics.attributes(
                    frame: frame, dropped: !applied, dropReason: applied ? nil : "mirror_apply_failed", renderMode: "ghostty-mirror",
                    targetRevision: frame.sessionRevision, appliedRevision: applied ? frame.sessionRevision : nil, applyMS: applyMS)
                SpacesDeviceTerminalPerformanceLogger.emit(
                    .init(sessionID: sessionID, source: "ios-mirror", name: "render_frame_mirror_apply", elapsedMS: applyMS, attributes: attributes))
            }
            if applied {
                lastAppliedRenderFrameIdentity = identity
                if let surface = mirrorSurface() { ghostty_surface_refresh(surface) }
                // The shared surface stays hidden from the moment it is handed over until a frame of
                // this view's own session has landed on it, so a rebind never shows the previous
                // session's pixels inside this view.
                GhosttySharedTerminalMirror.shared.revealSurface(from: self)
            } else {
                ghosttyRemoteTerminalTrace("mirror_apply_failed")
                setNeedsDisplay()
            }
        }

        private func appliedRenderFrameIdentity(for frame: GhosttyRenderFrame) -> AppliedRenderFrameIdentity {
            AppliedRenderFrameIdentity(
                renderKey: lastRenderKey, version: frame.version, sessionRevision: frame.sessionRevision, ownerEpoch: frame.ownerEpoch,
                acceptsTerminalInput: acceptsTerminalInput, snapshot: frame.snapshot)
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
            // The C cell's link fields are export-only — applying a snapshot ignores them — so they
            // stay zeroed here and a cell's OSC 8 target travels no further than the Swift snapshot.
            // Nothing consumes those targets for interaction yet: a mirrored link whose label is not
            // itself a URL renders as plain text (#373 tracks hit-testing or surface apply).
            var cells = snapshot.cells.map { cell in
                ghostty_terminal_snapshot_cell_s(
                    codepoint: cell.codepoint, foreground_rgb: cell.foregroundRGB, background_rgb: cell.backgroundRGB, flags: cell.flags,
                    grapheme_extra_len: 0, grapheme_extras: nil, link_index: 0)
            }
            // The frame's clusters live in one buffer the cells point into, so they stay alive for
            // exactly the span of the C call and no cell owns memory Ghostty would have to free.
            var clusterExtras = GhosttyTerminalSnapshotClusterExtras.flatten(snapshot)
            return clusterExtras.codepoints.withUnsafeMutableBufferPointer { extras in
                if let base = extras.baseAddress {
                    for placement in clusterExtras.placements {
                        cells[placement.cellIndex].grapheme_extra_len = UInt16(placement.count)
                        cells[placement.cellIndex].grapheme_extras = base + placement.offset
                    }
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
                    // Only an interactive owner's mirror keeps the session's capture flags. An ended or
                    // read-only pane's frame can still carry them (a crash never disables tracking), and
                    // a captured mirror consumes the synthetic click a link tap probes with — links in
                    // that pane would silently stop opening.
                    cSnapshot.mouse_reporting_active = acceptsTerminalInput && snapshot.mouseReportingActive
                    cSnapshot.mouse_shift_capture = acceptsTerminalInput ? snapshot.mouseShiftCapture : 0
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
        }

        private func viewportWindow(for snapshot: GhosttyTerminalSnapshot) -> GhosttyTerminalSnapshotViewport.Window {
            let size = viewportSize()
            return GhosttyTerminalSnapshotViewport.window(for: snapshot, columns: size.columns, rows: size.rows, horizontalAlignment: .leading)
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

        private func scrollPointerPosition(for location: CGPoint) -> TerminalScrollPointerPosition? {
            let renderBounds = visibleRenderBounds()
            return TerminalScrollPointerPosition.normalized(
                x: Double(location.x - renderBounds.minX), y: Double(location.y - renderBounds.minY), width: Double(renderBounds.width),
                height: Double(renderBounds.height))
        }

        @discardableResult private func sendScroll(
            horizontal: CGFloat, vertical: CGFloat, scrollMods: Int32, pointerPosition: TerminalScrollPointerPosition?
        ) -> Bool {
            onSendScroll?(Double(horizontal), Double(vertical), scrollMods, pointerPosition)
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
            let font = UIFont.monospacedSystemFont(ofSize: CGFloat(fontSize.points), weight: .regular)
            let width = ceil(("W" as NSString).size(withAttributes: [.font: font]).width)
            let height = ceil(font.lineHeight)
            return CellMetrics(width: max(width, 1), height: max(height, 1))
        }

        private func sendPendingAccessoryModifiersIfNeeded(for text: String) -> Bool {
            guard !pendingAccessoryModifiers.isEmpty else { return false }
            defer { clearAccessoryModifiers() }
            guard text.count == 1, let scalar = text.unicodeScalars.first, scalar.properties.isAlphabetic else { return false }
            let key = String(scalar).lowercased()
            // cmd+v is a client-side clipboard action, not a chord the terminal resolves: the key resolver
            // drops non-line-editing command chords, so without this the keystroke would fall through and
            // type a literal "v". The keystroke is consumed either way, including on an empty clipboard.
            if pendingAccessoryModifiers == [.command], key == "v" {
                pasteFromClipboard()
                return true
            }
            guard let keySpec = modifiedKeySpec(for: key) else { return false }
            onSendKey?(keySpec)
            return true
        }

        private func sendAccessoryText(_ text: String) {
            guard acceptsTerminalInput, !text.isEmpty else { return }
            if sendPendingAccessoryModifiersIfNeeded(for: text) { return }
            clearAccessoryModifiers()
            onSendText?(text, false)
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

        func surfaceHostFrameForTesting() -> CGRect { GhosttySharedTerminalMirror.shared.surfaceHostView.frame }

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

            private let onComposer: () -> Void
            private let onPaste: () -> Void
            private let onText: (String) -> Void
            private let onKey: (String) -> Void
            private let onModifier: (AccessoryModifier) -> Void
            private let onKeyboardToggle: () -> Void
            private let toolbarStackView = UIStackView()
            private let scrollView = UIScrollView()
            private let contentStackView = UIStackView()
            private let pinnedStackView = UIStackView()
            private var modifierButtons: [AccessoryModifier: UIButton] = [:]
            private let composerButton = UIButton(type: .system)
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
                onComposer: @escaping () -> Void, onPaste: @escaping () -> Void, onText: @escaping (String) -> Void,
                onKey: @escaping (String) -> Void, onModifier: @escaping (AccessoryModifier) -> Void, onKeyboardToggle: @escaping () -> Void
            ) {
                self.onComposer = onComposer
                self.onPaste = onPaste
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

                addIconButton(imageName: "doc.on.clipboard", accessibilityLabel: "Paste", accessibilityIdentifier: "terminal.accessory.paste") {
                    [weak self] in self?.onPaste()
                }
                addTextButton("tab") { [weak self] in self?.onKey("tab") }
                addTextButton("/") { [weak self] in self?.onText("/") }
                addTextButton("~") { [weak self] in self?.onText("~") }
                addTextButton("|") { [weak self] in self?.onText("|") }
                addTextButton("-") { [weak self] in self?.onText("-") }
                addTextButton("_") { [weak self] in self?.onText("_") }
                addTextButton("esc") { [weak self] in self?.onKey("esc") }
                addModifierButton(.shift)
                addModifierButton(.control)
                addModifierButton(.command)
                addModifierButton(.option)

                configureButton(composerButton, imageName: "plus.bubble")
                composerButton.accessibilityIdentifier = "terminal.accessory.composer"
                composerButton.accessibilityLabel = "Compose message"
                composerButton.addAction(UIAction { [weak self] _ in self?.onComposer() }, for: .touchUpInside)
                pinnedStackView.addArrangedSubview(composerButton)

                configureButton(joystickButton, imageName: "dpad")
                joystickButton.accessibilityIdentifier = "terminal.accessory.arrow-joystick"
                joystickButton.accessibilityLabel = "Arrow key joystick"
                joystickButton.accessibilityHint = "Slide toward a direction to send an arrow key; hold the slide to repeat."
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

            private func addIconButton(imageName: String, accessibilityLabel: String, accessibilityIdentifier: String, action: @escaping () -> Void) {
                let button = UIButton(type: .system)
                configureButton(button, imageName: imageName)
                button.accessibilityLabel = accessibilityLabel
                button.accessibilityIdentifier = accessibilityIdentifier
                button.addAction(UIAction { _ in action() }, for: .touchUpInside)
                contentStackView.addArrangedSubview(button)
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

            func beginJoystickTrackingForTesting(at point: CGPoint, bounds: CGRect, initialDelay: Duration, interval: Duration) {
                joystickButton.repeatInitialDelay = initialDelay
                joystickButton.repeatInterval = interval
                joystickButton.bounds = CGRect(origin: .zero, size: bounds.size)
                joystickButton.beginTrackingForTesting(at: point)
            }

            func moveJoystickTrackingForTesting(to point: CGPoint) { joystickButton.continueTrackingForTesting(at: point) }

            func endJoystickTrackingForTesting() { joystickButton.endTrackingForTesting() }

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
            // How far the finger must slide from where it landed before a direction
            // registers. The control is a relative thumbstick: the touch-down point is the
            // neutral origin, so the swipe direction—not where the press started—decides the
            // arrow key. A stationary tap stays neutral and sends nothing.
            private static let directionActivationDistance: CGFloat = 16

            var onDirection: ((String) -> Void)?

            // Hold-to-repeat cadence, mirroring keyboard key repeat: the first key fires when
            // the swipe crosses the activation distance, then the active direction repeats
            // after an initial delay. Settable so tests can drive the repeat without
            // real-time waits.
            var repeatInitialDelay: Duration = .milliseconds(400)
            var repeatInterval: Duration = .milliseconds(100)

            private var activeDirection: String?
            private var repeatTask: Task<Void, Never>?
            private var trackingOrigin: CGPoint?

            override func point(inside point: CGPoint, with event: UIEvent?) -> Bool { Self.acceptsActivation(at: point, in: bounds) }

            override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
                isHighlighted = true
                trackingOrigin = touch.location(in: self)
                return true
            }

            override func continueTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
                updateTracking(at: touch.location(in: self))
                return true
            }

            override func endTracking(_ touch: UITouch?, with event: UIEvent?) {
                isHighlighted = false
                stopRepeating()
                trackingOrigin = nil
            }

            override func cancelTracking(with event: UIEvent?) {
                isHighlighted = false
                stopRepeating()
                trackingOrigin = nil
            }

            // Updates the held direction from how far the finger has slid since touch-down.
            // Pauses while the touch sits within the neutral zone or strays outside the
            // release area; resumes against the original origin when it slides back in.
            private func updateTracking(at point: CGPoint) {
                guard Self.acceptsRelease(at: point, in: bounds), let origin = trackingOrigin else {
                    isHighlighted = false
                    setActiveDirection(nil)
                    return
                }
                isHighlighted = true
                setActiveDirection(Self.direction(forTranslationX: point.x - origin.x, y: point.y - origin.y))
            }

            // Sets the direction being held, firing it immediately and (re)starting the
            // repeat loop. Passing nil, or releasing, stops the repeat. The fire is
            // synchronous, so a quick flick sends exactly one key before the initial delay.
            private func setActiveDirection(_ direction: String?) {
                guard direction != activeDirection else { return }
                activeDirection = direction
                repeatTask?.cancel()
                guard let direction else {
                    repeatTask = nil
                    return
                }
                onDirection?(direction)
                repeatTask = Task { @MainActor [weak self] in
                    guard let self else { return }
                    try? await Task.sleep(for: self.repeatInitialDelay)
                    while !Task.isCancelled {
                        guard let direction = self.activeDirection else { return }
                        self.onDirection?(direction)
                        try? await Task.sleep(for: self.repeatInterval)
                    }
                }
            }

            private func stopRepeating() {
                repeatTask?.cancel()
                repeatTask = nil
                activeDirection = nil
            }

            func beginTrackingForTesting(at point: CGPoint) {
                isHighlighted = true
                trackingOrigin = point
            }

            func continueTrackingForTesting(at point: CGPoint) { updateTracking(at: point) }

            func endTrackingForTesting() {
                isHighlighted = false
                stopRepeating()
                trackingOrigin = nil
            }

            static func acceptsActivation(at point: CGPoint, in bounds: CGRect) -> Bool {
                bounds.insetBy(dx: -activationHorizontalMargin, dy: -activationVerticalMargin).contains(point)
            }

            static func acceptsRelease(at point: CGPoint, in bounds: CGRect) -> Bool {
                bounds.insetBy(dx: -releaseMargin, dy: -releaseMargin).contains(point)
            }

            static func direction(forTranslationX dx: CGFloat, y dy: CGFloat) -> String? {
                guard abs(dx) > directionActivationDistance || abs(dy) > directionActivationDistance else { return nil }
                if abs(dx) > abs(dy) { return dx < 0 ? "left" : "right" }
                return dy < 0 ? "up" : "down"
            }
        }

    }

#endif
