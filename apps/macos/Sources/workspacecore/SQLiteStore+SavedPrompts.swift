import Foundation
import spacesdevicecore

/// The prompts the user saved on this device. Every write raises `saved_prompts_revision` in the same
/// transaction, so a client that sees the revision go up in the overview knows to pull the list, and a list
/// response older than one already applied can be told apart by its revision. The revision only goes up.
extension SQLiteStore {
    /// The library and the revision it was read at, ordered most recently used first. This is a read, so it
    /// stays out of a write transaction, which would post the change signal and push an overview for
    /// nothing. The revision is read first: a write landing between the two reads leaves the revision
    /// lower than the rows, so a client fetches again rather than treating stale rows as current.
    public func savedPromptLibrary() throws -> SpacesDeviceSavedPromptsResult {
        let revision = try savedPromptsRevision()
        let rows = try queryRows(
            sql: """
                SELECT id, title, text, created_at, updated_at, last_used_at FROM saved_prompts
                ORDER BY last_used_at DESC, created_at DESC, id
                """)
        let prompts = rows.compactMap { row -> SpacesDeviceSavedPrompt? in
            guard row.count == 6 else { return nil }
            return SpacesDeviceSavedPrompt(id: row[0], title: row[1], text: row[2], createdAt: row[3], updatedAt: row[4], lastUsedAt: row[5])
        }
        return SpacesDeviceSavedPromptsResult(prompts: prompts, revision: revision)
    }

    /// 0 until the first write.
    public func savedPromptsRevision() throws -> Int { Int(try setting(key: SettingsKey.savedPromptsRevision) ?? "") ?? 0 }

    /// A new prompt counts as used when it is created, so it lands at the top of the library.
    public func createSavedPrompt(title: String, text: String, at timestamp: String) throws -> SpacesDeviceSavedPrompt {
        let prompt = SpacesDeviceSavedPrompt(
            id: UUID().uuidString, title: title, text: text, createdAt: timestamp, updatedAt: timestamp, lastUsedAt: timestamp)
        try withImmediateTransaction {
            try execute(
                sql: "INSERT INTO saved_prompts(id, title, text, created_at, updated_at, last_used_at) VALUES (?, ?, ?, ?, ?, ?)",
                bindings: [prompt.id, title, text, timestamp, timestamp, timestamp])
            try raiseSavedPromptsRevision()
        }
        return prompt
    }

    /// Replaces the title and text without moving the prompt in the library. Returns false, and leaves the
    /// revision alone, when the prompt does not exist.
    public func updateSavedPrompt(id: String, title: String, text: String, at timestamp: String) throws -> Bool {
        try withImmediateTransaction {
            guard try savedPromptExists(id: id) else { return false }
            try execute(sql: "UPDATE saved_prompts SET title = ?, text = ?, updated_at = ? WHERE id = ?", bindings: [title, text, timestamp, id])
            try raiseSavedPromptsRevision()
            return true
        }
    }

    /// Returns false, and leaves the revision alone, when the prompt does not exist.
    public func deleteSavedPrompt(id: String) throws -> Bool {
        try withImmediateTransaction {
            guard try savedPromptExists(id: id) else { return false }
            try execute(sql: "DELETE FROM saved_prompts WHERE id = ?", bindings: [id])
            try raiseSavedPromptsRevision()
            return true
        }
    }

    /// Moves the prompt to the top of the library. Returns false, and leaves the revision alone, when the
    /// prompt does not exist.
    public func recordSavedPromptUse(id: String, at timestamp: String) throws -> Bool {
        try withImmediateTransaction {
            guard try savedPromptExists(id: id) else { return false }
            try execute(sql: "UPDATE saved_prompts SET last_used_at = ? WHERE id = ?", bindings: [timestamp, id])
            try raiseSavedPromptsRevision()
            return true
        }
    }

    private func savedPromptExists(id: String) throws -> Bool {
        !(try queryRows(sql: "SELECT 1 FROM saved_prompts WHERE id = ?", bindings: [id])).isEmpty
    }

    private func raiseSavedPromptsRevision() throws {
        try execute(
            sql: """
                INSERT INTO settings(key, value) VALUES (?, '1')
                ON CONFLICT(key) DO UPDATE SET value = CAST(value AS INTEGER) + 1
                """, bindings: [SettingsKey.savedPromptsRevision])
    }
}
