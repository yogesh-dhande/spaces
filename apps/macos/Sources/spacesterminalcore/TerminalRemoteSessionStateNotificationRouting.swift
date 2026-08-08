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
/// `scroll`, `clear_screen`, `resize`) are therefore output-shaped. They arrive at
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
    public static func notifications(forReason reason: String) -> [Notification.Name] {
        switch reason {
        case TerminalRemoteSessionStateReason.attachmentState: return [.spacesTerminalAttachmentStateDidChange, .spacesTerminalRuntimeStateDidChange]
        case TerminalRemoteSessionStateReason.sessionMetadata: return [.spacesTerminalSessionMetadataDidChange]
        case TerminalRemoteSessionStateReason.initial, TerminalRemoteSessionStateReason.runtimeState, TerminalRemoteSessionStateReason.terminated:
            return [.spacesTerminalRuntimeStateDidChange]
        case TerminalRemoteSessionStateReason.output, TerminalRemoteSessionStateReason.input, TerminalRemoteSessionStateReason.inputOutput,
            TerminalRemoteSessionStateReason.stateChange, TerminalRemoteSessionStateReason.scroll, TerminalRemoteSessionStateReason.clearScreen,
            TerminalRemoteSessionStateReason.resize:
            return [.spacesTerminalOutputDidChange]
        case TerminalRemoteSessionStateReason.clipboardWrite:
            // Deliberately no notification. A clipboard write changes nothing a pane presents — the
            // receiving client acts on it where it applies the payload, by writing its own
            // pasteboard — so neither refresh family has anything to do. The row exists because the
            // `default:` below silently drops unknown reasons, which would make a later reader
            // think this reason was simply forgotten.
            return []
        default:
            // A reason this build does not know. The payload has already been applied to the
            // mirror and to the client's cached session state, so posting nothing keeps an
            // unrecognized reason off the refresh path instead of letting it inherit the most
            // expensive one; a state change that needs a refresh also arrives under a known reason.
            //
            // Falling back to a runtime-state refresh here would buy forward compatibility with a
            // daemon that introduces a reason this client has never seen, at the cost of restoring
            // the silent inheritance of the most expensive path that this exhaustive table exists
            // to prevent. That trade is deliberately declined: a reason is added to this table in
            // the same change that introduces it, so an unknown reason means a client and daemon
            // built from different sources — a mismatch this product does not carry compatibility
            // code for.
            return []
        }
    }

    /// Whether `reason` routes to exactly `[.spacesTerminalOutputDidChange]` — the same test
    /// `TerminalRemoteStateReductionOutput.isCoalescibleOnApply` needs on every mailbox submit, but
    /// answered without building the two `[Notification.Name]` arrays `notifications(forReason:)`
    /// allocates to make that comparison. A switch over the same reasons costs nothing per call, which
    /// matters here: the reduce loop calls this once per payload on a session under steady output,
    /// several times a second for as long as the session streams.
    ///
    /// This must stay consistent with `notifications(forReason:) == [.spacesTerminalOutputDidChange]`
    /// for every reason — enforced by `TerminalRemoteSessionStateNotificationRoutingTests`, which checks
    /// this predicate against that comparison for every declared reason plus an unknown one, so the two
    /// cannot drift apart as reasons are added.
    public static func isOutputShaped(reason: String) -> Bool {
        switch reason {
        case TerminalRemoteSessionStateReason.output, TerminalRemoteSessionStateReason.input, TerminalRemoteSessionStateReason.inputOutput,
            TerminalRemoteSessionStateReason.stateChange, TerminalRemoteSessionStateReason.scroll, TerminalRemoteSessionStateReason.clearScreen,
            TerminalRemoteSessionStateReason.resize:
            return true
        default:
            return false
        }
    }
}
