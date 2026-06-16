import SwiftUI
import spacesmobilecore
import spacesterminalcore

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedSession: SelectedTerminalSessionRoute?
    @State private var pendingTerminalLaunch: PendingTerminalLaunch?
    @State private var pendingAuthenticationMessage: String?
    @State private var terminalListRefreshGeneration = 0
    @State private var isShowingFilters = false
    let model: SpacesMobileAppModel

    var body: some View {
        NavigationStack {
            terminalHomeView
                .navigationTitle("Spaces")
                .tint(Theme.accent)
                .toolbar {
                    toolbarContent
                }
                .navigationDestination(item: $selectedSession) { selectedSession in
                    TerminalDetailView(
                        session: selectedSession.session,
                        settings: model.settings,
                        appModel: model,
                        onAuthenticationRequired: { message in
                            pendingAuthenticationMessage = message
                            self.selectedSession = nil
                        },
                        onSessionChanged: { session in
                            self.selectedSession = SelectedTerminalSessionRoute(session: session)
                        }
                    ) {
                        self.selectedSession = nil
                    }
                    .id(selectedSession.id)
                }
                .navigationDestination(item: $pendingTerminalLaunch) { pendingTerminalLaunch in
                    TerminalLaunchPendingView(launch: pendingTerminalLaunch, model: model) { session in
                        self.pendingTerminalLaunch = nil
                        if let session {
                            selectedSession = SelectedTerminalSessionRoute(session: session)
                        }
                    } onBack: {
                        self.pendingTerminalLaunch = nil
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
        .sheet(isPresented: workspaceCreateSheetBinding) {
            WorkspaceCreateSheet(model: model)
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
            guard !model.isShowingConnectionSettings, activeTerminalRouteID == nil else { return }
            await model.refresh()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                guard scenePhase == .active, !model.isShowingConnectionSettings, activeTerminalRouteID == nil else { return }
                await model.refresh()
            }
        }
        .onChange(of: activeTerminalRouteID) { oldValue, newValue in
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

    private var workspaceCreateSheetBinding: Binding<Bool> {
        Binding(
            get: { model.isShowingWorkspaceCreateSheet },
            set: { model.isShowingWorkspaceCreateSheet = $0 }
        )
    }

    private var errorAlertBinding: Binding<Bool> {
        Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.dismissError() } }
        )
    }

    private var activeTerminalRouteID: String? {
        selectedSession?.id ?? pendingTerminalLaunch?.id
    }

    private var refreshLoopTaskID: String {
        [
            scenePhase == .active ? "active" : "inactive",
            model.isShowingConnectionSettings ? "settings" : "home",
            activeTerminalRouteID ?? "list",
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
                ProgressView("Loading workspaces...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        homeControls
                        if model.workspaceGroups.isEmpty && model.terminalGroups.isEmpty {
                            ContentUnavailableView(
                                "No Workspaces",
                                systemImage: "rectangle.stack",
                                description: Text("Create a workspace or adjust the current filters.")
                            )
                            .frame(maxWidth: .infinity, minHeight: 360)
                        } else {
                            ForEach(model.workspaceGroups) { group in
                                workspaceCard(group)
                            }
                            ForEach(model.terminalGroups) { group in
                                terminalGroupCard(group)
                            }
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

    private var homeControls: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.mutedSecondary)
            TextField("Search workspaces", text: Binding(get: { model.searchText }, set: { model.searchText = $0 }))
                .font(.system(size: 14))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button {
                isShowingFilters.toggle()
            } label: {
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .font(.system(size: 18, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.accent)
            .popover(isPresented: $isShowingFilters) {
                filterPopover
                    .presentationCompactAdaptation(.popover)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.border, lineWidth: 1))
    }

    private var filterPopover: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Rows")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.muted)
            ForEach(SpacesMobileWorkspaceRowType.allCases) { type in
                Toggle(isOn: Binding(get: { model.visibleRowTypes.contains(type) }, set: { _ in model.toggleRowTypeFilter(type) })) {
                    Label(type.label, systemImage: type.iconName)
                }
            }
            Divider()
            Text("State")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.muted)
            ForEach([SpacesMobileRunState.notStarted, .running, .exited], id: \.self) { state in
                Toggle(isOn: Binding(get: { model.visibleRunStates.contains(state) }, set: { _ in model.toggleRunStateFilter(state) })) {
                    Text(state.mobileLabel)
                }
            }
        }
        .padding(16)
        .frame(width: 260)
    }

    private func workspaceCard(_ group: SpacesMobileWorkspaceGroup) -> some View {
        SectionCard {
            workspaceHeader(group)
            ForEach(Array(group.rows.enumerated()), id: \.element.id) { index, row in
                if index == 0 {
                    RowDivider(inset: 0)
                } else {
                    RowDivider()
                }
                workspaceRuntimeRow(row)
            }
            if group.rows.isEmpty {
                RowDivider(inset: 0)
                Text("No configured rows")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.muted)
                    .padding(.init(top: 10, leading: 14, bottom: 10, trailing: 14))
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
                Task { await model.launchSpacesAppIfNeeded() }
            } label: {
                if model.isLaunchingSpacesApp {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Label("Launch Spaces on Mac", systemImage: "macwindow")
                }
            }
            .disabled(!model.settings.isPaired || model.isLaunchingSpacesApp)
            .accessibilityLabel("Launch Spaces on Mac")
            .accessibilityIdentifier("toolbar.launchSpacesApp")

            Button {
                model.isShowingWorkspaceCreateSheet = true
            } label: {
                Label("New Workspace", systemImage: "plus")
            }
            .disabled(model.overview?.projects.isEmpty ?? true)

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

    private func workspaceHeader(_ group: SpacesMobileWorkspaceGroup) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(group.workspace.projectName.uppercased())
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.mutedSecondary)
                    .tracking(0.4)
                Text(group.workspace.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Text(group.workspace.dir)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.mutedSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
            Button {
                pendingTerminalLaunch = PendingTerminalLaunch(workspace: group.workspace)
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .disabled(model.isMutating)
            .accessibilityLabel("Open Workspace Terminal")
        }
        .padding(.init(top: 12, leading: 14, bottom: 12, trailing: 14))
    }

    private func workspaceRuntimeRow(_ row: SpacesMobileWorkspaceRuntimeRow) -> some View {
        let rowIdentifier = row.sessionID.map { "terminal.row.\($0)" } ?? "workspace.row.\(row.id)"
        return HStack(spacing: 10) {
            Button {
                activateRuntimeRow(row)
            } label: {
                HStack(spacing: 10) {
                    StatusDot(kind: statusKind(for: row.runState))
                    TypeIconTile(systemName: row.type.iconName)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.title)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Theme.text)
                            .lineLimit(1)
                        Text(row.detail)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.muted)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 0)
                    if showsStateChip(for: row) {
                        MetaChip(text: row.runState.mobileLabel)
                    }
                    runtimePrimaryIndicator(for: row)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(model.isMutating || (row.sessionID == nil && !row.canRun))
            .accessibilityIdentifier(rowIdentifier)
            runtimeActionButtons(for: row)
        }
        .padding(.init(top: 9, leading: 14, bottom: 9, trailing: 14))
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private func terminalGroupCard(_ group: SpacesMobileTerminalWorkspaceGroup) -> some View {
        SectionCard {
            terminalGroupHeader(group)
            ForEach(Array(group.sessions.enumerated()), id: \.element.id) { index, session in
                if index == 0 {
                    RowDivider(inset: 0)
                } else {
                    RowDivider()
                }
                terminalSessionRow(session)
            }
        }
    }

    private func terminalGroupHeader(_ group: SpacesMobileTerminalWorkspaceGroup) -> some View {
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
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.init(top: 12, leading: 14, bottom: 12, trailing: 14))
    }

    private func terminalSessionRow(_ session: SpacesMobileTerminalSessionSummary) -> some View {
        Button {
            selectedSession = SelectedTerminalSessionRoute(session: session)
        } label: {
            HStack(spacing: 10) {
                StatusDot(kind: statusKind(for: session.state))
                TypeIconTile(systemName: "terminal.fill")
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
                Spacer(minLength: 0)
                if session.state != .running {
                    MetaChip(text: session.state.rawValue.capitalized)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.mutedSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(model.isMutating || (!session.isControlAvailable && !session.hasFinalRender))
        .accessibilityIdentifier("terminal.row.\(session.id)")
        .padding(.init(top: 9, leading: 14, bottom: 9, trailing: 14))
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    @ViewBuilder private func runtimePrimaryIndicator(for row: SpacesMobileWorkspaceRuntimeRow) -> some View {
        if row.sessionID != nil {
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.mutedSecondary)
        } else if row.canRun {
            Image(systemName: "play.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.mutedSecondary)
        }
    }

    @ViewBuilder private func runtimeActionButtons(for row: SpacesMobileWorkspaceRuntimeRow) -> some View {
        if showsRunActionButton(for: row) {
            Button {
                pendingTerminalLaunch = PendingTerminalLaunch(row: row, action: .run)
            } label: {
                Image(systemName: "play.fill")
            }
            .buttonStyle(.borderless)
            .disabled(model.isMutating)
            .accessibilityLabel("Run")
            .accessibilityIdentifier("runtime.action.run.\(row.id)")
        }
        if row.canStop {
            Button {
                Task { await model.stop(row: row) }
            } label: {
                Image(systemName: "stop.fill")
            }
            .buttonStyle(.borderless)
            .disabled(model.isMutating)
            .accessibilityLabel("Stop")
            .accessibilityIdentifier("runtime.action.stop.\(row.id)")
        }
        if row.canRestart {
            Button {
                pendingTerminalLaunch = PendingTerminalLaunch(row: row, action: .restart)
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .disabled(model.isMutating)
            .accessibilityLabel("Restart")
            .accessibilityIdentifier("runtime.action.restart.\(row.id)")
        }
    }

    private func showsRunActionButton(for row: SpacesMobileWorkspaceRuntimeRow) -> Bool {
        guard row.sessionID != nil, row.canRun else { return false }
        guard case .process = row.source else { return false }
        return row.runState == .exited
    }

    private func activateRuntimeRow(_ row: SpacesMobileWorkspaceRuntimeRow) {
        if let session = model.terminalSession(for: row) {
            selectedSession = SelectedTerminalSessionRoute(session: session)
        } else if row.canRun {
            pendingTerminalLaunch = PendingTerminalLaunch(row: row, action: .primary)
        }
    }

    private func statusKind(for state: SpacesMobileRunState) -> StatusDot.Kind {
        switch state {
        case .running: .running
        case .exited: .exited
        case .notStarted: .idle
        }
    }

    private func statusKind(for state: TerminalSessionState) -> StatusDot.Kind {
        switch state {
        case .starting, .running: .running
        case .exited, .failed: .exited
        }
    }

    private func showsStateChip(for row: SpacesMobileWorkspaceRuntimeRow) -> Bool {
        guard row.runState != .running else { return false }
        if case .terminal = row.source { return true }
        return false
    }
}

private struct SelectedTerminalSessionRoute: Identifiable, Hashable {
    let session: SpacesMobileTerminalSessionSummary

    var id: String { session.id }

    static func == (lhs: SelectedTerminalSessionRoute, rhs: SelectedTerminalSessionRoute) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

private struct PendingTerminalLaunch: Identifiable, Sendable, Hashable {
    enum Action: Sendable {
        case primary
        case run
        case restart
        case workspaceTerminal
    }

    let id: String
    let title: String
    let detail: String
    let systemImage: String
    let action: Action
    let row: SpacesMobileWorkspaceRuntimeRow?
    let workspaceID: String?

    init(row: SpacesMobileWorkspaceRuntimeRow, action: Action) {
        self.id = "\(action.idComponent):\(row.id)"
        title = row.title
        detail = row.detail
        systemImage = row.type.iconName
        self.action = action
        self.row = row
        workspaceID = nil
    }

    init(workspace: SpacesMobileWorkspaceSummary) {
        id = "workspace-terminal:\(workspace.id)"
        title = "Workspace Terminal"
        detail = workspace.dir
        systemImage = "terminal.fill"
        action = .workspaceTerminal
        row = nil
        workspaceID = workspace.id
    }

    static func == (lhs: PendingTerminalLaunch, rhs: PendingTerminalLaunch) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

private extension PendingTerminalLaunch.Action {
    var idComponent: String {
        switch self {
        case .primary: "primary"
        case .run: "run"
        case .restart: "restart"
        case .workspaceTerminal: "workspace-terminal"
        }
    }

    var progressLabel: String {
        switch self {
        case .primary: "Starting terminal..."
        case .run: "Starting terminal..."
        case .restart: "Restarting terminal..."
        case .workspaceTerminal: "Opening terminal..."
        }
    }
}

private struct TerminalLaunchPendingView: View {
    private static let chromeControlHeight: CGFloat = 36
    private static let surfaceBackground = Color(red: 15 / 255, green: 21 / 255, blue: 23 / 255)

    let launch: PendingTerminalLaunch
    let model: SpacesMobileAppModel
    let onSessionReady: @MainActor (SpacesMobileTerminalSessionSummary?) -> Void
    let onBack: @MainActor () -> Void

    @State private var hasStarted = false

    var body: some View {
        VStack(spacing: 0) {
            topOverlay
                .padding(.horizontal, 8)
                .padding(.top, 4)
                .padding(.bottom, 4)

            VStack(spacing: 18) {
                Spacer(minLength: 0)
                Image(systemName: launch.systemImage)
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.82))
                ProgressView()
                    .tint(.white)
                Text(launch.action.progressLabel)
                    .font(.body.monospaced())
                    .foregroundStyle(.white.opacity(0.88))
                    .multilineTextAlignment(.center)
                Text(launch.detail)
                    .font(.footnote.monospaced())
                    .foregroundStyle(.white.opacity(0.56))
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 28)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Self.surfaceBackground.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .task(id: launch.id) {
            guard !hasStarted else { return }
            hasStarted = true
            let session = await runLaunch()
            guard !Task.isCancelled else { return }
            await onSessionReady(session)
        }
        .accessibilityIdentifier("terminal.launch.\(launch.id)")
    }

    private var topOverlay: some View {
        HStack(spacing: 8) {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(height: Self.chromeControlHeight)
                    .padding(.horizontal, 12)
                    .background(
                        Capsule()
                            .fill(.black.opacity(0.28))
                            .overlay(Capsule().strokeBorder(.white.opacity(0.10), lineWidth: 1))
                    )
            }
            .accessibilityIdentifier("terminal.launch.back")
            .accessibilityLabel("Back")

            Spacer(minLength: 0)

            Text(launch.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .accessibilityIdentifier("terminal.launch.title")

            Spacer(minLength: 0)
            Color.clear.frame(width: Self.chromeControlHeight, height: 1)
        }
        .frame(height: Self.chromeControlHeight)
    }

    private func runLaunch() async -> SpacesMobileTerminalSessionSummary? {
        switch launch.action {
        case .primary:
            guard let row = launch.row else { return nil }
            return await model.performPrimaryAction(for: row)
        case .run:
            guard let row = launch.row else { return nil }
            return await model.run(row: row)
        case .restart:
            guard let row = launch.row else { return nil }
            return await model.restart(row: row)
        case .workspaceTerminal:
            guard let workspaceID = launch.workspaceID else { return nil }
            return await model.openWorkspaceTerminal(workspaceID: workspaceID)
        }
    }
}

private struct WorkspaceCreateSheet: View {
    private enum BranchMode: String, CaseIterable, Identifiable {
        case create
        case existing

        var id: String { rawValue }

        var label: String {
            switch self {
            case .create: "Create"
            case .existing: "Existing"
            }
        }
    }

    @Environment(\.dismiss) private var dismiss
    let model: SpacesMobileAppModel

    @State private var selectedProjectID = ""
    @State private var title = ""
    @State private var branchMode: BranchMode = .create
    @State private var branch = ""
    @State private var targetBranch = ""
    @State private var directoryName = ""

    private var projects: [SpacesMobileProjectSummary] {
        let optionProjects = model.workspaceCreateOptions?.projects ?? []
        return optionProjects.isEmpty ? (model.overview?.projects ?? []) : optionProjects
    }

    private var selectedProject: SpacesMobileProjectSummary? {
        projects.first(where: { $0.id == selectedProjectID }) ?? projects.first
    }

    private var branchOptions: [String] { model.workspaceCreateOptions?.branchOptions ?? [] }

    private var canCreate: Bool {
        guard selectedProject != nil, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        guard selectedProject?.isGitRepo == true else { return true }
        return !branch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !targetBranch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Project", selection: $selectedProjectID) {
                        ForEach(projects) { project in
                            Text(project.name).tag(project.id)
                        }
                    }
                    TextField("Title", text: $title)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                if selectedProject?.isGitRepo == true {
                    Section {
                        Picker("Branch", selection: $branchMode) {
                            ForEach(BranchMode.allCases) { mode in
                                Text(mode.label).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)

                        if branchMode == .existing, !branchOptions.isEmpty {
                            Picker("Existing branch", selection: $branch) {
                                ForEach(branchOptions, id: \.self) { option in
                                    Text(option).tag(option)
                                }
                            }
                        } else {
                            TextField(branchMode == .existing ? "Existing branch" : "Branch name", text: $branch)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                        }

                        TextField("Target branch", text: $targetBranch)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        TextField("Directory name", text: $directoryName)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                }
            }
            .navigationTitle("New Workspace")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(model.isMutating ? "Creating..." : "Create") {
                        Task {
                            await model.createWorkspace(
                                projectID: selectedProject?.id ?? selectedProjectID,
                                title: title,
                                branch: selectedProject?.isGitRepo == true ? trimmed(branch) : nil,
                                targetBranch: selectedProject?.isGitRepo == true ? trimmed(targetBranch) : nil,
                                directoryName: selectedProject?.isGitRepo == true ? trimmed(directoryName) : nil,
                                allowExistingBranchReuse: branchMode == .existing)
                        }
                    }
                    .disabled(!canCreate || model.isMutating)
                }
            }
            .task {
                if selectedProjectID.isEmpty {
                    selectedProjectID = model.overview?.projects.first?.id ?? ""
                }
                await model.loadWorkspaceCreateOptions(projectID: selectedProjectID.isEmpty ? nil : selectedProjectID)
                applyProjectDefaults()
            }
            .onChange(of: selectedProjectID) { _, newValue in
                Task {
                    await model.loadWorkspaceCreateOptions(projectID: newValue)
                    applyProjectDefaults()
                }
            }
            .onChange(of: branchMode) { _, _ in applyBranchModeDefaults() }
        }
    }

    private func applyProjectDefaults() {
        if selectedProjectID.isEmpty {
            selectedProjectID = projects.first?.id ?? ""
        }
        if targetBranch.isEmpty {
            targetBranch = selectedProject?.defaultBranch ?? branchOptions.first ?? ""
        }
        applyBranchModeDefaults()
    }

    private func applyBranchModeDefaults() {
        guard selectedProject?.isGitRepo == true else { return }
        if branchMode == .existing, branch.isEmpty {
            branch = branchOptions.first ?? ""
        }
    }

    private func trimmed(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
