import Foundation

/// The tunable bounds that govern how long an ended terminal session's on-disk footprint
/// (`output.log`, `service.log`, per-session sqlite rows, directory) is retained before the
/// daemon garbage collector reclaims it. All retention knobs live in one type so the daemon has
/// a single place to reason about — and a single place to override in tests — the lifetime of a
/// session's footprint.
///
/// A session's transcript deliberately outlives its process so an ended pane stays reopenable
/// (see `TerminalSessionGarbageCollector`); these bounds decide when "reopenable" turns into
/// "reclaimable". Reference `TerminalScrollbackBudget` for the sibling policy that bounds a
/// *live* transcript's size; this type bounds an *ended* session's age and aggregate disk use.
public struct TerminalSessionRetentionPolicy: Sendable {
    /// How long an ended session's footprint is kept past the session's end before it age-expires.
    /// Seven days keeps an ended pane reopenable for a full week — long enough that a user who
    /// closes a pane on Friday can still reopen its scrollback the following Friday — after which
    /// the session's referencing product rows are released and its footprint is purged. The clock
    /// is the session's own end time (runtime `exitedAt`), not any per-row timestamp, so the whole
    /// session ages as one unit.
    public let endedSessionMaxAge: TimeInterval

    /// The aggregate on-disk ceiling for all ended sessions' directories. The age rule alone lets a
    /// bursty week — many large, chatty ended sessions created in quick succession — accumulate
    /// gigabytes that would sit for seven days before any of it expires. This backstop bounds that
    /// accumulation ahead of the age rule: once the ended-session total exceeds it, the collector
    /// evicts oldest-ended-first even for sessions younger than `endedSessionMaxAge`. Two gigabytes
    /// leaves generous room for a week of normal transcripts while still capping pathological bursts.
    public let endedTranscriptByteBudget: Int64

    /// How long a session directory that has no runtime state yet (config written, runtime not) is
    /// protected from the separate orphan sweep. A session is created in two steps, so a directory
    /// briefly exists with no runtime row; this grace period keeps that mid-creation window from
    /// being mistaken for an orphaned directory and reclaimed out from under a session that is still
    /// coming up. One hour is far longer than any real creation takes while still bounding a truly
    /// orphaned directory's lifetime. This knob is consumed by the orphan sweep, not by
    /// `TerminalSessionGarbageCollector`; it lives here so every retention bound is authored in one
    /// place.
    public let orphanGracePeriod: TimeInterval

    /// The retention policy the daemon runs in production.
    public static let standard = TerminalSessionRetentionPolicy(
        endedSessionMaxAge: 7 * 86_400, endedTranscriptByteBudget: 2_000_000_000, orphanGracePeriod: 3_600)

    public init(endedSessionMaxAge: TimeInterval, endedTranscriptByteBudget: Int64, orphanGracePeriod: TimeInterval) {
        self.endedSessionMaxAge = endedSessionMaxAge
        self.endedTranscriptByteBudget = endedTranscriptByteBudget
        self.orphanGracePeriod = orphanGracePeriod
    }
}
