import QuickLook
import SwiftUI
import spacesterminalmobileghostty
import spacesdevicecore
import spacesterminalcore

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
    private var e2eConfig: SpacesMobileE2EConfig { .shared }
    private var shouldCaptureRenderedText: Bool { e2eConfig.isEnabled && e2eConfig.matches(sessionID: session.id) }
    private var e2eCommandRequestPath: String? {
        guard e2eConfig.isEnabled, e2eConfig.matches(sessionID: session.id), let eventLogPath = e2eConfig.eventLogPath else { return nil }
        return "\(eventLogPath).command-request.json"
    }

    init(
        session: SpacesDeviceTerminalSessionSummary,
        settings: SpacesMobileConnectionSettings,
        appModel: SpacesMobileAppModel,
        onAuthenticationRequired: @escaping @MainActor @Sendable (String) -> Void,
        onSessionChanged: @escaping (SpacesDeviceTerminalSessionSummary) -> Void,
        onBack: @escaping () -> Void
    ) {
        self.session = session
        self.settings = settings
        self.appModel = appModel
        self.onAuthenticationRequired = onAuthenticationRequired
        self.onSessionChanged = onSessionChanged
        self.onBack = onBack
        _model = State(
            initialValue: TerminalViewerModel(
                session: session,
                settings: settings,
                onAuthenticationRequired: onAuthenticationRequired
            )
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            topOverlay
                .padding(.horizontal, 8)
                .padding(.top, 4)
                .padding(.bottom, 4)

            Group {
                if hasMountedTerminalSurface || model.showsTerminalSurface {
                    ZStack {
                        GhosttyRemoteTerminalView(
                            ownerEpoch: model.ownerRenderEpoch,
                            endedRender: model.endedRender,
                            fallbackText: model.visibleText,
                            isVisible: model.shouldPresentLiveSurface,
                            acceptsInput: model.keepsTerminalInputSurfaceActive,
                            isBusy: model.isBusy,
                            onInputReadinessChanged: { ready in
                                model.setInputSurfaceReady(ready)
                                writeE2EEventIfNeeded(kind: "input_readiness", detail: ready ? "ready" : "pending")
                            },
                            onScrollGestureApplied: {
                                writeE2EEventIfNeeded(kind: "e2e_scroll_gesture_applied", detail: nil)
                                model.flushPendingScroll()
                            },
                            onRenderedTextChanged: shouldCaptureRenderedText ? { text in
                                renderedText = text
                                model.recordRenderedText(text)
                            } : nil,
                            onViewportSizeChanged: { columns, rows in
                                model.updateViewportSize(columns: columns, rows: rows)
                            },
                            onSendText: { text in
                                sendTerminalText(text)
                            },
                            onSendKey: { key in
                                sendTerminalKey(key)
                            },
                            onSendScroll: { horizontal, vertical, scrollMods in
                                sendTerminalScroll(horizontal: horizontal, vertical: vertical, scrollMods: scrollMods)
                            },
                            onOpenLink: { link in
                                openTerminalLink(link)
                            },
                            onOpenComposer: {
                                isShowingComposer = true
                            }
                        )
                        .accessibilityIdentifier("terminal.surface")
                        .allowsHitTesting(model.shouldPresentLiveSurface)
                        .accessibilityHidden(!model.shouldPresentLiveSurface)
                        .background(Self.surfaceBackground)

                        if !model.shouldPresentLiveSurface {
                            statusShell
                                .onAppear { renderedText = "" }
                        }
                    }
                } else {
                    statusShell
                        .onAppear { renderedText = "" }
                }
            }
            .overlay(alignment: .bottom) {
                linkPreviewBannerOverlay
            }

            if let errorMessage = model.errorMessage {
                errorBanner(errorMessage)
            }
        }
        .background(Self.surfaceBackground.ignoresSafeArea())
        .accessibilityIdentifier("terminal.detail.\(session.id)")
        .toolbar(.hidden, for: .navigationBar)
        .task { model.start() }
        .task(id: session.id) { await refreshRuntimeRowsWhileVisible() }
        .task(id: e2eDumpStateKey) { writeE2EDumpIfNeeded() }
        .task(id: e2eCommandRequestPath) { await consumeE2ECommandRequestsIfNeeded() }
        .onChange(of: model.showsTerminalSurface) { showsTerminalSurface in
            if showsTerminalSurface { hasMountedTerminalSurface = true }
            if !showsTerminalSurface { renderedText = "" }
        }
        .onChange(of: model.shouldPresentLiveSurface) { shouldPresentLiveSurface in
            writeE2EEventIfNeeded(kind: "surface_visibility", detail: shouldPresentLiveSurface ? "visible" : "hidden")
        }
        .onChange(of: colorScheme) { newColorScheme in
            Task { await model.sendAppearance(newColorScheme == .dark ? .dark : .light) }
        }
        .sheet(
            item: Binding(
                get: { model.linkPreview },
                set: { preview in
                    if preview == nil { model.dismissLinkPreview() }
                })
        ) { preview in
            TerminalLinkPreviewSheet(preview: preview)
        }
        .sheet(isPresented: $isShowingComposer) {
            TerminalComposerSheet(model: model, stagedScreenshots: appModel.stagedScreenshots)
        }
        .onDisappear { model.stop() }
    }

    private var linkPreviewBannerOverlay: some View {
        VStack(spacing: 0) {
            if model.isPreparingLinkPreview {
                previewStatusBanner("Preparing preview…")
            }
            if let previewErrorMessage = model.linkPreviewErrorMessage {
                errorBanner(previewErrorMessage)
            }
        }
        .allowsHitTesting(false)
    }

    private func sendTerminalText(_ text: String) {
        guard !text.isEmpty else { return }
        writeE2EEventIfNeeded(kind: "send_text", detail: text)
        Task { await model.sendText(text) }
    }

    private func sendTerminalKey(_ key: String) {
        writeE2EEventIfNeeded(kind: "send_key", detail: key)
        Task { await model.sendKey(key) }
    }

    private func sendTerminalScroll(horizontal: Double, vertical: Double, scrollMods: Int32) {
        writeE2EEventIfNeeded(kind: "send_scroll", detail: "\(horizontal),\(vertical)")
        Task { await model.sendScroll(horizontal: horizontal, vertical: vertical, scrollMods: scrollMods) }
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
                Image(systemName: isBackNavigationInProgress ? "arrow.triangle.2.circlepath" : "chevron.left")
                    .font(.subheadline.weight(.semibold))
            }
            .disabled(isBackNavigationInProgress)

            Spacer(minLength: 0)

            Text(runtimeRow?.title ?? model.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(1)

            Spacer(minLength: 0)

            trailingChrome
            .frame(minWidth: Self.chromeControlHeight, alignment: .trailing)
        }
        .frame(height: Self.chromeControlHeight)
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
                        }
                        .disabled(appModel.isMutating)
                    }
                    if row.canRestartFromTerminalDetail {
                        Button {
                            Task { await restartRuntime(row) }
                        } label: {
                            Label("Restart", systemImage: "arrow.clockwise")
                        }
                        .disabled(appModel.isMutating)
                    }
                    if row.canStopFromTerminalDetail {
                        Button(role: .destructive) {
                            Task { await appModel.stop(row: row) }
                        } label: {
                            Label("Stop", systemImage: "stop.fill")
                        }
                        .disabled(appModel.isMutating)
                    }
                } label: {
                    Image(systemName: appModel.isMutating ? "arrow.triangle.2.circlepath" : "ellipsis")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(width: Self.chromeControlHeight, height: Self.chromeControlHeight)
                        .background(
                            Capsule()
                                .fill(.black.opacity(0.28))
                                .overlay(Capsule().strokeBorder(.white.opacity(0.10), lineWidth: 1))
                        )
                }
                .disabled(appModel.isMutating)
                .accessibilityLabel("Terminal actions")
                .accessibilityIdentifier("terminal.runtimeActions")
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
                chromeActivityBadge(accessibilityLabel: "Preparing input")
                    .accessibilityIdentifier("terminal.ownerPreparing")
            } else {
                // Ownership is obvious from the absence of the Take Over button,
                // so no visible tag is shown. An invisible marker preserves the
                // ownership signal for UI tests.
                ownerStateMarker
            }
        }
    }

    private func runRuntime(_ row: SpacesMobileWorkspaceRuntimeRow) async {
        if let session = await appModel.run(row: row) {
            onSessionChanged(session)
        }
    }

    private func restartRuntime(_ row: SpacesMobileWorkspaceRuntimeRow) async {
        if let session = await appModel.restart(row: row) {
            onSessionChanged(session)
        }
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
            Text("Take Over")
                .font(.headline.weight(.semibold))
                .foregroundStyle(Theme.primaryButtonText)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .padding(.horizontal, 14)
                .frame(height: Self.chromeControlHeight)
                .background(Capsule().fill(Theme.primaryButtonFill))
        }
        .buttonStyle(.plain)
        .disabled(model.isBusy)
        .accessibilityLabel("Take Over")
        .accessibilityIdentifier("terminal.takeover")
        .accessibilityElement(children: .ignore)
    }

    /// Zero-visual-footprint accessibility marker that preserves the ownership
    /// signal used by UI tests now that the visible "Owner" tag is removed.
    private var ownerStateMarker: some View {
        Text("Owner")
            .font(.caption2)
            .foregroundStyle(.clear)
            .frame(width: 1, height: 1)
            .clipped()
            .accessibilityIdentifier("terminal.ownerBadge")
    }

    private var statusShell: some View {
        VStack(spacing: 18) {
            Spacer(minLength: 0)
            Image(
                systemName: model.isOwner && model.isPreparingInput || model.isTakingOver || model.isConnecting
                    ? "arrow.triangle.2.circlepath.circle.fill" : "lock.desktopcomputer"
            )
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(.white.opacity(0.82))
            Text(model.visibleText)
                .font(.body.monospaced())
                .foregroundStyle(.white.opacity(0.88))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)
            if model.showsTakeOverAction {
                takeOverButton
                    .padding(.top, 4)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Self.surfaceBackground)
    }

    private func chromeButton<Label: View>(
        accessibilityIdentifier: String,
        accessibilityLabel: String,
        action: @escaping () -> Void,
        @ViewBuilder label: () -> Label
    ) -> some View {
        Button(action: action) {
            label()
                .foregroundStyle(.white)
                .frame(height: Self.chromeControlHeight)
                .padding(.horizontal, 18)
                .background(
                    Capsule()
                        .fill(.black.opacity(0.28))
                        .overlay(Capsule().strokeBorder(.white.opacity(0.10), lineWidth: 1))
                )
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityIdentifier(accessibilityIdentifier)
    }

    private func chromeActivityBadge(accessibilityLabel: String) -> some View {
        ZStack {
            ProgressView()
                .controlSize(.small)
                .tint(.white.opacity(0.9))
        }
        .frame(width: Self.chromeControlHeight, height: Self.chromeControlHeight)
        .background(
            Capsule()
                .fill(.black.opacity(0.18))
                .overlay(Capsule().strokeBorder(.white.opacity(0.08), lineWidth: 1))
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private func errorBanner(_ message: String) -> some View {
        Text(message)
            .font(.footnote)
            .foregroundStyle(.red)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color(uiColor: .secondarySystemBackground))
            .accessibilityIdentifier("terminal.errorBanner")
    }

    private func previewStatusBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
                .tint(.white.opacity(0.9))
            Text(message)
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.86))
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.black.opacity(0.32))
        .accessibilityIdentifier("terminal.previewStatus")
    }

    private var e2eDumpStateKey: String {
        [
            model.title,
            model.renderStateKey,
            model.isOwner ? "owner" : "viewer",
            model.showsTerminalSurface ? "surface" : "status",
            model.isConnecting ? "connecting" : "steady",
            model.isBusy ? "busy" : "idle",
            model.isOwnershipSynchronizationScheduled ? "syncScheduled" : "syncNotScheduled",
            model.isSynchronizingOwnership ? "syncing" : "synced",
            model.isPreparingInput ? "preparing" : "prepared",
            model.isInputSurfaceReady ? "inputReady" : "inputPending",
            model.errorMessage ?? "",
            model.isPreparingLinkPreview ? "previewPreparing" : "previewIdle",
            model.linkPreview?.title ?? "",
            model.linkPreview?.mediaKind.rawValue ?? "",
            model.linkPreviewErrorMessage ?? "",
            shouldCaptureRenderedText ? renderedText : "",
        ].joined(separator: "|")
    }

    private func writeE2EDumpIfNeeded() {
        guard e2eConfig.isEnabled, e2eConfig.matches(sessionID: session.id) else { return }
        SpacesMobileE2EDumpWriter.writeCurrentDump(
            .init(
                sessionID: session.id,
                title: model.title,
                renderMode: model.renderMode,
                isOwner: model.isOwner,
                showsTerminalSurface: model.showsTerminalSurface,
                isConnecting: model.isConnecting,
                isBusy: model.isBusy,
                isOwnershipSynchronizationScheduled: model.isOwnershipSynchronizationScheduled,
                isSynchronizingOwnership: model.isSynchronizingOwnership,
                isPreparingInput: model.isPreparingInput,
                isInputSurfaceReady: model.isInputSurfaceReady,
                viewportColumns: model.viewportColumns,
                viewportRows: model.viewportRows,
                lastSentResizeColumns: model.lastSentResizeColumns,
                lastSentResizeRows: model.lastSentResizeRows,
                runtimeColumns: model.runtimeColumns,
                runtimeRows: model.runtimeRows,
                snapshotColumns: model.snapshotColumns,
                snapshotRows: model.snapshotRows,
                snapshotText: model.snapshotText,
                errorMessage: model.errorMessage,
                isPreparingLinkPreview: model.isPreparingLinkPreview,
                linkPreviewTitle: model.linkPreview?.title,
                linkPreviewMediaKind: model.linkPreview?.mediaKind,
                linkPreviewErrorMessage: model.linkPreviewErrorMessage,
                visibleText: model.visibleText,
                renderedText: renderedText,
                renderStateKey: model.renderStateKey,
                emittedAt: model.latestState?.emittedAt ?? ISO8601DateFormatter().string(from: Date())
            ),
            config: e2eConfig
        )
    }

    private func writeE2EEventIfNeeded(kind: String, detail: String?) {
        guard e2eConfig.isEnabled, e2eConfig.matches(sessionID: session.id) else { return }
        SpacesMobileE2EDumpWriter.appendEvent(
            .init(
                sessionID: session.id,
                kind: kind,
                detail: detail,
                emittedAt: ISO8601DateFormatter().string(from: Date())
            ),
            config: e2eConfig
        )
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
                    writeE2EEventIfNeeded(
                        kind: "e2e_command_request_consumed",
                        detail: requestDetail
                    )
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

    var detail: String {
        [
            "id=\(id)",
            "sendEnter=\(sendEnter ?? true)",
            "text=\(text ?? "")",
            "key=\(key ?? "")",
        ].joined(separator: " ")
    }
}

private struct TerminalLinkPreviewSheet: View {
    let preview: TerminalLinkPreview

    var body: some View {
        NavigationStack {
            TerminalQuickLookPreview(url: preview.url)
                .ignoresSafeArea(edges: .bottom)
                .accessibilityIdentifier("terminal.linkPreview")
                .navigationTitle(preview.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        ShareLink(item: preview.url) {
                            Label("Open In", systemImage: "square.and.arrow.up")
                        }
                    }
                }
        }
    }
}

private struct TerminalQuickLookPreview: UIViewControllerRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator {
        Coordinator(url: url)
    }

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

        init(url: URL) {
            self.url = url
        }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> any QLPreviewItem {
            url as NSURL
        }
    }
}
