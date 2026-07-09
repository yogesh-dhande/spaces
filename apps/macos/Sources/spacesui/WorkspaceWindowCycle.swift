import Foundation

/// Client-side window-cycle state machine.
///
/// A "window" is a client concept (see docs/implementation.md): cycling rotates over the
/// same ordered focusable targets the numbered shortcuts use (rebuilt from the overview),
/// tracked here by an opaque per-target cursor key. The cursor remembers the last-focused
/// target per workspace, the recent cursor list supplies MRU ordering at the start of a
/// cycle burst, and a short-lived cycle session preserves that rotation across rapid
/// presses. All state is held in memory only. This type is intentionally agnostic to the
/// target type — the caller maps each target to a stable cursor key.
enum WorkspaceWindowCycle {
    typealias Cursor = String

    /// A short-lived record of the order targets were last cycled in, so rapid repeated
    /// presses keep a stable rotation even as the target list is rebuilt.
    struct CycleSession: Sendable {
        var orderedCursors: [Cursor]
        var currentIndex: Int
        var lastUsedAt: Date
    }

    /// How long a cycle session stays authoritative after the last press (matches the
    /// orchestrator's 2-second window).
    static let cycleSessionTimeout: TimeInterval = 2

    static func index(of cursor: Cursor, in cursors: [Cursor]) -> Int? {
        cursors.firstIndex(of: cursor)
    }

    /// Reorders targets for cycling. When a recent cycle session still matches the current
    /// cursors it preserves that rotation; otherwise it builds a fresh MRU order with the
    /// resolved current target first, then recent targets, then remaining targets in natural
    /// order.
    static func cycleOrdering(cursors: [Cursor], currentIndex: Int?, session: CycleSession?, recentCursors: [Cursor] = [])
        -> (indices: [Int], currentIndex: Int?)
    {
        if let session, let sessionIndices = sessionTargetIndices(session: session, cursors: cursors) {
            let resolvedCurrentIndex: Int?
            if let currentIndex {
                let cursor = cursors[currentIndex]
                resolvedCurrentIndex = sessionIndices.firstIndex(where: { cursors[$0] == cursor }) ?? session.currentIndex
            } else {
                resolvedCurrentIndex = session.currentIndex
            }
            return (sessionIndices, resolvedCurrentIndex)
        }
        let orderedIndices = mruTargetIndices(cursors: cursors, currentIndex: currentIndex, recentCursors: recentCursors)
        return (orderedIndices, currentIndex.flatMap { orderedIndices.firstIndex(of: $0) })
    }

    private static func mruTargetIndices(cursors: [Cursor], currentIndex: Int?, recentCursors: [Cursor]) -> [Int] {
        var remainingIndicesByCursor: [Cursor: [Int]] = [:]
        for (index, cursor) in cursors.enumerated() { remainingIndicesByCursor[cursor, default: []].append(index) }

        var orderedIndices: [Int] = []
        func append(cursor: Cursor) {
            guard var indices = remainingIndicesByCursor[cursor], let nextIndex = indices.first else { return }
            orderedIndices.append(nextIndex)
            indices.removeFirst()
            remainingIndicesByCursor[cursor] = indices.isEmpty ? nil : indices
        }

        if let currentIndex, cursors.indices.contains(currentIndex) { append(cursor: cursors[currentIndex]) }
        for cursor in recentCursors { append(cursor: cursor) }
        for (_, indices) in remainingIndicesByCursor.sorted(by: { $0.value[0] < $1.value[0] }) { orderedIndices.append(contentsOf: indices) }
        return orderedIndices
    }

    private static func sessionTargetIndices(session: CycleSession, cursors: [Cursor]) -> [Int]? {
        var remainingIndicesByCursor: [Cursor: [Int]] = [:]
        for (index, cursor) in cursors.enumerated() { remainingIndicesByCursor[cursor, default: []].append(index) }
        var orderedIndices: [Int] = []
        for cursor in session.orderedCursors {
            guard var indices = remainingIndicesByCursor[cursor], let nextIndex = indices.first else { return nil }
            orderedIndices.append(nextIndex)
            indices.removeFirst()
            remainingIndicesByCursor[cursor] = indices.isEmpty ? nil : indices
        }
        for (_, indices) in remainingIndicesByCursor.sorted(by: { $0.value[0] < $1.value[0] }) { orderedIndices.append(contentsOf: indices) }
        return orderedIndices
    }

    /// The next index to focus given the ordering and a direction (+1 next, -1 previous).
    static func nextIndex(orderedCount: Int, orderedCurrentIndex: Int?, delta: Int) -> Int {
        guard orderedCount > 0 else { return 0 }
        if let orderedCurrentIndex { return (orderedCurrentIndex + delta + orderedCount) % orderedCount }
        return delta > 0 ? 0 : orderedCount - 1
    }
}
