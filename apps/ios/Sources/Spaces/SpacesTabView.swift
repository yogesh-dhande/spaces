import SwiftUI
import spacesdevicecore
import spacesterminalcore

/// Home tab: every project, its workspaces as header bands, and their runtime rows beneath.
struct SpacesTabView: View {
    @Bindable var model: SpacesMobileAppModel
    @State private var selectedSession: SelectedTerminalSessionRoute?
    @State private var selectedBrowserSession: SelectedBrowserSessionRoute?
    @State private var pendingTerminalLaunch: PendingTerminalLaunch?
    @State private var isShowingFilters = false
    @State private var pendingHideWorkspace: SpacesDeviceWorkspaceSummary?
    @State private var pendingDeleteWorkspace: SpacesDeviceWorkspaceSummary?
    @State private var terminalListRefreshGeneration = 0
    @State private var renamingRowID: String?
    @State private var renameText = ""
    @State private var isShowingPairingScanner = false
    @FocusState private var isRenameFieldFocused: Bool

    var body: some View {
        NavigationStack {
            homeView.navigationTitle("Spaces").tint(Theme.accent).toolbar { toolbarContent }.terminalSessionNavigation(
                model: model, selectedSession: $selectedSession, pendingTerminalLaunch: $pendingTerminalLaunch
            ) {
                terminalListRefreshGeneration += 1
                Task { await model.refresh() }
            }.navigationDestination(item: $selectedBrowserSession) { route in
                BrowserSessionDetailView(
                    title: route.row.title, subtitle: route.row.route.identityHost, request: route.proxyRequest,
                    stagedScreenshots: model.stagedScreenshots
                ) { selectedBrowserSession = nil }.id(route.id)
            }
        }.onChange(of: model.pendingTerminalDeepLinkSession) { _, session in
            // A `spaces://terminal/…` deep link resolves to a session on the model; consume it here so
            // the Spaces tab (the deep link's landing tab) pushes its detail route.
            guard let session else { return }
            selectedSession = SelectedTerminalSessionRoute(session: session)
            model.pendingTerminalDeepLinkSession = nil
        }.accessibilityIdentifier("tab.spaces").overviewPolling(
            model: model, tab: .spaces, activeDetailRouteID: activeDetailRouteID, refreshGeneration: terminalListRefreshGeneration
        ).sheet(isPresented: workspaceCreateSheetBinding) { WorkspaceCreateSheet(model: model) }.confirmationDialog(
            "Hide this workspace?", isPresented: hideWorkspaceDialogBinding, titleVisibility: .visible, presenting: pendingHideWorkspace
        ) { workspace in
            // Hiding stops the workspace first, so a running one loses its processes and agents — the
            // confirm button says so rather than hiding that behind a bare "Hide".
            Button(workspace.isRunning ? "Stop and Hide" : "Hide", role: .destructive) { Task { await model.hideWorkspace(workspace) } }
            Button("Cancel", role: .cancel) {}
        } message: { workspace in
            Text(
                workspace.isRunning
                    ? "\"\(workspace.displayName)\" is running. Hiding it stops its processes and coding agents, and removes it from this list and the Mac sidebar. Unhide it from the Mac."
                    : "\"\(workspace.displayName)\" will be removed from this list and the Mac sidebar. Unhide it from the Mac.")
        }.sheet(item: $pendingDeleteWorkspace) { workspace in
            WorkspaceDeleteSheet(workspace: workspace) { deleteLocalBranch, deleteRemoteBranch in
                Task { await model.deleteWorkspace(workspace, deleteLocalBranch: deleteLocalBranch, deleteRemoteBranch: deleteRemoteBranch) }
            }
        }
    }

    private var hideWorkspaceDialogBinding: Binding<Bool> {
        Binding(get: { pendingHideWorkspace != nil }, set: { if !$0 { pendingHideWorkspace = nil } })
    }

    /// Any detail route — a terminal, a pending terminal launch, or a browser session — that should
    /// pause this tab's refresh poll while it is on screen.
    private var activeDetailRouteID: String? { selectedSession?.id ?? pendingTerminalLaunch?.id ?? selectedBrowserSession?.id }

    private var workspaceCreateSheetBinding: Binding<Bool> {
        Binding(get: { model.isShowingWorkspaceCreateSheet }, set: { model.isShowingWorkspaceCreateSheet = $0 })
    }

    @ToolbarContentBuilder private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            // Demo Mode's backend cannot create workspaces, so the New Workspace action is hidden rather
            // than shown and left to fail.
            if model.settings.isPaired && !model.isDemoModeEnabled {
                Button {
                    model.isShowingWorkspaceCreateSheet = true
                } label: {
                    Label("New Workspace", systemImage: "plus")
                }.disabled(model.isMutating || model.isActiveDeviceBlocked).accessibilityIdentifier("spaces.newWorkspace")
            }
        }
    }

    private var homeView: some View {
        Group {
            if !model.settings.isPaired {
                ContentUnavailableView {
                    Label("Pair This Device", systemImage: "iphone.gen3.radiowaves.left.and.right")
                } description: {
                    Text(model.connectionNotice ?? "Scan the QR code shown in the Mac app's Devices settings.")
                } actions: {
                    Button {
                        isShowingPairingScanner = true
                    } label: {
                        Label("Scan QR Code", systemImage: "qrcode.viewfinder")
                    }.buttonStyle(.borderedProminent).accessibilityIdentifier("spaces.scanToPair")
                    Button("Try Demo Mode") {
                        model.setDemoMode(true)
                        Task { await model.refresh() }
                    }.buttonStyle(.bordered).accessibilityIdentifier("spaces.tryDemoMode")
                }.frame(maxWidth: .infinity, maxHeight: .infinity).fullScreenCover(isPresented: $isShowingPairingScanner) {
                    QRCodeScannerView { payload in model.prepareScannedPairingLink(payload) }
                }
            } else {
                List {
                    homeControls.padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 12).bandListRow()
                    if model.isActiveDeviceBlocked {
                        // Fully blocked, scoped to this device: the banner in homeControls is the only
                        // surface. Switch to another paired device or restart this device's daemon.
                        EmptyView()
                    } else if model.isLoading && model.overview == nil {
                        ProgressView("Loading workspaces...").frame(maxWidth: .infinity, minHeight: 360).bandListRow()
                    } else if projectGroups.isEmpty && model.terminalGroups.isEmpty && !isHiddenSectionVisible {
                        ContentUnavailableView(
                            "No Workspaces", systemImage: "rectangle.stack", description: Text("Create a workspace or adjust the current filters.")
                        ).frame(maxWidth: .infinity, minHeight: 360).bandListRow()
                    } else {
                        ForEach(projectGroups) { projectGroup in projectSection(projectGroup) }
                        ForEach(model.terminalGroups) { group in terminalGroupSection(group) }
                    }
                    if !model.isActiveDeviceBlocked { hiddenSection }
                }.listStyle(.plain).id(terminalListRefreshGeneration).background(Theme.bg).scrollContentBackground(.hidden).refreshable {
                    await model.refresh()
                }
            }
        }.background(Theme.bg.ignoresSafeArea())
    }

    private var homeControls: some View {
        VStack(spacing: 8) {
            deviceSelectorRow
            compatibilityBanner
            if !model.isActiveDeviceBlocked { searchFilterRow }
        }
    }

    @ViewBuilder private var compatibilityBanner: some View {
        if let status = model.daemonStatus, let remedy = model.daemonUpdateRemedy, remedy != .none {
            // The update action fires directly: `requestDaemonUpdate()` re-execs the daemon onto
            // whatever build is staged and preserves running terminals, processes, and coding agents,
            // so there is nothing to confirm or defer.
            CompatibilityBannerView(remedy: remedy, status: status, isMutating: model.isMutating, isApplyingUpdate: model.isApplyingDaemonUpdate) {
                Task { await model.requestDaemonUpdate() }
            }
        }
    }

    private var deviceSelectorRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "desktopcomputer.and.macbook").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.accent)
            if model.pairedDevices.count > 1 {
                Menu {
                    ForEach(model.pairedDevices) { device in
                        Button {
                            model.selectDevice(id: device.id)
                            Task { await model.refresh() }
                        } label: {
                            Label(device.name, systemImage: device.id == model.activeDeviceID ? "checkmark" : "desktopcomputer")
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(model.activeDeviceName ?? "Device").font(.system(size: 13, weight: .medium)).lineLimit(1)
                        Image(systemName: "chevron.up.chevron.down").font(.system(size: 10, weight: .semibold))
                    }.foregroundStyle(Theme.accent)
                }.buttonStyle(.plain)
            } else {
                Text(model.activeDeviceName ?? "Device").font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.accent).lineLimit(1)
            }
            Spacer(minLength: 0)
            if model.isActiveDeviceBlocked || model.daemonUpdatePending {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.orange)
                    .accessibilityLabel(model.isActiveDeviceBlocked ? "Device incompatible" : "Daemon update pending")
            }
        }.padding(.horizontal, 12).padding(.vertical, 9).background(Theme.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous)).overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.border, lineWidth: 1))
    }

    private var searchFilterRow: some View {
        HStack(spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.mutedSecondary)
                TextField("Search workspaces", text: $model.searchText).font(.system(size: 13)).textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }.padding(.horizontal, 10).frame(height: 36).background(Theme.surface2, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            Button {
                isShowingFilters.toggle()
            } label: {
                Image(systemName: "line.3.horizontal.decrease.circle").font(.system(size: 18, weight: .semibold))
            }.buttonStyle(.plain).foregroundStyle(Theme.accent).popover(isPresented: $isShowingFilters) {
                filterPopover.presentationCompactAdaptation(.popover)
            }
        }
    }

    private var filterPopover: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Rows").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.muted)
            ForEach(SpacesMobileWorkspaceRowType.allCases) { type in
                Toggle(isOn: Binding(get: { model.visibleRowTypes.contains(type) }, set: { _ in model.toggleRowTypeFilter(type) })) {
                    Label(type.label, systemImage: type.iconName)
                }
            }
            Divider()
            Text("State").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.muted)
            ForEach([SpacesDeviceRunState.notStarted, .running, .exited], id: \.self) { state in
                Toggle(isOn: Binding(get: { model.visibleRunStates.contains(state) }, set: { _ in model.toggleRunStateFilter(state) })) {
                    Text(state.mobileLabel)
                }
            }
        }.padding(16).frame(width: 260)
    }

    // MARK: - Project / workspace sections

    private var projectGroups: [ProjectGroup] {
        var dict: [String: (name: String, groups: [SpacesMobileWorkspaceGroup])] = [:]
        var order: [String] = []
        for group in model.workspaceGroups {
            let projectID = group.workspace.projectID
            if dict[projectID] == nil {
                dict[projectID] = (group.workspace.projectName, [])
                order.append(projectID)
            }
            dict[projectID]?.groups.append(group)
        }
        return order.compactMap { projectID in
            guard let entry = dict[projectID] else { return nil }
            return ProjectGroup(projectID: projectID, projectName: entry.name, workspaceGroups: entry.groups)
        }
    }

    @ViewBuilder private func projectSection(_ projectGroup: ProjectGroup) -> some View {
        Text(projectGroup.projectName.uppercased()).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.mutedSecondary).tracking(0.4)
            .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 20).padding(.top, 14).bandListRow()
        ForEach(Array(projectGroup.workspaceGroups.enumerated()), id: \.element.id) { index, group in
            // The project caption already separates the first workspace from what is above it, so only
            // the workspaces after it carry the full band lead-in gap.
            workspaceSection(group, topGap: index == 0 ? 8 : 14)
        }
    }

    @ViewBuilder private func workspaceSection(_ group: SpacesMobileWorkspaceGroup, topGap: CGFloat) -> some View {
        let isCollapsed = model.collapsedWorkspaceIDs.contains(group.id)
        Button {
            withAnimation(.easeInOut(duration: 0.2)) { model.toggleWorkspaceCollapsed(group.id) }
        } label: {
            HeaderBand {
                WorkspaceBandLabel(isGitWorkspace: group.workspace.isGitWorkspace, displayName: group.workspace.displayName)
                Spacer(minLength: 0)
                Image(systemName: isCollapsed ? "chevron.right" : "chevron.down").font(.system(size: 12, weight: .semibold)).foregroundStyle(
                    Theme.mutedSecondary)
            }.contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityIdentifier("workspace.band.\(group.id)").bandListHeaderRow(topGap: topGap).modifier(
            WorkspaceBandActions(
                model: model, workspace: group.workspace, onHide: { pendingHideWorkspace = group.workspace },
                onDelete: { pendingDeleteWorkspace = group.workspace }))
        if !isCollapsed {
            WorkspaceControlBar(
                workspace: group.workspace, isMutating: model.isMutating, onStart: { Task { await model.launchWorkspace(group.workspace) } },
                onRestart: { Task { await model.restartWorkspace(group.workspace) } },
                onStop: { Task { await model.stopWorkspace(group.workspace) } },
                // Demo Mode's backend does not open ad hoc terminals; hide the action there.
                onNewTerminal: model.isDemoModeEnabled ? nil : { pendingTerminalLaunch = PendingTerminalLaunch(workspace: group.workspace) }
            ).bandListRow()
            if group.rows.isEmpty {
                Text("No configured rows").font(.system(size: 12)).foregroundStyle(Theme.muted).frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 9).padding(.horizontal, 20).bandListRow()
            }
            ForEach(group.rows) { row in
                // Lifecycle actions reach a row two ways: a long press opens the full menu (Rename
                // included), a trailing swipe offers the lifecycle subset. Full swipe is off so an
                // over-swipe cannot run or stop something on its own.
                runtimeRow(row).bandListRow().swipeActions(edge: .trailing, allowsFullSwipe: false) { runtimeSwipeActions(for: row) }
            }
        }
    }

    @ViewBuilder private func runtimeRow(_ row: SpacesMobileWorkspaceRuntimeRow) -> some View {
        if renamingRowID == row.id {
            renameRow(row)
        } else {
            let rowIdentifier = row.sessionID.map { "terminal.row.\($0)" } ?? "workspace.row.\(row.id)"
            let button = Button {
                activateRuntimeRow(row)
            } label: {
                BandRow(dotKind: row.statusDotKind, tile: .tile(for: row.type), title: row.title, detail: row.detail) {
                    runtimeTrailingIndicator(for: row)
                }
            }.buttonStyle(.plain).disabled(isRuntimeRowDisabled(row)).accessibilityIdentifier(rowIdentifier)

            // Long-press only offers a menu when the row has something to offer. A row with neither a
            // lifecycle action nor a renamable name — an exited terminal whose session is gone, or a
            // process running without a configured entry — would otherwise open an empty menu.
            if hasContextMenu(row) { button.contextMenu { runtimeContextMenu(for: row) } } else { button }
        }
    }

    /// The row being renamed: the title becomes a text field seeded with the current name and the rest of
    /// the row stays put. Return commits; leaving the field (tapping away, scrolling it off) reverts, so a
    /// half-typed name never reaches the daemon.
    private func renameRow(_ row: SpacesMobileWorkspaceRuntimeRow) -> some View {
        BandRow(
            dotKind: row.statusDotKind, tile: .tile(for: row.type),
            title: {
                TextField("Name", text: $renameText).textInputAutocapitalization(.never).autocorrectionDisabled().submitLabel(.done).focused(
                    $isRenameFieldFocused
                ).onSubmit { commitRename(for: row) }
            }, detail: row.detail
        ) { EmptyView() }.accessibilityIdentifier("runtime.rename.\(row.id)").onAppear { isRenameFieldFocused = true }.onChange(
            of: isRenameFieldFocused
        ) { _, isFocused in if !isFocused { renamingRowID = nil } }
    }

    private func hasContextMenu(_ row: SpacesMobileWorkspaceRuntimeRow) -> Bool {
        row.canRun || row.canStop || row.canRestart || model.canRename(row: row)
    }

    private func beginRename(for row: SpacesMobileWorkspaceRuntimeRow) {
        renameText = row.title
        renamingRowID = row.id
    }

    private func commitRename(for row: SpacesMobileWorkspaceRuntimeRow) {
        let title = renameText
        renamingRowID = nil
        Task { await model.rename(row: row, to: title) }
    }

    /// Browser session rows are always tappable: opening one loads a URL through the on-device proxy
    /// and never touches the bridge client, so unlike every other row it is gated neither on
    /// `isMutating` nor on having a session or a run action.
    private func isRuntimeRowDisabled(_ row: SpacesMobileWorkspaceRuntimeRow) -> Bool {
        guard !row.isBrowserSession else { return false }
        return model.isMutating || (row.sessionID == nil && !row.canRun)
    }

    @ViewBuilder private func runtimeTrailingIndicator(for row: SpacesMobileWorkspaceRuntimeRow) -> some View {
        if row.isBrowserSession || row.sessionID != nil { RowChevron() } else if row.canRun { RowPlayIndicator() }
    }

    /// The lifecycle subset of `runtimeContextMenu`. Rename stays menu-only: it swaps a text field into
    /// the row, which a swipe gesture that has just closed cannot hand focus to cleanly. The row being
    /// renamed offers nothing at all — swiping it would only drop the field's focus and discard the edit.
    @ViewBuilder private func runtimeSwipeActions(for row: SpacesMobileWorkspaceRuntimeRow) -> some View {
        if renamingRowID != row.id { runtimeLifecycleSwipeActions(for: row) }
    }

    @ViewBuilder private func runtimeLifecycleSwipeActions(for row: SpacesMobileWorkspaceRuntimeRow) -> some View {
        if row.canRun {
            Button {
                pendingTerminalLaunch = PendingTerminalLaunch(row: row, action: .run)
            } label: {
                Label("Run", systemImage: "play.fill")
            }.tint(Theme.accent).disabled(model.isMutating)
        }
        if row.canStop {
            Button {
                Task { await model.stop(row: row) }
            } label: {
                Label("Stop", systemImage: "stop.fill")
            }.tint(Theme.red).disabled(model.isMutating)
        }
        if row.canRestart {
            Button {
                pendingTerminalLaunch = PendingTerminalLaunch(row: row, action: .restart)
            } label: {
                Label("Restart", systemImage: "arrow.clockwise")
            }.tint(Theme.muted).disabled(model.isMutating)
        }
    }

    @ViewBuilder private func runtimeContextMenu(for row: SpacesMobileWorkspaceRuntimeRow) -> some View {
        if row.canRun {
            Button {
                pendingTerminalLaunch = PendingTerminalLaunch(row: row, action: .run)
            } label: {
                Label("Run", systemImage: "play.fill")
            }.disabled(model.isMutating)
        }
        if row.canStop {
            Button {
                Task { await model.stop(row: row) }
            } label: {
                Label("Stop", systemImage: "stop.fill")
            }.disabled(model.isMutating)
        }
        if row.canRestart {
            Button {
                pendingTerminalLaunch = PendingTerminalLaunch(row: row, action: .restart)
            } label: {
                Label("Restart", systemImage: "arrow.clockwise")
            }.disabled(model.isMutating)
        }
        if model.canRename(row: row) {
            Button {
                beginRename(for: row)
            } label: {
                Label("Rename", systemImage: "pencil")
            }.disabled(model.isMutating)
        }
    }

    private func activateRuntimeRow(_ row: SpacesMobileWorkspaceRuntimeRow) {
        if case .browserSession(let browserRow) = row.source {
            guard let proxyRequest = model.browserSessionProxyRequest(for: browserRow) else { return }
            selectedBrowserSession = SelectedBrowserSessionRoute(row: browserRow, proxyRequest: proxyRequest)
        } else if let session = model.terminalSession(for: row) {
            selectedSession = SelectedTerminalSessionRoute(session: session)
        } else if row.canRun {
            pendingTerminalLaunch = PendingTerminalLaunch(row: row, action: .primary)
        }
    }

    // MARK: - Hidden workspaces

    /// Demo Mode's backend cannot serve `setWorkspaceHidden`, so the recovery section that depends on it
    /// stays off there — the same reasoning that keeps Hide itself out of `WorkspaceBandActions`. The
    /// section is otherwise unfiltered by search or the row/state filters: it exists to recover a
    /// workspace that the filtered browse below can no longer show, not to be browsed itself. Loose
    /// terminal-session groups set the precedent for how search affects an auxiliary section here — they
    /// stay on screen and filter their own contents rather than disappearing outright — so this section
    /// likewise stays on screen while a search is active instead of hiding.
    private var isHiddenSectionVisible: Bool { !model.isDemoModeEnabled && !model.hiddenWorkspaces.isEmpty }

    @ViewBuilder private var hiddenSection: some View {
        if isHiddenSectionVisible {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { model.toggleHiddenSectionExpanded() }
            } label: {
                HeaderBand {
                    Text("Hidden").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                    Spacer(minLength: 0)
                    Text("\(model.hiddenWorkspaces.count)").font(.system(size: 12)).foregroundStyle(Theme.mutedSecondary).monospacedDigit()
                    Image(systemName: model.isHiddenSectionExpanded ? "chevron.down" : "chevron.right").font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.mutedSecondary)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityIdentifier("spaces.hiddenSection").bandListHeaderRow()
            if model.isHiddenSectionExpanded { ForEach(model.hiddenWorkspaces) { workspace in hiddenWorkspaceRow(workspace) } }
        }
    }

    private func hiddenWorkspaceRow(_ workspace: SpacesDeviceWorkspaceSummary) -> some View {
        BandRow(
            dotKind: nil, tile: TypeIconTile(systemName: workspace.isGitWorkspace ? "arrow.triangle.branch" : "folder"), title: workspace.displayName,
            detail: workspace.projectName, detailIsMonospaced: false
        ) { EmptyView() }.bandListRow().accessibilityIdentifier("workspace.hidden.\(workspace.id)").contextMenu { unhideButton(workspace) }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) { unhideButton(workspace) }
    }

    /// No confirmation: unlike Hide (which can stop a running workspace), unhiding only changes
    /// visibility and cannot lose anything, so it fires directly from the swipe or the menu.
    private func unhideButton(_ workspace: SpacesDeviceWorkspaceSummary) -> some View {
        Button {
            Task { await model.unhideWorkspace(workspace) }
        } label: {
            Label("Unhide", systemImage: "eye")
        }.tint(Theme.accent).disabled(model.isMutating).accessibilityIdentifier("workspace.unhide.\(workspace.id)")
    }

    // MARK: - Loose terminal-session groups

    @ViewBuilder private func terminalGroupSection(_ group: SpacesMobileTerminalWorkspaceGroup) -> some View {
        let workspace = model.overview?.workspaces.first { $0.id == group.id }
        HeaderBand {
            WorkspaceBandLabel(isGitWorkspace: workspace?.isGitWorkspace ?? false, displayName: group.workspaceTitle)
            Spacer(minLength: 0)
            Text(group.projectName.uppercased()).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.mutedSecondary).tracking(0.4)
                .lineLimit(1)
        }.accessibilityIdentifier("workspace.band.\(group.id)").bandListHeaderRow()
        ForEach(group.sessions) { session in terminalSessionRow(session).bandListRow() }
    }

    private func terminalSessionRow(_ session: SpacesDeviceTerminalSessionSummary) -> some View {
        Button {
            selectedSession = SelectedTerminalSessionRoute(session: session)
        } label: {
            BandRow(
                dotKind: StatusDot.Kind(session.state), tile: .tile(for: .workspaceTerminals), title: session.title, detail: session.liveTitle ?? ""
            ) { RowChevron() }
        }.buttonStyle(.plain).disabled(model.isMutating || (!session.isControlAvailable && !session.hasFinalRender)).accessibilityIdentifier(
            "terminal.row.\(session.id)")
    }
}

/// The workspace band's actions — Hide and Delete — offered both on long press and on trailing swipe.
/// Demo Mode's backend can do neither, so there the band presents no menu and no swipe rather than
/// actions that would fail. A full swipe cannot fire either action: Delete needs its confirmation sheet
/// and Hide its confirmation dialog, so neither is safe to trigger by over-swiping.
private struct WorkspaceBandActions: ViewModifier {
    let model: SpacesMobileAppModel
    let workspace: SpacesDeviceWorkspaceSummary
    let onHide: () -> Void
    let onDelete: () -> Void

    /// The daemon refuses to delete a default workspace — a project's own directory goes when the project
    /// does — so the action is hidden rather than offered and rejected.
    private var canDelete: Bool { !workspace.isDefault }

    func body(content: Content) -> some View {
        if model.isDemoModeEnabled {
            content
        } else {
            content.contextMenu {
                hideButton
                if canDelete { deleteButton }
            }.swipeActions(edge: .trailing, allowsFullSwipe: false) {
                if canDelete { deleteButton }
                hideButton.tint(Theme.muted)
            }
        }
    }

    private var hideButton: some View {
        Button {
            onHide()
        } label: {
            Label("Hide", systemImage: "eye.slash")
        }.disabled(model.isMutating).accessibilityIdentifier("workspace.hide.\(workspace.id)")
    }

    private var deleteButton: some View {
        Button(role: .destructive) {
            onDelete()
        } label: {
            Label("Delete", systemImage: "trash")
        }.disabled(model.isMutating).accessibilityIdentifier("workspace.delete.\(workspace.id)")
    }
}

private struct ProjectGroup: Identifiable {
    let projectID: String
    let projectName: String
    let workspaceGroups: [SpacesMobileWorkspaceGroup]
    var id: String { projectID }
}

/// A browser-session row pushed onto the Spaces stack, carrying the authenticated proxy request the
/// web view loads. Only the Spaces tab lists browser sessions, so this route lives here rather than
/// in the terminal navigation shared with Alerts and Agents.
struct SelectedBrowserSessionRoute: Identifiable, Hashable {
    let row: SpacesMobileBrowserSessionRow
    let proxyRequest: BrowserProxyRequest

    var id: String { row.id }

    static func == (lhs: SelectedBrowserSessionRoute, rhs: SelectedBrowserSessionRoute) -> Bool { lhs.id == rhs.id }

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// New-workspace sheet: pick a project on the active device, then a branch for git projects.
struct WorkspaceCreateSheet: View {
    @Environment(\.dismiss) private var dismiss
    let model: SpacesMobileAppModel

    @State private var selectedProjectID: String?
    @State private var branch = ""

    private var projects: [SpacesDeviceProjectSummary] { model.workspaceCreateOptions?.projects ?? model.overview?.projects ?? [] }

    private var project: SpacesDeviceProjectSummary? { projects.first(where: { $0.id == selectedProjectID }) }

    private var isGitRepo: Bool { project?.isGitRepo == true }

    // Only git projects support creating workspaces; a non-git project owns a single
    // workspace (its project directory).
    private var canCreate: Bool { isGitRepo && !branch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        NavigationStack {
            Form {
                Section("Project") {
                    Picker("Project", selection: $selectedProjectID) { ForEach(projects) { project in Text(project.name).tag(Optional(project.id)) } }
                }
                if isGitRepo {
                    Section("Branch") { TextField("new branch name", text: $branch).textInputAutocapitalization(.never).autocorrectionDisabled() }
                } else if project != nil {
                    Section { Text("Non-git projects have a single workspace for the project directory.").foregroundStyle(.secondary) }
                }
            }.navigationTitle("New Workspace").toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(model.isMutating ? "Creating..." : "Create") {
                        guard let selectedProjectID else { return }
                        Task {
                            let trimmedBranch = branch.trimmingCharacters(in: .whitespacesAndNewlines)
                            await model.createWorkspace(
                                projectID: selectedProjectID, branch: trimmedBranch, baseBranch: project?.defaultBranch, directoryName: nil,
                                allowExistingBranchReuse: false)
                        }
                    }.disabled(!canCreate || model.isMutating)
                }
            }.task {
                await model.loadWorkspaceCreateOptions()
                if selectedProjectID == nil { selectedProjectID = model.workspaceCreateOptions?.selectedProjectID ?? projects.first?.id }
            }
        }
    }
}
