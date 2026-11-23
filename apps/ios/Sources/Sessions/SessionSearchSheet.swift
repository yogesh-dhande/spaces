import SwiftUI
import spacesdevicecore

/// Sessions: finds a coding-agent conversation among everything a paired device's agents have stored
/// and resumes it. The device, agents, and project filters are chips under the search field that push
/// their own lists, so a phone with many devices never has to fit them in a tab strip.
struct SessionSearchSheet: View {
    enum Route: Hashable {
        case devices
        case agents
        case projects
    }

    let appModel: SpacesMobileAppModel
    /// Called with the terminal a resume opened, after the sheet has asked to close.
    let onResumed: (SelectedTerminalSessionRoute) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var model: SessionSearchModel
    @State private var path: [Route] = []
    @FocusState private var searchFocused: Bool

    init(appModel: SpacesMobileAppModel, onResumed: @escaping (SelectedTerminalSessionRoute) -> Void) {
        self.appModel = appModel
        self.onResumed = onResumed
        _model = State(initialValue: appModel.makeSessionSearchModel())
    }

    var body: some View {
        NavigationStack(path: $path) {
            root.background(Theme.bg).navigationTitle("Sessions").navigationBarTitleDisplayMode(.inline).toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }.foregroundStyle(Theme.accent).frame(minHeight: 44).accessibilityIdentifier("sessions.done")
                }
            }.navigationDestination(for: Route.self) { route in
                switch route {
                case .devices: SessionSearchDeviceList(model: model, appModel: appModel, onPicked: { path.removeAll() })
                case .agents: SessionSearchAgentList(model: model)
                case .projects: SessionSearchProjectList(model: model, onPicked: { path.removeAll() })
                }
            }
        }.presentationDetents([.large]).presentationDragIndicator(.visible).presentationBackground(Theme.bg).tint(Theme.accent)
            .accessibilityIdentifier("sessions.sheet").task {
                searchFocused = true
                await model.reload()
            }.task(id: model.needsPolling) {
                // Runs while the sheet is up and the device reports indexing; the task ends with the sheet.
                guard model.needsPolling else { return }
                while !Task.isCancelled {
                    try? await Task.sleep(for: SessionSearchModel.pollInterval)
                    guard !Task.isCancelled else { return }
                    await model.poll()
                }
            }.onChange(of: model.query) { model.queryChanged() }.onChange(of: appModel.offlineDeviceIDs) {
                model.refreshDevices()
                Task { await model.reload() }
            }.onChange(of: appModel.pairedDevices) { model.refreshDevices() }
    }

    private var root: some View {
        VStack(spacing: 0) {
            if let name = model.deviceName {
                searchField
                filterChips(deviceName: name)
                if !model.isDeviceOffline { statusLine }
                content
            } else {
                ContentUnavailableView("No Devices", systemImage: "desktopcomputer", description: Text("Pair a device to search its sessions."))
            }
        }
    }

    /// Device, agents, and project as one scrollable row of chips. Each shows the current choice and
    /// opens its picker.
    private func filterChips(deviceName: String) -> some View {
        let agents = SessionSearchRowText.agentsSummary(model.effectiveAgents)
        let project = SessionSearchRowText.projectSummary(model.effectiveProject)
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                filterChip(
                    value: deviceName, symbol: "desktopcomputer", accessibility: "Device: \(deviceName). Change device", id: "sessions.device",
                    route: .devices)
                filterChip(
                    value: agents, symbol: "cpu", accessibility: "Agents: \(agents). Change agents", id: "sessions.agents", route: .agents)
                filterChip(
                    value: project, symbol: "folder", accessibility: "Projects: \(project). Change project", id: "sessions.projects",
                    route: .projects)
            }.padding(.horizontal, 16)
        }.padding(.bottom, 6)
    }

    private func filterChip(value: String, symbol: String, accessibility: String, id: String, route: Route) -> some View {
        Button {
            path.append(route)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: symbol).accessibilityHidden(true)
                Text(value).lineLimit(1)
                Image(systemName: "chevron.down").font(.caption2.weight(.semibold)).accessibilityHidden(true)
            }.font(.footnote.weight(.medium)).foregroundStyle(Theme.text).padding(.horizontal, 10).frame(minHeight: 32).background(
                Theme.surface2, in: Capsule()
            ).contentShape(Capsule())
        }.buttonStyle(.plain).accessibilityElement(children: .ignore).accessibilityLabel(accessibility).accessibilityAddTraits(.isButton)
            .accessibilityIdentifier(id)
    }

    /// The count of loaded sessions, with the device's indexing progress while it builds and any search
    /// error.
    private var statusLine: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let progress = model.progress, progress.isBuilding {
                Text("Indexing \(progress.indexedSessions) of \(progress.totalSessions) sessions").accessibilityIdentifier("sessions.indexing")
            }
            if !model.hits.isEmpty {
                Text(SessionSearchRowText.countSummary(loaded: model.hits.count, hasMore: model.results.hasMore)).accessibilityIdentifier(
                    "sessions.count")
            }
            if let error = model.searchError {
                Text(error).foregroundStyle(Theme.red).accessibilityIdentifier("sessions.error")
            }
        }.font(.footnote).foregroundStyle(Theme.mutedSecondary).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16)
            .padding(.bottom, 4)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.subheadline.weight(.medium)).foregroundStyle(Theme.mutedSecondary).accessibilityHidden(true)
            TextField("Search sessions", text: $model.query).font(.body).textInputAutocapitalization(.never).autocorrectionDisabled().submitLabel(
                .search
            ).focused($searchFocused).accessibilityIdentifier("sessions.search")
            if !model.query.isEmpty {
                Button {
                    model.query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.mutedSecondary).frame(minWidth: 44, minHeight: 44)
                }.accessibilityLabel("Clear search")
            }
        }.padding(.leading, 12).frame(minHeight: 44).background(Theme.surface2, in: RoundedRectangle(cornerRadius: 10, style: .continuous)).padding(
            .horizontal, 16
        ).padding(.bottom, 8)
    }

    @ViewBuilder private var content: some View {
        if model.isDeviceOffline {
            ContentUnavailableView("\(model.deviceName ?? "This device") is offline", systemImage: "wifi.slash").accessibilityIdentifier(
                "sessions.offline")
        } else if model.hits.isEmpty, !model.results.hasMore {
            // A page can come back empty yet have more after it (the server drops hits that resume in another
            // project), so the list with its Show more stands in for the empty state then.
            if model.isLoading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.searchError == nil, model.progress != nil, !model.isIndexBuilding {
                ContentUnavailableView(
                    model.query.trimmingCharacters(in: .whitespaces).isEmpty ? "No sessions yet." : "No sessions match.",
                    systemImage: "magnifyingglass"
                ).accessibilityIdentifier("sessions.empty")
            } else {
                Spacer(minLength: 0)
            }
        } else {
            List {
                ForEach(model.hits, id: \.listID) { hit in
                    SessionSearchRow(
                        hit: hit, query: model.query, now: appModel.relativeTimeReference,
                        failure: model.resumeFailure?.hitID == hit.listID ? model.resumeFailure?.message : nil
                    ) { Task { await resume(hit) } }.listRowBackground(Color.clear).listRowInsets(
                        EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                }
                if model.results.hasMore {
                    Button {
                        Task { await model.showMore() }
                    } label: {
                        HStack {
                            if model.isLoadingMore { ProgressView() }
                            Text("Show more").foregroundStyle(Theme.accent)
                        }.frame(maxWidth: .infinity, minHeight: 44)
                    }.disabled(model.isLoadingMore).listRowBackground(Color.clear).accessibilityIdentifier("sessions.showMore")
                }
            }.listStyle(.plain).scrollContentBackground(.hidden)
        }
    }

    private func resume(_ hit: SpacesDeviceAgentSessionHit) async {
        guard let opened = await model.resume(hit) else { return }
        dismiss()
        onResumed(SelectedTerminalSessionRoute(session: opened.session, deviceID: opened.deviceID))
    }
}
