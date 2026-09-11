import Foundation
import XCTest
import spacesdatabase
import spacesterminalcore

#if os(Linux)
    import CSQLite3
#else
    import SQLite3
#endif

/// Behavior coverage for the v19→v20 step: `TerminalClientKind`'s raw values were renamed from
/// `localWindow`/`remoteViewer` to `local`/`remote`, and both places that persist the raw string —
/// `terminal_clients.kind` and every client entry inside a `terminal_remote_session_states.payload_json`
/// — must be rewritten in place so an existing row keeps decoding after the rename ships.
final class TerminalClientKindMigrationTests: XCTestCase {
    func testMigrationFromV19RewritesStoredClientKinds() throws {
        let dir = try makeTempDirectory()
        let dbPath = dir.appendingPathComponent("v19.db").path

        // Build the payload with today's enum, then string-substitute the old raw values in: the old
        // cases no longer exist, so this is the only way to reproduce the on-disk shape a v19 profile
        // actually has. `JSONEncoder()` here matches `TerminalSessionPersistence.writeRemoteSessionState`
        // exactly (no `.prettyPrinted`/`.withoutEscapingSlashes`), so the encoded form is the same compact,
        // unspaced JSON a real profile would have on disk.
        let localClient = TerminalClient(
            id: "client-local", kind: .local, identity: TerminalClientIdentity(label: "This Mac"), connectedAt: "2026-09-01T00:00:00Z")
        let remoteClient = TerminalClient(
            id: "client-remote", kind: .remote, identity: TerminalClientIdentity(label: "iPhone"), connectedAt: "2026-09-01T00:00:01Z")
        let withClientsPayload = GhosttyRemoteSessionStatePayload(
            sessionID: "session-with-clients", reason: TerminalRemoteSessionStateReason.attachmentState.rawValue, emittedAt: "2026-09-01T00:00:02Z",
            sessionStateRevision: 1, sessionStateFlags: 0, screenStateRevision: 1, runtimeState: nil,
            attachmentSnapshot: TerminalSessionAttachmentSnapshot(clients: [localClient, remoteClient]), title: "alpha",
            workingDirectory: "/tmp/alpha", outputByteCount: nil)
        let currentEncodedWithClients = String(data: try JSONEncoder().encode(withClientsPayload), encoding: .utf8)!
        XCTAssertTrue(currentEncodedWithClients.contains("\"kind\":\"local\""))
        XCTAssertTrue(currentEncodedWithClients.contains("\"kind\":\"remote\""))
        let legacyEncodedWithClients = currentEncodedWithClients.replacingOccurrences(of: "\"kind\":\"local\"", with: "\"kind\":\"localWindow\"")
            .replacingOccurrences(of: "\"kind\":\"remote\"", with: "\"kind\":\"remoteViewer\"")

        // Proves the fixture actually reproduces the problem: a payload on disk with the old raw values
        // fails to decode against today's `TerminalClientKind`, which is exactly the data loss this
        // migration step exists to prevent.
        XCTAssertThrowsError(try JSONDecoder().decode(GhosttyRemoteSessionStatePayload.self, from: legacyEncodedWithClients.data(using: .utf8)!))

        // A session with no clients carries no `"kind"` at all (the attachment snapshot is omitted when
        // nil), so it must come out of the migration byte-identical.
        let noClientsPayload = GhosttyRemoteSessionStatePayload(
            sessionID: "session-no-clients", reason: TerminalRemoteSessionStateReason.initial.rawValue, emittedAt: "2026-09-01T00:00:03Z",
            sessionStateRevision: 1, sessionStateFlags: 0, screenStateRevision: 1, runtimeState: nil, attachmentSnapshot: nil, title: "beta",
            workingDirectory: "/tmp/beta", outputByteCount: nil)
        let encodedNoClients = String(data: try JSONEncoder().encode(noClientsPayload), encoding: .utf8)!
        XCTAssertFalse(encodedNoClients.contains("\"kind\""))

        try createV19Database(at: dbPath, legacyPayloadWithClients: legacyEncodedWithClients, payloadWithoutClients: encodedNoClients)

        // Opening the database runs the v19→v20 step in place.
        let database = try SpacesSQLiteDatabase(path: dbPath)

        XCTAssertEqual(try scalar(database, "SELECT current_version FROM migration_state"), "\(DatabaseSchema.currentVersion)")

        // terminal_clients.kind is rewritten for both rows.
        XCTAssertEqual(try scalar(database, "SELECT kind FROM terminal_clients WHERE client_id = 'client-local'"), "local")
        XCTAssertEqual(try scalar(database, "SELECT kind FROM terminal_clients WHERE client_id = 'client-remote'"), "remote")

        // The rewritten payload decodes cleanly and carries the renamed cases.
        let rewrittenJSON = try scalar(database, "SELECT payload_json FROM terminal_remote_session_states WHERE session_id = 'session-with-clients'")
        let rewrittenPayload = try JSONDecoder().decode(GhosttyRemoteSessionStatePayload.self, from: rewrittenJSON!.data(using: .utf8)!)
        let rewrittenClients = rewrittenPayload.attachmentSnapshot?.clients ?? []
        XCTAssertEqual(rewrittenClients.first(where: { $0.id == "client-local" })?.kind, .local)
        XCTAssertEqual(rewrittenClients.first(where: { $0.id == "client-remote" })?.kind, .remote)
        // The rewrite only touches the `kind` substrings, so the result matches what encoding the same
        // payload with today's enum produces byte for byte.
        XCTAssertEqual(rewrittenJSON, currentEncodedWithClients)

        // The client-less payload is untouched.
        XCTAssertEqual(
            try scalar(database, "SELECT payload_json FROM terminal_remote_session_states WHERE session_id = 'session-no-clients'"), encodedNoClients)
    }

    private func scalar(_ database: SpacesSQLiteDatabase, _ sql: String) throws -> String? { try database.queryRow(sql: sql)?.first }

    private func makeTempDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    /// Seeds a schema-v19 database: the `migration_state` marker at 19 and the v19-shape
    /// `terminal_clients`/`terminal_remote_session_states` tables the v19→v20 step touches, populated
    /// with the old raw client-kind values.
    private func createV19Database(at path: String, legacyPayloadWithClients: String, payloadWithoutClients: String) throws {
        var handle: OpaquePointer?
        guard sqlite3_open(path, &handle) == SQLITE_OK, let db = handle else {
            XCTFail("Failed opening fixture database at \(path)")
            return
        }
        defer { sqlite3_close(db) }
        let escapedLegacyPayload = legacyPayloadWithClients.replacingOccurrences(of: "'", with: "''")
        let escapedNoClientsPayload = payloadWithoutClients.replacingOccurrences(of: "'", with: "''")
        let sql = """
            CREATE TABLE migration_state (current_version INTEGER NOT NULL);
            INSERT INTO migration_state(current_version) VALUES (19);

            CREATE TABLE terminal_clients (
              root_directory TEXT NOT NULL,
              session_id TEXT NOT NULL,
              client_id TEXT NOT NULL,
              kind TEXT NOT NULL,
              identity_label TEXT NOT NULL,
              identity_host_name TEXT,
              identity_device_name TEXT,
              identity_network_address TEXT,
              connected_at TEXT NOT NULL,
              lease_refreshed_at TEXT NOT NULL,
              disconnected_at TEXT,
              PRIMARY KEY (root_directory, client_id)
            );
            INSERT INTO terminal_clients(
              root_directory, session_id, client_id, kind, identity_label, connected_at, lease_refreshed_at
            ) VALUES ('/tmp/alpha', 'session-with-clients', 'client-local', 'localWindow', 'This Mac', 'now', 'now');
            INSERT INTO terminal_clients(
              root_directory, session_id, client_id, kind, identity_label, connected_at, lease_refreshed_at
            ) VALUES ('/tmp/alpha', 'session-with-clients', 'client-remote', 'remoteViewer', 'iPhone', 'now', 'now');

            CREATE TABLE terminal_remote_session_states (
              session_id TEXT PRIMARY KEY,
              root_directory TEXT NOT NULL UNIQUE,
              payload_json TEXT NOT NULL,
              has_final_render INTEGER NOT NULL DEFAULT 0
            );
            INSERT INTO terminal_remote_session_states(session_id, root_directory, payload_json, has_final_render)
            VALUES ('session-with-clients', '/tmp/alpha', '\(escapedLegacyPayload)', 0);
            INSERT INTO terminal_remote_session_states(session_id, root_directory, payload_json, has_final_render)
            VALUES ('session-no-clients', '/tmp/beta', '\(escapedNoClientsPayload)', 0);
            """
        var errorMessage: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &errorMessage) == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? "unknown sqlite error"
            if let errorMessage { sqlite3_free(errorMessage) }
            XCTFail("Failed seeding v19 fixture: \(message)")
            return
        }
    }
}
