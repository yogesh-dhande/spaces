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
    /// `onDisconnect` fires exactly once when the stream ends (with an error, or `nil` on clean close).
    /// The `request` is the fully-formed `.subscribe` request the client built (auth token and client
    /// identity already applied), so a backend transmits it as-is.
    func openSessionStream(
        request: SpacesDeviceAPIRequest, onEvent: @escaping @MainActor (GhosttyRemoteSessionStatePayload) -> Void,
        onDisconnect: @escaping @MainActor (Error?) -> Void
    ) throws -> SpacesDeviceAPIStreamHandle
}
