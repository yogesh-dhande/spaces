import SwiftUI
import spacesterminalmobileghostty
import spacesmobilecore

struct TerminalDetailView: View {
    let session: SpacesMobileTerminalSessionSummary
    let settings: SpacesMobileConnectionSettings

    @State private var model: TerminalViewerModel

    init(session: SpacesMobileTerminalSessionSummary, settings: SpacesMobileConnectionSettings) {
        self.session = session
        self.settings = settings
        _model = State(initialValue: TerminalViewerModel(session: session, settings: settings))
    }

    var body: some View {
        VStack(spacing: 0) {
            GhosttyRemoteTerminalView(
                snapshot: model.snapshot,
                fallbackText: model.visibleText,
                acceptsInput: model.isOwner,
                isBusy: model.isBusy,
                onSendText: { text in
                    Task { await model.sendText(text) }
                },
                onSendKey: { key in
                    Task { await model.sendKey(key) }
                }
            )
            .background(Color(red: 0.10, green: 0.12, blue: 0.15))
            .overlay(alignment: .topTrailing) {
                if model.isConnecting {
                    ProgressView()
                        .controlSize(.small)
                        .padding(12)
                }
            }

            if let errorMessage = model.errorMessage {
                Divider()
                errorBanner(errorMessage)
            }
        }
        .navigationTitle(model.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !model.isOwner {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Take Over") {
                        Task { await model.takeOver() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isBusy)
                }
            }
        }
        .task { model.start() }
        .onDisappear { model.stop() }
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
