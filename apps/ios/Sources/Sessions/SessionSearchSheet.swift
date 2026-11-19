import SwiftUI
import spacesdevicecore

/// Search Sessions: finds a coding-agent conversation among everything a paired device's agents have stored
/// and resumes it. The device and the agent and project filters are rows that push their own lists, so a phone with many
/// devices never has to fit them in a tab strip.
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
            root.background(Theme.bg).navigationTitle("Search Sessions").navigationBarTitleDisplayMode(.inline).toolbar {
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
                filterRow(label: "Device", value: name, accessibility: "Device: \(name). Change device", id: "sessions.device", route: .devices)
                filterRow(
                    label: "Agents", value: SessionSearchRowText.agentsSummary(model.effectiveAgents),
                    accessibility: "Agents: \(SessionSearchRowText.agentsSummary(model.effectiveAgents)). Change agents", id: "sessions.agents",
                    route: .agents)
                filterRow(
                    label: "Projects", value: SessionSearchRowText.projectSummary(model.effectiveProject),
                    accessibility: "Projects: \(SessionSearchRowText.projectSummary(model.effectiveProject)). Change project",
                    id: "sessions.projects", route: .projects)
                searchField
                content
            } else {
                ContentUnavailableView("No Devices", systemImage: "desktopcomputer", description: Text("Pair a device to search its sessions."))
            }
        }
    }

    private func filterRow(label: String, value: String, accessibility: String, id: String, route: Route) -> some View {
        Button {
            path.append(route)
        } label: {
            HStack(spacing: 10) {
                Text(label).foregroundStyle(Theme.mutedSecondary)
                Text(value).fontWeight(.semibold).foregroundStyle(Theme.text).lineLimit(1).truncationMode(.tail).frame(
                    maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(Theme.mutedSecondary).accessibilityHidden(true)
            }.font(.subheadline).padding(.horizontal, 12).frame(minHeight: 44).background(
                Theme.surface2, in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            ).contentShape(Rectangle())
        }.buttonStyle(.plain).padding(.horizontal, 16).padding(.bottom, 8).accessibilityElement(children: .ignore).accessibilityLabel(accessibility)
            .accessibilityAddTraits(.isButton).accessibilityIdentifier(id)
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
            statusMessage("\(model.deviceName ?? "This device") is offline", id: "sessions.offline")
        } else {
            List {
                if let progress = model.progress, progress.isBuilding {
                    Text("Indexing \(progress.indexedSessions) of \(progress.totalSessions) sessions").font(.footnote).foregroundStyle(
                        Theme.mutedSecondary
                    ).listRowBackground(Color.clear).listRowSeparator(.hidden).accessibilityIdentifier("sessions.indexing")
                }
                if let error = model.searchError {
                    Text(error).font(.footnote).foregroundStyle(Theme.red).listRowBackground(Color.clear).listRowSeparator(.hidden)
                        .accessibilityIdentifier("sessions.error")
                }
                if model.hits.isEmpty {
                    if model.isLoading {
                        ProgressView().frame(maxWidth: .infinity).listRowBackground(Color.clear).listRowSeparator(.hidden)
                    } else if model.searchError == nil, model.progress != nil, !model.isIndexBuilding {
                        Text(model.query.trimmingCharacters(in: .whitespaces).isEmpty ? "No sessions yet." : "No sessions match.").font(.subheadline)
                            .foregroundStyle(Theme.muted).frame(maxWidth: .infinity).listRowBackground(Color.clear).listRowSeparator(.hidden)
                            .accessibilityIdentifier("sessions.empty")
                    }
                }
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

    private func statusMessage(_ text: String, id: String) -> some View {
        Text(text).font(.subheadline).foregroundStyle(Theme.muted).multilineTextAlignment(.center).padding(.horizontal, 24).frame(
            maxWidth: .infinity, maxHeight: .infinity, alignment: .center
        ).accessibilityIdentifier(id)
    }

    private func resume(_ hit: SpacesDeviceAgentSessionHit) async {
        guard let opened = await model.resume(hit) else { return }
        dismiss()
        onResumed(SelectedTerminalSessionRoute(session: opened.session, deviceID: opened.deviceID))
    }
}
