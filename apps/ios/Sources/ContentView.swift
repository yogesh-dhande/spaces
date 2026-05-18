import SwiftUI
import spacesmobilecore

struct ContentView: View {
    let model: SpacesMobileAppModel

    var body: some View {
        NavigationSplitView {
            workspaceSidebar
        } content: {
            terminalListPane
        } detail: {
            terminalDetailPane
        }
        .toolbar {
            toolbarContent
        }
        .sheet(isPresented: connectionSettingsBinding) {
            ConnectionSettingsView(initialSettings: model.settings) { settings in
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
        .task {
            if model.overview == nil {
                if !model.settings.isPaired {
                    model.isShowingConnectionSettings = true
                } else {
                    await model.refresh()
                }
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

    private var workspaceSidebar: some View {
        List {
            Button {
                model.selectedWorkspace = .all
            } label: {
                Label("All Terminals", systemImage: "rectangle.stack")
            }
            .buttonStyle(.plain)
            .listRowBackground(
                model.selectedWorkspace == .all ? Color.accentColor.opacity(0.14) : Color.clear
            )
            ForEach(model.workspaceSections) { section in
                Section(section.projectName) {
                    ForEach(section.workspaces) { workspace in
                        Button {
                            model.selectedWorkspace = .workspace(workspace.id)
                        } label: {
                            workspaceRow(workspace)
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(
                            model.selectedWorkspace == .workspace(workspace.id) ? Color.accentColor.opacity(0.14) : Color.clear
                        )
                    }
                }
            }
        }
        .navigationTitle("Workspaces")
    }

    private var terminalListPane: some View {
        Group {
            if model.isLoading && model.overview == nil {
                ProgressView("Loading terminals…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.filteredSessions.isEmpty {
                ContentUnavailableView(
                    "No Terminals",
                    systemImage: "terminal",
                    description: Text("Start `spaces mobile serve` on your Mac and refresh.")
                )
            } else {
                List {
                    ForEach(model.filteredSessions) { session in
                        Button {
                            model.selectedSessionID = session.id
                        } label: {
                            sessionRow(session)
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(
                            model.selectedSessionID == session.id ? Color.accentColor.opacity(0.14) : Color.clear
                        )
                    }
                }
                .navigationTitle("Terminals")
            }
        }
    }

    private var terminalDetailPane: some View {
        Group {
            if let session = model.selectedSession {
                TerminalDetailView(session: session, settings: model.settings)
                    .id("\(session.id)|\(model.settings.trimmedHost)|\(model.settings.port)|\(model.settings.trimmedAuthToken ?? "")")
            } else {
                ContentUnavailableView(
                    "Select a Terminal",
                    systemImage: "terminal",
                    description: Text("Choose a workspace and terminal to connect.")
                )
            }
        }
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

    private func workspaceRow(_ workspace: SpacesMobileWorkspaceSummary) -> some View {
        HStack(spacing: 12) {
            Image(systemName: workspace.isRunning ? "circle.fill" : "circle")
                .font(.caption)
                .foregroundStyle(workspace.isRunning ? Color.green : Color.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text(workspace.title)
                    .font(.headline)
                Text("\(workspace.sessionCount) terminals")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func sessionRow(_ session: SpacesMobileTerminalSessionSummary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: session.state == .running ? "terminal.fill" : "terminal")
                    .foregroundStyle(session.state == .running ? Color.green : Color.secondary)
                Text(session.title)
                    .font(.headline)
                Spacer()
                Text(session.workspaceTitle ?? "Unassigned")
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
                Text(ownerLabel(for: session))
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    private func ownerLabel(for session: SpacesMobileTerminalSessionSummary) -> String {
        let ownerClientID = session.attachmentSnapshot.attachments.first(where: { $0.mode == .owner && $0.detachedAt == nil })?.clientID
        return session.attachmentSnapshot.clients.first(where: { $0.id == ownerClientID })?.identity.label ?? "No owner"
    }
}
