import Foundation
import spacesdevicecore
import spacesterminalcore

/// Turns a watched child agent's lifecycle transition into a multi-line notification block delivered into the
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

    /// Resolves the coding-agent kind label (claude/codex/opencode, or a launch title) for a local watched
    /// agent, used for the `(<kind>)` parenthetical. The daemon wires this to the same runtime-label
    /// resolution `agent list` uses; a `nil` result renders as `coding agent`. Defaults to `nil` so tests
    /// and non-daemon callers do not have to supply session-file access.
    public typealias ResolveAgentKind = (_ agent: AgentWindowRecord) -> String?

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
    private let resolveAgentKind: ResolveAgentKind
    private let logError: (String) -> Void
    private let now: () -> String

    public init(
        store: SQLiteStore, deliver: @escaping DeliverLine, resolveAgentKind: @escaping ResolveAgentKind = { _ in nil },
        logError: @escaping (String) -> Void = { FileHandle.standardError.write(Data($0.utf8)) },
        now: @escaping () -> String = { TerminalSessionTimestamp.string(from: Date()) }
    ) {
        self.store = store
        self.deliver = deliver
        self.resolveAgentKind = resolveAgentKind
        self.logError = logError
        self.now = now
    }

    /// A watched child agent transitioned to blocked/done/exited. For every subscriber of that agent,
    /// render one notification block and deliver it now if the subscriber is idle, else coalesce it into that
    /// subscriber's pending queue. For an `exited` child the caller MUST invoke this before deleting the
    /// agent row, since row deletion cascades the subscription edges away; the rendered pending line has
    /// no FK and survives that deletion.
    public func childDidTransition(agent: AgentWindowRecord, transition: ChildTransition) throws {
        let subscriptions = try store.agentSubscriptions(agentSessionID: agent.id)
        guard !subscriptions.isEmpty else { return }
        let line = try renderLine(agent: agent, transition: transition)
        for subscription in subscriptions {
            let subscriberID = subscription.subscriberTerminalSessionID
            try deliverOrQueue(subscriberTerminalSessionID: subscriberID, agentSessionID: agent.id, transition: transition, line: line) {
                try? self.store.deleteAgentSubscription(subscriberTerminalSessionID: subscriberID, agentSessionID: agent.id)
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
            try deliverOrQueue(subscriberTerminalSessionID: subscriberID, agentSessionID: terminalSessionID, transition: transition, line: line) {
                try? self.store.deleteAgentRemoteSubscription(
                    subscriberTerminalSessionID: subscriberID, deviceID: deviceID, agentSessionID: terminalSessionID)
            }
        }
    }

    /// Delivers a rendered line now when the subscriber is idle, otherwise coalesces it onto the
    /// subscriber's pending queue. On a failed immediate delivery the subscriber has vanished, so the
    /// caller-supplied `dropEdge` tears down the originating watch edge (local or cross-device). Shared by
    /// the local and remote transition paths so both gate and queue identically.
    private func deliverOrQueue(
        subscriberTerminalSessionID subscriberID: String, agentSessionID: String, transition: ChildTransition, line: String, dropEdge: () -> Void
    ) throws {
        if try subscriberIsIdle(terminalSessionID: subscriberID) {
            do { try deliver(subscriberID, line) } catch {
                logError(
                    "spaces: agent notification delivery failed subscriber=\(subscriberID) agent=\(agentSessionID) error=\(error.localizedDescription)\n")
                dropEdge()
            }
        } else {
            try store.upsertPendingAgentNotification(
                subscriberTerminalSessionID: subscriberID, agentSessionID: agentSessionID, transition: transition.word, message: line,
                createdAt: now())
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

    /// The single injected block for a local watched agent. Gathers the enriched context — project name,
    /// workspace directory path and branch, terminal session id, agent kind — from the store, then defers
    /// to the shared formatter; the deep link targets the local child's terminal session (no `?device=`).
    /// Reads the workspace and its project from the store, so it can throw. A workspace or project that no
    /// longer exists (deleted out from under a still-running agent) falls back to the id string for that
    /// field rather than failing delivery — a single clean path with no layered fallbacks. The `workspace`
    /// field is the workspace's full directory path (`dir`) so an orchestrator can locate the worktree.
    func renderLine(agent: AgentWindowRecord, transition: ChildTransition) throws -> String {
        let workspace = try store.workspace(id: agent.workspaceID)
        let project = try workspace.flatMap { try store.project(id: $0.projectID) }
        let kind = resolveAgentKind(agent) ?? "coding agent"
        return renderBlock(
            label: agent.label ?? kind, kind: kind, transition: transition,
            project: project?.name ?? workspace?.projectID ?? agent.workspaceID,
            workspace: workspace?.dir ?? agent.workspaceID,
            branch: workspace?.branch, sessionID: agent.terminalTrackingID ?? agent.id, note: agent.note, deviceID: nil)
    }

    /// The single injected block for a watched agent on a paired device. Reuses the shared format; the
    /// deep link is device-qualified (`?device=<id>`) and targets the remote child's terminal session
    /// (the watched key). Project/workspace/branch/label/note all come straight off the `listAgentSessions`
    /// row — the remote device already resolved them, so this path does no store lookups. The kind is the
    /// row's `agent` field (the remote daemon's resolved agent label), falling back to `coding agent`.
    func renderRemoteLine(terminalSessionID: String, row: SpacesDeviceAgentSessionRow, deviceID: String, transition: ChildTransition) -> String {
        let kind = row.agent ?? "coding agent"
        return renderBlock(
            label: row.label ?? kind, kind: kind, transition: transition, project: row.projectName,
            workspace: row.workspaceDir, branch: row.branch, sessionID: terminalSessionID, note: row.note, deviceID: deviceID)
    }

    /// The single injected block shared by the local and cross-device paths — a pure formatter over
    /// explicit fields, so both paths produce an identical shape. It is one multi-line string: a sentence
    /// first line (`[spaces] <label> (<kind>) is <word>`) followed by two-space-indented `key: value`
    /// continuation lines in the order project, workspace, branch, session, note, link. The `branch` line
    /// is omitted when the branch is empty/nil and the `note` line when the note is; the rest are always
    /// present so an orchestrating agent can parse fields rather than the deep link's URL. Multi-line YAML
    /// is markedly more readable in agent transcripts than a packed single line; the deep link stays
    /// clickable because Ghostty's URL matcher charset stops at end-of-line and excludes quotes, and the
    /// indented continuation lines — like the `[spaces]` first line, which never starts with `#`, `/`, or
    /// `!` — are safe from the slash/command syntax some agent TUIs apply to a leading character. The cost
    /// is that a plain-shell subscriber echoes one junk line per continuation, which is acceptable since
    /// subscribers are agent TUIs first. Values render verbatim: notes are stripped of control characters
    /// (including newlines) at annotate time and labels come from launch-config titles, so no continuation
    /// line can be forged and there is no second sanitization pass to add. `session` and the deep link
    /// both target the child's terminal session id.
    func renderBlock(
        label: String, kind: String, transition: ChildTransition, project: String, workspace: String, branch: String?, sessionID: String,
        note: String?, deviceID: String?
    ) -> String {
        let deepLink = SpacesTerminalDeepLink(sessionID: sessionID, deviceID: deviceID).absoluteString
        var lines = ["[spaces] \(label) (\(kind)) is \(transition.word)"]
        lines.append("  project: \(project)")
        lines.append("  workspace: \(workspace)")
        if let branch, !branch.isEmpty { lines.append("  branch: \(branch)") }
        lines.append("  session: \(sessionID)")
        if let note, !note.isEmpty { lines.append("  note: \(note)") }
        lines.append("  link: \(deepLink)")
        return lines.joined(separator: "\n")
    }
}
