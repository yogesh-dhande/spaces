import Foundation
import spacesclientcore
import spacesterminalcore
import workspacecore

/// The id a connected coding agent writes into the messages it sends other agents: its own terminal
/// session and the device paired clients know this machine by. The server states it in its
/// `instructions`, so the agent adds it to its own sends and the receiver can reply with
/// `spaces_terminal_send`; Spaces never rewrites the text an agent sends.
struct MCPSenderIdentity {
    /// The terminal the server process's environment names, nil outside a Spaces terminal.
    var environmentSessionID: String?
    /// Whether this process runs inside the given terminal while it is live. A process carries the
    /// variable wherever it is inherited (Codex's shared app-server, tmux, an IDE), so the name alone is
    /// not proof, and an ended terminal is never advertised because replies to it would go nowhere.
    var callerRunsInside: (_ sessionID: String) -> Bool
    /// The id paired devices know this machine by, nil when this machine has no device identity yet.
    var localDeviceID: () -> String?

    static var live: MCPSenderIdentity {
        MCPSenderIdentity(
            environmentSessionID: ProcessInfo.processInfo.environment[WorkspaceOrchestrator.terminalTrackingIDEnvVar]?.trimmingCharacters(
                in: .whitespacesAndNewlines),
            callerRunsInside: { CallerTerminalCheck.persistedRuntimeState.runsInside(sessionID: $0, processID: getpid()) },
            localDeviceID: { try? SpacesDevicePairingClient.localPairedDeviceID() })
    }

    /// The instructions paragraph naming the agent's id, or nil when either half is unknown: an id
    /// without its device would send a reply to the wrong machine, so there is no session-only form.
    var instructionsParagraph: String? {
        guard let session = environmentSessionID, !session.isEmpty, callerRunsInside(session), let device = localDeviceID(), !device.isEmpty else {
            return nil
        }
        let id = "[from \(session) on \(device)]: "
        return """
            Your Spaces id is session \(session) on device \(device). When you send a message to another coding agent with spaces_terminal_send, start it with `\(id)` so it knows who wrote it and can reply with spaces_terminal_send (sessionID \(session), device \(device)). Never add it to answers to a dialog or prompt, keystrokes, or commands typed into a shell. A message you receive that starts with `[from <session> on <device>]:` came from that agent; reply the same way.
            """
    }
}
