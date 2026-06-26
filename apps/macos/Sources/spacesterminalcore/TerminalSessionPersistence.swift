import Foundation
import spacesdatabase

public struct TerminalSessionLaunchConfiguration: Codable, Sendable, Equatable {
    public let sessionID: String
    public let backend: TerminalSessionBackendKind
    public let lifetimePolicy: TerminalSessionLifetimePolicy
    public let workspaceID: String?
    public let kind: TerminalSessionKind
    public let title: String
    public let workingDirectory: String
    public let shell: String
    public let command: String?
    public let createdAt: String

    public init(
        sessionID: String, backend: TerminalSessionBackendKind = .ghosttyEmbedded, lifetimePolicy: TerminalSessionLifetimePolicy = .persistent,
        title: String, workingDirectory: String, shell: String, command: String?, createdAt: String
    ) {
        self.init(
            sessionID: sessionID, backend: backend, lifetimePolicy: lifetimePolicy, title: title, workingDirectory: workingDirectory, shell: shell,
            command: command, createdAt: createdAt, workspaceID: nil, kind: .shell)
    }

    public init(
        sessionID: String, backend: TerminalSessionBackendKind = .ghosttyEmbedded, lifetimePolicy: TerminalSessionLifetimePolicy = .persistent,
        title: String, workingDirectory: String, shell: String, command: String?, createdAt: String, workspaceID: String?, kind: TerminalSessionKind
    ) {
        self.sessionID = sessionID
        self.backend = backend
        self.lifetimePolicy = lifetimePolicy
        self.workspaceID = workspaceID
        self.kind = kind
        self.title = title
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
        workspaceID = try container.decodeIfPresent(String.self, forKey: .workspaceID)
        kind = try container.decodeIfPresent(TerminalSessionKind.self, forKey: .kind) ?? .shell
        title = try container.decode(String.self, forKey: .title)
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
}

public struct TerminalSessionAttachmentSnapshot: Codable, Sendable, Equatable {
    public var clients: [TerminalClient]
    public var attachments: [TerminalAttachment]

    public init(clients: [TerminalClient] = [], attachments: [TerminalAttachment] = []) {
        self.clients = clients
        self.attachments = attachments
    }
}

public enum TerminalSessionPersistence {
    public static let remoteClientLeaseInterval: TimeInterval = 60

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
                        VALUES (?, ?, ?, ?, NULLIF(?, ''), ?, ?, ?, ?, NULLIF(?, ''), ?)
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
                        configuration.workspaceID ?? "", configuration.kind.rawValue, configuration.title, configuration.workingDirectory,
                        configuration.shell, configuration.command ?? "", configuration.createdAt,
                    ])
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
                        INSERT INTO terminal_remote_session_states(session_id, root_directory, reason, payload_json, emitted_at, updated_at)
                        VALUES (?, ?, ?, ?, ?, ?)
                        ON CONFLICT(session_id) DO UPDATE SET
                          root_directory = excluded.root_directory,
                          reason = excluded.reason,
                          payload_json = excluded.payload_json,
                          emitted_at = excluded.emitted_at,
                          updated_at = excluded.updated_at
                        """,
                    bindings: [
                        payload.sessionID, root, payload.reason, payloadJSON, payload.emittedAt,
                        GhosttyRemoteSessionStateTimestamp.string(from: Date()),
                    ])
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
                    SELECT session_id, backend, lifetime_policy, COALESCE(workspace_id, ''), kind, title, working_directory, shell, COALESCE(command, ''),
                           created_at
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
                           COALESCE(identity_network_address, ''), connected_at, COALESCE(disconnected_at, '')
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
                          terminal_native_id, codex_thread_id, environment_keys_json, created_at, acknowledged_at
                        )
                        VALUES (?, ?, ?, ?, NULLIF(?, ''), NULLIF(?, ''), ?, NULLIF(?, ''), NULLIF(?, ''), NULLIF(?, ''), NULLIF(?, ''), ?, ?, NULL)
                        ON CONFLICT(id) DO UPDATE SET
                          root_directory = excluded.root_directory,
                          session_id = excluded.session_id,
                          event_type = excluded.event_type,
                          workspace_id = excluded.workspace_id,
                          workspace_path = excluded.workspace_path,
                          provider = excluded.provider,
                          label = excluded.label,
                          terminal_tracking_id = excluded.terminal_tracking_id,
                          terminal_native_id = excluded.terminal_native_id,
                          codex_thread_id = excluded.codex_thread_id,
                          environment_keys_json = excluded.environment_keys_json,
                          created_at = excluded.created_at,
                          acknowledged_at = NULL
                        """,
                    bindings: [
                        event.id, root, event.sessionID, event.type, event.workspaceID ?? "", event.workspacePath ?? "", event.provider,
                        event.label ?? "", event.terminalTrackingID ?? "", event.terminalNativeID ?? "", event.codexThreadID ?? "",
                        environmentKeysJSON, event.createdAt,
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
                           COALESCE(terminal_tracking_id, ''), COALESCE(terminal_native_id, ''), COALESCE(codex_thread_id, ''),
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

    public static func touchClient(id clientID: String, paths: TerminalSessionPaths, touchedAt: String) throws {
        let root = normalizedRootDirectory(paths.rootDirectory)
        try withDatabase(paths: paths) { database in
            try database.withImmediateTransaction {
                let changes = try database.executeReturningChanges(
                    sql: """
                        UPDATE terminal_clients
                        SET lease_refreshed_at = ?
                        WHERE root_directory = ? AND client_id = ?
                        """, bindings: [touchedAt, root, clientID])
                if changes == 0 { throw TerminalSessionPersistenceError.unknownClient(clientID) }
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

    public static func activeAttachments(paths: TerminalSessionPaths) throws -> [TerminalAttachment] {
        try readAttachmentSnapshot(paths: paths).attachments.filter { $0.detachedAt == nil }
    }

    public static func liveAttachments(
        paths: TerminalSessionPaths, now: Date = Date(),
        remoteClientLeaseInterval: TimeInterval = TerminalSessionPersistence.remoteClientLeaseInterval
    ) throws -> [TerminalAttachment] {
        let root = normalizedRootDirectory(paths.rootDirectory)
        return try withDatabase(paths: paths) { database in
            let rows = try database.queryRows(
                sql: """
                    SELECT a.id, a.session_id, a.client_id, a.mode, a.attached_at, COALESCE(a.detached_at, ''),
                           c.kind, COALESCE(c.disconnected_at, ''), c.lease_refreshed_at
                    FROM terminal_attachments a
                    JOIN terminal_clients c ON c.root_directory = a.root_directory AND c.client_id = a.client_id
                    WHERE a.root_directory = ? AND a.detached_at IS NULL
                    ORDER BY a.attached_at, a.id
                    """, bindings: [root])
            let cutoff = now.addingTimeInterval(-remoteClientLeaseInterval)
            return try rows.compactMap { row in
                guard row[7].isEmpty else { return nil }
                if row[6] != TerminalClientKind.localWindow.rawValue {
                    guard let lastSeenAt = parseISO8601(row[8]), lastSeenAt >= cutoff else { return nil }
                }
                return try decodeAttachment(row: Array(row[0...5]))
            }
        }
    }

    public static func staleRemoteClientIDs(
        paths: TerminalSessionPaths, now: Date = Date(),
        remoteClientLeaseInterval: TimeInterval = TerminalSessionPersistence.remoteClientLeaseInterval
    ) throws -> [String] {
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
                guard let lastSeenAt = parseISO8601(row[1]), lastSeenAt >= cutoff else { return row[0] }
                return nil
            }
        }
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

    public static func listKnownSessions(fileManager _: FileManager = .default) throws -> [TerminalSessionLaunchConfiguration] {
        try withProfileDatabase { database in
            try database.queryRows(
                sql: """
                    SELECT session_id, backend, lifetime_policy, COALESCE(workspace_id, ''), kind, title, working_directory, shell, COALESCE(command, ''),
                           created_at
                    FROM terminal_sessions
                    ORDER BY created_at, session_id
                    """
            ).map(decodeLaunchConfiguration(row:))
        }
    }

    public static func writeWindowFrame(_ frame: TerminalSessionWindowFrame, mode: TerminalAttachmentMode, paths: TerminalSessionPaths) throws {
        let root = normalizedRootDirectory(paths.rootDirectory)
        try paths.ensureDirectories()
        try withDatabase(paths: paths) { database in
            try database.withImmediateTransaction {
                let sessionID = try existingSessionID(rootDirectory: root, database: database)
                try database.execute(
                    sql: """
                        INSERT INTO terminal_window_frames(root_directory, session_id, mode, x, y, width, height, updated_at)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                        ON CONFLICT(root_directory, mode) DO UPDATE SET
                          session_id = excluded.session_id,
                          x = excluded.x,
                          y = excluded.y,
                          width = excluded.width,
                          height = excluded.height,
                          updated_at = excluded.updated_at
                        """,
                    bindings: [
                        root, sessionID, mode.rawValue, frame.x, frame.y, frame.width, frame.height, ISO8601DateFormatter().string(from: Date()),
                    ])
            }
        }
    }

    public static func readWindowFrame(mode: TerminalAttachmentMode, paths: TerminalSessionPaths) throws -> TerminalSessionWindowFrame? {
        let root = normalizedRootDirectory(paths.rootDirectory)
        return try withDatabase(paths: paths) { database in
            guard
                let row = try database.queryRow(
                    sql: """
                        SELECT x, y, width, height
                        FROM terminal_window_frames
                        WHERE root_directory = ? AND mode = ?
                        """, bindings: [root, mode.rawValue])
            else { return nil }
            return try decodeWindowFrame(row: row)
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
            command: row[8].isEmpty ? nil : row[8], createdAt: row[9], workspaceID: row[3].isEmpty ? nil : row[3], kind: kind)
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
        guard row.count >= 12 else { throw TerminalSessionPersistenceError.invalidRow("terminal_agent_signal_events") }
        return TerminalServiceAgentSignalEvent(
            id: row[0], sessionID: row[1], workspaceID: row[2].isEmpty ? nil : row[2], workspacePath: row[3].isEmpty ? nil : row[3], type: row[4],
            provider: row[5], label: row[6].isEmpty ? nil : row[6], terminalTrackingID: row[7].isEmpty ? nil : row[7],
            terminalNativeID: row[8].isEmpty ? nil : row[8], codexThreadID: row[9].isEmpty ? nil : row[9],
            environmentKeys: try decodeEnvironmentKeys(row[10]), createdAt: row[11])
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
        guard row.count >= 8 else { throw TerminalSessionPersistenceError.invalidRow("terminal_clients") }
        guard let kind = TerminalClientKind(rawValue: row[1]) else { throw TerminalSessionPersistenceError.invalidValue("kind", row[1]) }
        return TerminalClient(
            id: row[0], kind: kind,
            identity: TerminalClientIdentity(
                label: row[2], hostName: row[3].isEmpty ? nil : row[3], deviceName: row[4].isEmpty ? nil : row[4],
                networkAddress: row[5].isEmpty ? nil : row[5]), connectedAt: row[6], disconnectedAt: row[7].isEmpty ? nil : row[7])
    }

    private static func decodeAttachment(row: [String]) throws -> TerminalAttachment {
        guard row.count >= 6 else { throw TerminalSessionPersistenceError.invalidRow("terminal_attachments") }
        guard let mode = TerminalAttachmentMode(rawValue: row[3]) else { throw TerminalSessionPersistenceError.invalidValue("mode", row[3]) }
        return TerminalAttachment(
            id: row[0], sessionID: row[1], clientID: row[2], mode: mode, attachedAt: row[4], detachedAt: row[5].isEmpty ? nil : row[5])
    }

    private static func decodeWindowFrame(row: [String]) throws -> TerminalSessionWindowFrame {
        guard row.count >= 4 else { throw TerminalSessionPersistenceError.invalidRow("terminal_window_frames") }
        guard let x = Double(row[0]), let y = Double(row[1]), let width = Double(row[2]), let height = Double(row[3]) else {
            throw TerminalSessionPersistenceError.invalidValue("window_frame", row.joined(separator: ","))
        }
        return TerminalSessionWindowFrame(x: x, y: y, width: width, height: height)
    }

    private static func withDatabase<T>(paths: TerminalSessionPaths, _ body: (SpacesSQLiteDatabase) throws -> T) throws -> T {
        let database = try SpacesSQLiteDatabase(path: databasePath(for: paths))
        return try body(database)
    }

    private static func withProfileDatabase<T>(_ body: (SpacesSQLiteDatabase) throws -> T) throws -> T {
        let database = try SpacesSQLiteDatabase(path: SpacesProfile.current().databasePath)
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

    private static func parseISO8601(_ value: String) -> Date? { ISO8601DateFormatter().date(from: value) }
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
