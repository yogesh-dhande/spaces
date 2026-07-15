import Foundation
import Testing
import spacesclientcore
import spacesdeviceapi
import spacesdevicecore
import workspacecore

@testable import spacesterminalcore
@testable import spacesui

/// Exercises the pure/static seams that route `spaces://terminal/…` deep links. The local-vs-remote
/// classification and the remote pane-open request build are exercised without an AppKitController
/// instance, mirroring how the rest of the AppKitController suite tests decision logic; the remote
/// session resolution reuses the `resolveSessionSummaryMatchOffMain` Device API seam (its off-main
/// success case is covered in AppKitControllerDeviceParityTests) so the loud "session not found on
/// device" alert's input is validated here for the miss case.
@Suite struct AppKitControllerTerminalDeepLinkTests {
    private func device(id: String, name: String) -> SpacesPairedDeviceRecord {
        SpacesPairedDeviceRecord(
            id: id, name: name, platform: "linux", host: "10.0.0.4", port: 19000, certificateFingerprint: "fingerprint",
            createdAt: "2026-06-01T00:00:00Z", updatedAt: "2026-06-01T00:00:00Z")
    }

    private func summary(id: String, workspaceID: String) -> SpacesDeviceTerminalSessionSummary {
        SpacesDeviceTerminalSessionSummary(
            id: id, title: "codex", workingDirectory: "/srv/project-feature", shell: "/bin/zsh", command: "codex", state: .running,
            backend: .ghosttyEmbedded, lifetimePolicy: .persistent, servicePID: 4321, childPID: 5678, workspaceID: workspaceID,
            workspaceTitle: "Feature", projectID: "project-1", projectName: "Project", createdAt: "2026-06-22T12:00:00Z",
            updatedAt: "2026-06-22T12:00:05Z", isControlAvailable: true, isSubscriptionAvailable: true,
            attachmentSnapshot: TerminalSessionAttachmentSnapshot(), rowKind: .agent)
    }

    // MARK: - Local vs remote classification

    @Test func deepLinkWithoutDeviceTargetsLocal() {
        #expect(
            AppKitController.terminalDeepLinkTarget(for: SpacesTerminalDeepLink(sessionID: "session-1"))
                == .local(sessionID: "session-1"))
    }

    @Test func deepLinkWithLocalDeviceIDTargetsLocal() {
        #expect(
            AppKitController.terminalDeepLinkTarget(
                for: SpacesTerminalDeepLink(sessionID: "session-1", deviceID: SpacesPairedDeviceRecord.localDeviceID))
                == .local(sessionID: "session-1"))
    }

    @Test func deepLinkWithOtherDeviceIDTargetsRemote() {
        #expect(
            AppKitController.terminalDeepLinkTarget(for: SpacesTerminalDeepLink(sessionID: "session-1", deviceID: "linux-box"))
                == .remote(sessionID: "session-1", deviceID: "linux-box"))
    }

    // MARK: - Remote pane-open request

    @Test func remotePaneOpenRequestPinsOwningDeviceAndCarriesSessionMetadata() {
        let device = device(id: "linux-box", name: "Build Box")
        let summary = summary(id: "session-remote", workspaceID: "workspace-remote")

        let request = AppKitController.terminalSessionPaneOpenRequest(
            from: AppKitController.TerminalSessionSummaryMatch(device: device, summary: summary))

        // The device is pinned so the pane attaches to the remote device rather than resolving the
        // (possibly-unloaded) workspace's device, which would fall back to local.
        #expect(request.deviceID == "linux-box")
        #expect(request.sessionID == "session-remote")
        #expect(request.workspaceID == "workspace-remote")
        #expect(request.title == "codex")
        #expect(request.workingDirectory == "/srv/project-feature")
        #expect(request.kind == .agent)
        #expect(request.shell == "/bin/zsh")
        #expect(request.command == "codex")
        #expect(request.initialState == .running)
        #expect(request.servicePID == 4321)
        #expect(request.childPID == 5678)
        #expect(request.createdAt == "2026-06-22T12:00:00Z")
        #expect(request.updatedAt == "2026-06-22T12:00:05Z")
        #expect(request.preparedCredentials == nil)
    }

    // MARK: - Remote session resolution seam

    @Test func remoteSessionResolutionReturnsNilWhenDeviceLacksSession() async {
        let device = device(id: "linux-box", name: "Build Box")
        let clientApp = SpacesDeviceClientApp(
            installationID: "install", bundleID: "com.example.Spaces", platform: "macos", deviceName: "Mac", appVersion: "1.0")

        // The device's overview carries a different session, so a query for the deep link's session id
        // misses — the input that drives the "session not found on device" loud alert.
        let match = await AppKitController.resolveSessionSummaryMatchOffMain(
            sessionID: "session-missing", device: device, clientApp: clientApp,
            resolveOverview: { device, _ in
                SpacesDeviceOverviewResolution(
                    overview: SpacesDeviceOverview(
                        device: device, overview: SpacesDeviceOverviewPayload(workspaces: [], sessions: [summary(id: "other", workspaceID: "ws")])),
                    daemonStatus: nil, compatibility: nil)
            })

        #expect(match == nil)
    }
}
