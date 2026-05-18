import SwiftUI
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
            header
            Divider()
            ScrollView([.horizontal, .vertical]) {
                Text(model.visibleText)
                    .font(.system(size: 13, weight: .regular, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(16)
                    .textSelection(.enabled)
            }
            .background(Color(red: 0.10, green: 0.12, blue: 0.15))
            .foregroundStyle(.white)

            Divider()
            inputBar
        }
        .navigationTitle(model.title)
        .navigationBarTitleDisplayMode(.inline)
        .task { model.start() }
        .onDisappear { model.stop() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text(model.isOwner ? "Owner" : "Viewer")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background((model.isOwner ? Color.green : Color.orange).opacity(0.18), in: Capsule())
                    .foregroundStyle(model.isOwner ? Color.green : Color.orange)

                if model.isConnecting {
                    ProgressView()
                        .controlSize(.small)
                }

                Spacer()

                if !model.isOwner {
                    Button("Take Over") {
                        Task { await model.takeOver() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isBusy)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                detailRow("Workspace", session.workspaceTitle ?? "Unassigned")
                detailRow("Owner", model.ownerLabel)
                detailRow("Directory", model.workingDirectory)
                detailRow("Session", session.id)
            }

            if let errorMessage = model.errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
        .padding(16)
        .background(Color(uiColor: .secondarySystemBackground))
    }

    private var inputBar: some View {
        @Bindable var bindableModel = model

        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                TextField("Send a command line", text: $bindableModel.pendingLine)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.system(.body, design: .monospaced))
                    .onSubmit {
                        Task { await model.sendLine() }
                    }

                Button("Send Line") {
                    Task { await model.sendLine() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.isOwner || model.pendingLine.isEmpty || model.isBusy)
            }

            HStack(spacing: 10) {
                controlButton("Enter") { await model.sendKey("enter") }
                controlButton("Esc") { await model.sendKey("esc") }
                controlButton("Ctrl-C") { await model.sendKey("ctrl+c") }
            }
        }
        .padding(16)
        .background(Color(uiColor: .systemBackground))
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 72, alignment: .leading)
            Text(value)
                .font(.caption)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
        }
    }

    private func controlButton(_ title: String, action: @escaping @Sendable () async -> Void) -> some View {
        Button(title) {
            Task { await action() }
        }
        .buttonStyle(.bordered)
        .disabled(!model.isOwner || model.isBusy)
    }
}
