import Foundation
import XCTest

@testable import spacesclientcore
@testable import spacesterminalcore

#if os(Linux)
    import CSQLite3
#else
    import SQLite3
#endif

final class SpacesClientDatabaseTests: XCTestCase {
    func testClientSettingsRoundTripAndClear() throws {
        let database = try makeTemporaryClientDatabase()

        try database.setSetting(key: "app_editor", value: "cursor")
        XCTAssertEqual(try database.setting(key: "app_editor"), "cursor")

        try database.setSetting(key: "app_editor", value: nil)
        XCTAssertNil(try database.setting(key: "app_editor"))
    }

    func testProjectCollapseStateIsScopedByDeviceAndProject() throws {
        let database = try makeTemporaryClientDatabase()

        try database.setProjectCollapsed(deviceID: "local", projectID: "project-1", isCollapsed: true)
        try database.setProjectCollapsed(deviceID: "remote", projectID: "project-1", isCollapsed: false)

        XCTAssertTrue(try database.isProjectCollapsed(deviceID: "local", projectID: "project-1"))
        XCTAssertFalse(try database.isProjectCollapsed(deviceID: "remote", projectID: "project-1"))
        XCTAssertEqual(try database.projectCollapseStates(deviceID: "local"), ["project-1": true])
    }

    func testWorkspacePanelLayoutRoundTripsAndDeletes() throws {
        let database = try makeTemporaryClientDatabase()

        try database.writeWorkspacePanelLayout(deviceID: "local", workspaceID: "ws-1", layoutJSON: "{\"version\":1}")
        XCTAssertEqual(try database.workspacePanelLayout(deviceID: "local", workspaceID: "ws-1"), "{\"version\":1}")

        try database.writeWorkspacePanelLayout(deviceID: "local", workspaceID: "ws-1", layoutJSON: "{\"version\":1,\"tabs\":[]}")
        XCTAssertEqual(try database.workspacePanelLayout(deviceID: "local", workspaceID: "ws-1"), "{\"version\":1,\"tabs\":[]}")

        try database.deleteWorkspacePanelLayout(deviceID: "local", workspaceID: "ws-1")
        XCTAssertNil(try database.workspacePanelLayout(deviceID: "local", workspaceID: "ws-1"))
    }

    func testPanelWindowsRoundTripWithAndWithoutFrames() throws {
        let database = try makeTemporaryClientDatabase()

        try database.upsertPanelWindow(.init(id: "win-1", layoutJSON: "{}", frame: (x: 10, y: 20, width: 800, height: 600)))
        try database.upsertPanelWindow(.init(id: "win-2", layoutJSON: "{}", frame: nil))

        let windows = try database.panelWindows()
        XCTAssertEqual(Set(windows.map(\.id)), ["win-1", "win-2"])
        let framed = try XCTUnwrap(windows.first { $0.id == "win-1" })
        XCTAssertEqual(framed.frame?.x, 10)
        XCTAssertEqual(framed.frame?.height, 600)
        XCTAssertNil(try XCTUnwrap(windows.first { $0.id == "win-2" }).frame)

        try database.deletePanelWindow(id: "win-1")
        XCTAssertEqual(try database.panelWindows().map(\.id), ["win-2"])
    }

    // A database with tables but no readable `migration_state` marker is unrecognized, not
    // upgradeable: opening it fails closed instead of silently resetting or migrating (there are no
    // existing users, so old on-disk databases are deleted by hand instead of carried forward).
    func testOpenFailsClosedWhenMigrationStateMarkerIsMissing() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("spaces-client.db").path

        let database = try SpacesClientDatabase(path: path)
        let record = device(id: "device-untouched")
        try database.upsert(device: record)

        // Remove the marker row while leaving every table (including its data) in place.
        try withRawSQLiteConnection(path: path) { handle in
            XCTAssertEqual(sqlite3_exec(handle, "DELETE FROM migration_state;", nil, nil, nil), SQLITE_OK)
        }

        do {
            _ = try SpacesClientDatabase(path: path)
            XCTFail("Expected opening a database without a migration_state marker to throw.")
        } catch {
            guard case SpacesClientError.invalidArgument(let message) = error else {
                return XCTFail("Expected SpacesClientError.invalidArgument, got \(error)")
            }
            XCTAssertTrue(message.contains("missing migration_state marker"), message)
        }

        // The failed open must not have touched the file: restoring the marker (no data rewrite)
        // reveals the paired-device row is exactly as it was left.
        try withRawSQLiteConnection(path: path) { handle in
            XCTAssertEqual(sqlite3_exec(handle, "INSERT INTO migration_state(current_version) VALUES (1);", nil, nil, nil), SQLITE_OK)
        }
        let reopened = try SpacesClientDatabase(path: path)
        XCTAssertEqual(try reopened.pairedDevice(id: record.id), record)
    }

    // A `migration_state` marker ahead of this build's schema (e.g. a downgrade, or a database from
    // a build that raised the version) is unsupported: opening it fails closed rather than guessing
    // at a downgrade path.
    func testOpenFailsClosedWhenMigrationStateVersionIsAheadOfCurrent() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("spaces-client.db").path

        _ = try SpacesClientDatabase(path: path)
        try withRawSQLiteConnection(path: path) { handle in
            XCTAssertEqual(sqlite3_exec(handle, "DELETE FROM migration_state;", nil, nil, nil), SQLITE_OK)
            XCTAssertEqual(sqlite3_exec(handle, "INSERT INTO migration_state(current_version) VALUES (7);", nil, nil, nil), SQLITE_OK)
        }

        do {
            _ = try SpacesClientDatabase(path: path)
            XCTFail("Expected opening a database with an unsupported schema version to throw.")
        } catch {
            guard case SpacesClientError.invalidArgument(let message) = error else {
                return XCTFail("Expected SpacesClientError.invalidArgument, got \(error)")
            }
            XCTAssertTrue(message.contains("7"), message)
        }
    }

    private func withRawSQLiteConnection(path: String, _ body: (OpaquePointer) throws -> Void) throws {
        var handle: OpaquePointer?
        guard sqlite3_open(path, &handle) == SQLITE_OK, let handle else { throw XCTSkip("Failed opening raw sqlite3 connection at \(path).") }
        defer { sqlite3_close(handle) }
        try body(handle)
    }

    // Any database at a released schema version must reach the current version by applying every
    // intermediate step serially — the step list may never skip a version.
    func testMigrationStepsFormOneSerialChainToCurrentVersion() {
        var version = 1
        while version < SpacesClientDatabase.currentVersion {
            guard let step = SpacesClientDatabase.defaultMigrationSteps.first(where: { $0.fromVersion == version }) else {
                return XCTFail("No client migration step from schema version \(version)")
            }
            XCTAssertEqual(step.toVersion, version + 1, "Step from \(version) must move exactly one version forward")
            version = step.toVersion
        }
    }

    func testDefaultPathUsesEnvironmentOverride() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let overridePath = root.appendingPathComponent("Client/spaces-client.db", isDirectory: false).path
        let originalClientDatabasePath = currentEnvironmentValue(SpacesClientDatabase.databasePathEnvironmentVariable)
        setenv(SpacesClientDatabase.databasePathEnvironmentVariable, overridePath, 1)
        defer {
            restoreEnvironmentValue(originalClientDatabasePath, name: SpacesClientDatabase.databasePathEnvironmentVariable)
            try? FileManager.default.removeItem(at: root)
        }

        XCTAssertEqual(try SpacesClientDatabase.defaultPath(), overridePath)
    }

    func testDefaultPathUsesCurrentProfileRoot() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let profileRoot = root.appendingPathComponent("profile-a", isDirectory: true)
        try FileManager.default.createDirectory(at: profileRoot, withIntermediateDirectories: true)
        let originalDatabasePath = currentEnvironmentValue("SPACES_DB_PATH")
        let originalRuntimePath = currentEnvironmentValue("SPACES_RUNTIME_DIR")
        let originalClientDatabasePath = currentEnvironmentValue(SpacesClientDatabase.databasePathEnvironmentVariable)
        setenv("SPACES_DB_PATH", profileRoot.appendingPathComponent("spaces.db").path, 1)
        setenv("SPACES_RUNTIME_DIR", profileRoot.appendingPathComponent("runtime").path, 1)
        unsetenv(SpacesClientDatabase.databasePathEnvironmentVariable)
        SpacesProfile.resetCacheForTesting()
        defer {
            restoreEnvironmentValue(originalDatabasePath, name: "SPACES_DB_PATH")
            restoreEnvironmentValue(originalRuntimePath, name: "SPACES_RUNTIME_DIR")
            restoreEnvironmentValue(originalClientDatabasePath, name: SpacesClientDatabase.databasePathEnvironmentVariable)
            SpacesProfile.resetCacheForTesting()
            try? FileManager.default.removeItem(at: root)
        }

        XCTAssertEqual(try SpacesClientDatabase.defaultPath(), profileRoot.appendingPathComponent("Client/spaces-client.db", isDirectory: false).path)
    }

    func testDefaultPathUsesHomeScopedProfileRoot() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let originalHome = currentEnvironmentValue("HOME")
        let originalDatabasePath = currentEnvironmentValue("SPACES_DB_PATH")
        let originalRuntimePath = currentEnvironmentValue("SPACES_RUNTIME_DIR")
        let originalClientDatabasePath = currentEnvironmentValue(SpacesClientDatabase.databasePathEnvironmentVariable)
        setenv("HOME", home.path, 1)
        unsetenv("SPACES_DB_PATH")
        unsetenv("SPACES_RUNTIME_DIR")
        unsetenv(SpacesClientDatabase.databasePathEnvironmentVariable)
        SpacesProfile.resetCacheForTesting()
        defer {
            restoreEnvironmentValue(originalHome, name: "HOME")
            restoreEnvironmentValue(originalDatabasePath, name: "SPACES_DB_PATH")
            restoreEnvironmentValue(originalRuntimePath, name: "SPACES_RUNTIME_DIR")
            restoreEnvironmentValue(originalClientDatabasePath, name: SpacesClientDatabase.databasePathEnvironmentVariable)
            SpacesProfile.resetCacheForTesting()
            try? FileManager.default.removeItem(at: home)
        }

        let currentDirectoryPath = FileManager.default.currentDirectoryPath
        let profile = try SpacesProfile.resolve(
            environment: ["HOME": home.path], homeDirectoryURL: home, currentDirectoryPath: currentDirectoryPath,
            executablePath: SpacesProfile.currentExecutablePath(currentDirectoryPath: currentDirectoryPath))
        XCTAssertEqual(
            try SpacesClientDatabase.defaultPath(),
            URL(fileURLWithPath: profile.rootDirectory, isDirectory: true).appendingPathComponent("Client", isDirectory: true).appendingPathComponent(
                "spaces-client.db", isDirectory: false
            ).path)
    }

    func testPairedDevicesAreScopedToCurrentProfile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let profileA = root.appendingPathComponent("profile-a", isDirectory: true)
        let profileB = root.appendingPathComponent("profile-b", isDirectory: true)
        try FileManager.default.createDirectory(at: profileA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: profileB, withIntermediateDirectories: true)
        let originalDatabasePath = currentEnvironmentValue("SPACES_DB_PATH")
        let originalRuntimePath = currentEnvironmentValue("SPACES_RUNTIME_DIR")
        let originalClientDatabasePath = currentEnvironmentValue(SpacesClientDatabase.databasePathEnvironmentVariable)
        unsetenv(SpacesClientDatabase.databasePathEnvironmentVariable)
        defer {
            restoreEnvironmentValue(originalDatabasePath, name: "SPACES_DB_PATH")
            restoreEnvironmentValue(originalRuntimePath, name: "SPACES_RUNTIME_DIR")
            restoreEnvironmentValue(originalClientDatabasePath, name: SpacesClientDatabase.databasePathEnvironmentVariable)
            SpacesProfile.resetCacheForTesting()
            try? FileManager.default.removeItem(at: root)
        }

        setenv("SPACES_DB_PATH", profileA.appendingPathComponent("spaces.db").path, 1)
        setenv("SPACES_RUNTIME_DIR", profileA.appendingPathComponent("runtime").path, 1)
        SpacesProfile.resetCacheForTesting()
        let profileADatabasePath = try SpacesClientDatabase.defaultPath()
        let databaseA = try SpacesClientDatabase()
        let record = device(id: "profile-a-device")
        try databaseA.upsert(device: record)
        XCTAssertEqual(try databaseA.pairedDevices().map(\.id), [record.id])

        setenv("SPACES_DB_PATH", profileB.appendingPathComponent("spaces.db").path, 1)
        setenv("SPACES_RUNTIME_DIR", profileB.appendingPathComponent("runtime").path, 1)
        SpacesProfile.resetCacheForTesting()
        let profileBDatabasePath = try SpacesClientDatabase.defaultPath()
        let databaseB = try SpacesClientDatabase()

        XCTAssertNotEqual(profileADatabasePath, profileBDatabasePath)
        XCTAssertTrue(try databaseB.pairedDevices().isEmpty)
    }

    func testDefaultDatabaseCacheFollowsResolvedDefaultPath() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let databaseAPath = root.appendingPathComponent("a/spaces-client.db", isDirectory: false).path
        let databaseBPath = root.appendingPathComponent("b/spaces-client.db", isDirectory: false).path
        let originalClientDatabasePath = currentEnvironmentValue(SpacesClientDatabase.databasePathEnvironmentVariable)
        defer {
            restoreEnvironmentValue(originalClientDatabasePath, name: SpacesClientDatabase.databasePathEnvironmentVariable)
            try? FileManager.default.removeItem(at: root)
        }

        setenv(SpacesClientDatabase.databasePathEnvironmentVariable, databaseAPath, 1)
        try SpacesClientDatabase.defaultDatabase().setSetting(key: "active_workspace_id", value: "workspace-a")

        setenv(SpacesClientDatabase.databasePathEnvironmentVariable, databaseBPath, 1)
        XCTAssertNil(try SpacesClientDatabase.defaultDatabase().setting(key: "active_workspace_id"))
        try SpacesClientDatabase.defaultDatabase().setSetting(key: "active_workspace_id", value: "workspace-b")

        setenv(SpacesClientDatabase.databasePathEnvironmentVariable, databaseAPath, 1)
        XCTAssertEqual(try SpacesClientDatabase.defaultDatabase().setting(key: "active_workspace_id"), "workspace-a")

        setenv(SpacesClientDatabase.databasePathEnvironmentVariable, databaseBPath, 1)
        XCTAssertEqual(try SpacesClientDatabase.defaultDatabase().setting(key: "active_workspace_id"), "workspace-b")
    }

    func testDefaultDatabaseSerializesConcurrentSharedConnectionOperations() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let databasePath = root.appendingPathComponent("Client/spaces-client.db", isDirectory: false).path
        let originalClientDatabasePath = currentEnvironmentValue(SpacesClientDatabase.databasePathEnvironmentVariable)
        setenv(SpacesClientDatabase.databasePathEnvironmentVariable, databasePath, 1)
        defer {
            restoreEnvironmentValue(originalClientDatabasePath, name: SpacesClientDatabase.databasePathEnvironmentVariable)
            try? FileManager.default.removeItem(at: root)
        }

        let queue = DispatchQueue(label: "spaces-client-database-concurrency", attributes: .concurrent)
        let group = DispatchGroup()
        let errors = ErrorCollector()
        let records = (0..<50).map { device(id: "device-\($0)") }

        for (index, record) in records.enumerated() {
            group.enter()
            queue.async {
                defer { group.leave() }
                do {
                    let database = try SpacesClientDatabase.defaultDatabase()
                    let id = record.id
                    try database.upsert(device: record)
                    try database.setSetting(key: "setting-\(index)", value: "value-\(index)")
                    try database.setProjectCollapsed(deviceID: id, projectID: "project-\(index)", isCollapsed: true)
                    try database.deletePairedDevice(id: id)
                } catch { errors.append(error) }
            }
        }

        group.wait()

        let collectedErrors = errors.values()
        XCTAssertTrue(collectedErrors.isEmpty, collectedErrors.map(\.localizedDescription).joined(separator: "\n"))
        XCTAssertTrue(try SpacesClientDatabase.defaultDatabase().pairedDevices().isEmpty)
    }

    func testPairedDeviceMetadataPersistsWithoutToken() throws {
        try withTemporaryProfile { root in
            let databaseURL = root.appendingPathComponent("Client/spaces-client.db", isDirectory: false)
            let database = try SpacesClientDatabase(path: databaseURL.path)
            let record = device(id: "device-1")

            try database.upsert(device: record)
            try SpacesDeviceCredentialStore.saveToken("SECRET-TOKEN", deviceID: record.id)
            defer { try? SpacesDeviceCredentialStore.deleteToken(deviceID: record.id) }

            let reopened = try SpacesClientDatabase(path: databaseURL.path)
            XCTAssertEqual(try reopened.pairedDevice(id: record.id), record)
            XCTAssertEqual(try SpacesDeviceCredentialStore.token(deviceID: record.id), "SECRET-TOKEN")

            let databaseBytes = try Data(contentsOf: databaseURL)
            XCTAssertNil(String(data: databaseBytes, encoding: .utf8)?.range(of: "SECRET-TOKEN"))
        }
    }

    func testFreshDatabaseReportsNoBackups() throws {
        try withTemporaryProfile { root in
            let databaseURL = root.appendingPathComponent("Client/spaces-client.db", isDirectory: false)
            let database = try SpacesClientDatabase(path: databaseURL.path)

            XCTAssertEqual(try database.backupURLs(), [])
        }
    }

    func testFailedMigrationRestoresBackup() throws {
        try withTemporaryProfile { root in
            let databaseURL = root.appendingPathComponent("Client/spaces-client.db", isDirectory: false)
            let database = try SpacesClientDatabase(path: databaseURL.path)
            let record = device(id: "device-rollback")
            try database.upsert(device: record)
            try SpacesDeviceCredentialStore.saveToken("SECRET-TOKEN", deviceID: record.id)
            defer { try? SpacesDeviceCredentialStore.deleteToken(deviceID: record.id) }

            let failingStep = SpacesClientMigrationStep(
                fromVersion: SpacesClientDatabase.currentVersion, toVersion: SpacesClientDatabase.currentVersion + 1,
                description: "Intentional failure"
            ) { _ in throw NSError(domain: "SpacesClientDatabaseTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "boom"]) }
            XCTAssertThrowsError(
                try SpacesClientDatabase(
                    path: databaseURL.path, currentVersion: SpacesClientDatabase.currentVersion + 1, migrationSteps: [failingStep]))

            let restored = try SpacesClientDatabase(path: databaseURL.path)
            XCTAssertEqual(try restored.pairedDevice(id: record.id), record)

            let backupURLs = try restored.backupURLs()
            XCTAssertEqual(backupURLs.count, 1)
            let backupBytes = try Data(contentsOf: backupURLs[0])
            XCTAssertNil(String(data: backupBytes, encoding: .utf8)?.range(of: "SECRET-TOKEN"))
        }
    }

    func testBrowserSessionWindowIDsListAllAndClearAllScopedToWorkspace() throws {
        let database = try makeTemporaryClientDatabase()
        let deviceID = "device-local"
        try database.setBrowserSessionWindowID(deviceID: deviceID, workspaceID: "ws-1", targetURL: "http://localhost:3000", windowID: 11)
        try database.setBrowserSessionWindowID(deviceID: deviceID, workspaceID: "ws-1", targetURL: "http://localhost:4000", windowID: 22)
        try database.setBrowserSessionWindowID(deviceID: deviceID, workspaceID: "ws-2", targetURL: "http://localhost:3000", windowID: 33)

        let workspaceOneWindows = try database.browserSessionWindowIDs(deviceID: deviceID, workspaceID: "ws-1")
        XCTAssertEqual(Set(workspaceOneWindows.map(\.windowID)), [11, 22])
        XCTAssertEqual(Set(workspaceOneWindows.map(\.targetURL)), ["http://localhost:3000", "http://localhost:4000"])

        // Stopping a workspace clears all of its tracked browser-session tab locations, and only that workspace's.
        try database.clearBrowserSessionWindowIDs(deviceID: deviceID, workspaceID: "ws-1")
        XCTAssertTrue(try database.browserSessionWindowIDs(deviceID: deviceID, workspaceID: "ws-1").isEmpty)
        XCTAssertEqual(try database.browserSessionWindowID(deviceID: deviceID, workspaceID: "ws-2", targetURL: "http://localhost:3000"), 33)
    }

    func testTerminalOwnerClientIDPersistsUpdatesAndScopesByDeviceAndSession() throws {
        let database = try makeTemporaryClientDatabase()

        XCTAssertNil(try database.terminalOwnerClientID(deviceID: "local", sessionID: "session-1"))

        try database.setTerminalOwnerClientID(deviceID: "local", sessionID: "session-1", clientID: "client-a")
        XCTAssertEqual(try database.terminalOwnerClientID(deviceID: "local", sessionID: "session-1"), "client-a")

        // A later successful owner attach replaces the mapping for the same (device, session).
        try database.setTerminalOwnerClientID(deviceID: "local", sessionID: "session-1", clientID: "client-b")
        XCTAssertEqual(try database.terminalOwnerClientID(deviceID: "local", sessionID: "session-1"), "client-b")

        // Distinct sessions and devices keep separate mappings.
        try database.setTerminalOwnerClientID(deviceID: "local", sessionID: "session-2", clientID: "client-c")
        try database.setTerminalOwnerClientID(deviceID: "remote", sessionID: "session-1", clientID: "client-d")
        XCTAssertEqual(try database.terminalOwnerClientID(deviceID: "local", sessionID: "session-2"), "client-c")
        XCTAssertEqual(try database.terminalOwnerClientID(deviceID: "remote", sessionID: "session-1"), "client-d")
        XCTAssertEqual(try database.terminalOwnerClientID(deviceID: "local", sessionID: "session-1"), "client-b")
    }

    // A version-1 database (this build's first shipped schema) upgrades to version 2 by adding the
    // terminal owner client id table while carrying every existing row forward untouched.
    func testMigratesVersionOneDatabaseToTerminalOwnerClientIDs() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("spaces-client.db").path

        // Open at version 1 with no migration steps and seed a device. `createSchema` writes the whole
        // current schema, so drop the terminal table by hand to reproduce a genuine pre-version-2
        // on-disk database that lacks it.
        let versionOne = try SpacesClientDatabase(path: path, currentVersion: 1, migrationSteps: [])
        let record = device(id: "device-carried-forward")
        try versionOne.upsert(device: record)
        try withRawSQLiteConnection(path: path) { handle in
            XCTAssertEqual(sqlite3_exec(handle, "DROP TABLE terminal_owner_client_ids;", nil, nil, nil), SQLITE_OK)
        }

        // Reopening at the current version runs the 1 -> 2 step, which recreates the table.
        let upgraded = try SpacesClientDatabase(path: path)
        XCTAssertEqual(try upgraded.pairedDevice(id: record.id), record)
        try upgraded.setTerminalOwnerClientID(deviceID: "local", sessionID: "session-1", clientID: "client-a")
        XCTAssertEqual(try upgraded.terminalOwnerClientID(deviceID: "local", sessionID: "session-1"), "client-a")
    }

    private func device(id: String) -> SpacesPairedDeviceRecord {
        SpacesPairedDeviceRecord(
            id: id, name: "Studio Mac", platform: "macos", host: "studio.local", port: 7443, certificateFingerprint: "SHA256:abc",
            sshHost: "studio.local", sshUser: "yogesh", sshPort: 22, createdAt: "2026-06-17T00:00:00Z", updatedAt: "2026-06-17T00:00:00Z",
            lastSelectedAt: "2026-06-17T00:01:00Z")
    }

    private func makeTemporaryClientDatabase() throws -> SpacesClientDatabase {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return try SpacesClientDatabase(path: root.appendingPathComponent("spaces-client.db").path)
    }

    private func withTemporaryProfile(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let originalDatabasePath = currentEnvironmentValue("SPACES_DB_PATH")
        let originalRuntimePath = currentEnvironmentValue("SPACES_RUNTIME_DIR")
        let originalClientDatabasePath = currentEnvironmentValue(SpacesClientDatabase.databasePathEnvironmentVariable)
        let originalClientSecretDirectory = currentEnvironmentValue(SpacesDeviceCredentialStore.secretDirectoryEnvironmentVariable)
        setenv("SPACES_DB_PATH", root.appendingPathComponent("daemon/spaces.db").path, 1)
        setenv("SPACES_RUNTIME_DIR", root.appendingPathComponent("daemon/runtime").path, 1)
        setenv(SpacesDeviceCredentialStore.secretDirectoryEnvironmentVariable, root.appendingPathComponent("Client/Secrets").path, 1)
        unsetenv(SpacesClientDatabase.databasePathEnvironmentVariable)
        SpacesProfile.resetCacheForTesting()
        defer {
            restoreEnvironmentValue(originalDatabasePath, name: "SPACES_DB_PATH")
            restoreEnvironmentValue(originalRuntimePath, name: "SPACES_RUNTIME_DIR")
            restoreEnvironmentValue(originalClientDatabasePath, name: SpacesClientDatabase.databasePathEnvironmentVariable)
            restoreEnvironmentValue(originalClientSecretDirectory, name: SpacesDeviceCredentialStore.secretDirectoryEnvironmentVariable)
            SpacesProfile.resetCacheForTesting()
            try? FileManager.default.removeItem(at: root)
        }

        try body(root)
    }

    private func currentEnvironmentValue(_ name: String) -> String? {
        guard let value = getenv(name) else { return nil }
        return String(cString: value)
    }

    private func restoreEnvironmentValue(_ value: String?, name: String) { if let value { setenv(name, value, 1) } else { unsetenv(name) } }
}

private final class ErrorCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var errors: [Error] = []

    func append(_ error: Error) {
        lock.lock()
        errors.append(error)
        lock.unlock()
    }

    func values() -> [Error] {
        lock.lock()
        defer { lock.unlock() }
        return errors
    }
}
