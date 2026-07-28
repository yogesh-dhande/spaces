#if canImport(AppKit) && canImport(GhosttyKit)
    import AppKit
    import Foundation
    import GhosttyKit
    import spacesterminalcore

    public struct GhosttyTerminalSearchDebugState: Sendable, Equatable {
        public let isVisible: Bool
        public let query: String
        public let total: Int?
        public let selected: Int?

        public init(isVisible: Bool, query: String, total: Int?, selected: Int?) {
            self.isVisible = isVisible
            self.query = query
            self.total = total
            self.selected = selected
        }
    }

    @MainActor private final class GhosttyMirrorSurfaceHostView: NSView { override func hitTest(_ point: NSPoint) -> NSView? { nil } }

    @MainActor final class GhosttyMirrorTerminalView: NSView, NSSearchFieldDelegate {
        typealias SendTextHandler = @MainActor (String, Bool) -> Void
        typealias SendKeyHandler = @MainActor (String) -> Void
        typealias SendScrollHandler = @MainActor (CGFloat, CGFloat, Int32, TerminalScrollPointerPosition?) -> Void
        typealias SendMouseButtonHandler = @MainActor (UInt8, Bool, TerminalScrollPointerPosition?) -> Void
        typealias ViewportSizeHandler = @MainActor (Int, Int) -> Void

        private struct SurfaceGeometry: Equatable {
            let width: UInt32
            let height: UInt32
            let scale: Double
            let displayID: UInt32?
            let windowNumber: Int?
        }

        private struct CellMetrics: Equatable {
            let width: CGFloat
            let height: CGFloat
        }

        private struct AppliedRenderFrameIdentity: Equatable {
            let renderStateKey: String
            let version: Int
            let sessionRevision: UInt64?
            let ownerEpoch: UInt64
            let columns: Int
            let rows: Int
            let snapshot: GhosttyTerminalSnapshot?
        }

        private static let defaultFontSize: CGFloat = 12
        private static let searchUpBindingAction = "navigate_search:next"
        private static let searchDownBindingAction = "navigate_search:previous"
        private static let shortSearchQueryDebounceDelay: Duration = .milliseconds(300)

        private let launchConfiguration: TerminalSessionLaunchConfiguration
        private let surfaceHostView = GhosttyMirrorSurfaceHostView(frame: .zero)
        private let searchOverlay = NSVisualEffectView()
        private let searchField = NSSearchField()
        private let searchStatusLabel = NSTextField(labelWithString: "")
        private let searchUpButton = NSButton()
        private let searchDownButton = NSButton()
        private let searchCloseButton = NSButton()
        private var mirror: ghostty_mirror_t?
        private var latestFrame: GhosttyRenderFrame?
        private var renderStateKey = ""
        private var lastGeometry: SurfaceGeometry?
        private var lastAppliedRenderFrameIdentity: AppliedRenderFrameIdentity?
        private var lastReportedViewportSize: (columns: Int, rows: Int)?
        private var renderedText = ""
        private var pendingSurfacePresentationTask: Task<Void, Never>?
        private var pendingFirstResponderRestoreTask: Task<Void, Never>?
        private var pendingSearchQueryTask: Task<Void, Never>?
        private var mouseTrackingArea: NSTrackingArea?
        private var windowVisibilityObservation: NSKeyValueObservation?
        private var searchTotal: Int?
        private var searchSelected: Int?
        private var submittedSearchQuery: String?
        private var suppressedFocusOnlyMouseButtonNumbers = Set<Int>()
        private var hoveredLink: String? {
            didSet {
                guard hoveredLink != oldValue else { return }
                window?.invalidateCursorRects(for: self)
                if hoveredLink != nil { NSCursor.pointingHand.set() }
            }
        }
        var debugBindingActionHandler: (@MainActor (String) -> Bool)?
        private(set) var debugRecordedBindingActions: [String] = []
        var debugMouseEventHandler: (@MainActor (String) -> Bool)?
        /// Stands in for the live mirror surface's mouse-capture state, which only exists once a real
        /// surface has applied a frame.
        var debugMouseCapturedForTesting: Bool?
        private(set) var debugRecordedMouseEvents: [String] = []
        var debugRenderFrameApplyHandler: (@MainActor (GhosttyRenderFrame, String) -> Bool)?
        private(set) var debugRenderFrameApplyCount = 0
        var debugOpenURLHandler: (@MainActor (URL) -> Bool)?

        /// Per-pane link router installed by `RemoteGhosttySessionHost`. When set it fully replaces the
        /// legacy local-only `GhosttyTerminalLinkOpener.open` path for `.openURL` action events, so the
        /// coordinator can route web/loopback/remote-file links (fetch-over-Device-API, loopback notice).
        /// Left nil in contexts with no coordinator (tests, non-device hosts), where the legacy opener
        /// and its `debugOpenURLHandler` test seam still apply.
        var onOpenLink: (@MainActor (String) -> Void)?
        var acceptsTerminalInput = false { didSet { restoreFirstResponderIfWindowReady() } }
        var onSendText: SendTextHandler?
        var onSendKey: SendKeyHandler?
        var onSendScroll: SendScrollHandler?
        var onSendMouseButton: SendMouseButtonHandler?
        var onViewportSizeChanged: ViewportSizeHandler?

        init(launchConfiguration: TerminalSessionLaunchConfiguration) {
            self.launchConfiguration = launchConfiguration
            super.init(frame: .zero)
            wantsLayer = true
            layer?.backgroundColor = NSColor.activeTheme(\.terminal.background).cgColor
            installSurfaceHostView()
            installSearchOverlay()
        }

        @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        deinit {
            MainActor.assumeIsolated {
                pendingFirstResponderRestoreTask?.cancel()
                pendingSearchQueryTask?.cancel()
                pendingSurfacePresentationTask?.cancel()
                if let surface = mirrorSurface() { GhosttyMirrorAppService.shared.unregisterActionHandler(for: surface) }
                if let mirror { ghostty_mirror_free(mirror) }
            }
        }

        override var acceptsFirstResponder: Bool { acceptsTerminalInput }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        /// Whether this pane has terminal content to show. A pane holds a mirror only while it is on
        /// screen, so holding none is no evidence of having nothing to render: an off-screen pane keeps
        /// its frame and builds or rebuilds the surface the moment it is displayed. Reporting otherwise
        /// would strand it, because the two conditions depend on each other — the pane controller
        /// unhides the terminal container only for a pane that reports content, and the pane builds its
        /// surface only once that container is unhidden. A pane that is on screen and still holds no
        /// mirror is the one genuine failure: surface creation did not succeed and there is nothing to
        /// render.
        var hasRenderedContent: Bool { latestFrame != nil && (mirror != nil || !isDisplayed) }

        /// Whether this pane is on screen. Two things take a pane off screen without changing its window
        /// membership, and both leave its surface rendering to nobody at full cost. A miniaturized,
        /// ordered-out, or app-hidden window leaves every one of its views with the same non-nil
        /// `window`. And the pane controller switches a pane to its status or text renderer by hiding
        /// the container above this view inside a window that stays perfectly visible — a viewer pane,
        /// which only ever shows a takeover prompt, sits there for as long as another client owns the
        /// session.
        var isDisplayed: Bool { window?.isVisible == true && !isHiddenOrHasHiddenAncestor }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observeWindowVisibility()
            applyDisplayState()
        }

        /// AppKit sends these whether this view or any ancestor of it was hidden, which is how the pane
        /// notices the renderer switch hiding the container above it. They say nothing about a window
        /// leaving the screen; `windowVisibilityObservation` covers that.
        override func viewDidHide() {
            super.viewDidHide()
            applyDisplayState()
        }

        override func viewDidUnhide() {
            super.viewDidUnhide()
            applyDisplayState()
        }

        /// A window's visibility changes with no view-hierarchy event of any kind — it is miniaturized,
        /// ordered out, or hidden along with the app while its views keep the same `window` — so the
        /// pane watches the window itself to notice becoming hidden and coming back.
        private func observeWindowVisibility() {
            windowVisibilityObservation = window?.observe(\.isVisible) { [weak self] _, _ in MainActor.assumeIsolated { self?.applyDisplayState() } }
        }

        private func applyDisplayState() {
            guard isDisplayed else {
                lastGeometry = nil
                updateSurfaceFocus()
                GhosttyMirrorSurfaceMRU.shared.noteHidden()
                return
            }
            GhosttyMirrorSurfaceMRU.shared.noteDisplayed(self)
            ensureMirrorIfNeeded()
            updateSurfaceGeometry()
            reportViewportSizeIfNeeded()
            applyLatestFrameIfPossible()
            restoreFirstResponderIfWindowReady()
        }

        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            ensureMirrorIfNeeded()
            updateSurfaceGeometry()
            reportViewportSizeIfNeeded()
        }

        override func viewDidChangeBackingProperties() {
            super.viewDidChangeBackingProperties()
            updateSurfaceGeometry()
        }

        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            updateSearchOverlayAppearance()
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let mouseTrackingArea {
                removeTrackingArea(mouseTrackingArea)
                self.mouseTrackingArea = nil
            }
            let trackingArea = NSTrackingArea(
                rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
            addTrackingArea(trackingArea)
            mouseTrackingArea = trackingArea
        }

        override func resetCursorRects() {
            super.resetCursorRects()
            addCursorRect(bounds, cursor: hoveredLink == nil ? .iBeam : .pointingHand)
        }

        override func mouseDown(with event: NSEvent) {
            if suppressesFocusOnlyMousePress(for: event) { return }
            focusWindow()
            sendMousePosition(event)
            _ = sendMouseButton(state: GHOSTTY_MOUSE_PRESS, button: GHOSTTY_MOUSE_LEFT, event: event)
        }

        override func mouseUp(with event: NSEvent) {
            if suppressesFocusOnlyMouseRelease(for: event) { return }
            sendMousePosition(event)
            _ = sendMouseButton(state: GHOSTTY_MOUSE_RELEASE, button: GHOSTTY_MOUSE_LEFT, event: event)
        }

        override func rightMouseDown(with event: NSEvent) {
            if suppressesFocusOnlyMousePress(for: event) { return }
            focusWindow()
            sendMousePosition(event)
            if !sendMouseButton(state: GHOSTTY_MOUSE_PRESS, button: GHOSTTY_MOUSE_RIGHT, event: event) { super.rightMouseDown(with: event) }
        }

        override func rightMouseUp(with event: NSEvent) {
            if suppressesFocusOnlyMouseRelease(for: event) { return }
            sendMousePosition(event)
            if !sendMouseButton(state: GHOSTTY_MOUSE_RELEASE, button: GHOSTTY_MOUSE_RIGHT, event: event) { super.rightMouseUp(with: event) }
        }

        override func otherMouseDown(with event: NSEvent) {
            if suppressesFocusOnlyMousePress(for: event) { return }
            focusWindow()
            sendMousePosition(event)
            _ = sendMouseButton(state: GHOSTTY_MOUSE_PRESS, button: Self.ghosttyMouseButton(for: event.buttonNumber), event: event)
        }

        override func otherMouseUp(with event: NSEvent) {
            if suppressesFocusOnlyMouseRelease(for: event) { return }
            sendMousePosition(event)
            _ = sendMouseButton(state: GHOSTTY_MOUSE_RELEASE, button: Self.ghosttyMouseButton(for: event.buttonNumber), event: event)
        }

        override func mouseMoved(with event: NSEvent) { sendMousePosition(event) }

        override func mouseDragged(with event: NSEvent) { sendMousePosition(event) }

        override func rightMouseDragged(with event: NSEvent) { sendMousePosition(event) }

        override func otherMouseDragged(with event: NSEvent) { sendMousePosition(event) }

        override func mouseExited(with event: NSEvent) {
            hoveredLink = nil
            guard let surface = mirrorSurface() else { return }
            guard NSEvent.pressedMouseButtons == 0 else { return }
            ghostty_surface_mouse_pos(surface, -1, -1, Self.ghosttyMouseModifiers(for: event.modifierFlags))
            ghostty_surface_refresh(surface)
        }

        override func scrollWheel(with event: NSEvent) {
            let scrollMods = Self.makeScrollMods(hasPreciseDeltas: event.hasPreciseScrollingDeltas, phase: event.momentumPhase)
            let pointerPosition = Self.scrollPointerPosition(
                for: event.locationInWindow, in: self, mods: Self.ghosttyMouseModifiers(for: event.modifierFlags).rawValue)
            onSendScroll?(event.scrollingDeltaX, event.scrollingDeltaY, scrollMods, pointerPosition)
        }

        override func keyDown(with event: NSEvent) {
            if handleTerminalKeyEvent(event) { return }
            super.keyDown(with: event)
        }

        @discardableResult func handleTerminalKeyEvent(_ event: NSEvent, requireFirstResponder: Bool = true) -> Bool {
            guard event.type == .keyDown, acceptsTerminalInput, window?.isKeyWindow == true else {
                TerminalPerformance.logLine(
                    "spaces: input_trace point=mirror_guard keycode=\(event.keyCode) accepts=\(acceptsTerminalInput ? 1 : 0) "
                        + "key_window=\(window?.isKeyWindow == true ? 1 : 0)\n")
                return false
            }
            if GhosttyTerminalInputTranslator.shouldDeferToSystemShortcut(keyCode: event.keyCode, modifierFlags: event.modifierFlags) { return false }
            if !requireFirstResponder, window?.firstResponder !== self { window?.makeFirstResponder(self) }
            guard !requireFirstResponder || canProcessTerminalInput else {
                TerminalPerformance.logLine("spaces: input_trace point=mirror_can_process keycode=\(event.keyCode) drop=1\n")
                return false
            }
            guard canProcessTerminalInput else {
                TerminalPerformance.logLine("spaces: input_trace point=mirror_can_process2 keycode=\(event.keyCode) drop=1\n")
                return false
            }
            if let keySpec = Self.remoteKeySpecifier(for: event) {
                onSendKey?(keySpec)
                return true
            }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if flags.contains(.command) { return false }
            if let characters = GhosttyTerminalInputTranslator.ghosttyText(for: event), !characters.isEmpty {
                onSendText?(characters, false)
                return true
            }
            return false
        }

        /// False once the session's runtime state stops being interactive. A process that exits or
        /// crashes with mouse tracking enabled leaves its final frame carrying live tracking flags,
        /// and applying those to the mirror would keep consuming clicks (suppressing local text
        /// selection) with no application left to receive them. Flipping this re-applies the latest
        /// frame with the capture flags stripped.
        var sessionPermitsMouseCapture = true {
            didSet {
                guard sessionPermitsMouseCapture != oldValue else { return }
                guard latestFrame?.snapshot.mouseReportingActive == true else { return }
                lastAppliedRenderFrameIdentity = nil
                applyLatestFrameIfPossible()
            }
        }

        func update(frame: GhosttyRenderFrame?, renderStateKey: String) {
            if self.renderStateKey != renderStateKey { renderedText = "" }
            self.renderStateKey = renderStateKey
            latestFrame = frame
            renderedText = frame.map { GhosttyTerminalSnapshotGrid.fullPlainText(for: $0.snapshot) } ?? ""
            ensureMirrorIfNeeded()
            applyLatestFrameIfPossible()
            restoreFirstResponderIfWindowReady()
        }

        func update(snapshot: GhosttyTerminalSnapshot?, renderStateKey: String) {
            let frame = snapshot.map { GhosttyRenderFrame(sessionRevision: nil, ownerEpoch: 0, snapshot: $0) }
            update(frame: frame, renderStateKey: renderStateKey)
        }

        func snapshot() -> GhosttyTerminalSnapshot? {
            if let surface = mirrorSurface(), let captured = GhosttyTerminalSnapshotCapture.captureFromSurface(surface) { return captured }
            return latestFrame?.snapshot
        }

        func snapshotText() -> String? {
            if let surfaceText = GhosttyTerminalSnapshotCapture.captureText(from: mirrorSurface()), !surfaceText.isEmpty { return surfaceText }
            if !renderedText.isEmpty { return renderedText }
            guard let snapshot = latestFrame?.snapshot else { return nil }
            return GhosttyTerminalSnapshotGrid.fullPlainText(for: snapshot)
        }

        func renderedSnapshotText() -> String? { snapshotText() }
        var hasRenderedSurfaceContent: Bool { latestFrame != nil }

        func surfaceCellSize() -> (columns: Int, rows: Int)? {
            ensureMirrorIfNeeded()
            updateSurfaceGeometry()
            if let surface = mirrorSurface() {
                let size = ghostty_surface_size(surface)
                if size.columns > 0, size.rows > 0 { return (Int(size.columns), Int(size.rows)) }
            }
            // An off-screen pane has not changed size and holds no surface to measure. The estimate
            // below measures a different font from the one Ghostty renders with, so reporting it would
            // resize the session to a grid it never rendered at; the real grid returns with the surface
            // that is built when the pane is displayed again.
            guard isDisplayed else { return nil }
            let metrics = cellMetrics()
            guard bounds.width > 0, bounds.height > 0, metrics.width > 0, metrics.height > 0 else { return nil }
            return (max(Int(floor(bounds.width / metrics.width)), 1), max(Int(floor(bounds.height / metrics.height)), 1))
        }

        func copySelectionToPasteboard() -> Bool { GhosttyClipboardBridge.copySelection(from: mirrorSurface()) }

        /// Unit tests inject a uniquely-named pasteboard here so paste tests never touch the user's
        /// real clipboard. Nil in the app, where paste keeps using `NSPasteboard.general`.
        var pasteboardOverrideForTesting: NSPasteboard?

        func pasteClipboardContents() -> Bool {
            guard acceptsTerminalInput else { return false }
            guard let text = (pasteboardOverrideForTesting ?? .general).string(forType: .string), !text.isEmpty else { return false }
            onSendText?(text, true)
            return true
        }

        @discardableResult func sendScroll(
            horizontal: CGFloat, vertical: CGFloat, scrollMods: Int32 = 0, pointerPosition: TerminalScrollPointerPosition? = nil
        ) -> Bool {
            onSendScroll?(horizontal, vertical, scrollMods, pointerPosition)
            return true
        }

        @discardableResult func performBindingAction(_ action: String) -> Bool {
            let performed = sendBindingAction(action)
            guard performed || action == "end_search" else { return false }
            applySearchSideEffect(for: action)
            return performed || action == "end_search"
        }

        func applyActionEvent(_ event: GhosttyActionEvent) {
            switch event {
            case .openURL(_, let value):
                if let onOpenLink { onOpenLink(value) } else { _ = GhosttyTerminalLinkOpener.open(value, openURL: debugOpenURLHandler) }
            case .mouseOverLink(let value): hoveredLink = value
            case .startSearch(let needle): showSearchOverlay(query: needle, submitSeededQuery: needle != nil)
            case .endSearch: hideSearchOverlay()
            case .searchTotal(let total):
                guard acceptsSearchResultEvent else { return }
                searchTotal = total
                updateSearchStatusLabel()
            case .searchSelected(let selected):
                guard acceptsSearchResultEvent else { return }
                searchSelected = selected
                updateSearchStatusLabel()
            case .setTitle, .setWorkingDirectory: break
            }
        }

        var debugSearchState: GhosttyTerminalSearchDebugState {
            .init(isVisible: !searchOverlay.isHidden, query: searchField.stringValue, total: searchTotal, selected: searchSelected)
        }

        static func makeScrollMods(hasPreciseDeltas: Bool, phase: NSEvent.Phase) -> Int32 {
            TerminalScrollModifiers.make(hasPreciseDeltas: hasPreciseDeltas, momentumPhase: scrollMomentumPhase(for: phase))
        }

        private static func scrollMomentumPhase(for phase: NSEvent.Phase) -> TerminalScrollMomentumPhase {
            guard !phase.isEmpty else { return .none }
            if phase.contains(.mayBegin) { return .mayBegin }
            if phase.contains(.cancelled) { return .cancelled }
            if phase.contains(.ended) { return .ended }
            return .changed
        }

        func focusWindow(_ window: NSWindow?) {
            guard let window else { return }
            if searchOverlayIsVisible {
                if !window.isKeyWindow { window.makeKeyAndOrderFront(nil) }
                if !searchFieldHasFocus {
                    window.makeFirstResponder(searchField)
                    searchField.selectText(nil)
                }
                updateSurfaceFocus()
                return
            }
            if window.firstResponder !== self { window.makeFirstResponder(self) }
            if !window.isKeyWindow { window.makeKeyAndOrderFront(nil) }
            updateSurfaceFocus()
        }

        /// Tears the pane's rendering down for good: the mirror is freed, the render state is dropped,
        /// and the view leaves its container. Driven by ownership and attachment transitions, never by
        /// visibility — a pane that is merely hidden goes through `evictMirrorSurface` instead.
        func releaseSurface() {
            freeMirror()
            latestFrame = nil
            renderedText = ""
            GhosttyMirrorSurfaceMRU.shared.forget(self)
            removeFromSuperview()
        }

        /// Frees the mirror and its IOSurface buffers when this pane falls past the warm-surface cap,
        /// while keeping the view able to rebuild itself. The retained frame is a full grid, so becoming
        /// displayed again recreates the mirror and repaints it from that frame without needing a
        /// resync from the session host.
        func evictMirrorSurface() { freeMirror() }

        private func freeMirror() {
            // The find overlay's matches live in the surface, so its state cannot outlive the mirror.
            resetSearchOverlay(restoreFocus: false)
            pendingSurfacePresentationTask?.cancel()
            pendingSurfacePresentationTask = nil
            if let surface = mirrorSurface() { GhosttyMirrorAppService.shared.unregisterActionHandler(for: surface) }
            if let mirror {
                ghostty_mirror_free(mirror)
                self.mirror = nil
            }
            lastGeometry = nil
            lastAppliedRenderFrameIdentity = nil
        }

        private var canProcessTerminalInput: Bool { acceptsTerminalInput && window?.isKeyWindow == true && window?.firstResponder === self }
        private var searchOverlayIsVisible: Bool { !searchOverlay.isHidden }
        private var acceptsSearchResultEvent: Bool {
            guard searchOverlayIsVisible, let submittedSearchQuery, !submittedSearchQuery.isEmpty else { return false }
            return submittedSearchQuery == searchField.stringValue
        }

        private var searchFieldHasFocus: Bool {
            guard let window else { return false }
            return window.firstResponder === searchField || window.firstResponder === searchField.currentEditor()
        }

        private func focusWindow() { focusWindow(window) }

        func restoreFirstResponderIfWindowReady(deferIfNeeded: Bool = true) {
            guard acceptsTerminalInput, let window, window.isKeyWindow else {
                updateSurfaceFocus()
                return
            }
            guard !searchOverlayIsVisible else {
                updateSurfaceFocus()
                return
            }
            // Reclaim focus only when it fell back to the window itself (mirror
            // re-parenting resigns it during structural updates). This runs on every
            // render frame for every attached owner pane, so grabbing focus
            // unconditionally would continuously steal it from sibling panes and from
            // other controls in the window (the tab rename editor, sidebar editors).
            guard window.firstResponder === window else {
                updateSurfaceFocus()
                return
            }
            window.makeFirstResponder(self)
            updateSurfaceFocus()
            if deferIfNeeded { scheduleDeferredFirstResponderRestore() }
        }

        private func scheduleDeferredFirstResponderRestore() {
            guard pendingFirstResponderRestoreTask == nil else { return }
            pendingFirstResponderRestoreTask = Task { @MainActor [weak self] in
                await Task.yield()
                guard let self else { return }
                self.pendingFirstResponderRestoreTask = nil
                self.restoreFirstResponderIfWindowReady(deferIfNeeded: false)
            }
        }

        private func installSurfaceHostView() {
            surfaceHostView.translatesAutoresizingMaskIntoConstraints = false
            surfaceHostView.wantsLayer = true
            addSubview(surfaceHostView, positioned: .below, relativeTo: nil)
            NSLayoutConstraint.activate([
                surfaceHostView.topAnchor.constraint(equalTo: topAnchor), surfaceHostView.leadingAnchor.constraint(equalTo: leadingAnchor),
                surfaceHostView.trailingAnchor.constraint(equalTo: trailingAnchor), surfaceHostView.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
        }

        private func installSearchOverlay() {
            searchOverlay.translatesAutoresizingMaskIntoConstraints = false
            searchOverlay.material = .hudWindow
            searchOverlay.blendingMode = .withinWindow
            searchOverlay.state = .active
            searchOverlay.isHidden = true
            searchOverlay.wantsLayer = true
            searchOverlay.layer?.cornerRadius = 7
            searchOverlay.layer?.masksToBounds = false
            searchOverlay.layer?.shadowColor = NSColor.black.cgColor
            searchOverlay.layer?.shadowOpacity = 0.22
            searchOverlay.layer?.shadowRadius = 10
            searchOverlay.layer?.shadowOffset = NSSize(width: 0, height: -1)
            updateSearchOverlayAppearance()

            searchField.translatesAutoresizingMaskIntoConstraints = false
            searchField.delegate = self
            searchField.placeholderString = "Find"
            searchField.sendsSearchStringImmediately = true
            searchField.target = self
            searchField.action = #selector(searchFieldAction)
            searchField.setAccessibilityIdentifier("terminal-search-field")

            searchStatusLabel.translatesAutoresizingMaskIntoConstraints = false
            searchStatusLabel.font = .systemFont(ofSize: 11)
            searchStatusLabel.textColor = .secondaryLabelColor
            searchStatusLabel.alignment = .center
            searchStatusLabel.isHidden = true
            searchStatusLabel.setContentHuggingPriority(.required, for: .horizontal)
            searchStatusLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

            configureSearchButton(searchUpButton, symbolName: "chevron.up", action: #selector(searchUpAction), tooltip: "Find Up")
            configureSearchButton(searchDownButton, symbolName: "chevron.down", action: #selector(searchDownAction), tooltip: "Find Down")
            configureSearchButton(searchCloseButton, symbolName: "xmark", action: #selector(searchCloseAction), tooltip: "Close Find")

            let stackView = NSStackView(views: [searchField, searchStatusLabel, searchUpButton, searchDownButton, searchCloseButton])
            stackView.translatesAutoresizingMaskIntoConstraints = false
            stackView.orientation = .horizontal
            stackView.alignment = .centerY
            stackView.spacing = 6
            stackView.detachesHiddenViews = true
            searchOverlay.addSubview(stackView)
            addSubview(searchOverlay)

            NSLayoutConstraint.activate([
                searchOverlay.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
                searchOverlay.topAnchor.constraint(equalTo: topAnchor, constant: 12),
                searchOverlay.widthAnchor.constraint(lessThanOrEqualToConstant: 360),
                stackView.topAnchor.constraint(equalTo: searchOverlay.topAnchor, constant: 6),
                stackView.leadingAnchor.constraint(equalTo: searchOverlay.leadingAnchor, constant: 8),
                stackView.trailingAnchor.constraint(equalTo: searchOverlay.trailingAnchor, constant: -8),
                stackView.bottomAnchor.constraint(equalTo: searchOverlay.bottomAnchor, constant: -6),
                searchField.widthAnchor.constraint(equalToConstant: 180),
            ])
        }

        private func configureSearchButton(_ button: NSButton, symbolName: String, action: Selector, tooltip: String) {
            button.translatesAutoresizingMaskIntoConstraints = false
            button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: tooltip)
            button.imagePosition = .imageOnly
            button.isBordered = false
            button.contentTintColor = .secondaryLabelColor
            button.target = self
            button.action = action
            button.toolTip = tooltip
            button.setButtonType(.momentaryPushIn)
            NSLayoutConstraint.activate([button.widthAnchor.constraint(equalToConstant: 24), button.heightAnchor.constraint(equalToConstant: 24)])
        }

        private func updateSearchOverlayAppearance() {
            let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let backgroundColor = isDark ? NSColor(calibratedWhite: 0.10, alpha: 0.88) : NSColor(calibratedWhite: 0.98, alpha: 0.92)
            searchOverlay.layer?.backgroundColor = backgroundColor.cgColor
            searchOverlay.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(isDark ? 0.32 : 0.55).cgColor
            searchOverlay.layer?.borderWidth = 0.5
        }

        private func ensureMirrorIfNeeded() {
            guard mirror == nil, isDisplayed else { return }
            do {
                try GhosttyMirrorAppService.shared.startIfNeeded()
                guard let app = GhosttyMirrorAppService.shared.app else { throw GhosttyEmbeddedAppServiceError.configuration("ghostty app missing") }
                var host = makeSurfaceHost()
                var config = ghostty_session_config_new()
                config.surface.platform_tag = host.platform_tag
                config.surface.platform = host.platform
                config.surface.scale_factor = host.scale_factor
                config.surface.context = GHOSTTY_SURFACE_CONTEXT_WINDOW
                // Host-managed with no receive_buffer on purpose: the fork's HostManaged write path
                // drops writes with no callback, so mouse reports the mirror encodes locally (its
                // restored tracking flags collapse every mode to normal/X10) can never reach any
                // consumer — only the on/off capture bit changes mirror behavior. Likewise the
                // exported flag reads the application-requested mode, not the surface's effective
                // policy: daemon sessions run Spaces-generated config that never sets
                // mouse-reporting=false or binds toggle_mouse_reporting, so the two cannot diverge.
                config.surface.backend = GHOSTTY_SURFACE_IO_BACKEND_HOST_MANAGED
                config.parked_host = host
                mirror = ghostty_mirror_new(app, &host, &config)
                guard mirror != nil else { throw GhosttyEmbeddedAppServiceError.configuration("ghostty_mirror_new failed") }
                lastGeometry = nil
                lastAppliedRenderFrameIdentity = nil
                updateSurfaceGeometry()
                updateSurfaceFocus()
                if let surface = mirrorSurface() {
                    GhosttyMirrorAppService.shared.registerActionHandler(for: surface) { [weak self] event in self?.applyActionEvent(event) }
                }
            } catch { fputs("spaces: ghostty mirror creation failed for session \(launchConfiguration.sessionID): \(error)\n", stderr) }
        }

        private func makeSurfaceHost() -> ghostty_surface_host_s {
            var host = ghostty_surface_host_s()
            host.platform_tag = GHOSTTY_PLATFORM_MACOS
            host.platform = ghostty_platform_u(macos: ghostty_platform_macos_s(nsview: Unmanaged.passUnretained(surfaceHostView).toOpaque()))
            host.scale_factor = Double(window?.backingScaleFactor ?? 2.0)
            return host
        }

        private func mirrorSurface() -> ghostty_surface_t? {
            guard let mirror else { return nil }
            return ghostty_mirror_surface(mirror)
        }

        @discardableResult private func sendMouseButton(state: ghostty_input_mouse_state_e, button: ghostty_input_mouse_button_e, event: NSEvent)
            -> Bool
        {
            // The mirror sees the button first: it carries the session terminal's mouse-tracking flags,
            // so it performs Ghostty's own selection-versus-report arbitration (clearing the selection
            // and resetting the click gesture while an application tracks the mouse) before the same
            // click is forwarded to the session that can actually deliver it.
            let consumed = deliverMouseButtonToMirror(state: state, button: button, event: event)
            forwardMouseButtonIfReported(state: state, button: button, event: event)
            return consumed
        }

        @discardableResult private func deliverMouseButtonToMirror(
            state: ghostty_input_mouse_state_e, button: ghostty_input_mouse_button_e, event: NSEvent
        ) -> Bool {
            if let debugMouseEventHandler {
                let stateDescription = state.rawValue == GHOSTTY_MOUSE_PRESS.rawValue ? "press" : "release"
                let description = "button:\(stateDescription):\(button.rawValue)"
                debugRecordedMouseEvents.append(description)
                return debugMouseEventHandler(description)
            }
            guard let surface = mirrorSurface() else { return false }
            let consumed = ghostty_surface_mouse_button(surface, state, button, Self.ghosttyMouseModifiers(for: event.modifierFlags))
            ghostty_surface_refresh(surface)
            return consumed
        }

        /// Sends the click on to the session's own terminal when a mouse-aware application there is
        /// tracking the mouse. This repeats the condition Ghostty's surface uses to decide it should
        /// emit a mouse report, which is the same decision the mirror just made locally.
        private func forwardMouseButtonIfReported(state: ghostty_input_mouse_state_e, button: ghostty_input_mouse_button_e, event: NSEvent) {
            guard let onSendMouseButton, mouseButtonBelongsToSession(modifierFlags: event.modifierFlags) else { return }
            let mods = Self.ghosttyMouseModifiers(for: event.modifierFlags)
            let pointerPosition = Self.scrollPointerPosition(for: event.locationInWindow, in: self, mods: mods.rawValue)
            onSendMouseButton(UInt8(clamping: button.rawValue), state.rawValue == GHOSTTY_MOUSE_PRESS.rawValue, pointerPosition)
        }

        /// True when the application on the other end owns this click. Shift is the local escape hatch:
        /// Spaces leaves Ghostty's `mouse-shift-capture` at its `false` default, so shift keeps the
        /// click for selection unless the terminal itself asked for shift to be captured.
        private func mouseButtonBelongsToSession(modifierFlags: NSEvent.ModifierFlags) -> Bool {
            // Checked here as well as at frame apply so the decision is right even for a final
            // frame that raced ahead of the runtime-state update that ended the session.
            guard sessionPermitsMouseCapture else { return false }
            guard mirrorCapturesMouse else { return false }
            guard modifierFlags.contains(.shift) else { return true }
            return latestFrame?.snapshot.mouseShiftCapture == GhosttyTerminalSnapshot.mouseShiftCaptureEnabled
        }

        private var mirrorCapturesMouse: Bool {
            if let debugMouseCapturedForTesting { return debugMouseCapturedForTesting }
            guard let surface = mirrorSurface() else { return false }
            return ghostty_surface_mouse_captured(surface)
        }

        private func sendMousePosition(_ event: NSEvent) {
            if let debugMouseEventHandler {
                debugRecordedMouseEvents.append("position")
                _ = debugMouseEventHandler("position")
                return
            }
            guard let surface = mirrorSurface() else { return }
            let position = Self.ghosttyMousePosition(for: event.locationInWindow, in: self)
            ghostty_surface_mouse_pos(surface, position.x, position.y, Self.ghosttyMouseModifiers(for: event.modifierFlags))
            ghostty_surface_refresh(surface)
        }

        private func suppressesFocusOnlyMousePress(for event: NSEvent) -> Bool {
            guard let window, !window.isKeyWindow else { return false }
            suppressedFocusOnlyMouseButtonNumbers.insert(event.buttonNumber)
            focusWindow(window)
            return true
        }

        private func suppressesFocusOnlyMouseRelease(for event: NSEvent) -> Bool {
            suppressedFocusOnlyMouseButtonNumbers.remove(event.buttonNumber) != nil
        }

        private func updateSurfaceGeometry() {
            guard let mirror, let surface = mirrorSurface(), let backingSize = backingPixelSize() else { return }
            let scale = Double(window?.backingScaleFactor ?? 2.0)
            let displayID = (window?.screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
            let geometry = SurfaceGeometry(
                width: backingSize.width, height: backingSize.height, scale: scale, displayID: displayID, windowNumber: window?.windowNumber)
            guard geometry != lastGeometry else { return }

            var host = makeSurfaceHost()
            _ = ghostty_mirror_set_host(mirror, &host)
            ghostty_surface_set_content_scale(surface, scale, scale)
            if let displayID { ghostty_surface_set_display_id(surface, displayID) }
            ghostty_surface_set_size(surface, geometry.width, geometry.height)
            ghostty_surface_set_occlusion(surface, window?.occlusionState.contains(.visible) ?? true)
            ghostty_surface_refresh(surface)
            lastGeometry = geometry
        }

        private func backingPixelSize() -> (width: UInt32, height: UInt32)? {
            let size = convertToBacking(bounds).size
            let width = Int(floor(size.width))
            let height = Int(floor(size.height))
            guard width > 0, height > 0 else { return nil }
            return (UInt32(width), UInt32(height))
        }

        private func updateSurfaceFocus() {
            guard let surface = mirrorSurface() else { return }
            ghostty_surface_set_focus(surface, canProcessTerminalInput)
            ghostty_surface_refresh(surface)
        }

        private func reportViewportSizeIfNeeded() {
            guard let size = surfaceCellSize() else { return }
            guard lastReportedViewportSize?.columns != size.columns || lastReportedViewportSize?.rows != size.rows else { return }
            lastReportedViewportSize = size
            onViewportSizeChanged?(size.columns, size.rows)
        }

        private func applyLatestFrameIfPossible() {
            guard let frame = latestFrame else {
                lastAppliedRenderFrameIdentity = nil
                return
            }
            let identity = appliedRenderFrameIdentity(for: frame)
            guard identity != lastAppliedRenderFrameIdentity else { return }
            if let debugRenderFrameApplyHandler {
                guard debugRenderFrameApplyHandler(frame, renderStateKey) else { return }
                lastAppliedRenderFrameIdentity = identity
                debugRenderFrameApplyCount += 1
                return
            }
            guard let mirror else { return }
            updateSurfaceGeometry()
            let applyStartedAt = Date()
            let applied = withCFrame(frame) { cFrame in ghostty_mirror_apply_render_frame(mirror, cFrame) }
            let applyMS = TerminalPerformance.elapsedMS(since: applyStartedAt)
            let attributes = GhosttyRenderFrameMetrics.attributes(
                frame: frame, dropped: !applied, dropReason: applied ? nil : "mirror_apply_failed", renderMode: "ghostty-mirror",
                targetRevision: frame.sessionRevision, appliedRevision: applied ? frame.sessionRevision : nil, applyMS: applyMS)
            SpacesDeviceTerminalPerformanceLogger.emit(
                .init(
                    sessionID: launchConfiguration.sessionID, source: "mac-mirror", name: "render_frame_mirror_apply", elapsedMS: applyMS,
                    attributes: attributes))
            TerminalPerformance.logMetric(
                "terminal_render_frame_mirror_apply", target: "session=\(launchConfiguration.sessionID)", elapsedMS: applyMS, success: applied,
                detail: GhosttyRenderFrameMetrics.detailString(attributes))
            guard applied else {
                fputs("spaces: ghostty mirror frame apply failed for session \(launchConfiguration.sessionID)\n", stderr)
                return
            }
            lastAppliedRenderFrameIdentity = identity
            GhosttyMirrorAppService.shared.tick()
            presentSurfaceNow()
            GhosttyMirrorAppService.shared.tick()
            surfaceHostView.needsDisplay = true
            surfaceHostView.displayIfNeeded()
            window?.displayIfNeeded()
            scheduleSurfacePresentationRefresh()
        }

        private func scheduleSurfacePresentationRefresh() {
            pendingSurfacePresentationTask?.cancel()
            pendingSurfacePresentationTask = Task { @MainActor [weak self] in
                await Task.yield()
                guard let self, !Task.isCancelled else { return }
                self.pendingSurfacePresentationTask = nil
                guard let surface = self.mirrorSurface() else { return }
                ghostty_surface_refresh(surface)
                ghostty_surface_draw(surface)
                GhosttyMirrorAppService.shared.tick()
                self.surfaceHostView.needsDisplay = true
                self.surfaceHostView.displayIfNeeded()
                self.window?.displayIfNeeded()
            }
        }

        private func presentSurfaceNow() {
            guard let surface = mirrorSurface() else { return }
            ghostty_surface_refresh(surface)
            ghostty_surface_draw(surface)
        }

        private func appliedRenderFrameIdentity(for frame: GhosttyRenderFrame) -> AppliedRenderFrameIdentity {
            AppliedRenderFrameIdentity(
                renderStateKey: renderStateKey, version: frame.version, sessionRevision: frame.sessionRevision, ownerEpoch: frame.ownerEpoch,
                columns: frame.columns, rows: frame.rows, snapshot: frame.snapshot)
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
                cSnapshot.mouse_reporting_active = sessionPermitsMouseCapture && snapshot.mouseReportingActive
                cSnapshot.mouse_shift_capture = sessionPermitsMouseCapture ? snapshot.mouseShiftCapture : 0
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

        private func cellMetrics() -> CellMetrics {
            let font = NSFont.monospacedSystemFont(ofSize: Self.defaultFontSize, weight: .regular)
            let width = ceil(("W" as NSString).size(withAttributes: [.font: font]).width)
            let height = ceil(font.ascender - font.descender + font.leading)
            return CellMetrics(width: max(width, 1), height: max(height, 1))
        }

        @objc private func searchFieldAction() { updateSearchQuery() }

        private func updateSearchQuery() {
            guard !searchOverlay.isHidden else { return }
            scheduleSearchQuery(searchField.stringValue)
        }

        private func scheduleSearchQuery(_ query: String) {
            pendingSearchQueryTask?.cancel()
            pendingSearchQueryTask = nil
            submittedSearchQuery = nil
            resetSearchResultCounts()
            guard Self.shouldDebounceSearchQuery(query) else {
                submitSearchQuery(query, resetResults: false)
                return
            }
            pendingSearchQueryTask = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: Self.shortSearchQueryDebounceDelay) } catch { return }
                guard let self, self.searchOverlayIsVisible, self.searchField.stringValue == query else { return }
                self.pendingSearchQueryTask = nil
                self.submitSearchQuery(query, resetResults: false)
            }
        }

        private func submitSearchQuery(_ query: String, resetResults: Bool = true) {
            pendingSearchQueryTask?.cancel()
            pendingSearchQueryTask = nil
            submittedSearchQuery = query
            if resetResults { resetSearchResultCounts() }
            _ = sendBindingAction("search:\(query)")
        }

        private static func shouldDebounceSearchQuery(_ query: String) -> Bool { !query.isEmpty && query.count < 3 }

        @objc private func searchUpAction() { _ = performBindingAction(Self.searchUpBindingAction) }

        @objc private func searchDownAction() { _ = performBindingAction(Self.searchDownBindingAction) }

        @objc private func searchCloseAction() { _ = performBindingAction("end_search") }

        private func applySearchSideEffect(for action: String) {
            if action == "start_search" {
                showSearchOverlay(query: nil)
            } else if action == "end_search" {
                hideSearchOverlay()
            } else if action.hasPrefix("search:") {
                let query = String(action.dropFirst("search:".count))
                showSearchOverlay(query: query)
                submittedSearchQuery = query
                resetSearchResultCounts()
            }
        }

        private func showSearchOverlay(query: String?, submitSeededQuery: Bool = false) {
            pendingFirstResponderRestoreTask?.cancel()
            pendingFirstResponderRestoreTask = nil
            searchOverlay.isHidden = false
            if let query { searchField.stringValue = query }
            window?.makeFirstResponder(searchField)
            searchField.selectText(nil)
            if submitSeededQuery, let query { submitSearchQuery(query) } else { updateSearchStatusLabel() }
        }

        private func hideSearchOverlay() { resetSearchOverlay(restoreFocus: true) }

        private func resetSearchOverlay(restoreFocus: Bool) {
            pendingFirstResponderRestoreTask?.cancel()
            pendingFirstResponderRestoreTask = nil
            searchOverlay.isHidden = true
            pendingSearchQueryTask?.cancel()
            pendingSearchQueryTask = nil
            submittedSearchQuery = nil
            resetSearchResultCounts()
            searchField.stringValue = ""
            if restoreFocus { restoreFirstResponderIfWindowReady() }
        }

        private func resetSearchResultCounts() {
            searchTotal = nil
            searchSelected = nil
            updateSearchStatusLabel()
        }

        @discardableResult private func sendBindingAction(_ action: String) -> Bool {
            if let debugBindingActionHandler {
                debugRecordedBindingActions.append(action)
                return debugBindingActionHandler(action)
            }
            ensureMirrorIfNeeded()
            guard let surface = mirrorSurface() else { return false }
            let performed = action.withCString { pointer in ghostty_surface_binding_action(surface, pointer, UInt(action.lengthOfBytes(using: .utf8)))
            }
            if performed { ghostty_surface_refresh(surface) }
            return performed
        }

        private func updateSearchStatusLabel() {
            let statusText: String
            if let selected = searchSelected, let total = searchTotal, total > 0 {
                statusText = "\(selected + 1) of \(total)"
            } else if let total = searchTotal {
                statusText = total == 0 ? "No matches" : "\(total)"
            } else {
                statusText = ""
            }
            searchStatusLabel.stringValue = statusText
            searchStatusLabel.isHidden = statusText.isEmpty
        }

        static func ghosttyMouseModifiers(for flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
            var mods: UInt32 = GHOSTTY_MODS_NONE.rawValue
            if flags.contains(.shift) { mods |= GHOSTTY_MODS_SHIFT.rawValue }
            if flags.contains(.control) { mods |= GHOSTTY_MODS_CTRL.rawValue }
            if flags.contains(.option) { mods |= GHOSTTY_MODS_ALT.rawValue }
            if flags.contains(.command) { mods |= GHOSTTY_MODS_SUPER.rawValue }
            return ghostty_input_mods_e(mods)
        }

        static func ghosttyMousePosition(for locationInWindow: NSPoint, in view: NSView) -> (x: Double, y: Double) {
            let position = view.convert(locationInWindow, from: nil)
            return (Double(position.x), Double(view.frame.height - position.y))
        }

        static func scrollPointerPosition(for locationInWindow: NSPoint, in view: NSView, mods: UInt32 = GHOSTTY_MODS_NONE.rawValue)
            -> TerminalScrollPointerPosition?
        {
            let position = view.convert(locationInWindow, from: nil)
            return TerminalScrollPointerPosition.normalized(
                x: Double(position.x - view.bounds.minX), y: Double(view.bounds.maxY - position.y), width: Double(view.bounds.width),
                height: Double(view.bounds.height), mods: mods)
        }

        static func ghosttyMouseButton(for buttonNumber: Int) -> ghostty_input_mouse_button_e {
            switch buttonNumber {
            case 0: return GHOSTTY_MOUSE_LEFT
            case 1: return GHOSTTY_MOUSE_RIGHT
            case 2: return GHOSTTY_MOUSE_MIDDLE
            case 3: return GHOSTTY_MOUSE_EIGHT
            case 4: return GHOSTTY_MOUSE_NINE
            case 5: return GHOSTTY_MOUSE_SIX
            case 6: return GHOSTTY_MOUSE_SEVEN
            case 7: return GHOSTTY_MOUSE_FOUR
            case 8: return GHOSTTY_MOUSE_FIVE
            case 9: return GHOSTTY_MOUSE_TEN
            case 10: return GHOSTTY_MOUSE_ELEVEN
            default: return GHOSTTY_MOUSE_UNKNOWN
            }
        }

        static func remoteKeySpecifier(for event: NSEvent) -> String? { GhosttyTerminalInputTranslator.keySpecifier(for: event) }

        var debugHasLiveMirrorSurface: Bool { mirror != nil }
        /// Text read back from the live mirror surface, ignoring the retained frame and text cache, so
        /// a test can tell an actually repainted surface from a remembered one. Nil with no mirror.
        var debugMirrorSurfaceText: String? { GhosttyTerminalSnapshotCapture.captureText(from: mirrorSurface()) }
        /// Whether the live surface holds a selection. Selection lives in the surface and cannot
        /// outlive it, so a test can tell a pane that kept its surface from one whose surface was
        /// freed and rebuilt underneath it.
        var debugHasSurfaceSelection: Bool { mirrorSurface().map { ghostty_surface_has_selection($0) } ?? false }
        var debugSearchFieldHasFocus: Bool { searchFieldHasFocus }
        var debugSearchStatusVisible: Bool { !searchStatusLabel.isHidden }
        var debugSearchUpBindingAction: String { Self.searchUpBindingAction }
        var debugSearchDownBindingAction: String { Self.searchDownBindingAction }
        var debugHoveredLink: String? { hoveredLink }
    }
#endif
