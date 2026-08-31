import Foundation

/// Maps a remote session-state payload's `reason` to the local notifications a client
/// mirroring that session fans out after applying it.
///
/// The two notification families cost very different amounts to observe: a
/// `.spacesTerminalOutputDidChange` observer refreshes only when screen content can change what
/// its pane presents — never for a pane whose live Ghostty mirror painted the content itself, and
/// never for one parked on the takeover screen, which presents no session content until its
/// surface becomes renderable. `.spacesTerminalRuntimeStateDidChange` drives a full pane refresh
/// unconditionally — attachment and ownership resolution, renderer selection, and tab/pane title
/// re-derivation.
///
/// Reasons that describe screen content (`input`, `input_output`, `output`, `state_change`,
/// `scroll`, `clear_screen`, `selection`, `resize`) are therefore output-shaped. `selection`
/// belongs here because the shared highlight lives in the exported snapshot like any other
/// screen content: a newer frame renders it exactly, and a pane parked on the takeover or
/// unavailable presentation needs the output notification to notice its first renderable
/// frame even when that frame arrived under `selection`. They arrive at
/// interaction frequency, and applying the payload has already updated the mirror's frame
/// and the client's cached runtime/attachment state by the time this routing runs. Every
/// change a pane refresh actually reacts to — a runtime-state transition, an attachment or
/// ownership change, a title or working-directory change, termination — is broadcast under
/// its own reason, so none of the screen-content reasons carries a state change of its own.
///
/// `session_metadata` routes to `.spacesTerminalSessionMetadataDidChange` alone, not also to
/// `.spacesTerminalRuntimeStateDidChange`: `TerminalSessionPaneViewController` observes both, and
/// both observers do the identical unconditional `refreshNow()` gated only by session ID, so
/// fanning one title change out to both would run that refresh twice for no second effect. A
/// coding agent rewriting its terminal title can post this reason many times a second, and the
/// duplicate used to double that refresh cost on every one of them. The in-process local host
/// (`GhosttyEmbeddedSessionHost.postSessionMetadataDidChange`) never posted the runtime-state
/// notification alongside its metadata one — this table's remote-mirroring path is what
/// introduced the extra fan-out, not a second consumer that actually needs it. `attachment_state`
/// keeps its own pairing unchanged: fixing that would be the same shape of change but is out of
/// scope here, since ownership handoffs are rare enough that doubling their refresh is not the
/// streaming-cadence cost this table exists to control.
public enum TerminalRemoteSessionStateNotificationRouting {
    /// Keeps the `String` entry point: callers hold the wire reason off a payload, not the parsed
    /// enum. An unrecognized reason parses to `nil` and posts nothing, matching what the old
    /// `default:` branch did — the payload has already been applied to the mirror and to the
    /// client's cached session state, so posting nothing keeps an unrecognized reason off the
    /// refresh path instead of letting it inherit the most expensive one; a state change that needs
    /// a refresh also arrives under a known reason.
    ///
    /// Falling back to a runtime-state refresh here would buy forward compatibility with a daemon
    /// that introduces a reason this client has never seen, at the cost of restoring the silent
    /// inheritance of the most expensive path this table exists to prevent. That trade is
    /// deliberately declined: a reason is added to this table in the same change that introduces it,
    /// so an unknown reason means a client and daemon built from different sources — a mismatch this
    /// product does not carry compatibility code for.
    public static func notifications(forReason reason: String) -> [Notification.Name] {
        guard let reasonKind = TerminalRemoteSessionStateReason(rawValue: reason) else { return [] }
        // `isOutputShaped` is the single source for which reasons are screen-content-shaped; deferring
        // to it here (rather than repeating its case list) is what keeps this switch and that one from
        // disagreeing about any given reason.
        if reasonKind.isOutputShaped { return [.spacesTerminalOutputDidChange] }
        switch reasonKind {
        case .attachmentState: return [.spacesTerminalAttachmentStateDidChange, .spacesTerminalRuntimeStateDidChange]
        case .sessionMetadata: return [.spacesTerminalSessionMetadataDidChange]
        case .initial, .runtimeState, .terminated: return [.spacesTerminalRuntimeStateDidChange]
        case .clipboardWrite:
            // Deliberately no notification. A clipboard write changes nothing a pane presents — the
            // receiving client acts on it where it applies the payload, by writing its own
            // pasteboard — so neither refresh family has anything to do. The row exists because
            // dropping it would make a later reader think this reason was simply forgotten.
            return []
        case .output, .input, .inputOutput, .stateChange, .scroll, .clearScreen, .selection, .resize:
            // Unreachable: the `isOutputShaped` guard above already returned for every one of these
            // cases. Listed anyway because the switch must stay exhaustive over the full enum, which
            // is what forces `isOutputShaped` to be updated (and this switch to be revisited) the
            // moment a case is added or reclassified.
            preconditionFailure("isOutputShaped already returned for this reason")
        }
    }

    /// Whether `reason` routes to exactly `[.spacesTerminalOutputDidChange]` — the same test
    /// `TerminalRemoteStateReductionOutput.isCoalescibleOnApply` needs on every mailbox submit, but
    /// answered without building the two `[Notification.Name]` arrays `notifications(forReason:)`
    /// allocates to make that comparison. A switch over the same reasons costs nothing per call, which
    /// matters here: the reduce loop calls this once per payload on a session under steady output,
    /// several times a second for as long as the session streams.
    ///
    /// Shares `isOutputShaped` with `notifications(forReason:)` above, so the two cannot drift apart
    /// as reasons are added: both switch exhaustively over `TerminalRemoteSessionStateReason`, so the
    /// compiler demands both are revisited when a case is added or reclassified.
    public static func isOutputShaped(reason: String) -> Bool { TerminalRemoteSessionStateReason(rawValue: reason)?.isOutputShaped ?? false }
}

extension TerminalRemoteSessionStateReason {
    /// Whether this reason describes screen content that could change what a mirroring pane
    /// presents. The single source both `TerminalRemoteSessionStateNotificationRouting.notifications(forReason:)`
    /// and `.isOutputShaped(reason:)` read, so the two entry points cannot disagree about a reason.
    fileprivate var isOutputShaped: Bool {
        switch self {
        case .output, .input, .inputOutput, .stateChange, .scroll, .clearScreen, .selection, .resize: return true
        case .initial, .attachmentState, .sessionMetadata, .runtimeState, .terminated, .clipboardWrite: return false
        }
    }
}
