import QuickLook
import SwiftUI
import UIKit
import spacesdevicecore
import spacesterminalcore
import spacesterminalmobileghostty

struct TerminalDetailView: View {
    private static let chromeControlHeight: CGFloat = 36
    /// Gap between the Copy pill and the highlight's edge, on whichever side it sits: enough that the
    /// pill never touches (let alone covers) the selected text.
    private static let selectionCopyPillGap: CGFloat = 6

    let session: SpacesDeviceTerminalSessionSummary
    let settings: SpacesMobileConnectionSettings
    let appModel: SpacesMobileAppModel
    let onAuthenticationRequired: @MainActor @Sendable (String) -> Void
    let onSessionChanged: (SpacesDeviceTerminalSessionSummary) -> Void
    let onBack: () -> Void

    @State private var hasMountedTerminalSurface = false
    @State private var isBackNavigationInProgress = false
    @State private var isShowingComposer = false
    /// The row awaiting Stop confirmation from the toolbar menu. A separate state from `SpacesTabView`'s
    /// `pendingStop` because this is a different view with no shared owner to hold it.
    @State private var pendingStopRow: SpacesMobileWorkspaceRuntimeRow?
    @State private var renderedText = ""
    @State private var model: TerminalViewerModel
    /// Measured size of the Copy pill's visible capsule (see `TerminalSelectionCopyPill`), captured via
    /// `SelectionCopyPillSizePreferenceKey` so the overlay can right-align the capsule's trailing edge to
    /// the selection's anchor point without knowing the label's rendered width ahead of time. Resets to
    /// `.zero` whenever the pill is absent (the preference key's default), so a size from a previous
    /// selection never leaks into the next one's first frame.
    @State private var selectionCopyPillSize: CGSize = .zero
    /// Whether the pill is showing its brief "Copied" confirmation instead of "Copy".
    @State private var isSelectionCopyPillShowingCopied = false
    /// Cancels a pending "Copied" -> "Copy" revert when a new copy starts before the previous one's timer
    /// fires, so two quick copies do not race to leave the label in the wrong state.
    @State private var selectionCopyFeedbackTask: Task<Void, Never>?
    /// The app's effective light/dark scheme. `preferredColorScheme` at the app scene stamps the forced
    /// mode here, and a `.system` mode lets it track the OS trait, so observing it covers both an appearance
    /// setting flip and an OS switch — either way the live session is re-themed to match the app.
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(TerminalFontSizeStorage.key) private var terminalFontSize: TerminalFontSize = .default
    private var e2eConfig: SpacesMobileE2EConfig { .shared }
    private var shouldCaptureRenderedText: Bool { e2eConfig.isEnabled && e2eConfig.matches(sessionID: session.id) }
    private var e2eCommandRequestPath: String? {
        guard e2eConfig.isEnabled, e2eConfig.matches(sessionID: session.id), let eventLogPath = e2eConfig.eventLogPath else { return nil }
        return "\(eventLogPath).command-request.json"
    }

    init(
        session: SpacesDeviceTerminalSessionSummary, settings: SpacesMobileConnectionSettings, appModel: SpacesMobileAppModel,
        onAuthenticationRequired: @escaping @MainActor @Sendable (String) -> Void,
        onSessionChanged: @escaping (SpacesDeviceTerminalSessionSummary) -> Void, onBack: @escaping () -> Void
    ) {
        self.session = session
        self.settings = settings
        self.appModel = appModel
        self.onAuthenticationRequired = onAuthenticationRequired
        self.onSessionChanged = onSessionChanged
        self.onBack = onBack
        let appModel = appModel
        _model = State(
            initialValue: TerminalViewerModel(
                session: session, settings: settings, onAuthenticationRequired: onAuthenticationRequired,
                onOpenTerminalDeepLink: { link in Task { await appModel.openTerminalDeepLink(link) } }, bridgeClient: appModel.deviceClient,
                isDemoMode: appModel.isDemoModeEnabled))
    }

    var body: some View {
        VStack(spacing: 0) {
            topOverlay.padding(.horizontal, 8).padding(.top, 4).padding(.bottom, 4)

            Group {
                if hasMountedTerminalSurface || model.showsTerminalSurface {
                    ZStack {
                        GhosttyRemoteTerminalView(
                            ownerEpoch: model.ownerRenderEpoch, endedRender: model.endedRender, fallbackText: model.visibleText,
                            isVisible: model.shouldPresentLiveSurface, acceptsInput: model.keepsTerminalInputSurfaceActive, isBusy: model.isBusy,
                            fontSize: terminalFontSize,
                            onInputReadinessChanged: { ready in
                                model.setInputSurfaceReady(ready)
                                writeE2EEventIfNeeded(kind: "input_readiness", detail: ready ? "ready" : "pending")
                            },
                            onScrollGestureApplied: {
                                writeE2EEventIfNeeded(kind: "e2e_scroll_gesture_applied", detail: nil)
                                model.flushPendingScroll()
                            },
                            onRenderedTextChanged: shouldCaptureRenderedText
                                ? { text in
                                    renderedText = text
                                    model.recordRenderedText(text)
                                } : nil, onViewportSizeChanged: { columns, rows in model.updateViewportSize(columns: columns, rows: rows) },
                            onSendText: { text, asPaste in sendTerminalText(text, asPaste: asPaste) }, onSendKey: { key in sendTerminalKey(key) },
                            onSendScroll: { horizontal, vertical, scrollMods, pointerPosition in
                                sendTerminalScroll(
                                    horizontal: horizontal, vertical: vertical, scrollMods: scrollMods, pointerPosition: pointerPosition)
                            }, onOpenLink: { link in openTerminalLink(link) }, onOpenComposer: { isShowingComposer = true },
                            // A clipboard image pasted at the terminal lands in the composer pre-attached
                            // rather than in the session: sending an image stays a deliberate composer action.
                            onPasteClipboardImage: {
                                guard model.pasteClipboardImageIntoComposer() else { return false }
                                isShowingComposer = true
                                return true
                            }, onClearSelectionTapped: { clearSelectionOnTerminalTap() }
                        ).ignoresSafeArea(.keyboard, edges: .bottom).accessibilityIdentifier("terminal.surface").allowsHitTesting(
                            model.shouldPresentLiveSurface
                        ).accessibilityHidden(!model.shouldPresentLiveSurface).background(Theme.terminalSurface)

                        if !model.shouldPresentLiveSurface { statusShell.onAppear { renderedText = "" } }

                        selectionCopyPillOverlay
                    }
                } else {
                    statusShell.onAppear { renderedText = "" }
                }
            }.overlay(alignment: .bottom) { linkPreviewBannerOverlay }

            if model.isDemoMode { demoNoticeBanner }
            if let errorMessage = model.errorMessage { errorBanner(errorMessage) }
            // The pane is an accessibility container (`.accessibilityElement(children: .contain)`) rather
            // than a plain identified view: an identifier on a SwiftUI container otherwise replaces the
            // identifier of every element beneath it, which would leave this whole screen -- back button,
            // banners, dismiss controls -- carrying "terminal.detail.<id>" and nothing else.
        }.background(Theme.terminalSurface.ignoresSafeArea()).accessibilityElement(children: .contain).accessibilityIdentifier(
            "terminal.detail.\(session.id)"
        ).toolbar(.hidden, for: .navigationBar).task {
            if scenePhase != .active { model.prepareForBackgrounding() }
            model.start()
            if scenePhase == .active { model.resumeAfterBackgrounding() }
        }.task(id: session.id) { await refreshRuntimeRowsWhileVisible() }.task(id: e2eDumpStateKey) { writeE2EDumpIfNeeded() }.task(
            id: e2eCommandRequestPath
        ) { await consumeE2ECommandRequestsIfNeeded() }.onChange(of: model.showsTerminalSurface) { showsTerminalSurface in
            if showsTerminalSurface { hasMountedTerminalSurface = true }
            if !showsTerminalSurface { renderedText = "" }
        }.onChange(of: model.shouldPresentLiveSurface) { shouldPresentLiveSurface in
            writeE2EEventIfNeeded(kind: "surface_visibility", detail: shouldPresentLiveSurface ? "visible" : "hidden")
        }.onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .background: model.prepareForBackgrounding()
            case .active: model.resumeAfterBackgrounding()
            case .inactive: break
            @unknown default: break
            }
        }.onChange(of: colorScheme) { newColorScheme in Task { await model.sendAppearance(newColorScheme == .dark ? .dark : .light) } }.sheet(
            item: Binding(get: { model.linkPreview }, set: { preview in if preview == nil { model.dismissLinkPreview() } })
        ) { preview in TerminalLinkPreviewSheet(preview: preview) }.fullScreenCover(
            item: Binding(get: { model.safariLink }, set: { link in if link == nil { model.dismissSafariLink() } })
        ) { safariLink in TerminalSafariView(url: safariLink.url) }.sheet(isPresented: $isShowingComposer) {
            TerminalComposerSheet(model: model, stagedScreenshots: appModel.stagedScreenshots)
        }.confirmationDialog(
            pendingStopRow.map { StopConfirmationCopy.rowTitle($0.title) } ?? "", isPresented: pendingStopDialogBinding, titleVisibility: .visible,
            presenting: pendingStopRow
        ) { row in
            Button("Stop", role: .destructive) { Task { await appModel.stop(row: row) } }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text(StopConfirmationCopy.rowMessage)
        }.onDisappear { model.stop() }
    }

    private var pendingStopDialogBinding: Binding<Bool> { Binding(get: { pendingStopRow != nil }, set: { if !$0 { pendingStopRow = nil } }) }

    private var linkPreviewBannerOverlay: some View {
        VStack(spacing: 0) {
            // Transient and self-clearing: never dismissable, and explicitly non-interactive so it
            // never swallows a tap meant for the terminal underneath.
            if model.isPreparingLinkPreview { previewStatusBanner("Preparing preview…").allowsHitTesting(false) }
            if let previewErrorMessage = model.linkPreviewErrorMessage { errorBanner(previewErrorMessage, onDismiss: { model.dismissLinkBanners() }) }
            if let linkNotice = model.linkNotice { noticeBanner(linkNotice, onDismiss: { model.dismissLinkBanners() }) }
        }
    }

    /// The Copy pill, positioned from the current frame's shared selection. Absent whenever the frame
    /// carries no selection: the pill is not hidden-but-present, it is not built at all, so it never
    /// intercepts a tap meant for the terminal underneath.
    @ViewBuilder private var selectionCopyPillOverlay: some View {
        if let placement = selectionCopyPillPlacement {
            let origin = TerminalSelectionCopyPillLayout.origin(
                anchor: placement.anchor, pillSize: selectionCopyPillSize, gap: Self.selectionCopyPillGap, contentOrigin: placement.contentOrigin,
                gridSize: placement.gridSize)
            TerminalSelectionCopyPill(isCopied: isSelectionCopyPillShowingCopied) { performCopySelection() }.background(
                GeometryReader { proxy in Color.clear.preference(key: SelectionCopyPillSizePreferenceKey.self, value: proxy.size) }
            ).onPreferenceChange(SelectionCopyPillSizePreferenceKey.self) { selectionCopyPillSize = $0 }.offset(x: origin.x, y: origin.y)
                // The anchor is a point in the terminal view's own top-leading coordinate space, so the pill
                // must start from the stack's top-leading corner before the offset places it; the enclosing
                // ZStack's default center alignment would otherwise shift the whole placement by half the
                // stack minus half the pill.
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    /// Anchor plus the grid bounds `TerminalSelectionCopyPillLayout.origin` clamps the pill into.
    private struct SelectionCopyPillPlacement {
        let anchor: TerminalSelectionCopyPillLayout.Anchor
        let contentOrigin: CGPoint
        let gridSize: CGSize
    }

    /// `contentOrigin`/cell metrics mirror exactly what `GhosttyRemoteTerminalHostView` itself measures
    /// (`GhosttyRemoteTerminalViewport.contentInsets`/`cellMetrics(fontSize:)`), so the pill agrees with
    /// the surface on where a row/column lands on screen without the two ever drifting apart.
    private var selectionCopyPillPlacement: SelectionCopyPillPlacement? {
        // The daemon rejects readSelectionText once the session has ended, so the pill would be a
        // dead control on a frozen frame.
        guard let snapshot = model.latestState?.renderSnapshot, snapshot.selection != nil, model.endedRender == nil,
            let columns = model.viewportColumns, let rows = model.viewportRows
        else { return nil }
        let metrics = GhosttyRemoteTerminalViewport.cellMetrics(fontSize: terminalFontSize)
        let contentOrigin = CGPoint(x: GhosttyRemoteTerminalViewport.contentInsets.left, y: GhosttyRemoteTerminalViewport.contentInsets.top)
        guard
            let anchor = TerminalSelectionCopyPillLayout.anchor(
                snapshot: snapshot, viewportColumns: columns, viewportRows: rows, contentOrigin: contentOrigin, cellWidth: metrics.width,
                cellHeight: metrics.height)
        else { return nil }
        let gridSize = CGSize(width: CGFloat(columns) * metrics.width, height: CGFloat(rows) * metrics.height)
        return SelectionCopyPillPlacement(anchor: anchor, contentOrigin: contentOrigin, gridSize: gridSize)
    }

    /// A plain tap on the terminal while a selection is present clears it for every viewer (see
    /// `GhosttyRemoteTerminalHostView.handleTapToActivateInput`); the pill's own tap never reaches here,
    /// it is a separate SwiftUI overlay that captures its own taps first.
    private func clearSelectionOnTerminalTap() {
        writeE2EEventIfNeeded(kind: "clear_selection", detail: nil)
        Task { await model.clearSelection() }
    }

    private func performCopySelection() {
        writeE2EEventIfNeeded(kind: "copy_selection", detail: nil)
        selectionCopyFeedbackTask?.cancel()
        selectionCopyFeedbackTask = Task {
            let succeeded = await model.copySelection()
            guard !Task.isCancelled else { return }
            guard succeeded else { return }
            isSelectionCopyPillShowingCopied = true
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            isSelectionCopyPillShowingCopied = false
        }
    }

    private func sendTerminalText(_ text: String, asPaste: Bool = false) {
        guard !text.isEmpty else { return }
        writeE2EEventIfNeeded(kind: "send_text", detail: text)
        Task { await model.sendText(text, asPaste: asPaste) }
    }

    private func sendTerminalKey(_ key: String) {
        writeE2EEventIfNeeded(kind: "send_key", detail: key)
        Task { await model.sendKey(key) }
    }

    private func sendTerminalScroll(horizontal: Double, vertical: Double, scrollMods: Int32, pointerPosition: TerminalScrollPointerPosition?) {
        writeE2EEventIfNeeded(kind: "send_scroll", detail: "\(horizontal),\(vertical)")
        Task { await model.sendScroll(horizontal: horizontal, vertical: vertical, scrollMods: scrollMods, pointerPosition: pointerPosition) }
    }

    private func openTerminalLink(_ link: String) {
        writeE2EEventIfNeeded(kind: "open_link", detail: link)
        Task { await model.openTerminalLink(link) }
    }

    private var topOverlay: some View {
        HStack(spacing: 8) {
            chromeButton(accessibilityIdentifier: "terminal.back", accessibilityLabel: "Back") {
                beginBackNavigation()
            } label: {
                Image(systemName: isBackNavigationInProgress ? "arrow.triangle.2.circlepath" : "chevron.left").font(.subheadline.weight(.semibold))
            }.disabled(isBackNavigationInProgress)

            Spacer(minLength: 0)

            Text(runtimeRow?.title ?? model.title).font(.subheadline.weight(.semibold)).foregroundStyle(.white).lineLimit(1)

            Spacer(minLength: 0)

            trailingChrome.frame(minWidth: Self.chromeControlHeight, alignment: .trailing)
        }.frame(height: Self.chromeControlHeight)
    }

    private var runtimeRow: SpacesMobileWorkspaceRuntimeRow? { appModel.runtimeRow(forSessionID: session.id) }

    @ViewBuilder private var trailingChrome: some View {
        if let row = runtimeRow, row.hasTerminalDetailActions {
            HStack(spacing: 6) {
                ownerChromeStateMarker
                Menu {
                    if row.canRun {
                        Button {
                            Task { await runRuntime(row) }
                        } label: {
                            Label("Run", systemImage: "play.fill")
                        }.disabled(appModel.isMutating)
                    }
                    if row.canRestartFromTerminalDetail {
                        Button {
                            Task { await restartRuntime(row) }
                        } label: {
                            Label("Restart", systemImage: "arrow.clockwise")
                        }.disabled(appModel.isMutating)
                    }
                    if row.canStopFromTerminalDetail {
                        Button(role: .destructive) {
                            pendingStopRow = row
                        } label: {
                            Label("Stop", systemImage: "stop.fill")
                        }.disabled(appModel.isMutating)
                    }
                } label: {
                    Image(systemName: appModel.isMutating ? "arrow.triangle.2.circlepath" : "ellipsis").font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white).frame(width: Self.chromeControlHeight, height: Self.chromeControlHeight).background(
                            Theme.terminalChromePillBackground)
                }.disabled(appModel.isMutating).accessibilityLabel("Terminal actions").accessibilityIdentifier("terminal.runtimeActions")
            }
        } else if model.isOwner {
            ownerChromeStateMarker
        } else {
            Color.clear.frame(width: 1, height: 1)
        }
    }

    @ViewBuilder private var ownerChromeStateMarker: some View {
        if model.isOwner {
            if model.isPreparingInput {
                chromeActivityBadge(accessibilityLabel: "Preparing input").accessibilityIdentifier("terminal.ownerPreparing")
            } else {
                // Ownership is obvious from the absence of the Take Over button,
                // so no visible tag is shown. An invisible marker preserves the
                // ownership signal for UI tests.
                ownerStateMarker
            }
        }
    }

    private func runRuntime(_ row: SpacesMobileWorkspaceRuntimeRow) async {
        if let session = await appModel.run(row: row) { onSessionChanged(session) }
    }

    private func restartRuntime(_ row: SpacesMobileWorkspaceRuntimeRow) async {
        if let session = await appModel.restart(row: row) { onSessionChanged(session) }
    }

    private func refreshRuntimeRowsWhileVisible() async {
        await appModel.refresh()
        while !Task.isCancelled {
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            guard !Task.isCancelled else { return }
            await appModel.refresh()
        }
    }

    private func beginBackNavigation() {
        guard !isBackNavigationInProgress else { return }
        isBackNavigationInProgress = true
        Task {
            await model.prepareForBackNavigation()
            onBack()
        }
    }

    /// Brand-primary Take Over control (teal fill, dark ink) for viewers.
    private var takeOverButton: some View {
        Button {
            Task { await model.takeOver() }
        } label: {
            Text("Take Over").font(.headline.weight(.semibold)).foregroundStyle(Theme.primaryButtonText).lineLimit(1).minimumScaleFactor(0.8).padding(
                .horizontal, 14
            ).frame(height: Self.chromeControlHeight).background(Capsule().fill(Theme.primaryButtonFill))
        }.buttonStyle(.plain).disabled(model.isBusy).accessibilityLabel("Take Over").accessibilityIdentifier("terminal.takeover")
            .accessibilityElement(children: .ignore)
    }

    /// Zero-visual-footprint accessibility marker that preserves the ownership
    /// signal used by UI tests now that the visible "Owner" tag is removed.
    private var ownerStateMarker: some View {
        Text("Owner").font(.caption2).foregroundStyle(.clear).frame(width: 1, height: 1).clipped().accessibilityIdentifier("terminal.ownerBadge")
    }

    private var statusShell: some View {
        TerminalStatusPlaceholder(
            systemName: model.isOwner && model.isPreparingInput || model.isTakingOver || model.isConnecting
                ? "arrow.triangle.2.circlepath.circle.fill" : "lock.desktopcomputer"
        ) {
            Text(model.visibleText).font(.body.monospaced()).foregroundStyle(.white.opacity(0.88)).multilineTextAlignment(.center).padding(
                .horizontal, 28)
            if model.showsTakeOverAction { takeOverButton.padding(.top, 4) }
        }.background(Theme.terminalSurface)
    }

    private func chromeButton<Label: View>(
        accessibilityIdentifier: String, accessibilityLabel: String, action: @escaping () -> Void, @ViewBuilder label: () -> Label
    ) -> some View {
        Button(action: action) {
            label().foregroundStyle(.white).frame(height: Self.chromeControlHeight).padding(.horizontal, 18).background(
                Theme.terminalChromePillBackground)
        }.accessibilityElement(children: .ignore).accessibilityLabel(accessibilityLabel).accessibilityIdentifier(accessibilityIdentifier)
    }

    private func chromeActivityBadge(accessibilityLabel: String) -> some View {
        ZStack { ProgressView().controlSize(.small).tint(.white.opacity(0.9)) }.frame(
            width: Self.chromeControlHeight, height: Self.chromeControlHeight
        ).background(Capsule().fill(.black.opacity(0.18)).overlay(Capsule().strokeBorder(.white.opacity(0.08), lineWidth: 1))).accessibilityElement(
            children: .ignore
        ).accessibilityLabel(accessibilityLabel)
    }

    private func errorBanner(_ message: String, onDismiss: (() -> Void)? = nil) -> some View {
        dismissableBanner(
            message: message, textColor: .red, identifier: "terminal.errorBanner", dismissIdentifier: "terminal.errorBanner.dismiss",
            onDismiss: onDismiss)
    }

    private func noticeBanner(_ message: String, onDismiss: (() -> Void)? = nil) -> some View {
        dismissableBanner(
            message: message, textColor: .primary, identifier: "terminal.linkNotice", dismissIdentifier: "terminal.linkNotice.dismiss",
            onDismiss: onDismiss)
    }

    /// Shared row for `errorBanner`/`noticeBanner`. An accessibility container for the same reason as the
    /// pane root: the banner keeps `identifier` and its dismiss button keeps `dismissIdentifier`, instead
    /// of the banner's identifier overwriting the button's.
    ///
    /// Hit-testable only when `onDismiss` is supplied:
    /// the trailing xmark button and a tap anywhere on the banner both call it. The `model.errorMessage`
    /// banner reuses `errorBanner` without an `onDismiss`, so it keeps its present (already
    /// non-interactive) behavior unchanged.
    private func dismissableBanner(message: String, textColor: Color, identifier: String, dismissIdentifier: String, onDismiss: (() -> Void)?)
        -> some View
    {
        HStack(spacing: 8) {
            Text(message).font(.footnote).foregroundStyle(textColor).frame(maxWidth: .infinity, alignment: .leading)
            if let onDismiss {
                Button(action: onDismiss) { Image(systemName: "xmark").font(.footnote.weight(.semibold)).foregroundStyle(.secondary) }
                    .accessibilityIdentifier(dismissIdentifier)
            }
        }.padding(.horizontal, 16).padding(.vertical, 12).background(Color(uiColor: .secondarySystemBackground)).accessibilityElement(
            children: .contain
        ).accessibilityIdentifier(identifier).contentShape(Rectangle()).allowsHitTesting(onDismiss != nil).onTapGesture { onDismiss?() }
    }

    /// Persistent read-only notice shown on every demo terminal. Like the session-ended banner, it names
    /// a lasting fact about the pane (input is unavailable) rather than a transient state, so it carries no
    /// dismiss affordance and stays for the life of the demo session. Accent-tinted to read as a Demo Mode
    /// surface, matching the app's Demo Mode banner.
    private var demoNoticeBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.desktopcomputer").font(.footnote.weight(.semibold)).foregroundStyle(Theme.accent)
            Text("Demo Mode — terminal input requires a paired Mac").font(.footnote).foregroundStyle(.white.opacity(0.88))
            Spacer(minLength: 0)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).padding(.vertical, 12).background(Theme.accentTint).overlay(
            Rectangle().frame(height: 1).foregroundStyle(Theme.accent.opacity(0.4)), alignment: .top
        ).accessibilityIdentifier("demo.terminalNotice")
    }

    private func previewStatusBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small).tint(.white.opacity(0.9))
            Text(message).font(.footnote).foregroundStyle(.white.opacity(0.86))
            Spacer(minLength: 0)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).padding(.vertical, 10).background(Color.black.opacity(0.32))
            .accessibilityIdentifier("terminal.previewStatus")
    }

    /// Change identity for the e2e dump task, and nothing else. Building it reads twenty model
    /// properties and joins them, on every body evaluation of a view that re-evaluates at the session's
    /// flush rate; `writeE2EDumpIfNeeded` is gated on the same condition, so outside an e2e run the key
    /// collapses to a constant and the task never re-runs.
    private var e2eDumpStateKey: String {
        guard shouldCaptureRenderedText else { return "" }
        // Broken out of the array literal below: folding either back in makes the whole expression too
        // complex for the type checker to solve in reasonable time.
        let appliedFrameSize: String = model.ownerRenderEpoch?.bootstrapSnapshot.map { "\($0.columns)x\($0.rows)" } ?? ""
        // The viewport can change (a resize round trip settling, a keyboard transition) with neither the
        // owner's applied frame nor the rendered text moving — dropped columns can be blank, and a
        // narrower grid can still show the same visible characters. `showsCroppedHostGrid` in the e2e UI
        // tests compares the applied frame against this viewport, so the dump has to refresh on it too, or
        // that comparison runs against a value this task never updated.
        let viewportSize: String = "\(model.viewportColumns.map(String.init) ?? "?")x\(model.viewportRows.map(String.init) ?? "?")"
        return [
            model.title, model.renderStateKey, model.isOwner ? "owner" : "viewer", model.showsTerminalSurface ? "surface" : "status",
            model.isConnecting ? "connecting" : "steady", model.isBusy ? "busy" : "idle",
            model.isOwnershipSynchronizationScheduled ? "syncScheduled" : "syncNotScheduled", model.isSynchronizingOwnership ? "syncing" : "synced",
            model.isPreparingInput ? "preparing" : "prepared", model.isInputSurfaceReady ? "inputReady" : "inputPending", model.errorMessage ?? "",
            model.isPreparingLinkPreview ? "previewPreparing" : "previewIdle", model.linkPreview?.title ?? "",
            model.linkPreview?.kind?.rawValue ?? "", model.linkPreview?.content.caseName ?? "", model.linkPreviewErrorMessage ?? "",
            model.linkNotice ?? "", renderedText, appliedFrameSize, viewportSize,
        ].joined(separator: "|")
    }

    private func writeE2EDumpIfNeeded() {
        guard e2eConfig.isEnabled, e2eConfig.matches(sessionID: session.id) else { return }
        SpacesMobileE2EDumpWriter.writeCurrentDump(
            .init(
                sessionID: session.id, title: model.title, renderMode: model.renderMode, isOwner: model.isOwner,
                showsTerminalSurface: model.showsTerminalSurface, isConnecting: model.isConnecting, isBusy: model.isBusy,
                isOwnershipSynchronizationScheduled: model.isOwnershipSynchronizationScheduled,
                isSynchronizingOwnership: model.isSynchronizingOwnership, isPreparingInput: model.isPreparingInput,
                isInputSurfaceReady: model.isInputSurfaceReady, viewportColumns: model.viewportColumns, viewportRows: model.viewportRows,
                lastSentResizeColumns: model.lastSentResizeColumns, lastSentResizeRows: model.lastSentResizeRows,
                runtimeColumns: model.runtimeColumns, runtimeRows: model.runtimeRows, snapshotColumns: model.snapshotColumns,
                snapshotRows: model.snapshotRows, appliedFrameColumns: model.ownerRenderEpoch?.bootstrapSnapshot?.columns,
                appliedFrameRows: model.ownerRenderEpoch?.bootstrapSnapshot?.rows, snapshotText: model.snapshotText, errorMessage: model.errorMessage,
                isPreparingLinkPreview: model.isPreparingLinkPreview, linkPreviewTitle: model.linkPreview?.title,
                linkPreviewArtifactKind: model.linkPreview?.kind, linkPreviewContentKind: model.linkPreview?.content.caseName,
                linkPreviewErrorMessage: model.linkPreviewErrorMessage, linkNotice: model.linkNotice, visibleText: model.visibleText,
                renderedText: renderedText, renderStateKey: model.renderStateKey,
                emittedAt: model.latestState?.emittedAt ?? ISO8601DateFormatter().string(from: Date())), config: e2eConfig)
    }

    private func writeE2EEventIfNeeded(kind: String, detail: String?) {
        guard e2eConfig.isEnabled, e2eConfig.matches(sessionID: session.id) else { return }
        SpacesMobileE2EDumpWriter.appendEvent(
            .init(sessionID: session.id, kind: kind, detail: detail, emittedAt: ISO8601DateFormatter().string(from: Date())), config: e2eConfig)
    }

    private func consumeE2ECommandRequestsIfNeeded() async {
        guard let e2eCommandRequestPath else { return }
        let requestURL = URL(fileURLWithPath: e2eCommandRequestPath)
        while !Task.isCancelled {
            if let data = try? Data(contentsOf: requestURL) {
                if let request = try? JSONDecoder().decode(E2ECommandRequest.self, from: data) {
                    let requestDetail = request.detail
                    // A link open is not terminal input: it neither needs nor waits for input readiness,
                    // and it is the only way a test fixture can drive this path. Ghostty's link hit-test
                    // is refused on a column-cropped frame (see `appliedFrameCoversHostColumns`), and the
                    // Demo Mode recording the blocking smoke lane runs against is always a few columns
                    // wider than the phone's viewport, so a tap on a rendered link there can never open
                    // one. The link-banner regression coverage (#650) reaches the banners through this.
                    if let link = request.link?.trimmingCharacters(in: .whitespacesAndNewlines), !link.isEmpty {
                        await model.openTerminalLink(link)
                    } else if let key = request.key?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty {
                        await waitForE2EInputReadiness()
                        await model.sendKey(key)
                    } else if request.sendEnter ?? true, let text = request.text {
                        await waitForE2EInputReadiness()
                        await model.sendText(text, appendNewline: true)
                    } else if let text = request.text {
                        await waitForE2EInputReadiness()
                        await model.sendText(text)
                    }
                    writeE2EEventIfNeeded(kind: "e2e_command_request_consumed", detail: requestDetail)
                } else {
                    writeE2EEventIfNeeded(kind: "e2e_command_request_invalid", detail: requestURL.lastPathComponent)
                }
                try? FileManager.default.removeItem(at: requestURL)
            }
            try? await Task.sleep(for: .milliseconds(150))
        }
    }

    private func waitForE2EInputReadiness(timeout: Duration = .seconds(10)) async {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !Task.isCancelled, ContinuousClock.now < deadline {
            if model.acceptsInput && model.isInputSurfaceReady { return }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }
}

/// Reports the Copy pill's measured visible size back up to `TerminalDetailView`, so its overlay can
/// right-align the capsule's trailing edge to the selection anchor without a two-pass layout. Defaults to
/// `.zero`, which is also what a torn-down pill (no selection this frame) reports, so a stale size from a
/// previous selection never carries into the next one.
private struct SelectionCopyPillSizePreferenceKey: PreferenceKey {
    static let defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) { value = nextValue() }
}

private struct E2ECommandRequest: Decodable {
    let id: String
    let text: String?
    let key: String?
    let link: String?
    let sendEnter: Bool?

    var detail: String {
        ["id=\(id)", "sendEnter=\(sendEnter ?? true)", "text=\(text ?? "")", "key=\(key ?? "")", "link=\(link ?? "")"].joined(separator: " ")
    }
}

private struct TerminalLinkPreviewSheet: View {
    let preview: TerminalLinkPreview

    var body: some View {
        NavigationStack {
            content.ignoresSafeArea(edges: .bottom).accessibilityIdentifier("terminal.linkPreview").navigationTitle(preview.title)
                .navigationBarTitleDisplayMode(.inline).toolbar { toolbarContent }
        }
    }

    /// Each content kind renders through its dedicated viewer: image/video/PDF keep QuickLook, plain text
    /// gets the selectable monospaced text view, Markdown gets the rendered/raw viewer, and a local HTML
    /// artifact uses the isolated web view. A plain web page has no case here; it opens through
    /// `TerminalSafariView` instead (see `TerminalViewerModel.safariLink`).
    @ViewBuilder private var content: some View {
        switch preview.content {
        case .quickLook(let url): TerminalQuickLookPreview(url: url)
        case .text(let url): TerminalTextArtifactView(url: url)
        case .markdown(let url): TerminalMarkdownArtifactView(url: url)
        case .htmlFile(let url): TerminalWebArtifactView(load: .fileURL(url))
        }
    }

    /// Every content kind here is file-backed, so the toolbar offers Share to hand the on-device file
    /// to another app.
    @ToolbarContentBuilder private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            switch preview.content {
            case .quickLook(let url), .text(let url), .markdown(let url), .htmlFile(let url):
                ShareLink(item: url) { Label("Open In", systemImage: "square.and.arrow.up") }
            }
        }
    }
}

private struct TerminalQuickLookPreview: UIViewControllerRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator { Coordinator(url: url) }

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: QLPreviewController, context: Context) {
        context.coordinator.url = url
        controller.reloadData()
    }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        var url: URL

        init(url: URL) { self.url = url }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> any QLPreviewItem { url as NSURL }
    }
}
