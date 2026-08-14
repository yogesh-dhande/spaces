import AppKit
import Carbon
import CoreImage
import Foundation
import spacesclientcore
import spacesdeviceapi
import spacesdevicecore
import spacesterminalcore
import spacesterminalghostty
import spacesterminalui
import systembridge
import workspacecore

/// Owns the Workspaces visibility dialog: a searchable device -> project -> workspace outline for
/// showing/hiding rows in the sidebar. `AppKitController` holds a single instance and delegates the
/// dialog to it. The controller reaches back into the host for project/device model state and shared
/// device-mutation services via `host`.
@MainActor final class WorkspaceVisibilityController: NSObject {
    unowned let host: AppKitController

    init(host: AppKitController) {
        self.host = host
        super.init()
    }

    private var workspaceVisibilityWindow: NSWindow?
    private let workspaceVisibilityOutline = WorkspaceVisibilityOutlineController()
    private weak var workspaceVisibilityOutlineView: NSOutlineView?
    private var workspaceVisibilityQuery = ""

    func showWorkspaceVisibilityDialog() {
        host.clearActiveAddFormStateAndCloseWindows()
        workspaceVisibilityQuery = ""

        let searchField = NSSearchField()
        searchField.placeholderString = "Search projects and workspaces"
        searchField.target = self
        searchField.action = #selector(workspaceVisibilitySearchChanged(_:))
        searchField.sendsWholeSearchString = false
        searchField.sendsSearchStringImmediately = false
        searchField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        searchField.setAccessibilityIdentifier("workspace-visibility-search")

        let filterRow = NSStackView(views: [searchField])
        filterRow.orientation = .horizontal
        filterRow.spacing = 8
        filterRow.distribution = .fill

        let outlineView = NSOutlineView()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("visibility"))
        column.resizingMask = .autoresizingMask
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        outlineView.indentationPerLevel = 14
        outlineView.selectionHighlightStyle = .none
        outlineView.floatsGroupRows = false
        outlineView.dataSource = workspaceVisibilityOutline
        outlineView.delegate = workspaceVisibilityOutline
        workspaceVisibilityOutlineView = outlineView
        workspaceVisibilityOutline.onToggleWorkspaceVisible = { [weak self] workspaceID, visible in
            self?.setWorkspaceHidden(workspaceID: workspaceID, isHidden: !visible) { [weak self] _ in self?.reloadWorkspaceVisibilityRows() }
        }
        workspaceVisibilityOutline.onToggleProjectVisible = { [weak self] projectID, visible in
            self?.setProjectHidden(projectID: projectID, isHidden: !visible) { [weak self] _ in self?.reloadWorkspaceVisibilityRows() }
        }

        let scroll = NSScrollView()
        scroll.documentView = outlineView
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder

        reloadWorkspaceVisibilityRows()
        presentWorkspaceVisibilityWindow(filterRow: filterRow, tableScroll: scroll)
    }

    @objc private func workspaceVisibilitySearchChanged(_ sender: NSSearchField) {
        workspaceVisibilityQuery = sender.stringValue
        reloadWorkspaceVisibilityRows()
    }

    private func reloadWorkspaceVisibilityRows() {
        workspaceVisibilityOutline.devices = WorkspaceVisibilityTree.build(
            devices: host.deviceSections.map { .init(deviceID: $0.deviceID, name: $0.displayName) }, projects: host.projects,
            workspacesByProject: host.workspacesByProject, query: workspaceVisibilityQuery)
        guard let outlineView = workspaceVisibilityOutlineView else { return }
        outlineView.reloadData()
        workspaceVisibilityOutline.expandAll(outlineView)
    }

    private func presentWorkspaceVisibilityWindow(filterRow: NSView, tableScroll: NSView) {
        let header = host.buildFormWindowHeader(
            symbol: "line.3.horizontal.decrease.circle", title: "Workspaces", closeAction: #selector(AppKitController.closeWorkspaceVisibilityWindow))
        let root = NSView()
        root.wantsLayer = true
        bindAppearanceReactiveLayer(root) { [unowned host] view in view.layer?.backgroundColor = host.sidebarPanelBackgroundColor().cgColor }
        let headerDivider = host.settingsHairlineDivider()
        for view in [header, headerDivider, filterRow, tableScroll] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor), header.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            header.topAnchor.constraint(equalTo: root.topAnchor), header.heightAnchor.constraint(equalToConstant: 52),
            headerDivider.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            headerDivider.trailingAnchor.constraint(equalTo: root.trailingAnchor), headerDivider.topAnchor.constraint(equalTo: header.bottomAnchor),
            headerDivider.heightAnchor.constraint(equalToConstant: 1), filterRow.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            filterRow.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            filterRow.topAnchor.constraint(equalTo: headerDivider.bottomAnchor, constant: 12),
            tableScroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            tableScroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            tableScroll.topAnchor.constraint(equalTo: filterRow.bottomAnchor, constant: 10),
            tableScroll.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
        ])
        let window: NSWindow
        if let existing = workspaceVisibilityWindow {
            window = existing
        } else {
            let created = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 720, height: 560), styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                backing: .buffered, defer: false)
            created.titlebarAppearsTransparent = true
            created.titleVisibility = .hidden
            created.isMovableByWindowBackground = true
            created.isReleasedWhenClosed = false
            created.minSize = NSSize(width: 560, height: 360)
            created.standardWindowButton(.miniaturizeButton)?.isHidden = true
            created.standardWindowButton(.zoomButton)?.isHidden = true
            created.standardWindowButton(.closeButton)?.isHidden = true
            created.center()
            workspaceVisibilityWindow = created
            window = created
        }
        window.contentView = root
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func closeWorkspaceVisibilityWindow() { workspaceVisibilityWindow?.performClose(nil) }

    /// Hides a workspace from the sidebar without the visibility dialog open — used by the sidebar
    /// workspace row's right-click menu. Reuses `setWorkspaceHidden` (stop-if-running prompt included);
    /// the sidebar refreshes from the mutation response, so the completion is a no-op.
    func hideWorkspace(workspaceID: String) { setWorkspaceHidden(workspaceID: workspaceID, isHidden: true) { _ in } }

    /// Sets a workspace's sidebar visibility (persisted as `isHidden`), routing to
    /// the device that owns the workspace and stopping it first if it is running.
    private func setWorkspaceHidden(workspaceID: String, isHidden: Bool, completion: @escaping (Bool) -> Void) {
        guard let (project, workspace) = host.findWorkspace(id: workspaceID) else { return completion(false) }
        Task { @MainActor [weak self] in
            guard let self else { return completion(false) }
            // Route by the owning project's device: hide/unhide is a daemon mutation, and the
            // wrong daemon would either reject it or hide a same-id row it does not own. It also
            // goes through the mutation chokepoint, so an unreachable device refuses it up front
            // instead of stopping the workspace against a daemon that is not there.
            guard let device = host.deviceForWorkspaceMutation(workspaceID: workspaceID) else {
                host.showWorkspaceDeviceUnavailableError(workspaceID: workspaceID)
                return completion(false)
            }
            // Decide the "Stop and Hide" prompt and the stop from fresh daemon state,
            // not a possibly-stale cached snapshot (remote overviews refresh on a
            // throttled cadence), so a running workspace is never hidden without being
            // stopped, nor a stopped one prompted about needlessly.
            var isRunning = workspace.isRunning
            if isHidden {
                let clientApp = SpacesDeviceClient.macOSClientApp(appVersion: AppVersion.short)
                let overviewResult: Result<SpacesDeviceOverview, Error> = await Task.detached(priority: .userInitiated) {
                    do { return .success(try SpacesDeviceClient.overview(device: device, clientApp: clientApp)) } catch { return .failure(error) }
                }.value
                switch overviewResult {
                case .success(let overview): isRunning = overview.overview.workspaces.first(where: { $0.id == workspaceID })?.isRunning ?? false
                case .failure(let error):
                    host.showError(error)
                    return completion(false)
                }
            }
            if isHidden, isRunning {
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "Hide workspace?"
                alert.informativeText = "\"\(workspace.displayName)\" is currently running. Hiding it stops the workspace first."
                alert.addButton(withTitle: "Stop and Hide")
                alert.addButton(withTitle: "Cancel")
                guard alert.runModal() == .alertFirstButtonReturn else { return completion(false) }
                let stopResult = await AppKitController.deviceMutation(device: device) { device in
                    try SpacesDeviceClient.stopWorkspace(
                        workspaceID: workspaceID, device: device, clientApp: SpacesDeviceClient.macOSClientApp(appVersion: AppVersion.short))
                }
                if case .failure(let error) = stopResult {
                    host.showError(error)
                    return completion(false)
                }
            }
            let result = await AppKitController.deviceMutation(device: device) { device in
                try SpacesDeviceClient.updateWorkspaceMetadata(
                    workspaceID: workspaceID, isHidden: isHidden, updatesHidden: true, device: device,
                    clientApp: SpacesDeviceClient.macOSClientApp(appVersion: AppVersion.short))
            }
            switch result {
            case .success(let response):
                if isHidden, host.selectedWorkspaceID == workspaceID { host.selectedWorkspaceID = nil }
                host.applyDeviceMutationResponse(
                    response, deviceID: device.id, selectedProjectID: project.id, selectedWorkspaceID: isHidden ? nil : workspaceID)
                completion(true)
            case .failure(let error):
                host.showError(error)
                completion(false)
            }
        }
    }

    /// Sets a project's sidebar visibility (persisted as the project's own `isHidden`), routing to the
    /// device that owns the project and stopping its running workspaces first.
    ///
    /// The project flag is independent of each workspace's, so this never writes a child's flag:
    /// unhiding the project brings back exactly the workspaces that were shown before it was hidden.
    private func setProjectHidden(projectID: String, isHidden: Bool, completion: @escaping (Bool) -> Void) {
        guard host.projects.contains(where: { $0.id == projectID }) else { return completion(false) }
        Task { @MainActor [weak self] in
            guard let self else { return completion(false) }
            // Same routing and gating rule as a workspace hide: the owning project's device, resolved
            // through the mutation chokepoint so an unreachable device refuses up front rather than
            // stopping workspaces against a daemon that is not there.
            guard let device = host.deviceForProjectMutation(projectID: projectID) else {
                host.showProjectDeviceUnavailableError(projectID: projectID)
                return completion(false)
            }
            let clientApp = SpacesDeviceClient.macOSClientApp(appVersion: AppVersion.short)
            if isHidden {
                // Decide the prompt and the stops from fresh daemon state rather than a possibly-stale
                // cached snapshot, for the same reason as `setWorkspaceHidden`.
                let overviewResult: Result<SpacesDeviceOverview, Error> = await Task.detached(priority: .userInitiated) {
                    do { return .success(try SpacesDeviceClient.overview(device: device, clientApp: clientApp)) } catch { return .failure(error) }
                }.value
                let running: [SpacesDeviceWorkspaceSummary]
                switch overviewResult {
                case .success(let overview): running = overview.overview.workspaces.filter { $0.projectID == projectID && $0.isRunning }
                case .failure(let error):
                    host.showError(error)
                    return completion(false)
                }
                if !running.isEmpty {
                    // One prompt for the whole project, naming every workspace the hide will stop, so the
                    // user confirms the full cost once instead of once per workspace.
                    let alert = NSAlert()
                    alert.alertStyle = .warning
                    alert.messageText = "Hide project?"
                    alert.informativeText =
                        "Hiding this project stops its running workspaces first: \(running.map(\.displayName).joined(separator: ", "))."
                    alert.addButton(withTitle: "Stop and Hide")
                    alert.addButton(withTitle: "Cancel")
                    guard alert.runModal() == .alertFirstButtonReturn else { return completion(false) }
                    for workspace in running {
                        let stopResult = await AppKitController.deviceMutation(device: device) { device in
                            try SpacesDeviceClient.stopWorkspace(workspaceID: workspace.id, device: device, clientApp: clientApp)
                        }
                        // A workspace that would not stop is left running and visible: hiding the project
                        // now would strand it out of view still running.
                        if case .failure(let error) = stopResult {
                            host.showError(error)
                            return completion(false)
                        }
                    }
                }
            }
            let result = await AppKitController.deviceMutation(device: device) { device in
                try SpacesDeviceClient.updateProjectMetadata(projectID: projectID, isHidden: isHidden, device: device, clientApp: clientApp)
            }
            switch result {
            case .success(let response):
                // A hidden project leaves the sidebar with every row under it, so a selection inside it
                // is dropped before the rebuild — `findWorkspace` still resolves hidden rows, so leaving
                // it set would keep a detail pane open for a workspace that has no row.
                if isHidden, let selectedWorkspaceID = host.selectedWorkspaceID, host.findWorkspace(id: selectedWorkspaceID)?.0.id == projectID {
                    host.selectedWorkspaceID = nil
                }
                if isHidden, host.selectedProjectID == projectID { host.selectedProjectID = nil }
                host.applyDeviceMutationResponse(response, deviceID: device.id, selectedProjectID: isHidden ? nil : projectID)
                completion(true)
            case .failure(let error):
                host.showError(error)
                completion(false)
            }
        }
    }
}
