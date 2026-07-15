import Foundation
import spacesdevicecore
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
    /// render one line and deliver it now if the subscriber is idle, else coalesce it into that
    /// subscriber's pending queue. For an `exited` child the caller MUST invoke this before deleting the
    /// agent row, since row deletion cascades the subscription edges away; the rendered pending line has
    /// no FK and survives that deletion.
    public func childDidTransition(agent: AgentWindowRecord, transition: ChildTransition) throws {
        let subscriptions = try store.agentSubscriptions(agentSessionID: agent.id)
        guard !subscriptions.isEmpty else { return }
        let line = renderLine(agent: agent, transition: transition)
        for subscription in subscriptions {
            let subscriberID = subscription.subscriberTerminalSessionID
            if try subscriberIsIdle(terminalSessionID: subscriberID) {
                _ = attemptDelivery(subscriberTerminalSessionID: subscriberID, agentSessionID: agent.id, line: line)
            } else {
                try store.upsertPendingAgentNotification(
                    subscriberTerminalSessionID: subscriberID, agentSessionID: agent.id, message: line, createdAt: now())
            }
        }
    }

    /// A subscriber terminal became idle (or exited). Flush its queued notifications in enqueue order,
    /// delivering each once. Every flushed row is removed whether delivery succeeds (delivered-once) or
    /// fails (the subscriber vanished — the edge is dropped too), so a subscriber never re-receives a
    /// line and a dead one never accumulates undeliverable state.
    public func subscriberDidBecomeIdle(subscriberTerminalSessionID: String) throws {
        for pending in try store.pendingAgentNotifications(subscriberTerminalSessionID: subscriberTerminalSessionID) {
            _ = attemptDelivery(
                subscriberTerminalSessionID: subscriberTerminalSessionID, agentSessionID: pending.agentSessionID, line: pending.message)
            try store.deletePendingAgentNotification(id: pending.id)
        }
    }

    /// A subscriber is idle when its own agent row is idle/done, or when it has no agent row at all (a
    /// plain shell terminal is always ready to receive). A spinning or waiting agent is busy: queue.
    private func subscriberIsIdle(terminalSessionID: String) throws -> Bool {
        guard let agent = try store.agentWindowByTerminalSession(terminalSessionID: terminalSessionID) else { return true }
        switch agent.status {
        case .idle, .done: return true
        case .spinning, .waiting: return false
        }
    }

    /// Delivers a line, dropping the subscription edge and logging on failure. Returns whether delivery
    /// succeeded. A failed delivery means the subscriber session is gone, so the watch edge is torn down
    /// — the queued pending row (if any) is dropped separately by the caller.
    @discardableResult private func attemptDelivery(subscriberTerminalSessionID: String, agentSessionID: String, line: String) -> Bool {
        do {
            try deliver(subscriberTerminalSessionID, line)
            return true
        } catch {
            logError(
                "spaces: agent notification delivery failed subscriber=\(subscriberTerminalSessionID) agent=\(agentSessionID) error=\(error.localizedDescription)\n"
            )
            try? store.deleteAgentSubscription(subscriberTerminalSessionID: subscriberTerminalSessionID, agentSessionID: agentSessionID)
            return false
        }
    }

    /// The single injected line. The `[spaces]` prefix guarantees the line never starts with `#`, `/`,
    /// or `!` (leading characters some agent TUIs treat as slash/command syntax). The note and label are
    /// rendered verbatim: notes are already stripped of control characters at annotate time, and labels
    /// come from launch-config titles, so there is no second sanitization pass to add. The deep link
    /// targets the child's terminal session so a human can jump straight to its pane.
    func renderLine(agent: AgentWindowRecord, transition: ChildTransition) -> String {
        let label = agent.label ?? agent.provider.rawValue
        let deepLinkSessionID = agent.terminalTrackingID ?? agent.id
        let deepLink = SpacesTerminalDeepLink(sessionID: deepLinkSessionID).absoluteString
        var line = "[spaces] \(label) (\(agent.provider.rawValue)) is \(transition.word)"
        if let note = agent.note, !note.isEmpty { line += " — note: \(note)" }
        line += " — open: \(deepLink)"
        return line
    }
}
