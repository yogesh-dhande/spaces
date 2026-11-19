import Foundation

/// How far a refresh pass has got: units are sessions that need reading, so "Indexing N of M sessions"
/// is `processed` of `total`.
public struct AgentSessionIndexProgress: Sendable, Equatable {
    public var processed: Int
    public var total: Int
    public var isRefreshing: Bool

    public init(processed: Int = 0, total: Int = 0, isRefreshing: Bool = false) {
        self.processed = processed
        self.total = total
        self.isRefreshing = isRefreshing
    }
}

/// What one refresh pass did. A pass over unchanged stores reports `sessionsRead == 0`: it discovered and
/// stat-ed, and read no content.
public struct AgentSessionRefreshSummary: Sendable, Equatable {
    public var sessionsDiscovered = 0
    public var sessionsRead = 0
    /// Rows written to the full-text index. A continued turn is rewritten, so it counts once.
    public var turnsWritten = 0
    /// File system work discovery did: files stat-ed, directories stat-ed to check for change, and
    /// directories actually listed. A pass over unchanged stores lists none and stats only files that can
    /// still grow.
    public var filesStatted = 0
    public var directoriesStatted = 0
    public var directoriesListed = 0
    public var sessionsRemoved = 0
    /// Sessions whose files could not be read (a compressed file still being written, a malformed
    /// document). They keep their previous index state and are retried by the next pass.
    public var sessionsFailed = 0
    public var wasCancelled = false

    public init() {}
}
