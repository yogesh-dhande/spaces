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
                    ? "\"\(workspace.displayName)\" is running. Hiding it stops its processes and coding agents, and moves it to the Hidden section at the end of this list."
                    : "\"\(workspace.displayName)\" will move to the Hidden section at the end of this list.")
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
                    #if DEBUG
                        let _ = SpacesListIdentityDump.record(listIdentityRows)
                    #endif
                    Section {
                        homeControls.padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 12).bandListRow().id(SpacesListRowID.controls)
                    }
                    if model.isActiveDeviceBlocked {
                        // Fully blocked, scoped to this device: the banner in homeControls is the only
                        // surface. Switch to another paired device or restart this device's daemon.
                        EmptyView()
                    } else if model.isLoading && model.overview == nil {
                        Section {
                            ProgressView("Loading workspaces...").frame(maxWidth: .infinity, minHeight: 360).bandListRow().id(SpacesListRowID.loading)
                        }
                    } else if projectGroups.isEmpty && model.terminalGroups.isEmpty && !isHiddenSectionVisible {
                        Section {
                            ContentUnavailableView(
                                "No Workspaces", systemImage: "rectangle.stack",
                                description: Text("Create a workspace or adjust the current filters.")
                            ).frame(maxWidth: .infinity, minHeight: 360).bandListRow().id(SpacesListRowID.empty)
                        }
                    } else {
                        ForEach(projectGroups) { projectGroup in projectSection(projectGroup) }
                        ForEach(model.terminalGroups) { group in terminalGroupSection(group) }
                    }
                    if !model.isActiveDeviceBlocked { hiddenSection }
                }.listStyle(.plain).listSectionSpacing(0).id(terminalListRefreshGeneration).background(Theme.bg).scrollContentBackground(.hidden)
                    .refreshable { await model.refresh() }
            }
        }.background(Theme.bg.ignoresSafeArea())
    }

    #if DEBUG
        /// The identity of every row `homeView`'s list is about to render, in the same order and under the
        /// same conditions, for `SpacesListIdentityDump`. Built from the same `SpacesListRowID` values the
        /// rows themselves carry, so the dump reports what the list actually identifies rows by rather than
        /// a second description of it that could drift.
        private var listIdentityRows: [String] {
            var rows = ["controls@\(SpacesListRowID.controls)"]
            if model.isActiveDeviceBlocked {
                // No rows: the compatibility banner in homeControls is the whole surface.
            } else if model.isLoading && model.overview == nil {
                rows.append("loading@\(SpacesListRowID.loading)")
            } else if projectGroups.isEmpty && model.terminalGroups.isEmpty && !isHiddenSectionVisible {
                rows.append("empty@\(SpacesListRowID.empty)")
            } else {
                for projectGroup in projectGroups {
                    rows.append("projectCaption@\(SpacesListRowID.projectCaption(projectGroup.id))")
                    for group in projectGroup.workspaceGroups {
                        rows.append("band@\(SpacesListRowID.workspaceBand(group.id))")
                        guard !model.collapsedWorkspaceIDs.contains(group.id) else { continue }
                        rows.append("controlBar@\(SpacesListRowID.workspaceControlBar(group.id))")
                        if group.rows.isEmpty { rows.append("noRows@\(SpacesListRowID.workspaceEmptyRows(group.id))") }
                        rows.append(contentsOf: group.rows.map { "runtimeRow@\(SpacesListRowID.runtimeRow($0.id))" })
                    }
                }
                for group in model.terminalGroups {
                    rows.append("looseBand@\(SpacesListRowID.looseBand(group.workspaceID))")
                    rows.append(contentsOf: group.sessions.map { "looseSession@\(SpacesListRowID.looseSession($0.id))" })
                }
            }
            if !model.isActiveDeviceBlocked, isHiddenSectionVisible {
                rows.append("hiddenHeader@\(SpacesListRowID.hiddenHeader)")
                if model.isHiddenSectionExpanded {
                    rows.append(contentsOf: model.hiddenWorkspaces.map { "hiddenWorkspace@\(SpacesListRowID.hiddenWorkspace($0.id))" })
                }
            }
            return rows
        }
    #endif

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

    /// One list section for the project's caption and one for each of its workspaces.
    ///
    /// The sections are what keep the list's bookkeeping sound rather than a visual device — they carry no
    /// header and `listSectionSpacing(0)` keeps them from adding any spacing of their own, so the caption
    /// and bands look exactly as they did when the whole tab was a single section. Every workspace being
    /// its own section means adding or removing one is an insert or delete of a whole section instead of a
    /// run of rows inside a 49-row section, which is the update the collection view was miscounting.
    @ViewBuilder private func projectSection(_ projectGroup: ProjectGroup) -> some View {
        Section {
            Text(projectGroup.projectName.uppercased()).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.mutedSecondary).tracking(0.4)
                .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 20).padding(.top, 14).bandListRow().id(
                    SpacesListRowID.projectCaption(projectGroup.id))
        }
        ForEach(Array(projectGroup.workspaceGroups.enumerated()), id: \.element.id) { index, group in
            // The project caption already separates the first workspace from what is above it, so only
            // the workspaces after it carry the full band lead-in gap.
            Section { workspaceSection(group, topGap: index == 0 ? 8 : 14) }
        }
    }

    /// A workspace's band plus, when it is expanded, its control bar and runtime rows.
    ///
    /// Marking a workspace as deleting changes only what its rows draw and what they accept — it adds no
    /// row and takes none away. Collapsing the workspace for the duration would read better, and was tried
    /// three times, but removing its control bar and runtime rows at the moment the delete is confirmed
    /// crashes the collection view (`attempt to delete item 6 from section 3 which only contains 6 items
    /// before the update`): it counts one item fewer than the section actually holds, so a removal inside
    /// a section walks off its end. Wrapping the publishes in an animation, which is the one code path
    /// that never crashed, does not change that. Removing a whole section — what the daemon confirming
    /// the delete does — is sound; removing rows within one is not. The only structural change a delete
    /// makes is therefore the one the daemon confirms, when the workspace leaves the overview.
    @ViewBuilder private func workspaceSection(_ group: SpacesMobileWorkspaceGroup, topGap: CGFloat) -> some View {
        let isDeleting = model.isWorkspacePendingDeletion(group.id)
        let isCollapsed = model.collapsedWorkspaceIDs.contains(group.id)
        Button {
            withAnimation(.easeInOut(duration: 0.2)) { model.toggleWorkspaceCollapsed(group.id) }
        } label: {
            HeaderBand {
                WorkspaceBandLabel(isGitWorkspace: group.workspace.isGitWorkspace, displayName: group.workspace.displayName)
                Spacer(minLength: 0)
                // The spinner takes the collapse chevron's place, so a deleting band reads as busy rather
                // than merely collapsed.
                if isDeleting {
                    ProgressView().controlSize(.small).tint(Theme.mutedSecondary)
                } else {
                    Image(systemName: isCollapsed ? "chevron.right" : "chevron.down").font(.system(size: 12, weight: .semibold)).foregroundStyle(
                        Theme.mutedSecondary)
                }
            }.contentShape(Rectangle()).opacity(isDeleting ? 0.5 : 1)
        }.buttonStyle(.plain).disabled(isDeleting).accessibilityIdentifier("workspace.band.\(group.id)").accessibilityValue(
            isDeleting ? "Deleting" : ""
        ).bandListHeaderRow(topGap: topGap).modifier(
            WorkspaceBandActions(
                model: model, workspace: group.workspace, onHide: { pendingHideWorkspace = group.workspace },
                onDelete: { pendingDeleteWorkspace = group.workspace })
        ).id(SpacesListRowID.workspaceBand(group.id))
        if !isCollapsed {
            // Dimmed and inert with the band while the delete runs: the rows stay listed (removing them is
            // the structural change this deliberately avoids) but nothing under a workspace on its way out
            // is worth acting on.
            WorkspaceControlBar(
                workspace: group.workspace, isMutating: model.isMutating || isDeleting,
                onStart: { Task { await model.launchWorkspace(group.workspace) } },
                onRestart: { Task { await model.restartWorkspace(group.workspace) } },
                onStop: { Task { await model.stopWorkspace(group.workspace) } },
                // Demo Mode's backend does not open ad hoc terminals; hide the action there.
                onNewTerminal: model.isDemoModeEnabled ? nil : { pendingTerminalLaunch = PendingTerminalLaunch(workspace: group.workspace) }
            ).opacity(isDeleting ? 0.5 : 1).bandListRow().id(SpacesListRowID.workspaceControlBar(group.id))
            if group.rows.isEmpty {
                Text("No configured rows").font(.system(size: 12)).foregroundStyle(Theme.muted).frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 9).padding(.horizontal, 20).bandListRow().id(SpacesListRowID.workspaceEmptyRows(group.id))
            }
            ForEach(group.rows) { row in
                // Lifecycle actions reach a row two ways: a long press opens the full menu (Rename
                // included), a trailing swipe offers the lifecycle subset. Full swipe is off so an
                // over-swipe cannot run or stop something on its own.
                runtimeRow(row).disabled(isDeleting).opacity(isDeleting ? 0.5 : 1).bandListRow().swipeActions(edge: .trailing, allowsFullSwipe: false)
                { runtimeSwipeActions(for: row) }.id(SpacesListRowID.runtimeRow(row.id))
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

    /// The Hidden header and each hidden workspace are separate list sections rather than rows of one
    /// section, for the same reason each workspace is its own section: hiding and unhiding add and remove
    /// a row while the section around it survives, and a row leaving a surviving section is the update the
    /// collection view miscounts (see `workspaceSection`). A whole section arriving or leaving is sound,
    /// so every row that can come and go independently owns one.
    @ViewBuilder private var hiddenSection: some View {
        if isHiddenSectionVisible {
            Section {
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
                }.buttonStyle(.plain).accessibilityIdentifier("spaces.hiddenSection").bandListHeaderRow().id(SpacesListRowID.hiddenHeader)
            }
            if model.isHiddenSectionExpanded { ForEach(model.hiddenWorkspaces) { workspace in Section { hiddenWorkspaceRow(workspace) } } }
        }
    }

    private func hiddenWorkspaceRow(_ workspace: SpacesDeviceWorkspaceSummary) -> some View {
        BandRow(
            dotKind: nil, tile: TypeIconTile(systemName: workspace.isGitWorkspace ? "arrow.triangle.branch" : "folder"), title: workspace.displayName,
            detail: workspace.projectName, detailIsMonospaced: false
        ) { EmptyView() }.bandListRow().accessibilityIdentifier("workspace.hidden.\(workspace.id)").contextMenu { unhideButton(workspace) }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) { unhideButton(workspace) }.id(SpacesListRowID.hiddenWorkspace(workspace.id))
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

    /// The band and each loose session are separate sections, like the Hidden section's rows: a session
    /// ending drops its row while the band around it stays, and a row leaving a surviving section is what
    /// the collection view miscounts.
    @ViewBuilder private func terminalGroupSection(_ group: SpacesMobileTerminalWorkspaceGroup) -> some View {
        let workspace = model.overview?.workspaces.first { $0.id == group.workspaceID }
        Section {
            HeaderBand {
                WorkspaceBandLabel(isGitWorkspace: workspace?.isGitWorkspace ?? false, displayName: group.workspaceTitle)
                Spacer(minLength: 0)
                Text(group.projectName.uppercased()).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.mutedSecondary).tracking(0.4)
                    .lineLimit(1)
                // Identified as the loose band it is, not as the workspace: the workspace's own band
                // already carries `workspace.band.<id>`, and two rows answering to one identifier is what
                // `SpacesMobileTerminalWorkspaceGroup.id` exists to avoid.
            }.accessibilityIdentifier("workspace.looseBand.\(group.workspaceID)").bandListHeaderRow().id(SpacesListRowID.looseBand(group.workspaceID))
        }
        ForEach(group.sessions) { session in Section { terminalSessionRow(session).bandListRow().id(SpacesListRowID.looseSession(session.id)) } }
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

/// The identity of every row in the Spaces list.
///
/// Each row states its own identity with `.id(…)` rather than leaving SwiftUI to infer one from where the
/// row sits in the builder. The Spaces list is one section assembled from sibling `ForEach`es and
/// multi-row builder functions, and inferred identity there proved unstable: with the list's rows and
/// their order provably unchanged (see `SpacesListIdentityDump`), the collection view was still told 15
/// rows had been deleted and 15 inserted, and it counted one item fewer than the list actually had. An
/// update against that mismatched bookkeeping is the inconsistent batch update that crashed the app while
/// a workspace was being deleted.
///
/// A row's identity must therefore be unique across the whole list, not merely within its own `ForEach` —
/// every case here is prefixed by the kind of row it is, so an id the daemon reuses across row families
/// (a workspace id naming both a band and a loose band, say) still yields two distinct rows.
private enum SpacesListRowID {
    static let controls = "controls"
    static let loading = "loading"
    static let empty = "empty"
    static let hiddenHeader = "hidden.header"

    static func projectCaption(_ projectID: String) -> String { "project.caption.\(projectID)" }
    static func workspaceBand(_ workspaceID: String) -> String { "workspace.band.\(workspaceID)" }
    static func workspaceControlBar(_ workspaceID: String) -> String { "workspace.controlBar.\(workspaceID)" }
    static func workspaceEmptyRows(_ workspaceID: String) -> String { "workspace.noRows.\(workspaceID)" }
    static func runtimeRow(_ rowID: String) -> String { "runtime.row.\(rowID)" }
    static func looseBand(_ workspaceID: String) -> String { "loose.band.\(workspaceID)" }
    static func looseSession(_ sessionID: String) -> String { "loose.session.\(sessionID)" }
    static func hiddenWorkspace(_ workspaceID: String) -> String { "hidden.workspace.\(workspaceID)" }
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

#if DEBUG
    /// Test-support diagnostic, not product behavior: prints the identity of every row the Spaces list is
    /// about to render, in render order, once per content evaluation.
    ///
    /// It exists because `UICollectionView`'s inconsistent-update exception reports only counts ("after the
    /// update (42) must be (41)"), which cannot say *which* row the list lost or gained. Dumping the
    /// flattened identity list on every evaluation makes the two publishes either side of a crash directly
    /// diffable, and makes a duplicate identity — two rows the list counts as one — visible at a glance.
    ///
    /// Each row is logged as `label@identity`: `label` is where the row sits in the builder, `identity` is
    /// the value SwiftUI identifies it by (`-` for rows carrying structural identity only, which have no id
    /// of their own). Duplicates are therefore judged on the `identity` half, across the whole flattened
    /// list rather than per `ForEach`.
    ///
    /// Lives beside `SpacesTabView.listIdentityRows`, the mirror of the list body it dumps, so the two are
    /// edited together. Off unless `SPACES_MOBILE_LIST_IDENTITY_DUMP=1` is set in the app's environment,
    /// and compiled out of release builds entirely.
    @MainActor enum SpacesListIdentityDump {
        static let isEnabled = ProcessInfo.processInfo.environment["SPACES_MOBILE_LIST_IDENTITY_DUMP"] == "1"

        private static var sequence = 0

        /// `rows` is an autoclosure so a disabled dump costs nothing but the flag read — the list body is
        /// re-evaluated constantly while scrolling, and this runs inside that evaluation.
        static func record(_ rows: @autoclosure () -> [String]) {
            guard isEnabled else { return }
            sequence += 1
            let identities = rows()
            let duplicates = duplicateIdentities(in: identities)
            let line =
                "LISTDUMP seq=\(sequence) t=\(String(format: "%.4f", Date().timeIntervalSince1970)) count=\(identities.count) "
                + "duplicates=\(duplicates.isEmpty ? "none" : duplicates.joined(separator: ",")) rows=\(identities.joined(separator: " "))\n"
            FileHandle.standardError.write(Data(line.utf8))
        }

        /// The identities carried by more than one row, which is exactly what makes a batch update
        /// inconsistent: the list then holds fewer distinct identities than it has rows. Structural-only
        /// rows (`-`) are excluded — they are told apart by position, not by value.
        private static func duplicateIdentities(in rows: [String]) -> [String] {
            var seen: Set<String> = []
            var duplicates: [String] = []
            for row in rows {
                guard let identity = row.split(separator: "@", maxSplits: 1).last.map(String.init), identity != "-" else { continue }
                if !seen.insert(identity).inserted, !duplicates.contains(identity) { duplicates.append(identity) }
            }
            return duplicates
        }
    }
#endif
