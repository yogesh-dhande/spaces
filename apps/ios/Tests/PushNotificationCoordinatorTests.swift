#if canImport(UIKit)
    import XCTest
    @testable import SpacesMobile

    @MainActor final class PushNotificationCoordinatorTests: XCTestCase {
        private let token = Data([0xAB, 0xCD, 0x01])

        private func makeCoordinator(system: FakePushSystem? = nil, relay: FakePushRelay = FakePushRelay(), environment: PushEnvironment = .sandbox)
            -> PushNotificationCoordinator
        {
            let defaults = UserDefaults(suiteName: "push-coordinator-tests-\(UUID().uuidString)")!
            return PushNotificationCoordinator(
                system: system ?? FakePushSystem(), relay: relay, preferences: PushNotificationPreferences(defaults: defaults),
                environment: environment)
        }

        func testRegistrationSendsTheCapabilityAndTogglesToEveryPairedDevice() async {
            let relay = FakePushRelay()
            let coordinator = makeCoordinator(relay: relay)
            let mac = FakePushEndpoint()
            let linux = FakePushEndpoint()
            coordinator.deviceTokenReceived(token)

            await coordinator.sync(
                installID: "INSTALL-1",
                targets: [PushDeviceTarget(deviceID: "device-mac", endpoint: mac), PushDeviceTarget(deviceID: "device-linux", endpoint: linux)])

            XCTAssertEqual(
                relay.registrations,
                [.init(apnsToken: "abcd01", environment: .sandbox, installID: "INSTALL-1", deviceIDs: ["device-linux", "device-mac"])])
            let expected = FakePushEndpoint.Registration(capability: "capability-1", notifyBlocked: true, notifyFinished: false)
            XCTAssertEqual(mac.registrations, [expected])
            XCTAssertEqual(linux.registrations, [expected])
        }

        func testRegistrationHappensEvenWithBothTogglesOff() async {
            let coordinator = makeCoordinator()
            let device = FakePushEndpoint()
            coordinator.deviceTokenReceived(token)
            coordinator.preferences.notifyBlocked = false
            coordinator.preferences.notifyFinished = false

            await coordinator.sync(installID: "I", targets: [PushDeviceTarget(deviceID: "d", endpoint: device)])

            XCTAssertEqual(device.registrations, [.init(capability: "capability-1", notifyBlocked: false, notifyFinished: false)])
        }

        func testResendingReusesTheCapabilityAndCarriesTheNewToggles() async {
            let relay = FakePushRelay()
            let coordinator = makeCoordinator(relay: relay)
            let device = FakePushEndpoint()
            let targets = [PushDeviceTarget(deviceID: "d", endpoint: device)]
            coordinator.deviceTokenReceived(token)
            await coordinator.sync(installID: "I", targets: targets)

            coordinator.preferences.notifyFinished = true
            await coordinator.sync(installID: "I", targets: targets)

            XCTAssertEqual(relay.registrations.count, 1, "the same token keeps its capability")
            XCTAssertEqual(
                device.registrations.map(\.notifyFinished), [false, true], "every trigger re-sends to the device with the current toggles")
        }

        func testANewTokenAsksTheRelayForANewCapabilityAndResendsIt() async {
            let relay = FakePushRelay()
            let coordinator = makeCoordinator(relay: relay)
            let device = FakePushEndpoint()
            let targets = [PushDeviceTarget(deviceID: "d", endpoint: device)]
            coordinator.deviceTokenReceived(token)
            await coordinator.sync(installID: "I", targets: targets)

            coordinator.deviceTokenReceived(Data([0x09, 0x09]))
            await coordinator.sync(installID: "I", targets: targets)

            XCTAssertEqual(relay.registrations.map(\.apnsToken), ["abcd01", "0909"])
            XCTAssertEqual(device.registrations.map(\.capability), ["capability-1", "capability-2"])
        }

        func testNothingIsSentWithoutPermissionOrAToken() async {
            let relay = FakePushRelay()
            let system = FakePushSystem(status: .denied)
            let coordinator = makeCoordinator(system: system, relay: relay)
            let device = FakePushEndpoint()
            let targets = [PushDeviceTarget(deviceID: "d", endpoint: device)]

            coordinator.deviceTokenReceived(token)
            await coordinator.sync(installID: "I", targets: targets)
            XCTAssertTrue(relay.registrations.isEmpty, "denied permission registers nothing")

            system.status = .authorized
            let tokenless = makeCoordinator(system: system, relay: relay)
            await tokenless.sync(installID: "I", targets: targets)
            XCTAssertTrue(relay.registrations.isEmpty, "no token registers nothing")
            XCTAssertTrue(device.registrations.isEmpty)
        }

        func testARelayFailureIsSilentAndTheNextTriggerRetries() async {
            let relay = FakePushRelay()
            relay.failRegister = true
            let coordinator = makeCoordinator(relay: relay)
            let device = FakePushEndpoint()
            let targets = [PushDeviceTarget(deviceID: "d", endpoint: device)]
            coordinator.deviceTokenReceived(token)

            await coordinator.sync(installID: "I", targets: targets)
            XCTAssertTrue(device.registrations.isEmpty, "no capability, nothing to hand out")

            relay.failRegister = false
            await coordinator.sync(installID: "I", targets: targets)
            XCTAssertEqual(device.registrations.count, 1)
        }

        func testThePermissionIsAskedOnlyAfterPairingAndOnlyOnce() async {
            let system = FakePushSystem(status: .notDetermined)
            let coordinator = makeCoordinator(system: system)

            await coordinator.prepare(askIfNeeded: false)
            XCTAssertEqual(system.permissionRequests, 0, "launching never asks")
            XCTAssertEqual(system.remoteRegistrations, 0)

            await coordinator.prepare(askIfNeeded: true)
            XCTAssertEqual(system.permissionRequests, 1)
            XCTAssertEqual(system.remoteRegistrations, 1, "an allowed permission starts APNs")

            await coordinator.prepare(askIfNeeded: true)
            XCTAssertEqual(system.permissionRequests, 1, "an answered question is not asked again")
        }

        func testADeniedPermissionIsExposedAndNeverRegistersWithAPNs() async {
            let system = FakePushSystem(status: .notDetermined)
            system.grantsPermission = false
            let coordinator = makeCoordinator(system: system)
            XCTAssertFalse(coordinator.isDenied, "before the question is asked the toggles show normally")

            await coordinator.prepare(askIfNeeded: true)

            XCTAssertTrue(coordinator.isDenied)
            XCTAssertEqual(system.remoteRegistrations, 0)
        }

        func testAnEmptyPairedSetIsSentOnceAfterDevicesWereRegisteredEvenWhenNotificationsAreDenied() async {
            let defaults = UserDefaults(suiteName: "push-coordinator-tests-\(UUID().uuidString)")!
            let relay = FakePushRelay()
            let first = PushNotificationCoordinator(
                system: FakePushSystem(), relay: relay, preferences: PushNotificationPreferences(defaults: defaults), environment: .sandbox)
            first.deviceTokenReceived(token)
            await first.sync(installID: "I", targets: [PushDeviceTarget(deviceID: "d", endpoint: FakePushEndpoint())])

            // A later launch: the user has since denied notifications, and the last device is gone.
            let system = FakePushSystem(status: .denied)
            let second = PushNotificationCoordinator(
                system: system, relay: relay, preferences: PushNotificationPreferences(defaults: defaults), environment: .sandbox)
            await second.prepare(askIfNeeded: false)
            XCTAssertEqual(system.remoteRegistrations, 1, "the token is fetched to deliver the empty list")
            second.deviceTokenReceived(token)
            await second.sync(installID: "I", pairedDeviceIDs: [], targets: [])
            await second.sync(installID: "I", pairedDeviceIDs: [], targets: [])

            XCTAssertEqual(relay.registrations.map(\.deviceIDs), [["d"], []], "sent once, then the job is done")
        }

        func testNothingIsRegisteredForAPhoneThatNeverHadADevice() async {
            let relay = FakePushRelay()
            let coordinator = makeCoordinator(relay: relay)
            coordinator.deviceTokenReceived(token)

            await coordinator.sync(installID: "I", pairedDeviceIDs: [], targets: [])

            XCTAssertTrue(relay.registrations.isEmpty)
        }

        func testUnpairingTellsTheDevice() async {
            let coordinator = makeCoordinator()
            let device = FakePushEndpoint()

            await coordinator.unpair(PushDeviceTarget(deviceID: "device-mac", endpoint: device))

            XCTAssertEqual(device.unregisterCount, 1)
        }

        func testTheRelayIsToldTheFullPairedListAndAgainWhenItChanges() async {
            let relay = FakePushRelay()
            let coordinator = makeCoordinator(relay: relay)
            let mac = FakePushEndpoint()
            let linux = FakePushEndpoint()
            let targets = [PushDeviceTarget(deviceID: "device-mac", endpoint: mac), PushDeviceTarget(deviceID: "device-linux", endpoint: linux)]
            coordinator.deviceTokenReceived(token)

            await coordinator.sync(installID: "I", pairedDeviceIDs: ["device-mac", "device-linux"], targets: targets)
            await coordinator.sync(installID: "I", pairedDeviceIDs: ["device-linux", "device-mac"], targets: targets)
            XCTAssertEqual(relay.registrations.map(\.deviceIDs), [["device-linux", "device-mac"]], "an unchanged list is not sent again")

            await coordinator.sync(installID: "I", pairedDeviceIDs: ["device-mac"], targets: [targets[0]])

            XCTAssertEqual(relay.registrations.map(\.deviceIDs), [["device-linux", "device-mac"], ["device-mac"]])
            XCTAssertEqual(mac.registrations.last?.capability, "capability-2")
        }

        func testAnUncredentialedDeviceIsStillOnTheRelaysPairedList() async {
            let relay = FakePushRelay()
            let coordinator = makeCoordinator(relay: relay)
            let mac = FakePushEndpoint()
            coordinator.deviceTokenReceived(token)

            await coordinator.sync(
                installID: "I", pairedDeviceIDs: ["device-mac", "device-no-token"], targets: [PushDeviceTarget(deviceID: "device-mac", endpoint: mac)]
            )

            XCTAssertEqual(relay.registrations.map(\.deviceIDs), [["device-mac", "device-no-token"]])
        }

        func testANewlyPairedDeviceIsAllowedByTheRelayBeforeItIsToldAnything() async {
            let log = PushEventLog()
            let coordinator = makeCoordinator(relay: FakePushRelay(log: log))
            let mac = FakePushEndpoint(name: "mac", log: log)
            let linux = FakePushEndpoint(name: "linux", log: log)
            coordinator.deviceTokenReceived(token)
            await coordinator.sync(
                installID: "I", pairedDeviceIDs: ["device-mac"], targets: [PushDeviceTarget(deviceID: "device-mac", endpoint: mac)])

            await coordinator.sync(
                installID: "I", pairedDeviceIDs: ["device-linux", "device-mac"],
                targets: [PushDeviceTarget(deviceID: "device-mac", endpoint: mac), PushDeviceTarget(deviceID: "device-linux", endpoint: linux)])

            let events = log.events
            let relayIndex = events.lastIndex(of: "relay.register device-linux,device-mac")
            XCTAssertNotNil(relayIndex)
            XCTAssertEqual(events.firstIndex(of: "linux.register").map { $0 > relayIndex! }, true)
        }

        func testARelayFailureOnAChangedListKeepsTheNewDeviceUntold() async {
            let relay = FakePushRelay()
            let coordinator = makeCoordinator(relay: relay)
            let mac = FakePushEndpoint()
            let linux = FakePushEndpoint()
            coordinator.deviceTokenReceived(token)
            await coordinator.sync(
                installID: "I", pairedDeviceIDs: ["device-mac"], targets: [PushDeviceTarget(deviceID: "device-mac", endpoint: mac)])

            relay.failRegister = true
            await coordinator.sync(
                installID: "I", pairedDeviceIDs: ["device-linux", "device-mac"],
                targets: [PushDeviceTarget(deviceID: "device-mac", endpoint: mac), PushDeviceTarget(deviceID: "device-linux", endpoint: linux)])
            XCTAssertTrue(linux.registrations.isEmpty, "the relay would refuse its first report, and the device would drop the registration")

            relay.failRegister = false
            await coordinator.sync(
                installID: "I", pairedDeviceIDs: ["device-linux", "device-mac"],
                targets: [PushDeviceTarget(deviceID: "device-mac", endpoint: mac), PushDeviceTarget(deviceID: "device-linux", endpoint: linux)])
            XCTAssertEqual(linux.registrations.count, 1)
        }

        func testTogglesPersistAndDefaultBlockedOnFinishedOff() {
            let defaults = UserDefaults(suiteName: "push-prefs-tests-\(UUID().uuidString)")!
            let first = PushNotificationPreferences(defaults: defaults)
            XCTAssertTrue(first.notifyBlocked)
            XCTAssertFalse(first.notifyFinished)

            first.notifyBlocked = false
            first.notifyFinished = true

            let second = PushNotificationPreferences(defaults: defaults)
            XCTAssertFalse(second.notifyBlocked)
            XCTAssertTrue(second.notifyFinished)
        }
    }
#endif

#if canImport(UIKit)
    import XCTest
    @testable import SpacesMobile

    final class PushEnvironmentTests: XCTestCase {
        /// A provisioning profile is a CMS envelope: binary framing around the XML plist.
        private func profile(apsEnvironment: String?) -> Data {
            let entitlements = apsEnvironment.map { "<key>aps-environment</key><string>\($0)</string>" } ?? ""
            let xml = """
                <?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>Name</key><string>Spaces</string>\
                <key>Entitlements</key><dict>\(entitlements)</dict></dict></plist>
                """
            return Data([0x30, 0x82, 0x0A, 0x01, 0x06, 0x09]) + Data(xml.utf8) + Data([0x31, 0x82, 0x00, 0xFF])
        }

        func testADevelopmentProfileIsSandbox() {
            XCTAssertEqual(PushEnvironment.environment(provisioningProfile: profile(apsEnvironment: "development")), .sandbox)
        }

        func testAProductionProfileIsProduction() {
            XCTAssertEqual(PushEnvironment.environment(provisioningProfile: profile(apsEnvironment: "production")), .production)
        }

        func testAProfileWithoutAPushEnvironmentOrAnXMLPlistReadsNothing() {
            XCTAssertNil(PushEnvironment.environment(provisioningProfile: profile(apsEnvironment: nil)))
            XCTAssertNil(PushEnvironment.environment(provisioningProfile: Data([0x30, 0x82, 0x01])))
        }
    }
#endif
