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
    /// `initialEventTimeout` is the whole budget from starting the dial to decoding the stream's first
    /// payload: the caller sizes it for the attempt it is making (a cold open can afford a slow link, a
    /// redial into a reported outage cannot), so it is a per-call value rather than a backend constant.
    func openSessionStream(
        request: SpacesDeviceAPIRequest, initialEventTimeout: Duration, onEvent: @escaping @MainActor (GhosttyRemoteSessionStatePayload) -> Void,
        onDisconnect: @escaping @MainActor (SpacesDeviceAPIStreamDisconnect) -> Void
    ) async throws -> SpacesDeviceAPIStreamHandle

    /// Opens a device-overview push stream: the daemon's `subscribeDeviceOverview` semantics (see
    /// `spacesdevicecore.SpacesDeviceAPIOverviewStreamClient`), which push a fresh overview whenever the
    /// daemon's database changes rather than answering only on request. `onOverview` delivers every
    /// pushed overview and `onDisconnect` fires exactly once when the stream ends, carrying its error (or
    /// `nil` on an intentional stop). Unlike `openSessionStream`'s callbacks, both arrive off the main
    /// actor (the network backend's callbacks run on the shared stream client's own receive thread), so a
    /// caller that touches `@MainActor` state hops itself; this mirrors the Mac sidebar's
    /// `SpacesDeviceClient.subscribeOverview`, which the network backend below delegates to.
    func openOverviewStream(
        authToken: String?, clientApp: SpacesDeviceClientApp?, onOverview: @escaping @Sendable (SpacesDeviceOverviewPayload) -> Void,
        onDisconnect: @escaping @Sendable ((any Error)?) -> Void
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
    /// Default for a backend with no overview-stream concept: every test fake that exercises only the
    /// terminal session stream or the request path. The two production backends (network, Demo) both
    /// override this; a fake that hits it is one this feature does not touch.
    func openOverviewStream(
        authToken: String?, clientApp: SpacesDeviceClientApp?, onOverview: @escaping @Sendable (SpacesDeviceOverviewPayload) -> Void,
        onDisconnect: @escaping @Sendable ((any Error)?) -> Void
    ) async throws -> SpacesDeviceAPIStreamHandle { throw SpacesDeviceAPIClientError.invalidEndpoint }
}
