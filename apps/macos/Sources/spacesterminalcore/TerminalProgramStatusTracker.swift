import Foundation

/// The state of one OSC 7501 report. Raw values are libghostty-vt's `GhosttyProgramStatusState`, which
/// is also the order of the Ghostty fork's `GHOSTTY_PROGRAM_STATUS_STATE_*` action enum, so both
/// terminal engines hand the same numbers to one tracker.
public enum TerminalProgramStatusState: UInt32, Sendable, Equatable {
    case idle = 0
    case working = 1
    case done = 2
    case blocked = 3
    case error = 4
    case clear = 5
}

/// The agent status change a run of reports amounts to.
public enum TerminalProgramStatusTransition: Sendable, Equatable {
    case working
    case blocked
    case done
}

/// Folds one terminal's OSC 7501 reports into the agent status change they imply.
///
/// A program may report several records at once, each under its own id (empty for the program itself,
/// `a/b` for a child of `a`), so a single report says little: one record finishing while another keeps
/// working must not read as the agent being done. The tracker therefore keeps the latest activity per
/// id and reports only changes of the aggregate: blocked when any record is blocked, else working when
/// any is working, else inactive. `idle`, `done`, and `error` all mean the record is no longer active.
///
/// Leaving inactive for an active aggregate is `working` or `blocked`, and leaving an active aggregate
/// for inactive is `done`, however it got there (a report, a clear, or an eviction). Inactive to
/// inactive is nothing, so an agent announcing itself with `idle` does not look like a finished turn.
/// `kind`, `msg`, `title`, and `progress` carry nothing Spaces acts on and never reach this type.
public struct TerminalProgramStatusTracker: Sendable, Equatable {
    /// Bounds the table against a program minting unbounded ids. Past it the least recently updated
    /// record is dropped, which at worst makes a long-quiet record forget it was working.
    public static let maximumRecordCount = 256

    private enum Activity: Equatable {
        case inactive
        case working
        case blocked
    }

    private struct Record: Equatable {
        var activity: Activity
        var updateOrder: UInt64
    }

    private var records: [String: Record] = [:]
    private var nextUpdateOrder: UInt64 = 0

    public init() {}

    public var recordCount: Int { records.count }

    /// Applies one report and returns the agent status change it caused, or nil when the aggregate did
    /// not move between inactive, working, and blocked.
    public mutating func apply(state: TerminalProgramStatusState, id: String) -> TerminalProgramStatusTransition? {
        let before = aggregate()
        switch state {
        case .clear:
            clear(id: id)
        case .idle, .done, .error:
            record(.inactive, id: id)
        case .working:
            record(.working, id: id)
        case .blocked:
            record(.blocked, id: id)
        }
        let after = aggregate()
        guard after != before else { return nil }
        switch after {
        case .blocked: return .blocked
        case .working: return .working
        case .inactive: return .done
        }
    }

    /// Forgets every record without reporting anything: the agent they described is gone, so there is
    /// no status left to settle.
    public mutating func reset() {
        records.removeAll()
    }

    private func aggregate() -> Activity {
        var result = Activity.inactive
        for record in records.values {
            if record.activity == .blocked { return .blocked }
            if record.activity == .working { result = .working }
        }
        return result
    }

    private mutating func record(_ activity: Activity, id: String) {
        if records[id] == nil, records.count >= Self.maximumRecordCount {
            if let oldest = records.min(by: { $0.value.updateOrder < $1.value.updateOrder })?.key { records.removeValue(forKey: oldest) }
        }
        records[id] = Record(activity: activity, updateOrder: nextUpdateOrder)
        nextUpdateOrder &+= 1
    }

    /// A clear removes the record with this id and everything beneath it; the empty id is the root, so
    /// it removes everything.
    private mutating func clear(id: String) {
        guard !id.isEmpty else {
            records.removeAll()
            return
        }
        let childPrefix = id + "/"
        records = records.filter { $0.key != id && !$0.key.hasPrefix(childPrefix) }
    }
}
