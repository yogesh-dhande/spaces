import Foundation

/// Which side of a diff a review comment's line lives on: `old` anchors to the pre-image (a removed or
/// context line), `new` to the post-image (an added or context line) — the same vocabulary a unified
/// diff's two columns use. Matches the code pane web app's `DiffLineAnnotation.side`.
public enum WorkspaceReviewCommentSide: String, Codable, Sendable {
    case old
    case new
}

/// A code pane review-comment draft, or an archived (sent) one. Anchored to a `(filePath, side,
/// lineNumber)` triple with the anchored line's own text (`lineText`) captured at creation time so a
/// later diff refresh can re-place a draft whose line moved (exact match) or float it to the nearest
/// matching line (fuzzy match) — see the code pane web app's re-anchoring logic, which owns that search.
/// `sentAt` is `nil` for a draft; once set the comment is archived and no longer appears in
/// `WorkspaceReviewCommentStore.drafts(workspaceID:)`. There is no thread or resolution state: sending
/// is the whole lifecycle a comment has past its draft stage, matching the locked v1 decision that the
/// agent's next diff is the reply.
public struct WorkspaceReviewCommentRecord: Codable, Sendable, Equatable {
    public let id: String
    public let workspaceID: String
    public let filePath: String
    public let side: WorkspaceReviewCommentSide
    public let lineNumber: Int
    public let lineText: String
    public let body: String
    public let createdAt: String
    public let updatedAt: String
    /// Monotonic edit counter, bumped by every `upsertReviewComment` call that updates an existing row
    /// (a fresh insert starts at `0`). This, not `updatedAt`, is the send endpoint's concurrency token:
    /// `updatedAt` comes from `TerminalSessionTimestamp.string(from:)`, which has whole-second resolution,
    /// so two edits inside the same second would leave it unchanged and let a stale send through silently.
    /// `updatedAt` itself stays purely informational (display/debugging), not read for conflict detection.
    public let revision: Int
    public let sentAt: String?

    public init(
        id: String, workspaceID: String, filePath: String, side: WorkspaceReviewCommentSide, lineNumber: Int, lineText: String, body: String,
        createdAt: String, updatedAt: String, revision: Int, sentAt: String?
    ) {
        self.id = id
        self.workspaceID = workspaceID
        self.filePath = filePath
        self.side = side
        self.lineNumber = lineNumber
        self.lineText = lineText
        self.body = body
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.revision = revision
        self.sentAt = sentAt
    }
}
