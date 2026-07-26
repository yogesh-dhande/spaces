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

    func testCanonicalPortNormalizesToEphemeralForDevelopmentProfile() throws {
        try withTemporaryProfile { _ in
            let settings = try SpacesDeviceAPISettingsStore(profileSource: { .developmentWorktree }).loadOrCreate()

            XCTAssertEqual(settings.port, 0)
            XCTAssertEqual(settings.host, SpacesDeviceAPIDefaults.host)
        }
    }

    func testCanonicalPortKeptForInstalledProfile() throws {
        try withTemporaryProfile { _ in
            let settings = try SpacesDeviceAPISettingsStore(profileSource: { .installedFallback }).loadOrCreate()

            XCTAssertEqual(settings.port, SpacesDeviceAPIDefaults.port)
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

    func testEnvironmentPortOverrideWinsOverCanonicalNormalizationForDevelopmentProfile() throws {
        try withTemporaryProfile { _ in
            // Env override to a specific port wins even though the profile would otherwise bind ephemerally.
            let specific = try SpacesDeviceAPISettingsStore(
                environment: [SpacesDeviceAPIDefaults.portEnvironmentVariable: "51234"], profileSource: { .developmentWorktree }
            ).loadOrCreate()
            XCTAssertEqual(specific.port, 51_234)

            // Env override to the canonical port also wins — this is how the Linux systemd install binds it.
            let canonical = try SpacesDeviceAPISettingsStore(
                environment: [SpacesDeviceAPIDefaults.portEnvironmentVariable: String(SpacesDeviceAPIDefaults.port)],
                profileSource: { .developmentWorktree }
            ).loadOrCreate()
            XCTAssertEqual(canonical.port, SpacesDeviceAPIDefaults.port)
        }
    }

    func testFreshCreateNormalizesEffectivePortButStoredFileKeepsCanonicalDefault() throws {
        try withTemporaryProfile { root in
            let settings = try SpacesDeviceAPISettingsStore(profileSource: { .developmentWorktree }).loadOrCreate()
            XCTAssertEqual(settings.port, 0)

            let settingsURL = root.appendingPathComponent("runtime/terminal/device-api.json")
            let storedData = try Data(contentsOf: settingsURL)
            let stored = try JSONDecoder().decode(SpacesDeviceAPISettings.self, from: storedData)
            XCTAssertEqual(stored.port, SpacesDeviceAPIDefaults.port)
        }
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
