import AppKit
import Foundation
import spacesclientcore
import spacesdevicecore
import workspacecore

/// Asks a device to replace a shell it lost when a pane for that shell is first shown.
///
/// The answer's overview goes through the usual mutation path, so `TerminalSessionReplacementDiff`
/// retargets the pane in place (tab, split position and window) and, because the diff runs on every
/// authoritative overview, does the same for any other client of the device that did not send the request.
/// Nothing is drawn on success. A missing working directory is the one refusal the pane reports.
@MainActor final class LostShellResumeController {
    private unowned let host: AppKitController
    private var requests = LostShellResumeRequests()

    init(host: AppKitController) { self.host = host }

    /// Called when a device's overview installs. Panes restored at launch are shown before the device has
    /// reported the lost session, so the overview that first lists it is when they can be judged.
    func overviewInstalled(deviceID: String) {
        for sessionID in host.panelCoordinator.visibleTerminalSessionIDs(deviceID: deviceID) { paneShown(deviceID: deviceID, sessionID: sessionID) }
        // The overview can also show that a failed session was never going to be asked about.
        host.panelCoordinator.lostShellResumeHoldDidChange(deviceID: deviceID)
    }

    /// Called when a terminal pane becomes visible. Sends at most one request per session per launch.
    func paneShown(deviceID: String, sessionID: String) {
        // The device is resolved before the claim: an offline device sends nothing, and a session claimed
        // for a send that never happened would stay unasked-about for the whole launch.
        guard let device = host.deviceForMutation(deviceID: deviceID),
            requests.claim(sessionID: sessionID, overview: host.deviceSection(id: deviceID)?.overview)
        else { return }
        let epoch = host.panelCoordinator.paneReplacementEpoch
        Task { @MainActor [weak self] in
            let result = await AppKitController.deviceMutation(device: device) { device in
                try SpacesDeviceClient.resumeLostShell(
                    sessionID: sessionID,
                    context: DeviceRequestContext(device: device, clientApp: SpacesDeviceClient.macOSClientApp(appVersion: AppVersion.short)))
            }
            guard let self else { return }
            switch result {
            case .success(let response):
                // The pane has followed the replacement by the time the hold ends.
                host.applyDeviceMutationResponse(response, deviceID: deviceID, epoch: epoch)
                requests.finish(sessionID: sessionID)
            case .failure(let error):
                // A restore offer holds the shell for as long as it is open, so the pane shows its failed
                // state meanwhile instead of waiting out the offer.
                if LostShellResumeRequests.isRestorePending(error) {
                    requests.release(sessionID: sessionID)
                } else {
                    requests.finish(sessionID: sessionID)
                }
                if LostShellResumeRequests.isFolderMissing(error) { host.panelCoordinator.showLostShellFolderMissing(sessionID: sessionID) }
            }
            host.panelCoordinator.lostShellResumeHoldDidChange(deviceID: deviceID)
        }
    }

    /// Whether a failed session's pane keeps its previous presentation: its request is in flight or would
    /// be sent once the overview says so (`LostShellResumeRequests.holdsFailedState`). An unreachable
    /// device never answers, so it holds nothing.
    func holdsFailedState(deviceID: String, sessionID: String) -> Bool {
        guard host.deviceForMutation(deviceID: deviceID) != nil else { return false }
        return requests.holdsFailedState(sessionID: sessionID, overview: host.deviceSection(id: deviceID)?.overview)
    }
}
