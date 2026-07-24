#if canImport(UIKit)
    import XCTest
    import Network
    import spacesdevicecore
    import spacesterminalcore
    @testable import SpacesMobile

    /// Multi-address device pairing: a paired Mac can be reachable at more than one address (LAN and
    /// Tailscale). These tests cover the legacy single-`host` decode safety net (a decode failure drops
    /// every paired device, so tolerating the pre-multi-address JSON shape matters), that device identity
    /// stays address-independent across a rescan, and the `activeHost` warm-start cache.
    ///
    /// These tests exercise the real `SpacesMobileDeviceStore` persistence, which lives in
    /// `UserDefaults.standard` and the Keychain, so each test clears and reseeds that state — see
    /// `SpacesMobileDemoModeTests` for the same pattern.
    final class SpacesMobileDeviceStoreTests: XCTestCase {
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

        // MARK: - Legacy decode

        /// A device record written by a pre-multi-address build has a single `"host"` string and no
        /// `"hosts"`/`"activeHost"`. Decoding it must not drop the device: it should wrap the host as a
        /// one-element `hosts` list. Goes through the store's public `load` so this proves the real
        /// persistence path, not just `JSONDecoder` in isolation.
        func testLegacyDeviceRecordJSONDecodesThroughStoreLoad() throws {
            let legacyJSON = """
                [{"id":"device-legacy","name":"Legacy Mac","host":"192.168.1.24","port":47847,\
                "certificateFingerprint":"SHA256:legacy","createdAt":"2024-01-01T00:00:00Z","updatedAt":"2024-01-01T00:00:00Z"}]
                """
            UserDefaults.standard.set(Data(legacyJSON.utf8), forKey: devicesKey)

            let state = SpacesMobileDeviceStore.load(fallbackSettings: SpacesMobileConnectionSettings())

            XCTAssertEqual(state.devices.count, 1)
            let device = try XCTUnwrap(state.devices.first)
            XCTAssertEqual(device.hosts, ["192.168.1.24"])
            XCTAssertNil(device.activeHost)
        }

        /// `SpacesMobileConnectionSettings` tolerates the same legacy `"host"` key.
        func testLegacyConnectionSettingsJSONDecodesSingleHost() throws {
            let legacyJSON = #"{"host":"10.1.1.5"}"#
            let settings = try JSONDecoder().decode(SpacesMobileConnectionSettings.self, from: Data(legacyJSON.utf8))
            XCTAssertEqual(settings.hosts, ["10.1.1.5"])
        }

        /// Encoding a multi-host settings blob preserves order and never writes the legacy `"host"` key.
        func testConnectionSettingsMultiHostRoundTripPreservesOrderAndOmitsLegacyKey() throws {
            var settings = SpacesMobileConnectionSettings()
            settings.hosts = ["10.0.0.5", "100.64.0.5"]

            let data = try JSONEncoder().encode(settings)
            let json = try XCTUnwrap(String(data: data, encoding: .utf8))
            XCTAssertFalse(json.contains("\"host\":"), "must not encode the legacy singular key")
            XCTAssertTrue(json.contains("\"hosts\":"))

            let decoded = try JSONDecoder().decode(SpacesMobileConnectionSettings.self, from: data)
            XCTAssertEqual(decoded.hosts, ["10.0.0.5", "100.64.0.5"])
        }

        /// Same round-trip contract for the paired-device record type.
        func testPairedDeviceRecordMultiHostRoundTripPreservesOrderAndOmitsLegacyKey() throws {
            let record = SpacesMobilePairedDeviceRecord(
                id: "device-abc", name: "Mac", hosts: ["10.0.0.5", "100.64.0.5"], port: 47_900,
                certificateFingerprint: "SHA256:mac", createdAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-01T00:00:00Z",
                lastSelectedAt: nil, activeHost: nil)

            let data = try JSONEncoder().encode(record)
            let json = try XCTUnwrap(String(data: data, encoding: .utf8))
            XCTAssertFalse(json.contains("\"host\":"), "must not encode the legacy singular key")
            XCTAssertTrue(json.contains("\"hosts\":"))

            let decoded = try JSONDecoder().decode(SpacesMobilePairedDeviceRecord.self, from: data)
            XCTAssertEqual(decoded.hosts, ["10.0.0.5", "100.64.0.5"])
        }

        // MARK: - Device identity is address-independent

        /// Two `upsert`s for the same certificate fingerprint and port but different `hosts` (e.g. a QR
        /// rescan that adds the Tailscale candidate to an already-paired Mac) must fold into one device,
        /// not create a second row, and the surviving id must be stable.
        func testUpsertWithDifferentHostsSameFingerprintProducesOneDevice() throws {
            let first = SpacesMobileDeviceStore.upsert(
                settings: makeSettings(hosts: ["10.0.0.5"], fingerprint: "SHA256:mac", token: "token-1"), name: "Mac")
            XCTAssertEqual(first.devices.count, 1)
            let firstID = try XCTUnwrap(first.devices.first?.id)

            let second = SpacesMobileDeviceStore.upsert(
                settings: makeSettings(hosts: ["100.64.0.5"], fingerprint: "SHA256:mac", token: "token-2"), name: "Mac")

            XCTAssertEqual(SpacesMobileDeviceStore.load(fallbackSettings: SpacesMobileConnectionSettings()).devices.count, 1)
            XCTAssertEqual(second.devices.first?.id, firstID, "the rescan must upgrade the existing row, not mint a new id")
        }

        /// Regression: before `deviceID` excluded the address, folding the id on a rescan orphaned the
        /// Keychain auth token stored under the old id. The token must stay readable under the surviving id.
        func testSecondUpsertKeepsAuthTokenReadableUnderSurvivingID() throws {
            let first = SpacesMobileDeviceStore.upsert(
                settings: makeSettings(hosts: ["10.0.0.5"], fingerprint: "SHA256:mac", token: "token-1"), name: "Mac")
            let id = try XCTUnwrap(first.devices.first?.id)

            let second = SpacesMobileDeviceStore.upsert(
                settings: makeSettings(hosts: ["100.64.0.5"], fingerprint: "SHA256:mac", token: "token-2"), name: "Mac")

            XCTAssertEqual(second.devices.first?.id, id)
            XCTAssertEqual(SpacesMobileDeviceStore.authToken(deviceID: id), "token-2")
        }

        /// The second `upsert`'s `hosts` replace the first's outright (the rescan upgrades the row in
        /// place), `createdAt` is preserved from the original record, and `updatedAt` moves forward.
        func testSecondUpsertReplacesHostsAndPreservesCreatedAt() throws {
            let first = SpacesMobileDeviceStore.upsert(
                settings: makeSettings(hosts: ["10.0.0.5"], fingerprint: "SHA256:mac", token: "token-1"), name: "Mac")
            let firstRecord = try XCTUnwrap(first.devices.first)

            // ISO8601DateFormatter's default format has one-second resolution; sleep past a full second so
            // `updatedAt` is provably a later timestamp instead of merely "not asserted".
            Thread.sleep(forTimeInterval: 1.1)

            let second = SpacesMobileDeviceStore.upsert(
                settings: makeSettings(hosts: ["100.64.0.5"], fingerprint: "SHA256:mac", token: "token-2"), name: "Mac")
            let secondRecord = try XCTUnwrap(second.devices.first)

            XCTAssertEqual(secondRecord.hosts, ["100.64.0.5"])
            XCTAssertEqual(secondRecord.createdAt, firstRecord.createdAt)
            XCTAssertGreaterThan(secondRecord.updatedAt, firstRecord.updatedAt)
        }

        /// Two different certificate fingerprints must never fold together, even if hosts overlap.
        func testUpsertWithDifferentFingerprintsProducesTwoDevices() throws {
            _ = SpacesMobileDeviceStore.upsert(
                settings: makeSettings(hosts: ["10.0.0.5"], fingerprint: "SHA256:mac-a", token: "token-a"), name: "Mac A")
            let state = SpacesMobileDeviceStore.upsert(
                settings: makeSettings(hosts: ["10.0.0.5"], fingerprint: "SHA256:mac-b", token: "token-b"), name: "Mac B")

            XCTAssertEqual(state.devices.count, 2)
            XCTAssertEqual(Set(state.devices.map(\.id)).count, 2)
        }

        // MARK: - activeHost

        /// `recordActiveHost` sets `activeHost` when the host is a member of the matched record's `hosts`.
        func testRecordActiveHostSetsActiveHostWhenMatched() throws {
            let state = SpacesMobileDeviceStore.upsert(
                settings: makeSettings(hosts: ["10.0.0.5", "100.64.0.5"], fingerprint: "SHA256:mac", token: "token"), name: "Mac")
            let id = try XCTUnwrap(state.devices.first?.id)

            SpacesMobileDeviceStore.recordActiveHost("100.64.0.5", certificateFingerprint: "SHA256:mac")

            let reloaded = SpacesMobileDeviceStore.load(fallbackSettings: SpacesMobileConnectionSettings())
            XCTAssertEqual(reloaded.devices.first(where: { $0.id == id })?.activeHost, "100.64.0.5")
        }

        /// A host that is not one of the record's `hosts` must never be adopted as `activeHost` —
        /// `recordActiveHost` never invents a candidate.
        func testRecordActiveHostIgnoresHostNotInHosts() throws {
            let state = SpacesMobileDeviceStore.upsert(
                settings: makeSettings(hosts: ["10.0.0.5"], fingerprint: "SHA256:mac", token: "token"), name: "Mac")
            let id = try XCTUnwrap(state.devices.first?.id)

            SpacesMobileDeviceStore.recordActiveHost("192.168.99.99", certificateFingerprint: "SHA256:mac")

            let reloaded = SpacesMobileDeviceStore.load(fallbackSettings: SpacesMobileConnectionSettings())
            XCTAssertNil(reloaded.devices.first(where: { $0.id == id })?.activeHost)
        }

        /// Recording the same already-active host a second time must be a true no-op: the persisted
        /// devices blob is byte-identical before and after, not merely logically unchanged.
        func testRecordActiveHostIsNoOpWhenUnchanged() throws {
            _ = SpacesMobileDeviceStore.upsert(
                settings: makeSettings(hosts: ["10.0.0.5", "100.64.0.5"], fingerprint: "SHA256:mac", token: "token"), name: "Mac")
            SpacesMobileDeviceStore.recordActiveHost("100.64.0.5", certificateFingerprint: "SHA256:mac")
            let blobBefore = try XCTUnwrap(UserDefaults.standard.data(forKey: devicesKey))

            SpacesMobileDeviceStore.recordActiveHost("100.64.0.5", certificateFingerprint: "SHA256:mac")

            XCTAssertEqual(UserDefaults.standard.data(forKey: devicesKey), blobBefore)
        }

        /// `clearActiveHosts` nils the cached candidate on every paired device.
        func testClearActiveHostsNilsEveryDevice() throws {
            _ = SpacesMobileDeviceStore.upsert(
                settings: makeSettings(hosts: ["10.0.0.5"], fingerprint: "SHA256:mac-1", token: "token-1"), name: "Mac 1")
            _ = SpacesMobileDeviceStore.upsert(
                settings: makeSettings(hosts: ["10.0.0.6"], fingerprint: "SHA256:mac-2", token: "token-2"), name: "Mac 2")
            SpacesMobileDeviceStore.recordActiveHost("10.0.0.5", certificateFingerprint: "SHA256:mac-1")
            SpacesMobileDeviceStore.recordActiveHost("10.0.0.6", certificateFingerprint: "SHA256:mac-2")

            SpacesMobileDeviceStore.clearActiveHosts()

            let reloaded = SpacesMobileDeviceStore.load(fallbackSettings: SpacesMobileConnectionSettings())
            XCTAssertEqual(reloaded.devices.count, 2)
            XCTAssertTrue(reloaded.devices.allSatisfy { $0.activeHost == nil })
        }

        /// Warm-start reordering: once `recordActiveHost` has learned an address, selecting that device
        /// must yield settings whose `hosts` starts with that address even though it was not first in the
        /// record's own `hosts` list. Reached only through the public `select` API.
        func testSelectReordersHostsWithActiveHostFirst() throws {
            let state = SpacesMobileDeviceStore.upsert(
                settings: makeSettings(hosts: ["10.0.0.5", "100.64.0.5"], fingerprint: "SHA256:mac", token: "token", installationID: "INSTALL-1"),
                name: "Mac")
            let id = try XCTUnwrap(state.devices.first?.id)
            SpacesMobileDeviceStore.recordActiveHost("100.64.0.5", certificateFingerprint: "SHA256:mac")

            let selected = try XCTUnwrap(SpacesMobileDeviceStore.select(deviceID: id, installationID: "INSTALL-1"))

            XCTAssertEqual(selected.settings.hosts, ["100.64.0.5", "10.0.0.5"])
        }

        /// An `activeHost` that is no longer a member of `hosts` (e.g. a rescan replaced the address list)
        /// must be dropped rather than carried forward onto the new record.
        func testActiveHostNoLongerInHostsIsDroppedOnUpsert() throws {
            let first = SpacesMobileDeviceStore.upsert(
                settings: makeSettings(hosts: ["10.0.0.5"], fingerprint: "SHA256:mac", token: "token-1"), name: "Mac")
            let id = try XCTUnwrap(first.devices.first?.id)
            SpacesMobileDeviceStore.recordActiveHost("10.0.0.5", certificateFingerprint: "SHA256:mac")

            let second = SpacesMobileDeviceStore.upsert(
                settings: makeSettings(hosts: ["100.64.0.5"], fingerprint: "SHA256:mac", token: "token-2"), name: "Mac")

            XCTAssertEqual(second.devices.first?.id, id)
            XCTAssertNil(second.devices.first?.activeHost)
        }

        // MARK: - Helpers

        private func makeSettings(hosts: [String], fingerprint: String, token: String, installationID: String = "INSTALL")
            -> SpacesMobileConnectionSettings
        {
            var settings = SpacesMobileConnectionSettings()
            settings.hosts = hosts
            settings.port = 47_900
            settings.certificateFingerprint = fingerprint
            settings.authToken = token
            settings.installationID = installationID
            return settings
        }

        private func resetPersistedState() {
            for device in SpacesMobileDeviceStore.load(fallbackSettings: SpacesMobileConnectionSettings()).devices {
                _ = SpacesMobileDeviceStore.remove(deviceID: device.id, fallbackSettings: SpacesMobileConnectionSettings())
            }
            let defaults = UserDefaults.standard
            for key in [devicesKey, activeDeviceKey, connectionSettingsKey, demoModeKey] { defaults.removeObject(forKey: key) }
        }
    }

    /// `SpacesDeviceEndpointResolver` opens real `NWConnection`s, so only the parts of its contract that
    /// don't depend on a live daemon are covered here: the up-front validation guard, and the shape of the
    /// error thrown when every candidate is unreachable.
    final class SpacesDeviceEndpointResolverTests: XCTestCase {
        /// An empty `hosts` list is rejected before any connection attempt.
        func testConnectThrowsInvalidEndpointForEmptyHosts() async {
            var settings = SpacesMobileConnectionSettings()
            settings.hosts = []
            settings.port = 47_900
            let resolver = SpacesDeviceEndpointResolver(settings: settings)

            do {
                _ = try await resolver.connect(timeout: .seconds(1), queue: .main)
                XCTFail("expected invalidEndpoint")
            } catch SpacesDeviceAPIClientError.invalidEndpoint {
                // expected
            } catch {
                XCTFail("unexpected error: \(error)")
            }
        }

        /// Every candidate that never answers (and never even resets the connection, so there is no pin
        /// mismatch to report) surfaces as `allCandidatesUnreachable`, naming every host that was tried —
        /// which is what proves the resolver walked the whole list rather than giving up on the first.
        /// Uses RFC 5737 TEST-NET addresses (`192.0.2.1`, `198.51.100.1`) — guaranteed non-routable to a
        /// live host — instead of a live daemon, so the failure is deterministic. The short `timeout`
        /// becomes the per-candidate cap (`min(timeout, 5s)`), keeping a test that has to wait out two
        /// real connect attempts near two seconds instead of the ten a production-sized budget would cost.
        func testAllCandidatesUnreachableNamesEveryHostTried() async throws {
            var settings = SpacesMobileConnectionSettings()
            settings.hosts = ["192.0.2.1", "198.51.100.1"]
            settings.port = 47_900
            settings.certificateFingerprint = "SHA256:unreachable"
            let resolver = SpacesDeviceEndpointResolver(settings: settings)

            do {
                _ = try await resolver.connect(timeout: .milliseconds(300), queue: .main)
                XCTFail("expected allCandidatesUnreachable")
            } catch SpacesDeviceAPIClientError.allCandidatesUnreachable(let hosts) {
                XCTAssertEqual(hosts, ["192.0.2.1", "198.51.100.1"])
            } catch {
                XCTFail("unexpected error: \(error)")
            }
        }

        /// The error message names the unreachable addresses and points at Tailscale, since the most
        /// common real-world cause is being away from the paired Mac's LAN with Tailscale not connected.
        /// Asserted on the error value directly: the message is a property of the case, so proving its
        /// content needs no connection attempt.
        func testAllCandidatesUnreachableDescriptionNamesHostsAndTailscale() throws {
            let error = SpacesDeviceAPIClientError.allCandidatesUnreachable(hosts: ["192.168.1.24", "100.86.197.104"])
            let description = try XCTUnwrap(error.errorDescription)
            XCTAssertTrue(description.contains("192.168.1.24"))
            XCTAssertTrue(description.contains("100.86.197.104"))
            XCTAssertTrue(description.contains("Tailscale"))
        }
    }
#endif
