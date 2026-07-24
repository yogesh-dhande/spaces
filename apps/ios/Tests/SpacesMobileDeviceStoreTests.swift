#if canImport(UIKit)
    import XCTest
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

        /// An empty advertised list means the daemon reported nothing — never that it has no addresses —
        /// so it must never overwrite a record's `hosts`, even when they differ from what a later call
        /// would advertise. Reports no change, since a caller (`SpacesMobileAppModel`) uses that to decide
        /// whether its live client needs rebuilding.
        func testMergeAdvertisedHostsIsNoOpWhenHostsIsEmpty() throws {
            let state = SpacesMobileDeviceStore.upsert(settings: makeSettings(hosts: ["10.0.0.5"], fingerprint: "SHA256:mac", token: "token"), name: "Mac")
            let id = try XCTUnwrap(state.devices.first?.id)

            let changed = SpacesMobileDeviceStore.mergeAdvertisedHosts([], certificateFingerprint: "SHA256:mac")

            XCTAssertFalse(changed)
            let reloaded = SpacesMobileDeviceStore.load(fallbackSettings: SpacesMobileConnectionSettings())
            XCTAssertEqual(reloaded.devices.first(where: { $0.id == id })?.hosts, ["10.0.0.5"])
        }

        /// The core backfill behavior: a device paired before its Mac had Tailscale has only a LAN
        /// address stored. Once the daemon reports both addresses, the record adopts the daemon's list
        /// and order verbatim, with no rescan, and reports the change so a live client can be rebuilt.
        func testMergeAdvertisedHostsAdoptsDaemonOrder() throws {
            let state = SpacesMobileDeviceStore.upsert(settings: makeSettings(hosts: ["10.0.0.5"], fingerprint: "SHA256:mac", token: "token"), name: "Mac")
            let id = try XCTUnwrap(state.devices.first?.id)

            let changed = SpacesMobileDeviceStore.mergeAdvertisedHosts(["10.0.0.5", "100.64.0.5"], certificateFingerprint: "SHA256:mac")

            XCTAssertTrue(changed)
            let reloaded = SpacesMobileDeviceStore.load(fallbackSettings: SpacesMobileConnectionSettings())
            XCTAssertEqual(reloaded.devices.first(where: { $0.id == id })?.hosts, ["10.0.0.5", "100.64.0.5"])
        }

        /// `activeHost` survives a merge that keeps it in the new list.
        func testMergeAdvertisedHostsKeepsActiveHostWhenStillPresent() throws {
            _ = SpacesMobileDeviceStore.upsert(
                settings: makeSettings(hosts: ["10.0.0.5", "100.64.0.5"], fingerprint: "SHA256:mac", token: "token"), name: "Mac")
            SpacesMobileDeviceStore.recordActiveHost("100.64.0.5", certificateFingerprint: "SHA256:mac")

            SpacesMobileDeviceStore.mergeAdvertisedHosts(["100.64.0.5", "10.0.0.5"], certificateFingerprint: "SHA256:mac")

            let reloaded = SpacesMobileDeviceStore.load(fallbackSettings: SpacesMobileConnectionSettings())
            XCTAssertEqual(reloaded.devices.first?.activeHost, "100.64.0.5")
        }

        /// `activeHost` is dropped (not carried forward as an invented candidate) when the daemon's
        /// advertised list no longer includes it.
        func testMergeAdvertisedHostsDropsActiveHostNoLongerPresent() throws {
            _ = SpacesMobileDeviceStore.upsert(
                settings: makeSettings(hosts: ["10.0.0.5", "100.64.0.5"], fingerprint: "SHA256:mac", token: "token"), name: "Mac")
            SpacesMobileDeviceStore.recordActiveHost("100.64.0.5", certificateFingerprint: "SHA256:mac")

            SpacesMobileDeviceStore.mergeAdvertisedHosts(["10.0.0.5"], certificateFingerprint: "SHA256:mac")

            let reloaded = SpacesMobileDeviceStore.load(fallbackSettings: SpacesMobileConnectionSettings())
            XCTAssertNil(reloaded.devices.first?.activeHost)
        }

        /// Merging the record's own current `hosts` (the common steady-state case) must be a true no-op:
        /// the persisted devices blob is byte-identical before and after, and no change is reported.
        func testMergeAdvertisedHostsIsNoOpWhenUnchanged() throws {
            _ = SpacesMobileDeviceStore.upsert(
                settings: makeSettings(hosts: ["10.0.0.5", "100.64.0.5"], fingerprint: "SHA256:mac", token: "token"), name: "Mac")
            let blobBefore = try XCTUnwrap(UserDefaults.standard.data(forKey: devicesKey))

            let changed = SpacesMobileDeviceStore.mergeAdvertisedHosts(["10.0.0.5", "100.64.0.5"], certificateFingerprint: "SHA256:mac")

            XCTAssertFalse(changed)
            XCTAssertEqual(UserDefaults.standard.data(forKey: devicesKey), blobBefore)
        }

        /// No paired device matches the fingerprint: a no-op, not a crash or an invented record.
        func testMergeAdvertisedHostsIsNoOpWhenFingerprintUnmatched() throws {
            _ = SpacesMobileDeviceStore.upsert(settings: makeSettings(hosts: ["10.0.0.5"], fingerprint: "SHA256:mac", token: "token"), name: "Mac")

            let changed = SpacesMobileDeviceStore.mergeAdvertisedHosts(["10.0.0.5", "100.64.0.5"], certificateFingerprint: "SHA256:other")

            XCTAssertFalse(changed)
            let reloaded = SpacesMobileDeviceStore.load(fallbackSettings: SpacesMobileConnectionSettings())
            XCTAssertEqual(reloaded.devices.first?.hosts, ["10.0.0.5"])
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
#endif
