import Foundation

/// Every `reason` a session core stamps on a broadcast remote-state payload. Subscribers route on
/// these, so a core must never broadcast a reason that is not declared here — the enum makes that
/// structural: a producer can only construct a case that exists, and a consumer that switches on
/// the enum without a `default:` is told by the compiler when a new case needs handling.
///
/// Raw values are the wire strings (`GhosttyRemoteSessionStatePayload.reason`) and must stay
/// byte-identical to what has always shipped; every case spells its raw value explicitly so the
/// wire contract is visible in one place, even where it matches the case name.
public enum TerminalRemoteSessionStateReason: String, Sendable, CaseIterable {
    case initial = "initial"
    case attachmentState = "attachment_state"
    case sessionMetadata = "session_metadata"
    case input = "input"
    case inputOutput = "input_output"
    case output = "output"
    case stateChange = "state_change"
    case scroll = "scroll"
    case clearScreen = "clear_screen"
    /// The shared selection changed (set or cleared), by any viewer or by the daemon auto-clearing
    /// a garbage-pinned selection. Selection is host-anchored, not owner-gated, so this reason
    /// carries no owner-specific gating of its own.
    case selection = "selection"
    case runtimeState = "runtime_state"
    case resize = "resize"
    case terminated = "terminated"
    /// A program copied to the clipboard (OSC 52). Carries `clipboardWrite` and nothing else the
    /// client acts on; see `TerminalClipboardWritePayload`.
    case clipboardWrite = "clipboard_write"
}
