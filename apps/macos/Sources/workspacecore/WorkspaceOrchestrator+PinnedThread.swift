import Foundation
import spacesdevicecore
import spacesterminalcore

/// Pinned threads: named, resumable coding-agent conversations that stay under their workspace after the
/// agent stops.
///
/// Invariant: while a pin is attached to an agent row, that row's `user_label` equals the pin's `name`;
/// a not-running pin's `name` is its only copy. Every writer of that pair is in this file or is one of the
/// lifecycle hooks in `WorkspaceOrchestrator+Agent.swift` that call `detachPinnedThread(fromAgent:)`, and
/// each writes the pair inside one transaction.
extension WorkspaceOrchestrator {
    /// Pins the conversation an agent row is running under `name`, which becomes the row's name.
    ///
    /// A row whose agent has already exited (or whose terminal is gone) is pinned straight into the
    /// not-running state: the conversation is what the pin keeps, and the exited row returns to its default
    /// name. Eligibility is `SpacesDeviceAgentPinUnavailableReason.evaluate`, the rule the overview shows
    /// as a disabled menu item.
    public func pinAgentSession(workspaceID: String, agentID: String, name: String) throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw WorkspaceError.invalidArgument(message: "A pinned thread needs a name.") }
        try store.withTransaction {
            guard let existing = try store.agentWindow(id: agentID), existing.workspaceID == workspaceID else {
                throw WorkspaceError.invalidArgument(message: "No coding-agent session '\(agentID)' in workspace \(workspaceID).")
            }
            guard let conversation = try store.pinnableConversation(agentID: agentID) else {
                throw WorkspaceError.invalidArgument(message: "No coding-agent session '\(agentID)' in workspace \(workspaceID).")
            }
            let conversationIsPinned =
                try store.pinnedThread(attachedToAgentID: agentID) != nil
                || (try conversation.sessionKey.map { try store.pinnedThread(workspaceID: workspaceID, sessionKey: $0) != nil } ?? false)
            if let reason = SpacesDeviceAgentPinUnavailableReason.evaluate(
                sessionKey: conversation.sessionKey, relaunchCommand: conversation.launchCommand, conversationIsPinned: conversationIsPinned)
            {
                throw WorkspaceError.invalidArgument(message: "Cannot pin this agent: \(reason.message)")
            }
            // Eligibility guarantees all three: a resumable key needs a launch command, and a pin without a
            // directory could not be resumed.
            guard let sessionKey = conversation.sessionKey, let launchCommand = conversation.launchCommand,
                let workingDirectory = conversation.workingDirectory
            else {
                throw WorkspaceError.invalidArgument(
                    message: "Cannot pin this agent: \(SpacesDeviceAgentPinUnavailableReason.noConversation.message)")
            }
            try refuseNameOfClaimedTerminal(workspaceID: workspaceID, agent: existing, name: name)
            try validateWorkspaceFocusNames(
                workspaceID: workspaceID,
                agentWindows: try store.agentWindows(workspaceID: workspaceID).map { $0.id == existing.id ? $0.withUserLabel(name) : $0 })
            let pin = PinnedThreadRecord(
                id: UUID().uuidString, workspaceID: workspaceID, sessionKey: sessionKey, name: name, launchCommand: launchCommand,
                workingDirectory: workingDirectory, agentSessionID: existing.id, pinnedAt: nowISO8601())
            try store.insertPinnedThread(pin)
            try store.setAgentSessionUserLabel(id: existing.id, userLabel: name)
            if existing.status == .exited || !builtInAgentSessionIsStillLive(existing) {
                try detachPinnedThread(fromAgent: existing.withUserLabel(name))
            }
        }
    }

    /// Detaches the pin from the agent row running it, leaving the pin not running and the row an ordinary
    /// unpinned row under its default name ("-2" numbered when that is taken). Returns the row as stored
    /// afterwards, or `agent` itself when it holds no pin.
    ///
    /// The row's new name is computed before the pin is released, with nothing excluded: while the pin is
    /// attached its name is still held by the row, and computing after the release would see the pin as a
    /// not-running reservation of its own name. Writing first and computing second would instead fail
    /// validation on a temporary duplicate.
    @discardableResult func detachPinnedThread(fromAgent agent: AgentWindowRecord) throws -> AgentWindowRecord {
        try store.withTransaction {
            guard let pin = try store.pinnedThread(attachedToAgentID: agent.id) else { return agent }
            let label = try uniqueAgentFocusLabel(
                workspaceID: agent.workspaceID, preferredLabel: agent.label ?? Self.defaultAgentLabel, excludingAgentWindowID: nil)
            try store.setPinnedThreadAgent(id: pin.id, agentSessionID: nil)
            let reportedLabel = agent.label.map(normalizedFocusName)
            let userLabel = label.flatMap { normalizedFocusName($0) == reportedLabel ? nil : $0 }
            try store.setAgentSessionUserLabel(id: agent.id, userLabel: userLabel)
            return try store.agentWindow(id: agent.id) ?? agent
        }
    }

    /// The detach a lifecycle write owes when it would change the conversation `existing` is running: the
    /// pin stays on the conversation it was pinned with, so the terminal splits off as an ordinary row.
    /// `newKey` is the conversation id the write is about to store.
    func detachingPinnedThreadIfConversationChanges(_ existing: AgentWindowRecord, newKey: String?) throws -> AgentWindowRecord {
        guard newKey != existing.sessionKey else { return existing }
        return try detachPinnedThread(fromAgent: existing)
    }

    /// Attaches the pin that holds `sessionKey` to the agent row of a terminal that was just launched to
    /// resume that conversation, so the new row takes the pin's name and is the pin's running row. Called
    /// right after the launch wrote the row, inside the workspace lifecycle gate, which makes it cover
    /// every resume path: a pin's own resume, a standalone restore, and an automation restore.
    ///
    /// Nothing happens unless the row names the pin's conversation: a hook that reported a different
    /// conversation first wins over the one the launch asked for. A pin still attached to a dead row (one
    /// whose terminal ended but which has not been reaped yet) is released from it first.
    func attachPinnedThread(workspaceID: String, sessionKey: String, terminalSessionID: String) throws {
        try store.withTransaction {
            guard let row = try store.agentWindow(workspaceID: workspaceID, terminalTrackingID: terminalSessionID), row.sessionKey == sessionKey,
                let pin = try store.pinnedThread(workspaceID: workspaceID, sessionKey: sessionKey)
            else { return }
            if let attachedID = pin.agentSessionID {
                if attachedID == row.id { return }
                guard let attachedRow = try store.agentWindow(id: attachedID) else { return }
                if builtInAgentSessionIsStillLive(attachedRow) { return }
                // The dead row still carries the pin's name, so it gives it back before the new row takes it.
                try detachPinnedThread(fromAgent: attachedRow)
            }
            try store.setPinnedThreadAgent(id: pin.id, agentSessionID: row.id)
            // The pin is attached now, so its name is no longer a reservation and the row can take it. A
            // failure here is a broken invariant, not a user error: it throws and the launch is torn down.
            try validateWorkspaceFocusNames(
                workspaceID: workspaceID,
                agentWindows: try store.agentWindows(workspaceID: workspaceID).map { $0.id == row.id ? $0.withUserLabel(pin.name) : $0 })
            try store.setAgentSessionUserLabel(id: row.id, userLabel: pin.name)
        }
    }

    /// Resumes a not-running pin in a clean new terminal in its workspace, resuming the conversation with
    /// the agent's own resume command. A pin that already has a live row answers with that row's terminal
    /// instead of launching a second one. If the conversation no longer exists the agent's own error
    /// shows in the new terminal and the pin is kept.
    public func resumePinnedThread(workspaceID: String, pinID: String) throws -> PinnedThreadResumption {
        guard let pin = try store.pinnedThread(id: pinID), pin.workspaceID == workspaceID else {
            throw WorkspaceError.invalidArgument(message: "No pinned thread '\(pinID)' in workspace \(workspaceID).")
        }
        if let agentID = pin.agentSessionID, let row = try store.agentWindow(id: agentID), builtInAgentSessionIsStillLive(row),
            let sessionID = builtInAgentSessionID(for: row)
        {
            return PinnedThreadResumption(sessionID: sessionID, launchedSession: nil)
        }
        let session = try createWorkspaceAgentSession(
            workspaceID: workspaceID, command: CodingAgent.resumeCommand(launchCommand: pin.launchCommand, sessionKey: pin.sessionKey), title: nil,
            recordedLaunchCommand: pin.launchCommand, workingDirectory: pin.workingDirectory, resumedAgentSessionKey: pin.sessionKey)
        return PinnedThreadResumption(sessionID: session.id, launchedSession: session)
    }

    /// Removes a pin. A running pin's row keeps the pin's name, which is already its `user_label`; a
    /// not-running pin simply disappears.
    public func unpinThread(workspaceID: String, pinID: String) throws {
        try store.withTransaction {
            guard let pin = try store.pinnedThread(id: pinID), pin.workspaceID == workspaceID else {
                throw WorkspaceError.invalidArgument(message: "No pinned thread '\(pinID)' in workspace \(workspaceID).")
            }
            try store.deletePinnedThread(id: pin.id)
        }
    }

    /// Renames a pin, and its running row with it. An empty name is refused: unlike a coding-agent rename
    /// there is no reported name to fall back to.
    public func renamePinnedThread(workspaceID: String, pinID: String, name: String) throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw WorkspaceError.invalidArgument(message: "A pinned thread needs a name.") }
        try store.withTransaction {
            guard let pin = try store.pinnedThread(id: pinID), pin.workspaceID == workspaceID else {
                throw WorkspaceError.invalidArgument(message: "No pinned thread '\(pinID)' in workspace \(workspaceID).")
            }
            if let agentID = pin.agentSessionID {
                // An attached pin's name is carried by its row, so the candidate replaces the row's name.
                if let row = try store.agentWindow(id: agentID) { try refuseNameOfClaimedTerminal(workspaceID: workspaceID, agent: row, name: name) }
                try validateWorkspaceFocusNames(
                    workspaceID: workspaceID,
                    agentWindows: try store.agentWindows(workspaceID: workspaceID).map { $0.id == agentID ? $0.withUserLabel(name) : $0 })
                try store.setAgentSessionUserLabel(id: agentID, userLabel: name)
            } else {
                try validateWorkspaceFocusNames(
                    workspaceID: workspaceID,
                    pinnedThreads: try store.pinnedThreads(workspaceID: workspaceID).map { $0.id == pin.id ? $0.withName(name) : $0 })
            }
            try store.setPinnedThreadName(id: pin.id, name: name)
        }
    }

    /// Refuses a pin name equal to a name of the ad-hoc shell terminal the agent row claims. Full validation
    /// lets the claiming row share its terminal's names, but a pin detaches from the row later (agent exit or
    /// conversation change) and then the shell and the not-running pin would both hold the name.
    private func refuseNameOfClaimedTerminal(workspaceID: String, agent: AgentWindowRecord, name: String) throws {
        guard let sessionID = terminalTargetID(record: agent) else { return }
        let normalized = normalizedFocusName(name)
        guard try adHocTerminalNames(workspaceID: workspaceID, sessionID: sessionID).contains(where: { normalizedFocusName($0) == normalized }) else {
            return
        }
        throw WorkspaceError.invalidArgument(
            message: "Name '\(name)' is used by this agent's terminal. Choose a different name for the pinned thread.")
    }

    /// The names not-running pins hold. They are real rows in the sidebar, so every name check treats them
    /// as taken; a running pin's name is already its row's name.
    func notRunningPinnedThreadNames(workspaceID: String) throws -> [String] {
        try store.pinnedThreads(workspaceID: workspaceID).filter { $0.agentSessionID == nil }.compactMap { sanitizedFocusName($0.name) }
    }
}
