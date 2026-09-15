import Foundation

/// The window cycle's in-memory bookkeeping, filed by scope: the cursor remembering the last target
/// focused in each rotation, the recent-target lists that supply MRU ordering at the start of a cycle
/// burst, and the short-lived frozen rotation that keeps rapid presses walking one order.
///
/// A workspace rotation reads its own recent list; every cross-device rotation reads one shared list
/// of visits across all devices and workspaces, so switching between global modes never restarts from
/// a cold order. Nothing here is persisted: a launch starts from sidebar order.
struct WindowCycleState {
    private static let maxRecentCursorCount = 128

    private var cursorByScope: [String: WorkspaceWindowCycle.Cursor] = [:]
    private var recentCursorsByWorkspaceScope: [String: [WorkspaceWindowCycle.Cursor]] = [:]
    private var recentGlobalCursors: [WorkspaceWindowCycle.Cursor] = []
    private var cycleSessionByScope: [String: WorkspaceWindowCycle.CycleSession] = [:]

    func cursor(for scope: WindowCycleScope) -> WorkspaceWindowCycle.Cursor? { cursorByScope[scope.key] }

    func recentCursors(for scope: WindowCycleScope) -> [WorkspaceWindowCycle.Cursor] {
        switch scope {
        case .workspace: return recentCursorsByWorkspaceScope[scope.key] ?? []
        case .mode: return recentGlobalCursors
        }
    }

    /// The frozen rotation still authoritative for `scope`, dropping one that has gone stale.
    mutating func validCycleSession(for scope: WindowCycleScope, now: Date = Date()) -> WorkspaceWindowCycle.CycleSession? {
        guard let session = cycleSessionByScope[scope.key] else { return nil }
        guard now.timeIntervalSince(session.lastUsedAt) <= WorkspaceWindowCycle.cycleSessionTimeout else {
            cycleSessionByScope.removeValue(forKey: scope.key)
            return nil
        }
        return session
    }

    /// Records a visit to a target: it becomes the workspace rotation's cursor and the head of that
    /// workspace's recent list, and, when the owning device is known, the head of the shared
    /// cross-device list too. `globalCursor` is nil only while a workspace's owning device is not
    /// loaded, which is exactly when a cross-device rotation cannot name the target either.
    ///
    /// A visit that did not come from cycling ends every frozen rotation, not just this workspace's:
    /// the user went somewhere by hand, so no burst is still running.
    mutating func recordVisit(
        cursor: WorkspaceWindowCycle.Cursor, globalCursor: WorkspaceWindowCycle.Cursor?, workspaceID: String, preserveCycleSession: Bool
    ) {
        guard !cursor.isEmpty else { return }
        let scope = WindowCycleScope.workspace(workspaceID)
        cursorByScope[scope.key] = cursor
        recentCursorsByWorkspaceScope[scope.key] = Self.promoting(cursor, in: recentCursorsByWorkspaceScope[scope.key] ?? [])
        if let globalCursor, !globalCursor.isEmpty { recentGlobalCursors = Self.promoting(globalCursor, in: recentGlobalCursors) }
        if !preserveCycleSession { cycleSessionByScope.removeAll() }
    }

    /// Records where a cycle step landed in `scope` and freezes the rotation it walked, so the next
    /// press within the burst window continues that same order.
    mutating func recordCycleLanding(scope: WindowCycleScope, orderedCursors: [WorkspaceWindowCycle.Cursor], index: Int, at landedAt: Date = Date()) {
        guard orderedCursors.indices.contains(index) else { return }
        cursorByScope[scope.key] = orderedCursors[index]
        cycleSessionByScope[scope.key] = WorkspaceWindowCycle.CycleSession(orderedCursors: orderedCursors, currentIndex: index, lastUsedAt: landedAt)
    }

    private static func promoting(_ cursor: WorkspaceWindowCycle.Cursor, in cursors: [WorkspaceWindowCycle.Cursor]) -> [WorkspaceWindowCycle.Cursor] {
        var promoted = cursors
        promoted.removeAll { $0 == cursor }
        promoted.insert(cursor, at: 0)
        if promoted.count > maxRecentCursorCount { promoted.removeLast(promoted.count - maxRecentCursorCount) }
        return promoted
    }
}
