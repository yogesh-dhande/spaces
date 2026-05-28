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
                .navigationTitle("Spaces")
                .tint(Theme.accent)
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
        .sheet(isPresented: connectionSettingsBinding, onDismiss: { model.clearPendingPairingLink() }) {
            ConnectionSettingsView(
                initialSettings: model.settings,
                initialPairingLink: model.pendingPairingLink,
                noticeMessage: model.connectionNotice,
                onPairingLinkConsumed: { model.clearPendingPairingLink() }
            ) { settings in
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
        .onOpenURL { url in
            model.preparePairingLink(url)
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
                ScrollView {
                    LazyVStack(spacing: 14) {
                        ForEach(model.terminalGroups) { group in
                            workspaceCard(group)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                }
                .id(terminalListRefreshGeneration)
                .background(Theme.bg)
                .scrollContentBackground(.hidden)
                .refreshable {
                    await model.refresh()
                }
            }
        }
        .background(Theme.bg.ignoresSafeArea())
    }

    private func workspaceCard(_ group: SpacesMobileTerminalWorkspaceGroup) -> some View {
        VStack(spacing: 0) {
            workspaceHeader(group)
            ForEach(Array(group.sessions.enumerated()), id: \.element.id) { index, session in
                if index == 0 {
                    RowDivider(inset: 0)
                } else {
                    RowDivider()
                }
                Button {
                    selectedSession = session
                } label: {
                    sessionRow(session)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("terminal.row.\(session.id)")
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
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(group.projectName.uppercased())
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.mutedSecondary)
                    .tracking(0.4)
                Text(group.workspaceTitle)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Text(group.workspaceDirectory)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.mutedSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
            Text("\(group.sessions.count)")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.muted)
        }
        .padding(.init(top: 12, leading: 14, bottom: 12, trailing: 14))
    }

    private func sessionRow(_ session: SpacesMobileTerminalSessionSummary) -> some View {
        HStack(spacing: 10) {
            StatusDot(kind: .init(session.state))
            TypeIconTile(systemName: session.state == .running ? "terminal.fill" : "terminal")
            VStack(alignment: .leading, spacing: 2) {
                Text(session.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Text(session.workingDirectory)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.muted)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if session.state != .running {
                MetaChip(text: session.state.rawValue)
            }
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.mutedSecondary)
        }
        .padding(.init(top: 9, leading: 14, bottom: 9, trailing: 14))
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}
