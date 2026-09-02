import AppKit
import Carbon
import Foundation
import spacesclientcore
import spacesdevicecore
import spacesterminalcore
import workspacecore

/// Field-reference bundles for a single-instance form. `formTag` is the generation stamped on the
/// form's controls (`NSControl.tag`) when it is built, letting a control's action confirm it still
/// belongs to the live form. See `ProjectFormsController.liveFormRefs(_:forSenderTag:)`.
protocol FormGenerationTagged { var formTag: Int { get } }

/// Owns the add-project, add-workspace, and project-settings form windows: their single-instance
/// window/field-reference state, the unsaved-changes and generation-tag bookkeeping that guards a
/// stale control's action, the multi-step add-project flow (device → source → loading → config), the
/// add-workspace branch-mode UI, and the Device API calls each form's Save/Create/Import/Export/Delete
/// buttons send. Extracted from `AppKitController` as a behavior-preserving move (part of the ongoing
/// decomposition of that type); `AppKitController` holds this as `projectForms` and reaches it as
/// `host.projectForms` from other files (`ShortcutsController`, `SidebarController`,
/// `WorkspaceVisibilityController`, `AutomationsController`) that need to know whether a form is open
/// or must close one before presenting something else. `AppKitController` stays the host for device
/// resolution, sidebar/overview state, error presentation, and the workspace-settings/automation-editor
/// windows, which this controller reaches through `host.`.
@MainActor final class ProjectFormsController: NSObject {
    unowned let host: AppKitController

    init(host: AppKitController) {
        self.host = host
        super.init()
    }

    // MARK: - Form window / field-reference state

    private var addProjectWindow: NSWindow?
    private var addWorkspaceWindow: NSWindow?
    private var projectSettingsWindow: NSWindow?
    var projectSettingsProjectID: String?
    // Each of these dialogs is single-instance (one optional window above), so at most one live set of
    // field references exists at a time. Its controls are stamped with the form's generation tag; see
    // `liveFormRefs(_:forSenderTag:)` for how a stale control's action is rejected.
    private var projectSettingsFieldRefs: ProjectFieldRefs?
    private var addProjectFieldRefs: AddProjectFieldRefs?
    private var addWorkspaceFieldRefs: AddWorkspaceFieldRefs?
    private var pathCompletionFieldEditor: PathCompletionTextView?

    // Clearing any reload blocker (unsaved project settings, an open add form) can
    // happen from several paths; flushing here covers them all so a deferred
    // database/worktree reload is never stranded once the user is idle again.
    var projectHasUnsavedChanges = false { didSet { if oldValue, !projectHasUnsavedChanges { host.flushDeferredSidebarReloadsIfNeeded() } } }
    var activeAddWorkspaceFormTag: Int? { didSet { if oldValue != nil, activeAddWorkspaceFormTag == nil { host.flushDeferredSidebarReloadsIfNeeded() } } }
    var activeAddProjectFormTag: Int? { didSet { if oldValue != nil, activeAddProjectFormTag == nil { host.flushDeferredSidebarReloadsIfNeeded() } } }

    private enum AddWorkspaceBranchMode: String {
        case existing
        case create
    }

    private struct WorkspaceCreateInput: Sendable {
        let projectID: String
        let branch: String?
        let baseBranch: String?
        let notes: String?
        let allowRemoteBranchLookup: Bool
        let allowExistingBranchReuse: Bool
        let replaceExistingManagedDirectory: Bool
    }

    // MARK: - Delegate fan-outs (conformance stays on AppKitController)

    /// The three form-window branches of `AppKitController.windowWillClose(_:)`. Returns true when the
    /// closing window belonged to one of these forms (handled), so the host stops there; otherwise the
    /// host continues to its own workspace-settings/settings-window branches.
    func handleWindowWillClose(_ closingWindow: NSWindow?) -> Bool {
        if closingWindow === addProjectWindow {
            clearActiveAddProjectFormState()
            return true
        }
        if closingWindow === addWorkspaceWindow {
            clearActiveAddWorkspaceFormState()
            return true
        }
        if closingWindow === projectSettingsWindow {
            projectSettingsFieldRefs = nil
            projectSettingsProjectID = nil
            projectHasUnsavedChanges = false
            return true
        }
        return false
    }

    /// Logic for `AppKitController.windowWillReturnFieldEditor(_:to:)`: only the add-project window's
    /// directory field wants path-completion behavior.
    func fieldEditor(for window: NSWindow, client: Any?) -> Any? {
        guard window === addProjectWindow, let field = client as? NSTextField, addProjectRefs(forDirectoryField: field) != nil else { return nil }
        let editor = pathCompletionFieldEditor ?? PathCompletionTextView()
        editor.isFieldEditor = true
        pathCompletionFieldEditor = editor
        return editor
    }

    /// The form branches of `AppKitController.controlTextDidChange(_:)`, checked after the command
    /// palette branch. Returns true when `changedField` belonged to one of these forms (handled).
    func handleControlTextDidChange(_ changedField: NSTextField) -> Bool {
        if let refs = addProjectFieldRefs, refs.repoURLField === changedField {
            updateAddProjectSourceStepUI(refs)
            return true
        }
        if let refs = addProjectRefs(forDirectoryField: changedField) {
            updateAddProjectSourceStepUI(refs)
            scheduleAddProjectDirectorySuggestions(refs)
            return true
        }
        if let refs = addWorkspaceFieldRefs, refs.existingBranchField === changedField || refs.newBranchField === changedField {
            if let existingBranchField = refs.existingBranchField, existingBranchField === changedField {
                Self.syncExistingWorkspaceBranchSelection(existingBranchField: existingBranchField)
            }
            handleAddWorkspaceBranchFieldChange(refs: refs)
            return true
        }
        return false
    }

    /// Logic for `AppKitController.control(_:textView:completions:forPartialWordRange:indexOfSelectedItem:)`:
    /// only the add-project directory field offers path completions.
    func directoryPathCompletions(for control: NSControl, words: [String], indexOfSelectedItem index: UnsafeMutablePointer<Int>) -> [String] {
        guard let refs = addProjectRefs(forDirectoryField: control) else { return words }
        index.pointee = -1
        return refs.directoryCompletions
    }

    /// Logic for `AppKitController.comboBoxSelectionDidChange(_:)`: only the add-workspace existing-branch
    /// combo box is form-owned state.
    func handleComboBoxSelectionDidChange(_ comboBox: NSComboBox) {
        guard let refs = addWorkspaceFieldRefs, refs.existingBranchField === comboBox else { return }
        let selectedBranchValue = (comboBox.objectValueOfSelectedItem as? String) ?? comboBox.stringValue
        comboBox.stringValue = selectedBranchValue
        handleAddWorkspaceBranchFieldChange(refs: refs, branchValueOverride: selectedBranchValue)
    }

    /// `Escape` cancels whichever add-project/add-workspace form is open. Called by
    /// `ShortcutsController`'s shortcut monitor from a different file in the same module.
    func handleFormCancelShortcut(event: NSEvent) -> Bool {
        guard event.keyCode == UInt16(kVK_Escape) else { return false }
        if addWorkspaceWindow?.isVisible == true {
            closeAddWorkspaceWindow()
            return true
        }
        if addProjectWindow?.isVisible == true {
            closeAddProjectWindow()
            return true
        }
        return false
    }

    // MARK: - @objc target forwarders (host keeps thin selector-target versions of these)

    func showProjectSettings(_ sender: NSButton) {
        guard let projectID = sender.identifier?.rawValue, let project = host.deviceModel.projects.first(where: { $0.id == projectID }) else {
            return
        }
        showProjectSettingsDialog(project: project)
    }

    func addWorkspace(_ sender: NSButton) {
        guard let projectID = sender.identifier?.rawValue, let project = host.deviceModel.projects.first(where: { $0.id == projectID }) else {
            return
        }
        showAddWorkspaceForm(project: project)
    }

    /// Add Project is a two-step flow: pick the device, then configure the project. The device step is
    /// skipped when the local Mac is the only device. Splitting device selection out fixes the device
    /// for the configuration step, so the project's source always targets one daemon.
    func addProject() {
        if Self.addProjectRequiresDeviceSelection(deviceCount: host.deviceModel.deviceSections.count) {
            showAddProjectDeviceStep()
        } else {
            showAddProjectSourceStep(deviceID: localProjectCreationDeviceID())
        }
    }

    // Not private: `ShortcutsController.handleNewWorkspaceShortcut` calls this from a different file
    // in the same module (cross-file `private` isn't visible).
    func addWorkspaceFromShortcut() {
        guard let project = currentProjectForNewWorkspace() else { return }
        showAddWorkspaceForm(project: project)
    }

    // MARK: - Project Settings

    private func showProjectSettingsDialog(project: ProjectSummary) {
        clearActiveAddFormStateAndCloseWindows()
        projectHasUnsavedChanges = false

        let projectSettings:
            (setupScript: String?, stopScript: String?, ports: [ServiceDefinition], processes: [ProcessTemplate], browserSessions: [BrowserSession])
        if let activeProject = host.deviceProjectSummary(projectID: project.id).map({ SpacesDeviceProjectSettingsViewModel(project: $0) }) {
            projectSettings = Self.localProjectSettings(from: activeProject.config)
        } else {
            projectSettings = (setupScript: nil, stopScript: nil, ports: [], processes: [], browserSessions: [])
        }

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false

        // --- Directory subtitle (the project name is shown in the dialog header) ---
        let dirField = NSTextField(string: project.dir)
        dirField.font = Typography.monoMetadata
        dirField.textColor = .tertiaryLabelColor
        dirField.lineBreakMode = .byTruncatingMiddle
        dirField.isEditable = false
        dirField.isSelectable = true
        dirField.drawsBackground = false
        dirField.isBordered = false
        dirField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        stack.addArrangedSubview(dirField)
        constrainFormFieldToFillWidth(dirField, in: stack)

        // --- Fields ---
        let setupScriptSection = ScriptSection(
            title: "Setup Script", editAccessibilityIdentifier: "setup-script-edit", formAccessibilityPrefix: "project-setup-script",
            value: projectSettings.setupScript ?? "", subtitle: "Runs when each new workspace is created.")
        let stopScriptSection = ScriptSection(
            title: "Stop Script", editAccessibilityIdentifier: "stop-script-edit", formAccessibilityPrefix: "workspace-stop-script",
            value: projectSettings.stopScript ?? "", subtitle: "Runs after processes stop — on stop, restart, and delete.")
        let portsSection = PortsSection(
            ports: projectSettings.ports, subtitle: "Per-workspace services, routed through Caddy.", showsEnvironmentVariableHints: true)
        let processesSection = ProcessesSection(
            processes: projectSettings.processes, subtitle: "Commands that run inside the workspace.", showsRuntimeControls: false)
        let browserSessionsSection = BrowserSessionsSection(
            sessions: projectSettings.browserSessions, subtitle: "Named URLs that open in Chrome when you focus them.")

        setupScriptSection.onCommit = { [weak self] _ in self?.projectHasUnsavedChanges = true }
        stopScriptSection.onCommit = { [weak self] _ in self?.projectHasUnsavedChanges = true }
        portsSection.onCommit = { [weak self] _ in self?.projectHasUnsavedChanges = true }
        portsSection.presentRemoveConfirmation = { [weak self] port, confirm in
            self?.presentProjectPortRemoveConfirmation(port: port, confirm: confirm)
        }
        processesSection.onCommit = { [weak self] _ in self?.projectHasUnsavedChanges = true }
        processesSection.validateProcess = { process in try AppKitController.validateProcessTemplate(process) }
        processesSection.presentValidationError = { [weak self] error in self?.host.showError(error) }
        processesSection.presentRemoveConfirmation = { [weak self] process, confirm in
            self?.presentProjectProcessRemoveConfirmation(process: process, confirm: confirm)
        }
        browserSessionsSection.onCommit = { [weak self] _ in self?.projectHasUnsavedChanges = true }
        browserSessionsSection.presentRemoveConfirmation = { [weak self] session, confirm in
            self?.presentProjectBrowserSessionRemoveConfirmation(session: session, confirm: confirm)
        }

        for section in [setupScriptSection.view, portsSection.view, processesSection.view, browserSessionsSection.view, stopScriptSection.view] {
            stack.addArrangedSubview(section)
            constrainFormFieldToFillWidth(section, in: stack)
        }

        // --- Buttons ---
        let saveButton = actionButton(
            title: "Save", symbol: nil, tooltip: "Save project (⌘S)", action: #selector(saveProject(_:)), primary: true, target: self)
        saveButton.identifier = NSUserInterfaceItemIdentifier(project.id)
        saveButton.setAccessibilityIdentifier("project-settings-save")
        saveButton.keyEquivalent = "\r"

        let importButton = actionButton(
            title: "Import spaces.yaml", symbol: nil, tooltip: "Load spaces.yaml into project settings",
            action: #selector(importProjectSpacesYAML(_:)), primary: false, target: self)
        importButton.setAccessibilityIdentifier("project-settings-import-spaces-yaml")
        Theme.applySecondaryStyle(to: importButton)

        let exportButton = actionButton(
            title: "Export spaces.yaml", symbol: nil, tooltip: "Export this project to spaces.yaml", action: #selector(exportProjectSpacesYAML(_:)),
            primary: false, target: self)
        exportButton.setAccessibilityIdentifier("project-settings-export-spaces-yaml")
        Theme.applySecondaryStyle(to: exportButton)

        let discardImportButton = actionButton(
            title: "Discard Import", symbol: nil, tooltip: "Discard imported config changes and reload the saved project settings",
            action: #selector(discardProjectConfigChanges(_:)), primary: false, target: self)
        discardImportButton.setAccessibilityIdentifier("project-settings-discard-import")
        discardImportButton.isHidden = true
        Theme.applySecondaryStyle(to: discardImportButton)

        let deleteButton = NSButton(title: "Delete", target: self, action: #selector(deleteProject(_:)))
        deleteButton.identifier = NSUserInterfaceItemIdentifier(project.id)
        deleteButton.setAccessibilityIdentifier("project-settings-delete")
        Theme.applyTextStyle(to: deleteButton, color: .systemRed)

        let buttonRow = NSStackView()
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8
        buttonRow.addArrangedSubview(deleteButton)
        buttonRow.addArrangedSubview(NSView())
        buttonRow.addArrangedSubview(importButton)
        buttonRow.addArrangedSubview(exportButton)
        buttonRow.addArrangedSubview(discardImportButton)
        buttonRow.addArrangedSubview(saveButton)
        stack.addArrangedSubview(buttonRow)
        constrainFormFieldToFillWidth(buttonRow, in: stack)

        presentProjectSettingsWindow(hosting: stack, project: project)

        let fieldsTag = storeProjectFields(
            projectID: project.id, setupScriptSection: setupScriptSection, stopScriptSection: stopScriptSection, portsSection: portsSection,
            processesSection: processesSection, browserSessionsSection: browserSessionsSection, importButton: importButton,
            exportButton: exportButton, discardImportedConfigButton: discardImportButton)
        saveButton.tag = fieldsTag
        discardImportButton.tag = fieldsTag
        importButton.tag = fieldsTag
        exportButton.tag = fieldsTag
        registerDirtyTracking(
            setupScriptSection: setupScriptSection, stopScriptSection: stopScriptSection, portsSection: portsSection,
            processesSection: processesSection, browserSessionsSection: browserSessionsSection)
    }

    private func presentProjectSettingsWindow(hosting stack: NSStackView, project: ProjectSummary) {
        projectSettingsProjectID = project.id
        let header = buildFormWindowHeader(
            symbol: "gearshape", title: project.name, closeAction: #selector(closeProjectSettingsWindow), target: self)
        projectSettingsWindow = host.presentFormWindow(existing: projectSettingsWindow, header: header, hosting: stack)
    }

    @objc private func closeProjectSettingsWindow() { projectSettingsWindow?.performClose(nil) }

    private func registerDirtyTracking(
        setupScriptSection: ScriptSection, stopScriptSection: ScriptSection, portsSection: PortsSection, processesSection: ProcessesSection,
        browserSessionsSection: BrowserSessionsSection
    ) {
        projectHasUnsavedChanges = false
        setupScriptSection.onCommit = { [weak self] _ in self?.projectHasUnsavedChanges = true }
        stopScriptSection.onCommit = { [weak self] _ in self?.projectHasUnsavedChanges = true }
        portsSection.onCommit = { [weak self] _ in self?.projectHasUnsavedChanges = true }
        processesSection.onCommit = { [weak self] _ in self?.projectHasUnsavedChanges = true }
        browserSessionsSection.onCommit = { [weak self] _ in self?.projectHasUnsavedChanges = true }
    }

    @objc private func saveProject(_ sender: NSButton) {
        commitEditing()
        guard let refs = Self.liveFormRefs(projectSettingsFieldRefs, forSenderTag: sender.tag) else { return }
        guard validateServiceEditorsCommitted(refs.portsSection, before: "saving project settings") else { return }
        guard confirmProjectImportWorkspaceSyncIfNeeded(refs) else { return }
        do {
            try persistProjectFields(refs)
            projectHasUnsavedChanges = false
            host.reloadData()
            // Saving is the terminal action for this dialog, so close it; the header X / Escape remain
            // for dismissing without saving. performClose routes through windowWillClose cleanup.
            projectSettingsWindow?.performClose(nil)
        } catch { host.showError(error) }
    }

    @objc private func exportProjectSpacesYAML(_ sender: NSButton) {
        commitEditing()
        guard let refs = Self.liveFormRefs(projectSettingsFieldRefs, forSenderTag: sender.tag) else { return }
        guard !projectHasUnsavedChanges, !refs.hasOpenSectionEditor else {
            host.showInfoMessage(title: "Save project settings first", message: "Save or discard pending changes before exporting spaces.yaml.")
            return
        }
        do {
            if let device = host.deviceForDaemonStateMutation() {
                let epoch = host.panelCoordinator.paneReplacementEpoch
                let response = try SpacesDeviceClient.exportProjectSpacesYAML(
                    projectID: refs.projectID,
                    context: DeviceRequestContext(device: device, clientApp: SpacesDeviceClient.macOSClientApp(appVersion: AppVersion.short)))
                host.applyDeviceMutationResponse(response, deviceID: device.id, epoch: epoch)
                host.showInfoMessage(title: "Exported spaces.yaml", message: response.message)
                return
            }
            host.showSelectedDeviceUnavailableError()
        } catch { host.showError(error) }
    }

    @objc private func importProjectSpacesYAML(_ sender: NSButton) {
        commitEditing()
        guard let refs = Self.liveFormRefs(projectSettingsFieldRefs, forSenderTag: sender.tag) else { return }
        do {
            if let device = host.deviceForDaemonStateMutation() {
                // A non-git project's template always syncs to its single workspace, so it takes the
                // sync path unprompted; git projects choose whether to update existing workspaces.
                let updateAllWorkspaces: Bool
                if isGitProject(refs.projectID) {
                    let decision = presentProjectImportWorkspaceSyncPrompt()
                    guard decision != .cancel else { return }
                    updateAllWorkspaces = decision == .updateAllWorkspaces
                } else {
                    updateAllWorkspaces = true
                }
                let epoch = host.panelCoordinator.paneReplacementEpoch
                let response = try SpacesDeviceClient.importProjectSpacesYAML(
                    projectID: refs.projectID, updateAllWorkspaces: updateAllWorkspaces,
                    context: DeviceRequestContext(device: device, clientApp: SpacesDeviceClient.macOSClientApp(appVersion: AppVersion.short)))
                refs.hasPendingImportedConfig = false
                refs.pendingImportUpdateAllWorkspaces = false
                refs.importButton.isHidden = false
                refs.exportButton.isHidden = false
                refs.discardImportedConfigButton.isHidden = true
                projectHasUnsavedChanges = false
                host.applyDeviceMutationResponse(response, deviceID: device.id, epoch: epoch)
                return
            }
            host.showSelectedDeviceUnavailableError()
        } catch { host.showError(error) }
    }

    @objc private func discardProjectConfigChanges(_ sender: NSButton) {
        commitEditing()
        guard let refs = Self.liveFormRefs(projectSettingsFieldRefs, forSenderTag: sender.tag) else { return }
        if let config = host.deviceProjectSummary(projectID: refs.projectID)?.config {
            hydrateProjectSettings(refs, from: config)
            refs.hasPendingImportedConfig = false
            refs.pendingImportUpdateAllWorkspaces = false
            refs.importButton.isHidden = false
            refs.exportButton.isHidden = false
            refs.discardImportedConfigButton.isHidden = true
            projectHasUnsavedChanges = false
            return
        }
        host.showDeviceNotLoadedError()
    }

    private func hydrateProjectSettings(_ refs: ProjectFieldRefs, from config: SpacesDeviceProjectConfig) {
        let settings = Self.localProjectSettings(from: config)
        refs.setupScriptSection.replace(value: settings.setupScript ?? "")
        refs.stopScriptSection.replace(value: settings.stopScript ?? "")
        refs.portsSection.replace(ports: settings.ports)
        refs.processesSection.replace(processes: settings.processes)
        refs.browserSessionsSection.replace(sessions: settings.browserSessions)
    }

    /// Whether the project is a git repo (vs a non-git project standing in for its single
    /// workspace). Unknown project ids default to git so the workspace-sync prompt is preserved.
    private func isGitProject(_ projectID: String) -> Bool { host.deviceModel.projects.first { $0.id == projectID }?.isGitRepo ?? true }

    private func confirmProjectImportWorkspaceSyncIfNeeded(_ refs: ProjectFieldRefs) -> Bool {
        guard refs.hasPendingImportedConfig else { return true }
        // A non-git project's template always syncs to its single workspace (see
        // updateProjectConfig), so there is no "project only" choice to offer — proceed unprompted.
        guard isGitProject(refs.projectID) else { return true }
        return Self.applyProjectImportWorkspaceSyncDecision(presentProjectImportWorkspaceSyncPrompt(), to: refs)
    }

    private func presentProjectImportWorkspaceSyncPrompt() -> ProjectImportWorkspaceSyncDecision {
        let alert = NSAlert()
        alert.messageText = "Update workspaces?"
        alert.informativeText = "Save the imported spaces.yaml settings to this project. Apply the same settings to every workspace in this project?"
        alert.addButton(withTitle: "Update All Workspaces")
        alert.addButton(withTitle: "Project Only")
        alert.addButton(withTitle: "Cancel")
        return Self.projectImportWorkspaceSyncDecision(for: alert.runModal())
    }

    private func presentManagedDirectoryReplacementPrompt(candidates: [SpacesDeviceManagedDirectoryReplacementCandidate]) -> Bool {
        let paths = candidates.map(\.path).joined(separator: "\n")
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = candidates.count == 1 ? "Replace existing managed folder?" : "Replace existing managed folders?"
        alert.informativeText = """
            Spaces found existing managed folders that are not registered to any project or workspace:

            \(paths)

            Replace them before continuing?
            """
        alert.addButton(withTitle: "Replace")
        alert.addButton(withTitle: "Cancel")
        let decision = Self.managedDirectoryReplacementDecision(for: alert.runModal())
        return Self.shouldStartManagedDirectoryReplacementFlow(candidateCount: candidates.count, decision: decision)
    }

    @objc private func deleteProject(_ sender: NSButton) {
        guard let projectID = sender.identifier?.rawValue, host.deviceModel.projects.contains(where: { $0.id == projectID }) else { return }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Delete project?"
        alert.informativeText = """
            This removes the project and its workspaces from Spaces.
            If this project was cloned into ~/spaces/repos by Spaces, that project directory is deleted.
            For git projects, related workspace directories under ~/spaces/workspaces are also deleted.
            """
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }

        sender.isEnabled = false
        host.showOperationProgressOverlay(
            message: "Deleting project...", detail: "Removing the project and its managed workspaces.", context: .project(projectID))
        Task { @MainActor [weak self, weak sender] in
            guard let self else { return }
            defer {
                sender?.isEnabled = true
                host.hideOperationProgressOverlay()
            }
            if let device = host.deviceForDaemonStateMutation() {
                let epoch = host.panelCoordinator.paneReplacementEpoch
                let result = await AppKitController.deviceMutation(device: device) { device in
                    try SpacesDeviceClient.deleteProject(
                        projectID: projectID,
                        context: DeviceRequestContext(device: device, clientApp: SpacesDeviceClient.macOSClientApp(appVersion: AppVersion.short)))
                }
                switch result {
                case .success(let response):
                    projectHasUnsavedChanges = false
                    host.selectedProjectID = nil
                    host.selectedWorkspaceID = nil
                    closeProjectSettingsWindow()
                    // Pass the deleting device explicitly: the selection was just cleared, so any
                    // selection-based device inference would misroute a remote delete's overview (and
                    // its pane-prune keep-set) into the local section.
                    host.applyDeviceMutationResponse(response, deviceID: device.id, epoch: epoch)
                case .failure(let error): host.showError(error)
                }
            } else {
                host.showSelectedDeviceUnavailableError()
            }
        }
    }

    private func persistProjectFields(_ refs: ProjectFieldRefs) throws {
        if let device = host.deviceForDaemonStateMutation() {
            // A non-git project stands in for its single workspace, so its project settings are the
            // config that runs: sync the saved template to that workspace unconditionally. Git
            // projects keep the template/per-workspace split and only sync a pending import when the
            // user chose Update All Workspaces.
            let updateAllWorkspaces = Self.projectSaveSyncsAllWorkspaces(
                isGitRepo: isGitProject(refs.projectID), pendingImportUpdateAllWorkspaces: refs.pendingImportUpdateAllWorkspaces)
            let epoch = host.panelCoordinator.paneReplacementEpoch
            let response = try SpacesDeviceClient.updateProjectConfig(
                projectID: refs.projectID, config: Self.deviceProjectConfig(from: refs), updateAllWorkspaces: updateAllWorkspaces,
                context: DeviceRequestContext(device: device, clientApp: SpacesDeviceClient.macOSClientApp(appVersion: AppVersion.short)))
            refs.hasPendingImportedConfig = false
            refs.pendingImportUpdateAllWorkspaces = false
            refs.discardImportedConfigButton.isHidden = true
            host.applyDeviceMutationResponse(response, deviceID: device.id, epoch: epoch)
            return
        }
        throw host.deviceUnavailableError(deviceID: host.selectedRowDeviceID() ?? SpacesPairedDeviceRecord.localDeviceID)
    }

    private func commitEditing() {
        let windows = [host.window, NSApp.keyWindow, NSApp.mainWindow].compactMap { $0 }
        for window in windows {
            window.endEditing(for: nil)
            _ = window.makeFirstResponder(nil)
        }
    }

    private func validateServiceEditorsCommitted(_ portsSection: PortsSection, before action: String) -> Bool {
        guard !portsSection.hasOpenEditor else {
            host.showInfoMessage(
                title: "Finish service name",
                message:
                    "Service names cannot be empty and must use lowercase letters, digits, or hyphens, starting and ending with a letter or digit, before \(action)."
            )
            return false
        }
        return true
    }

    private func presentProjectPortRemoveConfirmation(port: ServiceDefinition, confirm: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = "Remove port \"\(port.name)\"?"
        alert.informativeText = "This removes the port definition from the project."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        confirm(alert.runModal() == .alertFirstButtonReturn)
    }

    private func presentProjectProcessRemoveConfirmation(process: ProcessTemplate, confirm: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        let displayName = process.name ?? process.command
        alert.messageText = "Remove \(displayName)?"
        alert.informativeText = "This removes the process from the project."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        confirm(alert.runModal() == .alertFirstButtonReturn)
    }

    private func presentProjectBrowserSessionRemoveConfirmation(session: BrowserSession, confirm: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        let displayName = session.name ?? session.url ?? "this session"
        alert.messageText = "Remove \(displayName)?"
        alert.informativeText = "This removes the browser session from the project."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        confirm(alert.runModal() == .alertFirstButtonReturn)
    }

    // MARK: - Add Project

    /// The device-selection step is shown only when there is a choice; a single device (the local Mac)
    /// goes straight to project configuration.
    nonisolated static func addProjectRequiresDeviceSelection(deviceCount: Int) -> Bool { deviceCount > 1 }

    /// Step 1: choose the device the project will be created on. Each device is a full-width,
    /// left-aligned row; clicking one advances to the configuration step. Closing the window cancels.
    private func showAddProjectDeviceStep() {
        clearActiveAddProjectFormState()

        let deviceRows = host.deviceModel.deviceSections.map { addProjectDeviceRow(section: $0) }
        let deviceCard = host.formSectionCard(
            icon: "desktopcomputer", title: "Device", subtitle: "Choose where this project will live.", contentViews: deviceRows)

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(deviceCard)
        constrainFormFieldToFillWidth(deviceCard, in: stack)

        presentAddProjectWindow(hosting: stack, title: "New Project")
    }

    /// A left-aligned, hover-highlighted device row: platform icon, device name, and a `local`/`remote`
    /// caption, with a trailing chevron signaling that clicking advances to project configuration.
    /// A project can only be created on a reachable device; an offline daemon would make the source
    /// step's Continue hang on a request that just times out, so its row is shown disabled.
    nonisolated static func addProjectDeviceIsSelectable(loadState: AppKitController.SidebarDeviceLoadState) -> Bool { !loadState.isOffline }

    private func addProjectDeviceRow(section: AppKitController.DeviceSection) -> NSView {
        let selectable = Self.addProjectDeviceIsSelectable(loadState: section.loadState)
        let container = ClickableRowView(isInteractive: selectable)
        container.layer?.borderWidth = 1
        bindAppearanceReactiveLayer(container) { [weak self] view in
            view.layer?.borderColor = self?.host.sidebar.sidebarCardBorderColor(isSelected: false).cgColor
        }
        container.alphaValue = selectable ? 1 : AppKitController.unreachableDeviceAlpha
        container.setAccessibilityElement(true)
        container.setAccessibilityRole(.button)
        container.setAccessibilityLabel(section.displayName)
        container.setAccessibilityIdentifier("add-project-device-option")
        container.toolTip = selectable ? "Create the project on \(section.displayName)" : "\(section.displayName) is offline"

        let iconView = NSImageView()
        iconView.image = NSImage(systemSymbolName: section.isLocal ? "desktopcomputer" : "server.rack", accessibilityDescription: nil)
        iconView.contentTintColor = host.sidebar.sidebarThemeColor(light: (13, 95, 93), dark: (61, 198, 184))
        iconView.setContentHuggingPriority(.required, for: .horizontal)
        iconView.setContentCompressionResistancePriority(.required, for: .horizontal)

        let nameField = NSTextField(labelWithString: section.displayName)
        nameField.font = Typography.sectionTitle
        nameField.textColor = .labelColor
        nameField.lineBreakMode = .byTruncatingMiddle
        nameField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let caption = selectable ? (section.isLocal ? "This device" : "Remote device") : "Offline"
        let captionField = NSTextField(labelWithString: caption)
        captionField.font = Typography.metadata
        captionField.textColor = .secondaryLabelColor
        captionField.lineBreakMode = .byTruncatingTail

        let textStack = NSStackView(views: [nameField, captionField])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 1

        // Selectable rows show a chevron (click advances); offline rows show a muted offline glyph.
        let trailingIcon = NSImageView()
        trailingIcon.image = NSImage(systemSymbolName: selectable ? "chevron.right" : "bolt.horizontal.circle", accessibilityDescription: nil)
        trailingIcon.contentTintColor = .tertiaryLabelColor
        trailingIcon.setContentHuggingPriority(.required, for: .horizontal)
        trailingIcon.setContentCompressionResistancePriority(.required, for: .horizontal)

        let row = NSStackView(views: [iconView, textStack, NSView(), trailingIcon])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        row.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: container.leadingAnchor), row.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            row.topAnchor.constraint(equalTo: container.topAnchor), row.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            container.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])

        // An offline device is not clickable, so no gesture is attached and Continue can never target it.
        guard selectable else { return container }
        let deviceID = section.deviceID
        let target = AppKitController.ClickTarget { [weak self] in self?.showAddProjectSourceStep(deviceID: deviceID) }
        let recognizer = NSClickGestureRecognizer(target: target, action: #selector(AppKitController.ClickTarget.clicked(_:)))
        container.addGestureRecognizer(recognizer)
        objc_setAssociatedObject(container, &AppKitController.clickTargetAssocKey, target, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return container
    }

    /// The New Project title, naming the target device only when there is a choice to disambiguate.
    private func addProjectFlowTitle(deviceID: String) -> String {
        host.deviceModel.deviceSections.count > 1 ? "New Project · \(host.deviceDisplayName(id: deviceID))" : "New Project"
    }

    /// Step 2: choose the source — an existing folder or a repository to clone — and its location.
    /// Continue loads the configuration (Step 3). Splitting the source into its own step means it is
    /// fixed before configuration, so there is no source toggle to switch mid-config.
    private func showAddProjectSourceStep(deviceID: String) {
        clearActiveAddProjectFormState()

        let deviceName = host.deviceDisplayName(id: deviceID)
        let folderRow = addProjectSourceRow(
            icon: "folder", title: "Existing folder", subtitle: "Use a project already on \(deviceName)", accessibilityID: "add-project-source-folder"
        )
        let gitRow = addProjectSourceRow(
            icon: "chevron.left.forwardslash.chevron.right", title: "Clone a repo", subtitle: "Clone a Git repository into ~/spaces/repos",
            accessibilityID: "add-project-source-git")

        let dirField = NSTextField(string: "")
        dirField.placeholderString = "~/projects/my-app"
        dirField.delegate = host
        dirField.setAccessibilityIdentifier("add-project-directory-path")
        let repoURLField = NSTextField(string: "")
        repoURLField.placeholderString = "https://github.com/org/repo.git"
        repoURLField.delegate = host
        repoURLField.setAccessibilityIdentifier("add-project-repo-url")
        let folderInputRow = sourceInputRow(headerText: "Folder path", field: dirField)
        let gitInputRow = sourceInputRow(headerText: "Repository URL", field: repoURLField)
        folderInputRow.isHidden = true
        gitInputRow.isHidden = true

        // Config-step controls are built now and shown after Continue loads the config.
        let (setup, stop, ports, processes, browsers) = makeAddProjectConfigSections()
        let createButton = actionButton(
            title: "Create", symbol: nil, tooltip: "Create project", action: #selector(createProject(_:)), primary: true, target: self)
        let spacesYAMLMissingLabel = NSTextField(
            wrappingLabelWithString: "No spaces.yaml found in this repository. Set up the configuration below as needed.")
        spacesYAMLMissingLabel.font = Typography.rowDetail
        spacesYAMLMissingLabel.textColor = .secondaryLabelColor
        spacesYAMLMissingLabel.setAccessibilityIdentifier("add-project-spaces-yaml-missing")

        let continueButton = actionButton(
            title: "Continue", symbol: nil, tooltip: "Load the project configuration", action: #selector(continueFromSourceStep(_:)), primary: true,
            target: self)
        continueButton.isEnabled = false
        continueButton.setAccessibilityIdentifier("add-project-source-continue")

        let id = storeAddProjectFields(
            folderRow: folderRow, gitRow: gitRow, folderInputRow: folderInputRow, gitInputRow: gitInputRow, dirField: dirField,
            repoURLField: repoURLField, continueButton: continueButton, setupScriptSection: setup, stopScriptSection: stop, portsSection: ports,
            processesSection: processes, browserSessionsSection: browsers, createButton: createButton, spacesYAMLMissingLabel: spacesYAMLMissingLabel)
        activeAddProjectFormTag = id
        guard let refs = addProjectFieldRefs else { return }
        refs.selectedDeviceID = deviceID
        attachAddProjectSourceRowSelection(folderRow, kind: .folder, tag: id)
        attachAddProjectSourceRowSelection(gitRow, kind: .git, tag: id)

        presentAddProjectSourceStep(refs)
    }

    /// Renders the source step from the stored field views and presents it. Used for the initial
    /// presentation and to return to the source step (with the entered values intact) when a load fails
    /// or the managed-directory replacement prompt is declined.
    private func presentAddProjectSourceStep(_ refs: AddProjectFieldRefs) {
        let sourceCard = host.formSectionCard(
            icon: "folder.badge.plus", title: "Source", subtitle: "Where does your project live?",
            contentViews: [refs.folderRow, refs.gitRow, refs.folderInputRow, refs.gitInputRow])

        let cancelButton = actionButton(
            title: "Cancel", symbol: nil, tooltip: "Cancel", action: #selector(cancelProjectForm), primary: false, target: self)
        Theme.applySecondaryStyle(to: cancelButton)
        let buttonRow = NSStackView()
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8
        buttonRow.setViews([cancelButton], in: .leading)
        buttonRow.setViews([refs.continueButton], in: .trailing)

        let stack = addProjectStepStack()
        stack.addArrangedSubview(sourceCard)
        stack.addArrangedSubview(buttonRow)
        constrainFormFieldToFillWidth(sourceCard, in: stack)
        constrainFormFieldToFillWidth(buttonRow, in: stack)

        presentAddProjectWindow(hosting: stack, title: addProjectFlowTitle(deviceID: refs.selectedDeviceID))
        updateAddProjectSourceStepUI(refs)
    }

    /// A brief loading step shown while the chosen source's `spaces.yaml` is fetched. It carries no
    /// editable inputs so the source cannot change while the preview is in flight.
    private func presentAddProjectLoadingStep(deviceID: String, detail: String) {
        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.startAnimation(nil)
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.setContentHuggingPriority(.required, for: .horizontal)

        let label = NSTextField(labelWithString: detail)
        label.font = Typography.rowDetail
        label.textColor = .secondaryLabelColor

        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 10
        row.alignment = .centerY
        row.addArrangedSubview(spinner)
        row.addArrangedSubview(label)

        let card = host.formSectionCard(icon: "square.and.arrow.down", title: "Loading project settings", subtitle: "", contentViews: [row])

        let cancelButton = actionButton(
            title: "Cancel", symbol: nil, tooltip: "Cancel", action: #selector(cancelProjectForm), primary: false, target: self)
        Theme.applySecondaryStyle(to: cancelButton)
        let buttonRow = NSStackView()
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8
        buttonRow.setViews([cancelButton], in: .leading)

        let stack = addProjectStepStack()
        stack.addArrangedSubview(card)
        stack.addArrangedSubview(buttonRow)
        constrainFormFieldToFillWidth(card, in: stack)
        constrainFormFieldToFillWidth(buttonRow, in: stack)

        presentAddProjectWindow(hosting: stack, title: addProjectFlowTitle(deviceID: deviceID))
    }

    /// Step 3: review and edit the configuration (loaded from the source on entry) and create.
    private func showAddProjectConfigStep(_ refs: AddProjectFieldRefs) {
        let cancelButton = actionButton(
            title: "Cancel", symbol: nil, tooltip: "Cancel", action: #selector(cancelProjectForm), primary: false, target: self)
        Theme.applySecondaryStyle(to: cancelButton)
        let buttonRow = NSStackView()
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8
        buttonRow.setViews([cancelButton], in: .leading)
        buttonRow.setViews([refs.createButton], in: .trailing)

        refs.spacesYAMLMissingLabel.isHidden = !refs.spacesYAMLMissing

        let sectionViews = [
            refs.spacesYAMLMissingLabel, refs.setupScriptSection.view, refs.portsSection.view, refs.processesSection.view,
            refs.browserSessionsSection.view, refs.stopScriptSection.view, buttonRow,
        ]
        let stack = addProjectStepStack()
        for view in sectionViews {
            view.isHidden = view === refs.spacesYAMLMissingLabel ? !refs.spacesYAMLMissing : false
            stack.addArrangedSubview(view)
            constrainFormFieldToFillWidth(view, in: stack)
        }

        presentAddProjectWindow(hosting: stack, title: addProjectFlowTitle(deviceID: refs.selectedDeviceID))
        refs.createButton.isEnabled = true
    }

    private func addProjectStepStack() -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.detachesHiddenViews = true
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    private func makeAddProjectConfigSections() -> (ScriptSection, ScriptSection, PortsSection, ProcessesSection, BrowserSessionsSection) {
        let setupScriptSection = ScriptSection(
            title: "Setup Script", editAccessibilityIdentifier: "setup-script-edit", formAccessibilityPrefix: "project-setup-script", value: "",
            subtitle: "Runs when each new workspace is created.")
        let stopScriptSection = ScriptSection(
            title: "Stop Script", editAccessibilityIdentifier: "stop-script-edit", formAccessibilityPrefix: "workspace-stop-script", value: "",
            subtitle: "Runs after processes stop — on stop, restart, and delete.")
        let portsSection = PortsSection(subtitle: "Per-workspace named ports, exposed as env vars.", showsEnvironmentVariableHints: true)
        let processesSection = ProcessesSection(subtitle: "Commands that run inside the workspace.", showsRuntimeControls: false)
        let browserSessionsSection = BrowserSessionsSection(subtitle: "Named URLs that open in Chrome when you focus them.")
        return (setupScriptSection, stopScriptSection, portsSection, processesSection, browserSessionsSection)
    }

    /// A left-aligned, hover-highlighted, selectable source row (icon, title, caption). Selecting it
    /// reveals its input below; the highlighted border marks the current choice.
    private func addProjectSourceRow(icon: String, title: String, subtitle: String, accessibilityID: String) -> ClickableRowView {
        let container = ClickableRowView(isInteractive: true)
        container.layer?.borderWidth = 1
        bindAppearanceReactiveLayer(container) { [weak self] view in
            view.layer?.borderColor = self?.host.sidebar.sidebarCardBorderColor(isSelected: false).cgColor
        }
        container.setAccessibilityElement(true)
        container.setAccessibilityRole(.button)
        container.setAccessibilityLabel(title)
        container.setAccessibilityIdentifier(accessibilityID)

        let iconView = NSImageView()
        iconView.image = NSImage(systemSymbolName: icon, accessibilityDescription: nil)
        iconView.contentTintColor = host.sidebar.sidebarThemeColor(light: (13, 95, 93), dark: (61, 198, 184))
        iconView.setContentHuggingPriority(.required, for: .horizontal)
        iconView.setContentCompressionResistancePriority(.required, for: .horizontal)

        let titleField = NSTextField(labelWithString: title)
        titleField.font = Typography.sectionTitle
        titleField.textColor = .labelColor
        let captionField = NSTextField(labelWithString: subtitle)
        captionField.font = Typography.metadata
        captionField.textColor = .secondaryLabelColor
        captionField.lineBreakMode = .byTruncatingTail

        let textStack = NSStackView(views: [titleField, captionField])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 1

        let row = NSStackView(views: [iconView, textStack, NSView()])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        row.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: container.leadingAnchor), row.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            row.topAnchor.constraint(equalTo: container.topAnchor), row.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            container.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
        return container
    }

    private func sourceInputRow(headerText: String, field: NSTextField) -> NSView {
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let stack = NSStackView(views: [makeFieldHeader(headerText), field])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.detachesHiddenViews = true
        field.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return stack
    }

    private func attachAddProjectSourceRowSelection(_ row: ClickableRowView, kind: AddProjectSourceKind, tag: Int) {
        let target = AppKitController.ClickTarget { [weak self] in self?.selectAddProjectSourceKind(kind, tag: tag) }
        let recognizer = NSClickGestureRecognizer(target: target, action: #selector(AppKitController.ClickTarget.clicked(_:)))
        row.addGestureRecognizer(recognizer)
        objc_setAssociatedObject(row, &AppKitController.clickTargetAssocKey, target, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    private func selectAddProjectSourceKind(_ kind: AddProjectSourceKind, tag: Int) {
        guard let refs = Self.liveFormRefs(addProjectFieldRefs, forSenderTag: tag) else { return }
        refs.selectedSourceKind = kind
        updateAddProjectSourceStepUI(refs)
        addProjectWindow?.makeFirstResponder(kind == .folder ? refs.dirField : refs.repoURLField)
    }

    private func updateAddProjectSourceStepUI(_ refs: AddProjectFieldRefs) {
        let kind = refs.selectedSourceKind
        setAddProjectSourceRowSelected(refs.folderRow, selected: kind == .folder)
        setAddProjectSourceRowSelected(refs.gitRow, selected: kind == .git)
        refs.folderInputRow.isHidden = kind != .folder
        refs.gitInputRow.isHidden = kind != .git
        let input: String
        switch kind {
        case .folder: input = refs.dirField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        case .git: input = refs.repoURLField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        case nil: input = ""
        }
        refs.continueButton.isEnabled = kind != nil && !input.isEmpty
    }

    private func setAddProjectSourceRowSelected(_ row: ClickableRowView, selected: Bool) {
        row.layer?.borderWidth = selected ? 2 : 1
        bindAppearanceReactiveLayer(row) { [weak self] view in
            view.layer?.borderColor =
                selected
                ? self?.host.sidebar.sidebarThemeColor(light: (13, 95, 93), dark: (61, 198, 184)).cgColor
                : self?.host.sidebar.sidebarCardBorderColor(isSelected: false).cgColor
        }
    }

    /// The default device for new projects: the local Mac.
    private func localProjectCreationDeviceID() -> String {
        host.deviceModel.deviceSections.first(where: { $0.isLocal })?.deviceID ?? SpacesPairedDeviceRecord.localDeviceID
    }

    private func presentAddProjectWindow(hosting stack: NSStackView, title: String) {
        let header = buildFormWindowHeader(
            symbol: "square.and.pencil", title: title, closeAction: #selector(closeAddProjectWindow), target: self)
        addProjectWindow = host.presentFormWindow(existing: addProjectWindow, header: header, hosting: stack)
    }

    @objc private func closeAddProjectWindow() { addProjectWindow?.performClose(nil) }

    @objc private func cancelProjectForm() { closeAddProjectWindow() }

    @objc private func createProject(_ sender: NSButton) {
        commitEditing()
        guard let refs = Self.liveFormRefs(addProjectFieldRefs, forSenderTag: sender.tag) else { return }
        guard validateServiceEditorsCommitted(refs.portsSection, before: "creating the project") else { return }
        do {
            // The project is created on the device fixed in step 1; folder autocomplete and preview
            // used the same device.
            if let device = host.deviceRecord(forDeviceID: refs.selectedDeviceID) {
                let projectDir: String?
                let gitURL: String?
                if refs.selectedSourceKind == .git {
                    let repoURL = refs.repoURLField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !repoURL.isEmpty else { throw WorkspaceError.invalidArgument(message: "Git repository URL is required.") }
                    projectDir = nil
                    gitURL = repoURL
                } else {
                    let dir = refs.dirField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !dir.isEmpty else { return }
                    projectDir = dir
                    gitURL = nil
                }
                let config = Self.deviceProjectConfig(from: refs)
                // For a git source the daemon clones the repository now and applies this config (the
                // preview only fetched spaces.yaml). Cloning at Create means nothing is left behind if
                // the user cancels, so there is no prepared clone to track or discard.
                let originalTitle = sender.title
                sender.isEnabled = false
                sender.title = "Creating..."
                host.showOperationProgressOverlay(
                    message: "Creating project...", detail: "Creating the project on \(host.deviceDisplayName(id: refs.selectedDeviceID)).",
                    context: .global)
                Task { @MainActor [weak self, weak sender] in
                    guard let self else { return }
                    defer {
                        sender?.isEnabled = true
                        sender?.title = originalTitle
                        host.hideOperationProgressOverlay()
                    }
                    let epoch = host.panelCoordinator.paneReplacementEpoch
                    let result = await AppKitController.deviceMutation(device: device) { device in
                        try SpacesDeviceClient.createProject(
                            projectDir: projectDir, gitURL: gitURL, config: config,
                            context: DeviceRequestContext(device: device, clientApp: SpacesDeviceClient.macOSClientApp(appVersion: AppVersion.short)))
                    }
                    switch result {
                    case .success(let response):
                        clearActiveAddFormStateAndCloseWindows()
                        host.selectedProjectID = response.projectID
                        host.selectedWorkspaceID = response.workspaceID
                        // A new project on a remote device belongs to that device's
                        // section; force a remote refresh so it lands there immediately
                        // instead of waiting out the per-device freshness gate.
                        if host.isRemoteDeviceID(refs.selectedDeviceID) {
                            host.requestSidebarReload(forceRemoteRefresh: true)
                        } else {
                            host.applyDeviceMutationResponse(
                                response, deviceID: device.id, epoch: epoch, selectedProjectID: response.projectID,
                                selectedWorkspaceID: response.workspaceID)
                        }
                    case .failure(let error):
                        // Nothing was cloned yet (the clone is part of the failed Create), so there is
                        // no prepared clone to restore or discard.
                        host.showError(error)
                    }
                }
                return
            }
            host.showDeviceNotLoadedError()
        } catch { host.showError(error) }
    }

    @objc private func continueFromSourceStep(_ sender: NSButton) {
        guard let refs = Self.liveFormRefs(addProjectFieldRefs, forSenderTag: sender.tag) else { return }
        advanceFromSourceStep(refs)
    }

    /// Loads the configuration from the chosen source and advances to the config step. For a folder the
    /// daemon validates the path and reads any `spaces.yaml`; for a repo it fetches `spaces.yaml` (single
    /// file, no clone). While loading, the source inputs are replaced by a loading step so nothing is
    /// editable in flight; a failure returns to the source step (values intact) with the error surfaced.
    private func advanceFromSourceStep(_ refs: AddProjectFieldRefs) {
        guard let kind = refs.selectedSourceKind else { return }
        // Loading against an offline daemon would hang until the request times out. Offline devices are
        // not selectable in the device step, but the device step is skipped for a lone local device, so
        // guard here too and surface the offline state instead.
        if let section = host.deviceSection(id: refs.selectedDeviceID), !Self.addProjectDeviceIsSelectable(loadState: section.loadState) {
            host.showError(AppKitController.deviceUnreachableError(deviceName: section.displayName, isLocal: section.isLocal))
            return
        }
        guard let device = host.deviceRecord(forDeviceID: refs.selectedDeviceID) else {
            host.showDeviceNotLoadedError()
            return
        }
        let input = (kind == .folder ? refs.dirField : refs.repoURLField).stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return }

        // Swap the source inputs for a loading step. With no editable source on screen during the fetch,
        // the loaded config cannot end up describing a source different from what Create will use, so no
        // separate staleness bookkeeping is needed.
        presentAddProjectLoadingStep(
            deviceID: refs.selectedDeviceID,
            detail: kind == .folder ? "Validating the folder and reading spaces.yaml…" : "Reading spaces.yaml from the repository…")
        Task { @MainActor [weak self] in
            guard let self else { return }
            switch kind {
            case .folder:
                let result = await Self.deviceProjectPreview(dir: input, device: device)
                guard isActiveAddProjectForm(refs) else { return }
                switch result {
                case .success(let preview):
                    refs.spacesYAMLMissing = false
                    hydrateAddProjectSettings(refs, from: preview.config)
                    showAddProjectConfigStep(refs)
                case .failure(let error):
                    presentAddProjectSourceStep(refs)
                    host.showError(error)
                }
            case .git:
                let result = await Self.previewGitProjectResult(gitURL: input, device: device)
                guard isActiveAddProjectForm(refs) else { return }
                switch result {
                case .success(let preview):
                    // Managed directories already exist for this repo; Create replaces them, so confirm now.
                    if !preview.replacementCandidates.isEmpty, !presentManagedDirectoryReplacementPrompt(candidates: preview.replacementCandidates) {
                        presentAddProjectSourceStep(refs)
                        return
                    }
                    refs.spacesYAMLMissing = !preview.spacesYAMLFound
                    hydrateAddProjectSettings(refs, from: preview.config ?? SpacesDeviceProjectConfig())
                    showAddProjectConfigStep(refs)
                case .failure(let error):
                    presentAddProjectSourceStep(refs)
                    host.showError(error)
                }
            }
        }
    }

    private func isActiveAddProjectForm(_ refs: AddProjectFieldRefs) -> Bool {
        activeAddProjectFormTag == refs.formTag && addProjectFieldRefs === refs
    }

    private func addProjectRefs(forDirectoryField field: NSControl) -> AddProjectFieldRefs? {
        guard let refs = addProjectFieldRefs, refs.dirField === field else { return nil }
        return refs
    }

    private func scheduleAddProjectDirectorySuggestions(_ refs: AddProjectFieldRefs) {
        refs.directorySuggestionTask?.cancel()
        let query = refs.dirField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, let device = host.deviceRecord(forDeviceID: refs.selectedDeviceID) else {
            refs.directoryCompletions = []
            return
        }
        refs.directorySuggestionTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled, let self else { return }
            let suggestions = await Self.deviceDirectorySuggestions(path: query, device: device)
            guard !Task.isCancelled, isActiveAddProjectForm(refs), refs.dirField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) == query
            else { return }
            let completions = suggestions.map { ($0 as NSString).lastPathComponent }
            refs.directoryCompletions = completions
            // Suppress re-popping the dropdown when the only match is the leaf already typed.
            let typedLeaf = (query as NSString).lastPathComponent
            let exactSingleMatch = completions.count == 1 && completions[0].localizedCaseInsensitiveCompare(typedLeaf) == .orderedSame
            guard !completions.isEmpty, !exactSingleMatch, let editor = refs.dirField.currentEditor() else { return }
            editor.complete(nil)
        }
    }

    private func hydrateAddProjectSettings(_ refs: AddProjectFieldRefs, from config: SpacesDeviceProjectConfig) {
        let settings = Self.localProjectSettings(from: config)
        refs.setupScriptSection.replace(value: settings.setupScript ?? "")
        refs.stopScriptSection.replace(value: settings.stopScript ?? "")
        refs.portsSection.replace(ports: settings.ports)
        refs.processesSection.replace(processes: settings.processes)
        refs.browserSessionsSection.replace(sessions: settings.browserSessions)
    }

    // MARK: - Add Workspace

    private func currentProjectForNewWorkspace() -> ProjectSummary? {
        if let selectedProjectID = host.selectedProjectID, let project = host.deviceModel.projects.first(where: { $0.id == selectedProjectID }) {
            return project
        }
        if let selectedWorkspaceID = host.selectedWorkspaceID, let (project, _) = host.findWorkspace(id: selectedWorkspaceID) { return project }
        return nil
    }

    private func showAddWorkspaceForm(project: ProjectSummary) {
        // The new-workspace form is git-only: non-git projects own a single workspace
        // (the project directory) and offer no way to add more.
        guard project.isGitRepo else { return }
        // Creating a workspace clones and configures it on the owning daemon, so an unreachable
        // device has no form to fill in — refuse before opening it, the way the add-project device
        // picker refuses an offline device. The sidebar's + button is disabled for the same reason,
        // but the add-workspace shortcut reaches this directly from the selection.
        guard host.deviceForMutation(deviceID: project.deviceID) != nil else {
            host.showError(host.deviceUnavailableError(deviceID: project.deviceID))
            return
        }
        clearActiveAddWorkspaceFormState()

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false

        // --- Fields ---
        let baseBranchField = NSComboBox()
        baseBranchField.usesDataSource = false
        baseBranchField.completes = true
        baseBranchField.numberOfVisibleItems = 10
        baseBranchField.setAccessibilityIdentifier("add-workspace-base-branch")
        let baseBranches = [defaultWorkspaceBaseBranchFast(project: project)].compactMap { $0 }
        baseBranchField.addItems(withObjectValues: baseBranches)
        if let defaultBaseBranch = defaultWorkspaceBaseBranch(project: project, branches: baseBranches) {
            baseBranchField.stringValue = defaultBaseBranch
        }
        let existingBranchField = NSComboBox()
        existingBranchField.usesDataSource = false
        existingBranchField.completes = true
        existingBranchField.numberOfVisibleItems = 10
        existingBranchField.placeholderString = "search branches"
        existingBranchField.setAccessibilityIdentifier("add-workspace-existing-branch")
        existingBranchField.target = self
        existingBranchField.action = #selector(addWorkspaceBranchFieldChanged(_:))
        existingBranchField.delegate = host
        existingBranchField.addItems(withObjectValues: baseBranches)
        let newBranchField = NSTextField(string: "")
        newBranchField.placeholderString = "new branch name"
        newBranchField.setAccessibilityIdentifier("add-workspace-new-branch")
        newBranchField.delegate = host
        let notesField = NSTextField(string: "")
        notesField.placeholderString = "optional: context about what you're working on"
        notesField.setAccessibilityIdentifier("add-workspace-notes")
        let autoNameState = AddWorkspaceAutoNameState()

        // --- Content card ---
        let contentStack = NSStackView()
        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 10
        contentStack.detachesHiddenViews = true

        let modeSegmented = NSSegmentedControl(
            labels: ["Create branch", "Use existing"], trackingMode: .selectOne, target: self, action: #selector(addWorkspaceBranchModeChanged(_:)))
        modeSegmented.selectedSegment = 0
        modeSegmented.setAccessibilityIdentifier("add-workspace-branch-mode")
        modeSegmented.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        contentStack.addArrangedSubview(modeSegmented)

        let branchInputContainer = NSStackView()
        branchInputContainer.orientation = .vertical
        branchInputContainer.spacing = 0
        branchInputContainer.detachesHiddenViews = true
        branchInputContainer.addArrangedSubview(newBranchField)
        branchInputContainer.addArrangedSubview(existingBranchField)
        constrainFormFieldToFillWidth(newBranchField, in: branchInputContainer)
        constrainFormFieldToFillWidth(existingBranchField, in: branchInputContainer)
        existingBranchField.isHidden = true

        let branchRow = labeledInputRow(label: "Branch", input: branchInputContainer)
        contentStack.addArrangedSubview(branchRow)
        constrainFormFieldToFillWidth(branchRow, in: contentStack)

        let baseRow = labeledInputRow(label: "Base branch", input: baseBranchField)
        contentStack.addArrangedSubview(baseRow)
        constrainFormFieldToFillWidth(baseRow, in: contentStack)

        let notesRow = labeledInputRow(label: "Notes", input: notesField)
        contentStack.addArrangedSubview(notesRow)
        constrainFormFieldToFillWidth(notesRow, in: contentStack)

        let branchModeSegmented: NSSegmentedControl? = modeSegmented

        stack.addArrangedSubview(contentStack)
        constrainFormFieldToFillWidth(contentStack, in: stack)

        // --- Buttons ---
        let createButton = actionButton(
            title: "Create", symbol: nil, tooltip: "Create workspace", action: #selector(createWorkspace(_:)), primary: true, target: self)
        createButton.setAccessibilityIdentifier("add-workspace-create")
        let cancelButton = actionButton(
            title: "Cancel", symbol: nil, tooltip: "Cancel", action: #selector(closeAddWorkspaceWindow), primary: false, target: self)
        cancelButton.setAccessibilityIdentifier("add-workspace-cancel")
        Theme.applySecondaryStyle(to: cancelButton)

        let buttonRow = NSStackView()
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8
        buttonRow.setViews([cancelButton], in: .leading)
        buttonRow.setViews([createButton], in: .trailing)
        stack.addArrangedSubview(buttonRow)
        constrainFormFieldToFillWidth(buttonRow, in: stack)

        presentAddWorkspaceWindow(hosting: stack)

        createButton.tag = storeAddWorkspaceFields(
            projectID: project.id, isGitRepo: project.isGitRepo, branchModeSegmented: branchModeSegmented, existingBranchField: existingBranchField,
            newBranchField: newBranchField, baseBranchField: baseBranchField, baseBranchRow: baseRow, notesField: notesField,
            autoNameState: autoNameState, createButton: createButton)
        activeAddWorkspaceFormTag = createButton.tag
        if let refs = addWorkspaceFieldRefs {
            updateAddWorkspaceBranchInputUI(refs: refs)
            updateAddWorkspaceProgressiveDisclosure(refs: refs, branchValue: currentAddWorkspaceBranchValue(refs))
        }
        Task { @MainActor [weak self, weak newBranchField] in
            await Task.yield()
            guard let self else { return }
            self.addWorkspaceWindow?.makeFirstResponder(newBranchField)
        }
        let formTag = createButton.tag
        guard let device = host.deviceRecord(forDeviceID: project.deviceID) else {
            host.showDeviceNotLoadedError()
            return
        }
        Task { @MainActor [weak self, weak baseBranchField, weak existingBranchField] in
            guard let self else { return }
            let result = await Self.deviceWorkspaceCreateOptions(projectID: project.id, device: device).map(\.branchOptions)
            guard activeAddWorkspaceFormTag == formTag else { return }
            guard let baseBranchField else { return }
            guard case .success(let options) = result else { return }
            autoNameState.branchOptions = options
            let currentValue = baseBranchField.stringValue
            baseBranchField.removeAllItems()
            baseBranchField.addItems(withObjectValues: options)
            if !currentValue.isEmpty {
                baseBranchField.stringValue = currentValue
            } else if let defaultBranch = defaultWorkspaceBaseBranch(project: project, branches: options) {
                baseBranchField.stringValue = defaultBranch
            }
            if let existingBranchField {
                let existingValue = existingBranchField.stringValue
                existingBranchField.removeAllItems()
                existingBranchField.addItems(withObjectValues: options)
                if !existingValue.isEmpty { existingBranchField.stringValue = existingValue }
            }
            if let refs = Self.liveFormRefs(self.addWorkspaceFieldRefs, forSenderTag: formTag) {
                self.updateAddWorkspaceProgressiveDisclosure(refs: refs, branchValue: self.currentAddWorkspaceBranchValue(refs))
            }
        }
    }

    private func presentAddWorkspaceWindow(hosting stack: NSStackView) {
        let header = buildFormWindowHeader(
            symbol: "plus.rectangle.on.folder", title: "New Workspace", closeAction: #selector(closeAddWorkspaceWindow), target: self)
        addWorkspaceWindow = host.presentFormWindow(existing: addWorkspaceWindow, header: header, hosting: stack)
    }

    @objc private func closeAddWorkspaceWindow() { addWorkspaceWindow?.performClose(nil) }

    private func defaultWorkspaceBaseBranch(project: ProjectSummary, branches: [String]) -> String? {
        if let configured = project.defaultBranch, !configured.isEmpty { return configured }
        if branches.contains("main") { return "main" }
        if branches.contains("master") { return "master" }
        return branches.first
    }

    private func defaultWorkspaceBaseBranchFast(project: ProjectSummary) -> String? {
        if let configured = project.defaultBranch, !configured.isEmpty { return configured }
        return "main"
    }

    private func addWorkspaceBranchMode(refs: AddWorkspaceFieldRefs) -> AddWorkspaceBranchMode {
        refs.branchModeSegmented?.selectedSegment == 0 ? .create : .existing
    }

    static func resolvedExistingWorkspaceBranchValue(existingBranchField: NSComboBox?) -> String {
        guard let existingBranchField else { return "" }
        if existingBranchField.indexOfSelectedItem >= 0, let selectedValue = existingBranchField.objectValueOfSelectedItem as? String {
            return selectedValue
        }
        return existingBranchField.stringValue
    }

    static func syncExistingWorkspaceBranchSelection(existingBranchField: NSComboBox?) {
        guard let existingBranchField else { return }
        let currentText = existingBranchField.stringValue
        let selectedIndex = existingBranchField.indexOfSelectedItem
        guard selectedIndex >= 0, let selectedValue = existingBranchField.objectValueOfSelectedItem as? String, selectedValue != currentText else {
            return
        }
        existingBranchField.deselectItem(at: selectedIndex)
        existingBranchField.stringValue = currentText
    }

    private func currentAddWorkspaceBranchValue(_ refs: AddWorkspaceFieldRefs) -> String {
        switch addWorkspaceBranchMode(refs: refs) {
        case .existing: Self.resolvedExistingWorkspaceBranchValue(existingBranchField: refs.existingBranchField)
        case .create: refs.newBranchField?.stringValue ?? ""
        }
    }

    private func updateAddWorkspaceBranchInputUI(refs: AddWorkspaceFieldRefs) {
        let isCreatingBranch = addWorkspaceBranchMode(refs: refs) == .create
        refs.existingBranchField?.isHidden = isCreatingBranch
        refs.newBranchField?.isHidden = !isCreatingBranch
        // Base branch is the start point for a branch Spaces creates. Attaching to an existing
        // branch has no start point, so the whole row leaves the form in that mode.
        refs.baseBranchRow?.isHidden = !isCreatingBranch
    }

    private func updateAddWorkspaceProgressiveDisclosure(refs: AddWorkspaceFieldRefs, branchValue: String) {
        guard refs.isGitRepo else { return }
        let hasBranch = !branchValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        refs.createButton.isEnabled = hasBranch
    }

    @objc private func addWorkspaceBranchModeChanged(_ sender: NSSegmentedControl) {
        guard let refs = Self.liveFormRefs(addWorkspaceFieldRefs, forSenderTag: sender.tag) else { return }
        handleAddWorkspaceBranchFieldChange(refs: refs)
        if addWorkspaceBranchMode(refs: refs) == .create {
            host.window.makeFirstResponder(refs.newBranchField)
        } else {
            host.window.makeFirstResponder(refs.existingBranchField)
        }
    }

    @objc private func addWorkspaceBranchFieldChanged(_ sender: NSControl) {
        guard let refs = addWorkspaceFieldRefs, refs.existingBranchField === sender || refs.newBranchField === sender else { return }
        handleAddWorkspaceBranchFieldChange(refs: refs)
    }

    @objc private func createWorkspace(_ sender: NSButton) {
        guard let refs = Self.liveFormRefs(addWorkspaceFieldRefs, forSenderTag: sender.tag) else { return }
        do {
            let mode = addWorkspaceBranchMode(refs: refs)
            // Base branch only names the start point for a branch Spaces creates; attaching to an
            // existing branch checks that branch out directly and sends no base branch.
            let baseBranch = mode == .create ? refs.baseBranchField?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) : nil
            let branch = currentAddWorkspaceBranchValue(refs).trimmingCharacters(in: .whitespacesAndNewlines)
            let notes = refs.notesField?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedNotes: String?
            if let notes, notes.isEmpty { resolvedNotes = nil } else { resolvedNotes = notes }
            if refs.isGitRepo, branch.isEmpty { throw WorkspaceError.invalidArgument(message: "Branch name is required for git projects.") }
            if refs.isGitRepo, mode == .create, baseBranch == nil || baseBranch?.isEmpty == true {
                throw WorkspaceError.invalidArgument(message: "Base branch is required for git projects.")
            }
            if refs.isGitRepo, mode == .create, refs.autoNameState?.branchOptions.contains(branch) == true {
                throw WorkspaceError.invalidArgument(
                    message: "Branch '\(branch)' already exists. Choose it from Existing branch or enter a different new branch name.")
            }
            if let workspaceTargetDeviceID = host.deviceID(forProjectID: refs.projectID),
                let device = host.deviceForMutation(deviceID: workspaceTargetDeviceID)
            {
                let input = WorkspaceCreateInput(
                    projectID: refs.projectID, branch: branch, baseBranch: baseBranch, notes: resolvedNotes, allowRemoteBranchLookup: true,
                    allowExistingBranchReuse: mode == .existing, replaceExistingManagedDirectory: false)
                let originalTitle = sender.title
                sender.isEnabled = false
                sender.title = "Creating..."
                host.showOperationProgressOverlay(
                    message: "Creating workspace...", detail: "Creating the workspace on \(host.deviceDisplayName(id: workspaceTargetDeviceID)).",
                    context: .project(refs.projectID))
                Task { @MainActor [weak self, weak sender] in
                    guard let self else { return }
                    defer {
                        sender?.isEnabled = true
                        sender?.title = originalTitle
                        host.hideOperationProgressOverlay()
                    }
                    let epoch = host.panelCoordinator.paneReplacementEpoch
                    let result = await AppKitController.deviceMutation(device: device) { device in
                        try SpacesDeviceClient.createWorkspace(
                            projectID: input.projectID, branch: input.branch, baseBranch: input.baseBranch, notes: input.notes,
                            allowExistingBranchReuse: input.allowExistingBranchReuse,
                            context: DeviceRequestContext(device: device, clientApp: SpacesDeviceClient.macOSClientApp(appVersion: AppVersion.short)))
                    }
                    switch result {
                    case .success(let response):
                        clearActiveAddFormStateAndCloseWindows()
                        host.selectedProjectID = refs.projectID
                        host.selectedWorkspaceID = response.workspaceID
                        host.lastSelectedRow = -1
                        host.applyDeviceMutationResponse(
                            response, deviceID: device.id, epoch: epoch, selectedProjectID: refs.projectID, selectedWorkspaceID: response.workspaceID)
                    case .failure(let error): host.showError(error)
                    }
                }
                return
            }
            host.showError(host.deviceUnavailableError(deviceID: host.deviceID(forProjectID: refs.projectID)))
        } catch { host.showError(error) }
    }

    private func handleAddWorkspaceBranchFieldChange(refs: AddWorkspaceFieldRefs, branchValueOverride: String? = nil) {
        updateAddWorkspaceBranchInputUI(refs: refs)
        let branchValue = branchValueOverride ?? currentAddWorkspaceBranchValue(refs)
        updateAddWorkspaceProgressiveDisclosure(refs: refs, branchValue: branchValue)
    }

    // MARK: - Shared form plumbing

    private func clearActiveAddProjectFormState() {
        // Nothing is cloned until Create, so tearing down the form only clears its cached state.
        addProjectFieldRefs = nil
        activeAddProjectFormTag = nil
    }

    private func clearActiveAddWorkspaceFormState() {
        addWorkspaceFieldRefs = nil
        activeAddWorkspaceFormTag = nil
    }

    func clearActiveAddFormStateAndCloseWindows() {
        clearActiveAddProjectFormState()
        clearActiveAddWorkspaceFormState()
        closeVisibleAddFormWindows()
        host.flushDeferredSidebarReloadsIfNeeded()
    }

    private func closeVisibleAddFormWindows() {
        if addProjectWindow?.isVisible == true { addProjectWindow?.close() }
        if addWorkspaceWindow?.isVisible == true { addWorkspaceWindow?.close() }
        if projectSettingsWindow?.isVisible == true { projectSettingsWindow?.close() }
    }

    /// Resolves the live field references for a control's action, rejecting stale controls. A control
    /// carries the generation tag of the form it was built for; if that no longer matches the live
    /// form's `formTag` (the form was rebuilt or closed, or `liveRefs` is already nil), the action is
    /// dropped. This replaces the previous global tag-keyed caches now that each dialog is single-instance.
    static func liveFormRefs<Refs: FormGenerationTagged>(_ liveRefs: Refs?, forSenderTag senderTag: Int) -> Refs? {
        guard let liveRefs, liveRefs.formTag == senderTag else { return nil }
        return liveRefs
    }

    private func storeProjectFields(
        projectID: String, setupScriptSection: ScriptSection, stopScriptSection: ScriptSection, portsSection: PortsSection,
        processesSection: ProcessesSection, browserSessionsSection: BrowserSessionsSection, importButton: NSButton, exportButton: NSButton,
        discardImportedConfigButton: NSButton
    ) -> Int {
        let id = projectID.hashValue
        projectSettingsFieldRefs = ProjectFieldRefs(
            formTag: id, projectID: projectID, setupScriptSection: setupScriptSection, stopScriptSection: stopScriptSection,
            portsSection: portsSection, processesSection: processesSection, browserSessionsSection: browserSessionsSection,
            importButton: importButton, exportButton: exportButton, discardImportedConfigButton: discardImportedConfigButton)
        return id
    }

    private func storeAddProjectFields(
        folderRow: ClickableRowView, gitRow: ClickableRowView, folderInputRow: NSView, gitInputRow: NSView, dirField: NSTextField,
        repoURLField: NSTextField, continueButton: NSButton, setupScriptSection: ScriptSection, stopScriptSection: ScriptSection,
        portsSection: PortsSection, processesSection: ProcessesSection, browserSessionsSection: BrowserSessionsSection, createButton: NSButton,
        spacesYAMLMissingLabel: NSTextField
    ) -> Int {
        let id = UUID().uuidString.hashValue
        addProjectFieldRefs = AddProjectFieldRefs(
            formTag: id, folderRow: folderRow, gitRow: gitRow, folderInputRow: folderInputRow, gitInputRow: gitInputRow, dirField: dirField,
            repoURLField: repoURLField, continueButton: continueButton, setupScriptSection: setupScriptSection, stopScriptSection: stopScriptSection,
            portsSection: portsSection, processesSection: processesSection, browserSessionsSection: browserSessionsSection,
            createButton: createButton, spacesYAMLMissingLabel: spacesYAMLMissingLabel)
        continueButton.tag = id
        createButton.tag = id
        return id
    }

    private func storeAddWorkspaceFields(
        projectID: String, isGitRepo: Bool, branchModeSegmented: NSSegmentedControl?, existingBranchField: NSComboBox?, newBranchField: NSTextField?,
        baseBranchField: NSComboBox?, baseBranchRow: NSView?, notesField: NSTextField?, autoNameState: AddWorkspaceAutoNameState?,
        createButton: NSButton
    ) -> Int {
        let id = UUID().uuidString.hashValue
        addWorkspaceFieldRefs = AddWorkspaceFieldRefs(
            formTag: id, projectID: projectID, isGitRepo: isGitRepo, branchModeSegmented: branchModeSegmented,
            existingBranchField: existingBranchField, newBranchField: newBranchField, baseBranchField: baseBranchField, baseBranchRow: baseBranchRow,
            notesField: notesField, autoNameState: autoNameState, createButton: createButton)
        branchModeSegmented?.tag = id
        return id
    }

    // MARK: - Static conversion helpers (form-only paths)

    nonisolated private static func localProjectSettings(from config: SpacesDeviceProjectConfig) -> (
        setupScript: String?, stopScript: String?, ports: [ServiceDefinition], processes: [ProcessTemplate], browserSessions: [BrowserSession]
    ) {
        (
            setupScript: config.setupScript, stopScript: config.stopScript, ports: config.ports.map(AppKitController.localServiceDefinition(from:)),
            processes: config.processes.map(AppKitController.localProcessTemplate(from:)),
            browserSessions: config.browserSessions.map(AppKitController.localBrowserSession(from:))
        )
    }

    private static func deviceProjectConfig(from refs: ProjectFieldRefs) -> SpacesDeviceProjectConfig {
        SpacesDeviceProjectConfig(
            setupScript: refs.setupScriptSection.currentValue.isEmpty ? nil : refs.setupScriptSection.currentValue,
            stopScript: refs.stopScriptSection.currentValue.isEmpty ? nil : refs.stopScriptSection.currentValue,
            ports: refs.portsSection.currentPorts.map(AppKitController.deviceServiceDefinition(from:)),
            processes: refs.processesSection.currentProcesses.map(AppKitController.deviceProcessTemplate(from:)),
            browserSessions: refs.browserSessionsSection.currentSessions.map(AppKitController.deviceBrowserSession(from:)))
    }

    private static func deviceProjectConfig(from refs: AddProjectFieldRefs) -> SpacesDeviceProjectConfig {
        SpacesDeviceProjectConfig(
            setupScript: refs.setupScriptSection.currentValue.isEmpty ? nil : refs.setupScriptSection.currentValue,
            stopScript: refs.stopScriptSection.currentValue.isEmpty ? nil : refs.stopScriptSection.currentValue,
            ports: refs.portsSection.currentPorts.map(AppKitController.deviceServiceDefinition(from:)),
            processes: refs.processesSection.currentProcesses.map(AppKitController.deviceProcessTemplate(from:)),
            browserSessions: refs.browserSessionsSection.currentSessions.map(AppKitController.deviceBrowserSession(from:)))
    }

    // MARK: - Static RPC wrappers (form-only paths)

    nonisolated private static func deviceWorkspaceCreateOptions(projectID: String, device: SpacesPairedDeviceRecord) async -> Result<
        SpacesDeviceWorkspaceCreateOptions, Error
    > {
        await Task.detached(priority: .userInitiated) {
            do {
                return .success(
                    try SpacesDeviceClient.workspaceCreateOptions(
                        selectedProjectID: projectID,
                        context: DeviceRequestContext(device: device, clientApp: SpacesDeviceClient.macOSClientApp(appVersion: AppVersion.short))))
            } catch { return .failure(error) }
        }.value
    }

    nonisolated private static func deviceProjectPreview(dir: String, device: SpacesPairedDeviceRecord) async -> Result<
        SpacesDeviceProjectPreview, Error
    > {
        await Task.detached(priority: .userInitiated) {
            do {
                return .success(
                    try SpacesDeviceClient.previewProject(
                        dir: dir,
                        context: DeviceRequestContext(device: device, clientApp: SpacesDeviceClient.macOSClientApp(appVersion: AppVersion.short))))
            } catch { return .failure(error) }
        }.value
    }

    nonisolated private static func deviceDirectorySuggestions(path: String, device: SpacesPairedDeviceRecord) async -> [String] {
        await Task.detached(priority: .userInitiated) {
            (try? SpacesDeviceClient.listDirectories(
                path: path,
                context: DeviceRequestContext(device: device, clientApp: SpacesDeviceClient.macOSClientApp(appVersion: AppVersion.short)))) ?? []
        }.value
    }

    /// Loads a git repository's `spaces.yaml` (single file, no clone) plus any managed-directory
    /// replacement candidates. Routed through the Device API so the preview runs on the device that
    /// will own the project (local or remote), not always locally.
    nonisolated private static func previewGitProjectResult(gitURL: String, device: SpacesPairedDeviceRecord) async -> Result<
        SpacesDeviceGitProjectPreview, Error
    > {
        await Task.detached(priority: .userInitiated) {
            do {
                return .success(
                    try SpacesDeviceClient.previewGitProject(
                        gitURL: gitURL,
                        context: DeviceRequestContext(device: device, clientApp: SpacesDeviceClient.macOSClientApp(appVersion: AppVersion.short))))
            } catch { return .failure(error) }
        }.value
    }

    // MARK: - Pure decision helpers (form-only paths)

    enum ProjectImportWorkspaceSyncDecision: Equatable, Sendable {
        case updateAllWorkspaces
        case projectOnly
        case cancel
    }

    enum ManagedDirectoryReplacementDecision: Equatable, Sendable {
        case replace
        case cancel
    }

    static func projectImportWorkspaceSyncDecision(for response: NSApplication.ModalResponse) -> ProjectImportWorkspaceSyncDecision {
        switch response {
        case .alertFirstButtonReturn: return .updateAllWorkspaces
        case .alertSecondButtonReturn: return .projectOnly
        default: return .cancel
        }
    }

    static func managedDirectoryReplacementDecision(for response: NSApplication.ModalResponse) -> ManagedDirectoryReplacementDecision {
        response == .alertFirstButtonReturn ? .replace : .cancel
    }

    static func shouldStartManagedDirectoryReplacementFlow(candidateCount: Int, decision: ManagedDirectoryReplacementDecision) -> Bool {
        candidateCount == 0 || decision == .replace
    }

    /// Whether saving a project's settings should sync the template to its workspaces. A non-git
    /// project stands in for its single workspace, so it always syncs (the edits are the config that
    /// runs); a git project syncs only when a pending import chose Update All Workspaces.
    static func projectSaveSyncsAllWorkspaces(isGitRepo: Bool, pendingImportUpdateAllWorkspaces: Bool) -> Bool {
        !isGitRepo || pendingImportUpdateAllWorkspaces
    }

    @discardableResult static func applyProjectImportWorkspaceSyncDecision(_ decision: ProjectImportWorkspaceSyncDecision, to refs: ProjectFieldRefs)
        -> Bool
    {
        switch decision {
        case .updateAllWorkspaces:
            refs.pendingImportUpdateAllWorkspaces = true
            return true
        case .projectOnly:
            refs.pendingImportUpdateAllWorkspaces = false
            return true
        case .cancel: return false
        }
    }
}
