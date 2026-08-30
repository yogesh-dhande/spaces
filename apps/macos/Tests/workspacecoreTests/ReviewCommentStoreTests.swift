import Foundation
import XCTest

@testable import workspacecore

/// Behavior coverage for `workspace_review_comments`: draft listing, upsert insert/update, delete, and
/// `markReviewCommentsSent` archiving. Workspace/project-delete cascade for this table is covered
/// alongside every other dependent table in `StoreTests.testDeleteWorkspaceRemovesDependentRows` and
/// `testDeleteProjectRemovesProjectWorkspacesAndDependents`; the v17→v18 migration itself is covered by
/// `StoreTests.testUpgradeFromV17CreatesAUsableReviewCommentsTable`.
final class ReviewCommentStoreTests: XCTestCase {

    override func setUpWithError() throws { try useIsolatedSpacesProfile() }

    private func makeProjectAndWorkspace(store: SQLiteStore) throws -> (ProjectRecord, WorkspaceRecord) {
        let project = makeProjectRecord(dir: try makeTempDirectory().path)
        let workspace = makeWorkspaceRecord(projectID: project.id, dir: project.dir)
        try store.upsert(project: project)
        try store.upsert(workspace: workspace)
        return (project, workspace)
    }

    private func makeComment(
        id: String = UUID().uuidString, workspaceID: String, filePath: String = "src/foo.ts", side: WorkspaceReviewCommentSide = .new,
        lineNumber: Int = 1, lineText: String = "const x = compute();", body: String = "why recompute?", createdAt: String = "2026-08-22T00:00:00Z",
        updatedAt: String = "2026-08-22T00:00:00Z", revision: Int = 0, sentAt: String? = nil
    ) -> WorkspaceReviewCommentRecord {
        WorkspaceReviewCommentRecord(
            id: id, workspaceID: workspaceID, filePath: filePath, side: side, lineNumber: lineNumber, lineText: lineText, body: body,
            createdAt: createdAt, updatedAt: updatedAt, revision: revision, sentAt: sentAt)
    }

    func testUpsertInsertsANewDraftAndListDraftsReturnsIt() throws {
        let store = try makeTemporaryStore()
        let (_, workspace) = try makeProjectAndWorkspace(store: store)
        let comment = makeComment(workspaceID: workspace.id)

        try store.upsertReviewComment(comment)

        let drafts = try store.reviewCommentDrafts(workspaceID: workspace.id)
        XCTAssertEqual(drafts, [comment])
    }

    func testUpsertOnAnExistingIDUpdatesBodyAndAnchorButPreservesCreatedAt() throws {
        let store = try makeTemporaryStore()
        let (_, workspace) = try makeProjectAndWorkspace(store: store)
        let original = makeComment(id: "comment-1", workspaceID: workspace.id, lineNumber: 1, body: "original body", createdAt: "2026-08-01T00:00:00Z")
        try store.upsertReviewComment(original)

        let edited = makeComment(
            id: "comment-1", workspaceID: workspace.id, filePath: "src/bar.ts", lineNumber: 42, lineText: "moved()", body: "edited body",
            createdAt: "2026-08-20T00:00:00Z", updatedAt: "2026-08-20T00:00:00Z")
        try store.upsertReviewComment(edited)

        let reloaded = try XCTUnwrap(store.reviewComment(id: "comment-1"))
        XCTAssertEqual(reloaded.body, "edited body")
        XCTAssertEqual(reloaded.filePath, "src/bar.ts")
        XCTAssertEqual(reloaded.lineNumber, 42)
        XCTAssertEqual(reloaded.lineText, "moved()")
        XCTAssertEqual(reloaded.createdAt, "2026-08-01T00:00:00Z", "created_at is not overwritten by an update")
        XCTAssertEqual(reloaded.updatedAt, "2026-08-20T00:00:00Z")
        XCTAssertEqual(reloaded.revision, 1, "the store bumps revision itself on every update, ignoring whatever the caller bound")
    }

    /// The whole point of `revision`: unlike `updatedAt` (whole-second resolution, so two edits inside
    /// the same second are indistinguishable), it must advance on every single update regardless of how
    /// much wall-clock time passed between calls — this test makes back-to-back calls with no artificial
    /// delay to prove that.
    func testUpsertRevisionIncrementsMonotonicallyAcrossBackToBackUpdatesWithNoTimeGap() throws {
        let store = try makeTemporaryStore()
        let (_, workspace) = try makeProjectAndWorkspace(store: store)
        let comment = makeComment(id: "comment-1", workspaceID: workspace.id)

        try store.upsertReviewComment(comment)
        XCTAssertEqual(try XCTUnwrap(store.reviewComment(id: "comment-1")).revision, 0, "a fresh insert starts at revision 0")

        try store.upsertReviewComment(comment)
        XCTAssertEqual(try XCTUnwrap(store.reviewComment(id: "comment-1")).revision, 1)

        try store.upsertReviewComment(comment)
        XCTAssertEqual(try XCTUnwrap(store.reviewComment(id: "comment-1")).revision, 2)
    }

    func testDeleteReviewCommentRemovesIt() throws {
        let store = try makeTemporaryStore()
        let (_, workspace) = try makeProjectAndWorkspace(store: store)
        let comment = makeComment(id: "comment-1", workspaceID: workspace.id)
        try store.upsertReviewComment(comment)

        try store.deleteReviewComment(id: "comment-1")

        XCTAssertNil(try store.reviewComment(id: "comment-1"))
        XCTAssertTrue(try store.reviewCommentDrafts(workspaceID: workspace.id).isEmpty)
    }

    func testReviewCommentDraftsOrdersByCreatedAtAndExcludesOtherWorkspaces() throws {
        let store = try makeTemporaryStore()
        let (project, workspace) = try makeProjectAndWorkspace(store: store)
        let otherWorkspace = makeWorkspaceRecord(projectID: project.id, dir: try makeTempDirectory().path)
        try store.upsert(workspace: otherWorkspace)

        let second = makeComment(id: "second", workspaceID: workspace.id, createdAt: "2026-08-02T00:00:00Z")
        let first = makeComment(id: "first", workspaceID: workspace.id, createdAt: "2026-08-01T00:00:00Z")
        let otherWorkspaceComment = makeComment(id: "elsewhere", workspaceID: otherWorkspace.id, createdAt: "2026-08-01T00:00:00Z")
        try store.upsertReviewComment(second)
        try store.upsertReviewComment(first)
        try store.upsertReviewComment(otherWorkspaceComment)

        let drafts = try store.reviewCommentDrafts(workspaceID: workspace.id)
        XCTAssertEqual(drafts.map(\.id), ["first", "second"])
    }

    func testMarkReviewCommentsSentArchivesTheGivenIDsAndDropsThemFromDrafts() throws {
        let store = try makeTemporaryStore()
        let (_, workspace) = try makeProjectAndWorkspace(store: store)
        let sent = makeComment(id: "sent", workspaceID: workspace.id)
        let stillDraft = makeComment(id: "still-draft", workspaceID: workspace.id)
        try store.upsertReviewComment(sent)
        try store.upsertReviewComment(stillDraft)

        try store.markReviewCommentsSent(ids: ["sent"], sentAt: "2026-08-22T01:00:00Z")

        let drafts = try store.reviewCommentDrafts(workspaceID: workspace.id)
        XCTAssertEqual(drafts.map(\.id), ["still-draft"], "an archived comment leaves the draft list")

        let archived = try XCTUnwrap(store.reviewComment(id: "sent"))
        XCTAssertEqual(archived.sentAt, "2026-08-22T01:00:00Z")
    }

    func testMarkReviewCommentsSentWithMultipleIDsArchivesAllOfThem() throws {
        let store = try makeTemporaryStore()
        let (_, workspace) = try makeProjectAndWorkspace(store: store)
        let one = makeComment(id: "one", workspaceID: workspace.id)
        let two = makeComment(id: "two", workspaceID: workspace.id)
        try store.upsertReviewComment(one)
        try store.upsertReviewComment(two)

        try store.markReviewCommentsSent(ids: ["one", "two"], sentAt: "2026-08-22T01:00:00Z")

        XCTAssertTrue(try store.reviewCommentDrafts(workspaceID: workspace.id).isEmpty)
        XCTAssertEqual(try store.reviewComment(id: "one")?.sentAt, "2026-08-22T01:00:00Z")
        XCTAssertEqual(try store.reviewComment(id: "two")?.sentAt, "2026-08-22T01:00:00Z")
    }
}
