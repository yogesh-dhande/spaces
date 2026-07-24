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

/// Owns the Workspaces visibility dialog: a filterable table for showing/hiding
/// workspaces in the sidebar. `AppKitController` holds a single instance and
/// delegates the dialog to it. The controller reaches back into the host for
/// project/device model state and shared device-mutation services via `host`.
@MainActor final class WorkspaceVisibilityController: NSObject {
    unowned let host: AppKitController

    init(host: AppKitController) {
        self.host = host
        super.init()
    }

    private var workspaceVisibilityWindow: NSWindow?
    private let workspaceVisibilityTable = WorkspaceVisibilityTableController()
    private weak var workspaceVisibilityTableView: NSTableView?
    private var workspaceVisibilityQuery = ""
    private var workspaceVisibilityDeviceFilter: String?

    func showWorkspaceVisibilityDialog() {
        host.clearActiveAddFormStateAndCloseWindows()
        workspaceVisibilityQuery = ""
        workspaceVisibilityDeviceFilter = nil

        let searchField = NSSearchField()
        searchField.placeholderString = "Search workspaces"
        searchField.target = self
        searchField.action = #selector(workspaceVisibilitySearchChanged(_:))
        searchField.sendsWholeSearchString = false
        searchField.sendsSearchStringImmediately = false
        searchField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        searchField.setAccessibilityIdentifier("workspace-visibility-search")

        let devicePopUp = NSPopUpButton()
        devicePopUp.target = self
        devicePopUp.action = #selector(workspaceVisibilityDeviceFilterChanged(_:))
        devicePopUp.setContentHuggingPriority(.required, for: .horizontal)
        populateWorkspaceVisibilityDevicePopUp(devicePopUp)

        let filterRow = NSStackView(views: [searchField, devicePopUp])
        filterRow.orientation = .horizontal
        filterRow.spacing = 8
        filterRow.distribution = .fill

        let tableView = NSTableView()
        tableView.dataSource = workspaceVisibilityTable
        tableView.delegate = workspaceVisibilityTable
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.rowHeight = 24
        tableView.allowsColumnSelection = false
        tableView.headerView = NSTableHeaderView()
        addWorkspaceVisibilityColumn(tableView, id: WorkspaceVisibilityTableController.visibleColumn, title: "Show", width: 44, fixed: true)
        addWorkspaceVisibilityColumn(tableView, id: WorkspaceVisibilityTableController.titleColumn, title: "Workspace", width: 180)
        addWorkspaceVisibilityColumn(tableView, id: WorkspaceVisibilityTableController.projectColumn, title: "Project", width: 150)
        addWorkspaceVisibilityColumn(tableView, id: WorkspaceVisibilityTableController.deviceColumn, title: "Device", width: 130)
        addWorkspaceVisibilityColumn(tableView, id: WorkspaceVisibilityTableController.branchColumn, title: "Branch", width: 130)
        workspaceVisibilityTableView = tableView
        workspaceVisibilityTable.onToggleVisible = { [weak self] workspaceID, visible in
            self?.setWorkspaceHidden(workspaceID: workspaceID, isHidden: !visible) { [weak self] _ in self?.reloadWorkspaceVisibilityRows() }
        }

        let scroll = NSScrollView()
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder

        reloadWorkspaceVisibilityRows()
        presentWorkspaceVisibilityWindow(filterRow: filterRow, tableScroll: scroll)
    }

    private func addWorkspaceVisibilityColumn(
        _ tableView: NSTableView, id: NSUserInterfaceItemIdentifier, title: String, width: CGFloat, fixed: Bool = false
    ) {
        let column = NSTableColumn(identifier: id)
        column.title = title
        column.width = width
        column.minWidth = fixed ? width : 60
        if fixed { column.maxWidth = width }
        tableView.addTableColumn(column)
    }

    private func populateWorkspaceVisibilityDevicePopUp(_ popup: NSPopUpButton) {
        popup.removeAllItems()
        popup.addItem(withTitle: "All devices")
        for section in host.deviceSections {
            popup.addItem(withTitle: section.deviceName)
            popup.lastItem?.representedObject = section.deviceID
        }
        if let filter = workspaceVisibilityDeviceFilter, let item = popup.itemArray.first(where: { ($0.representedObject as? String) == filter }) {
            popup.select(item)
        } else {
            popup.selectItem(at: 0)
        }
    }

    @objc private func workspaceVisibilitySearchChanged(_ sender: NSSearchField) {
        workspaceVisibilityQuery = sender.stringValue
        reloadWorkspaceVisibilityRows()
    }

    @objc private func workspaceVisibilityDeviceFilterChanged(_ sender: NSPopUpButton) {
        workspaceVisibilityDeviceFilter = sender.selectedItem?.representedObject as? String
        reloadWorkspaceVisibilityRows()
    }

    private func buildWorkspaceVisibilityRows() -> [WorkspaceVisibilityRow] {
        var rows: [WorkspaceVisibilityRow] = []
        for project in host.projects {
            let deviceName = host.deviceSection(id: project.deviceID)?.deviceName ?? project.deviceID
            for workspace in host.workspacesByProject[project.id] ?? [] where !workspace.isArchived {
                rows.append(
                    WorkspaceVisibilityRow(
                        workspaceID: workspace.id, deviceID: project.deviceID, title: workspace.displayName, projectName: project.name,
                        deviceName: deviceName, branch: workspace.branch ?? "", isHidden: workspace.isHidden))
            }
        }
        return rows
    }

    private func reloadWorkspaceVisibilityRows() {
        let deviceFiltered =
            workspaceVisibilityDeviceFilter.map { id in buildWorkspaceVisibilityRows().filter { $0.deviceID == id } }
            ?? buildWorkspaceVisibilityRows()
        let candidates = deviceFiltered.enumerated().map { offset, row in
            CommandPaletteFuzzySearch.Candidate(
                id: offset,
                fields: [
                    .init(text: row.title, weight: 1.0), .init(text: row.projectName, weight: 0.6), .init(text: row.deviceName, weight: 0.4),
                    .init(text: row.branch, weight: 0.5),
                ])
        }
        let ranked = CommandPaletteFuzzySearch.rank(query: workspaceVisibilityQuery, candidates: candidates)
        workspaceVisibilityTable.rows = ranked.map { deviceFiltered[$0.id] }
        workspaceVisibilityTableView?.reloadData()
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
            // wrong daemon would either reject it or hide a same-id row it does not own.
            guard let device = host.deviceRecord(forDeviceID: project.deviceID) else {
                host.showDeviceNotLoadedError()
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
}
