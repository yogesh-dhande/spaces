import SwiftUI
import spacesmobilecore

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedSession: SpacesMobileTerminalSessionSummary?
    @State private var pendingAuthenticationMessage: String?
    @State private var terminalListRefreshGeneration = 0
    let model: SpacesMobileAppModel

    var body: some View {
        NavigationStack {
            terminalHomeView
                .navigationTitle("Terminals")
                .toolbar {
                    toolbarContent
                }
                .navigationDestination(isPresented: selectedSessionPresentationBinding) {
                    if let selectedSession {
                        TerminalDetailView(
                            session: selectedSession,
                            settings: model.settings,
                            onAuthenticationRequired: { message in
                                pendingAuthenticationMessage = message
                                self.selectedSession = nil
                            }
                        ) {
                            self.selectedSession = nil
                        }
                    }
                }
        }
        .sheet(isPresented: connectionSettingsBinding) {
            ConnectionSettingsView(initialSettings: model.settings, noticeMessage: model.connectionNotice) { settings in
                model.applyConnectionSettings(settings)
                Task { await model.refresh() }
            }
        }
        .alert(
            "Connection Error",
            isPresented: errorAlertBinding
        ) {
            Button("OK", role: .cancel) { model.dismissError() }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .task(id: refreshLoopTaskID) {
            guard scenePhase == .active else { return }
            if model.overview == nil {
                if !model.settings.isPaired {
                    model.isShowingConnectionSettings = true
                    return
                }
            }
            guard !model.isShowingConnectionSettings, selectedSession == nil else { return }
            await model.refresh()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                guard scenePhase == .active, !model.isShowingConnectionSettings, selectedSession == nil else { return }
                await model.refresh()
            }
        }
        .onChange(of: selectedSession?.id) { oldValue, newValue in
            if oldValue != nil, newValue == nil {
                handleTerminalDismissal()
            }
            guard newValue == nil, let message = pendingAuthenticationMessage else { return }
            pendingAuthenticationMessage = nil
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(300))
                model.handleAuthenticationFailure(message: message)
            }
        }
    }

    private var connectionSettingsBinding: Binding<Bool> {
        Binding(
            get: { model.isShowingConnectionSettings },
            set: { model.isShowingConnectionSettings = $0 }
        )
    }

    private var errorAlertBinding: Binding<Bool> {
        Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.dismissError() } }
        )
    }

    private var selectedSessionBinding: Binding<SpacesMobileTerminalSessionSummary?> {
        Binding(
            get: { selectedSession },
            set: { selectedSession = $0 }
        )
    }

    private var selectedSessionPresentationBinding: Binding<Bool> {
        Binding(
            get: { selectedSession != nil },
            set: { isPresented in
                if !isPresented {
                    selectedSession = nil
                }
            }
        )
    }

    private var refreshLoopTaskID: String {
        [
            scenePhase == .active ? "active" : "inactive",
            model.isShowingConnectionSettings ? "settings" : "home",
            selectedSession?.id ?? "list",
            "\(terminalListRefreshGeneration)",
        ].joined(separator: "|")
    }

    private var terminalHomeView: some View {
        Group {
            if !model.settings.isPaired {
                ContentUnavailableView {
                    Label("Pair This Device", systemImage: "iphone.gen3.radiowaves.left.and.right")
                } description: {
                    Text(model.connectionNotice ?? "Open Connection and pair this device again.")
                } actions: {
                    Button("Open Connection") {
                        model.isShowingConnectionSettings = true
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.isLoading && model.overview == nil {
                ProgressView("Loading terminals…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.terminalGroups.isEmpty {
                ContentUnavailableView(
                    "No Terminals",
                    systemImage: "terminal",
                    description: Text("Start a Spaces terminal on your Mac and refresh.")
                )
            } else {
                List {
                    ForEach(model.terminalGroups) { group in
                        Section {
                            ForEach(group.sessions) { session in
                                Button {
                                    selectedSession = session
                                } label: {
                                    sessionRow(session)
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("terminal.row.\(session.id)")
                            }
                        } header: {
                            workspaceHeader(group)
                        }
                    }
                }
                .id(terminalListRefreshGeneration)
                .listStyle(.insetGrouped)
                .refreshable {
                    await model.refresh()
                }
            }
        }
    }

    private func handleTerminalDismissal() {
        terminalListRefreshGeneration += 1
        Task { await model.refresh() }
    }

    @ToolbarContentBuilder private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button {
                Task { await model.refresh() }
            } label: {
                if model.isLoading {
                    ProgressView()
                } else {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }
            .disabled(model.isLoading)

            Button {
                model.isShowingConnectionSettings = true
            } label: {
                Label("Connection", systemImage: "slider.horizontal.3")
            }
        }
    }

    private func workspaceHeader(_ group: SpacesMobileTerminalWorkspaceGroup) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(group.projectName)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(group.workspaceTitle)
                .font(.headline)
                .foregroundStyle(.primary)
            Text(group.workspaceDirectory)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .textCase(nil)
    }

    private func sessionRow(_ session: SpacesMobileTerminalSessionSummary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: session.state == .running ? "terminal.fill" : "terminal")
                    .foregroundStyle(session.state == .running ? Color.green : Color.secondary)
                Text(session.title)
                    .font(.headline)
                Spacer()
                Text(ownerLabel(for: session))
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.secondary.opacity(0.12), in: Capsule())
            }
            Text(session.workingDirectory)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            HStack(spacing: 8) {
                Text(session.state.rawValue)
                Text(session.backend.rawValue)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private func ownerLabel(for session: SpacesMobileTerminalSessionSummary) -> String {
        let ownerClientID = session.attachmentSnapshot.attachments.first(where: { $0.mode == .owner && $0.detachedAt == nil })?.clientID
        return session.attachmentSnapshot.clients.first(where: { $0.id == ownerClientID })?.identity.label ?? "No owner"
    }
}
