import Foundation
import spacesterminalcore

/// Turns a watched child agent's lifecycle transition into a one-line notification delivered into the
/// subscribing terminal — immediately when that subscriber is idle, or queued and flushed the moment it
/// next goes idle. Pure logic over the store plus an injected delivery closure, so the daemon wires it
/// to the real terminal-send path and tests drive it with a recorder.
///
/// Construct one per signal at the daemon chokepoint (`recordProfileAgentSignal`) and discard it; it
/// holds no state of its own.
public struct AgentNotificationEngine {
    /// Delivers a rendered line into a terminal session. Throwing signals an undeliverable subscriber
    /// (a dead/absent session), which the engine treats as the subscriber having vanished.
    public typealias DeliverLine = (_ subscriberTerminalSessionID: String, _ line: String) throws -> Void

    /// The lifecycle transitions that produce a notification. `working`/`init` never do.
    public enum ChildTransition: Sendable {
        case blocked
        case done
        case exited

        /// The verb rendered into the line. Exit reads as `exited` (past tense) because the agent is gone.
        var word: String {
            switch self {
            case .blocked: "blocked"
            case .done: "done"
            case .exited: "exited"
            }
        }
    }

    private let store: SQLiteStore
    private let deliver: DeliverLine
    private let logError: (String) -> Void
    private let now: () -> String

    public init(
        store: SQLiteStore, deliver: @escaping DeliverLine, logError: @escaping (String) -> Void = { FileHandle.standardError.write(Data($0.utf8)) },
        now: @escaping () -> String = { TerminalSessionTimestamp.string(from: Date()) }
    ) {
        self.store = store
        self.deliver = deliver
        self.logError = logError
        self.now = now
    }

    /// A watched child agent transitioned to blocked/done/exited. For every subscriber of that agent,
    /// render one notification line and deliver it now if the subscriber is idle, else coalesce it into that
    /// subscriber's pending queue. The local `exited` transition does NOT come through here: an exit is
    /// enqueued inside the finalization claim and delivered by `deliverClaimedExitNotices`, because the
    /// exit's queue rows must exist before any other termination path can see the row as finalized and
    /// drop its subscription edges. Everything else — including a paired device's watched child exiting,
    /// whose edges no local termination touches — renders and queues here.
    public func childDidTransition(agent: AgentWindowRecord, transition: ChildTransition) throws {
        let subscriptions = try store.agentSubscriptions(agentSessionID: agent.id)
        guard !subscriptions.isEmpty else { return }
        let line = renderLine(agent: agent, transition: transition)
        for subscription in subscriptions {
            try deliverOrQueue(
                subscriberTerminalSessionID: subscription.subscriberTerminalSessionID, agentSessionID: agent.id, transition: transition, line: line)
        }
    }

    /// Delivers the `exited` notices that the finalization claim already queued for a watched child's
    /// subscribers (`SQLiteStore.claimAgentSessionExitEvent`). Exit is the one transition whose notice is
    /// enqueued before it is delivered rather than the other way round: the claim commits the queue rows
    /// in the same transaction as the `exit` event, so the obligation is durable from the instant any
    /// other path can observe the row as finalized and start tearing its subscription edges down. This
    /// pass therefore only decides WHEN each queued row lands — immediately for an idle subscriber, or
    /// left queued for a busy subscriber's next idle flush, the same gate `deliverOrQueue` applies to
    /// every other transition. The listing read below is only a set of candidates: the row is taken out
    /// of the queue by `claimPendingAgentNotification` (see its consume invariant) BEFORE it is
    /// delivered, so a concurrent idle flush racing this pass for the same row gets nil and delivers
    /// nothing. A failed delivery means that subscriber terminal is gone, handled by `subscriberDidExit`
    /// exactly as on the other delivery paths; the row is already out of the queue, and that teardown
    /// discards the subscriber's remaining queue too.
    public func deliverClaimedExitNotices(agentSessionID: String) throws {
        for queued in try store.pendingAgentNotifications(agentSessionID: agentSessionID) {
            guard try subscriberIsIdle(terminalSessionID: queued.subscriberTerminalSessionID) else { continue }
            guard let claimed = try store.claimPendingAgentNotification(id: queued.id) else { continue }
            if !attemptDelivery(
                subscriberTerminalSessionID: claimed.subscriberTerminalSessionID, agentSessionID: agentSessionID, line: claimed.message)
            {
                try? subscriberDidExit(subscriberTerminalSessionID: claimed.subscriberTerminalSessionID)
            }
        }
    }

    /// A watched child resumed working after being blocked (the daemon chokepoint calls this on a real
    /// blocked→working transition, and the remote watch on a waiting→spinning diff). The resume itself
    /// never notifies, but any HELD pending line still rendering `blocked` for this child is withdrawn —
    /// an "is blocked" notice delivered after the child resumed is misinformation. Held `done`/`exited`
    /// lines are terminal facts and stay. `agentSessionID` is the same key the queue rows carry: the
    /// local agent row id, or the child's terminal session id for a cross-device watch.
    public func childDidResumeWorking(agentSessionID: String) throws {
        try store.deletePendingAgentNotifications(agentSessionID: agentSessionID, transition: ChildTransition.blocked.word)
    }

    /// A watched coding-agent session on the paired device `deviceID` transitioned to blocked/done/exited,
    /// as observed by the remote watch service diffing successive `listAgentSessions` snapshots. Shares
    /// the exact idle-gating, queueing, and render logic with the local `childDidTransition` — the only
    /// differences are that subscribers come from the cross-device edge table and the line names the
    /// device. The watch edge keys on the child's terminal session id, which is also the id the line
    /// names. For an `exited` transition the caller drops the edges after this returns; the rendered
    /// pending line (no FK) survives that, matching the local exit path.
    public func remoteChildDidTransition(deviceID: String, terminalSessionID: String, transition: ChildTransition) throws {
        let subscribers = try store.agentRemoteSubscribers(deviceID: deviceID, agentSessionID: terminalSessionID)
        guard !subscribers.isEmpty else { return }
        let line = renderRemoteLine(terminalSessionID: terminalSessionID, deviceID: deviceID, transition: transition)
        for subscriberID in subscribers {
            try deliverOrQueue(subscriberTerminalSessionID: subscriberID, agentSessionID: terminalSessionID, transition: transition, line: line)
        }
    }

    /// Delivers a rendered line now when the subscriber is idle, otherwise coalesces it onto the
    /// subscriber's pending queue. On a failed immediate delivery the subscriber terminal is dead — the
    /// same fact `subscriberDidExit` is built to handle — so the failure is treated as that subscriber
    /// having exited: every trace of it as a subscriber (queued inbound lines, and every OUTGOING local
    /// and cross-device watch edge it holds, not just the one that just failed) is torn down in one call,
    /// matching the exit path exactly. The teardown is best-effort (`try?`): a store error while cleaning
    /// up a dead subscriber must not abort delivery to this child's OTHER subscribers still left in the
    /// caller's loop. Shared by the local and remote transition paths so both gate and queue identically.
    private func deliverOrQueue(subscriberTerminalSessionID subscriberID: String, agentSessionID: String, transition: ChildTransition, line: String)
        throws
    {
        if try subscriberIsIdle(terminalSessionID: subscriberID) {
            do { try deliver(subscriberID, line) } catch {
                logError(
                    "spaces: agent notification delivery failed subscriber=\(subscriberID) agent=\(agentSessionID) error=\(error.localizedDescription)\n"
                )
                try? subscriberDidExit(subscriberTerminalSessionID: subscriberID)
            }
        } else {
            try store.upsertPendingAgentNotification(
                subscriberTerminalSessionID: subscriberID, agentSessionID: agentSessionID, transition: transition.word, message: line,
                createdAt: now())
        }
    }

    /// A subscriber terminal became idle (or exited). Flush its queued notifications in enqueue order,
    /// delivering each once: the listing read is only a set of candidates, and each row is taken out of
    /// the queue by `claimPendingAgentNotification` (see its consume invariant) before it is delivered, so
    /// a row another drain took meanwhile is skipped rather than delivered a second time. The first
    /// delivery failure means the subscriber terminal is dead, not just that one queued row: the loop
    /// stops right there and hands off to `subscriberDidExit`, which purges every still-pending row for
    /// this subscriber and tears down every outgoing watch edge it holds, so a dead subscriber never
    /// accumulates undeliverable state on a later child transition either.
    public func subscriberDidBecomeIdle(subscriberTerminalSessionID: String) throws {
        for queued in try store.pendingAgentNotifications(subscriberTerminalSessionID: subscriberTerminalSessionID) {
            guard let claimed = try store.claimPendingAgentNotification(id: queued.id) else { continue }
            guard
                attemptDelivery(
                    subscriberTerminalSessionID: subscriberTerminalSessionID, agentSessionID: claimed.agentSessionID, line: claimed.message)
            else {
                try? subscriberDidExit(subscriberTerminalSessionID: subscriberTerminalSessionID)
                return
            }
        }
    }

    /// A subscriber terminal has permanently exited — its own agent exited and the terminal reverted to
    /// a bare shell, or the terminal itself was destroyed — and can never again be a valid delivery
    /// target under this session id. Tears down every trace of it as a subscriber:
    ///  - its queued INBOUND notifications, dropped rather than flushed: `subscriberDidBecomeIdle` would
    ///    submit these child-event lines into the shell prompt, which is corruption on the exit path; and
    ///  - every OUTGOING watch edge it holds, both same-device (`agent_subscriptions`) and cross-device
    ///    (`agent_remote_subscriptions`). Neither table has a foreign key on the subscriber column (only
    ///    `agent_subscriptions` has one, and only on the watched agent), so an exiting subscriber's own
    ///    watches of OTHER agents would otherwise survive forever: every later transition of a still-live
    ///    watched agent would keep re-queuing an undeliverable pending row for this dead subscriber, and
    ///    for a remote edge the paired device's overview stream would stay open with no edge that can
    ///    ever deliver.
    /// Deleting the edges is a plain store write like any other, so it fires the same `databaseDidChange`
    /// signal every mutation does; the daemon's `RemoteAgentWatchService.reconcile()` is driven off that
    /// signal, so a device whose last edge just vanished has its stream closed without this method
    /// needing to reach into daemon-only state.
    public func subscriberDidExit(subscriberTerminalSessionID: String) throws {
        try store.deletePendingAgentNotifications(subscriberTerminalSessionID: subscriberTerminalSessionID)
        try store.deleteAgentSubscriptions(subscriberTerminalSessionID: subscriberTerminalSessionID)
        try store.deleteAgentRemoteSubscriptions(subscriberTerminalSessionID: subscriberTerminalSessionID)
    }

    /// A subscriber is idle when its own agent row leaves it idle (idle/done — see
    /// `AgentWindowStatus.leavesSubscriberIdle`), or when it has no agent row at all (a plain shell
    /// terminal is always ready to receive). A spinning, waiting, or exited agent is not ready: queue.
    private func subscriberIsIdle(terminalSessionID: String) throws -> Bool {
        guard let agent = try store.agentWindowByTerminalSession(terminalSessionID: terminalSessionID) else { return true }
        return agent.status.leavesSubscriberIdle
    }

    /// Flush-path delivery: attempts one queued line and reports whether it landed, logging on failure.
    /// Does no store mutation itself — the caller (`subscriberDidBecomeIdle`) owns cleanup, deleting just
    /// this row on success or tearing down the whole subscriber via `subscriberDidExit` on failure, since a
    /// failed delivery means the subscriber terminal itself is gone, not just this one row.
    private func attemptDelivery(subscriberTerminalSessionID: String, agentSessionID: String, line: String) -> Bool {
        do {
            try deliver(subscriberTerminalSessionID, line)
            return true
        } catch {
            logError(
                "spaces: agent notification delivery failed subscriber=\(subscriberTerminalSessionID) agent=\(agentSessionID) error=\(error.localizedDescription)\n"
            )
            return false
        }
    }

    /// The line for a local watched agent, naming the child by its terminal session id: the id every
    /// orchestration tool takes, so the subscriber can act on the child without parsing anything else.
    func renderLine(agent: AgentWindowRecord, transition: ChildTransition) -> String {
        Self.line(sessionID: agent.terminalTrackingID ?? agent.id, deviceID: nil, transition: transition)
    }

    /// The line for a watched agent on a paired device. `deviceID` is the paired-device record id this
    /// machine knows the device by, the same id `--device` and the MCP `device` argument accept.
    func renderRemoteLine(terminalSessionID: String, deviceID: String, transition: ChildTransition) -> String {
        Self.line(sessionID: terminalSessionID, deviceID: deviceID, transition: transition)
    }

    /// `[spaces] <session-id> is <state>`, or `[spaces] <session-id> on <device-id> is <state>` for a
    /// child on a paired device. One line carrying only generated ids: everything else about the child
    /// (label, kind, workspace, brief) is one `spaces_agent_status` call away, and leaving it out keeps
    /// the notice cheap in the subscriber's context. Because neither id is free text, a plain-shell
    /// subscriber that executes the submitted line runs nothing an agent chose, and the leading `[`
    /// is not command syntax in any supported agent TUI (unlike `/`, `!`, or `#`).
    static func line(sessionID: String, deviceID: String?, transition: ChildTransition) -> String {
        guard let deviceID else { return "[spaces] \(sessionID) is \(transition.word)" }
        return "[spaces] \(sessionID) on \(deviceID) is \(transition.word)"
    }
}
