import AppKit
import spacesclientcore
import spacesdevicecore
import workspacecore

/// The requests that change a device's alert state: dismissals, visit reports, and Come Back Later marks.
/// Each goes to the device that owns the alert or row and is answered with that device's refreshed
/// overview, which is applied like any other mutation response. Nothing here changes local state ahead of
/// the answer.
extension AppKitController {
    /// Sends `request` to the device and applies the overview it answers with.
    private func performAlertRequest(
        deviceID: String, _ request: @escaping @Sendable (DeviceRequestContext) throws -> SpacesDeviceAPIResponse
    ) async -> Result<Void, Error> {
        guard let device = deviceForMutation(deviceID: deviceID) else { return .failure(deviceUnavailableError(deviceID: deviceID)) }
        let epoch = panelCoordinator.paneReplacementEpoch
        let result = await Self.deviceMutation(device: device) { device in
            try request(DeviceRequestContext(device: device, clientApp: SpacesDeviceClient.macOSClientApp(appVersion: AppVersion.short)))
        }
        switch result {
        case .success(let response):
            applyDeviceMutationResponse(response, deviceID: device.id, epoch: epoch)
            return .success(())
        case .failure(let error): return .failure(error)
        }
    }

    func dismissAlerts(keys: [String], deviceID: String) async -> Result<Void, Error> {
        await performAlertRequest(deviceID: deviceID) { try SpacesDeviceClient.dismissAlerts(keys: keys, context: $0) }
    }

    func setComeBackLater(rowKind: SpacesDeviceComeBackLaterRowKind, rowID: String, isOn: Bool, deviceID: String) {
        Task { @MainActor [weak self] in
            let result = await self?.performAlertRequest(deviceID: deviceID) {
                try SpacesDeviceClient.setComeBackLater(rowKind: rowKind, rowID: rowID, isOn: isOn, context: $0)
            }
            if case .failure(let error)? = result { self?.showError(error) }
        }
    }

    /// Whether the visit report was taken. A visit is background bookkeeping, so a device that cannot act
    /// or a failed request is not surfaced: the report is simply retried by the next overview apply.
    func sendTerminalVisit(deviceID: String, sessionID: String, focusedForSeconds: TimeInterval, keys: [String]) async -> Bool {
        guard deviceAcceptsDaemonActions(forDeviceID: deviceID) else { return false }
        let result = await performAlertRequest(deviceID: deviceID) {
            try SpacesDeviceClient.visitTerminalSession(sessionID: sessionID, focusedForSeconds: focusedForSeconds, keys: keys, context: $0)
        }
        if case .success = result { return true }
        return false
    }

    func makeTerminalVisitTracker() -> TerminalVisitTracker {
        TerminalVisitTracker(
            now: { Date() },
            schedule: { delay, work in
                let task = Task { @MainActor in
                    try? await Task.sleep(for: .seconds(delay))
                    guard !Task.isCancelled else { return }
                    work()
                }
                return { task.cancel() }
            },
            clearables: { [unowned self] terminal in
                deviceSection(id: terminal.deviceID)?.overview.map { TerminalVisitTracker.clearables(overview: $0, sessionID: terminal.sessionID) }
                    ?? TerminalVisitTracker.Clearables()
            },
            currentFocus: { [unowned self] in visitedTerminalIfActive() },
            sendVisit: { [unowned self] terminal, focusedFor, keys in
                await sendTerminalVisit(
                    deviceID: terminal.deviceID, sessionID: terminal.sessionID, focusedForSeconds: focusedFor, keys: keys.sorted())
            })
    }

    /// Feeds the visit tracker the terminal the key window is showing and whether Spaces is frontmost.
    /// Called wherever either can change (the focused pane of a layout, the key window, the main
    /// window's detail pane, app activation) and from the overview install funnel, which is also what
    /// tells the tracker a new alert arrived.
    func refreshTerminalVisit() {
        terminalVisits.update(focus: visitedTerminalIfActive(), isActive: NSApp.isActive)
    }

    /// The terminal a visit is to: the one in the focused pane of what the key window shows (the pane
    /// the workspace footer or a global window's identity strip names), nil when Spaces is not
    /// frontmost or the key window shows no terminal pane. The one derivation behind both
    /// `refreshTerminalVisit` and the tracker's check when a report is due.
    ///
    /// It is not the first responder: an ended terminal's pane never takes first responder, and a live
    /// terminal's input focus lands asynchronously after the pane is shown, so the first responder
    /// would leave exactly the terminals the user is looking at unvisitable. As a consequence keyboard
    /// focus moving into a sidebar rename field or the notes editor does not end a visit.
    private func visitedTerminalIfActive() -> TerminalVisitTracker.FocusedTerminal? {
        guard NSApp.isActive, let keyWindow = NSApp.keyWindow,
            let scope = Self.visitedPanelScope(
                keyWindowPanelWindowID: panelCoordinator.panelWindowID(forWindow: keyWindow), keyWindowIsMain: keyWindow === window,
                detailPane: detailPane)
        else { return nil }
        return panelCoordinator.briefToggleSessionID(scope: scope).flatMap { sessionID in
            deviceID(forSessionID: sessionID).map { TerminalVisitTracker.FocusedTerminal(deviceID: $0, sessionID: sessionID) }
        }
    }

    /// The panel whose focused pane a visit follows: the key window's own panel when it is a global
    /// panel window, or the workspace panel the main window's detail shows. Nil for every other key
    /// window and for any other detail pane (Alerts, Automations, a compatibility block, the placeholder).
    nonisolated static func visitedPanelScope(keyWindowPanelWindowID: String?, keyWindowIsMain: Bool, detailPane: DetailPane) -> PanelScope? {
        if let keyWindowPanelWindowID { return .globalWindow(panelWindowID: keyWindowPanelWindowID) }
        guard keyWindowIsMain, case .workspace(let workspaceID, let deviceID) = detailPane else { return nil }
        return .workspace(deviceID: deviceID, workspaceID: workspaceID)
    }

    /// The device that owns a terminal session: the device its pane is placed under, or for a pane in a
    /// global window, the device whose overview lists the session.
    func deviceID(forSessionID sessionID: String) -> String? {
        if case .workspace(let deviceID, _)? = panelCoordinator.placement(forSessionID: sessionID)?.scope { return deviceID }
        return deviceModel.deviceSections.first { $0.overview?.sessions.contains { $0.id == sessionID } == true }?.deviceID
    }
}
