import Foundation
import spacesdevicecore
import spacesterminalcore

/// The request/response half of the Device API backend seam.
///
/// A transport owns one logical command connection: `send` performs a single request/response
/// round trip and `close` releases the underlying connection. `SpacesDeviceAPICommandChannel`
/// wraps `any SpacesDeviceAPIRequestTransport`, layering the auth-token/client-app defaulting on
/// top so every backend (network, demo) shares the same channel semantics.
protocol SpacesDeviceAPIRequestTransport: Sendable {
    func send(request: SpacesDeviceAPIRequest, timeout: Duration) async throws -> SpacesDeviceAPIResponse
    func close() async
}

/// The pluggable backend behind `SpacesDeviceAPIClient`.
///
/// The production `SpacesDeviceNetworkBackend` speaks the pinned-TLS Device API over `NWConnection`;
/// Demo Mode swaps in an in-memory backend that serves seeded sample data. Splitting the client
/// from its transport lets both share the identical request and stream code paths in the client,
/// so a backend only has to supply request round trips and session streams.
protocol SpacesDeviceAPIBackend: Sendable {
    /// Opens a fresh request transport (one logical command connection).
    func makeRequestTransport() -> any SpacesDeviceAPIRequestTransport

    /// Opens a session state stream. Mirrors the daemon `subscribe` semantics: the returned handle
    /// cancels the stream, `onEvent` delivers each decoded payload on the main actor, and
    /// `onDisconnect` fires exactly once when the stream ends, carrying the disconnect event (its
    /// error, or `nil` on clean close, plus the dial-exhaustion verdict for a failed dial, see
    /// `SpacesDeviceAPIStreamDisconnect`). The `request` is the fully-formed `.subscribe` request the
    /// client built (auth token and client identity already applied), so a backend transmits it as-is.
    func openSessionStream(
        request: SpacesDeviceAPIRequest, onEvent: @escaping @MainActor (GhosttyRemoteSessionStatePayload) -> Void,
        onDisconnect: @escaping @MainActor (SpacesDeviceAPIStreamDisconnect) -> Void
    ) async throws -> SpacesDeviceAPIStreamHandle

    /// The candidate address this backend's endpoint resolution most recently proved reachable, if it has
    /// one. Lets a caller (e.g. the browser proxy's route table) ask for the address the command channel
    /// actually validated rather than trusting a possibly-stale persisted record. Defaults to `nil` for a
    /// backend with no such concept.
    func currentResolvedHost() async -> String?

    /// Clears any endpoint this backend has already resolved, so the next request or stream re-races
    /// every candidate instead of continuing to use whichever one most recently answered. Defaults to a
    /// no-op for a backend with no such concept.
    func resetEndpointResolution() async

    /// Sends `request` (in practice, always a `.ping`) pinned to `host` rather than through this
    /// backend's normal endpoint resolution. Backs the input-timeout ping-corroboration probe (see
    /// `TerminalViewerModel.startInputTimeoutCorroborationProbe`). Returns `nil` when any response comes
    /// back, or the failure otherwise. The probe runs only for a stream that reported a host, and only
    /// the network backend opens one, so the default below is never reached: it exists so the backends
    /// without a host concept (Demo Mode) need no stub of their own.
    func sendPinnedPing(request: SpacesDeviceAPIRequest, host: String, timeout: Duration) async -> (any Error)?
}

extension SpacesDeviceAPIBackend {
    func currentResolvedHost() async -> String? { nil }
    func resetEndpointResolution() async {}
    func sendPinnedPing(request: SpacesDeviceAPIRequest, host: String, timeout: Duration) async -> (any Error)? {
        SpacesDeviceAPIClientError.requestFailed("This backend has no pinned host to ping.")
    }
}
