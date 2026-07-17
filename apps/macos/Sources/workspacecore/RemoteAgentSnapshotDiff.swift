import spacesdevicecore

/// Pure, testable diff over successive `listAgentSessions` snapshots for one paired device. The remote
/// watch service feeds it the previous snapshot (watched terminal session id → last-seen row), the fresh
/// rows, and the set of currently-watched child terminal session ids; it returns the lifecycle
/// transitions to deliver plus the next snapshot to remember. Watches key on the child's terminal session
/// id — the stable cross-device handle the user addresses and the deep link targets — so a row is watched
/// when its `terminalSessionID` is in `watchedTerminalSessionIDs`.
///
/// Emission is gated per-agent on having a prior observation of that agent, which gives two properties
/// for free:
///  - a device's very first snapshot (empty `previous`) emits nothing and only seeds a baseline, while a
///    reconnect diffs against the retained baseline — so a dropped-then-restored stream never replays
///    the state it already reported, yet still emits every transition from the outage window;
///  - a newly-watched agent with no prior observation seeds silently rather than replaying the state it
///    was already in. The daemon's subscribe path pre-populates that prior observation with the row its
///    validation fetched (`RemoteAgentWatchService.seedBaseline`), so a first listing that arrives already
///    changed — or with the child gone — is diffed against the seed and its transition (or exit) is
///    surfaced; only a subscribe whose validation row could not be seeded falls back to seeding silently.
///
/// Transitions: a status change to `waiting` is `blocked`, to `done` is `done`, and `waiting` →
/// `spinning` is `resumedWorking` — the child resumed after an approval, which never notifies but
/// withdraws that child's held `blocked` line. Exit has two observable shapes, both mapped to `exited`:
/// a status change to `exited` (the child process ended but its terminal survived, so the row remains)
/// and a previously-seen watched agent that is absent from the new listing (the terminal is gone). A
/// `waiting` → `exited` change delivers `exited`; the engine's per-(subscriber, agent) pending-queue
/// upsert then replaces any held `blocked` line, so no stale "is blocked" notice outlives the exit.
public enum RemoteAgentSnapshotDiff {
    public enum TransitionKind: Equatable {
        case blocked
        case done
        case exited
        case resumedWorking

        /// The notifying transition this kind delivers, or `nil` for `resumedWorking`, whose only
        /// effect is the engine's held-blocked-line withdrawal.
        public var childTransition: AgentNotificationEngine.ChildTransition? {
            switch self {
            case .blocked: .blocked
            case .done: .done
            case .exited: .exited
            case .resumedWorking: nil
            }
        }
    }

    public struct Transition: Equatable {
        /// The watched child's terminal session id (the edge key), which also targets the deep link.
        public let terminalSessionID: String
        public let kind: TransitionKind
        /// The row the notification renders from. For `exited` this is the last-seen row (the agent is
        /// absent from the new listing), so its label/note survive the disappearance.
        public let row: SpacesDeviceAgentSessionRow

        public init(terminalSessionID: String, kind: TransitionKind, row: SpacesDeviceAgentSessionRow) {
            self.terminalSessionID = terminalSessionID
            self.kind = kind
            self.row = row
        }
    }

    public static func diff(
        previous: [String: SpacesDeviceAgentSessionRow], newRows: [SpacesDeviceAgentSessionRow], watchedTerminalSessionIDs: Set<String>
    ) -> (transitions: [Transition], snapshot: [String: SpacesDeviceAgentSessionRow]) {
        let newByTerminal = Dictionary(
            newRows.compactMap { row in row.terminalSessionID.flatMap { watchedTerminalSessionIDs.contains($0) ? ($0, row) : nil } },
            uniquingKeysWith: { first, _ in first })
        var transitions: [Transition] = []
        var snapshot: [String: SpacesDeviceAgentSessionRow] = [:]
        // Sorted iteration keeps transition (and therefore delivery) order deterministic.
        for terminalSessionID in watchedTerminalSessionIDs.sorted() {
            let prev = previous[terminalSessionID]
            if let new = newByTerminal[terminalSessionID] {
                snapshot[terminalSessionID] = new
                guard let prev else { continue }  // first observation of this agent: seed silently
                if let kind = statusTransition(from: prev.status, to: new.status) {
                    transitions.append(Transition(terminalSessionID: terminalSessionID, kind: kind, row: new))
                }
            } else if let prev {
                // Previously observed, now gone from the listing: the agent exited. Render from the
                // last-seen row and leave it out of the next snapshot — the caller drops the edge.
                transitions.append(Transition(terminalSessionID: terminalSessionID, kind: .exited, row: prev))
            }
        }
        return (transitions, snapshot)
    }

    /// A status transition worth acting on. `working`/`idle` targets never notify, and an unchanged
    /// status never re-emits (so a child that stays `waiting` across pushes yields one `blocked` line).
    /// The one working target that matters is `waiting` → `spinning`: the child resumed after an
    /// approval, which must withdraw its held `blocked` line even though it delivers nothing.
    private static func statusTransition(from previous: String, to current: String) -> TransitionKind? {
        guard previous != current else { return nil }
        switch current {
        case AgentWindowStatus.waiting.rawValue: return .blocked
        case AgentWindowStatus.done.rawValue: return .done
        case AgentWindowStatus.exited.rawValue: return .exited
        case AgentWindowStatus.spinning.rawValue: return previous == AgentWindowStatus.waiting.rawValue ? .resumedWorking : nil
        default: return nil
        }
    }
}
