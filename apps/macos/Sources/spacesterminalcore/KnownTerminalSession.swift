import Foundation

/// One `terminal_sessions` row: its launch configuration paired with the paths its stored
/// `root_directory` names.
///
/// The root is read from the row, never re-derived from the current profile. Re-deriving it made
/// every row whose stored root did not match the derived one invisible: the runtime-state lookup is
/// keyed on `root_directory`, so it missed, and the session was skipped by both the garbage collector
/// and startup stale recovery on every sweep, forever. Rows a predecessor daemon left behind and rows
/// whose runtime directory moved therefore accumulated with nothing able to reclaim or repair them.
///
/// A stored root is trusted for identity — it is what every `terminal_*` row is keyed by — but never
/// for deletion: `TerminalSessionPersistence.purgeSession` removes a directory only when the root is
/// one this profile owns.
public struct KnownTerminalSession: Sendable, Equatable {
    public let launchConfiguration: TerminalSessionLaunchConfiguration
    public let paths: TerminalSessionPaths

    public init(launchConfiguration: TerminalSessionLaunchConfiguration, paths: TerminalSessionPaths) {
        self.launchConfiguration = launchConfiguration
        self.paths = paths
    }

    public var sessionID: String { launchConfiguration.sessionID }
}
