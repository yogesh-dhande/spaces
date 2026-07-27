import Foundation
import spacesdatabase

public struct TerminalSessionLaunchConfiguration: Codable, Sendable, Equatable {
    public let sessionID: String
    public let backend: TerminalSessionBackendKind
    public let lifetimePolicy: TerminalSessionLifetimePolicy
    public let workspaceID: String
    public let kind: TerminalSessionKind
    public let title: String
    /// Manual rename applied by the user via `renameTerminalSession`. Kept separate from
    /// `title` (the launch-time title) because the runtime title is continuously rewritten
    /// from Ghostty set_title events; a set user title must win over both.
    public let userTitle: String?
    public let workingDirectory: String
    public let shell: String
    public let command: String?
    public let createdAt: String

    public init(
        sessionID: String, backend: TerminalSessionBackendKind = .ghosttyEmbedded, lifetimePolicy: TerminalSessionLifetimePolicy = .persistent,
        title: String, workingDirectory: String, shell: String, command: String?, createdAt: String, workspaceID: String, kind: TerminalSessionKind,
        userTitle: String? = nil
    ) {
        self.sessionID = sessionID
        self.backend = backend
        self.lifetimePolicy = lifetimePolicy
        self.workspaceID = workspaceID
        self.kind = kind
        self.title = title
        self.userTitle = userTitle
        self.workingDirectory = workingDirectory
        self.shell = shell
        self.command = command
        self.createdAt = createdAt
    }

    enum CodingKeys: String, CodingKey {
        case sessionID
        case backend
        case lifetimePolicy
        case workspaceID
        case kind
        case title
        case userTitle
        case workingDirectory
        case shell
        case command
        case createdAt
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionID = try container.decode(String.self, forKey: .sessionID)
        backend = try container.decodeIfPresent(TerminalSessionBackendKind.self, forKey: .backend) ?? .ghosttyEmbedded
        lifetimePolicy = try container.decodeIfPresent(TerminalSessionLifetimePolicy.self, forKey: .lifetimePolicy) ?? .persistent
        workspaceID = try container.decode(String.self, forKey: .workspaceID)
        kind = try container.decodeIfPresent(TerminalSessionKind.self, forKey: .kind) ?? .shell
        title = try container.decode(String.self, forKey: .title)
        userTitle = try container.decodeIfPresent(String.self, forKey: .userTitle)
        workingDirectory = try container.decode(String.self, forKey: .workingDirectory)
        shell = try container.decode(String.self, forKey: .shell)
        command = try container.decodeIfPresent(String.self, forKey: .command)
        createdAt = try container.decode(String.self, forKey: .createdAt)
    }
}

public struct TerminalSessionRuntimeState: Codable, Sendable, Equatable {
    public let sessionID: String
    public let backend: TerminalSessionBackendKind
    public let servicePID: Int32
    public let childPID: Int32?
    public let foregroundPID: Int32?
    public let foregroundExecutablePath: String?
    public let foregroundExecutableName: String?
    public let foregroundArgv: [String]?
    public let foregroundDetectedAgentKind: TerminalDetectedAgentKind?
    public let foregroundDisplayLabel: String?
    public let foregroundDisplayCommand: String?
    public let title: String?
    public let workingDirectory: String?
    public let columns: Int?
    public let rows: Int?
    public let state: TerminalSessionState
    public let updatedAt: String
    public let exitedAt: String?

    public init(
        sessionID: String, backend: TerminalSessionBackendKind = .ghosttyEmbedded, servicePID: Int32, childPID: Int32?, state: TerminalSessionState,
        updatedAt: String, exitedAt: String? = nil, title: String? = nil, workingDirectory: String? = nil, columns: Int? = nil, rows: Int? = nil,
        foregroundPID: Int32? = nil, foregroundExecutablePath: String? = nil, foregroundExecutableName: String? = nil,
        foregroundArgv: [String]? = nil, foregroundDetectedAgentKind: TerminalDetectedAgentKind? = nil, foregroundDisplayLabel: String? = nil,
        foregroundDisplayCommand: String? = nil
    ) {
        self.sessionID = sessionID
        self.backend = backend
        self.servicePID = servicePID
        self.childPID = childPID
        self.foregroundPID = foregroundPID
        self.foregroundExecutablePath = foregroundExecutablePath
        self.foregroundExecutableName = foregroundExecutableName
        self.foregroundArgv = foregroundArgv
        self.foregroundDetectedAgentKind = foregroundDetectedAgentKind
        self.foregroundDisplayLabel = foregroundDisplayLabel
        self.foregroundDisplayCommand = foregroundDisplayCommand
        self.title = title
        self.workingDirectory = workingDirectory
        self.columns = columns
        self.rows = rows
        self.state = state
        self.updatedAt = updatedAt
        self.exitedAt = exitedAt
    }

    enum CodingKeys: String, CodingKey {
        case sessionID
        case backend
        case servicePID
        case childPID
        case foregroundPID
        case foregroundExecutablePath
        case foregroundExecutableName
        case foregroundArgv
        case foregroundDetectedAgentKind
        case foregroundDisplayLabel
        case foregroundDisplayCommand
        case title
        case workingDirectory
        case columns
        case rows
        case state
        case updatedAt
        case exitedAt
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionID = try container.decode(String.self, forKey: .sessionID)
        backend = try container.decodeIfPresent(TerminalSessionBackendKind.self, forKey: .backend) ?? .ghosttyEmbedded
        servicePID = try container.decode(Int32.self, forKey: .servicePID)
        childPID = try container.decodeIfPresent(Int32.self, forKey: .childPID)
        foregroundPID = try container.decodeIfPresent(Int32.self, forKey: .foregroundPID)
        foregroundExecutablePath = try container.decodeIfPresent(String.self, forKey: .foregroundExecutablePath)
        foregroundExecutableName = try container.decodeIfPresent(String.self, forKey: .foregroundExecutableName)
        foregroundArgv = try container.decodeIfPresent([String].self, forKey: .foregroundArgv)
        foregroundDetectedAgentKind = try container.decodeIfPresent(TerminalDetectedAgentKind.self, forKey: .foregroundDetectedAgentKind)
        foregroundDisplayLabel = try container.decodeIfPresent(String.self, forKey: .foregroundDisplayLabel)
        foregroundDisplayCommand = try container.decodeIfPresent(String.self, forKey: .foregroundDisplayCommand)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        workingDirectory = try container.decodeIfPresent(String.self, forKey: .workingDirectory)
        columns = try container.decodeIfPresent(Int.self, forKey: .columns)
        rows = try container.decodeIfPresent(Int.self, forKey: .rows)
        state = try container.decode(TerminalSessionState.self, forKey: .state)
        updatedAt = try container.decode(String.self, forKey: .updatedAt)
        exitedAt = try container.decodeIfPresent(String.self, forKey: .exitedAt)
    }

    /// Identifies one run of a session: the child PID differs per launch and the exit timestamp per
    /// exit, so together they identify a single run. Used to tie ended-scrollback replay state and the
    /// transcript response to a specific run, so a transcript fetch that straddles a relaunch is
    /// rejected by data rather than by state-delivery timing.
    public var runIdentity: String { "\(childPID.map(String.init) ?? "-")|\(exitedAt ?? "-")" }
}

public struct TerminalSessionAttachmentSnapshot: Codable, Sendable, Equatable {
    public var clients: [TerminalClient]
    public var attachments: [TerminalAttachment]

    public init(clients: [TerminalClient] = [], attachments: [TerminalAttachment] = []) {
        self.clients = clients
        self.attachments = attachments
    }

    /// Attachments backed by a still-present client. An attachment counts as live only
    /// when it is not detached, its client is not disconnected, and — for the kinds whose
    /// liveness the lease decides (`TerminalClientKind.livenessDependsOnLease`, i.e. those
    /// that can vanish without sending a detach) — its lease was refreshed within
    /// `remoteClientLeaseInterval`. A local window client is always live while attached, and
    /// its lease is never even read. This is the single source of truth for liveness; the
    /// persistence query and any off-device consumer both judge attachments through this rule,
    /// so an expired remote viewer is never mistaken for a live attachment.
    public func liveAttachments(now: Date = Date(), remoteClientLeaseInterval: TimeInterval = TerminalSessionPersistence.remoteClientLeaseInterval)
        -> [TerminalAttachment]
    {
        let cutoff = now.addingTimeInterval(-remoteClientLeaseInterval)
        let clientsByID = Dictionary(clients.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return attachments.filter { attachment in
            guard attachment.detachedAt == nil, let client = clientsByID[attachment.clientID], client.disconnectedAt == nil else { return false }
            guard client.kind.livenessDependsOnLease else { return true }
            guard let lastSeenAt = TerminalSessionPersistence.parseISO8601(client.leaseRefreshedAt ?? ""), lastSeenAt >= cutoff else { return false }
            return true
        }
    }
}

public enum TerminalSessionPersistence {
    public static let remoteClientLeaseInterval: TimeInterval = 60

    /// Writes the launch-time configuration. `user_title` is intentionally excluded: it is owned
    /// by `writeUserTitle` (the rename command), so launch-config rewrites can never clobber a
    /// manual rename.
    public static func writeLaunchConfiguration(_ configuration: TerminalSessionLaunchConfiguration, paths: TerminalSessionPaths) throws {
        try paths.ensureDirectories()
        let root = normalizedRootDirectory(paths.rootDirectory)
        try withProfileDatabaseTransaction { database in
            try database.execute(
                sql: "DELETE FROM terminal_sessions WHERE root_directory = ? AND session_id <> ?", bindings: [root, configuration.sessionID])
            try database.execute(
                sql: """
                    INSERT INTO terminal_sessions(
                      session_id, root_directory, backend, lifetime_policy, workspace_id, kind, title, working_directory, shell, command, created_at
                    )
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, NULLIF(?, ''), ?)
                    ON CONFLICT(session_id) DO UPDATE SET
                      root_directory = excluded.root_directory,
                      backend = excluded.backend,
                      lifetime_policy = excluded.lifetime_policy,
                      workspace_id = excluded.workspace_id,
                      kind = excluded.kind,
                      title = excluded.title,
                      working_directory = excluded.working_directory,
                      shell = excluded.shell,
                      command = excluded.command,
                      created_at = excluded.created_at
                    """,
                bindings: [
                    configuration.sessionID, root, configuration.backend.rawValue, configuration.lifetimePolicy.rawValue, configuration.workspaceID,
                    configuration.kind.rawValue, configuration.title, configuration.workingDirectory, configuration.shell,
                    configuration.command ?? "", configuration.createdAt,
                ])
        }
    }

    /// Persists a manual rename for the session. The stored user title takes precedence over
    /// the auto-updated runtime title when the session's effective title is computed.
    public static func writeUserTitle(_ userTitle: String, sessionID: String, paths: TerminalSessionPaths) throws {
        let root = normalizedRootDirectory(paths.rootDirectory)
        try withProfileDatabaseTransaction { database in
            let canonicalSessionID = try existingSessionID(rootDirectory: root, database: database)
            guard canonicalSessionID == sessionID else { throw TerminalSessionPersistenceError.unknownSession(sessionID) }
            try database.execute(
                sql: "UPDATE terminal_sessions SET user_title = NULLIF(?, '') WHERE root_directory = ?", bindings: [userTitle, root])
        }
    }

    /// Persists the session's runtime state. Requires the session's own `terminal_sessions` row, the way
    /// every other per-session write does: a runtime row that outlives (or precedes) its session row is
    /// invisible to every session-driven sweep, so it can never be repaired or reclaimed.
    public static func writeRuntimeState(_ state: TerminalSessionRuntimeState, paths: TerminalSessionPaths, databasePath: String? = nil) throws {
        try paths.ensureDirectories()
        let root = normalizedRootDirectory(paths.rootDirectory)
        let foregroundArgvJSON = try encodeForegroundArgv(state.foregroundArgv)
        try withProfileDatabaseTransaction(at: databasePath) { database in
            let existingSessionID = try existingSessionID(rootDirectory: root, database: database)
            guard existingSessionID == state.sessionID else { throw TerminalSessionPersistenceError.unknownSession(state.sessionID) }
            try database.execute(
                sql: "DELETE FROM terminal_runtime_states WHERE root_directory = ? AND session_id <> ?", bindings: [root, state.sessionID])
            try database.execute(
                sql: """
                    INSERT INTO terminal_runtime_states(
                      session_id, root_directory, backend, service_pid, child_pid, title, working_directory, columns, rows, state, updated_at, exited_at,
                      foreground_pid, foreground_executable_path, foreground_executable_name, foreground_argv_json,
                      foreground_detected_agent_kind, foreground_display_label, foreground_display_command
                    )
                    VALUES (?, ?, ?, ?, ?, NULLIF(?, ''), NULLIF(?, ''), ?, ?, ?, ?, NULLIF(?, ''), ?, NULLIF(?, ''), NULLIF(?, ''),
                            NULLIF(?, ''), NULLIF(?, ''), NULLIF(?, ''), NULLIF(?, ''))
                    ON CONFLICT(session_id) DO UPDATE SET
                      root_directory = excluded.root_directory,
                      backend = excluded.backend,
                      service_pid = excluded.service_pid,
                      child_pid = excluded.child_pid,
                      title = excluded.title,
                      working_directory = excluded.working_directory,
                      columns = excluded.columns,
                      rows = excluded.rows,
                      state = excluded.state,
                      updated_at = excluded.updated_at,
                      exited_at = excluded.exited_at,
                      foreground_pid = excluded.foreground_pid,
                      foreground_executable_path = excluded.foreground_executable_path,
                      foreground_executable_name = excluded.foreground_executable_name,
                      foreground_argv_json = excluded.foreground_argv_json,
                      foreground_detected_agent_kind = excluded.foreground_detected_agent_kind,
                      foreground_display_label = excluded.foreground_display_label,
                      foreground_display_command = excluded.foreground_display_command
                    """,
                bindings: [
                    state.sessionID, root, state.backend.rawValue, state.servicePID, state.childPID.map { Int($0) } as Any? ?? NSNull(),
                    state.title ?? "", state.workingDirectory ?? "", state.columns as Any? ?? NSNull(), state.rows as Any? ?? NSNull(),
                    state.state.rawValue, state.updatedAt, state.exitedAt ?? "", state.foregroundPID.map { Int($0) } as Any? ?? NSNull(),
                    state.foregroundExecutablePath ?? "", state.foregroundExecutableName ?? "", foregroundArgvJSON ?? "",
                    state.foregroundDetectedAgentKind?.rawValue ?? "", state.foregroundDisplayLabel ?? "", state.foregroundDisplayCommand ?? "",
                ])
        }
    }

    public static func writeRemoteSessionState(_ payload: GhosttyRemoteSessionStatePayload, paths: TerminalSessionPaths, databasePath: String? = nil)
        throws
    {
        try paths.ensureDirectories()
        let root = normalizedRootDirectory(paths.rootDirectory)
        let encodedPayload = try JSONEncoder().encode(payload)
        guard let payloadJSON = String(data: encodedPayload, encoding: .utf8) else {
            throw TerminalSessionPersistenceError.invalidValue("payload_json", "<non-utf8>")
        }
        // Stored alongside the payload so readers answer "can this ended pane replay?" without decoding
        // it. The writer already holds the decoded update (the render-update decode cache was seeded by
        // whoever materialized this frame), so computing it here costs nothing.
        let hasFinalRender = payload.renderSnapshot != nil
        try withProfileDatabaseTransaction(at: databasePath) { database in
            let sessionID = try existingSessionID(rootDirectory: root, database: database)
            guard sessionID == payload.sessionID else { throw TerminalSessionPersistenceError.unknownSession(payload.sessionID) }
            try database.execute(
                sql: "DELETE FROM terminal_remote_session_states WHERE root_directory = ? AND session_id <> ?", bindings: [root, payload.sessionID])
            try database.execute(
                sql: """
                    INSERT INTO terminal_remote_session_states(session_id, root_directory, payload_json, has_final_render)
                    VALUES (?, ?, ?, ?)
                    ON CONFLICT(session_id) DO UPDATE SET
                      root_directory = excluded.root_directory,
                      payload_json = excluded.payload_json,
                      has_final_render = excluded.has_final_render
                    """, bindings: [payload.sessionID, root, payloadJSON, hasFinalRender ? 1 : 0])
        }
    }

    public static func writeAttachmentSnapshot(_ snapshot: TerminalSessionAttachmentSnapshot, paths: TerminalSessionPaths) throws {
        try paths.ensureDirectories()
        let root = normalizedRootDirectory(paths.rootDirectory)
        try withProfileDatabaseTransaction { database in
            let sessionID = try existingSessionID(rootDirectory: root, database: database)
            for attachment in snapshot.attachments where attachment.sessionID != sessionID {
                throw TerminalSessionPersistenceError.unknownSession(attachment.sessionID)
            }
            try database.execute(sql: "DELETE FROM terminal_attachments WHERE root_directory = ?", bindings: [root])
            try database.execute(sql: "DELETE FROM terminal_clients WHERE root_directory = ?", bindings: [root])
            for client in snapshot.clients {
                try upsertClient(client, sessionID: sessionID, rootDirectory: root, leaseRefreshedAt: client.connectedAt, database: database)
            }
            for attachment in snapshot.attachments {
                try database.execute(
                    sql: """
                        INSERT INTO terminal_attachments(id, root_directory, session_id, client_id, mode, attached_at, detached_at)
                        VALUES (?, ?, ?, ?, ?, ?, NULLIF(?, ''))
                        """,
                    bindings: [
                        attachment.id, root, sessionID, attachment.clientID, attachment.mode.rawValue, attachment.attachedAt,
                        attachment.detachedAt ?? "",
                    ])
            }
        }
    }

    public static func readLaunchConfiguration(paths: TerminalSessionPaths) throws -> TerminalSessionLaunchConfiguration {
        let root = normalizedRootDirectory(paths.rootDirectory)
        return try withProfileDatabase { database in
            let row = try database.queryRow(
                sql: """
                    SELECT session_id, backend, lifetime_policy, workspace_id, kind, title, working_directory, shell, COALESCE(command, ''),
                           created_at, COALESCE(user_title, '')
                    FROM terminal_sessions
                    WHERE root_directory = ?
                    """, bindings: [root])
            guard let row else { throw TerminalSessionPersistenceError.unknownSession(root) }
            return try decodeLaunchConfiguration(row: row)
        }
    }

    public static func readRuntimeState(paths: TerminalSessionPaths) throws -> TerminalSessionRuntimeState {
        let root = normalizedRootDirectory(paths.rootDirectory)
        return try withProfileDatabase { database in
            let row = try database.queryRow(
                sql: """
                    SELECT session_id, backend, service_pid, COALESCE(child_pid, ''), COALESCE(title, ''), COALESCE(working_directory, ''),
                           COALESCE(columns, ''), COALESCE(rows, ''), state, updated_at, COALESCE(exited_at, ''),
                           COALESCE(foreground_pid, ''), COALESCE(foreground_executable_path, ''),
                           COALESCE(foreground_executable_name, ''), COALESCE(foreground_argv_json, ''),
                           COALESCE(foreground_detected_agent_kind, ''), COALESCE(foreground_display_label, ''),
                           COALESCE(foreground_display_command, '')
                    FROM terminal_runtime_states
                    WHERE root_directory = ?
                    """, bindings: [root])
            guard let row else { throw TerminalSessionPersistenceError.unknownSession(root) }
            return try decodeRuntimeState(row: row)
        }
    }

    public static func readAttachmentSnapshot(paths: TerminalSessionPaths) throws -> TerminalSessionAttachmentSnapshot {
        let root = normalizedRootDirectory(paths.rootDirectory)
        return try withProfileDatabase { database in
            let clients = try database.queryRows(
                sql: """
                    SELECT client_id, kind, identity_label, COALESCE(identity_host_name, ''), COALESCE(identity_device_name, ''),
                           COALESCE(identity_network_address, ''), connected_at, COALESCE(disconnected_at, ''), lease_refreshed_at
                    FROM terminal_clients
                    WHERE root_directory = ?
                    ORDER BY connected_at, client_id
                    """, bindings: [root]
            ).map(decodeClient(row:))
            let attachments = try database.queryRows(
                sql: """
                    SELECT id, session_id, client_id, mode, attached_at, COALESCE(detached_at, '')
                    FROM terminal_attachments
                    WHERE root_directory = ?
                    ORDER BY attached_at, id
                    """, bindings: [root]
            ).map(decodeAttachment(row:))
            return TerminalSessionAttachmentSnapshot(clients: clients, attachments: attachments)
        }
    }

    public static func readRemoteSessionState(paths: TerminalSessionPaths) throws -> GhosttyRemoteSessionStatePayload {
        let root = normalizedRootDirectory(paths.rootDirectory)
        return try withProfileDatabase { database in
            let row = try database.queryRow(
                sql: """
                    SELECT payload_json
                    FROM terminal_remote_session_states
                    WHERE root_directory = ?
                    """, bindings: [root])
            guard let payloadJSON = row?.first else { throw TerminalSessionPersistenceError.unknownSession(root) }
            guard let data = payloadJSON.data(using: .utf8) else { throw TerminalSessionPersistenceError.invalidValue("payload_json", "<non-utf8>") }
            return try JSONDecoder().decode(GhosttyRemoteSessionStatePayload.self, from: data)
        }
    }

    public static func appendPendingAgentSignal(_ event: TerminalServiceAgentSignalEvent, paths: TerminalSessionPaths) throws {
        try paths.ensureDirectories()
        let root = normalizedRootDirectory(paths.rootDirectory)
        let environmentKeysJSON = try encodeEnvironmentKeys(event.environmentKeys)
        try withProfileDatabaseTransaction { database in
            let sessionID = try existingSessionID(rootDirectory: root, database: database)
            guard sessionID == event.sessionID else { throw TerminalSessionPersistenceError.unknownSession(event.sessionID) }
            try database.execute(
                sql: """
                    INSERT INTO terminal_agent_signal_events(
                      id, root_directory, session_id, event_type, workspace_id, workspace_path, provider, label, terminal_tracking_id,
                      environment_keys_json, created_at, acknowledged_at
                    )
                    VALUES (?, ?, ?, ?, NULLIF(?, ''), NULLIF(?, ''), ?, NULLIF(?, ''), NULLIF(?, ''), ?, ?, NULL)
                    ON CONFLICT(id) DO UPDATE SET
                      root_directory = excluded.root_directory,
                      session_id = excluded.session_id,
                      event_type = excluded.event_type,
                      workspace_id = excluded.workspace_id,
                      workspace_path = excluded.workspace_path,
                      provider = excluded.provider,
                      label = excluded.label,
                      terminal_tracking_id = excluded.terminal_tracking_id,
                      environment_keys_json = excluded.environment_keys_json,
                      created_at = excluded.created_at,
                      acknowledged_at = NULL
                    """,
                bindings: [
                    event.id, root, event.sessionID, event.type, event.workspaceID ?? "", event.workspacePath ?? "", event.provider,
                    event.label ?? "", event.terminalTrackingID ?? "", environmentKeysJSON, event.createdAt,
                ])
        }
    }

    public static func pendingAgentSignals(sessionID: String, paths: TerminalSessionPaths) throws -> [TerminalServiceAgentSignalEvent] {
        let root = normalizedRootDirectory(paths.rootDirectory)
        return try withProfileDatabase { database in
            let canonicalSessionID = try existingSessionID(rootDirectory: root, database: database)
            guard canonicalSessionID == sessionID else { throw TerminalSessionPersistenceError.unknownSession(sessionID) }
            let rows = try database.queryRows(
                sql: """
                    SELECT id, session_id, COALESCE(workspace_id, ''), COALESCE(workspace_path, ''), event_type, provider, COALESCE(label, ''),
                           COALESCE(terminal_tracking_id, ''),
                           environment_keys_json, created_at
                    FROM terminal_agent_signal_events
                    WHERE root_directory = ? AND session_id = ? AND acknowledged_at IS NULL
                    ORDER BY created_at, id
                    """, bindings: [root, sessionID])
            return try rows.map(decodeAgentSignalEvent(row:))
        }
    }

    public static func acknowledgeAgentSignals(ids: [String], sessionID: String, paths: TerminalSessionPaths, acknowledgedAt: String) throws {
        let normalizedIDs = ids.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !normalizedIDs.isEmpty else { return }
        let root = normalizedRootDirectory(paths.rootDirectory)
        try withProfileDatabaseTransaction { database in
            let canonicalSessionID = try existingSessionID(rootDirectory: root, database: database)
            guard canonicalSessionID == sessionID else { throw TerminalSessionPersistenceError.unknownSession(sessionID) }
            let placeholders = Array(repeating: "?", count: normalizedIDs.count).joined(separator: ",")
            try database.execute(
                sql: """
                    UPDATE terminal_agent_signal_events
                    SET acknowledged_at = ?
                    WHERE root_directory = ?
                      AND session_id = ?
                      AND id IN (\(placeholders))
                    """, bindings: [acknowledgedAt, root, sessionID] + normalizedIDs)
        }
    }

    public static func upsertClient(_ client: TerminalClient, paths: TerminalSessionPaths) throws {
        let root = normalizedRootDirectory(paths.rootDirectory)
        try withProfileDatabaseTransaction { database in
            let sessionID = try existingSessionID(rootDirectory: root, database: database)
            try upsertClient(client, sessionID: sessionID, rootDirectory: root, leaseRefreshedAt: client.connectedAt, database: database)
        }
    }

    /// Refreshes a connected client's lease and reports whether anything was touched. The `disconnected_at IS
    /// NULL` guard makes a lease touch for a durably disconnected client a no-op (returning `false`) rather than
    /// silently resurrecting its lease: a client that was expired/detached must not be able to keep a corpse
    /// alive by heartbeating. Returns `true` only when a live client's lease was refreshed.
    @discardableResult public static func touchClient(
        id clientID: String, paths: TerminalSessionPaths, touchedAt: String, databasePath: String? = nil
    ) throws -> Bool {
        let root = normalizedRootDirectory(paths.rootDirectory)
        return try withProfileDatabaseTransaction(at: databasePath) { database in
            let changes = try database.executeReturningChanges(
                sql: """
                    UPDATE terminal_clients
                    SET lease_refreshed_at = ?
                    WHERE root_directory = ? AND client_id = ? AND disconnected_at IS NULL
                    """, bindings: [touchedAt, root, clientID])
            return changes > 0
        }
    }

    public static func attachClient(
        sessionID: String, client: TerminalClient, mode: TerminalAttachmentMode, paths: TerminalSessionPaths, attachedAt: String
    ) throws {
        let root = normalizedRootDirectory(paths.rootDirectory)
        try paths.ensureDirectories()
        try withProfileDatabaseTransaction { database in
            let canonicalSessionID = try existingSessionID(rootDirectory: root, database: database)
            guard canonicalSessionID == sessionID else { throw TerminalSessionPersistenceError.unknownSession(sessionID) }
            let connectedClient = TerminalClient(
                id: client.id, kind: client.kind, identity: client.identity, connectedAt: client.connectedAt, disconnectedAt: nil)
            try upsertClient(connectedClient, sessionID: sessionID, rootDirectory: root, leaseRefreshedAt: attachedAt, database: database)

            if mode == .owner {
                try database.execute(
                    sql: """
                        UPDATE terminal_attachments
                        SET detached_at = ?
                        WHERE root_directory = ?
                          AND mode = 'owner'
                          AND detached_at IS NULL
                          AND client_id <> ?
                        """, bindings: [attachedAt, root, client.id])
            }

            if let activeRow = try database.queryRow(
                sql: """
                    SELECT id, attached_at
                    FROM terminal_attachments
                    WHERE root_directory = ? AND client_id = ? AND detached_at IS NULL
                    """, bindings: [root, client.id])
            {
                try database.execute(
                    sql: """
                        UPDATE terminal_attachments
                        SET session_id = ?, mode = ?
                        WHERE id = ?
                        """, bindings: [sessionID, mode.rawValue, activeRow[0]])
            } else {
                try database.execute(
                    sql: """
                        INSERT INTO terminal_attachments(id, root_directory, session_id, client_id, mode, attached_at, detached_at)
                        VALUES (?, ?, ?, ?, ?, ?, NULL)
                        """, bindings: [UUID().uuidString, root, sessionID, client.id, mode.rawValue, attachedAt])
            }
        }
    }

    public static func detachClient(id clientID: String, paths: TerminalSessionPaths, detachedAt: String) throws {
        let root = normalizedRootDirectory(paths.rootDirectory)
        try withProfileDatabaseTransaction { database in
            try database.execute(
                sql: """
                    UPDATE terminal_clients
                    SET disconnected_at = ?
                    WHERE root_directory = ? AND client_id = ?
                    """, bindings: [detachedAt, root, clientID])
            try database.execute(
                sql: """
                    UPDATE terminal_attachments
                    SET detached_at = ?
                    WHERE root_directory = ? AND client_id = ? AND detached_at IS NULL
                    """, bindings: [detachedAt, root, clientID])
        }
    }

    public static func detachActiveClients(paths: TerminalSessionPaths, detachedAt: String, databasePath: String? = nil) throws {
        let root = normalizedRootDirectory(paths.rootDirectory)
        try withProfileDatabaseTransaction(at: databasePath) { database in
            try database.execute(
                sql: """
                    UPDATE terminal_clients
                    SET disconnected_at = ?
                    WHERE root_directory = ? AND disconnected_at IS NULL
                    """, bindings: [detachedAt, root])
            try database.execute(
                sql: """
                    UPDATE terminal_attachments
                    SET detached_at = ?
                    WHERE root_directory = ? AND detached_at IS NULL
                    """, bindings: [detachedAt, root])
        }
    }

    /// Finalizes a stale session's repair as ONE all-or-nothing durable unit: the terminal runtime-state
    /// write AND the detach of every still-active client/attachment commit inside a single
    /// `BEGIN IMMEDIATE` transaction. Consolidating them here — the way `expireClients` consolidates
    /// detach+transfer — is load-bearing for the stale-recovery sweep: written as two separate
    /// transactions (`writeRuntimeState` then `detachActiveClients`), a repair whose first write commits
    /// but whose second write then fails through all retries would leave the row terminal with its
    /// attachments still active. The next restart's sweep skips terminal rows, so those ghost
    /// attachments on a dead session would never be cleaned. As one transaction any failure rolls back
    /// untouched, leaving the row in its prior live state so the next restart genuinely heals it via the
    /// dead-pid branch. Kept separate from `writeRuntimeState`/`detachActiveClients`, which still serve
    /// their own single-purpose callers.
    ///
    /// The repair writes rows only and deliberately does not create the session's directory: it runs
    /// against sessions discovered from their stored root, whose directory may be gone or outside this
    /// profile, and recreating one would litter a path the profile does not own.
    public static func finalizeSessionRepair(_ runtimeState: TerminalSessionRuntimeState, detachedAt: String, paths: TerminalSessionPaths) throws {
        let root = normalizedRootDirectory(paths.rootDirectory)
        let foregroundArgvJSON = try encodeForegroundArgv(runtimeState.foregroundArgv)
        try withProfileDatabaseTransaction { database in
            try database.execute(
                sql: "DELETE FROM terminal_runtime_states WHERE root_directory = ? AND session_id <> ?", bindings: [root, runtimeState.sessionID])
            try database.execute(
                sql: """
                    INSERT INTO terminal_runtime_states(
                      session_id, root_directory, backend, service_pid, child_pid, title, working_directory, columns, rows, state, updated_at, exited_at,
                      foreground_pid, foreground_executable_path, foreground_executable_name, foreground_argv_json,
                      foreground_detected_agent_kind, foreground_display_label, foreground_display_command
                    )
                    VALUES (?, ?, ?, ?, ?, NULLIF(?, ''), NULLIF(?, ''), ?, ?, ?, ?, NULLIF(?, ''), ?, NULLIF(?, ''), NULLIF(?, ''),
                            NULLIF(?, ''), NULLIF(?, ''), NULLIF(?, ''), NULLIF(?, ''))
                    ON CONFLICT(session_id) DO UPDATE SET
                      root_directory = excluded.root_directory,
                      backend = excluded.backend,
                      service_pid = excluded.service_pid,
                      child_pid = excluded.child_pid,
                      title = excluded.title,
                      working_directory = excluded.working_directory,
                      columns = excluded.columns,
                      rows = excluded.rows,
                      state = excluded.state,
                      updated_at = excluded.updated_at,
                      exited_at = excluded.exited_at,
                      foreground_pid = excluded.foreground_pid,
                      foreground_executable_path = excluded.foreground_executable_path,
                      foreground_executable_name = excluded.foreground_executable_name,
                      foreground_argv_json = excluded.foreground_argv_json,
                      foreground_detected_agent_kind = excluded.foreground_detected_agent_kind,
                      foreground_display_label = excluded.foreground_display_label,
                      foreground_display_command = excluded.foreground_display_command
                    """,
                bindings: [
                    runtimeState.sessionID, root, runtimeState.backend.rawValue, runtimeState.servicePID,
                    runtimeState.childPID.map { Int($0) } as Any? ?? NSNull(), runtimeState.title ?? "", runtimeState.workingDirectory ?? "",
                    runtimeState.columns as Any? ?? NSNull(), runtimeState.rows as Any? ?? NSNull(), runtimeState.state.rawValue,
                    runtimeState.updatedAt, runtimeState.exitedAt ?? "", runtimeState.foregroundPID.map { Int($0) } as Any? ?? NSNull(),
                    runtimeState.foregroundExecutablePath ?? "", runtimeState.foregroundExecutableName ?? "", foregroundArgvJSON ?? "",
                    runtimeState.foregroundDetectedAgentKind?.rawValue ?? "", runtimeState.foregroundDisplayLabel ?? "",
                    runtimeState.foregroundDisplayCommand ?? "",
                ])
            try database.execute(
                sql: """
                    UPDATE terminal_clients
                    SET disconnected_at = ?
                    WHERE root_directory = ? AND disconnected_at IS NULL
                    """, bindings: [detachedAt, root])
            try database.execute(
                sql: """
                    UPDATE terminal_attachments
                    SET detached_at = ?
                    WHERE root_directory = ? AND detached_at IS NULL
                    """, bindings: [detachedAt, root])
        }
    }

    public static func activeAttachments(paths: TerminalSessionPaths) throws -> [TerminalAttachment] {
        try readAttachmentSnapshot(paths: paths).attachments.filter { $0.detachedAt == nil }
    }

    /// Live attachments for a session, judged through
    /// `TerminalSessionAttachmentSnapshot.liveAttachments` so the daemon's own keep-alive
    /// decisions and off-device consumers apply one lease rule.
    public static func liveAttachments(
        paths: TerminalSessionPaths, now: Date = Date(),
        remoteClientLeaseInterval: TimeInterval = TerminalSessionPersistence.remoteClientLeaseInterval
    ) throws -> [TerminalAttachment] {
        try readAttachmentSnapshot(paths: paths).liveAttachments(now: now, remoteClientLeaseInterval: remoteClientLeaseInterval)
    }

    /// A lease-lapsed remote client together with the exact `lease_refreshed_at` the expiry decision observed.
    /// The observed lease is carried into `expireClients` so the durable detach is a compare-and-set: a client
    /// whose lease moved (it re-attached or heartbeated) between the decision and the queued commit is skipped
    /// rather than re-disconnected.
    public struct StaleRemoteClient: Sendable, Equatable {
        public let clientID: String
        public let leaseRefreshedAt: String
        public init(clientID: String, leaseRefreshedAt: String) {
            self.clientID = clientID
            self.leaseRefreshedAt = leaseRefreshedAt
        }
    }

    public static func staleRemoteClients(
        paths: TerminalSessionPaths, now: Date = Date(),
        remoteClientLeaseInterval: TimeInterval = TerminalSessionPersistence.remoteClientLeaseInterval
    ) throws -> [StaleRemoteClient] {
        let root = normalizedRootDirectory(paths.rootDirectory)
        // Kinds whose liveness the lease does not decide are excluded outright rather than compared against
        // the cutoff — their rows carry no meaningful lease. Derived from `livenessDependsOnLease` so this
        // filter and `liveAttachments` cannot disagree about which kinds the lease governs.
        let leaseExemptKinds = TerminalClientKind.allCases.filter { !$0.livenessDependsOnLease }.map(\.rawValue)
        let leaseExemptPlaceholders = Array(repeating: "?", count: leaseExemptKinds.count).joined(separator: ", ")
        return try withProfileDatabase { database in
            let rows = try database.queryRows(
                sql: """
                    SELECT c.client_id, c.lease_refreshed_at
                    FROM terminal_clients c
                    JOIN terminal_attachments a ON a.root_directory = c.root_directory AND a.client_id = c.client_id
                    WHERE c.root_directory = ?
                      AND a.detached_at IS NULL
                      AND c.disconnected_at IS NULL
                      AND c.kind NOT IN (\(leaseExemptPlaceholders))
                    ORDER BY c.client_id
                    """, bindings: [root] + leaseExemptKinds)
            let cutoff = now.addingTimeInterval(-remoteClientLeaseInterval)
            return rows.compactMap { row in
                guard let lastSeenAt = parseISO8601(row[1]), lastSeenAt >= cutoff else {
                    return StaleRemoteClient(clientID: row[0], leaseRefreshedAt: row[1])
                }
                return nil
            }
        }
    }

    public static func staleRemoteClientIDs(
        paths: TerminalSessionPaths, now: Date = Date(),
        remoteClientLeaseInterval: TimeInterval = TerminalSessionPersistence.remoteClientLeaseInterval
    ) throws -> [String] { try staleRemoteClients(paths: paths, now: now, remoteClientLeaseInterval: remoteClientLeaseInterval).map(\.clientID) }

    public static func transferOwnership(sessionID: String, newOwnerClientID: String, paths: TerminalSessionPaths, transferredAt: String) throws {
        let root = normalizedRootDirectory(paths.rootDirectory)
        try withProfileDatabaseTransaction { database in
            let canonicalSessionID = try existingSessionID(rootDirectory: root, database: database)
            guard canonicalSessionID == sessionID else { throw TerminalSessionPersistenceError.unknownSession(sessionID) }
            guard
                try database.queryRow(
                    sql: "SELECT client_id FROM terminal_clients WHERE root_directory = ? AND client_id = ?", bindings: [root, newOwnerClientID])
                    != nil
            else { throw TerminalSessionPersistenceError.unknownClient(newOwnerClientID) }

            try database.execute(
                sql: """
                    UPDATE terminal_attachments
                    SET mode = 'viewer'
                    WHERE root_directory = ?
                      AND mode = 'owner'
                      AND detached_at IS NULL
                      AND client_id <> ?
                    """, bindings: [root, newOwnerClientID])

            if let existing = try database.queryRow(
                sql: """
                    SELECT id
                    FROM terminal_attachments
                    WHERE root_directory = ? AND client_id = ? AND detached_at IS NULL
                    """, bindings: [root, newOwnerClientID])
            {
                try database.execute(
                    sql: """
                        UPDATE terminal_attachments
                        SET session_id = ?, mode = 'owner'
                        WHERE id = ?
                        """, bindings: [sessionID, existing[0]])
            } else {
                try database.execute(
                    sql: """
                        INSERT INTO terminal_attachments(id, root_directory, session_id, client_id, mode, attached_at, detached_at)
                        VALUES (?, ?, ?, ?, 'owner', ?, NULL)
                        """, bindings: [UUID().uuidString, root, sessionID, newOwnerClientID, transferredAt])
            }
        }
    }

    /// Reclaims a removed session's persisted footprint: every `terminal_*` row keyed by its root
    /// directory, plus the on-disk session directory (`output.log`, `service.log`). Control/subscription
    /// sockets live outside this directory and are already removed at terminate; this drops what
    /// terminate deliberately keeps for ended-pane replay, and is therefore only safe once the session is
    /// no longer shown by the product (see `TerminalSessionGarbageCollector`). Removing every table's row
    /// for the root — not just `terminal_remote_session_states` — keeps the persisted footprint from
    /// outliving the session it belongs to.
    ///
    /// The directory is removed before the rows, not after, so a failure stays retryable: sessions are
    /// discovered by `listKnownSessions`, which is DB-driven, so a `terminal_sessions` row is what makes a
    /// session visible to the next collection sweep. If `removeItem` threw after the rows were already
    /// deleted, the directory would be orphaned with nothing left to rediscover it — a permanent leak. With
    /// the directory removed first, a `removeItem` failure leaves the rows intact and the whole purge (not
    /// just the row deletion) is retried on the next sweep; if `removeItem` succeeds but the row deletion
    /// then fails, the next sweep still lists the session, still reads its runtime/attachment state (those
    /// are rows, not files), and skips the already-removed directory via the `fileExists` guard below before
    /// retrying the row deletion.
    ///
    /// Only a directory this profile owns is ever removed. Sessions are discovered from the root their
    /// row stores, so a row can name a path outside the profile — a runtime directory that moved, rows a
    /// predecessor daemon left behind — and deleting an arbitrary stored path would put user directories
    /// behind a garbage-collection sweep. Such a session is reclaimed rows-only, which is the whole of
    /// what it still costs.
    public static func purgeSession(paths: TerminalSessionPaths, fileManager: FileManager = .default) throws {
        if try TerminalSessionPaths.isProfileOwnedSessionRoot(paths.rootDirectory), fileManager.fileExists(atPath: paths.rootDirectory) {
            try fileManager.removeItem(atPath: paths.rootDirectory)
        }
        let root = normalizedRootDirectory(paths.rootDirectory)
        try withProfileDatabaseTransaction { database in
            for table in [
                "terminal_agent_signal_events", "terminal_attachments", "terminal_clients", "terminal_remote_session_states",
                "terminal_runtime_states", "terminal_sessions",
            ] { try database.execute(sql: "DELETE FROM \(table) WHERE root_directory = ?", bindings: [root]) }
        }
    }

    /// Result of an `expireClients` transaction. `.superseded` is NOT a failure: the transaction committed
    /// whatever remained valid, but the durable world moved out from under the original decision (a client
    /// refreshed its lease, a different client took ownership, or the transfer target detached in the race
    /// window), so the caller must reseed its optimistic cache and re-derive a fresh decision on the next tick
    /// rather than retry this exact — now stale — decision.
    public enum ExpireClientsOutcome: Sendable, Equatable {
        case applied
        case superseded
    }

    /// Atomically expires a set of stale clients — disconnecting each client and detaching its still-active
    /// attachments — and, optionally, transfers ownership to `newOwnerClientID`, all inside ONE transaction.
    /// Consolidating them here makes the stale-client expiry an all-or-nothing durable unit: a partial commit
    /// (some detaches landed, a later statement failed) could otherwise leave durable state ownerless — the
    /// detached owner no longer appears in `staleRemoteClients` or `activeAttachments`, so no later tick could
    /// re-derive the transfer. With a single transaction any genuine failure rolls back untouched.
    ///
    /// Every mutation is a compare-and-set against the state the expiry decision observed, because the decision
    /// is made on the engine but the write is queued and can land after a synchronous engine-side attachment
    /// write (a takeover, a detach, a re-attach/heartbeat) has changed durable state:
    ///   - Each client detach requires the client's `lease_refreshed_at` to still equal the observed lease and
    ///     the client to still be connected; a client that came back is skipped (not detached), never an error.
    ///   - A client whose heartbeat generation advanced past the decision-time snapshot is also skipped: its
    ///     durable lease touch is stuck FIFO-behind this expiry, so the committed lease row still looks stale
    ///     even though the client just heartbeated. The generation check is taken here, INSIDE the write
    ///     transaction (after the write lock is held), so it observes every heartbeat that landed while this
    ///     expiry blocked on a contended lock — a check taken before entering the transaction would miss them.
    ///   - The ownership transfer is applied only when the durable owner's OWN detach compare-and-set succeeded
    ///     in this transaction (it really was one of the clients we expired, and it did not come back), AND the
    ///     target still has an active attachment with a connected client row. Guarding on the actual detach —
    ///     not merely on the pre-detach owner being in the candidate list — is load-bearing: a stale owner that
    ///     synchronously re-attached keeps its active owner row (updated in place), so it stays the durable
    ///     owner; its detach CAS is skipped, and the transfer must be skipped with it rather than demoting the
    ///     re-attached owner and promoting the target. A target that detached in the window is likewise NOT
    ///     resurrected with a fresh owner row — that ghost owner (whose client is gone) would pin the session
    ///     open via `hasActiveAttachments`.
    /// When any compare-and-set skips, the transaction still commits what it safely can and returns
    /// `.superseded` so the caller reconciles rather than retries the stale decision. Kept separate from
    /// `detachClient`/`transferOwnership`, which still serve their own single-purpose callers.
    @discardableResult public static func expireClients(
        _ clients: [StaleRemoteClient], transferOwnershipTo newOwnerClientID: String?, sessionID: String, paths: TerminalSessionPaths,
        detachedAt: String, heartbeatGate: TerminalClientHeartbeatGenerationGate, observedHeartbeatGenerations: [String: UInt64],
        databasePath: String? = nil
    ) throws -> ExpireClientsOutcome {
        let root = normalizedRootDirectory(paths.rootDirectory)
        return try withProfileDatabaseTransaction(at: databasePath) { database in
            var worldMoved = false
            // Client IDs whose per-client detach compare-and-set actually landed in THIS transaction. The
            // transfer guard keys off this — not off the input candidate list — so an owner whose detach was
            // skipped (re-attached with a fresh lease, or heartbeated after the decision) never has ownership
            // transferred away from it.
            var detachedClientIDs: Set<String> = []
            // Capture the durable active owner BEFORE any detach so the transfer supersession guard can tell
            // whether ownership is still held by one of the clients we decided to expire. Read after the
            // detach loop it would always be nil in the normal case (the stale owner we just detached),
            // defeating the guard.
            let preDetachOwnerClientID = try database.queryRow(
                sql: """
                    SELECT client_id FROM terminal_attachments
                    WHERE root_directory = ? AND mode = 'owner' AND detached_at IS NULL
                    """, bindings: [root])?.first

            for client in clients {
                // Heartbeat veto: a client that heartbeated after the expiry decision (generation advanced
                // past the snapshot) is left live. Its durable lease touch is queued FIFO-behind this expiry,
                // so the committed lease row below would still match the stale observed lease and wrongly
                // detach it. Taken here, inside the held transaction, so a heartbeat that arrived while this
                // write blocked on a contended lock is still seen.
                //
                // Accepted residual: a heartbeat acknowledged in the instant between this check and COMMIT
                // is detached anyway. That window is microseconds against a 20s heartbeat cadence, and no
                // check placement can remove it — closing it would require the engine's heartbeat accept to
                // block on this transaction, the exact engine-blocks-on-SQLite coupling the persistence
                // queue removes. The client's next heartbeat gets a notFound rejection and recovers by
                // re-attaching (client-side reaction tracked in issue #223).
                if heartbeatGate.generationAdvanced(forClientID: client.clientID, since: observedHeartbeatGenerations) {
                    worldMoved = true
                    continue
                }
                // Compare-and-set the detach against the observed lease: a client that re-attached or
                // refreshed its lease (different lease_refreshed_at) — or already got disconnected — since
                // the decision matches nothing here, so it is left live. Skipping flags the decision
                // superseded so the caller reseeds; it is not an error.
                let clientChanges = try database.executeReturningChanges(
                    sql: """
                        UPDATE terminal_clients
                        SET disconnected_at = ?
                        WHERE root_directory = ? AND client_id = ? AND disconnected_at IS NULL AND lease_refreshed_at = ?
                        """, bindings: [detachedAt, root, client.clientID, client.leaseRefreshedAt])
                guard clientChanges > 0 else {
                    worldMoved = true
                    continue
                }
                detachedClientIDs.insert(client.clientID)
                try database.execute(
                    sql: """
                        UPDATE terminal_attachments
                        SET detached_at = ?
                        WHERE root_directory = ? AND client_id = ? AND detached_at IS NULL
                        """, bindings: [detachedAt, root, client.clientID])
            }
            guard let newOwnerClientID else { return worldMoved ? .superseded : .applied }
            let canonicalSessionID = try existingSessionID(rootDirectory: root, database: database)
            guard canonicalSessionID == sessionID else { throw TerminalSessionPersistenceError.unknownSession(sessionID) }
            guard
                try database.queryRow(
                    sql: "SELECT client_id FROM terminal_clients WHERE root_directory = ? AND client_id = ?", bindings: [root, newOwnerClientID])
                    != nil
            else { throw TerminalSessionPersistenceError.unknownClient(newOwnerClientID) }

            // Transfer supersession guard: only hand ownership away from an owner whose OWN detach landed in
            // this transaction. If a different client became the active owner between the decision and this
            // commit (e.g. a mobile takeover that was ack'd ok), or the stale owner synchronously re-attached
            // so its detach CAS was skipped, leave ownership untouched — stomping it would durably demote a
            // legitimate owner that enforcement already accepted.
            guard let preDetachOwnerClientID, detachedClientIDs.contains(preDetachOwnerClientID) else { return .superseded }

            try database.execute(
                sql: """
                    UPDATE terminal_attachments
                    SET mode = 'viewer'
                    WHERE root_directory = ?
                      AND mode = 'owner'
                      AND detached_at IS NULL
                      AND client_id <> ?
                    """, bindings: [root, newOwnerClientID])

            // Promote the target only if it still has an active attachment whose client row is connected.
            // Never INSERT a fresh owner row: a target that detached in the race window must not be
            // resurrected as a ghost durable owner (its client row is gone) that pins the session open.
            let promoted = try database.executeReturningChanges(
                sql: """
                    UPDATE terminal_attachments
                    SET session_id = ?, mode = 'owner'
                    WHERE root_directory = ? AND client_id = ? AND detached_at IS NULL
                      AND EXISTS (
                        SELECT 1 FROM terminal_clients c
                        WHERE c.root_directory = terminal_attachments.root_directory
                          AND c.client_id = terminal_attachments.client_id
                          AND c.disconnected_at IS NULL
                      )
                    """, bindings: [sessionID, root, newOwnerClientID])
            guard promoted > 0 else { return .superseded }
            return worldMoved ? .superseded : .applied
        }
    }

    /// Every known session, each paired with the paths its own stored `root_directory` names. The root
    /// is read from the row rather than re-derived from the current profile so a session the profile no
    /// longer derives a matching path for is still readable, repairable, and collectable.
    public static func listKnownSessions(fileManager _: FileManager = .default) throws -> [KnownTerminalSession] {
        try withProfileDatabase { database in
            try database.queryRows(
                sql: """
                    SELECT session_id, backend, lifetime_policy, workspace_id, kind, title, working_directory, shell, COALESCE(command, ''),
                           created_at, COALESCE(user_title, ''), root_directory
                    FROM terminal_sessions
                    ORDER BY created_at, session_id
                    """
            ).map { row in
                guard row.count >= 12 else { throw TerminalSessionPersistenceError.invalidRow("terminal_sessions") }
                let launchConfiguration = try decodeLaunchConfiguration(row: row)
                return KnownTerminalSession(
                    launchConfiguration: launchConfiguration,
                    paths: try TerminalSessionPaths.forStoredSession(id: launchConfiguration.sessionID, rootDirectory: row[11]))
            }
        }
    }

    /// Every session whose stored runtime state is in an interactive state, paired with that state, as
    /// one query. The other half of liveness — whether the recorded service process still exists — is
    /// the caller's, since it is a question about the operating system rather than about a row.
    ///
    /// This is how liveness is decided in bulk. Asking each session for its runtime state separately
    /// made the cost of "which sessions are live?" proportional to every session the device had ever
    /// created rather than to the live ones, because the per-session read had to run before any part of
    /// the liveness filter could. The join reproduces that filter's input exactly: both tables key their
    /// rows on the same normalized `root_directory`, which is also what a per-session read looks a
    /// runtime row up by, so a session is considered here if and only if its own read would have
    /// returned a row. A session whose runtime row is missing is absent from both.
    ///
    /// The interactive states are derived from `TerminalSessionState.isInteractive` rather than written
    /// out, so this pre-filter and the caller's own liveness rule cannot drift apart; it only drops rows
    /// the caller would drop anyway, and dropping them in SQL is what keeps ended sessions from costing
    /// anything to skip.
    ///
    /// A row whose runtime state cannot be decoded is skipped, matching a per-session read's failure
    /// being treated as "no runtime state"; a row whose launch configuration cannot be decoded still
    /// fails the whole call, because that is a corrupt session list rather than one unreadable session.
    public static func listInteractiveSessionRuntimeStates() throws -> [KnownTerminalSessionRuntime] {
        let interactiveStates = TerminalSessionState.allCases.filter(\.isInteractive).map(\.rawValue)
        let interactiveStatePlaceholders = Array(repeating: "?", count: interactiveStates.count).joined(separator: ", ")
        return try withProfileDatabase { database in
            try database.queryRows(
                sql: """
                    SELECT s.session_id, s.backend, s.lifetime_policy, s.workspace_id, s.kind, s.title, s.working_directory, s.shell,
                           COALESCE(s.command, ''), s.created_at, COALESCE(s.user_title, ''), s.root_directory,
                           r.session_id, r.backend, r.service_pid, COALESCE(r.child_pid, ''), COALESCE(r.title, ''),
                           COALESCE(r.working_directory, ''), COALESCE(r.columns, ''), COALESCE(r.rows, ''), r.state, r.updated_at,
                           COALESCE(r.exited_at, ''), COALESCE(r.foreground_pid, ''), COALESCE(r.foreground_executable_path, ''),
                           COALESCE(r.foreground_executable_name, ''), COALESCE(r.foreground_argv_json, ''),
                           COALESCE(r.foreground_detected_agent_kind, ''), COALESCE(r.foreground_display_label, ''),
                           COALESCE(r.foreground_display_command, '')
                    FROM terminal_sessions s
                    JOIN terminal_runtime_states r ON r.root_directory = s.root_directory
                    WHERE r.state IN (\(interactiveStatePlaceholders))
                    ORDER BY s.created_at, s.session_id
                    """, bindings: interactiveStates
            ).compactMap { row in
                guard row.count >= 30 else { throw TerminalSessionPersistenceError.invalidRow("terminal_sessions") }
                let launchConfiguration = try decodeLaunchConfiguration(row: Array(row[0..<11]))
                guard let runtimeState = try? decodeRuntimeState(row: Array(row[12...])) else { return nil }
                return KnownTerminalSessionRuntime(launchConfiguration: launchConfiguration, rootDirectory: row[11], runtimeState: runtimeState)
            }
        }
    }

    /// Whether the session's persisted final-render state carries a replayable frame. Reads the stored
    /// answer rather than decoding `payload_json`, which is a ~36 KB base64 grid snapshot.
    public static func hasFinalRender(paths: TerminalSessionPaths) throws -> Bool {
        let root = normalizedRootDirectory(paths.rootDirectory)
        return try withProfileDatabase { database in
            let row = try database.queryRow(
                sql: "SELECT has_final_render FROM terminal_remote_session_states WHERE root_directory = ?", bindings: [root])
            guard let raw = row?.first else { return false }
            return (Int(raw) ?? 0) != 0
        }
    }

    /// Every session whose persisted final-render state carries a replayable frame, as one query. The
    /// device overview asks this for each of its rows on every build, several times a second, so it
    /// reads the whole set once instead of opening a connection per session.
    public static func sessionIDsWithFinalRender() throws -> Set<String> {
        try withProfileDatabase { database in
            Set(try database.queryRows(sql: "SELECT session_id FROM terminal_remote_session_states WHERE has_final_render <> 0").compactMap(\.first))
        }
    }

    /// The stored byte count of each session's persisted final-render payload, keyed by root directory.
    /// The retention budget weighs these bytes alongside the session directory because they are where an
    /// ended session's footprint actually accumulates. Read as one query per sweep rather than per
    /// session, since each read otherwise opens its own connection.
    public static func finalRenderPayloadByteCountsByRootDirectory() throws -> [String: Int64] {
        try withProfileDatabase { database in
            var counts: [String: Int64] = [:]
            for row in try database.queryRows(sql: "SELECT root_directory, length(CAST(payload_json AS BLOB)) FROM terminal_remote_session_states")
            where row.count >= 2 { counts[row[0]] = Int64(row[1]) ?? 0 }
            return counts
        }
    }

    private static func upsertClient(
        _ client: TerminalClient, sessionID: String, rootDirectory: String, leaseRefreshedAt: String, database: SpacesSQLiteDatabase
    ) throws {
        try database.execute(
            sql: """
                INSERT INTO terminal_clients(
                  root_directory, session_id, client_id, kind, identity_label, identity_host_name, identity_device_name, identity_network_address,
                  connected_at, lease_refreshed_at, disconnected_at
                )
                VALUES (?, ?, ?, ?, ?, NULLIF(?, ''), NULLIF(?, ''), NULLIF(?, ''), ?, ?, NULLIF(?, ''))
                ON CONFLICT(root_directory, client_id) DO UPDATE SET
                  session_id = excluded.session_id,
                  kind = excluded.kind,
                  identity_label = excluded.identity_label,
                  identity_host_name = excluded.identity_host_name,
                  identity_device_name = excluded.identity_device_name,
                  identity_network_address = excluded.identity_network_address,
                  connected_at = excluded.connected_at,
                  lease_refreshed_at = excluded.lease_refreshed_at,
                  disconnected_at = excluded.disconnected_at
                """,
            bindings: [
                rootDirectory, sessionID, client.id, client.kind.rawValue, client.identity.label, client.identity.hostName ?? "",
                client.identity.deviceName ?? "", client.identity.networkAddress ?? "", client.connectedAt, leaseRefreshedAt,
                client.disconnectedAt ?? "",
            ])
    }

    private static func existingSessionID(rootDirectory: String, database: SpacesSQLiteDatabase) throws -> String {
        guard let row = try database.queryRow(sql: "SELECT session_id FROM terminal_sessions WHERE root_directory = ?", bindings: [rootDirectory])
        else { throw TerminalSessionPersistenceError.unknownSession(rootDirectory) }
        return row[0]
    }

    private static func decodeLaunchConfiguration(row: [String]) throws -> TerminalSessionLaunchConfiguration {
        guard row.count >= 10 else { throw TerminalSessionPersistenceError.invalidRow("terminal_sessions") }
        guard let backend = TerminalSessionBackendKind(rawValue: row[1]) else {
            throw TerminalSessionPersistenceError.invalidValue("backend", row[1])
        }
        guard let lifetimePolicy = TerminalSessionLifetimePolicy(rawValue: row[2]) else {
            throw TerminalSessionPersistenceError.invalidValue("lifetime_policy", row[2])
        }
        guard let kind = TerminalSessionKind(rawValue: row[4]) else { throw TerminalSessionPersistenceError.invalidValue("kind", row[4]) }
        return TerminalSessionLaunchConfiguration(
            sessionID: row[0], backend: backend, lifetimePolicy: lifetimePolicy, title: row[5], workingDirectory: row[6], shell: row[7],
            command: row[8].isEmpty ? nil : row[8], createdAt: row[9], workspaceID: row[3], kind: kind,
            userTitle: row.count > 10 && !row[10].isEmpty ? row[10] : nil)
    }

    private static func encodeForegroundArgv(_ argv: [String]?) throws -> String? {
        guard let argv else { return nil }
        let data = try JSONEncoder().encode(TerminalForegroundProcessInspector.boundedArguments(argv))
        guard let json = String(data: data, encoding: .utf8) else {
            throw TerminalSessionPersistenceError.invalidValue("foreground_argv_json", "<non-utf8>")
        }
        return json
    }

    private static func decodeForegroundArgv(_ json: String) throws -> [String]? {
        guard !json.isEmpty else { return nil }
        guard let data = json.data(using: .utf8) else { throw TerminalSessionPersistenceError.invalidValue("foreground_argv_json", "<non-utf8>") }
        return try JSONDecoder().decode([String].self, from: data)
    }

    private static func encodeEnvironmentKeys(_ keys: [String]) throws -> String {
        let data = try JSONEncoder().encode(keys)
        guard let json = String(data: data, encoding: .utf8) else {
            throw TerminalSessionPersistenceError.invalidValue("environment_keys_json", "<non-utf8>")
        }
        return json
    }

    private static func decodeEnvironmentKeys(_ json: String) throws -> [String] {
        guard !json.isEmpty else { return [] }
        guard let data = json.data(using: .utf8) else { throw TerminalSessionPersistenceError.invalidValue("environment_keys_json", "<non-utf8>") }
        return try JSONDecoder().decode([String].self, from: data)
    }

    private static func decodeAgentSignalEvent(row: [String]) throws -> TerminalServiceAgentSignalEvent {
        guard row.count >= 10 else { throw TerminalSessionPersistenceError.invalidRow("terminal_agent_signal_events") }
        return TerminalServiceAgentSignalEvent(
            id: row[0], sessionID: row[1], workspaceID: row[2].isEmpty ? nil : row[2], workspacePath: row[3].isEmpty ? nil : row[3], type: row[4],
            provider: row[5], label: row[6].isEmpty ? nil : row[6], terminalTrackingID: row[7].isEmpty ? nil : row[7],
            environmentKeys: try decodeEnvironmentKeys(row[8]), createdAt: row[9])
    }

    private static func decodeRuntimeState(row: [String]) throws -> TerminalSessionRuntimeState {
        guard row.count >= 11 else { throw TerminalSessionPersistenceError.invalidRow("terminal_runtime_states") }
        guard let backend = TerminalSessionBackendKind(rawValue: row[1]) else {
            throw TerminalSessionPersistenceError.invalidValue("backend", row[1])
        }
        guard let servicePID = Int32(row[2]) else { throw TerminalSessionPersistenceError.invalidValue("service_pid", row[2]) }
        guard let state = TerminalSessionState(rawValue: row[8]) else { throw TerminalSessionPersistenceError.invalidValue("state", row[8]) }
        let foregroundDetectedAgentKind: TerminalDetectedAgentKind?
        if row.count > 15, !row[15].isEmpty {
            guard let kind = TerminalDetectedAgentKind(rawValue: row[15]) else {
                throw TerminalSessionPersistenceError.invalidValue("foreground_detected_agent_kind", row[15])
            }
            foregroundDetectedAgentKind = kind
        } else {
            foregroundDetectedAgentKind = nil
        }
        return TerminalSessionRuntimeState(
            sessionID: row[0], backend: backend, servicePID: servicePID, childPID: Int32(row[3]), state: state, updatedAt: row[9],
            exitedAt: row[10].isEmpty ? nil : row[10], title: row[4].isEmpty ? nil : row[4], workingDirectory: row[5].isEmpty ? nil : row[5],
            columns: Int(row[6]), rows: Int(row[7]), foregroundPID: row.count > 11 ? Int32(row[11]) : nil,
            foregroundExecutablePath: row.count > 12 && !row[12].isEmpty ? row[12] : nil,
            foregroundExecutableName: row.count > 13 && !row[13].isEmpty ? row[13] : nil,
            foregroundArgv: row.count > 14 ? try decodeForegroundArgv(row[14]) : nil, foregroundDetectedAgentKind: foregroundDetectedAgentKind,
            foregroundDisplayLabel: row.count > 16 && !row[16].isEmpty ? row[16] : nil,
            foregroundDisplayCommand: row.count > 17 && !row[17].isEmpty ? row[17] : nil)
    }

    private static func decodeClient(row: [String]) throws -> TerminalClient {
        guard row.count >= 9 else { throw TerminalSessionPersistenceError.invalidRow("terminal_clients") }
        guard let kind = TerminalClientKind(rawValue: row[1]) else { throw TerminalSessionPersistenceError.invalidValue("kind", row[1]) }
        return TerminalClient(
            id: row[0], kind: kind,
            identity: TerminalClientIdentity(
                label: row[2], hostName: row[3].isEmpty ? nil : row[3], deviceName: row[4].isEmpty ? nil : row[4],
                networkAddress: row[5].isEmpty ? nil : row[5]), connectedAt: row[6], disconnectedAt: row[7].isEmpty ? nil : row[7],
            leaseRefreshedAt: row[8].isEmpty ? nil : row[8])
    }

    private static func decodeAttachment(row: [String]) throws -> TerminalAttachment {
        guard row.count >= 6 else { throw TerminalSessionPersistenceError.invalidRow("terminal_attachments") }
        guard let mode = TerminalAttachmentMode(rawValue: row[3]) else { throw TerminalSessionPersistenceError.invalidValue("mode", row[3]) }
        return TerminalAttachment(
            id: row[0], sessionID: row[1], clientID: row[2], mode: mode, attachedAt: row[4], detachedAt: row[5].isEmpty ? nil : row[5])
    }

    /// The active profile's terminal database. Callers that run in the same breath as the state they are
    /// persisting get this implicitly; work that commits later than it was decided resolves it up front
    /// (see `withProfileDatabase(at:)`).
    public static func currentDatabasePath() throws -> String { try SpacesProfile.current().databasePath }

    /// Every terminal-session read goes through here. The terminal database is profile-scoped, never
    /// session-scoped, so this and its writing counterpart are the only places the database path is
    /// resolved.
    ///
    /// Reads run on their own connection, so a read taken inline on the terminal engine — owner gating,
    /// stale-client liveness — never waits for a writer that is itself waiting on the database's write
    /// lock. See `TerminalDatabaseConnection`.
    private static func withProfileDatabase<T>(at databasePath: String? = nil, _ body: (SpacesSQLiteDatabase) throws -> T) throws -> T {
        try TerminalDatabaseConnection.shared.read(path: try databasePath ?? currentDatabasePath(), body)
    }

    /// Every terminal-session mutation goes through here, as one `BEGIN IMMEDIATE` transaction on the
    /// write connection. The transaction is opened by the funnel rather than by each body, so a mutation
    /// cannot end up on the read connection — or outside a transaction — by omission.
    ///
    /// `databasePath` is the database this unit of work belongs to, and resolving the active profile is its
    /// only default. Deferred work — the per-core persistence queue, whose closures commit long after the
    /// engine decided them — resolves the path when the write is *enqueued* and passes it here, so a write
    /// commits to the profile that was current when the state was produced rather than to whatever profile
    /// happens to be current when the queue reaches it. A daemon's profile never changes mid-process, so
    /// this is inert in production; it is what makes a test's isolation hold for writes that outlive the
    /// test that produced them.
    private static func withProfileDatabaseTransaction<T>(at databasePath: String? = nil, _ body: (SpacesSQLiteDatabase) throws -> T) throws -> T {
        try TerminalDatabaseConnection.shared.write(path: try databasePath ?? currentDatabasePath(), body)
    }

    /// Releases the process's terminal-database connections, taking their final WAL checkpoints now rather
    /// than leaving them to process teardown. The daemon calls this before replacing its own image at an
    /// `execv` handoff, which no connection would survive cleanly; a later read or write simply opens a
    /// fresh connection.
    public static func closeDatabaseConnection() { TerminalDatabaseConnection.shared.close() }

    private static func normalizedRootDirectory(_ rootDirectory: String) -> String {
        URL(fileURLWithPath: rootDirectory, isDirectory: true).standardizedFileURL.path
    }

    /// Parses lease/connection timestamps. Linux daemons emit them with fractional
    /// seconds (`...00.123Z`) while macOS emits whole-second stamps, so this delegates
    /// to the timestamp parser that accepts both — a plain ISO8601 formatter returns nil
    /// for fractional values, which would wrongly expire live remote viewers.
    fileprivate static func parseISO8601(_ value: String) -> Date? { GhosttyRemoteSessionStateTimestamp.date(from: value) }
}

extension SpacesSQLiteDatabase {
    fileprivate func executeReturningChanges(sql: String, bindings: [Any] = []) throws -> Int {
        try execute(sql: sql, bindings: bindings)
        guard let row = try queryRow(sql: "SELECT changes()"), let raw = row.first, let changes = Int(raw) else { return 0 }
        return changes
    }
}

public enum TerminalSessionPersistenceError: LocalizedError {
    case unknownClient(String)
    case unknownSession(String)
    case invalidRow(String)
    case invalidValue(String, String)

    public var errorDescription: String? {
        switch self {
        case .unknownClient(let clientID): "Unknown terminal client '\(clientID)'."
        case .unknownSession(let sessionID): "Unknown terminal session '\(sessionID)'."
        case .invalidRow(let table): "Invalid terminal persistence row in \(table)."
        case .invalidValue(let field, let value): "Invalid terminal persistence value for \(field): \(value)."
        }
    }
}
