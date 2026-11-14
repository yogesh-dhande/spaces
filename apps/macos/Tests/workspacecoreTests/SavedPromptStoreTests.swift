import Foundation
import XCTest
import spacesdevicecore

@testable import workspacecore

/// The device's saved prompt library: how writes order it and when they raise the revision clients use to
/// decide whether to fetch again.
final class SavedPromptStoreTests: XCTestCase {
    private func titles(_ store: SQLiteStore) throws -> [String] { try store.savedPromptLibrary().prompts.map(\.title) }

    func testANewPromptIsFirstBecauseCreatingItCountsAsUsingIt() throws {
        let store = try makeTemporaryStore()
        let first = try store.createSavedPrompt(title: "first", text: "one", at: "2026-11-13T10:00:00.000Z")
        _ = try store.createSavedPrompt(title: "second", text: "two", at: "2026-11-13T10:01:00.000Z")

        XCTAssertEqual(try titles(store), ["second", "first"])
        XCTAssertEqual(first.lastUsedAt, first.createdAt)
        XCTAssertEqual(try store.savedPromptLibrary().prompts.last?.lastUsedAt, "2026-11-13T10:00:00.000Z")
    }

    func testCopyingAnOlderPromptMovesItFirst() throws {
        let store = try makeTemporaryStore()
        let a = try store.createSavedPrompt(title: "a", text: "one", at: "2026-11-13T10:00:00.000Z")
        _ = try store.createSavedPrompt(title: "b", text: "two", at: "2026-11-13T10:01:00.000Z")

        XCTAssertTrue(try store.recordSavedPromptUse(id: a.id, at: "2026-11-13T10:02:00.000Z"))

        XCTAssertEqual(try titles(store), ["a", "b"])
    }

    func testEditingChangesTheTextButNotThePlaceInTheLibrary() throws {
        let store = try makeTemporaryStore()
        let a = try store.createSavedPrompt(title: "a", text: "one", at: "2026-11-13T10:00:00.000Z")
        _ = try store.createSavedPrompt(title: "b", text: "two", at: "2026-11-13T10:01:00.000Z")

        XCTAssertTrue(try store.updateSavedPrompt(id: a.id, title: "a edited", text: "changed", at: "2026-11-13T10:05:00.000Z"))

        let library = try store.savedPromptLibrary()
        XCTAssertEqual(library.prompts.map(\.title), ["b", "a edited"])
        let edited = try XCTUnwrap(library.prompts.last)
        XCTAssertEqual(edited.text, "changed")
        XCTAssertEqual(edited.createdAt, "2026-11-13T10:00:00.000Z")
        XCTAssertEqual(edited.updatedAt, "2026-11-13T10:05:00.000Z")
        XCTAssertEqual(edited.lastUsedAt, "2026-11-13T10:00:00.000Z")
    }

    func testDeletingRemovesThePrompt() throws {
        let store = try makeTemporaryStore()
        let a = try store.createSavedPrompt(title: "a", text: "one", at: "2026-11-13T10:00:00.000Z")
        _ = try store.createSavedPrompt(title: "b", text: "two", at: "2026-11-13T10:01:00.000Z")

        XCTAssertTrue(try store.deleteSavedPrompt(id: a.id))

        XCTAssertEqual(try titles(store), ["b"])
    }

    func testAnUnknownPromptReturnsFalseAndLeavesTheRevisionAlone() throws {
        let store = try makeTemporaryStore()
        _ = try store.createSavedPrompt(title: "a", text: "one", at: "2026-11-13T10:00:00.000Z")
        let revision = try store.savedPromptsRevision()

        XCTAssertFalse(try store.updateSavedPrompt(id: "missing", title: "t", text: "x", at: "2026-11-13T10:01:00.000Z"))
        XCTAssertFalse(try store.deleteSavedPrompt(id: "missing"))
        XCTAssertFalse(try store.recordSavedPromptUse(id: "missing", at: "2026-11-13T10:01:00.000Z"))

        XCTAssertEqual(try store.savedPromptsRevision(), revision)
    }

    func testEveryWriteRaisesTheRevisionAndReadsDoNot() throws {
        let store = try makeTemporaryStore()
        XCTAssertEqual(try store.savedPromptsRevision(), 0)

        let prompt = try store.createSavedPrompt(title: "a", text: "one", at: "2026-11-13T10:00:00.000Z")
        XCTAssertEqual(try store.savedPromptsRevision(), 1)
        _ = try store.updateSavedPrompt(id: prompt.id, title: "a", text: "two", at: "2026-11-13T10:01:00.000Z")
        XCTAssertEqual(try store.savedPromptsRevision(), 2)
        _ = try store.recordSavedPromptUse(id: prompt.id, at: "2026-11-13T10:02:00.000Z")
        XCTAssertEqual(try store.savedPromptsRevision(), 3)

        _ = try store.savedPromptLibrary()
        _ = try store.savedPromptLibrary()
        XCTAssertEqual(try store.savedPromptsRevision(), 3)

        _ = try store.deleteSavedPrompt(id: prompt.id)
        XCTAssertEqual(try store.savedPromptLibrary().revision, 4)
    }

    func testPromptsAndTheRevisionSurviveReopeningTheStore() throws {
        let store = try makeTemporaryStore()
        _ = try store.createSavedPrompt(title: "kept", text: "body\nwith lines  ", at: "2026-11-13T10:00:00.000Z")
        let reopened = try SQLiteStore(path: try DatabaseLocator.defaultPath())

        let library = try reopened.savedPromptLibrary()
        XCTAssertEqual(library.prompts.map(\.title), ["kept"])
        XCTAssertEqual(library.prompts.first?.text, "body\nwith lines  ")
        XCTAssertEqual(library.revision, 1)
    }
}
