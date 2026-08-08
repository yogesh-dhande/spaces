import QuickLook
import SwiftUI
import UIKit
import spacesdevicecore
import spacesterminalcore
import spacesterminalmobileghostty

struct TerminalDetailView: View {
    private static let chromeControlHeight: CGFloat = 36
    /// The terminal surface is always dark regardless of the app's light/dark
    /// appearance, so this uses the fixed brand dark background value
    /// (`Theme.bg` dark = 15,21,23) rather than a dynamic token.
    private static let surfaceBackground = Color(red: 15 / 255, green: 21 / 255, blue: 23 / 255)

    let session: SpacesDeviceTerminalSessionSummary
    let settings: SpacesMobileConnectionSettings
    let appModel: SpacesMobileAppModel
    let onAuthenticationRequired: @MainActor @Sendable (String) -> Void
    let onSessionChanged: (SpacesDeviceTerminalSessionSummary) -> Void
    let onBack: () -> Void

    @State private var hasMountedTerminalSurface = false
    @State private var isBackNavigationInProgress = false
    @State private var isShowingComposer = false
    @State private var renderedText = ""
    @State private var model: TerminalViewerModel
    /// The app's effective light/dark scheme. `preferredColorScheme` at the app scene stamps the forced
    /// mode here, and a `.system` mode lets it track the OS trait, so observing it covers both an appearance
    /// setting flip and an OS switch — either way the live session is re-themed to match the app.
    @Environment(\.colorScheme) private var colorScheme
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
                            },
                            onSendMouseButton: { button, pressed, pointerPosition in
                                sendTerminalMouseButton(button: button, pressed: pressed, pointerPosition: pointerPosition)
                            }, onOpenLink: { link in openTerminalLink(link) }, onOpenComposer: { isShowingComposer = true },
                            // A clipboard image pasted at the terminal lands in the composer pre-attached
                            // rather than in the session: sending an image stays a deliberate composer action.
                            onPasteClipboardImage: {
                                guard model.pasteClipboardImageIntoComposer() else { return false }
                                isShowingComposer = true
                                return true
                            }
                        ).accessibilityIdentifier("terminal.surface").allowsHitTesting(model.shouldPresentLiveSurface).accessibilityHidden(
                            !model.shouldPresentLiveSurface
                        ).background(Self.surfaceBackground)

                        if !model.shouldPresentLiveSurface { statusShell.onAppear { renderedText = "" } }
                    }
                } else {
                    statusShell.onAppear { renderedText = "" }
                }
            }.overlay(alignment: .bottom) { linkPreviewBannerOverlay }

            if model.isDemoMode { demoNoticeBanner }
            if let errorMessage = model.errorMessage { errorBanner(errorMessage) }
        }.background(Self.surfaceBackground.ignoresSafeArea()).accessibilityIdentifier("terminal.detail.\(session.id)").toolbar(
            .hidden, for: .navigationBar
        ).task { model.start() }.task(id: session.id) { await refreshRuntimeRowsWhileVisible() }.task(id: e2eDumpStateKey) { writeE2EDumpIfNeeded() }
            .task(id: e2eCommandRequestPath) { await consumeE2ECommandRequestsIfNeeded() }.onChange(of: model.showsTerminalSurface) {
                showsTerminalSurface in
                if showsTerminalSurface { hasMountedTerminalSurface = true }
                if !showsTerminalSurface { renderedText = "" }
            }.onChange(of: model.shouldPresentLiveSurface) { shouldPresentLiveSurface in
                writeE2EEventIfNeeded(kind: "surface_visibility", detail: shouldPresentLiveSurface ? "visible" : "hidden")
            }.onChange(of: colorScheme) { newColorScheme in Task { await model.sendAppearance(newColorScheme == .dark ? .dark : .light) } }.sheet(
                item: Binding(get: { model.linkPreview }, set: { preview in if preview == nil { model.dismissLinkPreview() } })
            ) { preview in TerminalLinkPreviewSheet(preview: preview) }.sheet(isPresented: $isShowingComposer) {
                TerminalComposerSheet(model: model, stagedScreenshots: appModel.stagedScreenshots)
            }.onDisappear { model.stop() }
    }

    private var linkPreviewBannerOverlay: some View {
        VStack(spacing: 0) {
            if model.isPreparingLinkPreview { previewStatusBanner("Preparing preview…") }
            if let previewErrorMessage = model.linkPreviewErrorMessage { errorBanner(previewErrorMessage) }
            if let linkNotice = model.linkNotice { noticeBanner(linkNotice) }
        }.allowsHitTesting(false)
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

    private func sendTerminalMouseButton(button: UInt8, pressed: Bool, pointerPosition: TerminalScrollPointerPosition?) {
        writeE2EEventIfNeeded(kind: "send_mouse_button", detail: "\(button),\(pressed)")
        // Direct call, not a Task: press and release arrive back-to-back and must enqueue in order.
        model.sendMouseButton(button: button, pressed: pressed, pointerPosition: pointerPosition)
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
                            Task { await appModel.stop(row: row) }
                        } label: {
                            Label("Stop", systemImage: "stop.fill")
                        }.disabled(appModel.isMutating)
                    }
                } label: {
                    Image(systemName: appModel.isMutating ? "arrow.triangle.2.circlepath" : "ellipsis").font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white).frame(width: Self.chromeControlHeight, height: Self.chromeControlHeight).background(
                            Capsule().fill(.black.opacity(0.28)).overlay(Capsule().strokeBorder(.white.opacity(0.10), lineWidth: 1)))
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
        VStack(spacing: 18) {
            Spacer(minLength: 0)
            Image(
                systemName: model.isOwner && model.isPreparingInput || model.isTakingOver || model.isConnecting
                    ? "arrow.triangle.2.circlepath.circle.fill" : "lock.desktopcomputer"
            ).font(.system(size: 34, weight: .semibold)).foregroundStyle(.white.opacity(0.82))
            Text(model.visibleText).font(.body.monospaced()).foregroundStyle(.white.opacity(0.88)).multilineTextAlignment(.center).padding(
                .horizontal, 28)
            if model.showsTakeOverAction { takeOverButton.padding(.top, 4) }
            Spacer(minLength: 0)
        }.frame(maxWidth: .infinity, maxHeight: .infinity).background(Self.surfaceBackground)
    }

    private func chromeButton<Label: View>(
        accessibilityIdentifier: String, accessibilityLabel: String, action: @escaping () -> Void, @ViewBuilder label: () -> Label
    ) -> some View {
        Button(action: action) {
            label().foregroundStyle(.white).frame(height: Self.chromeControlHeight).padding(.horizontal, 18).background(
                Capsule().fill(.black.opacity(0.28)).overlay(Capsule().strokeBorder(.white.opacity(0.10), lineWidth: 1)))
        }.accessibilityElement(children: .ignore).accessibilityLabel(accessibilityLabel).accessibilityIdentifier(accessibilityIdentifier)
    }

    private func chromeActivityBadge(accessibilityLabel: String) -> some View {
        ZStack { ProgressView().controlSize(.small).tint(.white.opacity(0.9)) }.frame(
            width: Self.chromeControlHeight, height: Self.chromeControlHeight
        ).background(Capsule().fill(.black.opacity(0.18)).overlay(Capsule().strokeBorder(.white.opacity(0.08), lineWidth: 1))).accessibilityElement(
            children: .ignore
        ).accessibilityLabel(accessibilityLabel)
    }

    private func errorBanner(_ message: String) -> some View {
        Text(message).font(.footnote).foregroundStyle(.red).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).padding(
            .vertical, 12
        ).background(Color(uiColor: .secondarySystemBackground)).accessibilityIdentifier("terminal.errorBanner")
    }

    private func noticeBanner(_ message: String) -> some View {
        Text(message).font(.footnote).foregroundStyle(.primary).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).padding(
            .vertical, 12
        ).background(Color(uiColor: .secondarySystemBackground)).accessibilityIdentifier("terminal.linkNotice")
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

    /// Change identity for the e2e dump task, and nothing else. Building it reads seventeen model
    /// properties and joins them, on every body evaluation of a view that re-evaluates at the session's
    /// flush rate; `writeE2EDumpIfNeeded` is gated on the same condition, so outside an e2e run the key
    /// collapses to a constant and the task never re-runs.
    private var e2eDumpStateKey: String {
        guard shouldCaptureRenderedText else { return "" }
        return [
            model.title, model.renderStateKey, model.isOwner ? "owner" : "viewer", model.showsTerminalSurface ? "surface" : "status",
            model.isConnecting ? "connecting" : "steady", model.isBusy ? "busy" : "idle",
            model.isOwnershipSynchronizationScheduled ? "syncScheduled" : "syncNotScheduled", model.isSynchronizingOwnership ? "syncing" : "synced",
            model.isPreparingInput ? "preparing" : "prepared", model.isInputSurfaceReady ? "inputReady" : "inputPending", model.errorMessage ?? "",
            model.isPreparingLinkPreview ? "previewPreparing" : "previewIdle", model.linkPreview?.title ?? "",
            model.linkPreview?.kind?.rawValue ?? "", model.linkPreview?.content.caseName ?? "", model.linkPreviewErrorMessage ?? "",
            model.linkNotice ?? "", renderedText,
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
                snapshotRows: model.snapshotRows, snapshotText: model.snapshotText, errorMessage: model.errorMessage,
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
                    if let key = request.key?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty {
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

private struct E2ECommandRequest: Decodable {
    let id: String
    let text: String?
    let key: String?
    let sendEnter: Bool?

    var detail: String { ["id=\(id)", "sendEnter=\(sendEnter ?? true)", "text=\(text ?? "")", "key=\(key ?? "")"].joined(separator: " ") }
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
    /// gets the selectable monospaced text view, Markdown gets the rendered/raw viewer, a local HTML
    /// artifact and an external web page both use the isolated web view (file mode vs. request mode).
    @ViewBuilder private var content: some View {
        switch preview.content {
        case .quickLook(let url): TerminalQuickLookPreview(url: url)
        case .text(let url): TerminalTextArtifactView(url: url)
        case .markdown(let url): TerminalMarkdownArtifactView(url: url)
        case .htmlFile(let url): TerminalWebArtifactView(load: .fileURL(url))
        case .webPage(let url): TerminalWebArtifactView(load: .request(url))
        }
    }

    /// File-backed content (all except `.webPage`) offers Share to hand the on-device file to another app;
    /// an external web page has no local file, so its equivalent affordance is opening the URL in Safari.
    @ToolbarContentBuilder private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            switch preview.content {
            case .quickLook(let url), .text(let url), .markdown(let url), .htmlFile(let url):
                ShareLink(item: url) { Label("Open In", systemImage: "square.and.arrow.up") }
            case .webPage(let url):
                Button {
                    UIApplication.shared.open(url)
                } label: {
                    Label("Open in Safari", systemImage: "safari")
                }.accessibilityIdentifier("terminal.linkPreview.openInSafari")
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
