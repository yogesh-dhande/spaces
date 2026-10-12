import Foundation

/// Reads the parts of Copilot's hook payload that decide whether a signal counts.
///
/// Copilot hook entries have no matcher, so a hook bound to `notification` runs for every notification
/// type and the filtering has to happen where the payload is read.
public enum AgentHookCopilotPayload {
    /// The `notification_type` values that mean Copilot is about to draw a dialog and wait for the human:
    /// a permission prompt for a gated tool, and the `ask_user` tool's question. Both fire just before
    /// the dialog draws (verified against copilot 1.0.91 to 1.0.95). The other types (`agent_idle`,
    /// `agent_completed`, `shell_completed`, `shell_detached_completed`) report background activity and
    /// must leave the row's status alone.
    static let blockingNotificationTypes: Set<String> = ["permission_prompt", "elicitation_dialog"]

    /// Whether a `notification` hook's stdin `payload` is one of the blocking types. An absent or
    /// unreadable payload, or one without a recognized type, is not a block.
    public static func reportsBlock(inHookPayload payload: Data?) -> Bool {
        guard let payload, !payload.isEmpty, let object = try? JSONSerialization.jsonObject(with: payload), let fields = object as? [String: Any],
            let type = fields["notification_type"] as? String
        else { return false }
        return blockingNotificationTypes.contains(type)
    }
}
