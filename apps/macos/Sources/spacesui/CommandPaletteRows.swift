import Foundation
import spacesdevicecore

/// One row of the command palette's table. The targets come first and the Prompts section follows them,
/// so a target's row index is its index among the targets: the numbered shortcuts map to rows
/// 0...9 and so reach targets only.
enum CommandPaletteRow: Equatable {
    case target(Int)
    /// The "Prompts" section label. It is never selectable.
    case promptsHeader
    case prompt(Int)
}

enum CommandPaletteRows {
    static func rows(targetCount: Int, promptCount: Int) -> [CommandPaletteRow] {
        var rows = (0..<targetCount).map(CommandPaletteRow.target)
        if promptCount > 0 {
            rows.append(.promptsHeader)
            rows.append(contentsOf: (0..<promptCount).map(CommandPaletteRow.prompt))
        }
        return rows
    }

    static func isSelectable(_ row: CommandPaletteRow) -> Bool { row != .promptsHeader }

    static func firstSelectableIndex(in rows: [CommandPaletteRow]) -> Int { rows.firstIndex(where: isSelectable) ?? 0 }

    /// The row an arrow key moves to: `delta` rows away, stepping over the header, stopping at either end.
    static func selectionIndex(from index: Int, delta: Int, in rows: [CommandPaletteRow]) -> Int {
        guard !rows.isEmpty, delta != 0 else { return index }
        var candidate = index + delta
        while rows.indices.contains(candidate) {
            if isSelectable(rows[candidate]) { return candidate }
            candidate += delta
        }
        return index
    }

    /// The saved prompts a query lists. Prompts appear only once something is typed: with an empty query
    /// the palette is a list of targets to jump to, and the whole library would bury them.
    static func promptEntries(in library: SavedPromptLibrary, query: String) -> [SavedPromptLibrary.Entry] {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        return library.entries(matching: query)
    }
}
