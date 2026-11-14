import Foundation
import Testing
import spacesdevicecore
import spacesterminalcore

@testable import spacesui

@Suite struct CommandPaletteRowsTests {
    @Test func targetsComeFirstSoTheirRowIndexIsTheirTargetIndex() {
        let rows = CommandPaletteRows.rows(targetCount: 3, promptCount: 2)

        #expect(rows == [.target(0), .target(1), .target(2), .promptsHeader, .prompt(0), .prompt(1)])
    }

    @Test func noPromptsMeansNoHeader() {
        #expect(CommandPaletteRows.rows(targetCount: 2, promptCount: 0) == [.target(0), .target(1)])
        #expect(CommandPaletteRows.rows(targetCount: 0, promptCount: 0).isEmpty)
    }

    @Test func theHeaderIsNeverSelectable() {
        let rows = CommandPaletteRows.rows(targetCount: 1, promptCount: 1)

        #expect(rows.filter(CommandPaletteRows.isSelectable) == [.target(0), .prompt(0)])
    }

    @Test func arrowKeysStepOverTheHeaderAndStopAtTheEnds() {
        let rows = CommandPaletteRows.rows(targetCount: 2, promptCount: 2)

        #expect(CommandPaletteRows.selectionIndex(from: 1, delta: 1, in: rows) == 3, "down from the last target skips the header")
        #expect(CommandPaletteRows.selectionIndex(from: 3, delta: -1, in: rows) == 1, "up from the first prompt skips the header")
        #expect(CommandPaletteRows.selectionIndex(from: 0, delta: -1, in: rows) == 0)
        #expect(CommandPaletteRows.selectionIndex(from: 4, delta: 1, in: rows) == 4)
    }

    @Test func withOnlyPromptsTheSelectionStartsBelowTheHeaderAndCannotMoveOntoIt() {
        let rows = CommandPaletteRows.rows(targetCount: 0, promptCount: 2)

        #expect(CommandPaletteRows.firstSelectableIndex(in: rows) == 1)
        #expect(CommandPaletteRows.selectionIndex(from: 1, delta: -1, in: rows) == 1)
    }

    @Test func promptsAppearOnlyForANonEmptyQuery() {
        var library = SavedPromptLibrary()
        let stamp = TerminalSessionTimestamp.fractionalString(from: Date())
        _ = library.reconcile(reachable: [SavedPromptLibrary.Device(id: "local", name: "This Mac", overviewRevision: 1)])
        library.apply(
            SpacesDeviceSavedPromptsResult(
                prompts: [
                    SpacesDeviceSavedPrompt(
                        id: "p", title: "Write the failing test first", text: "Reproduce the bug", createdAt: stamp, updatedAt: stamp,
                        lastUsedAt: stamp)
                ], revision: 1), deviceID: "local")

        #expect(CommandPaletteRows.promptEntries(in: library, query: "").isEmpty)
        #expect(CommandPaletteRows.promptEntries(in: library, query: "   ").isEmpty)
        #expect(CommandPaletteRows.promptEntries(in: library, query: "FAILING").map(\.prompt.id) == ["p"])
        #expect(CommandPaletteRows.promptEntries(in: library, query: "reproduce").map(\.prompt.id) == ["p"], "text matches too")
        #expect(CommandPaletteRows.promptEntries(in: library, query: "nothing like it").isEmpty)
    }
}
