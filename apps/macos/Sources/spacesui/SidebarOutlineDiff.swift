import Foundation

/// One row of the sidebar outline's logical tree: the outline item's cache key (its stable identity) and
/// everything that row renders.
struct SidebarOutlineRow: Hashable, Sendable {
    let cacheKey: String
    let signature: SidebarRowSignature
}

/// What an applied sidebar change means for the outline view.
enum SidebarOutlineDiffVerdict: Equatable {
    /// Nothing any row renders changed; the outline is already correct.
    case unchanged
    /// The same rows in the same order, with the listed ones rendering differently.
    case rowsChanged([String])
    /// Rows were added, removed, or reordered, so the outline has to be rebuilt wholesale.
    case structureChanged
}

/// Decides how little of the outline an applied sidebar change has to repaint.
///
/// A paired device with live terminal sessions pushes a changed overview several times a second, and
/// nearly every one of those changes touches a single row. Rebuilding every row view for each of them
/// costs tens of milliseconds of main-thread layout, so the outline is rebuilt wholesale only when its
/// rows actually changed shape.
enum SidebarOutlineDiff {
    /// `previous` is `nil` before the first apply, which has nothing painted yet and so always rebuilds.
    nonisolated static func compute(previous: [SidebarOutlineRow]?, current: [SidebarOutlineRow]) -> SidebarOutlineDiffVerdict {
        guard let previous, previous.count == current.count else { return .structureChanged }
        var changedCacheKeys: [String] = []
        for (previousRow, currentRow) in zip(previous, current) {
            // Identity and order are compared positionally: a row that moved renders in a different place
            // even when its content is untouched, which only a rebuild can express.
            guard previousRow.cacheKey == currentRow.cacheKey else { return .structureChanged }
            if previousRow.signature != currentRow.signature { changedCacheKeys.append(currentRow.cacheKey) }
        }
        return changedCacheKeys.isEmpty ? .unchanged : .rowsChanged(changedCacheKeys)
    }
}
