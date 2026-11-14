import AppKit
import Foundation
import spacesclientcore
import spacesdevicecore
import workspacecore

/// Owns the Prompts pane and the merged prompt library behind it, the sidebar count, and the command
/// palette's Prompts section.
///
/// Each device keeps its own prompts; the library holds the slice of every reachable device. The host calls
/// `reconcileDevices()` whenever an overview is installed, and a device whose overview reports a newer
/// prompt revision than its slice is fetched again. The library is kept whether or not the pane is open
/// because the sidebar count and the palette read it too.
///
/// The open draft belongs to the model, not to the pane's views: leaving the pane drops the views and
/// keeps the draft, so coming back restores what was being typed. Only moves the user makes inside the
/// pane, or through the sidebar, stop to ask what to do with unsaved edits.
@MainActor final class SavedPromptsController: NSObject {
    unowned let host: AppKitController

    init(host: AppKitController) {
        self.host = host
        super.init()
    }

    private struct ReachableDevice {
        let device: SavedPromptLibrary.Device
        let record: SpacesPairedDeviceRecord
    }

    private static let copiedFlashSeconds = 1.2
    private static let ageRefreshSeconds = 30.0

    private var library = SavedPromptLibrary()
    private var reachable: [ReachableDevice] = []
    private var model = SavedPromptsPaneModel()
    private var pane: SavedPromptsPaneView?
    private var isSaving = false
    private var copiedFlashTasks: [String: Task<Void, Never>] = [:]
    private var ageRefreshTask: Task<Void, Never>?

    var hasUnsavedEdits: Bool { model.hasUnsavedEdits }

    // MARK: - Library

    /// Brings the library in line with the host's devices. Cheap enough to run on every overview install:
    /// it fetches only the devices whose prompt revision moved, and repaints only when something changed.
    func reconcileDevices() {
        reachable = reachableDevices()
        let before = library
        let idsToFetch = library.reconcile(reachable: reachable.map(\.device))
        for id in idsToFetch {
            guard let record = reachable.first(where: { $0.device.id == id })?.record else { continue }
            fetch(deviceID: id, record: record)
        }
        if library != before { libraryDidChange() }
    }

    /// A loaded device section proves its credentials work (the overview that loaded it needed them), so
    /// a device is reachable exactly when its section is loaded and its daemon speaks a compatible wire
    /// version. An offline device's prompts are hidden rather than listed stale: they could not be copied
    /// from or edited anyway.
    private func reachableDevices() -> [ReachableDevice] {
        host.deviceModel.deviceSections.compactMap { section in
            guard section.loadState == .loaded, host.deviceCompatibility(forDeviceID: section.deviceID)?.isCompatible != false,
                let record = host.automationDeviceRecord(deviceID: section.deviceID)
            else { return nil }
            return ReachableDevice(
                device: SavedPromptLibrary.Device(
                    id: section.deviceID, name: section.isLocal ? ResourcesController.localDeviceTitle : section.deviceName,
                    overviewRevision: section.overview?.savedPromptsRevision ?? 0), record: record)
        }
    }

    private func requestContext(for record: SpacesPairedDeviceRecord) -> DeviceRequestContext {
        DeviceRequestContext(device: record, clientApp: SpacesDeviceClient.macOSClientApp(appVersion: AppVersion.short))
    }

    private func fetch(deviceID: String, record: SpacesPairedDeviceRecord) {
        let context = requestContext(for: record)
        Task { @MainActor [weak self] in
            let result = await Task.detached(priority: .userInitiated) { Result { try SpacesDeviceClient.listSavedPrompts(context: context) } }.value
            guard let self else { return }
            switch result {
            case .success(let prompts):
                library.apply(prompts, deviceID: deviceID)
                libraryDidChange()
                // An overview that advertised a newer revision while this fetch was in flight started no
                // fetch of its own, so the response may already be behind.
                reconcileDevices()
            case .failure:
                // The next overview install runs `reconcileDevices` again, which retries the fetch.
                library.fetchFailed(deviceID: deviceID)
            }
        }
    }

    private func libraryDidChange() {
        model.libraryChanged(entries: library.entries(matching: ""))
        host.sidebar.updatePromptsSidebarRow(count: library.count)
        if host.showingPrompts { render() }
        host.commandPalette.refreshPromptMatches()
    }

    /// The palette's Prompts section for a query.
    func paletteMatches(for query: String) -> [SavedPromptLibrary.Entry] { CommandPaletteRows.promptEntries(in: library, query: query) }

    // MARK: - Presentation

    /// Presents the pane, or when it is already showing, redraws it against the current library. Navigation
    /// cleanup runs only on entry: the host re-invokes this on every device update, and a background refresh
    /// must never close a form the user is filling in.
    func showPromptsDetail() {
        if !host.showingPrompts {
            host.projectForms.clearActiveAddFormStateAndCloseWindows()
            host.stopWorkspaceSetupDetailRefreshTimer()
            host.presentDetailPane(.prompts)
            host.showingSettings = false
            let previousProjectID = host.selectedProjectID
            let previousWorkspaceID = host.selectedWorkspaceID
            host.selectedProjectID = nil
            host.selectedWorkspaceID = nil
            host.outlineView.deselectAll(nil)
            host.refreshSidebarSelectionRows(
                previousProjectID: previousProjectID, currentProjectID: nil, previousWorkspaceID: previousWorkspaceID, currentWorkspaceID: nil)
            host.updateAlertsRowAppearance()
        }
        if pane == nil {
            reachable = reachableDevices()
            installPane()
            startAgeRefresh()
        }
        render()
    }

    /// Another pane replaced this one. The views go; the draft stays, so returning restores it.
    func paneDidHide() {
        ageRefreshTask?.cancel()
        ageRefreshTask = nil
        pane = nil
    }

    private func installPane() {
        host.clearWorkspaceDetailFooter()
        for view in host.detailContainer.subviews { view.removeFromSuperview() }
        host.detailContainer.wantsLayer = true
        bindAppearanceReactiveLayer(host.detailContainer) { [unowned host] view in
            view.layer?.backgroundColor = host.sidebar.sidebarPanelBackgroundColor().cgColor
        }
        let pane = SavedPromptsPaneView(query: model.query, editorActions: editorActions())
        pane.onSearchChange = { [weak self] query in
            self?.model.query = query
            self?.render()
        }
        pane.onNewPrompt = { [weak self] in
            guard let self, let deviceID = defaultNewPromptDeviceID() else { return }
            request(.beginNew(deviceID: deviceID))
        }
        pane.onRowClick = { [weak self] key in
            guard let self else { return }
            if let entry = library.entries(matching: "").first(where: { $0.id == key }) { request(.select(entry)) } else { request(.collapse) }
        }
        pane.onRowCopy = { [weak self] key in
            guard let self else { return }
            // The open row copies the editor's text, which may differ from the saved prompt's.
            if model.draft?.key == key {
                copyDraft()
            } else if let entry = library.entries(matching: "").first(where: { $0.id == key }) {
                copy(entry: entry, text: entry.prompt.text)
                flashCopied(key)
            }
        }
        showScrollableDetailStack(pane.stack, in: host.detailContainer)
        self.pane = pane
    }

    private func editorActions() -> SavedPromptEditorActions {
        SavedPromptEditorActions(
            titleChanged: { [weak self] in
                self?.model.setTitle($0)
                self?.render()
            },
            textChanged: { [weak self] in
                self?.model.setText($0)
                self?.render()
            },
            deviceChosen: { [weak self] in
                self?.model.setDevice($0)
                self?.render()
            }, save: { [weak self] in self?.save() },
            discard: { [weak self] in
                guard let self else { return }
                model.discardDraft(entries: library.entries(matching: ""))
                render()
            }, delete: { [weak self] in self?.request(.delete) }, escape: { [weak self] in self?.request(.collapse) })
    }

    /// Keeps the Used column's ages current while the pane is on screen.
    private func startAgeRefresh() {
        ageRefreshTask?.cancel()
        ageRefreshTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.ageRefreshSeconds))
                guard !Task.isCancelled else { return }
                self?.render()
            }
        }
    }

    private func render() {
        guard let pane else { return }
        let showsDevices = SavedPromptsPaneModel.showsDeviceChoices(pairedDeviceCount: host.deviceModel.deviceSections.count)
        let rows = currentRows(showsDevices: showsDevices)
        let emptyMessage: String? =
            rows.isEmpty
            ? (model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "No saved prompts. New Prompt saves one you can copy into any terminal." : "No matching prompts") : nil
        pane.render(
            rows: rows, showsDeviceColumn: showsDevices, canCreate: !reachable.isEmpty, emptyMessage: emptyMessage,
            editorState: model.draft.map { ($0.key, editorState(for: $0, showsDevices: showsDevices)) })
    }

    private func currentRows(showsDevices: Bool) -> [SavedPromptsPaneModel.Row] {
        model.renderPlan(
            filtered: library.entries(matching: model.query), all: library.entries(matching: ""),
            deviceNameForDraft: model.draft.flatMap { deviceName(for: $0.deviceID) }, showsDeviceColumn: showsDevices, now: Date())
    }

    private func editorState(for draft: SavedPromptDraft, showsDevices: Bool) -> SavedPromptEditorState {
        SavedPromptEditorState(
            title: draft.title, text: draft.text, isNew: draft.isNew, isDirty: draft.isDirty, error: draft.error,
            deviceChoices: draft.isNew && showsDevices ? reachable.map { .init(id: $0.device.id, name: $0.device.name) } : [],
            selectedDeviceID: draft.deviceID)
    }

    private func deviceName(for deviceID: String) -> String? {
        host.deviceModel.deviceSections.first(where: { $0.deviceID == deviceID }).map {
            $0.isLocal ? ResourcesController.localDeviceTitle : $0.deviceName
        }
    }

    private func defaultNewPromptDeviceID() -> String? {
        SavedPromptsPaneModel.defaultDeviceID(reachableDeviceIDs: reachable.map(\.device.id), localDeviceID: host.deviceModel.localDeviceID)
    }

    // MARK: - Leaving a prompt

    /// Runs `proceed` once the open draft's unsaved edits are settled: at once when there are none or the
    /// pane is not showing (the draft is then kept for the return), otherwise after Save or Discard.
    /// Cancel drops `proceed`.
    func confirmLeaving(proceed: @escaping @MainActor () -> Void) {
        guard host.showingPrompts, model.hasUnsavedEdits else {
            proceed()
            return
        }
        settleUnsavedEdits(then: proceed)
    }

    private func settleUnsavedEdits(then proceed: @escaping @MainActor () -> Void) {
        guard let draft = model.draft else {
            proceed()
            return
        }
        switch SavedPromptUnsavedConfirmation(promptTitle: draft.title, isNew: draft.isNew).run() {
        case .cancel: return
        case .discard:
            model.discardDraft(entries: library.entries(matching: ""))
            render()
            proceed()
        case .save: save { saved in if saved { proceed() } }
        }
    }

    /// Applies a move inside the pane. Unsaved edits are settled first, and the move is then repeated.
    private func request(_ action: SavedPromptsPaneAction) {
        switch model.attempt(action) {
        case .needsUnsavedDecision: settleUnsavedEdits { [weak self] in self?.request(action) }
        case .applied: if case .delete = action { confirmAndDelete() } else { render() }
        }
    }

    // MARK: - Save and delete

    private func save(then completion: (@MainActor (Bool) -> Void)? = nil) {
        guard !isSaving, let draft = model.draft else {
            completion?(false)
            return
        }
        if let message = draft.validationError {
            fail(message, completion)
            return
        }
        guard let record = host.deviceForMutation(deviceID: draft.deviceID) else {
            fail("That device is not reachable right now.", completion)
            return
        }
        isSaving = true
        let context = requestContext(for: record)
        let (deviceID, promptID, title, text) = (draft.deviceID, draft.promptID, draft.title, draft.text)
        Task { @MainActor [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                Result {
                    if let promptID {
                        try SpacesDeviceClient.updateSavedPrompt(id: promptID, title: title, text: text, context: context)
                    } else {
                        try SpacesDeviceClient.createSavedPrompt(title: title, text: text, context: context)
                    }
                }
            }.value
            guard let self else { return }
            isSaving = false
            switch result {
            case .success(let result):
                library.apply(result, deviceID: deviceID)
                if let promptID {
                    model.saveSucceeded(promptID: promptID, deviceID: deviceID, title: title, text: text)
                } else {
                    model.createSucceeded(
                        created: result.prompts.first { $0.id == result.createdPromptID }, deviceID: deviceID, title: title, text: text)
                }
                libraryDidChange()
                completion?(true)
            case .failure(let error):
                if model.isOpen(promptID: promptID, deviceID: deviceID) { fail(error.localizedDescription, completion) } else { completion?(false) }
            }
        }
    }

    private func fail(_ message: String, _ completion: (@MainActor (Bool) -> Void)?) {
        model.setError(message)
        render()
        completion?(false)
    }

    private func confirmAndDelete() {
        guard let draft = model.draft, let promptID = draft.promptID else { return }
        let deviceName = deviceName(for: draft.deviceID) ?? "this device"
        guard SavedPromptDeleteConfirmation(promptTitle: draft.originalTitle, deviceName: deviceName).run() else { return }
        guard let record = host.deviceForMutation(deviceID: draft.deviceID) else {
            fail("That device is not reachable right now.", nil)
            return
        }
        let context = requestContext(for: record)
        let deviceID = draft.deviceID
        Task { @MainActor [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                Result { try SpacesDeviceClient.deleteSavedPrompt(id: promptID, context: context) }
            }.value
            guard let self else { return }
            switch result {
            case .success(let prompts):
                library.apply(prompts, deviceID: deviceID)
                model.closeDraft(promptID: promptID, deviceID: deviceID)
                libraryDidChange()
            case .failure(let error): if model.isOpen(promptID: promptID, deviceID: deviceID) { fail(error.localizedDescription, nil) }
            }
        }
    }

    // MARK: - Copy

    /// Copies the open editor's current text, edited or not, and counts it as a use of the saved prompt.
    private func copyDraft() {
        guard let draft = model.draft else { return }
        if let entry = library.entries(matching: "").first(where: { $0.id == draft.key }) {
            copy(entry: entry, text: draft.text)
        } else {
            writeToPasteboard(draft.text)
        }
        flashCopied(draft.key)
    }

    /// Puts `text` on the pasteboard and records the prompt as just used, which moves it to the top.
    func copy(entry: SavedPromptLibrary.Entry, text: String) {
        writeToPasteboard(text)
        recordUse(of: entry)
    }

    private func writeToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// A failure is silent: the copy already worked, and the use only reorders the list.
    private func recordUse(of entry: SavedPromptLibrary.Entry) {
        guard let record = host.deviceForMutation(deviceID: entry.deviceID) else { return }
        let context = requestContext(for: record)
        let (deviceID, promptID) = (entry.deviceID, entry.prompt.id)
        Task { @MainActor [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                Result { try SpacesDeviceClient.recordSavedPromptUse(id: promptID, context: context) }
            }.value
            guard let self, case .success(let prompts) = result else { return }
            library.apply(prompts, deviceID: deviceID)
            libraryDidChange()
        }
    }

    private func flashCopied(_ key: String) {
        model.markCopied(key)
        render()
        copiedFlashTasks[key]?.cancel()
        copiedFlashTasks[key] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.copiedFlashSeconds))
            guard !Task.isCancelled, let self else { return }
            copiedFlashTasks[key] = nil
            model.clearCopied(key)
            render()
        }
    }
}
