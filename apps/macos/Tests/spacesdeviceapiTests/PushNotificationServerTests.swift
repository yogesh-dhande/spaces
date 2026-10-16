#if canImport(Network) && canImport(Security)
    import Foundation
    import XCTest
    import workspacecore

    @testable import spacesdeviceapi
    @testable import spacesdevicecore
    @testable import spacesterminalcore

    /// Device API server coverage for push notifications: which callers may register, where the registration
    /// lands, what unregistering tells the relay, and that a committed overview reaches the notifier even when
    /// no client streams.
    final class PushNotificationServerTests: XCTestCase {
        private let tlsRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
            "spaces-push-notification-tests-tls-\(UUID().uuidString)", isDirectory: true)

        override func tearDown() {
            try? FileManager.default.removeItem(at: tlsRoot)
            super.tearDown()
        }

        private func phone(_ id: String = "phone-1") -> SpacesDeviceClientApp {
            SpacesDeviceClientApp(
                installationID: id, bundleID: SpacesDeviceFirstPartyPolicy.iosBundleID, platform: "ios", deviceName: "iPhone", appVersion: "1.0")
        }

        func testAPairedPhoneRegistersOnItsOwnRecordAndAMacCannot() throws {
            try withTemporaryProfile {
                let harness = try Harness(tlsRoot: tlsRoot)
                defer { harness.stop() }

                let registered = try harness.send(
                    .registerPushNotifications(.init(capability: "cap-1", notifyBlocked: true, notifyFinished: false)), as: phone())
                XCTAssertTrue(registered.ok, registered.message)
                XCTAssertEqual(
                    try harness.registrations.pushRegistrations(),
                    ["phone-1": SpacesDevicePushRegistration(capability: "cap-1", notifyBlocked: true, notifyFinished: false)])

                // Sending again replaces the stored toggles and capability.
                _ = try harness.send(.registerPushNotifications(.init(capability: "cap-2", notifyBlocked: false, notifyFinished: true)), as: phone())
                XCTAssertEqual(try harness.registrations.pushRegistrations()["phone-1"]?.capability, "cap-2")

                let mac = SpacesDeviceClientApp(
                    installationID: "mac-1", bundleID: SpacesDeviceFirstPartyPolicy.macOSBundleID, platform: "macos", deviceName: "Mac",
                    appVersion: "1.0")
                let rejected = try harness.send(
                    .registerPushNotifications(.init(capability: "cap-mac", notifyBlocked: true, notifyFinished: true)), as: mac)
                XCTAssertFalse(rejected.ok)
                XCTAssertEqual(rejected.errorCode, .invalidArgument)
                XCTAssertNil(try harness.registrations.pushRegistrations()["mac-1"])
            }
        }

        func testUnregisteringClearsTheRecordAndTellsTheRelayOnce() throws {
            try withTemporaryProfile {
                let harness = try Harness(tlsRoot: tlsRoot)
                defer { harness.stop() }
                _ = try harness.send(.registerPushNotifications(.init(capability: "cap-1", notifyBlocked: true, notifyFinished: false)), as: phone())

                let response = try harness.send(.unregisterPushNotifications(.init()), as: phone())
                XCTAssertTrue(response.ok, response.message)
                XCTAssertTrue(try harness.registrations.pushRegistrations().isEmpty)
                XCTAssertEqual(harness.relay.requests, [.unregister(capability: "cap-1", deviceID: harness.relayDeviceID)])

                // Nothing left to unregister: a second call does not reach the relay again.
                _ = try harness.send(.unregisterPushNotifications(.init()), as: phone())
                XCTAssertEqual(harness.relay.requests.count, 1)
            }
        }

        func testACommittedOverviewReachesTheNotifierWhileNoClientStreams() throws {
            try withTemporaryProfile {
                let overview = PushOverviewFixture.overview(agents: [("a", .waiting)])
                let harness = try Harness(tlsRoot: tlsRoot, overview: overview)
                defer { harness.stop() }
                try harness.registrations.setPushRegistration(
                    SpacesDevicePushRegistration(capability: "cap-1", notifyBlocked: true, notifyFinished: false), forInstallationID: "phone-1")

                NotificationCenter.default.post(name: IPCNotification.databaseDidChange, object: nil)
                let seeded = expectation(description: "the first overview is seeded and a resync is waiting on the debounce")
                DispatchQueue.global().async {
                    while harness.scheduler.pendingCount == 0 { Thread.sleep(forTimeInterval: 0.02) }
                    seeded.fulfill()
                }
                wait(for: [seeded], timeout: 10)
                harness.scheduler.advance(by: 1)
                XCTAssertEqual(harness.relay.reports.map(\.total), [1])
                XCTAssertEqual(harness.relay.reports.map(\.blocked), [1])
                XCTAssertEqual(harness.relay.reports.map(\.notify), [false])
            }
        }

        /// An overview the test can swap while the server runs.
        private final class OverviewBox: @unchecked Sendable {
            private let lock = NSLock()
            private var payload: SpacesDeviceOverviewPayload
            init(_ payload: SpacesDeviceOverviewPayload) { self.payload = payload }
            var current: SpacesDeviceOverviewPayload {
                get {
                    lock.lock()
                    defer { lock.unlock() }
                    return payload
                }
                set {
                    lock.lock()
                    payload = newValue
                    lock.unlock()
                }
            }
        }

        private func waitForPendingTimer(_ harness: Harness) {
            let seeded = expectation(description: "the notifier has work waiting on its scheduler")
            DispatchQueue.global().async {
                while harness.scheduler.pendingCount == 0 { Thread.sleep(forTimeInterval: 0.02) }
                seeded.fulfill()
            }
            wait(for: [seeded], timeout: 10)
        }

        /// On a quiet daemon no change ever arrives to trigger a broadcast, so the notifier must be seeded at
        /// start: otherwise the first agent that becomes blocked is taken as the seed and never buzzes, and the
        /// startup badge resync never happens.
        func testTheNotifierIsSeededAtStartWithoutAnyLaterChange() throws {
            try withTemporaryProfile {
                let box = OverviewBox(PushOverviewFixture.overview())
                let registered = InMemoryPushRegistrations([
                    "phone-1": SpacesDevicePushRegistration(capability: "cap-1", notifyBlocked: true, notifyFinished: false)
                ])
                let harness = try Harness(tlsRoot: tlsRoot, overviewBox: box, registrations: registered)
                defer { harness.stop() }

                waitForPendingTimer(harness)
                harness.scheduler.advance(by: 1)
                XCTAssertEqual(harness.relay.reports.map(\.total), [0])

                box.current = PushOverviewFixture.overview(agents: [("a", .waiting)])
                NotificationCenter.default.post(name: IPCNotification.databaseDidChange, object: nil)
                waitForPendingTimer(harness)
                harness.scheduler.advance(by: 11)
                XCTAssertEqual(harness.relay.reports.map(\.notify), [false, false, true])
            }
        }

        private final class Harness {
            let server: SpacesDeviceAPIServer
            let client: SpacesDeviceAPIRequestSessionClient
            let registrations: InMemoryPushRegistrations
            let relay = RecordingPushRelay()
            let scheduler = ManualPushScheduler()
            let relayDeviceID: String
            private let token = "valid-token"

            init(
                tlsRoot: URL, overview: SpacesDeviceOverviewPayload? = nil, overviewBox: OverviewBox? = nil,
                registrations: InMemoryPushRegistrations = InMemoryPushRegistrations()
            ) throws {
                self.registrations = registrations
                let identity = try TerminalServiceTLSIdentityStore.loadOrCreate(root: tlsRoot)
                let loader: (@Sendable (SpacesDeviceClientApp?) throws -> SpacesDeviceOverviewPayload)? =
                    overviewBox.map { box in { @Sendable _ in box.current } } ?? overview.map { payload in { @Sendable _ in payload } }
                server = SpacesDeviceAPIServer(
                    host: "127.0.0.1", port: 0, identity: identity,
                    pairingStoreProtocol: AlwaysAuthorizedPushPairingStore(token: token, registrations: registrations),
                    overviewLoaderForTesting: loader, pushRelayClient: relay, pushScheduler: scheduler)
                try server.start()
                client = try SpacesDeviceAPIRequestSessionClient(
                    resolver: SpacesDeviceEndpointResolver(
                        hosts: ["127.0.0.1"], port: server.listeningPort, certificateFingerprint: identity.certificateFingerprint))
                relayDeviceID = SpacesDevicePushRelayDeviceID.make(certificateFingerprint: identity.certificateFingerprint, port: 0)
            }

            func send(_ command: SpacesDeviceAPICommand, as clientApp: SpacesDeviceClientApp) throws -> SpacesDeviceAPIResponse {
                try client.send(SpacesDeviceAPIRequest(command: command, authToken: token, clientApp: clientApp))
            }

            func stop() {
                client.cancel()
                server.stop()
            }
        }

        /// A pairing store that authorizes one token and keeps push registrations in memory.
        private final class AlwaysAuthorizedPushPairingStore: SpacesDevicePairingStoreProtocol {
            let token: String
            let registrations: InMemoryPushRegistrations
            init(token: String, registrations: InMemoryPushRegistrations) {
                self.token = token
                self.registrations = registrations
            }

            func pushRegistrations() throws -> [String: SpacesDevicePushRegistration] { try registrations.pushRegistrations() }
            func setPushRegistration(_ registration: SpacesDevicePushRegistration, forInstallationID installationID: String) throws {
                try registrations.setPushRegistration(registration, forInstallationID: installationID)
            }
            func clearPushRegistration(forInstallationID installationID: String, matchingCapability: String?) throws -> SpacesDevicePushRegistration?
            { try registrations.clearPushRegistration(forInstallationID: installationID, matchingCapability: matchingCapability) }

            func issueToken(for _: SpacesDeviceClientApp, presentedToken _: String?) throws -> String { token }
            func listDevices() throws -> [SpacesDevicePairedClient] { [] }
            func revoke(installationID _: String) throws {}
            func removeAll() throws {}
            func authorize(clientApp: SpacesDeviceClientApp?, authToken: String?) throws {
                guard clientApp != nil, authToken == token else {
                    throw NSError(domain: "SpacesDeviceAPIServer", code: 401, userInfo: [NSLocalizedDescriptionKey: "Invalid device auth token."])
                }
            }
            func validate(clientApp _: SpacesDeviceClientApp) throws {}
        }

        private func withTemporaryProfile(_ body: () throws -> Void) throws {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let originalDatabasePath = ProcessInfo.processInfo.environment[SpacesProfile.databasePathEnvironmentVariable]
            let originalRuntimePath = ProcessInfo.processInfo.environment[SpacesProfile.runtimeDirectoryEnvironmentVariable]
            setenv(SpacesProfile.databasePathEnvironmentVariable, root.appendingPathComponent("spaces.db").path, 1)
            unsetenv(SpacesProfile.runtimeDirectoryEnvironmentVariable)
            defer {
                if let originalDatabasePath {
                    setenv(SpacesProfile.databasePathEnvironmentVariable, originalDatabasePath, 1)
                } else {
                    unsetenv(SpacesProfile.databasePathEnvironmentVariable)
                }
                if let originalRuntimePath {
                    setenv(SpacesProfile.runtimeDirectoryEnvironmentVariable, originalRuntimePath, 1)
                } else {
                    unsetenv(SpacesProfile.runtimeDirectoryEnvironmentVariable)
                }
                try? FileManager.default.removeItem(at: root)
            }
            try body()
        }
    }
#endif
