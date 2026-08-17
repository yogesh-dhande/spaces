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

        /// True while the model wants a live subscription for this session but does not have one: the
        /// stream dropped or a connect failed and a retry is armed (see `scheduleReconnect`).
        ///
        /// Kept out of `currentRuntimeState` deliberately. The device's last report stays exactly as the
        /// device made it, so a session running on a device that went away reads as running-but-
        /// unreachable rather than as a session that changed state — a pane can then keep the device's
        /// last frame and say why it is frozen, instead of claiming the session ended.
        ///
        /// Published as a session-scoped notification rather than through the listener fan-out. Listeners
        /// are deliberately never told about a disconnect (see `handleStreamDisconnect`), because the
        /// render host would re-register and accumulate duplicate listeners on the one shared
        /// subscription; a notification observers re-read this property on keeps that hazard out of the
        /// disconnect path entirely, and any number of observers can watch it without touching the
        /// fan-out.
        private(set) var isStateStreamDisconnected = false

        private struct Listener {
            let id: UUID
            let onUpdate: @MainActor (GhosttyRemoteSessionStatePayload) -> Void
            let onDisconnect: @MainActor ((any Error)?) -> Void
        }

        private var listeners: [Listener] = []
        // Paces this session's reconnects. Internal (not `private`) so behavior tests can shorten its
        // delays instead of waiting out real seconds.
        let reconnectBackoff = TerminalStateStreamReconnectBackoff()
        private var streamClient: (any TerminalRemoteStateStreamClient)?
        // The candidate address the installed stream connected on, mirrored here because the stream picks
        // it internally and the protocol the model holds does not carry it. Read only by the corroboration
        // probe, which pins its ping to this address so the answer is about the stream's own path rather
        // than about whichever candidate a race happens to win. Nil whenever no stream is installed, and
        // whenever the installed one is a test double with no host of its own.
        private var streamConnectedHost: String?
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
        // Holds `scheduleReconnect`'s delayed retry so a second call while one is already pending is a
        // no-op instead of stacking a competing timer and doubling the backoff. Both
        // `establishStateStreamConnection`'s own failure paths and the connect-completion check in
        // `ensureSubscriptionStarted` can each decide the same failed connect owes a retry, so
        // `scheduleReconnect` has to tolerate being called twice for one failure. Cleared when the retry
        // fires (or the model is torn down); nothing else clears it early, so a connect that installs a
        // client on its own simply leaves the stale retry to find `streamClient` set and no-op when it runs.
        private var reconnectTask: Task<Void, Never>?

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
                    resolver: SpacesDeviceEndpointRegistry.resolver(for: device, certificateFingerprint: preparedCredentials.certificateFingerprint)),
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
                reconnectTask?.cancel()
                linkCorroborationProbe?.task.cancel()
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

        func pasteImage(_ image: TerminalPasteboardImage, clientID: String, ownerEpoch: UInt64?) async throws -> TerminalControlResponse {
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
                //
                // A coded unauthorized rejection is likewise accepted: the daemon is reachable but the boxed
                // token was revoked (e.g. a pairing-state reset rotated it). Ended sessions get no stream
                // reconnect, so without this the pane's scrollback would fail on every fetch until the pane is
                // recreated. This mirrors the stream-side unauthorized handling in `handleStreamDisconnect`.
                let isLocalPinMismatch: Bool
                if case TerminalServiceTLSError.certificatePinMismatch = error { isLocalPinMismatch = true } else { isLocalPinMismatch = false }
                let isLocalUnauthorizedRejection: Bool
                if case SpacesDeviceClientError.requestRejected(_, .unauthorized) = error {
                    isLocalUnauthorizedRejection = true
                } else {
                    isLocalUnauthorizedRejection = false
                }
                guard device.id == SpacesPairedDeviceRecord.localDeviceID,
                    isLocalPinMismatch || isLocalUnauthorizedRejection || SpacesDeviceClient.isLocalDaemonUnreachableError(error),
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
            sessionID: String, maxBytes: Int, requestClient: SpacesDeviceAPIRequestSessionClient, authToken: String?, clientApp: SpacesDeviceClientApp
        ) throws -> RemoteGhosttyTranscript {
            let request = SpacesDeviceAPIRequest(
                command: .terminalTranscript(SpacesDeviceTerminalTranscriptRequest(sessionID: sessionID, maxBytes: maxBytes)), authToken: authToken,
                clientApp: clientApp)
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
                // Preserve the response's error code so the instance-level recovery can recognize an
                // unauthorized rejection (a revoked local token) and re-bootstrap credentials rather than
                // retrying the doomed send. A nil code is fine; the render host treats any thrown transcript
                // error as transient and retries regardless of case.
                throw SpacesDeviceClientError.requestRejected(message: response.message, code: response.errorCode)
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
            if let replayPayload = replayPayloadForNewListener() { onUpdate(replayPayload) }
            ensureSubscriptionStarted()
            return ListenerHandle(detach: { [weak self] in Task { @MainActor [weak self] in self?.removeListener(id: id) } })
        }

        /// The cached payload as a listener joining mid-stream may consume it.
        ///
        /// The cache is the wire payload, and in steady state the render update on the wire is a delta:
        /// absolute values for the cells that changed and nothing for the rest. A listener registering now
        /// holds no baseline to apply that to, so the delta cannot paint anything — the applier refuses it
        /// outright — and handing it over only starts the listener's render chain with a failure and the
        /// resync round trip that failure costs. So the render update is handed over exactly when it is a
        /// full frame; otherwise the payload is replayed without it, and the render host asks the device
        /// for a full frame when it attaches without one (see `RemoteGhosttySessionHost.attach`).
        ///
        /// Everything else in the payload is still replayed: runtime state, ownership, title, and working
        /// directory are what tell a fresh listener what session it is looking at, and none of them
        /// depends on holding a render baseline. The cache itself is left alone — the delta is still the
        /// state the next payload merges onto for the listeners that do have the baseline for it.
        ///
        /// The classification reads the update's header (`renderUpdateKind`) and never decodes its cells:
        /// this runs on the main actor during listener registration, and a grid decode here is precisely
        /// the work the off-main reduction pipeline exists to keep off it. A blob whose header cannot be
        /// classified is treated as not-a-full-frame and stripped, which is the safe direction — the
        /// listener resyncs rather than being handed something it cannot use.
        private func replayPayloadForNewListener() -> GhosttyRemoteSessionStatePayload? {
            guard let latestRemoteStatePayload else { return nil }
            guard latestRemoteStatePayload.hasRenderUpdate else { return latestRemoteStatePayload }
            guard latestRemoteStatePayload.renderUpdateKind != .full else { return latestRemoteStatePayload }
            return latestRemoteStatePayload.replacingRenderUpdate(nil)
        }

        fileprivate func removeListener(id: UUID) {
            listeners.removeAll { $0.id == id }
            if listeners.isEmpty {
                stateRefreshRetryTask?.cancel()
                stateRefreshRetryTask = nil
            }
        }

        private func ensureSubscriptionStarted(now: Date = Date()) {
            // Test seam: fires on every call, including one the guard below immediately turns away, so
            // `spacesuiTests` can observe a delayed retry actually running (and being eaten by the
            // in-flight guard) instead of guessing whether real time has passed. Nil in production.
            ensureSubscriptionStartedInvokedForTesting?()
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
                guard let self else { return }
                self.subscriptionConnectTask = nil
                // Establishes the invariant a connect that finishes without leaving `streamClient`
                // installed always leaves a retry armed. `establishStateStreamConnection`'s own failure
                // paths already call `scheduleReconnect()` before returning, so this only does new work
                // when the connect reported success (`openStateStream` returned true) while a competing
                // disconnect — e.g. a failed input send racing the connect (`reportFailedInputSend`) —
                // had already cleared `streamClient` and lost its own retry to the
                // `subscriptionConnectTask != nil` guard above, which is still armed for as long as this
                // task is in flight. Without this, that race leaves the pane connected to nothing with no
                // retry coming. `scheduleReconnect()` is idempotent, so the common case — a retry is
                // already pending from one of those failure paths — is a no-op here.
                if self.streamClient == nil { self.scheduleReconnect() }
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
            if await openStateStream() { return }
            // The first connect failed. For the local device this may be a stale port or an idle-shut-down
            // daemon; ensure it is running and re-resolve its current port, then retry. The (possibly
            // rebuilt) request client now targets a running daemon, so re-run the catch-up: an ended
            // session's final render — and every subsequent transcript fetch — must reach the live daemon.
            guard await ensureLocalDeviceReachableForRetry() else {
                scheduleReconnect()
                return
            }
            await reloadCatchUpState()
            if await openStateStream() { return }
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
        @discardableResult private func openStateStream() async -> Bool {
            let request = SpacesDeviceAPIRequest(
                command: .subscribe(SpacesDeviceTerminalSubscriptionRequest(sessionID: sessionID, clientID: nil)),
                authToken: requestClientBox.current.authToken, clientApp: clientApp)
            let resolver = SpacesDeviceEndpointRegistry.resolver(for: device, certificateFingerprint: certificateFingerprint)
            streamClientGeneration &+= 1
            let generation = streamClientGeneration
            let client: SpacesDeviceAPIStateStreamClient
            do {
                client = try SpacesDeviceAPIStateStreamClient(
                    request: request, resolver: resolver,
                    onEvent: { [weak self] payload in Task { @MainActor [weak self] in self?.applyStreamEvent(payload, generation: generation) } },
                    onDisconnect: { [weak self] error in
                        Task { @MainActor [weak self] in self?.handleStreamDisconnect(error, generation: generation) }
                    })
            } catch { return false }
            streamClient = client
            let started: Bool
            if let connectOverrideForTesting = stateStreamConnectOverrideForTesting {
                // Test seam: lets `spacesuiTests` control exactly when and how the blocking connect
                // resolves, so it can reproduce `start()` succeeding for a client a competing disconnect
                // already stopped without racing real network timing. See the property's doc comment.
                started = await connectOverrideForTesting()
            } else {
                started = await Task.detached(priority: .userInitiated) { () -> Bool in
                    do {
                        try client.start()
                        return true
                    } catch { return false }
                }.value
            }
            guard started else {
                // Only clear the installed client if it is still this one; a racing disconnect (or a newer
                // connect) may already have replaced it, and clearing then would drop a healthy stream.
                if streamClient === client {
                    streamClient = nil
                    streamConnectedHost = nil
                }
                client.stop()
                return false
            }
            // A `true` result does not prove this client is still the current one (see the note above), so
            // only a client that is still installed declares the link healthy. Clearing the flag from a
            // client a racing disconnect already tore down would hide an outage that is still on.
            if streamClient === client {
                // Record which candidate address this stream pinned itself to (the concrete client picks
                // one host and keeps it for the life of the connection). The corroboration probe compares
                // its own answering address against this one; see `startLinkCorroborationProbe`.
                streamConnectedHost = client.connectedHost
                reconnectBackoff.reset()
                setStateStreamDisconnected(false)
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
        /// uses, which starts the daemon if it idle-shut-down. The bootstrap is coalesced process-wide
        /// through `LocalDeviceRecoveryBootstrap`, so when a pairing-state reset drops every open local
        /// pane's stream at once, concurrent per-pane recoveries share one bootstrap and install the same
        /// refreshed record and token instead of racing each other's token mints. It rebuilds the persistent
        /// request client when the port, host, certificate fingerprint, or auth token moved so catch-up `.state`,
        /// transcript fetches, and the retried subscribe reach the live daemon under its current identity and
        /// credentials. `bootstrapLocalDevice` presents the stored token so the daemon normally keeps it, but
        /// a daemon whose pairing state was reset mints and persists a fresh token, revoking the one the box
        /// still holds; this reads that persisted token back and rebuilds the box with it, so every vended
        /// sender re-authenticates. The rebuild swings the shared `requestClientBox` (client and token
        /// together), so senders already vended to the render host follow the new client and token. Returns
        /// true when a connect retry is worthwhile: this is the local device and the bootstrap succeeded, so
        /// the daemon is now reachable whether or not it rebound the same port, rotated its certificate, or
        /// rotated its token. Returns false for remote devices — their pinned identity is stable and their
        /// candidate addresses are already re-walked inside the connect itself (`SpacesDeviceEndpointResolver`)
        /// — and when the local bootstrap itself failed (the daemon could not be reached or started).
        ///
        /// Invoked from the connect-time subscribe recovery, the transcript path's local pin-mismatch/
        /// unreachable recovery, and the stream-disconnect path when the local daemon rejected a subscribe as
        /// `.unauthorized` — every case where the daemon is reachable but the pane's pinned identity or boxed
        /// token is stale, and the token refresh above is what re-authenticates the revoked case.
        @discardableResult private func ensureLocalDeviceReachableForRetry() async -> Bool {
            guard device.id == SpacesPairedDeviceRecord.localDeviceID else { return false }
            let clientApp = self.clientApp
            let previousHosts = device.hosts
            let previousPort = device.port
            let previousFingerprint = certificateFingerprint
            let previousToken = requestClientBox.current.authToken
            guard let outcome = await LocalDeviceRecoveryBootstrap.run(clientApp: clientApp) else { return false }
            let refreshed = outcome.record
            // A failed persisted-token read (outer nil) keeps the token the box already holds; a successful
            // read of nil is a legitimate "no token".
            let refreshedToken = outcome.persistedToken ?? previousToken
            let endpointOrIdentityChanged =
                refreshed.port != previousPort || refreshed.hosts != previousHosts || refreshed.certificateFingerprint != previousFingerprint
            // Rebuild on an endpoint/identity move or a token rotation through one branch — a token-only
            // change rebuilds the client too rather than carrying a special-cased in-place token swap.
            if endpointOrIdentityChanged || refreshedToken != previousToken,
                let rebuiltClient = try? SpacesDeviceAPIRequestSessionClient(
                    resolver: SpacesDeviceEndpointRegistry.resolver(for: refreshed, certificateFingerprint: refreshed.certificateFingerprint))
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
            // accumulating duplicates. The model owns reconnection, and publishes the drop
            // itself through `isStateStreamDisconnected` — observable without any listener
            // being notified, so the pane can report the outage while the fan-out stays put.
            // Stop the dropped client before dropping the reference: its pinned-TLS connection is
            // released only by an explicit cancel, so a bare `nil` would orphan the connection and its
            // dispatch queue for the life of the process while the reconnect mints a fresh one.
            let disconnectedClient = streamClient
            streamClient = nil
            streamConnectedHost = nil
            disconnectedClient?.stop()
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

        /// Reports that a terminal input send for this session failed, so the link state follows the
        /// client's own first-hand evidence instead of waiting on the subscription.
        ///
        /// Input travels on a different connection than the state stream. When a network path dies
        /// silently, nothing tears the subscription's socket down until TCP keepalive gives up 60–90
        /// seconds later, but the very next keystroke's request fails immediately — so a failed send is
        /// the earliest proof the device is unreachable, and dropping that evidence leaves the pane
        /// looking live for a minute while every keystroke goes nowhere.
        ///
        /// Only a transport failure qualifies (`isTransportFailureEvidenceOfLostLink`); a reachable
        /// daemon's coded rejection says nothing about the link and does nothing here.
        ///
        /// Returns whether this failure is CONCLUSIVE proof the link is gone — which is also this method's
        /// own `RemoteGhosttyInputFailureHandler` wiring contract: the render host discards its queued
        /// input backlog exactly when this is `true`, and leaves it queued (to keep draining once the link
        /// proves itself live again) when it is `false`.
        ///
        /// A transport failure is not one kind of evidence, and the two kinds get different reactions:
        ///  - a CONNECTION-LEVEL failure (refused, closed, every candidate unreachable) is conclusive that
        ///    the transport itself gave up. It takes the ordinary disconnect reaction immediately — drop
        ///    the subscription and arm the paced reconnect, which flips the disconnected notice — so the
        ///    claim stays falsifiable: the reconnect either succeeds and clears the notice, or keeps
        ///    failing and the notice is right. It returns `true`, so the queued backlog is discarded;
        ///  - a BARE REQUEST TIMEOUT (`SpacesDeviceClient.isDeviceAPIRequestTimeout`) proves only that one
        ///    round trip missed its deadline. On the hot per-keystroke path
        ///    (`interactiveControlRequestTimeoutSeconds`, 5s) a live link misses it routinely: under heavy
        ///    streaming the daemon's serial terminal-engine queue is saturated, so a keystroke's answer can
        ///    genuinely run late with nothing wrong with the link. A silently dead link produces the
        ///    identical timeout, so the timeout alone is inconclusive in both directions. Rather than
        ///    guess, it is CORROBORATED: the subscription is left installed and a single `.ping` probe goes
        ///    out on its own connection, clear of the input path (`startLinkCorroborationProbe`). The daemon answers
        ///    `.ping` unconditionally, without touching the database or the terminal-engine queue, so a
        ///    `pong` means the link is up and the pane keeps its stream with no notice, while a probe that
        ///    brings back no answer from the daemon is the conclusive evidence the timeout was not, and
        ///    takes the same teardown a connection-level failure takes. The timeout itself returns `false`, so the
        ///    keystrokes queued behind it survive a stall the link never actually lost;
        ///  - an already-disconnected link (a retry is already armed, so there is nothing new to do here)
        ///    returns `true` regardless of which shape this repeat failure is — the outage was already
        ///    confirmed by an earlier conclusive failure, a corroborated timeout, or the stream's own
        ///    disconnect, so every keystroke of an ongoing outage, not only the first, must keep dropping
        ///    its queued input rather than buffering behind a link that is not coming back on its own.
        @discardableResult func reportFailedInputSend(_ error: any Error) -> Bool {
            guard Self.isTransportFailureEvidenceOfLostLink(error) else { return false }
            // Typing produces one of these per keystroke for as long as the outage lasts. A link already
            // reported down has a retry armed, so re-reporting it must add no reconnect and no notice.
            guard !isStateStreamDisconnected else { return true }
            guard !SpacesDeviceClient.isDeviceAPIRequestTimeout(error) else {
                startLinkCorroborationProbe()
                return false
            }
            tearDownStreamAndScheduleReconnect()
            return true
        }

        /// The disconnect reaction a conclusive lost link takes: drop the subscription and arm the paced
        /// reconnect (which raises the disconnected notice). Shared by the connection-level failure branch
        /// of `reportFailedInputSend` and the corroboration probe's failed verdict, so both surface an
        /// outage identically.
        private func tearDownStreamAndScheduleReconnect() {
            // Retire this client's generation before stopping it: `stop()` cancels the connection, whose
            // receive loop then delivers one final disconnect callback, and that callback must not arm a
            // second reconnect on top of the one below.
            streamClientGeneration &+= 1
            let deadClient = streamClient
            streamClient = nil
            streamConnectedHost = nil
            deadClient?.stop()
            scheduleReconnect()
        }

        /// Deadline for the corroboration `.ping`, deliberately shorter than both the Device API's 10s
        /// default and the 5s interactive deadline that produced the timeout being corroborated. The probe
        /// only has to learn whether the daemon's listener still answers a request that does no work, so a
        /// long deadline would only stretch how long a genuinely dead link keeps looking live.
        private nonisolated static let linkCorroborationProbeTimeoutSeconds: TimeInterval = 2

        /// The in-flight corroboration probe and the stream generation it was started for. Typing produces
        /// one timeout per keystroke, so without a single-flight rule a stalled daemon would be probed once
        /// per keystroke; the first probe's verdict answers for all of them.
        ///
        /// Keyed by generation rather than by mere presence: a probe is only an answer about the stream it
        /// was started under, and its verdict is discarded when that stream is gone. A timeout on a stream
        /// installed after the probe went out therefore has to be corroborated on its own, so it starts a
        /// probe of its own instead of being silently answered by one whose verdict can no longer apply.
        /// The superseded probe is left to run itself out; nothing acts on it.
        private var linkCorroborationProbe: (generation: UInt64, task: Task<Void, Never>)?

        /// Sends `.ping` to decide whether a bare input-send timeout was a saturated daemon or a dead link,
        /// and applies the verdict:
        ///  - the pinned daemon decoded the request and answered it (a `pong`, or a coded rejection — the
        ///    link carried a request there and an answer back): the link is up, so the stream is left
        ///    exactly as it is and no notice is raised;
        ///  - anything else, whether or not it classifies as a transport failure: the link did not deliver
        ///    an answer, so it takes the same teardown a connection-level failure takes.
        ///
        /// The question the probe has to answer is not "is this device reachable" but "is the address this
        /// pane's stream depends on still answering". On a device with several candidate addresses those
        /// differ: the ping is therefore pinned to `streamConnectedHost`, the address the stream connected
        /// on, and races nothing. A raced ping would prove nothing about the stream in either direction —
        /// with both the LAN and the tailnet path up it can be answered on the address the stream is NOT
        /// on, and a stream sitting on a path that just died would be torn down (or spared) on the strength
        /// of an answer from somewhere else entirely.
        ///
        /// The verdict is scoped to the stream generation the probe was started under: if the stream was
        /// replaced or torn down meanwhile, a late verdict says nothing about the stream now installed and
        /// is dropped rather than tearing down a healthy replacement.
        ///
        /// Treating a missed probe as conclusive leans on the daemon answering `.ping` off its
        /// engine-blocked queues (`SpacesDeviceAPIServer.runsOnTerminalControlQueue`). Against a daemon
        /// predating that divert, saturation stalls the ping too and the verdict reproduces the
        /// bare-timeout teardown this probe replaces — the same banner the old client raised, two seconds
        /// later. Accepted rather than gated on a daemon-reported capability: clients and daemons ship in
        /// lockstep with no compatibility guarantees yet, and the mixed pairing merely degrades to the
        /// pre-probe behavior instead of anything worse.
        private func startLinkCorroborationProbe() {
            let generation = streamClientGeneration
            guard linkCorroborationProbe?.generation != generation else { return }
            let probe = linkCorroborationProbeForTesting ?? makeLinkCorroborationPingProbe()
            let pinnedHost = streamConnectedHost
            let task = Task { @MainActor [weak self] in
                let probeError = await probe(pinnedHost)
                guard let self else { return }
                // Release the slot only if it still holds THIS probe: a newer generation's probe may have
                // taken it while this one was out, and clearing that would let the next timeout start a
                // duplicate probe for a generation already being corroborated.
                if self.linkCorroborationProbe?.generation == generation { self.linkCorroborationProbe = nil }
                guard generation == self.streamClientGeneration else { return }
                guard !Self.isAnswerFromTheDaemon(probeError) else { return }
                self.tearDownStreamAndScheduleReconnect()
            }
            linkCorroborationProbe = (generation, task)
        }

        /// The real probe: a `.ping` on its own one-shot pinned-TLS connection, run off the main actor
        /// because both the connect and the send block. Returns the thrown error, or nil when the daemon
        /// answered at all. `pinnedHost` is the address the stream is connected on: the ping is aimed at
        /// exactly that candidate, so a failure is evidence about the stream's own address rather than
        /// about the device. It is also reported to the resolver as a stream failure, which steers the
        /// teardown's redial past the dead address instead of retrying it first. Only a stream whose
        /// address is unknown falls back to racing the candidates.
        ///
        /// It deliberately does NOT go through this session's shared `SpacesDeviceAPIRequestSessionClient`.
        /// That client serializes every request behind one lock and takes the lock BEFORE starting the
        /// per-operation deadline, so waiting for the lock is unbounded. The timeout that triggers this
        /// probe leaves the pane's input backlog queued and draining (the report answered `false`), and on
        /// a blackholed link every queued keystroke holds that lock for its full 5s interactive deadline in
        /// turn — with no fairness guarantee about who gets it next. A probe behind that backlog could wait
        /// out the entire outage, leaving the dead pane looking live: precisely the case the probe exists
        /// to catch. A one-shot client dials its own connection through the same shared endpoint resolver
        /// (so it reports failures back to the same place), and its timeout covers connect, send, and read
        /// with nothing queued ahead of it.
        ///
        /// The auth token still comes from the shared box, read here on the main actor: the box's own lock
        /// guards nothing but the client/token pair, so reading it never waits on a request.
        private func makeLinkCorroborationPingProbe() -> @MainActor (String?) async -> (any Error)? {
            let clientApp = self.clientApp
            let device = self.device
            let certificateFingerprint = self.certificateFingerprint
            let authToken = requestClientBox.current.authToken
            return { pinnedHost in
                await Task.detached(priority: .userInitiated) { () -> (any Error)? in
                    do {
                        let probeClient = try SpacesDeviceAPIRequestClient(
                            resolver: SpacesDeviceEndpointRegistry.resolver(for: device, certificateFingerprint: certificateFingerprint),
                            timeoutSeconds: Self.linkCorroborationProbeTimeoutSeconds)
                        _ = try probeClient.request(
                            SpacesDeviceAPIRequest(command: .ping, authToken: authToken, clientApp: clientApp), pinnedHost: pinnedHost)
                        return nil
                    } catch { return error }
                }.value
            }
        }

        /// Overrides the `.ping` corroboration probe, so `spacesuiTests` can resolve it as a success, a
        /// transport failure, or a coded rejection on demand instead of standing up a daemon that stalls
        /// and then dies. It receives the address the real probe would pin to, so a test can also assert
        /// the probe is aimed at the stream's own address. Nil in production, where the real probe always
        /// runs. Mirrors `stateStreamConnectOverrideForTesting`.
        var linkCorroborationProbeForTesting: (@MainActor (String?) async -> (any Error)?)?

        /// Awaits the in-flight corroboration probe and its verdict, so a test can observe the outcome
        /// deterministically instead of polling. A no-op when no probe is running.
        func drainPendingLinkCorroborationProbeForTesting() async { await linkCorroborationProbe?.task.value }

        /// Whether a corroboration probe is in flight; `spacesuiTests` uses it to prove a second timeout
        /// arriving during one does not spawn a competing probe.
        var hasInFlightLinkCorroborationProbeForTesting: Bool { linkCorroborationProbe != nil }

        /// Whether the corroboration probe's outcome is an answer from the daemon this session is pinned
        /// to. The verdict is a whitelist, not the transport-failure classification below, because the
        /// question the probe asks is narrow: did the trusted daemon decode this request and answer it?
        /// Only two outcomes say yes — no error at all, and a coded rejection, which is a decoded response
        /// the daemon composed. Everything else is a failed probe: a certificate pin mismatch (rotation, or
        /// the only reachable candidate presenting a different identity) means nothing authenticated as
        /// this daemon answered, and an unclassified or malformed-response error means nothing legible came
        /// back. Read through the blacklist below instead, those would count as a live link and leave a
        /// dead pane looking healthy until the stream's own socket timeout eventually notices.
        ///
        /// The `.requestRejected` branch carries the semantics rather than the production path: the
        /// one-shot client returns an `ok: false` response without throwing, so in production a rejection
        /// arrives as a successful `request()` call. The branch is what makes "a rejection is an answer"
        /// explicit, and `spacesuiTests` resolves the probe with one to hold that contract.
        nonisolated static func isAnswerFromTheDaemon(_ probeError: (any Error)?) -> Bool {
            guard let probeError else { return true }
            if case SpacesDeviceAPIRequestClientError.requestRejected = probeError { return true }
            return false
        }

        /// Whether a failed request is evidence about this session's link at all — true for any transport
        /// failure, timeout included: the request never demonstrably reached and was answered by the
        /// daemon. This is the broad classification that gates `reportFailedInputSend` doing anything at
        /// all; it does NOT by itself say the link is conclusively down — see `reportFailedInputSend`'s own
        /// doc for the finer distinction between a bare timeout (corroborated by a `.ping` before anything
        /// is torn down) and a connection-level failure (conclusive on its own). The probe's own verdict is
        /// read through `isAnswerFromTheDaemon` instead, which is stricter on purpose.
        ///
        /// A reachable daemon that answers with a coded rejection — the session is not running, another
        /// client owns it, the token was revoked — says nothing about the link, and reporting one as a
        /// dropped connection would put a false notice on the pane and dial a device that is answering.
        /// The classification is `SpacesDeviceClient`'s, shared with the reachability degrade the sidebar
        /// uses, so "the transport failed" means one thing across the app; a rejection the render host has
        /// already flattened into an opaque message error is not a transport failure by type and stays out
        /// without any message matching.
        nonisolated static func isTransportFailureEvidenceOfLostLink(_ error: any Error) -> Bool {
            SpacesDeviceClient.isDeviceAPITransportFailure(error)
        }

        /// Applies a live stream event only when it belongs to the current stream generation, so a
        /// superseded client cannot feed state after replacement. Catch-up `.state` responses bypass this
        /// and call `apply` directly — they carry no generation and their staleness is handled by
        /// `apply`'s emission-time guard.
        ///
        /// Internal (not `private`) for the same reason as `handleStreamDisconnect`: the concrete stream
        /// client offers no seam to force callback orderings, so `spacesuiTests` installs clients via
        /// `installStreamClientForTesting` and calls this with a chosen generation — which is the only way
        /// to prove that the one-shot delivery `apply` performs ahead of its staleness guard is still
        /// refused for a superseded client.
        func applyStreamEvent(_ payload: GhosttyRemoteSessionStatePayload, generation: UInt64) {
            guard generation == streamClientGeneration else { return }
            apply(payload)
        }

        // Test seams mirroring `openStateStream`'s install semantics. The concrete stream client offers no
        // protocol seam to force callback orderings, so `spacesuiTests` drives the generation guard through
        // these instead of racing a real connect.
        /// `connectedHost` stands in for the address the concrete client would have pinned itself to, so a
        /// test can drive the probe's host correlation without a multi-address daemon.
        @discardableResult func installStreamClientForTesting(
            _ client: any TerminalRemoteStateStreamClient, connectedHost: String? = nil
        ) -> UInt64 {
            streamClientGeneration &+= 1
            streamClient = client
            streamConnectedHost = connectedHost
            return streamClientGeneration
        }

        var hasActiveStreamClientForTesting: Bool { streamClient != nil }

        /// Overrides the blocking pinned-TLS connect `openStateStream` normally runs in a detached task,
        /// so a test can control exactly when and how it resolves instead of racing real network timing.
        /// `spacesuiTests` uses it to reproduce the connect-vs-disconnect race the post-connect check in
        /// `ensureSubscriptionStarted` guards against: resolving the connect only after a competing
        /// `reportFailedInputSend` has already cleared `streamClient` reproduces `start()` succeeding for
        /// a client that was concurrently stopped, deterministically. Nil in production, where the real
        /// detached connect always runs.
        var stateStreamConnectOverrideForTesting: (@MainActor () async -> Bool)?

        /// See the call site in `ensureSubscriptionStarted`.
        var ensureSubscriptionStartedInvokedForTesting: (@MainActor () -> Void)?

        /// The delay `scheduleReconnect` last actually armed a retry with, or nil once that retry has
        /// fired. A call that no-ops because a retry is already pending leaves this untouched, so
        /// `spacesuiTests` can prove a competing call never stacks a second timer or silently doubles the
        /// backoff on top of the one already armed.
        private(set) var lastReconnectDelayForTesting: Duration?

        /// Whether a delayed reconnect is currently armed and waiting to fire.
        var hasArmedReconnectForTesting: Bool { reconnectTask != nil }

        /// Awaits the in-flight connect `ensureSubscriptionStarted` started, if any, so a test can observe
        /// its outcome deterministically instead of polling.
        func drainPendingConnectForTesting() async { await subscriptionConnectTask?.value }

        /// Awaits an armed reconnect through its (test-shortened) backoff delay and the connect it starts,
        /// so a test can drive a real retry to completion deterministically instead of polling or sleeping
        /// out the interval. A no-op when no reconnect is armed.
        func drainPendingReconnectForTesting() async {
            guard let reconnectTask else { return }
            await reconnectTask.value
            await subscriptionConnectTask?.value
        }

        /// Re-subscribes after a backoff delay — only while the session may still be interactive and
        /// listeners remain. An ended session needs no live stream, so it is left disconnected, and it is
        /// also not reported as disconnected: the daemon streams live sessions only, so refusing an ended
        /// one is the expected answer rather than a link the user should be told about.
        ///
        /// The delay grows with the run of failures (`reconnectBackoff`) instead of retrying flat forever:
        /// a pane outlives its device going away, and a fixed cadence is a reconnect storm against a device
        /// that is genuinely down. Marking the link down here rather than in `handleStreamDisconnect` keeps
        /// the flag meaning exactly what the banner tells the user — the connection dropped and a retry is
        /// coming.
        ///
        /// Idempotent while a retry is already pending (`reconnectTask != nil`): more than one caller can
        /// decide the same failed connect owes a retry (see the connect-completion check in
        /// `ensureSubscriptionStarted`), and a second call here must not stack a competing timer or double
        /// the backoff on top of the one already armed.
        private func scheduleReconnect() {
            guard reconnectTask == nil else { return }
            guard !listeners.isEmpty, currentRuntimeState?.state.isInteractive != false else { return }
            setStateStreamDisconnected(true)
            let delay = reconnectBackoff.nextDelay()
            lastReconnectDelayForTesting = delay
            reconnectTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: delay)
                guard let self else { return }
                self.reconnectTask = nil
                guard self.streamClient == nil, !self.listeners.isEmpty, self.currentRuntimeState?.state.isInteractive != false else { return }
                self.lastSubscriptionAttemptAt = nil
                self.ensureSubscriptionStarted()
            }
        }

        /// Publishes a change in link state to this session's observers. Posted only on a flip, so a
        /// persistently down device does not wake every pane on every retry.
        private func setStateStreamDisconnected(_ isDisconnected: Bool) {
            guard isStateStreamDisconnected != isDisconnected else { return }
            isStateStreamDisconnected = isDisconnected
            TerminalSessionNotification.post(.spacesTerminalStateStreamConnectionDidChange, sessionID: sessionID)
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
            // A clipboard write is a one-shot EVENT, not state, so it is fanned out ahead of the
            // emission-time guard below and never subjected to it. The catch-up `.state` request runs on
            // its own connection in parallel with the live subscription, so a response served after the
            // event was emitted can still be installed before the event arrives here — and a state-ordering
            // rule discarding the event would lose the user's copy permanently, with nothing to redeliver
            // it. Ordering is meaningless for it anyway: the payload is addressed to one client and applied
            // once, so applying it from an "older" event is always right.
            //
            // Nothing here is advanced by it, and it never becomes cached state: the reason exports no
            // screen state, and the runtime/attachment snapshot it repeats was already delivered by the
            // output turn that carried the escape sequence. The generation guard still applies — this runs
            // downstream of `applyStreamEvent`, so an event from a superseded stream client never gets here.
            //
            // Ordering between clipboard events themselves inherits the transport's dispatch: each decoded
            // stream line hops to the main actor in its own task, so two copies emitted within the same
            // instant can apply reversed, leaving the older text until the next copy. Accepted — the
            // window is per-line task scheduling, the result self-corrects, and closing it means an
            // ordered drain across the whole stream transport for a race no state payload can hit
            // (those carry timestamps and tolerate reordering by design).
            if payload.reason == TerminalRemoteSessionStateReason.clipboardWrite {
                for listener in listeners { listener.onUpdate(payload) }
                return
            }
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

        /// Deadline for the interactive control commands on the hot per-keystroke path (typed input, key,
        /// scroll, resize, clear-screen), used in place of the Device API's 10s default. Measured healthy
        /// sends over the tailnet relay run 0.7-1.5s, so 5s keeps well over 3x headroom while halving the
        /// worst-case stall a keystroke would otherwise wait out on a dead link.
        ///
        /// This deadline gates how fast a keystroke typed into a dead pane reports as failed (see
        /// `RemoteGhosttySessionHost.reportInputFailure`). It does not by itself decide anything about the
        /// pane's link or its queued input backlog: a bare timeout at this deadline neither discards the
        /// backlog nor surfaces the disconnect notice, because a saturated daemon misses it on a perfectly
        /// live link. `reportFailedInputSend` corroborates the timeout with a `.ping` first, and only a
        /// probe that also fails at the transport tears the subscription down and raises the notice. That
        /// is what makes this deadline safe to keep tight: a false alarm at it costs one extra `.ping`
        /// round trip, not dropped keystrokes and a false banner. Re-measure actual send latency before
        /// tightening it further all the same, since every miss still costs that probe.
        nonisolated static let interactiveControlRequestTimeoutSeconds: TimeInterval = 5

        /// Whether `request` is one of the interactive control commands that ride the hot per-keystroke
        /// path and so use `interactiveControlRequestTimeoutSeconds` in place of the default. Attach,
        /// detach, heartbeat, takeover, and appearance changes are infrequent session-management calls
        /// made off that path and keep the default deadline.
        private nonisolated static func isInteractiveControlCommand(_ request: TerminalControlRequest) -> Bool {
            switch TerminalControlCommand(request: request) {
            case .send, .key, .clearScreen, .resize, .scroll, .mouseButton: true
            case .attach, .detach, .heartbeat, .takeover, .setAppearance, .unsupported: false
            }
        }

        /// The deadline `sendTerminalServiceRequest` uses for a `.control` command's Device API send:
        /// `interactiveControlRequestTimeoutSeconds` for the hot per-keystroke commands,
        /// `SpacesDeviceClient`'s own per-command default for everything else. Pulled out as its own pure
        /// function (not `private`) so `spacesuiTests` can assert the split deterministically — no real
        /// send, no waiting out either deadline — instead of only through an integration test that would
        /// have to time out for real to observe which one was used.
        nonisolated static func controlRequestTimeoutSeconds(for controlRequest: TerminalControlRequest, command: SpacesDeviceAPICommand)
            -> TimeInterval
        {
            isInteractiveControlCommand(controlRequest)
                ? interactiveControlRequestTimeoutSeconds : SpacesDeviceClient.requestTimeoutSeconds(for: command)
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
                let controlAPIRequest = SpacesDeviceAPIRequest(command: .terminalControl(deviceRequest), authToken: authToken, clientApp: clientApp)
                let timeoutSeconds = Self.controlRequestTimeoutSeconds(for: payload.controlRequest, command: controlAPIRequest.command)
                let response = try requestClient.send(controlAPIRequest, timeoutSeconds: timeoutSeconds)
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
