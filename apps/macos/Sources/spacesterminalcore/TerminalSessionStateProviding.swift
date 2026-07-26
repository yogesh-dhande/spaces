import Foundation

/// GUI-facing access to a terminal session's device-owned state.
///
/// The mac GUI treats a terminal session's launch configuration, runtime state,
/// attachment ownership, and latest remote render payload as device-owned daemon
/// state reached through the Device API — not as rows in the local `spaces.db`.
/// A single implementation serves both the local device and paired remote
/// devices: it is parameterized by the owning device record and session id,
/// seeds its launch configuration from the device overview, fetches catch-up
/// state through a Device API state request, and applies live updates from a
/// Device API subscription stream.
///
/// `current*` are synchronous reads of the model's last-known cached state so the
/// window controller's refresh path stays non-blocking; the cache is kept fresh
/// out of band by `refreshState()` and the subscription started through
/// `startStateStream(onUpdate:onDisconnect:)`.
@MainActor public protocol TerminalSessionStateProviding: AnyObject {
    /// Launch configuration for the session, seeded from the device overview and
    /// refreshed from streamed metadata. `nil` only before any state is known.
    var currentLaunchConfiguration: TerminalSessionLaunchConfiguration? { get }

    /// Latest known runtime state: process state, title, working directory, and
    /// viewport size. `nil` until the first catch-up state or stream update.
    var currentRuntimeState: TerminalSessionRuntimeState? { get }

    /// Latest known attachment snapshot, used to resolve the active owner client.
    var currentAttachmentSnapshot: TerminalSessionAttachmentSnapshot? { get }

    /// Most recent remote state payload (render update, revisions, metadata).
    var latestRemoteStatePayload: GhosttyRemoteSessionStatePayload? { get }

    /// True while the provider wants a live subscription for this session but does not have one — the
    /// stream dropped or a connect failed and a retry is armed.
    ///
    /// Deliberately separate from `currentRuntimeState`: the `current*` reads stay exactly as the
    /// device last reported them, so a session that is running on an unreachable device is
    /// representable as running-but-unreachable instead of being forced into an invented state. Read
    /// synchronously, and re-read on `.spacesTerminalStateStreamConnectionDidChange`, which the
    /// provider posts for this session id whenever the value flips.
    var isStateStreamDisconnected: Bool { get }

    /// Requests a catch-up state fetch so `current*` converge on the device's
    /// current view. The fetch is performed out of band; this call does not block
    /// and applied results surface through the `current*` reads and any active
    /// stream `onUpdate` callback.
    func refreshState()

    /// Starts (or re-attaches to) the live state subscription for this session.
    /// `onUpdate` fires on the main actor for each applied payload; `onDisconnect`
    /// fires when the stream ends, with `nil` for a clean end and an error
    /// otherwise. Calling more than once attaches additional listeners to the
    /// model's single underlying subscription rather than opening a new one.
    func startStateStream(
        onUpdate: @escaping @MainActor (GhosttyRemoteSessionStatePayload) -> Void, onDisconnect: @escaping @MainActor ((any Error)?) -> Void)
}
