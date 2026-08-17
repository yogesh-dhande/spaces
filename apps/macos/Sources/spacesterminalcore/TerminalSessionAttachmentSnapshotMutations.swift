import Foundation

/// In-memory equivalents of the attachment/client mutations `TerminalSessionPersistence` performs in SQL.
///
/// A session core applies the mutation to its authoritative in-memory snapshot on the terminal-engine
/// executor and enqueues the matching durable write onto its per-core persistence queue, so a contended
/// SQLite write lock delays the mirror instead of freezing the engine. Enforcement (owner gating) and every
/// broadcast read the in-memory snapshot, so these functions are the definition of what the product
/// believes; the SQL they mirror is the durable mirror a fresh core reseeds from. They are shared by the
/// macOS embedded core and the Linux headless core precisely so the two can never drift from each other or
/// from the SQL: each one below is the row-level transcription of the statement named in its doc comment.
extension TerminalSessionAttachmentSnapshot {
    /// Mirrors `upsertClient`: replaces the client's row wholesale (identity, kind, connection instant,
    /// lease), inserting it when absent.
    public func applyingClientUpsert(_ client: TerminalClient, leaseRefreshedAt: String) -> TerminalSessionAttachmentSnapshot {
        let upserted = TerminalClient(
            id: client.id, kind: client.kind, identity: client.identity, connectedAt: client.connectedAt, disconnectedAt: client.disconnectedAt,
            leaseRefreshedAt: leaseRefreshedAt)
        var clients = clients
        if let index = clients.firstIndex(where: { $0.id == client.id }) { clients[index] = upserted } else { clients.append(upserted) }
        return TerminalSessionAttachmentSnapshot(clients: clients, attachments: attachments)
    }

    /// Mirrors `attachClient`: upserts the client as connected with the attach instant as its lease, detaches
    /// any other client's active owner attachment when attaching as owner, and either re-modes this client's
    /// existing active attachment or inserts a new one.
    public func applyingAttach(client: TerminalClient, mode: TerminalAttachmentMode, sessionID: String, attachedAt: String)
        -> TerminalSessionAttachmentSnapshot
    {
        let connectedClient = TerminalClient(
            id: client.id, kind: client.kind, identity: client.identity, connectedAt: client.connectedAt, disconnectedAt: nil)
        var snapshot = applyingClientUpsert(connectedClient, leaseRefreshedAt: attachedAt)
        var attachments = snapshot.attachments
        if mode == .owner {
            attachments = attachments.map { attachment in
                guard attachment.detachedAt == nil, attachment.mode == .owner, attachment.clientID != client.id else { return attachment }
                return TerminalAttachment(
                    id: attachment.id, sessionID: attachment.sessionID, clientID: attachment.clientID, mode: attachment.mode,
                    attachedAt: attachment.attachedAt, detachedAt: attachedAt)
            }
        }
        if let index = attachments.firstIndex(where: { $0.detachedAt == nil && $0.clientID == client.id }) {
            let existing = attachments[index]
            attachments[index] = TerminalAttachment(
                id: existing.id, sessionID: sessionID, clientID: existing.clientID, mode: mode, attachedAt: existing.attachedAt, detachedAt: nil)
        } else {
            attachments.append(TerminalAttachment(sessionID: sessionID, clientID: client.id, mode: mode, attachedAt: attachedAt))
        }
        snapshot.attachments = attachments
        return snapshot
    }

    /// Mirrors `detachClient`: marks the client disconnected (whatever its prior state) and detaches every
    /// active attachment it holds.
    public func applyingDetach(clientID: String, detachedAt: String) -> TerminalSessionAttachmentSnapshot {
        let clients = clients.map { client -> TerminalClient in
            guard client.id == clientID else { return client }
            return TerminalClient(
                id: client.id, kind: client.kind, identity: client.identity, connectedAt: client.connectedAt, disconnectedAt: detachedAt,
                leaseRefreshedAt: client.leaseRefreshedAt)
        }
        let attachments = attachments.map { attachment -> TerminalAttachment in
            guard attachment.detachedAt == nil, attachment.clientID == clientID else { return attachment }
            return TerminalAttachment(
                id: attachment.id, sessionID: attachment.sessionID, clientID: attachment.clientID, mode: attachment.mode,
                attachedAt: attachment.attachedAt, detachedAt: detachedAt)
        }
        return TerminalSessionAttachmentSnapshot(clients: clients, attachments: attachments)
    }

    /// Mirrors `transferOwnership`: demotes every other active owner attachment to viewer and promotes the
    /// new owner's active attachment (inserting one when it holds none).
    public func applyingOwnershipTransfer(to newOwnerClientID: String, sessionID: String, transferredAt: String) -> TerminalSessionAttachmentSnapshot
    {
        var attachments = attachments.map { attachment -> TerminalAttachment in
            guard attachment.detachedAt == nil, attachment.mode == .owner, attachment.clientID != newOwnerClientID else { return attachment }
            return TerminalAttachment(
                id: attachment.id, sessionID: attachment.sessionID, clientID: attachment.clientID, mode: .viewer, attachedAt: attachment.attachedAt,
                detachedAt: nil)
        }
        if let index = attachments.firstIndex(where: { $0.detachedAt == nil && $0.clientID == newOwnerClientID }) {
            let existing = attachments[index]
            attachments[index] = TerminalAttachment(
                id: existing.id, sessionID: sessionID, clientID: existing.clientID, mode: .owner, attachedAt: existing.attachedAt, detachedAt: nil)
        } else {
            attachments.append(TerminalAttachment(sessionID: sessionID, clientID: newOwnerClientID, mode: .owner, attachedAt: transferredAt))
        }
        return TerminalSessionAttachmentSnapshot(clients: clients, attachments: attachments)
    }

    /// Mirrors `touchClient`: refreshes a connected client's lease. A disconnected client keeps its lease, so
    /// a stray touch can never resurrect a client the session already let go of.
    public func applyingClientLeaseTouch(clientID: String, leaseRefreshedAt: String) -> TerminalSessionAttachmentSnapshot {
        let clients = clients.map { client -> TerminalClient in
            guard client.id == clientID, client.disconnectedAt == nil else { return client }
            return TerminalClient(
                id: client.id, kind: client.kind, identity: client.identity, connectedAt: client.connectedAt, disconnectedAt: nil,
                leaseRefreshedAt: leaseRefreshedAt)
        }
        return TerminalSessionAttachmentSnapshot(clients: clients, attachments: attachments)
    }
}
