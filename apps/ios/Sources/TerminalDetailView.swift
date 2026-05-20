import SwiftUI
import spacesterminalmobileghostty
import spacesmobilecore

struct TerminalDetailView: View {
    let session: SpacesMobileTerminalSessionSummary
    let settings: SpacesMobileConnectionSettings
    let onAuthenticationRequired: @MainActor @Sendable (String) -> Void
    let onBack: () -> Void

    @State private var renderedText = ""
    @State private var model: TerminalViewerModel
    private let e2eConfig = SpacesMobileE2EConfig.shared

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

            GhosttyRemoteTerminalView(
                snapshot: model.snapshot,
                replayStateKey: model.replayStateKey,
                fallbackText: model.visibleText,
                acceptsInput: model.acceptsInput,
                isBusy: model.isBusy || model.isSynchronizingOwnership,
                onInputReadinessChanged: { ready in
                    model.setInputSurfaceReady(ready)
                },
                onRenderedTextChanged: { text in
                    renderedText = text
                },
                onViewportSizeChanged: { columns, rows in
                    model.updateViewportSize(columns: columns, rows: rows)
                },
                onSendText: { text in
                    Task { await model.sendText(text) }
                },
                onSendKey: { key in
                    Task { await model.sendKey(key) }
                }
            )
            .background(Color(red: 0.10, green: 0.12, blue: 0.15))

            if let errorMessage = model.errorMessage {
                errorBanner(errorMessage)
            }
        }
        .background(Color(red: 0.10, green: 0.12, blue: 0.15).ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .task { model.start() }
        .task(id: e2eDumpStateKey) { writeE2EDumpIfNeeded() }
        .onDisappear { model.stop() }
        .accessibilityIdentifier("terminal.detail.\(session.id)")
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
                        chromeProgressBadge("Preparing input…")
                            .accessibilityIdentifier("terminal.ownerPreparing")
                    } else {
                        chromeBadge("Owner")
                            .accessibilityIdentifier("terminal.ownerBadge")
                    }
                } else {
                    chromeButton {
                        Task { await model.takeOver() }
                    } label: {
                        Text("Take Over")
                            .font(.headline.weight(.semibold))
                    }
                    .disabled(model.isBusy)
                    .accessibilityIdentifier("terminal.takeover")
                }
            }
        }
        .overlay(alignment: .center) {
            if model.isConnecting {
                ProgressView()
                    .controlSize(.small)
                    .tint(.white)
            }
        }
    }

    private func chromeButton<Label: View>(action: @escaping () -> Void, @ViewBuilder label: () -> Label) -> some View {
        Button(action: action) {
            label()
                .foregroundStyle(.white)
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
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
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
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
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(
            Capsule()
                .fill(.black.opacity(0.18))
                .overlay(Capsule().strokeBorder(.white.opacity(0.08), lineWidth: 1))
        )
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
            model.isConnecting ? "connecting" : "steady",
            model.isBusy ? "busy" : "idle",
            model.isSynchronizingOwnership ? "syncing" : "synced",
            model.isInputSurfaceReady ? "inputReady" : "inputPending",
            model.errorMessage ?? "",
            renderedText,
        ].joined(separator: "|")
    }

    private func writeE2EDumpIfNeeded() {
        guard e2eConfig.isEnabled, e2eConfig.matches(sessionID: session.id) else { return }
        SpacesMobileE2EDumpWriter.writeCurrentDump(
            .init(
                sessionID: session.id,
                title: model.title,
                isOwner: model.isOwner,
                isConnecting: model.isConnecting,
                isBusy: model.isBusy,
                isSynchronizingOwnership: model.isSynchronizingOwnership,
                isInputSurfaceReady: model.isInputSurfaceReady,
                viewportColumns: model.viewportColumns,
                viewportRows: model.viewportRows,
                lastSentResizeColumns: model.lastSentResizeColumns,
                lastSentResizeRows: model.lastSentResizeRows,
                runtimeColumns: model.runtimeColumns,
                runtimeRows: model.runtimeRows,
                snapshotColumns: model.snapshotColumns,
                snapshotRows: model.snapshotRows,
                errorMessage: model.errorMessage,
                visibleText: model.visibleText,
                renderedText: renderedText,
                replayStateKey: model.replayStateKey,
                emittedAt: model.latestState?.emittedAt ?? ISO8601DateFormatter().string(from: Date())
            ),
            config: e2eConfig
        )
    }
}
