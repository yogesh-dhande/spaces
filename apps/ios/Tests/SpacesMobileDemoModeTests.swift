#if canImport(UIKit)
    import XCTest
    import spacesdevicecore
    import spacesterminalcore
    @testable import SpacesMobile

    /// Demo Mode toggle semantics: enabling hides the real paired devices behind the synthetic Demo Mac
    /// without touching the device store or Keychain, disabling restores them, the flag persists across
    /// launches, device-management actions are blocked while on, and a refresh serves the bundled
    /// recording end-to-end through `DemoDeviceBackend`.
    ///
    /// These tests exercise the real `SpacesMobileDeviceStore`/`DemoModeStore` persistence, which live in
    /// `UserDefaults.standard` and the Keychain, so each test clears and reseeds that state.
    @MainActor final class SpacesMobileDemoModeTests: XCTestCase {
        private let devicesKey = "spaces.mobile.paired-devices"
        private let activeDeviceKey = "spaces.mobile.active-device-id"
        private let connectionSettingsKey = "spaces.mobile.connection-settings"
        private let demoModeKey = "spaces.mobile.demo-mode-enabled"

        override func setUp() {
            super.setUp()
            resetPersistedState()
        }

        override func tearDown() {
            resetPersistedState()
            super.tearDown()
        }

        // MARK: - Hide / restore real records

        func testEnablingDemoModeHidesRealRecordsAndDisablingRestoresThem() {
            let seeded = seedRealDevices()
            XCTAssertEqual(seeded.count, 2)
            let realIDs = seeded.map(\.id)
            let realActiveID = UserDefaults.standard.string(forKey: activeDeviceKey)

            let model = SpacesMobileAppModel()
            XCTAssertFalse(model.isDemoModeEnabled)
            XCTAssertEqual(model.pairedDevices.map(\.id).sorted(), realIDs.sorted())

            model.setDemoMode(true)
            XCTAssertTrue(model.isDemoModeEnabled)
            XCTAssertEqual(model.pairedDevices.map(\.id), [SpacesMobileDemoDevice.id])
            XCTAssertEqual(model.activeDeviceID, SpacesMobileDemoDevice.id)
            XCTAssertEqual(model.activeDeviceName, SpacesMobileDemoDevice.name)
            XCTAssertTrue(model.settings.isPaired)

            model.setDemoMode(false)
            XCTAssertFalse(model.isDemoModeEnabled)
            XCTAssertEqual(model.pairedDevices.map(\.id).sorted(), realIDs.sorted())
            XCTAssertEqual(model.activeDeviceID, realActiveID)
        }

        /// Enabling and disabling Demo Mode must not rewrite the paired-device records or the Keychain
        /// tokens: the UserDefaults blob is byte-identical across the cycle and every device's token is
        /// still readable through the store API.
        func testDemoModeCycleLeavesDeviceStoreAndKeychainUntouched() throws {
            let seeded = seedRealDevices()
            let blobBefore = UserDefaults.standard.data(forKey: devicesKey)
            XCTAssertNotNil(blobBefore)

            let model = SpacesMobileAppModel()
            model.setDemoMode(true)

            XCTAssertEqual(UserDefaults.standard.data(forKey: devicesKey), blobBefore, "enabling Demo Mode must not rewrite the paired-device records")
            for device in seeded {
                XCTAssertEqual(SpacesMobileDeviceStore.authToken(deviceID: device.id), expectedToken(for: device))
            }

            model.setDemoMode(false)

            XCTAssertEqual(UserDefaults.standard.data(forKey: devicesKey), blobBefore, "the paired-device records must be byte-identical across the cycle")
            for device in seeded {
                XCTAssertEqual(SpacesMobileDeviceStore.authToken(deviceID: device.id), expectedToken(for: device))
            }
        }

        // MARK: - Persistence across launches

        func testDemoModeFlagPersistsAcrossInitWithRealRecordsIntactOnDisk() throws {
            let seeded = seedRealDevices()
            let blob = UserDefaults.standard.data(forKey: devicesKey)
            DemoModeStore.save(true)

            let model = SpacesMobileAppModel()
            XCTAssertTrue(model.isDemoModeEnabled, "a fresh init with the flag set lands in Demo Mode")
            XCTAssertEqual(model.pairedDevices.map(\.id), [SpacesMobileDemoDevice.id])
            XCTAssertEqual(UserDefaults.standard.data(forKey: devicesKey), blob, "real records stay untouched on disk while launched in Demo Mode")

            // Turning it off with nothing parked reloads the real records straight from the store.
            model.setDemoMode(false)
            XCTAssertFalse(model.isDemoModeEnabled)
            XCTAssertEqual(model.pairedDevices.map(\.id).sorted(), seeded.map(\.id).sorted())
            XCTAssertFalse(DemoModeStore.load())
        }

        // MARK: - Guards while enabled

        func testDeviceManagementActionsAreBlockedWhileDemoModeIsOn() {
            let model = SpacesMobileAppModel()
            model.setDemoMode(true)

            model.selectDevice(id: "device-anything")
            XCTAssertEqual(model.connectionNotice, "Turn off Demo Mode to pair or switch devices.")
            XCTAssertTrue(model.isDemoModeEnabled)
            XCTAssertEqual(model.pairedDevices.map(\.id), [SpacesMobileDemoDevice.id])

            model.connectionNotice = nil
            model.preparePairingLink(URL(string: "spaces://pair?v=3")!)
            XCTAssertEqual(model.connectionNotice, "Turn off Demo Mode to pair or switch devices.")
            XCTAssertNil(model.pendingPairingLink)
            XCTAssertFalse(model.isShowingConnectionSettings)

            model.connectionNotice = nil
            var paired = SpacesMobileConnectionSettings()
            paired.host = "10.0.0.42"
            paired.certificateFingerprint = "SHA256:new"
            paired.authToken = "token-new"
            model.applyConnectionSettings(paired)
            XCTAssertEqual(model.connectionNotice, "Turn off Demo Mode to pair or switch devices.")
            XCTAssertTrue(model.isDemoModeEnabled)
            XCTAssertEqual(model.pairedDevices.map(\.id), [SpacesMobileDemoDevice.id])

            // Removing the synthetic device is the same as turning Demo Mode off.
            model.removeDevice(id: SpacesMobileDemoDevice.id)
            XCTAssertFalse(model.isDemoModeEnabled)
        }

        // MARK: - Refresh through the demo backend

        func testRefreshInDemoModePopulatesOverviewAgentsAndAlertsFromBundle() async {
            let model = SpacesMobileAppModel()
            model.setDemoMode(true)

            await model.refresh()

            XCTAssertNotNil(model.overview, "refresh in Demo Mode should publish the bundled overview")
            XCTAssertNil(model.errorMessage)
            XCTAssertFalse(model.isActiveDeviceBlocked)
            XCTAssertFalse(model.agentGroups.isEmpty, "the demo bundle should surface coding-agent groups")
            XCTAssertFalse(model.attentionGroups.isEmpty, "the demo bundle should surface attention events")
            XCTAssertGreaterThan(model.undismissedAlertCount, 0)
        }

        // MARK: - Helpers

        private func seedRealDevices() -> [SpacesMobilePairedDeviceRecord] {
            _ = SpacesMobileDeviceStore.upsert(settings: realSettings(host: "10.0.0.10", fingerprint: "SHA256:studio", token: "token-studio"), name: "Studio")
            let state = SpacesMobileDeviceStore.upsert(settings: realSettings(host: "10.0.0.11", fingerprint: "SHA256:air", token: "token-air"), name: "Air")
            return state.devices
        }

        private func realSettings(host: String, fingerprint: String, token: String) -> SpacesMobileConnectionSettings {
            var settings = SpacesMobileConnectionSettings()
            settings.host = host
            settings.port = 47_900
            settings.certificateFingerprint = fingerprint
            settings.authToken = token
            return settings
        }

        private func expectedToken(for device: SpacesMobilePairedDeviceRecord) -> String {
            device.name == "Studio" ? "token-studio" : "token-air"
        }

        private func resetPersistedState() {
            for device in SpacesMobileDeviceStore.load(fallbackSettings: SpacesMobileConnectionSettings()).devices {
                _ = SpacesMobileDeviceStore.remove(deviceID: device.id, fallbackSettings: SpacesMobileConnectionSettings())
            }
            let defaults = UserDefaults.standard
            for key in [devicesKey, activeDeviceKey, connectionSettingsKey, demoModeKey] { defaults.removeObject(forKey: key) }
        }
    }
#endif
