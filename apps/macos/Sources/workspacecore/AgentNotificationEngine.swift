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
            try deliverOrQueue(subscriberTerminalSessionID: subscriberID, agentSessionID: agent.id, line: line) {
                try? self.store.deleteAgentSubscription(subscriberTerminalSessionID: subscriberID, agentSessionID: agent.id)
            }
        }
    }

    /// A watched coding-agent session on the paired device `deviceID` transitioned to blocked/done/exited,
    /// as observed by the remote watch service diffing successive `listAgentSessions` snapshots. Shares
    /// the exact idle-gating, queueing, and render logic with the local `childDidTransition` — the only
    /// differences are that subscribers come from the cross-device edge table and the deep link is
    /// device-qualified (`?device=<id>`). The watch edge keys on the child's terminal session id, which
    /// also targets the deep link. For an `exited` transition the caller drops the edges after this
    /// returns; the rendered pending line (no FK) survives that, matching the local exit path.
    public func remoteChildDidTransition(
        deviceID: String, terminalSessionID: String, row: SpacesDeviceAgentSessionRow, transition: ChildTransition
    ) throws {
        let subscribers = try store.agentRemoteSubscribers(deviceID: deviceID, agentSessionID: terminalSessionID)
        guard !subscribers.isEmpty else { return }
        let line = renderRemoteLine(terminalSessionID: terminalSessionID, row: row, deviceID: deviceID, transition: transition)
        for subscriberID in subscribers {
            try deliverOrQueue(subscriberTerminalSessionID: subscriberID, agentSessionID: terminalSessionID, line: line) {
                try? self.store.deleteAgentRemoteSubscription(
                    subscriberTerminalSessionID: subscriberID, deviceID: deviceID, agentSessionID: terminalSessionID)
            }
        }
    }

    /// Delivers a rendered line now when the subscriber is idle, otherwise coalesces it onto the
    /// subscriber's pending queue. On a failed immediate delivery the subscriber has vanished, so the
    /// caller-supplied `dropEdge` tears down the originating watch edge (local or cross-device). Shared by
    /// the local and remote transition paths so both gate and queue identically.
    private func deliverOrQueue(subscriberTerminalSessionID subscriberID: String, agentSessionID: String, line: String, dropEdge: () -> Void) throws {
        if try subscriberIsIdle(terminalSessionID: subscriberID) {
            do { try deliver(subscriberID, line) } catch {
                logError(
                    "spaces: agent notification delivery failed subscriber=\(subscriberID) agent=\(agentSessionID) error=\(error.localizedDescription)\n")
                dropEdge()
            }
        } else {
            try store.upsertPendingAgentNotification(
                subscriberTerminalSessionID: subscriberID, agentSessionID: agentSessionID, message: line, createdAt: now())
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

    /// Flush-path delivery: delivers a queued line, logging and dropping the same-device subscription edge
    /// on failure. Returns whether delivery succeeded; the pending row itself is deleted by the caller
    /// regardless. A failed delivery means the subscriber session is gone. A flushed row may have a
    /// cross-device origin (its `agentSessionID` is then a remote child's terminal session id); dropping a
    /// local edge for it is a harmless no-op, and the remote edge is torn down by the watch service on its
    /// next failed delivery — the flush path has no `deviceID` to identify the remote edge here.
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

    /// The single injected line for a local watched agent. See `renderLine(label:provider:note:...)` for
    /// the shared format; the deep link targets the local child's terminal session (no `?device=`).
    func renderLine(agent: AgentWindowRecord, transition: ChildTransition) -> String {
        renderLine(
            label: agent.label ?? agent.provider.rawValue, provider: agent.provider.rawValue, note: agent.note,
            deepLinkSessionID: agent.terminalTrackingID ?? agent.id, deviceID: nil, transition: transition)
    }

    /// The single injected line for a watched agent on a paired device. Reuses the shared format; the
    /// deep link is device-qualified (`?device=<id>`) and targets the remote child's terminal session
    /// (the watched key), and label/note come straight off the `listAgentSessions` row. The provider
    /// parenthetical is `spaces`: `listAgentSessions` only ever returns Spaces-provider coding-agent rows.
    func renderRemoteLine(terminalSessionID: String, row: SpacesDeviceAgentSessionRow, deviceID: String, transition: ChildTransition) -> String {
        renderLine(
            label: row.label ?? row.agent ?? "coding agent", provider: "spaces", note: row.note, deepLinkSessionID: terminalSessionID, deviceID: deviceID,
            transition: transition)
    }

    /// The single injected line shared by the local and cross-device paths. The `[spaces]` prefix
    /// guarantees the line never starts with `#`, `/`, or `!` (leading characters some agent TUIs treat as
    /// slash/command syntax). The note and label are rendered verbatim: notes are already stripped of
    /// control characters at annotate time and labels come from launch-config titles, so there is no
    /// second sanitization pass to add. The deep link lets a human jump straight to the child's pane.
    func renderLine(label: String, provider: String, note: String?, deepLinkSessionID: String, deviceID: String?, transition: ChildTransition)
        -> String
    {
        let deepLink = SpacesTerminalDeepLink(sessionID: deepLinkSessionID, deviceID: deviceID).absoluteString
        var line = "[spaces] \(label) (\(provider)) is \(transition.word)"
        if let note, !note.isEmpty { line += " — note: \(note)" }
        line += " — open: \(deepLink)"
        return line
    }
}
