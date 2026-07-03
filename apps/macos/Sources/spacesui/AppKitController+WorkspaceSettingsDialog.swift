import AppKit
import spacesclientcore
import spacesdevicecore
import workspacecore

/// Free-standing workspace settings dialog, presented from the gear button on the
/// workspace's sidebar row (mirroring the project settings window). It owns workspace
/// configuration editing only — processes, coding agents, browser sessions, ports, and
/// the stop script. Runtime controls (start/stop/restart/focus) live on the sidebar's
/// runtime-target rows, not here, so the sections render without runtime chrome and
/// every edit commits immediately through the owning device's config update (the same
/// auto-save behavior the sections had in the old inline workspace detail).
extension AppKitController {
    @objc func showWorkspaceSettings(_ sender: NSButton) {
        guard let workspaceID = sender.identifier?.rawValue, let (project, workspace) = findWorkspace(id: workspaceID) else { return }
        showWorkspaceSettingsDialog(project: project, workspace: workspace)
    }

    func showWorkspaceSettingsDialog(project: ProjectSummary, workspace: WorkspaceSummary) {
        guard let summary = deviceWorkspaceSummary(workspaceID: workspace.id) else {
            showDeviceNotLoadedError()
            return
        }
        let detail = SpacesDeviceWorkspaceDetailViewModel(workspace: summary)
        let config = Self.localWorkspaceSettings(from: detail.config)

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false

        // --- Directory subtitle (the workspace name is shown in the dialog header) ---
        let dirField = NSTextField(string: workspace.dir)
        dirField.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        dirField.textColor = .tertiaryLabelColor
        dirField.lineBreakMode = .byTruncatingMiddle
        dirField.isEditable = false
        dirField.isSelectable = true
        dirField.drawsBackground = false
        dirField.isBordered = false
        dirField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        dirField.setAccessibilityIdentifier("workspace-settings-dir")
        stack.addArrangedSubview(dirField)
        constrainFormFieldToFillWidth(dirField, in: stack)

        // --- Config sections, committing immediately like the sections always have for workspaces ---
        let workspaceID = workspace.id
        func commit(_ update: @escaping (inout WorkspaceSettings) -> Void) {
            // Route by this dialog's workspace, not the sidebar selection: the dialog is
            // free-standing, so the selection may have moved to another device or
            // workspace by the time an auto-save fires.
            do {
                if deviceForWorkspaceMutation(workspaceID: workspaceID) != nil {
                    try updateDeviceWorkspaceConfig(workspaceID: workspaceID, update: update)
                } else {
                    showDeviceNotLoadedError()
                }
            } catch { showError(error) }
        }

        let browserSessionsSection = BrowserSessionsSection(
            sessions: config.browserSessions,
            collapsedDisplayURLs: Self.browserSessionDisplayURLs(
                configuredSessions: config.browserSessions,
                resolvedSessions: detail.config.resolvedBrowserSessions.map(Self.localBrowserSession(from:))),
            subtitle: "Named URLs that open in Chrome when you focus them.")
        browserSessionsSection.onCommit = { updated in commit { $0.browserSessions = updated } }

        let processesSection = ProcessesSection(
            processes: config.processes, subtitle: "Commands that run inside the workspace.", showsRuntimeControls: false)
        processesSection.validateProcess = { process in try Self.validateProcessTemplate(process) }
        processesSection.presentValidationError = { [weak self] error in self?.showError(error) }
        processesSection.onCommit = { updated in commit { $0.processes = updated } }

        let agentLaunchersSection = AgentLaunchersSection(
            launchers: config.agentLaunchers, subtitle: "Coding agents that open in a Spaces terminal.", showsRuntimeControls: false)
        agentLaunchersSection.onCommit = { updated in commit { $0.agentLaunchers = updated } }

        let portsSection = PortsSection(
            ports: config.ports, collapsedDisplayPorts: detail.assignedPorts.map { Optional.some($0.port) },
            collapsedDisplayURLs: detail.assignedPorts.map { $0.url.isEmpty ? nil : $0.url },
            subtitle: "Per-workspace named ports, exposed as env vars.")
        portsSection.onCommit = { updated in commit { $0.ports = updated } }

        let stopScriptSection = ScriptSection(
            title: "Stop Script", editAccessibilityIdentifier: "stop-script-edit", formAccessibilityPrefix: "workspace-stop-script",
            value: config.stopScript ?? "", subtitle: "Runs after processes stop — on stop, restart, and archive.")
        stopScriptSection.onCommit = { value in commit { $0.stopScript = value.isEmpty ? nil : value } }

        for section in [browserSessionsSection.view, processesSection.view, agentLaunchersSection.view, portsSection.view, stopScriptSection.view] {
            stack.addArrangedSubview(section)
            constrainFormFieldToFillWidth(section, in: stack)
        }

        workspaceSettingsWorkspaceID = workspace.id
        let title = project.isGitRepo ? "\(project.name) / \(workspace.displayName)" : workspace.displayName
        let header = buildFormWindowHeader(symbol: "gearshape", title: title, closeAction: #selector(closeWorkspaceSettingsWindow))
        workspaceSettingsWindow = presentFormWindow(existing: workspaceSettingsWindow, header: header, hosting: stack)
    }

    @objc private func closeWorkspaceSettingsWindow() { workspaceSettingsWindow?.performClose(nil) }
}
