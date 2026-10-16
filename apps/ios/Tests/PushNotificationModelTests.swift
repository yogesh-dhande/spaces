#if canImport(UIKit)
    import XCTest
    import spacesdevicecore
    import spacesterminalcore
    @testable import SpacesMobile

    /// The push flow as the app model drives it: which devices are told what, and when, with fake relay,
    /// system, and device endpoints.
    @MainActor final class PushNotificationModelTests: XCTestCase {
        private let system = FakePushSystem()
        private let relay = FakePushRelay()
        private let macEndpoint = FakePushEndpoint()
        private let linuxEndpoint = FakePushEndpoint()

        override func setUp() {
            super.setUp()
            SpacesMobileDeviceStore.saveAuthTokenForTesting("linux-token", deviceID: "device-linux")
        }

        override func tearDown() {
            SpacesMobileDeviceStore.deleteAuthTokenForTesting(deviceID: "device-linux")
            for key in ["spaces.mobile.paired-devices", "spaces.mobile.active-device-id", "spaces.mobile.demo-mode-enabled"] {
                UserDefaults.standard.removeObject(forKey: key)
            }
            super.tearDown()
        }

        private func record(_ id: String) -> SpacesMobilePairedDeviceRecord {
            SpacesMobilePairedDeviceRecord(
                id: id, name: id == "device-mac" ? "MacBook Pro" : "Linux Box", hosts: ["127.0.0.1"], port: 47_847,
                certificateFingerprint: "fp-\(id)", createdAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-01T00:00:00Z", lastSelectedAt: nil)
        }

        private func makeModel(
            overviewBox: OverviewBox? = nil, status: UNAuthorizationStatus = .authorized, pairedBoth: Bool = true, relay: FakePushRelay? = nil,
            linuxEndpoint: FakePushEndpoint? = nil
        ) -> SpacesMobileAppModel {
            let relay = relay ?? self.relay
            let linuxEndpoint = linuxEndpoint ?? self.linuxEndpoint
            system.status = status
            var settings = SpacesMobileConnectionSettings()
            settings.hosts = ["127.0.0.1"]
            settings.authToken = "mac-token"
            settings.certificateFingerprint = "fp-device-mac"
            settings.installationID = "INSTALL-1"
            let client = SpacesDeviceAPIClient(settings: settings) { _ in
                SpacesDeviceAPIResponse(ok: true, message: "ok", result: overviewBox.map { .overview($0.overview) })
            }
            let endpoints = ["fp-device-mac": macEndpoint, "fp-device-linux": linuxEndpoint]
            let coordinator = PushNotificationCoordinator(
                system: system, relay: relay,
                preferences: PushNotificationPreferences(defaults: UserDefaults(suiteName: "push-model-tests-\(UUID().uuidString)")!),
                environment: .sandbox)
            let model = SpacesMobileAppModel(
                settings: settings, bridgeClient: client, pushCoordinator: coordinator,
                makePushEndpoint: { endpoints[$0.settings.certificateFingerprint] ?? FakePushEndpoint() })
            model.pairedDevices = pairedBoth ? [record("device-mac"), record("device-linux")] : [record("device-mac")]
            model.activeDeviceID = "device-mac"
            model.push.deviceTokenReceived(Data([0xAB]))
            return model
        }

        // MARK: Registration

        func testPairingAsksForPermissionThenRegistersWithEveryPairedDevice() async {
            let model = makeModel(status: .notDetermined)

            await model.startPushNotifications()

            XCTAssertEqual(system.permissionRequests, 1)
            XCTAssertEqual(system.remoteRegistrations, 1)
            XCTAssertEqual(
                relay.registrations,
                [.init(apnsToken: "ab", environment: .sandbox, installID: "INSTALL-1", deviceIDs: ["device-linux", "device-mac"])])
            let expected = FakePushEndpoint.Registration(capability: "capability-1", notifyBlocked: true, notifyFinished: false)
            XCTAssertEqual(macEndpoint.registrations, [expected])
            XCTAssertEqual(linuxEndpoint.registrations, [expected])
        }

        func testLaunchWithAnExistingPairingAsksForPermissionOnce() async {
            let model = makeModel(status: .notDetermined)

            await model.startPushNotifications()
            await model.startPushNotifications()

            XCTAssertEqual(system.permissionRequests, 1, "an upgrade with a pairing already in place is asked, and only once")
            XCTAssertEqual(macEndpoint.registrations.count, 2)
            XCTAssertEqual(linuxEndpoint.registrations.count, 2)
        }

        func testLaunchWithoutAPairingNeverAsks() async {
            let model = makeModel(status: .notDetermined)
            model.pairedDevices = []

            await model.startPushNotifications()

            XCTAssertEqual(system.permissionRequests, 0)
        }

        func testTurningOnAToggleBeforeThePermissionWasAskedAsksForIt() async {
            let model = makeModel(status: .notDetermined)

            await model.setNotifyFinished(true)

            XCTAssertEqual(system.permissionRequests, 1)
            XCTAssertEqual(macEndpoint.registrations.last, .init(capability: "capability-1", notifyBlocked: true, notifyFinished: true))
        }

        func testTurningOffAToggleNeverAsks() async {
            let model = makeModel(status: .notDetermined)

            await model.setNotifyBlocked(false)

            XCTAssertEqual(system.permissionRequests, 0)
        }

        func testRemovingTheLastDeviceWhileTheRelayIsDownIsRetriedOnTheNextLaunch() async {
            let data = try? JSONEncoder().encode([record("device-mac")])
            UserDefaults.standard.set(data, forKey: "spaces.mobile.paired-devices")
            let model = makeModel(pairedBoth: false)
            await model.syncPushRegistration()
            relay.failRegister = true

            model.removeDevice(id: "device-mac")
            await waitUntil { model.pairedDevices.isEmpty }
            await model.syncPushRegistration()
            XCTAssertEqual(relay.registrations.map(\.deviceIDs), [["device-mac"]], "the relay was down")

            relay.failRegister = false
            await model.startPushNotifications()
            await model.startPushNotifications()

            XCTAssertEqual(relay.registrations.map(\.deviceIDs), [["device-mac"], []], "the empty list is sent once, then nothing")
        }

        func testChangingEitherToggleResendsToEveryDeviceAndPersists() async {
            let model = makeModel()
            await model.syncPushRegistration()

            await model.setNotifyFinished(true)
            await model.setNotifyBlocked(false)

            XCTAssertEqual(macEndpoint.registrations.map { [$0.notifyBlocked, $0.notifyFinished] }, [[true, false], [true, true], [false, true]])
            XCTAssertEqual(linuxEndpoint.registrations.last, .init(capability: "capability-1", notifyBlocked: false, notifyFinished: true))
            XCTAssertFalse(model.push.preferences.notifyBlocked)
            XCTAssertTrue(model.push.preferences.notifyFinished)
        }

        func testANewTokenResendsANewCapability() async {
            let model = makeModel()
            await model.syncPushRegistration()

            model.push.deviceTokenReceived(Data([0xCD]))
            await model.syncPushRegistration()

            XCTAssertEqual(relay.registrations.map(\.apnsToken), ["ab", "cd"])
            XCTAssertEqual(linuxEndpoint.registrations.map(\.capability), ["capability-1", "capability-2"])
        }

        func testADeviceThatComesBackOnlineIsSentTheRegistrationAgain() async {
            let model = makeModel()
            await model.syncPushRegistration()
            model.setOfflineForTesting(true, deviceID: "device-linux")

            model.setOfflineForTesting(false, deviceID: "device-linux")
            await waitUntil { self.linuxEndpoint.registrations.count == 2 }

            XCTAssertEqual(linuxEndpoint.registrations.count, 2)
        }

        func testADeviceWithoutCredentialsIsNotSentTheRegistration() async {
            SpacesMobileDeviceStore.deleteAuthTokenForTesting(deviceID: "device-linux")
            let model = makeModel()

            await model.syncPushRegistration()

            XCTAssertEqual(macEndpoint.registrations.count, 1)
            XCTAssertTrue(linuxEndpoint.registrations.isEmpty)
        }

        // MARK: Unpairing

        /// `removeDevice` reloads the paired list from the device store, so a test that removes a device
        /// needs the store to hold the same devices the model was given.
        private func seedDeviceStore() {
            let data = try? JSONEncoder().encode([record("device-mac"), record("device-linux")])
            UserDefaults.standard.set(data, forKey: "spaces.mobile.paired-devices")
        }

        func testUnpairingTellsTheDeviceAndReRegistersTheRelayWithoutIt() async {
            seedDeviceStore()
            let model = makeModel()
            await model.syncPushRegistration()

            model.removeDevice(id: "device-linux")
            await waitUntil { self.linuxEndpoint.unregisterCount == 1 && self.relay.registrations.count == 2 }

            XCTAssertEqual(linuxEndpoint.unregisterCount, 1)
            XCTAssertEqual(macEndpoint.unregisterCount, 0)
            XCTAssertEqual(relay.registrations.map(\.deviceIDs), [["device-linux", "device-mac"], ["device-mac"]])
        }

        func testUnpairingAnOfflineDeviceStillDropsItFromTheRelay() async {
            seedDeviceStore()
            let model = makeModel()
            await model.syncPushRegistration()
            model.setOfflineForTesting(true, deviceID: "device-linux")

            model.removeDevice(id: "device-linux")
            await waitUntil { self.relay.registrations.count == 2 }

            XCTAssertEqual(relay.registrations.last?.deviceIDs, ["device-mac"])
        }

        func testPairingRegistersTheNewDeviceWithTheRelayBeforeTellingIt() async {
            let log = PushEventLog()
            let relay = FakePushRelay(log: log)
            let model = makeModel(relay: relay, linuxEndpoint: FakePushEndpoint(name: "linux", log: log))
            model.pairedDevices = [record("device-mac")]
            await model.syncPushRegistration()

            model.pairedDevices = [record("device-mac"), record("device-linux")]
            await model.syncPushRegistration()

            let events = log.events
            let relayIndex = events.lastIndex(of: "relay.register device-linux,device-mac")
            XCTAssertNotNil(relayIndex)
            XCTAssertEqual(events.firstIndex(of: "linux.register").map { $0 > relayIndex! }, true)
        }

        // MARK: Demo Mode

        func testDemoModeNeverAsksRegistersOrSetsTheBadge() async {
            let model = makeModel(status: .notDetermined)
            model.setDemoMode(true)
            defer {
                model.setDemoMode(false)
                DemoModeStore.save(false)
            }

            await model.startPushNotifications()
            await model.syncPushRegistration()
            await model.setNotifyFinished(true)
            await model.syncApplicationBadge()

            XCTAssertEqual(system.permissionRequests, 0)
            XCTAssertEqual(system.remoteRegistrations, 0)
            XCTAssertTrue(relay.registrations.isEmpty)
            XCTAssertTrue(macEndpoint.registrations.isEmpty)
            XCTAssertTrue(system.badges.isEmpty)
        }

        // MARK: Badge and notification tap

        func testTheBadgeMirrorsTheAppsOwnAlertCount() async {
            let model = makeModel()
            model.overview = makeOverview(codingAgentRows: [
                makeAgentRow(id: "a", activityState: .waiting, updatedAt: "2026-01-01T00:10:00Z"),
                makeAgentRow(id: "b", activityState: .done, updatedAt: "2026-01-01T00:20:00Z"),
            ])

            await model.syncApplicationBadge()

            XCTAssertEqual(system.badges, [2])
        }

        func testTheNotificationOpensTheAlertsTab() {
            let model = makeModel()
            model.selectedTab = .settings

            model.openAlertsFromNotification()

            XCTAssertEqual(model.selectedTab, .alerts)
        }

        func testTheNotificationResetsTheAlertsTabToItsListWhetherOrNotItIsSelected() {
            let model = makeModel()
            let before = model.alertsNavigationResetCount
            model.selectedTab = .settings

            model.openAlertsFromNotification()
            XCTAssertEqual(model.alertsNavigationResetCount, before + 1)

            model.openAlertsFromNotification()
            XCTAssertEqual(model.alertsNavigationResetCount, before + 2, "tapping while Alerts is already selected still shows the list")
        }

        // MARK: In-app banner

        final class OverviewBox: @unchecked Sendable {
            private let lock = NSLock()
            private var value: SpacesDeviceOverviewPayload
            init(_ value: SpacesDeviceOverviewPayload) { self.value = value }
            var overview: SpacesDeviceOverviewPayload {
                get { lock.withLock { value } }
                set { lock.withLock { value = newValue } }
            }
        }

        private func overview(waiting ids: [String]) -> SpacesDeviceOverviewPayload {
            let rows = ids.enumerated().map { index, id in
                makeAgentRow(id: id, name: "claude", activityState: .waiting, updatedAt: "2026-01-01T00:\(10 + index):00Z")
            }
            let base = makeOverview(codingAgentRows: rows, sessions: ids.map { id in makeTerminalSession(id: "session-\(id)") })
            return base
        }

        private func makeTerminalSession(id: String) -> SpacesDeviceTerminalSessionSummary {
            SpacesDeviceTerminalSessionSummary(
                id: id, title: "zsh", liveTitle: nil, workingDirectory: "/repo/workspace-feature", shell: "/bin/zsh", command: nil, state: .running,
                backend: .ghosttyEmbedded, lifetimePolicy: .persistent, servicePID: 100, childPID: nil, workspaceID: "workspace-feature",
                workspaceTitle: "feature", projectID: "project-1", projectName: "Project", createdAt: "2026-01-01T00:00:00Z",
                updatedAt: "2026-01-01T00:00:00Z", isControlAvailable: true, isSubscriptionAvailable: true,
                attachmentSnapshot: TerminalSessionAttachmentSnapshot(), bellAt: nil)
        }

        func testLaunchSeedsAndANewWaitingAlertThenRaisesTheBanner() async {
            let box = OverviewBox(overview(waiting: ["old"]))
            let model = makeModel(overviewBox: box, pairedBoth: false)

            await model.refresh()
            XCTAssertNil(model.alertBanner, "alerts that exist at launch never banner")

            box.overview = overview(waiting: ["old", "new"])
            await model.refresh()

            XCTAssertEqual(model.alertBanner?.bannerTitle, "claude needs input")
            XCTAssertEqual(model.alertBanner?.sourceID, "agent:new")
        }

        func testAnAlertInAHiddenWorkspaceAtSeedTimeNeverBannersWhenTheWorkspaceIsShownAgain() async {
            func overview(hiddenIsHidden: Bool, extraWaiting: Bool) -> SpacesDeviceOverviewPayload {
                let hiddenAgent = makeAgentRow(id: "hid", workspaceID: "workspace-hidden", activityState: .waiting, updatedAt: "2026-01-01T00:10:00Z")
                var visibleRows: [SpacesDeviceWorkspaceCodingAgentRow] = []
                if extraWaiting { visibleRows.append(makeAgentRow(id: "new", activityState: .waiting, updatedAt: "2026-01-01T00:20:00Z")) }
                let base = makeOverview(
                    workspaces: [
                        makeWorkspace(id: "workspace-feature", branch: "feature", codingAgentRows: visibleRows),
                        makeWorkspace(id: "workspace-hidden", branch: "hidden", isHidden: hiddenIsHidden, codingAgentRows: [hiddenAgent]),
                    ], sessions: [makeTerminalSession(id: "session-hid"), makeTerminalSession(id: "session-new")])
                return base
            }
            let box = OverviewBox(overview(hiddenIsHidden: true, extraWaiting: false))
            let model = makeModel(overviewBox: box, pairedBoth: false)
            await model.refresh()

            box.overview = overview(hiddenIsHidden: false, extraWaiting: false)
            await model.refresh()
            XCTAssertNil(model.alertBanner, "showing a hidden workspace again never banners what it already held")

            box.overview = overview(hiddenIsHidden: false, extraWaiting: true)
            await model.refresh()
            XCTAssertEqual(model.alertBanner?.sourceID, "agent:new", "a genuinely new alert still banners")
        }

        func testLeavingDemoModeThatWasOnAtLaunchStartsAPNsAndRegisters() async {
            let model = makeModel()
            model.setDemoMode(true)
            defer { DemoModeStore.save(false) }
            XCTAssertEqual(system.remoteRegistrations, 0)

            model.setDemoMode(false)
            await waitUntil { !self.relay.registrations.isEmpty }

            XCTAssertEqual(system.remoteRegistrations, 1, "APNs was never started while Demo Mode was on")
            XCTAssertEqual(relay.registrations.count, 1)
        }

        func testATurnedOffToggleRaisesNoBanner() async {
            let box = OverviewBox(overview(waiting: ["old"]))
            let model = makeModel(overviewBox: box, pairedBoth: false)
            await model.refresh()
            await model.setNotifyBlocked(false)

            box.overview = overview(waiting: ["old", "new"])
            await model.refresh()

            XCTAssertNil(model.alertBanner)
        }

        func testNoBannerForTheTerminalOnScreen() async {
            let box = OverviewBox(overview(waiting: ["old"]))
            let model = makeModel(overviewBox: box, pairedBoth: false)
            await model.refresh()
            model.setActiveTerminalSession("session-new")

            box.overview = overview(waiting: ["old", "new"])
            await model.refresh()

            XCTAssertNil(model.alertBanner)
        }

        func testTappingTheBannerOpensItsTerminalFromTheAlertsTab() async {
            let box = OverviewBox(overview(waiting: ["old"]))
            let model = makeModel(overviewBox: box, pairedBoth: false)
            await model.refresh()
            box.overview = overview(waiting: ["old", "new"])
            await model.refresh()
            model.selectedTab = .spaces

            model.openAlertBanner()

            XCTAssertNil(model.alertBanner)
            XCTAssertEqual(model.selectedTab, .alerts)
            XCTAssertEqual(model.pendingAlertTerminalRoute?.session.id, "session-new")
            XCTAssertEqual(model.pendingAlertTerminalRoute?.deviceID, "device-mac")
        }

        func testDismissingTheBannerClearsIt() async {
            let box = OverviewBox(overview(waiting: ["old"]))
            let model = makeModel(overviewBox: box, pairedBoth: false)
            await model.refresh()
            box.overview = overview(waiting: ["old", "new"])
            await model.refresh()

            model.dismissAlertBanner()

            XCTAssertNil(model.alertBanner)
        }

        func testClosingTheStreamsReseedsSoAlertsFromTheBackgroundNeverBanner() async {
            let box = OverviewBox(overview(waiting: ["old"]))
            let model = makeModel(overviewBox: box, pairedBoth: false)
            await model.refresh()
            model.stopDeviceStreams()

            box.overview = overview(waiting: ["old", "while-away"])
            await model.refresh()

            XCTAssertNil(model.alertBanner)
        }
    }
#endif
