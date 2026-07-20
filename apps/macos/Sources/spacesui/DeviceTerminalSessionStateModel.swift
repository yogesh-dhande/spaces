#if canImport(Network)
    import AppKit
    import Foundation
    import spacesclientcore
    import spacesdevicecore
    import spacesterminalcore
    import spacesterminalghostty
    import spacesterminalui
    import workspacecore

    /// Device-backed terminal session state for the mac GUI.
    ///
    /// One implementation serves both the local device and paired remote devices:
    /// it owns a pinned-TLS Device API session client and a single state
    /// subscription stream for the session, keyed by the owning
    /// `SpacesPairedDeviceRecord` and session id. Launch configuration is seeded
    /// from the device overview; runtime state, attachment ownership, and the
    /// latest render payload are filled by an initial catch-up `.state` request and
    /// kept current by the subscription. The mac GUI reads this state instead of
    /// opening the daemon's `spaces.db`, so the same code path drives local and
    /// remote terminal windows.
    ///
    /// The model exposes its one underlying subscription as a fan-out: the window
    /// controller observes metadata through `TerminalSessionStateProviding`, while
    /// the Ghostty render host is wired to the same stream through
    /// `makeHostStateStreamSubscriber()` and issues control/state requests through
    /// `terminalServiceRequestSender`. Nothing here writes to local `spaces.db`.
    @MainActor final class DeviceTerminalSessionStateModel: TerminalSessionStateProviding {
        struct PreparedCredentials: Sendable, Equatable {
            let certificateFingerprint: String
            let authToken: String?
        }

        // `device`, `certificateFingerprint`, and the boxed request client are mutable so the local
        // device's stale Device API endpoint can be re-resolved at connect time (see
        // `ensureLocalDeviceReachableForRetry`). The app holds this model for the pane's lifetime; the
        // paired_devices row it was seeded from goes stale when the local daemon idle-shuts-down and
        // rebinds a port — and its TLS identity may rotate — so the persistent request client, its
        // certificate fingerprint, and the subscription stream must all be able to swing to the daemon's
        // current endpoint and identity.
        private var device: SpacesPairedDeviceRecord
        private let sessionID: String
        private let clientApp: SpacesDeviceClientApp
        private var certificateFingerprint: String
        // Internal (not `private`) so `spacesuiTests` can swing the box to a second in-process server to
        // prove vended senders follow a local endpoint recovery: `ensureLocalDeviceReachableForRetry`
        // bootstraps through the real local control socket and cannot run hermetically, so the test drives
        // the box replacement the recovery performs directly.
        let requestClientBox: DeviceAPIRequestClientBox

        // Cached device-owned state. Synchronous reads keep the window controller's
        // refresh path non-blocking; updates arrive on the main actor.
        private(set) var currentLaunchConfiguration: TerminalSessionLaunchConfiguration?
        private(set) var currentRuntimeState: TerminalSessionRuntimeState?
        private(set) var currentAttachmentSnapshot: TerminalSessionAttachmentSnapshot?
        private(set) var latestRemoteStatePayload: GhosttyRemoteSessionStatePayload?

        private struct Listener {
            let id: UUID
            let onUpdate: @MainActor (GhosttyRemoteSessionStatePayload) -> Void
            let onDisconnect: @MainActor ((any Error)?) -> Void
        }

        private var listeners: [Listener] = []
        private var streamClient: (any TerminalRemoteStateStreamClient)?
        // Bumped every time a stream client is installed. `onEvent`/`onDisconnect` callbacks carry the
        // generation they were created under, so a superseded client's late callback (an immediate
        // post-connect rejection, or a straggling disconnect after replacement) is ignored instead of
        // tearing down or feeding the current stream.
        private var streamClientGeneration: UInt64 = 0
        private var lastSubscriptionAttemptAt: Date?
        private var refreshInFlight = false
        private var stateRefreshRetryTask: Task<Void, Never>?
        // Owns the off-main connect for the live subscription. The pinned-TLS connect blocks on a
        // semaphore, so it must never run on the main actor; while a connect is in flight this guards
        // `ensureSubscriptionStarted` from starting a second one.
        private var subscriptionConnectTask: Task<Void, Never>?

        // Emission time of the newest payload already applied. The catch-up `.state`
        // request runs in parallel with the live subscription, so a catch-up response
        // captured before a newer stream event can still arrive after it. The daemon
        // stamps every payload — render frame, attachment change, runtime update, and
        // the terminated final state — with its emission time, so `apply(_:)` drops a
        // payload that predates what we've applied, preventing a stale catch-up from
        // regressing owner/runtime/render. Revisions are deliberately not used for this:
        // attachment-only updates (and every Linux payload) reuse the prior revisions, so
        // a revision check would wrongly drop ownership changes after a quiet terminal.
        private var lastAppliedEmittedAt: Date?

        init(
            device: SpacesPairedDeviceRecord, sessionID: String, launchConfiguration: TerminalSessionLaunchConfiguration,
            initialRuntimeState: TerminalSessionRuntimeState? = nil, initialAttachmentSnapshot: TerminalSessionAttachmentSnapshot? = nil,
            clientApp: SpacesDeviceClientApp, preparedCredentials: PreparedCredentials
        ) throws {
            self.device = device
            self.sessionID = sessionID
            self.clientApp = clientApp
            certificateFingerprint = preparedCredentials.certificateFingerprint
            requestClientBox = DeviceAPIRequestClientBox(
                try SpacesDeviceAPIRequestSessionClient(
                    host: device.host, port: device.port, certificateFingerprint: preparedCredentials.certificateFingerprint),
                authToken: preparedCredentials.authToken)
            currentLaunchConfiguration = launchConfiguration
            currentRuntimeState = initialRuntimeState
            // Seed the owner from the overview so an owner-seeking open sees the existing
            // owner immediately and takes the takeover path, rather than attaching as owner
            // before the live subscription catches up.
            currentAttachmentSnapshot = initialAttachmentSnapshot
        }

        nonisolated static func resolveCredentials(device: SpacesPairedDeviceRecord, clientApp: SpacesDeviceClientApp, profile: SpacesProfile? = nil)
            throws -> PreparedCredentials
        {
            let credentials = try SpacesDeviceClient.credentialsEnsuringLocalRecovery(device: device, clientApp: clientApp, profile: profile)
            return PreparedCredentials(certificateFingerprint: credentials.certificateFingerprint, authToken: credentials.authToken)
        }

        deinit {
            guard Thread.isMainThread else { return }
            MainActor.assumeIsolated {
                streamClient?.stop()
                stateRefreshRetryTask?.cancel()
                subscriptionConnectTask?.cancel()
                requestClientBox.current.client.cancel()
            }
        }

        // MARK: TerminalSessionStateProviding

        func refreshState() {
            guard !refreshInFlight else { return }
            refreshInFlight = true
            let sessionID = self.sessionID
            let clientApp = self.clientApp
            let requestClientBox = self.requestClientBox
            Task { @MainActor [weak self] in
                let result = await Task.detached(priority: .userInitiated) {
                    let (client, token) = requestClientBox.current
                    return Self.fetchState(sessionID: sessionID, requestClient: client, authToken: token, clientApp: clientApp)
                }.value
                guard let self else { return }
                self.refreshInFlight = false
                switch result {
                case .success(let payload):
                    self.stateRefreshRetryTask?.cancel()
                    self.stateRefreshRetryTask = nil
                    self.apply(payload)
                case .failure: self.scheduleStateRefreshRetry()
                }
            }
        }

        func startStateStream(
            onUpdate: @escaping @MainActor (GhosttyRemoteSessionStatePayload) -> Void, onDisconnect: @escaping @MainActor ((any Error)?) -> Void
        ) { registerListener(onUpdate: onUpdate, onDisconnect: onDisconnect) }

        // MARK: Host wiring

        /// Device API request sender for the Ghostty render host's control and
        /// catch-up `.state` requests. Both local and remote sessions route through
        /// the owning device's Device API endpoint.
        var terminalServiceRequestSender: RemoteGhosttyTerminalServiceRequestSender {
            let sessionID = self.sessionID
            let clientApp = self.clientApp
            let requestClientBox = self.requestClientBox
            return { request in
                let (client, token) = requestClientBox.current
                return try Self.sendTerminalServiceRequest(
                    request, defaultSessionID: sessionID, requestClient: client, authToken: token, clientApp: clientApp)
            }
        }

        /// Applies the session state returned alongside a terminal control response
        /// (notably a successful takeover) so the window reflects the new owner/render
        /// immediately, without waiting for the live subscription to redeliver it.
        func applyControlResponseState(_ payload: GhosttyRemoteSessionStatePayload) { apply(payload) }

        /// A `@Sendable` applier for control responses, captured by the off-main control
        /// closures. It hops back to the main actor to update cached state and fan out.
        var controlStateApplier: @Sendable (GhosttyRemoteSessionStatePayload) -> Void {
            { [weak self] payload in Task { @MainActor [weak self] in self?.applyControlResponseState(payload) } }
        }

        func pasteImage(_ image: TerminalPasteboardImage, clientID: String, ownerEpoch: UInt64) async throws -> TerminalControlResponse {
            let sessionID = self.sessionID
            let clientApp = self.clientApp
            let requestClientBox = self.requestClientBox
            return try await Task.detached(priority: .userInitiated) {
                let (client, token) = requestClientBox.current
                let request = SpacesDeviceAPIRequest(
                    command: .terminalPasteImage(
                        SpacesDeviceTerminalPasteImageRequest(
                            sessionID: sessionID, clientID: clientID, ownerEpoch: ownerEpoch, fileExtension: image.fileExtension,
                            imageData: image.imageData)), authToken: token, clientApp: clientApp)
                let response = try client.send(request)
                return TerminalControlResponse(ok: response.ok, message: response.message)
            }.value
        }

        /// Fetches a suffix of the session's persisted output transcript for the render host's
        /// client-local ended-session scrollback replay. Read-only; routes through the owning device's
        /// Device API endpoint like every other request, so it serves local and remote sessions alike.
        ///
        /// This is the only request path an ended session still exercises, so — unlike every other request
        /// path — it recovers a dead local endpoint itself. `scheduleReconnect` bails for a non-interactive
        /// session, so an ended pane gets no stream reconnect; when the local daemon idle-shuts-down under an
        /// open ended pane nothing else ever rebuilds the shared request client, and each scroll's fetch
        /// would retry the dead endpoint forever. On a local-daemon reachability failure it re-resolves the
        /// daemon's current endpoint through `ensureLocalDeviceReachableForRetry` (which swings the shared
        /// box) and retries the send once; any other failure, or a failed recovery, rethrows the original
        /// error. No other request path gets this recovery — the stream side owns it for interactive sessions.
        func fetchTranscript(maxBytes: Int) async throws -> RemoteGhosttyTranscript {
            do { return try await sendTranscriptRequest(maxBytes: maxBytes) } catch {
                // A certificate pin mismatch is accepted as a recovery trigger here, unlike everywhere else.
                // `isLocalDaemonUnreachableError` deliberately excludes pin mismatch because for a REMOTE
                // device a rotated identity can only be re-established by re-pairing. For the LOCAL device it
                // IS recoverable: the daemon may have restarted on the same port with a rotated TLS identity,
                // and the bootstrap re-reads that current identity over the trusted local control socket. This
                // guard is already local-device-only, so accepting it here stays safe. The connector throws
                // `TerminalServiceTLSError.certificatePinMismatch` unwrapped, so match it directly.
                let isLocalPinMismatch: Bool
                if case TerminalServiceTLSError.certificatePinMismatch = error { isLocalPinMismatch = true } else { isLocalPinMismatch = false }
                guard device.id == SpacesPairedDeviceRecord.localDeviceID,
                    isLocalPinMismatch || SpacesDeviceClient.isLocalDaemonUnreachableError(error),
                    await ensureLocalDeviceReachableForRetry()
                else { throw error }
                return try await sendTranscriptRequest(maxBytes: maxBytes)
            }
        }

        /// Off-main transcript send against the box's current client and token. Factored out so
        /// `fetchTranscript`'s try/recover/retry reads as one flow.
        private func sendTranscriptRequest(maxBytes: Int) async throws -> RemoteGhosttyTranscript {
            let sessionID = self.sessionID
            let clientApp = self.clientApp
            let requestClientBox = self.requestClientBox
            return try await Task.detached(priority: .userInitiated) {
                let (client, token) = requestClientBox.current
                return try Self.fetchTranscript(
                    sessionID: sessionID, maxBytes: maxBytes, requestClient: client, authToken: token, clientApp: clientApp)
            }.value
        }

        /// Internal (not `private`) so `spacesuiTests` can drive it directly through
        /// `@testable import spacesui` against a real `SpacesDeviceAPIRequestSessionClient` pointed at an
        /// in-process `SpacesDeviceAPIServer`; the client is a concrete `final class` with no protocol
        /// seam to fake, so this is the closest faithful integration test of the mapping below.
        nonisolated static func fetchTranscript(
            sessionID: String, maxBytes: Int, requestClient: SpacesDeviceAPIRequestSessionClient, authToken: String?,
            clientApp: SpacesDeviceClientApp
        ) throws -> RemoteGhosttyTranscript {
            let request = SpacesDeviceAPIRequest(
                command: .terminalTranscript(SpacesDeviceTerminalTranscriptRequest(sessionID: sessionID, maxBytes: maxBytes)),
                authToken: authToken, clientApp: clientApp)
            // The session client's default timeout cannot carry a budget-sized transcript on a
            // slow remote link; use the shared per-command policy instead.
            let response = try requestClient.send(request, timeoutSeconds: SpacesDeviceClient.requestTimeoutSeconds(for: request.command))
            guard response.ok, let transcript = response.terminalTranscript else {
                // A missing `output.log` is definitive: the server reports `.sessionNotAvailable`, which
                // means there is simply nothing to replay. Return an empty transcript so the render host
                // latches its `.unavailable` verdict instead of retrying the doomed fetch on every scroll
                // gesture; every other failure stays transient and throws so the host retries. The server
                // does not report a run identity on the error response, so it is nil here.
                if response.errorCode == .sessionNotAvailable { return RemoteGhosttyTranscript(data: Data(), runIdentity: nil) }
                throw SpacesDeviceClientError.unavailable(response.message)
            }
            return RemoteGhosttyTranscript(data: transcript.data, runIdentity: transcript.runIdentity)
        }

        /// State-stream subscriber for the Ghostty render host. Instead of opening a
        /// second Device API stream, it attaches the host's callbacks to this model's
        /// single underlying subscription, so one stream feeds both the host renderer
        /// and the window controller.
        func makeHostStateStreamSubscriber() -> RemoteGhosttyStateStreamSubscriber {
            { [weak self] _, onEvent, onDisconnect in
                guard let self else { throw SpacesDeviceClientError.unavailable("Terminal state model was released.") }
                return MainActor.assumeIsolated {
                    self.registerListener(onUpdate: { payload in onEvent(payload) }, onDisconnect: { error in onDisconnect(error) })
                }
            }
        }

        // MARK: Fan-out subscription

        @discardableResult private func registerListener(
            onUpdate: @escaping @MainActor (GhosttyRemoteSessionStatePayload) -> Void, onDisconnect: @escaping @MainActor ((any Error)?) -> Void
        ) -> ListenerHandle {
            let id = UUID()
            listeners.append(Listener(id: id, onUpdate: onUpdate, onDisconnect: onDisconnect))
            // Replay the last known payload so a late subscriber renders immediately.
            if let latestRemoteStatePayload { onUpdate(latestRemoteStatePayload) }
            ensureSubscriptionStarted()
            return ListenerHandle(detach: { [weak self] in Task { @MainActor [weak self] in self?.removeListener(id: id) } })
        }

        fileprivate func removeListener(id: UUID) {
            listeners.removeAll { $0.id == id }
            if listeners.isEmpty {
                stateRefreshRetryTask?.cancel()
                stateRefreshRetryTask = nil
            }
        }

        private func ensureSubscriptionStarted(now: Date = Date()) {
            if streamClient != nil || subscriptionConnectTask != nil { return }
            if let lastSubscriptionAttemptAt, now.timeIntervalSince(lastSubscriptionAttemptAt) < 0.5 { return }
            lastSubscriptionAttemptAt = now
            // Catch up unconditionally, before (and independent of) the subscribe below.
            // The daemon only streams live sessions, so an ended session's subscribe is
            // rejected — but its `.state` response still carries the final render the host
            // needs, and that response must be applied even when no live stream attaches.
            refreshState()
            subscriptionConnectTask = Task { @MainActor [weak self] in
                await self?.establishStateStreamConnection()
                self?.subscriptionConnectTask = nil
            }
        }

        /// Establishes the live subscription stream, keeping the blocking pinned-TLS connect off the main
        /// actor (issue #185). The connect is gated by a dispatch-semaphore wait; running it on the main
        /// actor froze the UI for the full connect timeout whenever the endpoint was stale or unreachable.
        /// On a retryable connect failure for the local device it re-resolves the daemon's current Device
        /// API port and retries once, so an idle-shut-down daemon that rebound an ephemeral port (or a
        /// stale paired_devices row) is recovered rather than stranding the pane. `openStateStream` installs
        /// and clears `streamClient` itself (see its install-before-start note), so this method only decides
        /// whether to retry or schedule a reconnect from its boolean result.
        private func establishStateStreamConnection() async {
            if streamClient != nil { return }
            if await openStateStream(port: Int(device.port)) { return }
            // The first connect failed. For the local device this may be a stale port or an idle-shut-down
            // daemon; ensure it is running and re-resolve its current port, then retry. The (possibly
            // rebuilt) request client now targets a running daemon, so re-run the catch-up: an ended
            // session's final render — and every subsequent transcript fetch — must reach the live daemon.
            guard await ensureLocalDeviceReachableForRetry() else {
                scheduleReconnect()
                return
            }
            await reloadCatchUpState()
            if await openStateStream(port: Int(device.port)) { return }
            // A transient subscribe failure on a live session would otherwise strand existing listeners
            // with only the one-shot catch-up and no live updates, because the render host has already
            // taken its `ListenerHandle` and will not ask to subscribe again. Schedule the same
            // model-owned retry the disconnect path uses.
            scheduleReconnect()
        }

        /// Opens and starts the subscription stream, running the blocking `start()` connect in a detached
        /// task so its semaphore wait never lands on the main actor. Returns true when `start()` succeeded,
        /// false on a construction or connect/handshake failure.
        ///
        /// The client is installed as `streamClient` before `start()` runs: `start()` returns after merely
        /// sending the subscribe request, so a server rejection arrives as a later response line whose
        /// `onDisconnect` can reach the main actor before this function resumes. Installing first means that
        /// racing disconnect finds the client installed and clears it through the disconnect path (which
        /// owns reconnect), instead of clearing nothing and letting the resumption store a dead client that
        /// would block every future reconnect. A `true` result therefore does not guarantee the installed
        /// client is still current — a racing disconnect may already have cleared and rescheduled it — only
        /// that the disconnect path has taken over its lifecycle.
        @discardableResult private func openStateStream(port: Int) async -> Bool {
            let request = SpacesDeviceAPIRequest(
                command: .subscribe(SpacesDeviceTerminalSubscriptionRequest(sessionID: sessionID, clientID: nil)),
                authToken: requestClientBox.current.authToken, clientApp: clientApp)
            let host = device.host
            let fingerprint = certificateFingerprint
            streamClientGeneration &+= 1
            let generation = streamClientGeneration
            let client: SpacesDeviceAPIStateStreamClient
            do {
                client = try SpacesDeviceAPIStateStreamClient(
                    request: request, host: host, port: port, certificateFingerprint: fingerprint,
                    onEvent: { [weak self] payload in Task { @MainActor [weak self] in self?.applyStreamEvent(payload, generation: generation) } },
                    onDisconnect: { [weak self] error in
                        Task { @MainActor [weak self] in self?.handleStreamDisconnect(error, generation: generation) }
                    })
            } catch { return false }
            streamClient = client
            let started = await Task.detached(priority: .userInitiated) { () -> Bool in
                do {
                    try client.start()
                    return true
                } catch { return false }
            }.value
            guard started else {
                // Only clear the installed client if it is still this one; a racing disconnect (or a newer
                // connect) may already have replaced it, and clearing then would drop a healthy stream.
                if streamClient === client { streamClient = nil }
                client.stop()
                return false
            }
            return true
        }

        /// Deterministic catch-up used by the connect recovery path after re-resolving a stale local port.
        /// Unlike `refreshState()` it bypasses the `refreshInFlight` throttle — the throttled fetch is
        /// against the now-cancelled stale-port client and about to fail — so the ended session's final
        /// render reliably reloads against the fresh port. Reuses the same `fetchState` mapping.
        private func reloadCatchUpState() async {
            let sessionID = self.sessionID
            let clientApp = self.clientApp
            let requestClientBox = self.requestClientBox
            let result = await Task.detached(priority: .userInitiated) {
                let (client, token) = requestClientBox.current
                return Self.fetchState(sessionID: sessionID, requestClient: client, authToken: token, clientApp: clientApp)
            }.value
            if case .success(let payload) = result { apply(payload) }
        }

        /// For the local device, ensures the daemon is running and re-resolves its current Device API
        /// endpoint via `SpacesDeviceClient.bootstrapLocalDevice` — the same per-request resolution the CLI
        /// uses, which starts the daemon if it idle-shut-down — rebuilding the persistent request client
        /// when the port, host, certificate fingerprint, or auth token moved so catch-up `.state`,
        /// transcript fetches, and the retried subscribe reach the live daemon under its current identity and
        /// credentials. `bootstrapLocalDevice` presents the stored token so the daemon normally keeps it, but
        /// a daemon whose pairing state was reset mints and persists a fresh token, revoking the one the box
        /// still holds; this reads that persisted token back and rebuilds the box with it, so every vended
        /// sender re-authenticates. The rebuild swings the shared `requestClientBox` (client and token
        /// together), so senders already vended to the render host follow the new client and token. Returns
        /// true when a connect retry is worthwhile: this is the local device and the bootstrap succeeded, so
        /// the daemon is now reachable whether or not it rebound the same port, rotated its certificate, or
        /// rotated its token. Returns false for remote devices (stable endpoint, nothing to re-resolve) and
        /// when the local bootstrap itself failed (the daemon could not be reached or started).
        ///
        /// Invoked from the connect-time subscribe recovery, the transcript path's local pin-mismatch/
        /// unreachable recovery, and the stream-disconnect path when the local daemon rejected a subscribe as
        /// `.unauthorized` — every case where the daemon is reachable but the pane's pinned identity or boxed
        /// token is stale, and the token refresh above is what re-authenticates the revoked case.
        @discardableResult private func ensureLocalDeviceReachableForRetry() async -> Bool {
            guard device.id == SpacesPairedDeviceRecord.localDeviceID else { return false }
            let clientApp = self.clientApp
            let previousHost = device.host
            let previousPort = device.port
            let previousFingerprint = certificateFingerprint
            let previousToken = requestClientBox.current.authToken
            let bootstrapResult = await Task.detached(priority: .userInitiated) { () -> (record: SpacesPairedDeviceRecord, token: String?)? in
                guard let refreshed = try? SpacesDeviceClient.bootstrapLocalDevice(clientApp: clientApp) else { return nil }
                // The bootstrap persisted the daemon's (possibly rotated) token. Read it back so a
                // pairing-state reset that minted a new token re-authenticates every sender. A successful
                // read of `nil` is a legitimate "no token"; only a failed read falls back to the token the
                // box already holds, so a transient secret-store hiccup does not drop auth.
                let refreshedToken =
                    (try? SpacesDeviceCredentialStore.token(deviceID: SpacesPairedDeviceRecord.localDeviceID, profile: nil)) ?? previousToken
                return (refreshed, refreshedToken)
            }.value
            guard let bootstrapResult else { return false }
            let refreshed = bootstrapResult.record
            let refreshedToken = bootstrapResult.token
            let endpointOrIdentityChanged =
                refreshed.port != previousPort || refreshed.host != previousHost || refreshed.certificateFingerprint != previousFingerprint
            // Rebuild on an endpoint/identity move or a token rotation through one branch — a token-only
            // change rebuilds the client too rather than carrying a special-cased in-place token swap.
            if endpointOrIdentityChanged || refreshedToken != previousToken,
                let rebuiltClient = try? SpacesDeviceAPIRequestSessionClient(
                    host: refreshed.host, port: refreshed.port, certificateFingerprint: refreshed.certificateFingerprint)
            {
                let previousClient = requestClientBox.replace(with: rebuiltClient, authToken: refreshedToken)
                // `cancel()` contends with `send()`'s request lock, which an in-flight request against the
                // stale endpoint can hold for its full timeout — so the previous client must be cancelled
                // off the main actor.
                Task.detached(priority: .utility) { previousClient.cancel() }
                // The stream connect in `openStateStream` reads `certificateFingerprint`, so it must move to
                // the daemon's current identity too or the retried subscribe would pin-fail.
                certificateFingerprint = refreshed.certificateFingerprint
                device = refreshed
            }
            return true
        }

        /// Internal (not `private`) so `spacesuiTests` can drive the generation guard directly: the concrete
        /// stream client offers no seam to force callback orderings, so the test installs stream clients via
        /// `installStreamClientForTesting` and calls this with a stale generation to prove a superseded
        /// client's late callback is ignored.
        ///
        /// A reachable local daemon that rejected the subscribe as `.unauthorized` gets a credential refresh
        /// before the reconnect: the boxed token was revoked (a pairing-state reset minted a fresh one) while
        /// the endpoint stayed put, so re-bootstrapping through the trusted local control socket swings the
        /// box to the daemon's current token and the next subscribe authenticates. Every other disconnect
        /// takes the plain delayed reconnect.
        func handleStreamDisconnect(_ error: (any Error)?, generation: UInt64) {
            // A superseded stream client's late disconnect must not tear down the client that replaced it.
            guard generation == streamClientGeneration else { return }
            // Keep listeners attached through a subscribe drop: the asynchronous catch-up
            // `.state` (the final render for an ended session) must still reach them, and
            // not notifying listeners keeps the render host from re-registering and
            // accumulating duplicates. The model owns reconnection.
            streamClient = nil
            // Gate strictly on `.unauthorized` for the local device: an unauthorized subscribe rejection means
            // the daemon is reachable but the boxed token is stale, recoverable only by re-bootstrapping.
            // Ended-session rejections (session-not-running/not-available) and remote devices must never
            // trigger a bootstrap, so they fall through to the plain reconnect. A failed recovery still
            // reaches `scheduleReconnect`, so the loop degrades to the pre-existing retry cadence rather than
            // tightening.
            if let error, case SpacesDeviceAPIRequestClientError.requestRejected(_, .unauthorized) = error,
                device.id == SpacesPairedDeviceRecord.localDeviceID
            {
                Task { @MainActor [weak self] in
                    await self?.ensureLocalDeviceReachableForRetry()
                    self?.scheduleReconnect()
                }
                return
            }
            scheduleReconnect()
        }

        /// Applies a live stream event only when it belongs to the current stream generation, so a
        /// superseded client cannot feed state after replacement. Catch-up `.state` responses bypass this
        /// and call `apply` directly — they carry no generation and their staleness is handled by
        /// `apply`'s emission-time guard.
        private func applyStreamEvent(_ payload: GhosttyRemoteSessionStatePayload, generation: UInt64) {
            guard generation == streamClientGeneration else { return }
            apply(payload)
        }

        // Test seams mirroring `openStateStream`'s install semantics. The concrete stream client offers no
        // protocol seam to force callback orderings, so `spacesuiTests` drives the generation guard through
        // these instead of racing a real connect.
        @discardableResult func installStreamClientForTesting(_ client: any TerminalRemoteStateStreamClient) -> UInt64 {
            streamClientGeneration &+= 1
            streamClient = client
            return streamClientGeneration
        }

        var hasActiveStreamClientForTesting: Bool { streamClient != nil }

        /// Re-subscribes after a short delay — only while the session may still be
        /// interactive and listeners remain. The delay avoids a tight reconnect loop;
        /// an ended session needs no live stream, so it is left disconnected.
        private func scheduleReconnect() {
            guard !listeners.isEmpty, currentRuntimeState?.state.isInteractive != false else { return }
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(500))
                guard let self, self.streamClient == nil, !self.listeners.isEmpty, self.currentRuntimeState?.state.isInteractive != false else {
                    return
                }
                self.lastSubscriptionAttemptAt = nil
                self.ensureSubscriptionStarted()
            }
        }

        private func scheduleStateRefreshRetry() {
            guard !listeners.isEmpty, currentRuntimeState?.state == .starting else { return }
            guard stateRefreshRetryTask == nil else { return }
            stateRefreshRetryTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(500))
                guard let self, !Task.isCancelled else { return }
                self.stateRefreshRetryTask = nil
                guard !self.listeners.isEmpty, self.currentRuntimeState?.state == .starting else { return }
                self.refreshState()
            }
        }

        /// Updates the cached metadata and fans the raw payload out to every
        /// listener (the host reduces render frames; the controller re-reads
        /// metadata). The raw payload is forwarded unchanged so render deltas are
        /// not lost to metadata merging.
        private func apply(_ payload: GhosttyRemoteSessionStatePayload) {
            if let emittedAt = GhosttyRemoteSessionStateTimestamp.date(from: payload.emittedAt) {
                if let lastAppliedEmittedAt, emittedAt < lastAppliedEmittedAt { return }
                lastAppliedEmittedAt = emittedAt
            }
            let merged = latestRemoteStatePayload?.merged(with: payload) ?? payload
            latestRemoteStatePayload = merged
            if let runtimeState = merged.runtimeState { currentRuntimeState = runtimeState }
            if let attachmentSnapshot = merged.attachmentSnapshot { currentAttachmentSnapshot = attachmentSnapshot }
            currentLaunchConfiguration = currentLaunchConfiguration.map { configuration in
                TerminalSessionLaunchConfiguration(
                    sessionID: configuration.sessionID, backend: configuration.backend, lifetimePolicy: configuration.lifetimePolicy,
                    title: merged.title.isEmpty ? configuration.title : merged.title,
                    workingDirectory: merged.workingDirectory.isEmpty ? configuration.workingDirectory : merged.workingDirectory,
                    shell: configuration.shell, command: configuration.command, createdAt: configuration.createdAt,
                    workspaceID: configuration.workspaceID, kind: configuration.kind)
            }
            for listener in listeners { listener.onUpdate(payload) }
        }

        // MARK: Device API requests

        private enum StateFetchError: Error { case rejected(String) }

        private nonisolated static func fetchState(
            sessionID: String, requestClient: SpacesDeviceAPIRequestSessionClient, authToken: String?, clientApp: SpacesDeviceClientApp
        ) -> Result<GhosttyRemoteSessionStatePayload, Error> {
            do {
                let response = try requestClient.send(
                    SpacesDeviceAPIRequest(
                        command: .state(SpacesDeviceTerminalSessionRequest(sessionID: sessionID)), authToken: authToken, clientApp: clientApp))
                guard response.ok else { throw StateFetchError.rejected(response.message) }
                guard let payload = response.sessionState else { throw StateFetchError.rejected("Device did not return terminal state.") }
                return .success(payload)
            } catch { return .failure(error) }
        }

        /// Internal (not `private`) so `spacesuiTests` can drive it directly through
        /// `@testable import spacesui` against a real `SpacesDeviceAPIRequestSessionClient`
        /// pointed at an in-process `SpacesDeviceAPIServer`. `SpacesDeviceAPIRequestSessionClient`
        /// is a concrete `final class` that always opens a real pinned-TLS connection — there is no
        /// protocol seam to fake it through — so the closest faithful test doubles as an integration
        /// test of the request/response mapping below.
        nonisolated static func sendTerminalServiceRequest(
            _ request: TerminalServiceRequest, defaultSessionID: String, requestClient: SpacesDeviceAPIRequestSessionClient, authToken: String?,
            clientApp: SpacesDeviceClientApp
        ) throws -> TerminalServiceResponse {
            switch request.command {
            case .state(let payload):
                let response = try requestClient.send(
                    SpacesDeviceAPIRequest(
                        command: .state(SpacesDeviceTerminalSessionRequest(sessionID: payload.sessionID)), authToken: authToken, clientApp: clientApp)
                )
                return TerminalServiceResponse(ok: response.ok, message: response.message, sessionState: response.sessionState)
            case .control(let payload):
                let deviceRequest = try AppKitController.deviceTerminalControlRequest(
                    sessionID: payload.sessionID, controlRequest: payload.controlRequest)
                let response = try requestClient.send(
                    SpacesDeviceAPIRequest(command: .terminalControl(deviceRequest), authToken: authToken, clientApp: clientApp))
                return TerminalServiceResponse(
                    ok: response.ok, message: response.message, sessionState: response.sessionState,
                    controlResponse: TerminalControlResponse(ok: response.ok, message: response.message))
            case .resolveTerminalLink(let payload):
                guard let terminalLink = payload.terminalLink?.trimmingCharacters(in: .whitespacesAndNewlines), !terminalLink.isEmpty else {
                    throw WorkspaceError.invalidArgument(message: "Missing terminal link to resolve.")
                }
                let response = try requestClient.send(
                    SpacesDeviceAPIRequest(
                        command: .resolveTerminalLink(
                            SpacesDeviceTerminalLinkResolveRequest(sessionID: payload.sessionID, terminalLink: terminalLink)), authToken: authToken,
                        clientApp: clientApp))
                return TerminalServiceResponse(
                    ok: response.ok, message: response.message,
                    terminalLinkMetadata: response.terminalLinkMetadata.map(Self.terminalServiceLinkMetadata))
            case .readTerminalLinkChunk(let payload):
                guard let terminalLinkID = payload.terminalLinkID?.trimmingCharacters(in: .whitespacesAndNewlines), !terminalLinkID.isEmpty else {
                    throw WorkspaceError.invalidArgument(message: "Missing terminal link id to read.")
                }
                let response = try requestClient.send(
                    SpacesDeviceAPIRequest(
                        command: .readTerminalLinkChunk(
                            SpacesDeviceTerminalLinkChunkRequest(
                                sessionID: payload.sessionID, terminalLinkID: terminalLinkID, offset: payload.offset, limit: payload.limit)),
                        authToken: authToken, clientApp: clientApp))
                return TerminalServiceResponse(
                    ok: response.ok, message: response.message, terminalLinkChunk: response.terminalLinkChunk.map(Self.terminalServiceLinkChunk))
            default: throw WorkspaceError.invalidArgument(message: "Device terminal command '\(request.commandName)' is not supported.")
            }
        }

        /// Maps a Device API terminal-link metadata payload into the terminal-service wire type.
        /// Mirrors the daemon's own mapping for the reverse direction (a local Ghostty-embedded
        /// session resolving a link), see `SpacesdMain.terminalServiceLinkMetadata`, so a link
        /// resolved through either path produces the same `TerminalServiceTerminalLinkMetadata`.
        private nonisolated static func terminalServiceLinkMetadata(_ metadata: SpacesDeviceTerminalLinkMetadata)
            -> TerminalServiceTerminalLinkMetadata
        {
            TerminalServiceTerminalLinkMetadata(
                id: metadata.id, source: metadata.source.rawValue, originalLink: metadata.originalLink, displayName: metadata.displayName,
                contentType: metadata.contentType, artifactKind: metadata.artifactKind?.rawValue, byteCount: metadata.byteCount,
                externalURL: metadata.externalURL)
        }

        /// Maps a Device API terminal-link chunk payload into the terminal-service wire type.
        /// Mirrors `SpacesdMain.terminalServiceLinkChunk`.
        private nonisolated static func terminalServiceLinkChunk(_ chunk: SpacesDeviceTerminalLinkChunk) -> TerminalServiceTerminalLinkChunk {
            TerminalServiceTerminalLinkChunk(
                linkID: chunk.linkID, offset: chunk.offset, byteCount: chunk.byteCount, isFinal: chunk.isFinal, base64Data: chunk.base64Data)
        }
    }

    /// Mutable, thread-safe holder for the model's persistent Device API request client and the auth
    /// token that authenticates its requests.
    ///
    /// The render host vends request senders (`terminalServiceRequestSender`, and the closures behind
    /// `refreshState`/`pasteImage`/`fetchTranscript`/`reloadCatchUpState`) that run off the main actor and
    /// so cannot read main-actor state at send time. A local endpoint recovery
    /// (`ensureLocalDeviceReachableForRetry`) rebuilds the request client to target the daemon's current
    /// port and identity; capturing the client by value would leave those already-vended senders forever
    /// targeting the cancelled stale-endpoint client. Capturing this box instead and reading `current` at
    /// send time lets every vended sender observe the rebuilt client.
    ///
    /// The token is boxed with the client because a local recovery can rotate both: a daemon whose pairing
    /// state was reset mints a fresh token on the next bootstrap, revoking the one captured at init. Storing
    /// them together and reading them as one pair at send time keeps every vended sender authenticating with
    /// the token that belongs to the client it is about to send through.
    final class DeviceAPIRequestClientBox: @unchecked Sendable {
        private let lock = NSLock()
        private var client: SpacesDeviceAPIRequestSessionClient
        private var authToken: String?

        init(_ client: SpacesDeviceAPIRequestSessionClient, authToken: String?) {
            self.client = client
            self.authToken = authToken
        }

        /// The current client and its auth token, read together under the lock so a concurrent recovery
        /// cannot hand back a client paired with the other one's token.
        var current: (client: SpacesDeviceAPIRequestSessionClient, authToken: String?) { lock.withLock { (client, authToken) } }

        /// Swaps in a new client and its auth token, returning the previous client so the caller can cancel it.
        @discardableResult func replace(with newClient: SpacesDeviceAPIRequestSessionClient, authToken newAuthToken: String?)
            -> SpacesDeviceAPIRequestSessionClient
        {
            lock.withLock {
                let previous = client
                client = newClient
                authToken = newAuthToken
                return previous
            }
        }
    }

    /// Handle returned to a fan-out subscriber. Stopping it detaches that listener
    /// from the model's shared subscription without tearing the stream down for
    /// other listeners.
    private final class ListenerHandle: TerminalRemoteStateStreamClient, @unchecked Sendable {
        private let detach: @Sendable () -> Void

        init(detach: @escaping @Sendable () -> Void) { self.detach = detach }

        func stop() { detach() }
    }
#endif
