import Foundation

/// Stores desktop (yabai) window IDs outside the daemon database.
///
/// Desktop window IDs are client/desktop-local: they only exist for the machine running the GUI
/// and were the one piece of `runtime_targets` that the session-less daemon (no yabai) never owned.
/// They are keyed by the daemon-owned runtime-target id — stable across refreshes and uniform across
/// every window role (terminal, browser, editor, …) — so the GUI can own the window ID in the client
/// database while still correlating it to the logical runtime target.
///
/// The GUI injects a client-database-backed implementation into `SQLiteStore`; when no store is
/// injected (the daemon, the CLI), window IDs are simply absent — which is correct, since only the
/// local desktop can focus its own windows.
public protocol DesktopWindowIDStore: AnyObject, Sendable {
    func desktopWindowID(workspaceID: String, runtimeTargetID: String) throws -> Int?
    func setDesktopWindowID(workspaceID: String, runtimeTargetID: String, windowID: Int) throws
    func clearDesktopWindowID(workspaceID: String, runtimeTargetID: String) throws
    /// Reverse lookup for "which runtime targets own this yabai window", most-recently-updated first.
    func desktopWindowMatches(windowID: Int) throws -> [(workspaceID: String, runtimeTargetID: String)]
}
