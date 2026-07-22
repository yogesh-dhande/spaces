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
    /// when it is not detached, its client is not disconnected, and — for remote clients,
    /// which can vanish without sending a detach — its lease was refreshed within
    /// `remoteClientLeaseInterval`. Local window clients have no lease and are always live
    /// while attached. This is the single source of truth for liveness; the persistence
    /// query and any off-device consumer both judge attachments through this rule, so an
    /// expired remote viewer is never mistaken for a live attachment.
    public func liveAttachments(now: Date = Date(), remoteClientLeaseInterval: TimeInterval = TerminalSessionPersistence.remoteClientLeaseInterval)
        -> [TerminalAttachment]
    {
        let cutoff = now.addingTimeInterval(-remoteClientLeaseInterval)
        let clientsByID = Dictionary(clients.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return attachments.filter { attachment in
            guard attachment.detachedAt == nil, let client = clientsByID[attachment.clientID], client.disconnectedAt == nil else { return false }
            guard client.kind != .localWindow else { return true }
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
        try withDatabase(paths: paths) { database in
            try database.withImmediateTransaction {
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
                        configuration.sessionID, root, configuration.backend.rawValue, configuration.lifetimePolicy.rawValue,
                        configuration.workspaceID, configuration.kind.rawValue, configuration.title, configuration.workingDirectory,
                        configuration.shell, configuration.command ?? "", configuration.createdAt,
                    ])
            }
        }
    }

    /// Persists a manual rename for the session. The stored user title takes precedence over
    /// the auto-updated runtime title when the session's effective title is computed.
    public static func writeUserTitle(_ userTitle: String, sessionID: String, paths: TerminalSessionPaths) throws {
        let root = normalizedRootDirectory(paths.rootDirectory)
        try withDatabase(paths: paths) { database in
            try database.withImmediateTransaction {
                let canonicalSessionID = try existingSessionID(rootDirectory: root, database: database)
                guard canonicalSessionID == sessionID else { throw TerminalSessionPersistenceError.unknownSession(sessionID) }
                try database.execute(
                    sql: "UPDATE terminal_sessions SET user_title = NULLIF(?, '') WHERE root_directory = ?", bindings: [userTitle, root])
            }
        }
    }

    public static func writeRuntimeState(_ state: TerminalSessionRuntimeState, paths: TerminalSessionPaths) throws {
        try paths.ensureDirectories()
        let root = normalizedRootDirectory(paths.rootDirectory)
        let foregroundArgvJSON = try encodeForegroundArgv(state.foregroundArgv)
        try withDatabase(paths: paths) { database in
            try database.withImmediateTransaction {
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
    }

    public static func writeRemoteSessionState(_ payload: GhosttyRemoteSessionStatePayload, paths: TerminalSessionPaths) throws {
        try paths.ensureDirectories()
        let root = normalizedRootDirectory(paths.rootDirectory)
        let encodedPayload = try JSONEncoder().encode(payload)
        guard let payloadJSON = String(data: encodedPayload, encoding: .utf8) else {
            throw TerminalSessionPersistenceError.invalidValue("payload_json", "<non-utf8>")
        }
        try withDatabase(paths: paths) { database in
            try database.withImmediateTransaction {
                let sessionID = try existingSessionID(rootDirectory: root, database: database)
                guard sessionID == payload.sessionID else { throw TerminalSessionPersistenceError.unknownSession(payload.sessionID) }
                try database.execute(
                    sql: "DELETE FROM terminal_remote_session_states WHERE root_directory = ? AND session_id <> ?",
                    bindings: [root, payload.sessionID])
                try database.execute(
                    sql: """
                        INSERT INTO terminal_remote_session_states(session_id, root_directory, payload_json)
                        VALUES (?, ?, ?)
                        ON CONFLICT(session_id) DO UPDATE SET
                          root_directory = excluded.root_directory,
                          payload_json = excluded.payload_json
                        """, bindings: [payload.sessionID, root, payloadJSON])
            }
        }
    }

    public static func writeAttachmentSnapshot(_ snapshot: TerminalSessionAttachmentSnapshot, paths: TerminalSessionPaths) throws {
        try paths.ensureDirectories()
        let root = normalizedRootDirectory(paths.rootDirectory)
        try withDatabase(paths: paths) { database in
            try database.withImmediateTransaction {
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
    }

    public static func writeRemoteStateMirror(_ payload: GhosttyRemoteSessionStatePayload, paths: TerminalSessionPaths) throws {
        if let runtimeState = payload.runtimeState { try writeRuntimeState(runtimeState, paths: paths) }
        if let attachmentSnapshot = payload.attachmentSnapshot { try writeAttachmentSnapshot(attachmentSnapshot, paths: paths) }
        try writeRemoteSessionState(payload, paths: paths)
    }

    public static func readLaunchConfiguration(paths: TerminalSessionPaths) throws -> TerminalSessionLaunchConfiguration {
        let root = normalizedRootDirectory(paths.rootDirectory)
        return try withDatabase(paths: paths) { database in
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
        return try withDatabase(paths: paths) { database in
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
        return try withDatabase(paths: paths) { database in
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
        return try withDatabase(paths: paths) { database in
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
        try withDatabase(paths: paths) { database in
            try database.withImmediateTransaction {
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
    }

    public static func pendingAgentSignals(sessionID: String, paths: TerminalSessionPaths) throws -> [TerminalServiceAgentSignalEvent] {
        let root = normalizedRootDirectory(paths.rootDirectory)
        return try withDatabase(paths: paths) { database in
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
        try withDatabase(paths: paths) { database in
            try database.withImmediateTransaction {
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
    }

    public static func upsertClient(_ client: TerminalClient, paths: TerminalSessionPaths) throws {
        let root = normalizedRootDirectory(paths.rootDirectory)
        try withDatabase(paths: paths) { database in
            try database.withImmediateTransaction {
                let sessionID = try existingSessionID(rootDirectory: root, database: database)
                try upsertClient(client, sessionID: sessionID, rootDirectory: root, leaseRefreshedAt: client.connectedAt, database: database)
            }
        }
    }

    /// Refreshes a connected client's lease and reports whether anything was touched. The `disconnected_at IS
    /// NULL` guard makes a lease touch for a durably disconnected client a no-op (returning `false`) rather than
    /// silently resurrecting its lease: a client that was expired/detached must not be able to keep a corpse
    /// alive by heartbeating. Returns `true` only when a live client's lease was refreshed.
    @discardableResult
    public static func touchClient(id clientID: String, paths: TerminalSessionPaths, touchedAt: String) throws -> Bool {
        let root = normalizedRootDirectory(paths.rootDirectory)
        return try withDatabase(paths: paths) { database in
            try database.withImmediateTransaction {
                let changes = try database.executeReturningChanges(
                    sql: """
                        UPDATE terminal_clients
                        SET lease_refreshed_at = ?
                        WHERE root_directory = ? AND client_id = ? AND disconnected_at IS NULL
                        """, bindings: [touchedAt, root, clientID])
                return changes > 0
            }
        }
    }

    public static func attachClient(
        sessionID: String, client: TerminalClient, mode: TerminalAttachmentMode, paths: TerminalSessionPaths, attachedAt: String
    ) throws {
        let root = normalizedRootDirectory(paths.rootDirectory)
        try paths.ensureDirectories()
        try withDatabase(paths: paths) { database in
            try database.withImmediateTransaction {
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
    }

    public static func detachClient(id clientID: String, paths: TerminalSessionPaths, detachedAt: String) throws {
        let root = normalizedRootDirectory(paths.rootDirectory)
        try withDatabase(paths: paths) { database in
            try database.withImmediateTransaction {
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
    }

    public static func detachActiveClients(paths: TerminalSessionPaths, detachedAt: String) throws {
        let root = normalizedRootDirectory(paths.rootDirectory)
        try withDatabase(paths: paths) { database in
            try database.withImmediateTransaction {
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
    public static func finalizeSessionRepair(
        _ runtimeState: TerminalSessionRuntimeState, detachedAt: String, paths: TerminalSessionPaths
    ) throws {
        try paths.ensureDirectories()
        let root = normalizedRootDirectory(paths.rootDirectory)
        let foregroundArgvJSON = try encodeForegroundArgv(runtimeState.foregroundArgv)
        try withDatabase(paths: paths) { database in
            try database.withImmediateTransaction {
                try database.execute(
                    sql: "DELETE FROM terminal_runtime_states WHERE root_directory = ? AND session_id <> ?",
                    bindings: [root, runtimeState.sessionID])
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
        return try withDatabase(paths: paths) { database in
            let rows = try database.queryRows(
                sql: """
                    SELECT c.client_id, c.lease_refreshed_at
                    FROM terminal_clients c
                    JOIN terminal_attachments a ON a.root_directory = c.root_directory AND a.client_id = c.client_id
                    WHERE c.root_directory = ?
                      AND a.detached_at IS NULL
                      AND c.disconnected_at IS NULL
                      AND c.kind <> ?
                    ORDER BY c.client_id
                    """, bindings: [root, TerminalClientKind.localWindow.rawValue])
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
    ) throws -> [String] {
        try staleRemoteClients(paths: paths, now: now, remoteClientLeaseInterval: remoteClientLeaseInterval).map(\.clientID)
    }

    public static func transferOwnership(sessionID: String, newOwnerClientID: String, paths: TerminalSessionPaths, transferredAt: String) throws {
        let root = normalizedRootDirectory(paths.rootDirectory)
        try withDatabase(paths: paths) { database in
            try database.withImmediateTransaction {
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
    @discardableResult
    public static func expireClients(
        _ clients: [StaleRemoteClient], transferOwnershipTo newOwnerClientID: String?, sessionID: String, paths: TerminalSessionPaths,
        detachedAt: String, heartbeatGate: TerminalClientHeartbeatGenerationGate, observedHeartbeatGenerations: [String: UInt64]
    ) throws -> ExpireClientsOutcome {
        let root = normalizedRootDirectory(paths.rootDirectory)
        return try withDatabase(paths: paths) { database in
            try database.withImmediateTransaction {
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
    }

    public static func listKnownSessions(fileManager _: FileManager = .default) throws -> [TerminalSessionLaunchConfiguration] {
        try withProfileDatabase { database in
            try database.queryRows(
                sql: """
                    SELECT session_id, backend, lifetime_policy, workspace_id, kind, title, working_directory, shell, COALESCE(command, ''),
                           created_at, COALESCE(user_title, '')
                    FROM terminal_sessions
                    ORDER BY created_at, session_id
                    """
            ).map(decodeLaunchConfiguration(row:))
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

    private static func withDatabase<T>(paths: TerminalSessionPaths, _ body: (SpacesSQLiteDatabase) throws -> T) throws -> T {
        let databasePath = try databasePath(for: paths)
        let database = try SpacesSQLiteDatabase(
            path: databasePath,
            withMigrationAuthorization: { migration in
                try ProfileDatabaseMigrationGuard.withMigrationAuthorization(databasePath: databasePath, migration)
            })
        return try body(database)
    }

    private static func withProfileDatabase<T>(_ body: (SpacesSQLiteDatabase) throws -> T) throws -> T {
        let databasePath = try SpacesProfile.current().databasePath
        let database = try SpacesSQLiteDatabase(
            path: databasePath,
            withMigrationAuthorization: { migration in
                try ProfileDatabaseMigrationGuard.withMigrationAuthorization(databasePath: databasePath, migration)
            })
        return try body(database)
    }

    /// Test-only seam: when bound, terminal-session persistence resolves its database here instead of the
    /// active profile, letting tests isolate state without mutating the process-global SPACES_DB_PATH. It is
    /// task-local so concurrent test suites never observe each other's binding.
    @TaskLocal static var databasePathOverrideForTesting: String?

    private static func databasePath(for _: TerminalSessionPaths) throws -> String {
        if let databasePathOverrideForTesting { return databasePathOverrideForTesting }
        return try SpacesProfile.current().databasePath
    }

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
