import Foundation
import XCTest
import spacesdatabase

@testable import workspacecore

/// Opening a profile saved before saved prompts existed keeps everything it held and leaves the library
/// ready to use.
final class SavedPromptsSchemaMigrationTests: XCTestCase {
    /// The schema version a profile has just before the saved prompts step.
    private let preSavedPromptsVersion = 28

    func testUpgradeKeepsExistingDataAndStartsAnEmptyLibrary() throws {
        let store = try makeTemporaryStore()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        let project = makeProjectRecord(dir: dir)
        try store.upsert(project: project)
        let workspace = makeWorkspaceRecord(projectID: project.id, dir: dir + "/ws")
        try store.upsert(workspace: workspace)
        try store.setSetting(key: "kept_setting", value: "kept")
        // A profile saved before the step: the current shape without the prompts table or its revision.
        let dbPath = try DatabaseLocator.defaultPath()
        let raw = try SpacesSQLiteDatabase(path: dbPath)
        try raw.execute(sql: "DROP TABLE saved_prompts")
        try raw.execute(sql: "DELETE FROM settings WHERE key = 'saved_prompts_revision'")
        try raw.execute(sql: "UPDATE migration_state SET current_version = \(preSavedPromptsVersion)")

        let migrated = try SQLiteStore(path: dbPath)

        XCTAssertEqual(try migrated.setting(key: "kept_setting"), "kept")
        XCTAssertEqual(try migrated.workspace(id: workspace.id)?.id, workspace.id)
        XCTAssertEqual(try migrated.savedPromptLibrary().prompts.count, 0)
        XCTAssertEqual(try migrated.savedPromptLibrary().revision, 0)
        let created = try migrated.createSavedPrompt(title: "first", text: "body", at: "2026-11-13T10:00:00.000Z")
        XCTAssertEqual(try migrated.savedPromptLibrary().prompts.map(\.id), [created.id])
        XCTAssertEqual(try raw.queryRow(sql: "SELECT current_version FROM migration_state")?.first, "\(DatabaseSchema.currentVersion)")
    }
}
