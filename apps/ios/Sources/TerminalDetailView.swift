import SwiftUI
import spacesterminalmobileghostty
import spacesmobilecore

struct TerminalDetailView: View {
    private static let chromeControlHeight: CGFloat = 48

    let session: SpacesMobileTerminalSessionSummary
    let settings: SpacesMobileConnectionSettings
    let onAuthenticationRequired: @MainActor @Sendable (String) -> Void
    let onBack: () -> Void

    @State private var hasMountedTerminalSurface = false
    @State private var renderedText = ""
    @State private var model: TerminalViewerModel
    private var e2eConfig: SpacesMobileE2EConfig { .shared }
    private var shouldCaptureRenderedText: Bool { e2eConfig.isEnabled && e2eConfig.matches(sessionID: session.id) }
    private var e2eCommandRequestPath: String? {
        guard e2eConfig.isEnabled, e2eConfig.matches(sessionID: session.id), let eventLogPath = e2eConfig.eventLogPath else { return nil }
        return "\(eventLogPath).command-request.json"
    }

    init(
        session: SpacesMobileTerminalSessionSummary,
        settings: SpacesMobileConnectionSettings,
        onAuthenticationRequired: @escaping @MainActor @Sendable (String) -> Void,
        onBack: @escaping () -> Void
    ) {
        self.session = session
        self.settings = settings
        self.onAuthenticationRequired = onAuthenticationRequired
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
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 10)

            Group {
                if hasMountedTerminalSurface || model.showsTerminalSurface {
                    ZStack {
                        GhosttyRemoteTerminalView(
                            ownerEpoch: model.ownerRenderEpoch,
                            endedRender: model.endedRender,
                            fallbackText: model.visibleText,
                            isVisible: model.shouldPresentLiveSurface,
                            acceptsInput: model.keepsTerminalInputSurfaceActive,
                            isBusy: false,
                            onInputReadinessChanged: { ready in
                                model.setInputSurfaceReady(ready)
                                writeE2EEventIfNeeded(kind: "input_readiness", detail: ready ? "ready" : "pending")
                            },
                            onOutputBatchApplied: { batchID in
                                model.markOwnerRenderOutputApplied(batchID)
                            },
                            onHistorySeedApplied: { batchID in
                                model.markOwnerHistorySeedApplied(batchID)
                            },
                            onScrollGestureApplied: {
                                writeE2EEventIfNeeded(kind: "e2e_scroll_gesture_applied", detail: nil)
                            },
                            onRenderedTextChanged: shouldCaptureRenderedText ? { text in
                                renderedText = text
                            } : nil,
                            onViewportSizeChanged: { columns, rows in
                                model.updateViewportSize(columns: columns, rows: rows)
                            },
                            onSendText: { text in
                                sendTerminalText(text)
                            },
                            onSendKey: { key in
                                sendTerminalKey(key)
                            }
                        )
                        .accessibilityIdentifier("terminal.surface")
                        .allowsHitTesting(model.shouldPresentLiveSurface)
                        .accessibilityHidden(!model.shouldPresentLiveSurface)
                        .background(Color(red: 0.10, green: 0.12, blue: 0.15))

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

            if let errorMessage = model.errorMessage {
                errorBanner(errorMessage)
            }
        }
        .background(Color(red: 0.10, green: 0.12, blue: 0.15).ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .task { model.start() }
        .task(id: e2eDumpStateKey) { writeE2EDumpIfNeeded() }
        .task(id: e2eCommandRequestPath) { await consumeE2ECommandRequestsIfNeeded() }
        .onChange(of: model.showsTerminalSurface) { showsTerminalSurface in
            if showsTerminalSurface { hasMountedTerminalSurface = true }
            if !showsTerminalSurface { renderedText = "" }
        }
        .onChange(of: model.shouldPresentLiveSurface) { shouldPresentLiveSurface in
            writeE2EEventIfNeeded(kind: "surface_visibility", detail: shouldPresentLiveSurface ? "visible" : "hidden")
        }
        .onDisappear { model.stop() }
        .accessibilityIdentifier("terminal.detail.\(session.id)")
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

    private var topOverlay: some View {
        HStack(spacing: 12) {
            chromeButton {
                onBack()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.headline.weight(.semibold))
            }
            .accessibilityIdentifier("terminal.back")

            Spacer(minLength: 0)

            Text(model.title)
                .font(.headline.weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .accessibilityIdentifier("terminal.title")

            Spacer(minLength: 0)

            Group {
                if model.isOwner {
                    if model.isPreparingInput {
                        chromeActivityBadge(accessibilityLabel: "Preparing input")
                            .accessibilityIdentifier("terminal.ownerPreparing")
                    } else {
                        chromeBadge("Owner")
                            .accessibilityIdentifier("terminal.ownerBadge")
                    }
                } else if model.isTakingOver || model.isConnecting {
                    chromeProgressBadge("Taking over…")
                        .accessibilityIdentifier("terminal.takingOver")
                } else {
                    chromeButton {
                        Task { await model.takeOver() }
                    } label: {
                        Text("Take Over")
                            .font(.headline.weight(.semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .disabled(model.isBusy)
                    .accessibilityIdentifier("terminal.takeover")
                }
            }
        }
        .frame(height: Self.chromeControlHeight)
        .overlay(alignment: .center) {
            if model.isConnecting {
                ProgressView()
                    .controlSize(.small)
                    .tint(.white)
            }
        }
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
                .accessibilityIdentifier("terminal.statusText")
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(red: 0.10, green: 0.12, blue: 0.15))
    }

    private func chromeButton<Label: View>(action: @escaping () -> Void, @ViewBuilder label: () -> Label) -> some View {
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
    }

    private func chromeBadge(_ text: String) -> some View {
        Text(text)
            .font(.headline.weight(.semibold))
            .foregroundStyle(.white.opacity(0.9))
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .padding(.horizontal, 18)
            .frame(height: Self.chromeControlHeight)
            .background(
                Capsule()
                    .fill(.black.opacity(0.18))
                    .overlay(Capsule().strokeBorder(.white.opacity(0.08), lineWidth: 1))
            )
    }

    private func chromeProgressBadge(_ text: String) -> some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
                .tint(.white.opacity(0.9))
            Text(text)
                .font(.headline.weight(.semibold))
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .padding(.horizontal, 16)
        .frame(height: Self.chromeControlHeight)
        .background(
            Capsule()
                .fill(.black.opacity(0.18))
                .overlay(Capsule().strokeBorder(.white.opacity(0.08), lineWidth: 1))
        )
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

    private var e2eDumpStateKey: String {
        [
            model.title,
            model.replayStateKey,
            model.isOwner ? "owner" : "viewer",
            model.showsTerminalSurface ? "surface" : "status",
            model.isConnecting ? "connecting" : "steady",
            model.isBusy ? "busy" : "idle",
            model.isOwnershipSynchronizationScheduled ? "syncScheduled" : "syncNotScheduled",
            model.isSynchronizingOwnership ? "syncing" : "synced",
            model.isPreparingInput ? "preparing" : "prepared",
            model.isInputSurfaceReady ? "inputReady" : "inputPending",
            model.errorMessage ?? "",
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
                transcriptTail: model.transcriptTail,
                errorMessage: model.errorMessage,
                visibleText: model.visibleText,
                renderedText: renderedText,
                replayStateKey: model.replayStateKey,
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
                    writeE2EEventIfNeeded(
                        kind: "e2e_command_request_consumed",
                        detail: "id=\(request.id) sendEnter=\(request.sendEnter ?? true) text=\(request.text)"
                    )
                    await model.sendText(request.text)
                    if request.sendEnter ?? true {
                        await model.sendKey("enter")
                    }
                } else {
                    writeE2EEventIfNeeded(kind: "e2e_command_request_invalid", detail: requestURL.lastPathComponent)
                }
                try? FileManager.default.removeItem(at: requestURL)
            }
            try? await Task.sleep(for: .milliseconds(150))
        }
    }
}

private struct E2ECommandRequest: Decodable {
    let id: String
    let text: String
    let sendEnter: Bool?
}
