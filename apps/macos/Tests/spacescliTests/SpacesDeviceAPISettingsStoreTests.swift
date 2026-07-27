import Foundation
import XCTest
import spacesdevicecore

@testable import spacesdeviceapi

final class SpacesDeviceAPISettingsStoreTests: XCTestCase {
    func testLoadOrCreatePersistsStableDefaultEndpointForInstalledProfile() throws {
        try withTemporaryProfile { _ in
            let store = SpacesDeviceAPISettingsStore(profileSource: { .installedFallback })

            let created = try store.loadOrCreate()
            let reloaded = try SpacesDeviceAPISettingsStore(profileSource: { .installedFallback }).loadOrCreate()

            XCTAssertEqual(created.host, SpacesDeviceAPIDefaults.host)
            XCTAssertEqual(created.port, SpacesDeviceAPIDefaults.port)
            XCTAssertEqual(reloaded, created)
        }
    }

    func testEnvironmentOverridesEndpointWithoutChangingStoredDefaults() throws {
        try withTemporaryProfile { _ in
            let environment = [
                SpacesDeviceAPIDefaults.hostEnvironmentVariable: "127.0.0.1", SpacesDeviceAPIDefaults.portEnvironmentVariable: "51234",
            ]
            let overridden = try SpacesDeviceAPISettingsStore(environment: environment, profileSource: { .installedFallback }).loadOrCreate()
            let stored = try SpacesDeviceAPISettingsStore(profileSource: { .installedFallback }).loadOrCreate()

            XCTAssertEqual(overridden.host, "127.0.0.1")
            XCTAssertEqual(overridden.port, 51_234)
            XCTAssertEqual(stored.host, SpacesDeviceAPIDefaults.host)
            XCTAssertEqual(stored.port, SpacesDeviceAPIDefaults.port)
        }
    }

    func testLoadTolerantlyIgnoresRetiredIdentityFieldsInStoredSettings() throws {
        try withTemporaryProfile { root in
            let settingsURL = root.appendingPathComponent("runtime/terminal/device-api.json")
            try FileManager.default.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(
                """
                {"host": "0.0.0.0", "port": 47901, "transportKey": "RETIRED", "certificateFingerprint": "SHA256:retired"}
                """.utf8
            ).write(to: settingsURL)

            let loaded = try SpacesDeviceAPISettingsStore().loadOrCreate()

            XCTAssertEqual(loaded.host, "0.0.0.0")
            XCTAssertEqual(loaded.port, 47_901)
        }
    }

    func testIsDisabledByEnvironmentRecognizesOnlyTheDisableOverride() {
        // The override turns the Device API off; a relaunch can't bring it back, so the UI keys off this.
        XCTAssertTrue(SpacesDeviceAPIDefaults.isDisabledByEnvironment([SpacesDeviceAPIDefaults.disabledEnvironmentVariable: "1"]))
        XCTAssertTrue(SpacesDeviceAPIDefaults.isDisabledByEnvironment([SpacesDeviceAPIDefaults.disabledEnvironmentVariable: "true"]))
        XCTAssertTrue(SpacesDeviceAPIDefaults.isDisabledByEnvironment([SpacesDeviceAPIDefaults.disabledEnvironmentVariable: " TRUE "]))

        // Absent, empty, or any other value leaves the Device API enabled (a transient socket failure is
        // not the disabled-override case).
        XCTAssertFalse(SpacesDeviceAPIDefaults.isDisabledByEnvironment([:]))
        XCTAssertFalse(SpacesDeviceAPIDefaults.isDisabledByEnvironment([SpacesDeviceAPIDefaults.disabledEnvironmentVariable: ""]))
        XCTAssertFalse(SpacesDeviceAPIDefaults.isDisabledByEnvironment([SpacesDeviceAPIDefaults.disabledEnvironmentVariable: "0"]))
        XCTAssertFalse(SpacesDeviceAPIDefaults.isDisabledByEnvironment([SpacesDeviceAPIDefaults.disabledEnvironmentVariable: "no"]))
    }

    func testEnvironmentPortOverrideAllowsEphemeralPortWithoutChangingStoredDefaults() throws {
        try withTemporaryProfile { _ in
            let environment = [SpacesDeviceAPIDefaults.portEnvironmentVariable: "0"]
            let overridden = try SpacesDeviceAPISettingsStore(environment: environment, profileSource: { .installedFallback }).loadOrCreate()
            let stored = try SpacesDeviceAPISettingsStore(profileSource: { .installedFallback }).loadOrCreate()

            XCTAssertEqual(overridden.port, 0)
            XCTAssertEqual(stored.port, SpacesDeviceAPIDefaults.port)
        }
    }

    /// A development profile that has never been given a port assigns itself one from the development
    /// range, so it is reachable at a fixed address of its own without ever binding the canonical port the
    /// installed daemon a client already paired with is listening on.
    func testDevelopmentProfileAssignsItselfAPortFromTheDevelopmentRange() throws {
        try withTemporaryProfile { _ in
            let settings = try SpacesDeviceAPISettingsStore(profileSource: { .developmentWorktree }, portsClaimedByOtherProfiles: { _ in [] })
                .loadOrCreate()

            XCTAssertTrue(
                SpacesDeviceAPIDefaults.developmentPortRange.contains(settings.port),
                "Expected a port from the development range, got \(settings.port).")
            XCTAssertNotEqual(settings.port, SpacesDeviceAPIDefaults.port, "The canonical port belongs to the installed profile alone.")
            XCTAssertEqual(settings.host, SpacesDeviceAPIDefaults.host)
        }
    }

    /// The installed profile keeps the canonical port and is never sent through the development assignment,
    /// even when the ports other profiles claim include the canonical one — clients pair with it at that
    /// fixed address, so it is the one profile whose port is not negotiable.
    func testCanonicalPortKeptForInstalledProfile() throws {
        try withTemporaryProfile { root in
            let settings = try SpacesDeviceAPISettingsStore(
                profileSource: { .installedFallback }, portsClaimedByOtherProfiles: { _ in [SpacesDeviceAPIDefaults.port] }
            ).loadOrCreate()

            XCTAssertEqual(settings.port, SpacesDeviceAPIDefaults.port)
            let storedData = try Data(contentsOf: root.appendingPathComponent("runtime/terminal/device-api.json"))
            XCTAssertEqual(try JSONDecoder().decode(SpacesDeviceAPISettings.self, from: storedData).port, SpacesDeviceAPIDefaults.port)
        }
    }

    func testNonCanonicalStoredPortKeptForDevelopmentProfile() throws {
        try withTemporaryProfile { root in
            let settingsURL = root.appendingPathComponent("runtime/terminal/device-api.json")
            try FileManager.default.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(#"{"host": "0.0.0.0", "port": 51999}"#.utf8).write(to: settingsURL)

            let settings = try SpacesDeviceAPISettingsStore(profileSource: { .developmentWorktree }).loadOrCreate()

            XCTAssertEqual(settings.port, 51_999)
        }
    }

    func testEnvironmentPortOverrideWinsOverAssignedDevelopmentPort() throws {
        try withTemporaryProfile { _ in
            // Env override to a specific port wins over the port the profile assigns itself.
            let specific = try SpacesDeviceAPISettingsStore(
                environment: [SpacesDeviceAPIDefaults.portEnvironmentVariable: "51234"], profileSource: { .developmentWorktree },
                portsClaimedByOtherProfiles: { _ in [] }
            ).loadOrCreate()
            XCTAssertEqual(specific.port, 51_234)

            // Env override to the canonical port also wins — this is how the E2E profiles pin a port.
            let canonical = try SpacesDeviceAPISettingsStore(
                environment: [SpacesDeviceAPIDefaults.portEnvironmentVariable: String(SpacesDeviceAPIDefaults.port)],
                profileSource: { .developmentWorktree }, portsClaimedByOtherProfiles: { _ in [] }
            ).loadOrCreate()
            XCTAssertEqual(canonical.port, SpacesDeviceAPIDefaults.port)
        }
    }

    /// A development profile's assignment is PERSISTED, and a later load reuses it instead of choosing
    /// again. That stickiness is the product requirement: a paired client stores one host:port for the
    /// device, so a profile whose port moved between starts would orphan every client paired with it. The
    /// reload is handed a claimed-port set containing the port the first load assigned — which would force a
    /// different choice if the assignment were being recomputed — so only a respected stored port passes.
    func testFreshCreatePersistsTheAssignedDevelopmentPortAndLaterLoadsReuseIt() throws {
        try withTemporaryProfile { root in
            let assigned = try SpacesDeviceAPISettingsStore(profileSource: { .developmentWorktree }, portsClaimedByOtherProfiles: { _ in [] })
                .loadOrCreate()

            let storedData = try Data(contentsOf: root.appendingPathComponent("runtime/terminal/device-api.json"))
            XCTAssertEqual(try JSONDecoder().decode(SpacesDeviceAPISettings.self, from: storedData).port, assigned.port)

            let reloaded = try SpacesDeviceAPISettingsStore(
                profileSource: { .developmentWorktree }, portsClaimedByOtherProfiles: { _ in [assigned.port] }
            ).loadOrCreate()
            XCTAssertEqual(reloaded.port, assigned.port)
        }
    }

    /// The choice is a pure function of the profile root, so a profile lands on the same port on every start
    /// and on every machine — the property the persisted assignment above rests on — and the root actually
    /// participates, rather than every profile deriving one shared port.
    func testAssignedDevelopmentPortIsDeterministicPerProfileRootAndVariesAcrossRoots() {
        let roots = (0..<20).map { "/Users/tester/.spaces-dev/profiles/spaces/profile-\($0)" }
        let firstPass = roots.map { SpacesDeviceAPISettingsStore.assignedDevelopmentPort(profileRoot: $0, claimedPorts: []) }
        let secondPass = roots.map { SpacesDeviceAPISettingsStore.assignedDevelopmentPort(profileRoot: $0, claimedPorts: []) }

        XCTAssertEqual(firstPass, secondPass, "The same profile root must always derive the same port.")
        XCTAssertGreaterThan(Set(firstPass).count, 1, "Distinct profile roots must not all derive one port.")
        for port in firstPass {
            XCTAssertTrue(SpacesDeviceAPIDefaults.developmentPortRange.contains(port), "\(port) is outside the development range.")
            XCTAssertNotEqual(port, SpacesDeviceAPIDefaults.port, "No derived port may be the installed profile's canonical port.")
        }
    }

    /// Two profile roots that hash into the same slot must not both claim it: the second steps forward past
    /// every port a sibling profile has already recorded, so each profile on the device ends up with a port
    /// of its own.
    func testAssignedDevelopmentPortStepsPastPortsSiblingProfilesAlreadyClaimed() {
        let root = "/Users/tester/.spaces-dev/profiles/spaces/stepping"
        let range = SpacesDeviceAPIDefaults.developmentPortRange
        let derived = SpacesDeviceAPISettingsStore.assignedDevelopmentPort(profileRoot: root, claimedPorts: [])
        let next = range.lowerBound + ((derived - range.lowerBound) + 1) % range.count
        let afterNext = range.lowerBound + ((derived - range.lowerBound) + 2) % range.count

        XCTAssertEqual(SpacesDeviceAPISettingsStore.assignedDevelopmentPort(profileRoot: root, claimedPorts: [derived]), next)
        XCTAssertEqual(SpacesDeviceAPISettingsStore.assignedDevelopmentPort(profileRoot: root, claimedPorts: [derived, next]), afterNext)
    }

    /// Stepping wraps at the top of the range rather than walking out of it, so a profile whose derived slot
    /// sits near the end still finds a free port instead of falling outside the range — and in particular
    /// never onto the canonical port just below it.
    func testAssignedDevelopmentPortWrapsAroundToTheStartOfTheRange() throws {
        let range = SpacesDeviceAPIDefaults.developmentPortRange
        // Wraparound is only observable from a slot above the start of the range, so pick a root that lands
        // in one. Sampling is deterministic — the derivation is a pure hash of the root.
        let root = try XCTUnwrap(
            (0..<64).map { "/Users/tester/.spaces-dev/profiles/spaces/wrapping-\($0)" }.first {
                SpacesDeviceAPISettingsStore.assignedDevelopmentPort(profileRoot: $0, claimedPorts: []) > range.lowerBound
            }, "No sampled profile root derived a port above the start of the range.")
        let derived = SpacesDeviceAPISettingsStore.assignedDevelopmentPort(profileRoot: root, claimedPorts: [])

        let assigned = SpacesDeviceAPISettingsStore.assignedDevelopmentPort(profileRoot: root, claimedPorts: Set(derived...range.upperBound))

        XCTAssertEqual(assigned, range.lowerBound)
    }

    /// With every port claimed there is no unclaimed choice left to make, so the profile keeps its derived
    /// port and shares it rather than falling outside the range or off it entirely.
    func testAssignedDevelopmentPortKeepsItsDerivedPortWhenEveryPortIsClaimed() {
        let root = "/Users/tester/.spaces-dev/profiles/spaces/fully-claimed"
        let derived = SpacesDeviceAPISettingsStore.assignedDevelopmentPort(profileRoot: root, claimedPorts: [])

        let assigned = SpacesDeviceAPISettingsStore.assignedDevelopmentPort(
            profileRoot: root, claimedPorts: Set(SpacesDeviceAPIDefaults.developmentPortRange))

        XCTAssertEqual(assigned, derived)
        XCTAssertTrue(SpacesDeviceAPIDefaults.developmentPortRange.contains(assigned))
    }

    private func withTemporaryProfile(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let originalDatabasePath = ProcessInfo.processInfo.environment["SPACES_DB_PATH"]
        let originalRuntimePath = ProcessInfo.processInfo.environment["SPACES_RUNTIME_DIR"]
        let deviceAPIEnvironmentNames = [
            SpacesDeviceAPIDefaults.disabledEnvironmentVariable, SpacesDeviceAPIDefaults.hostEnvironmentVariable,
            SpacesDeviceAPIDefaults.portEnvironmentVariable,
        ]
        let originalDeviceAPIEnvironment = Dictionary(
            uniqueKeysWithValues: deviceAPIEnvironmentNames.map { ($0, ProcessInfo.processInfo.environment[$0]) })
        setenv("SPACES_DB_PATH", root.appendingPathComponent("spaces.db").path, 1)
        setenv("SPACES_RUNTIME_DIR", root.appendingPathComponent("runtime").path, 1)
        for name in deviceAPIEnvironmentNames { unsetenv(name) }
        defer {
            if let originalDatabasePath { setenv("SPACES_DB_PATH", originalDatabasePath, 1) } else { unsetenv("SPACES_DB_PATH") }
            if let originalRuntimePath { setenv("SPACES_RUNTIME_DIR", originalRuntimePath, 1) } else { unsetenv("SPACES_RUNTIME_DIR") }
            for (name, value) in originalDeviceAPIEnvironment { if let value { setenv(name, value, 1) } else { unsetenv(name) } }
            try? FileManager.default.removeItem(at: root)
        }

        try body(root)
    }
}
