import SwiftUI
import UIKit
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
    @State private var pendingStop: PendingStop?
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
        }.confirmationDialog(pendingStop?.title ?? "", isPresented: pendingStopDialogBinding, titleVisibility: .visible, presenting: pendingStop) {
            stop in
            Button("Stop", role: .destructive) { Task { await performPendingStop(stop) } }
            Button("Cancel", role: .cancel) {}
        } message: { stop in
            Text(stop.message)
        }.sheet(item: $pendingDeleteWorkspace) { workspace in
            WorkspaceDeleteSheet(workspace: workspace) { deleteLocalBranch, deleteRemoteBranch in
                Task { await model.deleteWorkspace(workspace, deleteLocalBranch: deleteLocalBranch, deleteRemoteBranch: deleteRemoteBranch) }
            }
        }
    }

    private var hideWorkspaceDialogBinding: Binding<Bool> {
        Binding(get: { pendingHideWorkspace != nil }, set: { if !$0 { pendingHideWorkspace = nil } })
    }

    private var pendingStopDialogBinding: Binding<Bool> { Binding(get: { pendingStop != nil }, set: { if !$0 { pendingStop = nil } }) }

    private func performPendingStop(_ stop: PendingStop) async {
        switch stop {
        case .row(let row): await model.stop(row: row)
        case .workspace(let workspace): await model.stopWorkspace(workspace)
        }
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
                        let _ = SpacesListIdentityDump.record(
                            listIdentitySections,
                            state: "pendingDelete=\(pendingDeleteWorkspace?.id ?? "none") pendingHide=\(pendingHideWorkspace?.id ?? "none") "
                                + "mutating=\(model.isMutating) marked=\(model.overview?.workspaces.filter { model.isWorkspacePendingDeletion($0.id) }.map(\.id).joined(separator: "+") ?? "")"
                        )
                    #endif
                    Section {
                        homeControls.padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 12).bandListRow().id(SpacesListRowID.controls)
                    }
                    if model.isActiveDeviceBlocked {
                        // Fully blocked, scoped to this device: nothing here can be used, so the version
                        // hero takes the whole list when there is something for the user to do or know,
                        // and the screen stays bare while Spaces is applying a staged build by itself.
                        // Switch to another paired device from the selector above either way.
                        if case .hero(let hero) = model.daemonCompatibilityPresentation {
                            Section {
                                DaemonVersionHeroView(content: hero, isMutating: model.isMutating, isApplyingUpdate: model.isApplyingDaemonUpdate) {
                                    Task { await model.retryStagedApply() }
                                }.frame(maxWidth: .infinity, minHeight: 360).bandListRow().id(SpacesListRowID.compatibilityHero)
                            }
                        }
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
        /// Every row `homeView`'s list is about to render, grouped into the sections it renders them in, in
        /// the same order and under the same conditions, for `SpacesListIdentityDump`. Built from the same
        /// `SpacesListRowID` values and the same `Section` boundaries the body uses, so the dump reports
        /// what the list actually holds rather than a second description of it that could drift.
        ///
        /// Sectioned rather than flat because the collection view's inconsistency is a *per-section* count:
        /// the dump is only comparable with UIKit's own `numberOfItems(inSection:)` if it is partitioned
        /// the same way.
        private var listIdentitySections: [[String]] {
            var sections: [[String]] = [["controls@\(SpacesListRowID.controls)"]]
            if model.isActiveDeviceBlocked {
                // The version hero is the whole surface, and there is none while a staged build is being
                // applied on its own.
                if case .hero = model.daemonCompatibilityPresentation { sections.append(["compatibilityHero@\(SpacesListRowID.compatibilityHero)"]) }
            } else if model.isLoading && model.overview == nil {
                sections.append(["loading@\(SpacesListRowID.loading)"])
            } else if projectGroups.isEmpty && model.terminalGroups.isEmpty && !isHiddenSectionVisible {
                sections.append(["empty@\(SpacesListRowID.empty)"])
            } else {
                for projectGroup in projectGroups {
                    sections.append(["projectCaption@\(SpacesListRowID.projectCaption(projectGroup.id))"])
                    for group in projectGroup.workspaceGroups {
                        var workspaceSection = ["band@\(SpacesListRowID.workspaceBand(group.id))"]
                        if !model.collapsedWorkspaceIDs.contains(group.id) {
                            workspaceSection.append("controlBar@\(SpacesListRowID.workspaceControlBar(group.id))")
                            if group.rows.isEmpty { workspaceSection.append("noRows@\(SpacesListRowID.workspaceEmptyRows(group.id))") }
                            workspaceSection.append(contentsOf: group.rows.map { "runtimeRow@\(SpacesListRowID.runtimeRow($0.id))" })
                        }
                        sections.append(workspaceSection)
                    }
                }
                for group in model.terminalGroups {
                    sections.append(["looseBand@\(SpacesListRowID.looseBand(group.workspaceID))"])
                    sections.append(contentsOf: group.sessions.map { ["looseSession@\(SpacesListRowID.looseSession($0.id))"] })
                }
            }
            if !model.isActiveDeviceBlocked, isHiddenSectionVisible {
                sections.append(["hiddenHeader@\(SpacesListRowID.hiddenHeader)"])
                if model.isHiddenSectionExpanded {
                    sections.append(contentsOf: model.hiddenProjects.map { ["hiddenProject@\(SpacesListRowID.hiddenProject($0.projectID))"] })
                    sections.append(contentsOf: model.hiddenWorkspaces.map { ["hiddenWorkspace@\(SpacesListRowID.hiddenWorkspace($0.id))"] })
                }
            }
            return sections
        }
    #endif

    private var homeControls: some View {
        VStack(spacing: 8) {
            deviceSelectorRow
            pendingUpdateCard
            if !model.isActiveDeviceBlocked { searchFilterRow }
        }
    }

    /// The quiet card for a device that works fine and has an update waiting. A blocked device's state
    /// is not shown here at all: it takes the whole list as the version hero, or nothing while Spaces is
    /// applying the staged build on its own.
    @ViewBuilder private var pendingUpdateCard: some View {
        if case .pendingUpdate(let content) = model.daemonCompatibilityPresentation {
            // The update action fires directly: `requestDaemonUpdate()` re-execs the daemon onto
            // whatever build is staged and preserves running terminals, processes, and coding agents,
            // so there is nothing to confirm or defer.
            PendingDaemonUpdateCardView(content: content, isMutating: model.isMutating, isApplyingUpdate: model.isApplyingDaemonUpdate) {
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
                // Every action here rides the shared `commandChannel`, whose gate drops a second mutation
                // without sending it, so the bar must read busy while any shared-channel mutation is in
                // flight or its taps would silently do nothing. A delete never sets `isMutating` (it runs
                // on its own private channel), so another workspace's delete never dims this bar (#450);
                // this workspace's own delete dims it via `isDeleting`.
                workspace: group.workspace, isBusy: model.isMutating || isDeleting,
                onStart: { Task { await model.launchWorkspace(group.workspace) } },
                onRestart: { Task { await model.restartWorkspace(group.workspace) } }, onStop: { pendingStop = .workspace(group.workspace) },
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
                // The swipe tray and the long-press menu are attached unconditionally so the row keeps its
                // identity (a structural change here is what the collection view miscounts — see above),
                // but they offer nothing while the workspace is deleting: `disabled` covers the row's own
                // tap, not the action surfaces hanging off it.
                runtimeRow(row, isDeleting: isDeleting).disabled(isDeleting).opacity(isDeleting ? 0.5 : 1).bandListRow().swipeActions(
                    edge: .trailing, allowsFullSwipe: false
                ) { if !isDeleting { runtimeSwipeActions(for: row) } }.id(SpacesListRowID.runtimeRow(row.id))
            }
        }
    }

    @ViewBuilder private func runtimeRow(_ row: SpacesMobileWorkspaceRuntimeRow, isDeleting: Bool) -> some View {
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
            if hasContextMenu(row), !isDeleting { button.contextMenu { runtimeContextMenu(for: row) } } else { button }
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

    /// Browser session rows are always tappable: opening one loads a URL through the on-device proxy and
    /// never touches the bridge client, so unlike every other row it is gated neither on having a session
    /// nor a run action, and never on `model.isMutating` (#450). A row with an existing session is the
    /// same: its tap navigates to that session locally (`activateRuntimeRow`) without touching the bridge
    /// client either, so it too stays ungated regardless of `model.isMutating`. This row's own deleting
    /// state is covered separately by the `disabled` the caller wraps it in (`workspaceSection`).
    ///
    /// A session-less row with nothing to run offers nothing either way, gated or not. The one case left
    /// is a session-less row whose tap starts a run: `activateRuntimeRow` pushes
    /// `TerminalLaunchPendingView`, which calls `model.performPrimaryAction`/`run`, and that path shares
    /// `commandChannel` and is refused by `performMutationReturningSession`'s own `isMutating` guard. Left
    /// ungated, a tap during a shared-channel mutation would push that pending view only for it to resolve
    /// to `nil` and pop itself a moment later — so this one case stays gated on `model.isMutating`
    /// (review round 2, finding 3).
    private func isRuntimeRowDisabled(_ row: SpacesMobileWorkspaceRuntimeRow) -> Bool {
        guard !row.isBrowserSession, row.sessionID == nil else { return false }
        guard row.canRun else { return true }
        return model.isMutating
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
                pendingStop = .row(row)
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
                pendingStop = .row(row)
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

    /// Demo Mode's backend cannot serve `setWorkspaceHidden`/`setProjectHidden`, so the recovery section
    /// that depends on them stays off there — the same reasoning that keeps Hide itself out of
    /// `WorkspaceBandActions`. The section is otherwise unfiltered by search or the row/state filters: it
    /// exists to recover a workspace or project that the filtered browse below can no longer show, not to
    /// be browsed itself. Loose terminal-session groups set the precedent for how search affects an
    /// auxiliary section here — they stay on screen and filter their own contents rather than disappearing
    /// outright — so this section likewise stays on screen while a search is active instead of hiding.
    private var isHiddenSectionVisible: Bool { !model.isDemoModeEnabled && (!model.hiddenWorkspaces.isEmpty || !model.hiddenProjects.isEmpty) }

    /// The Hidden header and each hidden row (project or workspace) are separate list sections rather than
    /// rows of one section, for the same reason each workspace is its own section: hiding and unhiding add
    /// and remove a row while the section around it survives, and a row leaving a surviving section is the
    /// update the collection view miscounts (see `workspaceSection`). A whole section arriving or leaving
    /// is sound, so every row that can come and go independently owns one.
    ///
    /// Hidden projects list before hidden workspaces: a project entry recovers a whole group of workspaces
    /// at once, so it reads as the "bigger" recovery action and leads.
    @ViewBuilder private var hiddenSection: some View {
        if isHiddenSectionVisible {
            Section {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { model.toggleHiddenSectionExpanded() }
                } label: {
                    HeaderBand {
                        Text("Hidden").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                        Spacer(minLength: 0)
                        Text("\(model.hiddenProjects.count + model.hiddenWorkspaces.count)").font(.system(size: 12)).foregroundStyle(
                            Theme.mutedSecondary
                        ).monospacedDigit()
                        Image(systemName: model.isHiddenSectionExpanded ? "chevron.down" : "chevron.right").font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Theme.mutedSecondary)
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityIdentifier("spaces.hiddenSection").bandListHeaderRow().id(SpacesListRowID.hiddenHeader)
            }
            if model.isHiddenSectionExpanded {
                ForEach(model.hiddenProjects) { project in Section { hiddenProjectRow(project) } }
                ForEach(model.hiddenWorkspaces) { workspace in Section { hiddenWorkspaceRow(workspace) } }
            }
        }
    }

    /// One hidden project's recovery row: unhiding clears only the project's own flag, resurfacing every
    /// workspace under it (each still subject to its own `isHidden` flag independently).
    private func hiddenProjectRow(_ project: SpacesMobileHiddenProjectSummary) -> some View {
        BandRow(
            dotKind: nil, tile: TypeIconTile(systemName: "folder"), title: project.projectName,
            detail: project.workspaceCount == 1 ? "1 workspace" : "\(project.workspaceCount) workspaces", detailIsMonospaced: false
        ) { EmptyView() }.bandListRow().accessibilityIdentifier("project.hidden.\(project.projectID)").contextMenu {
            unhideProjectButton(project)
        }.swipeActions(edge: .trailing, allowsFullSwipe: false) { unhideProjectButton(project) }.id(
            SpacesListRowID.hiddenProject(project.projectID))
    }

    private func hiddenWorkspaceRow(_ workspace: SpacesDeviceWorkspaceSummary) -> some View {
        BandRow(
            dotKind: nil, tile: TypeIconTile(systemName: workspace.isGitWorkspace ? "arrow.triangle.branch" : "folder"), title: workspace.displayName,
            detail: workspace.projectName, detailIsMonospaced: false
        ) { EmptyView() }.bandListRow().accessibilityIdentifier("workspace.hidden.\(workspace.id)").contextMenu {
            // A workspace hidden from another client while this one's delete is still unresolved lands
            // here; it is leaving either way, so it offers no unhide.
            if !model.isWorkspacePendingDeletion(workspace.id) { unhideButton(workspace) }
        }.swipeActions(edge: .trailing, allowsFullSwipe: false) { if !model.isWorkspacePendingDeletion(workspace.id) { unhideButton(workspace) } }.id(
            SpacesListRowID.hiddenWorkspace(workspace.id))
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

    /// Same no-confirmation reasoning as `unhideButton`: unhiding a project only changes visibility.
    private func unhideProjectButton(_ project: SpacesMobileHiddenProjectSummary) -> some View {
        Button {
            Task { await model.unhideProject(project) }
        } label: {
            Label("Unhide", systemImage: "eye")
        }.tint(Theme.accent).disabled(model.isMutating).accessibilityIdentifier("project.unhide.\(project.projectID)")
    }

    // MARK: - Loose terminal-session groups

    /// The band and each loose session are separate sections, like the Hidden section's rows: a session
    /// ending drops its row while the band around it stays, and a row leaving a surviving section is what
    /// the collection view miscounts.
    @ViewBuilder private func terminalGroupSection(_ group: SpacesMobileTerminalWorkspaceGroup) -> some View {
        let workspace = model.overview?.workspaces.first { $0.id == group.workspaceID }
        // A loose group belongs to a workspace this list is still showing, so a delete running against
        // that workspace marks these rows exactly as it marks the workspace's own band: dimmed and inert,
        // whether this device issued the delete or the daemon reports another client's teardown. Sessions
        // of a workspace the overview has already dropped form no group at all (see `terminalGroups`), so
        // what is marked here is always a workspace still listed beside these rows.
        let isDeleting = model.isWorkspacePendingDeletion(group.workspaceID)
        Section {
            HeaderBand {
                WorkspaceBandLabel(isGitWorkspace: workspace?.isGitWorkspace ?? false, displayName: group.workspaceTitle)
                Spacer(minLength: 0)
                Text(group.projectName.uppercased()).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.mutedSecondary).tracking(0.4)
                    .lineLimit(1)
                // Identified as the loose band it is, not as the workspace: the workspace's own band
                // already carries `workspace.band.<id>`, and two rows answering to one identifier is what
                // `SpacesMobileTerminalWorkspaceGroup.id` exists to avoid.
            }.opacity(isDeleting ? 0.5 : 1).accessibilityIdentifier("workspace.looseBand.\(group.workspaceID)").accessibilityValue(
                isDeleting ? "Deleting" : ""
            ).bandListHeaderRow().id(SpacesListRowID.looseBand(group.workspaceID))
        }
        ForEach(group.sessions) { session in
            Section { terminalSessionRow(session, isDeleting: isDeleting).bandListRow().id(SpacesListRowID.looseSession(session.id)) }
        }
    }

    private func terminalSessionRow(_ session: SpacesDeviceTerminalSessionSummary, isDeleting: Bool) -> some View {
        Button {
            selectedSession = SelectedTerminalSessionRoute(session: session)
        } label: {
            BandRow(
                dotKind: StatusDot.Kind(session.state), tile: .tile(for: .workspaceTerminals), title: session.title, detail: session.liveTitle ?? ""
            ) { RowChevron() }
            // Gated on this row's own deleting state, not `model.isMutating`: that flag also covers
            // mutations against other workspaces, which have nothing to do with this loose session (#450).
        }.buttonStyle(.plain).disabled(isDeleting || (!session.isControlAvailable && !session.hasFinalRender)).opacity(isDeleting ? 0.5 : 1)
            .accessibilityIdentifier("terminal.row.\(session.id)")
    }
}

/// A stop the user has asked for but not yet confirmed: either one runtime row's session or a whole
/// workspace. Both live in this tab (the row swipe tray/context menu and the workspace control bar), so
/// they share this one pending-state/dialog pair rather than each entry point carrying its own.
private enum PendingStop {
    case row(SpacesMobileWorkspaceRuntimeRow)
    case workspace(SpacesDeviceWorkspaceSummary)

    var title: String {
        switch self {
        case .row(let row): StopConfirmationCopy.rowTitle(row.title)
        case .workspace(let workspace): StopConfirmationCopy.workspaceTitle(workspace.displayName)
        }
    }

    var message: String {
        switch self {
        case .row: StopConfirmationCopy.rowMessage
        case .workspace: StopConfirmationCopy.workspaceMessage
        }
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
    static let compatibilityHero = "compatibility.hero"
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
    static func hiddenProject(_ projectID: String) -> String { "hidden.project.\(projectID)" }
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
        // Suppressed, not disabled, for both cases — the Demo Mode backend cannot serve these, and a
        // workspace already marked for deletion is inert by contract. Disabling would still open the swipe
        // tray and the context menu on a band whose workspace is on its way out; leaving the surfaces off
        // entirely is what makes the row genuinely offer nothing. This is the only in-flight gate Delete
        // and Hide need here: a delete whose outcome could not be confirmed keeps this mark on well after
        // the mutation itself has finished, so this is checked on its own rather than folded into a busy
        // flag that has already cleared.
        if model.isDemoModeEnabled || model.isWorkspacePendingDeletion(workspace.id) {
            content
        } else {
            content.contextMenu {
                hideButton
                if canDelete { menuDeleteButton }
            }.swipeActions(edge: .trailing, allowsFullSwipe: false) {
                if canDelete { swipeDeleteButton }
                hideButton.tint(Theme.muted)
            }
        }
    }

    /// Hide carries no role for the same reason `swipeDeleteButton` does not: it opens a confirmation and
    /// the band stays listed until a refreshed overview reports the workspace hidden.
    private var hideButton: some View {
        Button {
            onHide()
        } label: {
            Label("Hide", systemImage: "eye.slash")
        }.disabled(model.isMutating).accessibilityIdentifier("workspace.hide.\(workspace.id)")
    }

    /// Delete in the long-press menu, where `.destructive` is only what colours it red. Not gated on
    /// `model.isMutating`: a delete against another workspace has no bearing on this one (#450), and a
    /// delete of this workspace already in flight is caught by the outer `isWorkspacePendingDeletion`
    /// check, which removes the whole tray rather than leaving a disabled button behind.
    private var menuDeleteButton: some View {
        Button(role: .destructive) {
            onDelete()
        } label: {
            deleteLabel
        }.accessibilityIdentifier("workspace.delete.\(workspace.id)")
    }

    /// Delete in the swipe tray — deliberately roleless, tinted red by hand instead of carrying
    /// `.destructive`.
    ///
    /// A destructive swipe action tells the collection view its row is going away, and it drops that item
    /// from its own bookkeeping the moment the button is tapped. This one removes nothing: it opens a
    /// confirmation sheet, and the row stays listed through the confirmation, through the pending-deletion
    /// mark, and until a refreshed overview stops carrying the workspace. From that tap onward the
    /// collection view holds one item fewer than the list does for that section, and the update that
    /// finally removes the workspace walks off the end — `attempt to delete item 8 from section 6 which
    /// only contains 8 items before the update`, raised long after the tap that caused it, with the list's
    /// own rows provably unchanged, uniquely identified, and identically ordered across the culprit update.
    /// The same Delete taken from the long-press menu never desyncs, because a menu makes no such promise.
    ///
    /// The rule: `.destructive` in `swipeActions` is only correct when the action removes the row from the
    /// data synchronously with the tap (the Alerts tab's dismiss does, and keeps its role). Any swipe
    /// action that leaves its row in place must not carry it. `.tint(Theme.red)` keeps the tray identical.
    ///
    /// Not gated on `model.isMutating` — see `menuDeleteButton`: a delete against another workspace runs on
    /// its own private channel and has no bearing on whether this one can be tapped (#450).
    private var swipeDeleteButton: some View {
        Button {
            onDelete()
        } label: {
            deleteLabel
        }.tint(Theme.red).accessibilityIdentifier("workspace.delete.\(workspace.id)")
    }

    private var deleteLabel: some View { Label("Delete", systemImage: "trash") }
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
    /// update (42) must be (41)"), which cannot say *which* row the list lost or gained, and is raised on a
    /// later update than the one that did the damage. Two lines are emitted per evaluation and compared:
    ///
    /// - `LISTDUMP` — what the list is about to hold, partitioned into the sections it renders, plus the
    ///   presentation state driving that evaluation. A duplicate identity, two rows the list counts as one,
    ///   is called out here.
    /// - `UIKITCOUNTS` — what each `UICollectionView` in the key window believes it holds, read a main-queue
    ///   hop later so this evaluation's update has been applied. These are the cached counts the exception
    ///   is raised against, not a fresh data-source query.
    ///
    /// The first evaluation whose per-section counts disagree is the update that lost the row, which is the
    /// one worth investigating; every later one merely inherits the drift. Note the collection views are
    /// reported in hierarchy order, so a tab switch renumbers them — match a view to this list by its
    /// section count, never by position.
    ///
    /// Each row is logged as `label@identity`: `label` is where the row sits in the builder, `identity` is
    /// the value SwiftUI identifies it by (`-` for rows carrying structural identity only, which have no id
    /// of their own). Duplicates are judged on the `identity` half, across the whole list rather than per
    /// `ForEach`.
    ///
    /// Lives beside `SpacesTabView.listIdentitySections`, the mirror of the list body it dumps, so the two
    /// are edited together. Off unless `SPACES_MOBILE_LIST_IDENTITY_DUMP=1` is set in the app's environment,
    /// and compiled out of release builds entirely.
    @MainActor enum SpacesListIdentityDump {
        static let isEnabled = ProcessInfo.processInfo.environment["SPACES_MOBILE_LIST_IDENTITY_DUMP"] == "1"

        private static var sequence = 0

        /// `sections` is an autoclosure so a disabled dump costs nothing but the flag read — the list body
        /// is re-evaluated constantly while scrolling, and this runs inside that evaluation.
        ///
        /// Two lines are emitted per evaluation. `LISTDUMP` is what the list is about to hold, recorded
        /// inside the body evaluation. `UIKITCOUNTS` is what the collection views backing the app's lists
        /// believe they hold, read one main-queue hop later so the update this evaluation produced has been
        /// applied. Comparing the two per section is the point: an inconsistent batch update is UIKit's
        /// count drifting from the list's, and the first evaluation where they disagree is the update that
        /// lost a row — not the later one that trips the exception.
        static func record(_ sections: @autoclosure () -> [[String]], state: @autoclosure () -> String) {
            guard isEnabled else { return }
            sequence += 1
            let seq = sequence
            let sections = sections()
            let identities = sections.flatMap { $0 }
            let duplicates = duplicateIdentities(in: identities)
            let counts = sections.map { String($0.count) }.joined(separator: ",")
            let line =
                "LISTDUMP seq=\(seq) t=\(String(format: "%.4f", Date().timeIntervalSince1970)) count=\(identities.count) "
                + "sections=\(sections.count) counts=\(counts) \(state()) "
                + "duplicates=\(duplicates.isEmpty ? "none" : duplicates.joined(separator: ",")) rows=\(identities.joined(separator: " "))\n"
            FileHandle.standardError.write(Data(line.utf8))
            DispatchQueue.main.async { emitCollectionViewCounts(seq: seq) }
        }

        /// Every `UICollectionView` currently in the app's key window, with the section and per-section item
        /// counts it believes it has. `numberOfSections` and `numberOfItems(inSection:)` report the cached
        /// counts from the last applied update rather than re-asking the data source, which is exactly the
        /// bookkeeping the inconsistency exception is raised against.
        ///
        /// Every list in the app is reported, not just the Spaces tab's: a `TabView` keeps a visited tab's
        /// collection view alive and updating, so which one drifts is itself a finding.
        private static func emitCollectionViewCounts(seq: Int) {
            let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
            guard let window = windows.first(where: \.isKeyWindow) ?? windows.first else { return }
            var collectionViews: [UICollectionView] = []
            func walk(_ view: UIView) {
                if let collectionView = view as? UICollectionView { collectionViews.append(collectionView) }
                for subview in view.subviews { walk(subview) }
            }
            walk(window)
            let described = collectionViews.enumerated().map { index, collectionView -> String in
                let sectionCount = collectionView.numberOfSections
                let items = (0..<sectionCount).map { String(collectionView.numberOfItems(inSection: $0)) }.joined(separator: ",")
                return "cv\(index)[sections=\(sectionCount) counts=\(items)]"
            }
            let line =
                "UIKITCOUNTS seq=\(seq) t=\(String(format: "%.4f", Date().timeIntervalSince1970)) "
                + "views=\(collectionViews.count) \(described.joined(separator: " "))\n"
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
