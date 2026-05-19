import SwiftUI
import spacesterminalmobileghostty
import spacesmobilecore

struct TerminalDetailView: View {
    let session: SpacesMobileTerminalSessionSummary
    let settings: SpacesMobileConnectionSettings
    let onAuthenticationRequired: @MainActor @Sendable (String) -> Void
    let onBack: () -> Void

    @State private var model: TerminalViewerModel

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
                fallbackText: model.visibleText,
                acceptsInput: model.isOwner,
                isBusy: model.isBusy,
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
        .onDisappear { model.stop() }
    }

    private var topOverlay: some View {
        HStack(spacing: 12) {
            chromeButton {
                onBack()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.headline.weight(.semibold))
            }

            Spacer(minLength: 0)

            Text(model.title)
                .font(.headline.weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(1)

            Spacer(minLength: 0)

            Group {
                if model.isOwner {
                    chromeBadge("Owner")
                } else {
                    chromeButton {
                        Task { await model.takeOver() }
                    } label: {
                        Text("Take Over")
                            .font(.headline.weight(.semibold))
                    }
                    .disabled(model.isBusy)
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

    private func errorBanner(_ message: String) -> some View {
        Text(message)
            .font(.footnote)
            .foregroundStyle(.red)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color(uiColor: .secondarySystemBackground))
    }
}
