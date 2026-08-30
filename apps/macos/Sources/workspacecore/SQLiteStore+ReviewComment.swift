import Foundation
import spacesdatabase

extension SQLiteStore {
    /// Canonical column order for a full `workspace_review_comments` row read; reused by every SELECT
    /// and by the upsert below so both list the same columns in the same order.
    private static let reviewCommentColumns =
        "id, workspace_id, file_path, side, line_number, line_text, body, created_at, updated_at, revision, sent_at"

    /// Draft comments only, ordered by creation time — the code pane's card list on init/scope load.
    /// Archived (sent) comments have no browsing UI in v1, so nothing else reads them. `sent_at = ''`
    /// (not `IS NULL`) matches how a draft's absent `sentAt` is actually bound: `bind(_:to:)` only
    /// supports `String`, so an unsent comment binds an empty string, never a true SQL NULL.
    public func reviewCommentDrafts(workspaceID: String) throws -> [WorkspaceReviewCommentRecord] {
        let rows = try queryRows(
            sql: """
                SELECT \(Self.reviewCommentColumns)
                FROM workspace_review_comments
                WHERE workspace_id = ? AND sent_at = ''
                ORDER BY created_at
                """, bindings: [workspaceID])
        return rows.compactMap(decodeReviewComment(row:))
    }

    /// A single comment by id, regardless of draft/sent state — used to validate a comment id belongs to
    /// the workspace a caller claims before mutating or sending it.
    public func reviewComment(id: String) throws -> WorkspaceReviewCommentRecord? {
        guard
            let row = try queryRow(
                sql: """
                    SELECT \(Self.reviewCommentColumns)
                    FROM workspace_review_comments WHERE id = ?
                    """, bindings: [id])
        else { return nil }
        return decodeReviewComment(row: row)
    }

    /// Inserts a new draft or updates an existing one's body/anchor by id. `createdAt` is preserved
    /// across an update (`ON CONFLICT` never overwrites it); `updatedAt` always reflects this call.
    /// `sentAt` is never set here — only `markReviewCommentsSent` archives a comment — so editing an
    /// already-sent row (which the device-API layer rejects before reaching the store) cannot
    /// accidentally un-archive it.
    ///
    /// `revision` is the send endpoint's concurrency token (see `WorkspaceReviewCommentRecord.revision`),
    /// so an update must bump it independent of whatever value the caller bound: `revision =
    /// workspace_review_comments.revision + 1` reads the pre-update row's own column on the right-hand
    /// side, which SQLite's upsert grammar supports directly (verified against this codebase's SQLite
    /// 3.43.2). `comment.revision` is bound only for the INSERT branch, where a brand-new draft starts at
    /// `0` (an arbitrary but consistent choice — the first edit takes it to `1`, matching the update path
    /// below); the `ON CONFLICT` arm never reads that bound value.
    public func upsertReviewComment(_ comment: WorkspaceReviewCommentRecord) throws {
        try execute(
            sql: """
                INSERT INTO workspace_review_comments(\(Self.reviewCommentColumns))
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                  file_path = excluded.file_path,
                  side = excluded.side,
                  line_number = excluded.line_number,
                  line_text = excluded.line_text,
                  body = excluded.body,
                  updated_at = excluded.updated_at,
                  revision = workspace_review_comments.revision + 1
                """,
            bindings: [
                comment.id, comment.workspaceID, comment.filePath, comment.side.rawValue, String(comment.lineNumber), comment.lineText,
                comment.body, comment.createdAt, comment.updatedAt, String(comment.revision), comment.sentAt ?? "",
            ])
    }

    public func deleteReviewComment(id: String) throws {
        try execute(sql: "DELETE FROM workspace_review_comments WHERE id = ?", bindings: [id])
    }

    /// Archives a batch of comments atomically: either every id in `ids` is marked sent or none are,
    /// matching the send endpoint's "write succeeded, so archive all covered ids together" contract.
    public func markReviewCommentsSent(ids: [String], sentAt: String) throws {
        guard !ids.isEmpty else { return }
        try withImmediateTransaction {
            for id in ids {
                try execute(sql: "UPDATE workspace_review_comments SET sent_at = ? WHERE id = ?", bindings: [sentAt, id])
            }
        }
    }

    private func decodeReviewComment(row: [String]) -> WorkspaceReviewCommentRecord? {
        guard row.count >= 11, let side = WorkspaceReviewCommentSide(rawValue: row[3]), let lineNumber = Int(row[4]), let revision = Int(row[9])
        else { return nil }
        return WorkspaceReviewCommentRecord(
            id: row[0], workspaceID: row[1], filePath: row[2], side: side, lineNumber: lineNumber, lineText: row[5], body: row[6],
            createdAt: row[7], updatedAt: row[8], revision: revision, sentAt: row[10].isEmpty ? nil : row[10])
    }
}
