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

        /// The connection-stage state machine backing this session's banner: live, lost and quietly
        /// retrying (stage 1, "Reconnecting…" once a short grace elapses), or confirmed unreachable
        /// across every known candidate address (stage 2, "Device unreachable" with Retry). Shared with
        /// iOS through `TerminalConnectionStageTracker`, which is timer-free by design; this model owns
        /// every timer that steps it (the grace timer here, and the redial tasks further below).
        ///
        /// Kept out of `currentRuntimeState` deliberately, for the same reason as before this tracker
        /// existed: the device's last report stays exactly as the device made it, so a session running on
        /// a device that went away reads as running-but-unreachable rather than as a session that changed
        /// state: a pane can then keep the device's last frame and say why it is frozen, instead of
        /// claiming the session ended.
        ///
        /// Published as a session-scoped notification rather than through the listener fan-out. Listeners
        /// are deliberately never told about a disconnect (see `handleStreamDisconnect`), because the
        /// render host would re-register and accumulate duplicate listeners on the one shared
        /// subscription; a notification observers re-read this property on keeps that hazard out of the
        /// disconnect path entirely, and any number of observers can watch it without touching the
        /// fan-out. Notified only when a mutation actually flips the stage or the banner's visibility
        /// (see `applyStageTransition`), never on a call that leaves both unchanged: a persistently down
        /// device must not wake every pane on every retry.
        private(set) var connectionStageTracker = TerminalConnectionStageTracker()

        /// True while the model wants a live subscription for this session but does not have one: the
        /// stream dropped or a connect failed and a retry is armed (see `scheduleReconnect`). Required by
        /// `TerminalSessionStateProviding`; derived from `connectionStageTracker` so this coarse bit and
        /// the pane's finer stage/banner reads can never disagree.
        var isStateStreamDisconnected: Bool { connectionStageTracker.stage != .connected }

        // Owns the grace timer between a stream loss and the "Reconnecting…" banner actually showing
        // (`TerminalConnectionNotice.bannerGraceSeconds`), so a blip that heals within the grace never
        // paints anything. Cancelled the instant the outage resolves or escalates past needing it.
        private var graceTask: Task<Void, Never>?
        // Overrides the grace timer's delay for tests, mirroring `reconnectBackoff`'s test-mutable knobs.
        // Internal (not `private`) so behavior tests can shorten it instead of waiting out a real second.
        var graceDelayForTesting: Duration?

        private struct Listener {
            let id: UUID
            let onUpdate: @MainActor (GhosttyRemoteSessionStatePayload) -> Void
            let onDisconnect: @MainActor ((any Error)?) -> Void
        }

        private var listeners: [Listener] = []
        // Handles for listeners registered through `startStateStream`, which returns none to its caller.
        private var retainedListenerHandles: [ListenerHandle] = []
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
        // The generation the client currently in `streamClient` was installed under, or nil while none is
        // installed. Moves with `streamClient` only (see `installStreamClient`/`clearInstalledStreamClient`),
        // which is what makes it a safe answer to "did this disconnect come from the stream we hold?" —
        // `streamClientGeneration` alone is not, because it is bumped before a client is installed and again
        // when one is retired, so comparing against it can reject a drop from the very client still
        // installed and leave it there dead forever (issue #537).
        private var installedStreamClientGeneration: UInt64?
        // Owns the liveness recheck a stream loss starts when the cached runtime state claims the session
        // needs no stream (see `recheckLivenessAfterStreamLoss`). One task, which both asks and waits, so
        // there is a single place the question can be open and no second timer can pace it.
        private var livenessRecheckTask: Task<Void, Never>?
        // Identifies which recheck owns `livenessRecheckTask`, so a cancelled one that is still suspended in
        // its own request cannot clear the slot out from under its replacement (see `finishLivenessRecheck`).
        private var livenessRecheckGeneration: UInt64 = 0
        private var lastSubscriptionAttemptAt: Date?
        private var refreshInFlight = false
        private var stateRefreshRetryTask: Task<Void, Never>?
        // Owns the off-main connect for the live subscription. The pinned-TLS connect blocks on a
        // semaphore, so it must never run on the main actor; while a connect is in flight this guards
        // `ensureSubscriptionStarted` from starting a second one.
        private var subscriptionConnectTask: Task<Void, Never>?
        // Identifies one connect attempt end to end, from `ensureSubscriptionStarted()` through
        // `establishStateStreamConnection()`'s two `openStateStream()` dials. `client.start()`'s blocking
        // dial runs on a detached task with no structured-concurrency link to `subscriptionConnectTask`, so
        // cancelling that task (as `retryStateStreamConnection()` does) does not stop an abandoned dial from
        // finishing: it keeps running, and `establishStateStreamConnection()`'s `await`s around it keep
        // resuming and executing to completion regardless. Bumped whenever a new attempt starts
        // (`ensureSubscriptionStarted()`) or an in-flight one is retired (`retryStateStreamConnection()`),
        // and captured by the attempt's own closures. Every state mutation the attempt's body makes after
        // resuming from an `await` (scheduling a reconnect, clearing `subscriptionConnectTask`, moving the
        // connection-stage tracker) is gated on this generation still matching, so a superseded attempt's
        // belated completion is dropped instead of clobbering the replacement that took its place.
        private var connectAttemptGeneration: UInt64 = 0
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

        nonisolated static func resolveCredentials(context: DeviceRequestContext) throws -> PreparedCredentials {
            let credentials = try SpacesDeviceClient.credentialsEnsuringLocalRecovery(context: context)
            return PreparedCredentials(certificateFingerprint: credentials.certificateFingerprint, authToken: credentials.authToken)
        }

        deinit {
            guard Thread.isMainThread else { return }
            MainActor.assumeIsolated {
                streamClient?.stop()
                stateRefreshRetryTask?.cancel()
                subscriptionConnectTask?.cancel()
                reconnectTask?.cancel()
                livenessRecheckTask?.cancel()
                graceTask?.cancel()
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

        /// The handle is retained by the model because this protocol entry point hands the caller nothing to
        /// stop with: the listener it registers lives as long as the model does. `ListenerHandle` detaches on
        /// release as well as on `stop()`, so without the retain the handle would be freed on return and
        /// take the listener just registered with it.
        func startStateStream(
            onUpdate: @escaping @MainActor (GhosttyRemoteSessionStatePayload) -> Void, onDisconnect: @escaping @MainActor ((any Error)?) -> Void
        ) { retainedListenerHandles.append(registerListener(onUpdate: onUpdate, onDisconnect: onDisconnect)) }

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
                // Nothing is left to show an answer to, so stop asking rather than letting the recheck
                // poll out its current backoff against a session no one is watching.
                livenessRecheckTask?.cancel()
                livenessRecheckTask = nil
            }
        }

        /// Installs `client` as the session's live subscription, recording the generation it was created
        /// under. Every install goes through here so `installedStreamClientGeneration` can never drift from
        /// the client it describes; `handleStreamDisconnect` decides ownership of a drop by comparing
        /// against it.
        private func installStreamClient(_ client: any TerminalRemoteStateStreamClient, generation: UInt64) {
            streamClient = client
            installedStreamClientGeneration = generation
        }

        /// Detaches the installed subscription and returns it so the caller can stop it. The stop is the
        /// caller's because its timing differs by path (before or after arming a reconnect), but the state
        /// it leaves behind must not: nothing else clears `streamClient`.
        @discardableResult private func clearInstalledStreamClient() -> (any TerminalRemoteStateStreamClient)? {
            let installedClient = streamClient
            streamClient = nil
            installedStreamClientGeneration = nil
            streamConnectedHost = nil
            return installedClient
        }

        /// Called after a connect attempt's dial succeeds, to decide what becomes of the client it
        /// produced: recorded as the live stream's connected host when it is still the one installed, or
        /// stopped when it is not. A dial that resolves after its attempt was superseded (Retry, or a
        /// newer attempt that already installed its own client, see `connectAttemptGeneration`) still
        /// holds a real, connected subscription to the daemon; leaving it alone would leak that connection.
        ///
        /// Internal (not `private`) for the same reason as `handleStreamDisconnect`/`applyStreamEvent`
        /// below: the concrete stream client offers no seam to force this ordering through a real connect,
        /// so `spacesuiTests` calls it directly with a `FakeStreamClient` to prove the superseded case
        /// stops rather than installs.
        func finishSuccessfulConnect(_ client: any TerminalRemoteStateStreamClient, connectedHost: String?) {
            if streamClient === client {
                streamConnectedHost = connectedHost
            } else {
                client.stop()
            }
        }

        private func ensureSubscriptionStarted(now: Date = Date()) {
            // Test seam: fires on every call, including one the guard below immediately turns away, so
            // `spacesuiTests` can observe a delayed retry actually running (and being eaten by the
            // in-flight guard) instead of guessing whether real time has passed. Nil in production.
            ensureSubscriptionStartedInvokedForTesting?()
            if streamClient != nil || subscriptionConnectTask != nil { return }
            if let lastSubscriptionAttemptAt, now.timeIntervalSince(lastSubscriptionAttemptAt) < 0.5 {
                // The throttle paces attempts; it must never be the reason a session is left with listeners
                // and nothing arranging a stream for them. A pane whose last listener left and whose
                // replacement registers inside this window would otherwise land exactly there — the removal
                // cancelled the liveness recheck, and this return would drop the new listener's attempt with
                // nothing scheduled behind it. Hand the attempt to the paced retry instead of losing it.
                if reconnectTask == nil, livenessRecheckTask == nil { scheduleReconnect() }
                return
            }
            lastSubscriptionAttemptAt = now
            // Catch up unconditionally, before (and independent of) the subscribe below.
            // The daemon only streams live sessions, so an ended session's subscribe is
            // rejected — but its `.state` response still carries the final render the host
            // needs, and that response must be applied even when no live stream attaches.
            refreshState()
            connectAttemptGeneration &+= 1
            let attemptGeneration = connectAttemptGeneration
            subscriptionConnectTask = Task { @MainActor [weak self] in
                await self?.establishStateStreamConnection(generation: attemptGeneration)
                // A superseded attempt (retired by `retryStateStreamConnection()` while its dial was still
                // in flight) reaches here too: the detached dial task it awaited has no
                // structured-concurrency link to this task, so cancelling `subscriptionConnectTask` above
                // does not stop it from resuming and running this closure to completion. Dropping it here
                // is what keeps it from clearing `subscriptionConnectTask` (which by now belongs to the
                // attempt that superseded it) or deciding this session needs a reconnect it has no business
                // arming.
                guard let self, attemptGeneration == self.connectAttemptGeneration else { return }
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
        ///
        /// `generation` is this attempt's `connectAttemptGeneration`, captured by the caller before the
        /// first `await`. Every decision this method makes below an `await` is gated on that generation
        /// still being current: `client.start()`'s blocking dial (inside `openStateStream`) runs on a
        /// detached task with no structured-concurrency link to `subscriptionConnectTask`, so
        /// `retryStateStreamConnection()` cancelling that task does not stop an abandoned dial from
        /// resuming here. Without the gate, a stale attempt's belated failure would still reach
        /// `scheduleReconnect(after:)` and mark the tracker unreachable over a replacement's already-healthy
        /// stream.
        private func establishStateStreamConnection(generation: UInt64) async {
            guard generation == connectAttemptGeneration else { return }
            if streamClient != nil { return }
            let firstAttempt = await openStateStream()
            guard generation == connectAttemptGeneration else { return }
            if case .connected = firstAttempt { return }
            // The first connect failed. For the local device this may be a stale port or an idle-shut-down
            // daemon; ensure it is running and re-resolve its current port, then retry. The (possibly
            // rebuilt) request client now targets a running daemon, so re-run the catch-up: an ended
            // session's final render — and every subsequent transcript fetch — must reach the live daemon.
            //
            // The local-device bootstrap is why the "every candidate refused to dial" evidence in
            // `firstAttempt` is deliberately not acted on here: a single-candidate local device would
            // otherwise read as stage 2 unreachable on its very first routine idle-daemon restart, before
            // this bootstrap even gets a chance to run. Only the final attempt's evidence below decides
            // escalation. For a remote device `ensureLocalDeviceReachableForRetry()` always returns false
            // immediately, so this collapses to `firstAttempt` deciding it, same as before this bootstrap.
            let localDeviceRecoverable = await ensureLocalDeviceReachableForRetry()
            guard generation == connectAttemptGeneration else { return }
            guard localDeviceRecoverable else {
                scheduleReconnect(after: firstAttempt)
                return
            }
            await reloadCatchUpState()
            guard generation == connectAttemptGeneration else { return }
            let secondAttempt = await openStateStream()
            guard generation == connectAttemptGeneration else { return }
            if case .connected = secondAttempt { return }
            // A transient subscribe failure on a live session would otherwise strand existing listeners
            // with only the one-shot catch-up and no live updates, because the render host has already
            // taken its `ListenerHandle` and will not ask to subscribe again. Schedule the same
            // model-owned retry the disconnect path uses.
            scheduleReconnect(after: secondAttempt)
        }

        /// The outcome of one attempt to open the live subscription stream, distinguishing the specific
        /// evidence that escalates the connection banner to stage 2 ("Device unreachable") from every
        /// other failure, which keeps the ordinary stage 1 reconnect cadence. See
        /// `TerminalConnectionStageTracker`.
        private enum StateStreamConnectResult {
            case connected
            /// True only when the resolver has now tried every one of this device's candidate addresses
            /// across successive stream attempts and every one refused to dial: the specific hard
            /// evidence stage 2 requires (`SpacesDeviceAPIStateStreamClient.lastDialExhaustedAllCandidates`,
            /// itself sourced from `SpacesDeviceEndpointResolver.noteStreamFailed(host:)`'s return value).
            /// A single timed-out or refused attempt against a device with untried candidates left is
            /// `false`, as is a construction-time failure that never reached the network.
            case failed(allCandidatesUnreachable: Bool)
        }

        /// Opens and starts the subscription stream, running the blocking `start()` connect in a detached
        /// task so its semaphore wait never lands on the main actor. Returns `.connected` when `start()`
        /// succeeded, `.failed` on a construction or connect/handshake failure.
        ///
        /// The client is installed as `streamClient` before `start()` runs: `start()` returns after merely
        /// sending the subscribe request, so a server rejection arrives as a later response line whose
        /// `onDisconnect` can reach the main actor before this function resumes. Installing first means that
        /// racing disconnect finds the client installed and clears it through the disconnect path (which
        /// owns reconnect), instead of clearing nothing and letting the resumption store a dead client that
        /// would block every future reconnect. A `.connected` result therefore does not guarantee the
        /// installed client is still current: a racing disconnect may already have cleared and rescheduled
        /// it, only that the disconnect path has taken over its lifecycle.
        ///
        /// Deliberately does not touch the connection-stage tracker or `reconnectBackoff` on success: those
        /// declare the connection *proven* healthy, which happens once a frame actually arrives over the
        /// new stream (`applyStreamEvent`), not merely once `start()` returns.
        private func openStateStream() async -> StateStreamConnectResult {
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
            } catch { return .failed(allCandidatesUnreachable: false) }
            installStreamClient(client, generation: generation)
            let started: Bool
            // Captured before running the override below: the override closure is free to clear
            // `stateStreamConnectOverrideForTesting` itself (some tests do, to simulate a one-shot
            // connect), so reading the property again after the call would not reliably say which path
            // ran.
            let usingConnectOverrideForTesting = stateStreamConnectOverrideForTesting != nil
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
                if streamClient === client { clearInstalledStreamClient() }
                client.stop()
                // The verdict has to come from the failed dial itself, not a fresh query against the
                // resolver: with one resolver shared per device across every pane's stream, another
                // pane's `nextStreamHost()` call can reset the resolver's failed-host set between this
                // dial's own `noteStreamFailed(host:)` (inside `start()`) and a query made here, which
                // would silently swallow real "every candidate is down" evidence.
                // `client.lastDialExhaustedAllCandidates` is captured atomically with that recording, so
                // it cannot be raced out from under this read. `stateStreamConnectOverrideForTesting`
                // bypasses `start()` entirely, so tests drive the equivalent verdict through
                // `lastDialExhaustedAllCandidatesForTesting` instead.
                let allCandidatesUnreachable = usingConnectOverrideForTesting ? lastDialExhaustedAllCandidatesForTesting : client.lastDialExhaustedAllCandidates
                return .failed(allCandidatesUnreachable: allCandidatesUnreachable)
            }
            // A `.connected` result does not prove this client is still the current one (see the note
            // above): a racing disconnect, Retry, or a newer connect attempt may have superseded it while
            // the blocking dial above (which has no structured-concurrency link to the attempt that
            // started it, and so keeps running even after that attempt is retired, see
            // `connectAttemptGeneration`) was in flight. `finishSuccessfulConnect` records the connected
            // host (the address this stream pinned itself to; the corroboration probe compares its own
            // answering address against it, see `startLinkCorroborationProbe`) for a client that is still
            // installed, and stops one that is not rather than leaving it connected and forgotten.
            finishSuccessfulConnect(client, connectedHost: client.connectedHost)
            return .connected
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
            // A drop is this model's to react to exactly when it came from the client the model currently
            // holds. That is deliberately compared against the INSTALLED client's generation rather than the
            // newest generation issued: a superseded client's late disconnect must still not tear down the
            // client that replaced it, but a generation that moved on without replacing anything must not
            // turn away a drop from the stream still installed either — that leaves a dead client in place,
            // and `ensureSubscriptionStarted` reads any installed client as a live subscription, so the pane
            // would never resubscribe and never report the outage (issue #537).
            guard generation == installedStreamClientGeneration else { return }
            // Keep listeners attached through a subscribe drop: the asynchronous catch-up
            // `.state` (the final render for an ended session) must still reach them, and
            // not notifying listeners keeps the render host from re-registering and
            // accumulating duplicates. The model owns reconnection, and publishes the drop
            // itself through `isStateStreamDisconnected` — observable without any listener
            // being notified, so the pane can report the outage while the fan-out stays put.
            // Stop the dropped client before dropping the reference: its pinned-TLS connection is
            // released only by an explicit cancel, so a bare `nil` would orphan the connection and its
            // dispatch queue for the life of the process while the reconnect mints a fresh one.
            let disconnectedClient = clearInstalledStreamClient()
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
            // Accepted: a daemon that completed the pinned TLS handshake and accepted this subscription,
            // then closed the stream before delivering anything, only ever reaches stage 1 here (the
            // ordinary `scheduleReconnect()` cadence), never the resolver's all-candidates-unreachable
            // evidence that `openStateStream` consults on a `client.start()` throw. That is correct
            // framing, not a gap: the completed handshake and accepted subscription are themselves proof
            // the device is reachable, so a stream drop right after is a daemon-side fault, not
            // reachability evidence, and stage 1's ordinary retry is the right response to it. That holds
            // even when every candidate address ends this way in turn (`invalidating` records each host
            // so the next redial rotates, and deliberately discards `noteStreamFailed`'s exhaustion
            // verdict here): "Device unreachable" with Retry would misdescribe a daemon that is answering
            // the handshake, and Retry's one effect, dropping the cached endpoint, cannot help against an
            // address that already answered. The iOS client reads the same no-frame ending as exhaustion
            // evidence only because its stream handle is returned before the dial, so a refused dial and a
            // post-handshake close both arrive through its `onDisconnect` and cannot be told apart there;
            // `client.start()` throws synchronously on a refused dial, so a disconnect reaching this
            // method has by construction completed the handshake.
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
        ///    the transport itself gave up. It takes the disconnect reaction immediately (drop the
        ///    subscription and arm a redial, which flips the disconnected notice), so the claim stays
        ///    falsifiable: the reconnect either succeeds and clears the notice, or keeps failing and the
        ///    notice is right. Every candidate address having refused this send
        ///    (`SpacesDeviceEndpointResolverError.allCandidatesUnreachable`) is stronger than a failure
        ///    pinned to one address, and escalates straight to stage 2 (see
        ///    `tearDownStreamAndScheduleReconnect`) instead of the paced stage 1 cadence a single-address
        ///    refusal or closure takes. It returns `true`, so the queued backlog is discarded;
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
        ///  - an already-disconnected link (a retry is already armed, so there is usually nothing new to do
        ///    here) returns `true` regardless of which shape this repeat failure is: the outage was
        ///    already confirmed by an earlier conclusive failure, a corroborated timeout, or the stream's
        ///    own disconnect, so every keystroke of an ongoing outage, not only the first, must keep
        ///    dropping its queued input rather than buffering behind a link that is not coming back on its
        ///    own. The one exception is `allCandidatesUnreachable` while still only at stage 1
        ///    (`.reconnecting`): that is the same conclusive stage 2 evidence the branch below escalates
        ///    on, and arriving here mid-reconnect does not make it any less conclusive, so it still
        ///    escalates the tracker rather than being discarded as merely a repeat of already-known news.
        @discardableResult func reportFailedInputSend(_ error: any Error) -> Bool {
            guard Self.isTransportFailureEvidenceOfLostLink(error) else { return false }
            // Typing produces one of these per keystroke for as long as the outage lasts. A link already
            // reported down has a retry armed, so re-reporting it must add no reconnect and no notice,
            // except that every candidate address refusing THIS send is conclusive stage 2 evidence on its
            // own (see the branch below), and that conclusiveness does not depend on what the tracker
            // already believed: discarding it here, before it was even classified, would drop stronger
            // evidence than whatever downgraded reason put the tracker at stage 1 in the first place.
            guard !isStateStreamDisconnected else {
                if connectionStageTracker.stage != .unreachable, Self.isAllCandidatesUnreachableResolverError(error) {
                    // An automatic redial may already be in flight here: `openStateStream` installs
                    // `streamClient` before its blocking dial resolves, so a client that dialed but has
                    // delivered no frame yet leaves the tracker at `.reconnecting` exactly like this. Left
                    // in place, that stale attempt (and `subscriptionConnectTask`) would make the ladder
                    // redial armed below a no-op: it would be turned away by `ensureSubscriptionStarted()`'s
                    // own in-flight guard (`streamClient != nil || subscriptionConnectTask != nil`) until
                    // the stale attempt's own connect timeout or stream watchdog resolves it, minutes
                    // later. Retiring it first with the same cleanup Retry performs is what lets the ladder
                    // redial actually dial; the retired attempt's belated completion is dropped by the
                    // generation gate `retireInFlightStreamAttempt()` bumps, so it cannot arm a competing
                    // reconnect of its own.
                    retireInFlightStreamAttempt()
                    // Mirrors `scheduleReconnect(after:)`'s own use of this delay. The stale stage 1
                    // timer already armed here (`reconnectTask`, paced by `reconnectBackoff`, capped
                    // ~10s) has to be retired before rearming: `scheduleReconnect(delay:)` is a no-op
                    // while `reconnectTask != nil`, so without cancelling it first the fresh ladder delay
                    // computed below would just be discarded, and the redial would fire off the stale
                    // stage 1 cadence instead of the stage 2 ladder this escalation just moved to.
                    let redialDelaySeconds = applyStageTransition { $0.attemptEndedUnreachable() }
                    reconnectTask?.cancel()
                    reconnectTask = nil
                    scheduleReconnect(delay: .seconds(redialDelaySeconds))
                }
                return true
            }
            guard !SpacesDeviceClient.isDeviceAPIRequestTimeout(error) else {
                startLinkCorroborationProbe()
                return false
            }
            // `allCandidatesUnreachable` is the racing command-channel connect's own hard evidence: every
            // candidate address refused to dial for THIS send, not merely the one host a corroboration
            // probe or the state stream itself is pinned to. That is exactly the stage 2 evidence
            // `scheduleReconnect(after:)` already escalates on, so it must not be diluted into the
            // ordinary stage 1 cadence the way every other conclusive input failure (refused/closed on
            // one address) correctly is.
            tearDownStreamAndScheduleReconnect(allCandidatesUnreachable: Self.isAllCandidatesUnreachableResolverError(error))
            return true
        }

        /// Whether `error` is the endpoint resolver's own `allCandidatesUnreachable`: every one of this
        /// device's candidate addresses refused to dial on the racing command-channel connect that sent
        /// this input. Distinct from `StateStreamConnectResult.failed(allCandidatesUnreachable:)`, which is
        /// the state stream's own (one-candidate-per-attempt) evidence of the same fact: the two connects
        /// race candidates differently, so each carries its own proof.
        private static func isAllCandidatesUnreachableResolverError(_ error: any Error) -> Bool {
            if case SpacesDeviceEndpointResolverError.allCandidatesUnreachable = error { return true }
            return false
        }

        /// The disconnect reaction a conclusive lost link takes: drop the subscription and arm a redial.
        /// Shared by the connection-level failure branch of `reportFailedInputSend` and the corroboration
        /// probe's failed verdict, so both surface an outage identically, except for the redial's pacing:
        /// `allCandidatesUnreachable` is `reportFailedInputSend`'s own hard evidence (every candidate
        /// address refused this input send) and escalates straight to the stage 2 ladder exactly as
        /// `openStateStream`'s equivalent evidence does (see `scheduleReconnect(after:)`); the probe's
        /// failed verdict is pinned to one host and never sets it, so it keeps the ordinary stage 1 cadence.
        private func tearDownStreamAndScheduleReconnect(allCandidatesUnreachable: Bool = false) {
            // Retire this client's generation before stopping it: `stop()` cancels the connection, whose
            // receive loop then delivers one final disconnect callback, and that callback must not arm a
            // second reconnect on top of the one below.
            streamClientGeneration &+= 1
            let deadClient = clearInstalledStreamClient()
            deadClient?.stop()
            if allCandidatesUnreachable {
                scheduleReconnect(after: .failed(allCandidatesUnreachable: true))
            } else {
                scheduleReconnect()
            }
        }

        /// Deadline for the corroboration `.ping`, deliberately shorter than both the Device API's 10s
        /// default and the 5s interactive deadline that produced the timeout being corroborated. The probe
        /// only has to learn whether the daemon's listener still answers a request that does no work, so a
        /// long deadline would only stretch how long a genuinely dead link keeps looking live.
        ///
        /// A pong is a valid liveness signal because everything seconds-scale is diverted off the serial
        /// state queue that answers it: engine waits (`.terminalControl`, `.terminalPasteImage`,
        /// `.sendTerminalInput`, `.state`), workspace teardown, workspace stop, and workspace setup, each on
        /// its own serial queue, so a hung stop or setup script cannot also delay a teardown or the state
        /// queue. The commands still inline are database-read scale, with the residual long inline
        /// offenders (the git and network work inside workspace creation and git preview) tracked by issue
        /// #503, so a pong can in principle still be delayed past this deadline while one of those runs.
        /// Accepted until #503 closes that class.
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
        /// engine-blocked queues (the terminal-control lane commands divert to; see
        /// `SpacesDeviceAPICommandDescriptor` in `spacesdevicecore`). Against a daemon predating that
        /// divert, saturation stalls the ping too and the verdict reproduces the
        /// bare-timeout teardown this probe replaces — the same banner the old client raised, two seconds
        /// later. Accepted rather than gated on a daemon-reported capability: clients and daemons ship in
        /// lockstep with no compatibility guarantees yet, and the mixed pairing merely degrades to the
        /// pre-probe behavior instead of anything worse.
        ///
        /// A pong is proof about the link, not about the stream's own established socket. In the narrow
        /// window where the path drops and recovers between the input timeout and the probe (an interface
        /// switch that blackholes both sockets, healed within the timeout-plus-probe horizon), the probe's
        /// fresh connection pongs while the stream's socket stays dead, and the pane keeps a stream whose
        /// render is frozen until TCP keepalive errors the socket (60–90s; the disconnect callback then
        /// reconnects and catches up via `.state`). Typing is not gated on that: the request client drops
        /// its connection on any send failure, so the next keystroke dials fresh and lands as soon as the
        /// path is back. Accepted: tearing the stream down on a pong that follows a timeout is
        /// indistinguishable from the false teardown this probe exists to remove, and the residual cost is
        /// a stale passive render with a bounded self-heal, not lost input or a false banner.
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
            // Compared against the INSTALLED client's generation, exactly like `handleStreamDisconnect`'s
            // guard (see that field's doc comment): `streamClientGeneration` alone only ever increases and
            // is never retired by a disconnect, so a frame the old client already had in flight on the
            // main actor would still carry a generation equal to it and pass this guard after
            // `handleStreamDisconnect` cleared `streamClient`, clearing the banner and resetting backoff
            // for a stream that is no longer installed.
            guard generation == installedStreamClientGeneration else { return }
            // A frame actually arriving over the stream is the proof the connect succeeding in
            // `openStateStream` alone is not: it is what the tracker's contract means by
            // `frameReceived()`, and what `TerminalConnectionNotice`'s banner promises the user.
            clearConnectionOutage()
            apply(payload)
        }

        // Test seams mirroring `openStateStream`'s install semantics. The concrete stream client offers no
        // protocol seam to force callback orderings, so `spacesuiTests` drives the generation guard through
        // these instead of racing a real connect.
        /// `connectedHost` stands in for the address the concrete client would have pinned itself to, so a
        /// test can drive the probe's host correlation without a multi-address daemon.
        @discardableResult func installStreamClientForTesting(_ client: any TerminalRemoteStateStreamClient, connectedHost: String? = nil) -> UInt64 {
            streamClientGeneration &+= 1
            installStreamClient(client, generation: streamClientGeneration)
            streamConnectedHost = connectedHost
            return streamClientGeneration
        }

        var hasActiveStreamClientForTesting: Bool { streamClient != nil }

        /// Exposes the currently installed client's generation so a test that let a real connect attempt
        /// install its client (through `stateStreamConnectOverrideForTesting`, rather than
        /// `installStreamClientForTesting`) can still call `applyStreamEvent`/`handleStreamDisconnect` with
        /// the generation those calls require.
        var installedStreamClientGenerationForTesting: UInt64? { installedStreamClientGeneration }

        /// Overrides the blocking pinned-TLS connect `openStateStream` normally runs in a detached task,
        /// so a test can control exactly when and how it resolves instead of racing real network timing.
        /// `spacesuiTests` uses it to reproduce the connect-vs-disconnect race the post-connect check in
        /// `ensureSubscriptionStarted` guards against: resolving the connect only after a competing
        /// `reportFailedInputSend` has already cleared `streamClient` reproduces `start()` succeeding for
        /// a client that was concurrently stopped, deterministically. Nil in production, where the real
        /// detached connect always runs.
        var stateStreamConnectOverrideForTesting: (@MainActor () async -> Bool)?

        /// Stands in for `SpacesDeviceAPIStateStreamClient.lastDialExhaustedAllCandidates` when a failed
        /// connect came from `stateStreamConnectOverrideForTesting`: the override bypasses `start()`
        /// entirely, so the real client's verdict is never recorded. Ignored (and false) in production,
        /// where a failed connect always went through the real client and its own verdict is read
        /// instead.
        var lastDialExhaustedAllCandidatesForTesting = false

        /// See the call site in `ensureSubscriptionStarted`.
        var ensureSubscriptionStartedInvokedForTesting: (@MainActor () -> Void)?

        /// Overrides the `.state` request the liveness recheck makes, so `spacesuiTests` can hand it a
        /// chosen answer — a transport failure, a coded refusal, a running session, an exited one — and a
        /// chosen moment to answer. Nil in production, where every attempt is a real request. Same purpose
        /// as `stateStreamConnectOverrideForTesting`: this loop's whole contract is what it does with each
        /// answer, and racing a real device to produce them is neither fast nor deterministic.
        var livenessStateFetchOverrideForTesting: (@Sendable () async -> Result<GhosttyRemoteSessionStatePayload, any Error>)?

        /// Whether a liveness question is currently open (asking, or waiting out its retry delay). Cleared
        /// only after the answer has been acted on, so a test that sees it false can read the outcome.
        var hasArmedLivenessRecheckForTesting: Bool { livenessRecheckTask != nil }

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

        /// Re-subscribes after a backoff delay — only while listeners remain and the session is still
        /// interactive as far as the DEVICE is concerned. An ended session needs no live stream, so it is
        /// left disconnected, and it is also not reported as disconnected: the daemon streams live sessions
        /// only, so refusing an ended one is the expected answer rather than a link the user should be told
        /// about. Whether the session has ended is a question for the device, not for the cache this model
        /// happens to hold (see `recheckLivenessAfterStreamLoss`).
        ///
        /// The delay grows with the run of failures (`reconnectBackoff`) instead of retrying flat forever:
        /// a pane outlives its device going away, and a fixed cadence is a reconnect storm against a device
        /// that is genuinely down. Marking the link down here rather than in `handleStreamDisconnect` keeps
        /// the flag meaning exactly what the banner tells the user — the connection dropped, and a retry is
        /// coming unless nothing is listening for one.
        ///
        /// Idempotent while a retry is already pending (`reconnectTask != nil`): more than one caller can
        /// decide the same failed connect owes a retry (see the connect-completion check in
        /// `ensureSubscriptionStarted`), and a second call here must not stack a competing timer or double
        /// the backoff on top of the one already armed.
        ///
        /// `delay` overrides the ordinary `reconnectBackoff` cadence. Only `scheduleReconnect(after:)`
        /// passes one, for the one case with harder evidence than "a connect failed": every candidate
        /// address has now refused to dial, which is stage 2 and paces off `TerminalUnreachableBackoff`'s
        /// own (slower) ladder instead. Every other caller (a live subscription dropping, a failed input
        /// send, a liveness recheck failure) has no such evidence and always takes this default path.
        private func scheduleReconnect(delay: Duration? = nil) {
            // A retry is already armed, and whoever armed it already published the drop.
            guard reconnectTask == nil else { return }
            // Order matters below, and it is the opposite of the obvious one. A cached non-interactive
            // runtime state is not evidence that this session needs no stream: the stream that just died is
            // the only thing that keeps that cache current, so a cache that has gone `.exited` while the
            // session is in fact still running would turn this into a dead end no later event can reopen:
            // no stream, no retry, and no notice either (issue #537). So the cache is not trusted here; the
            // device is asked, and its answer re-enters this method through `apply`. A session that really
            // did end stays quiescent, which is why publishing the drop comes after this check rather than
            // at the top: the daemon streams live sessions only, so refusing an ended one is the expected
            // answer, not an outage to put on the pane.
            guard currentRuntimeState?.state.isInteractive != false else {
                recheckLivenessAfterStreamLoss()
                return
            }
            // Published before the listener check below: a live session whose stream is gone is an outage
            // the pane must be able to report whether or not this model goes on to arm a retry for it.
            markStreamLost()
            // Nothing is being fanned out to, so nothing needs a live stream; a listener registering later
            // starts one itself through `registerListener`.
            guard !listeners.isEmpty else { return }
            let resolvedDelay = delay ?? reconnectBackoff.nextDelay()
            lastReconnectDelayForTesting = resolvedDelay
            reconnectTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: resolvedDelay)
                // `try?` turns the sleep's `CancellationError` into a plain return from that line, not
                // from this task: without checking `Task.isCancelled` explicitly, a caller that cancels
                // this task (Retry, or an escalation rearming on the stage 2 ladder) would only stop the
                // sleep, and the body below would still run immediately afterward as if the delay had
                // elapsed for real, clearing whatever fresh `reconnectTask` the canceller went on to
                // arm and firing a spurious extra `ensureSubscriptionStarted()` of its own.
                guard let self, !Task.isCancelled else { return }
                self.reconnectTask = nil
                guard self.streamClient == nil, !self.listeners.isEmpty else { return }
                // Same rule as above: the retry does not end on the cached state's word alone.
                guard self.currentRuntimeState?.state.isInteractive != false else {
                    self.recheckLivenessAfterStreamLoss()
                    return
                }
                self.lastSubscriptionAttemptAt = nil
                self.ensureSubscriptionStarted()
            }
        }

        /// Arms the next redial from a failed connect's own evidence: the tracker's (slower) stage 2
        /// ladder once the attempt proves every known candidate address refused to dial, OR the tracker
        /// is already `.unreachable` from an earlier attempt, otherwise the ordinary stage 1 backoff (see
        /// `scheduleReconnect(delay:)`).
        ///
        /// The `connectionStageTracker.stage == .unreachable` half matters because the resolver's failed
        /// set is self-resetting (`SpacesDeviceEndpointResolver.nextStreamHost()` clears it right after a
        /// full cycle through every candidate), so with more than one candidate host the very next
        /// attempt after the one that reached stage 2 can fail with `allCandidatesUnreachable: false`
        /// even though nothing has actually improved. Without this, that attempt would drop back onto
        /// `reconnectBackoff` (capped at 10 s, and never reset by Retry) instead of continuing to pace on
        /// the stage 2 ladder: once unreachable, every failed attempt keeps pacing on the ladder until a
        /// frame actually arrives.
        private func scheduleReconnect(after result: StateStreamConnectResult) {
            let isAllCandidatesUnreachable: Bool
            if case .failed(true) = result { isAllCandidatesUnreachable = true } else { isAllCandidatesUnreachable = false }
            guard isAllCandidatesUnreachable || connectionStageTracker.stage == .unreachable else {
                scheduleReconnect()
                return
            }
            let redialDelaySeconds = applyStageTransition { $0.attemptEndedUnreachable() }
            scheduleReconnect(delay: .seconds(redialDelaySeconds))
        }

        /// Asks the device whether the session is still live, after a stream loss the cached runtime state
        /// claims needs no stream — and keeps asking until the device answers.
        ///
        /// The question is settled only by the answer to THIS recheck's own `.state` request. It
        /// deliberately does not ride `refreshState()`: that call coalesces with an in-flight request older
        /// than the drop, silently drops its failures, and delivers its result through `apply`, where any
        /// unrelated payload is indistinguishable from an answer. Each of those leaves the question open
        /// with nothing left to reopen it — a live session frozen behind a stale `.exited` cache, which is
        /// the stall this whole path exists to end (issue #537).
        ///
        /// A request that never arrives is not silence to wait out: it means the device is unreachable,
        /// which is an outage the pane must show, so the notice goes up and the question is asked again on
        /// the same paced cadence the reconnect uses (`reconnectBackoff`) rather than going quiescent. Only
        /// the device settles it: still interactive re-arms the reconnect the stale cache turned away, and a
        /// confirmed end (or a reachable daemon refusing the session) quiesces and clears the notice, per
        /// the ended-session contract that a refused subscribe is the expected answer, not an outage.
        private func recheckLivenessAfterStreamLoss() {
            guard wantsLivenessRecheck, livenessRecheckTask == nil else { return }
            livenessRecheckGeneration &+= 1
            let generation = livenessRecheckGeneration
            livenessRecheckTask = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    // Rebuilt per attempt, and nil once nothing needs an answer any more. Awaited outside
                    // the model so the round trip never holds it alive.
                    guard let fetch = self?.makeLivenessStateFetch() else { break }
                    let result = await fetch()
                    guard !Task.isCancelled, let outcome = self?.settleLivenessRecheck(with: result) else { break }
                    guard case .retryAfter(let retryDelay) = outcome else { break }
                    try? await Task.sleep(for: retryDelay)
                    guard !Task.isCancelled else { break }
                    // Re-resolve a local daemon that may have moved before asking again. An idle-shut-down
                    // daemon comes back on a fresh ephemeral port, so every attempt made through the request
                    // client the drop left behind would keep dialing an address nothing is listening on —
                    // the pane would poll and stay bannered forever against a daemon that is running. This is
                    // the same recovery the connect path runs between its own attempts, and a no-op for
                    // remote devices, whose candidate addresses are re-walked inside the request itself.
                    await self?.ensureLocalDeviceReachableForRetry()
                }
                self?.finishLivenessRecheck(generation: generation)
            }
        }

        /// Releases the recheck slot, but only for the task that still holds it. A cancelled recheck can be
        /// suspended inside its own request while a replacement is already armed; clearing the slot on its
        /// way out would strand that replacement — armed but no longer reachable, so a later listener removal
        /// could not cancel it and the next drop would arm a second recheck alongside it.
        private func finishLivenessRecheck(generation: UInt64) {
            guard generation == livenessRecheckGeneration else { return }
            livenessRecheckTask = nil
        }

        private enum LivenessRecheckOutcome {
            case settled
            case retryAfter(Duration)
        }

        /// Whether an open liveness question is still this model's to answer. An installed stream, a connect
        /// in flight, or an armed reconnect all mean recovery is owned elsewhere, and a background poll that
        /// kept raising the disconnected notice underneath a healthy stream would be worse than no poll.
        private var wantsLivenessRecheck: Bool { !listeners.isEmpty && streamClient == nil && subscriptionConnectTask == nil && reconnectTask == nil }

        /// The recheck's own `.state` request, or nil once nothing needs the answer. Vended as a closure so
        /// the recheck loop can await the round trip without holding the model across it.
        private func makeLivenessStateFetch() -> (@Sendable () async -> Result<GhosttyRemoteSessionStatePayload, any Error>)? {
            guard wantsLivenessRecheck else { return nil }
            if let livenessStateFetchOverrideForTesting { return livenessStateFetchOverrideForTesting }
            let sessionID = self.sessionID
            let clientApp = self.clientApp
            let requestClientBox = self.requestClientBox
            return {
                await Task.detached(priority: .userInitiated) {
                    let (client, token) = requestClientBox.current
                    return Self.fetchState(sessionID: sessionID, requestClient: client, authToken: token, clientApp: clientApp)
                }.value
            }
        }

        /// Reacts to one recheck answer, reporting whether the question is now settled or owes another ask.
        private func settleLivenessRecheck(with result: Result<GhosttyRemoteSessionStatePayload, any Error>) -> LivenessRecheckOutcome {
            switch result {
            case .success(let payload):
                // Applied first: this is also the freshest state this pane has. The decision below then
                // reads the cache rather than the payload, so an answer the emission-time guard refuses
                // (something newer landed while it was in flight) is decided on that newer truth.
                apply(payload)
                guard wantsLivenessRecheck else { return .settled }
                if currentRuntimeState?.state.isInteractive != false { scheduleReconnect() } else { clearConnectionOutage() }
                return .settled
            case .failure(let error):
                // Ownership is re-checked here for the same reason it is above: this answer describes a
                // request that was in flight, and a stream installed while it flew (another listener
                // registering is enough) already cleared the notice. Raising it again from a stale failure
                // would leave an outage notice standing over a healthy pane, with the loop then exiting
                // because that stream exists — so nothing would ever take it down.
                guard wantsLivenessRecheck else { return .settled }
                // ONLY the daemon's verdict on this session settles it: it looked the session up and has
                // none to serve, which is an answer about the session. Every other failure — a request that
                // never arrived, a pinned identity that did not match, an `ok` response carrying no state, a
                // refusal about credentials or the daemon's own state rather than the session — says nothing
                // about whether the session is alive, so treating any of them as an answer would quiesce
                // recovery on no evidence.
                if let refusal = error as? StateFetchError, refusal.isSessionVerdict {
                    clearConnectionOutage()
                    return .settled
                }
                // Unanswered, for whatever reason: the pane cannot reach its session, which is the outage it
                // exists to report, and the question is still open, so ask again after a paced delay. This
                // recheck's own polling failure carries none of `openStateStream`'s all-candidates evidence,
                // so it stays on the ordinary stage 1 cadence rather than escalating.
                markStreamLost()
                return .retryAfter(reconnectBackoff.nextDelay())
            }
        }

        /// Applies one mutation to `connectionStageTracker` and publishes a change to this session's
        /// observers exactly when it flips the stage or the banner's visibility, never on a call that
        /// leaves both unchanged, so a persistently down device does not wake every pane on every retry.
        /// Every mutation of the tracker goes through here so that contract cannot be missed at a call site.
        @discardableResult
        private func applyStageTransition<T>(_ mutate: (inout TerminalConnectionStageTracker) -> T) -> T {
            let before = connectionStageTracker
            let result = mutate(&connectionStageTracker)
            if connectionStageTracker.stage != before.stage || connectionStageTracker.isBannerVisible != before.isBannerVisible {
                TerminalSessionNotification.post(.spacesTerminalStateStreamConnectionDidChange, sessionID: sessionID)
            }
            return result
        }

        /// Declares the stream lost: moves the tracker to stage 1 (a no-op if it is already past stage 1;
        /// see `TerminalConnectionStageTracker.streamLost()`) and arms the grace timer that raises the
        /// "Reconnecting…" banner after `TerminalConnectionNotice.bannerGraceSeconds`, so a blip that heals
        /// within the grace never paints anything. Published before the listener-empty check in
        /// `scheduleReconnect(delay:)`, same as before this tracker existed: a live session whose stream is
        /// gone is an outage the pane must be able to report whether or not a retry gets armed for it.
        private func markStreamLost() {
            let wasConnected = connectionStageTracker.stage == .connected
            applyStageTransition { $0.streamLost() }
            // `streamLost()` is a no-op once past stage 1 (`TerminalConnectionStageTracker`'s only way out
            // of stage 2 is a live frame), so the grace only needs arming on the very first loss.
            guard wasConnected else { return }
            armGraceTimer()
        }

        /// Declares the stream outage over: cancels any pending grace timer, resets the ordinary
        /// `reconnectBackoff` cadence, and returns `connectionStageTracker` to `.connected` (hiding the
        /// banner and resetting its stage 2 ladder). Used both when a live frame proves the stream itself
        /// recovered (`applyStreamEvent`) and when a liveness recheck learns there is nothing left to
        /// reconnect to (the device confirms the session ended): in both cases nothing remains for the
        /// banner to report.
        private func clearConnectionOutage() {
            cancelGraceTimer()
            reconnectBackoff.reset()
            applyStageTransition { $0.frameReceived() }
        }

        /// Arms the one-shot timer between a stream loss and the "Reconnecting…" banner actually showing.
        /// Guarded by `markStreamLost()` so a second stream loss while stage 1 is already in progress
        /// (or one past it, in stage 2) never restarts or duplicates the grace.
        private func armGraceTimer() {
            graceTask?.cancel()
            let delay = graceDelayForTesting ?? .seconds(TerminalConnectionNotice.bannerGraceSeconds)
            graceTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: delay)
                guard let self, !Task.isCancelled else { return }
                self.graceTask = nil
                self.applyStageTransition { $0.graceElapsed() }
            }
        }

        private func cancelGraceTimer() {
            graceTask?.cancel()
            graceTask = nil
        }

        /// Retires any connect already in flight, and any client it already installed but that has not yet
        /// produced a frame: an automatic reconnect timer can start one before something else needs the
        /// slot back (Retry, or `reportFailedInputSend`'s stage 1 to stage 2 escalation), and
        /// `ensureSubscriptionStarted()`'s in-flight guard (`streamClient != nil || subscriptionConnectTask
        /// != nil`) would otherwise make a fresh redial a no-op until that stale attempt's own connect
        /// timeout or stream watchdog resolves it, minutes later. This mirrors
        /// `tearDownStreamAndScheduleReconnect`'s cleanup (retire the generation, clear and stop the
        /// installed client) without going through it: neither caller wants this to also schedule a
        /// reconnect of its own, since each arms one on its own terms right after.
        ///
        /// `connectAttemptGeneration` is bumped here too, not just inside whatever fresh
        /// `ensureSubscriptionStarted()` call follows: `client.start()`'s blocking dial has no
        /// structured-concurrency link to `subscriptionConnectTask`, so cancelling it above does not stop
        /// an in-flight attempt from resuming and finishing on its own later. Retiring its generation now
        /// (independent of whether a fresh attempt actually starts afterward) is what makes that belated
        /// completion recognizable as stale everywhere it is checked, so it cannot arm a competing
        /// reconnect of its own.
        private func retireInFlightStreamAttempt() {
            subscriptionConnectTask?.cancel()
            subscriptionConnectTask = nil
            connectAttemptGeneration &+= 1
            streamClientGeneration &+= 1
            let deadClient = clearInstalledStreamClient()
            deadClient?.stop()
        }

        /// User-initiated retry from the pane's Retry button, shown only in stage 2 ("Device unreachable").
        /// Resets the tracker's stage 2 ladder (`TerminalConnectionStageTracker.retryRequested()`, a no-op
        /// outside stage 2) so the NEXT automatic redial after this one starts from the ladder's shortest
        /// delay again rather than continuing to back off; cancels whatever redial is currently pending;
        /// drops the endpoint resolver's cached winner, since retrying is the user's own evidence that the
        /// address the stream last tried is not to be trusted again; and redials immediately, bypassing
        /// `ensureSubscriptionStarted`'s own throttle the same way the reconnect timer's own fire does.
        func retryStateStreamConnection() {
            applyStageTransition { $0.retryRequested() }
            reconnectTask?.cancel()
            reconnectTask = nil
            retireInFlightStreamAttempt()
            SpacesDeviceEndpointRegistry.resolver(for: device, certificateFingerprint: certificateFingerprint).clearCachedWinner()
            lastSubscriptionAttemptAt = nil
            ensureSubscriptionStarted()
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
            if payload.reasonKind == .clipboardWrite {
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

        /// Why a `.state` fetch produced no payload. The two are not interchangeable: only `rejected` is the
        /// daemon answering about this session, which is what lets the liveness recheck stop asking
        /// (`settleLivenessRecheck`). Internal (not `private`) so `spacesuiTests` can hand the recheck each
        /// shape without a daemon.
        enum StateFetchError: Error {
            /// The daemon answered `ok == false`, with the machine-readable reason it sent. Only some of
            /// those reasons are answers about this session — see `isSessionVerdict`.
            case rejected(message: String, code: SpacesDeviceErrorCode?)
            /// The daemon answered `ok` but carried no session state — an answer about nothing, which says
            /// as little about the session as a request that never arrived.
            case missingState

            /// Whether this refusal is the daemon's verdict on the session itself, which is the only kind of
            /// failure that settles the liveness recheck.
            ///
            /// `ok == false` is also how a reachable daemon reports conditions that have nothing to do with
            /// the session: a revoked or rotated token (`unauthorized`), a daemon shutting down or mid
            /// handoff, a request that reached the wrong daemon, an internal failure, or a code this build
            /// does not know. Reading any of those as "the session is gone" clears the outage notice and
            /// stops the asking, so a pane holding a stale non-interactive cache freezes there for good and
            /// never reaches the credential and endpoint recovery each retry runs
            /// (`ensureLocalDeviceReachableForRetry`) — issue #537's stall arriving by another road.
            var isSessionVerdict: Bool {
                guard case .rejected(_, let code) = self else { return false }
                switch code {
                // The daemon looked this session up and has no live session to serve.
                case .sessionNotRunning, .sessionNotAvailable, .notFound: return true
                default: return false
                }
            }
        }

        private nonisolated static func fetchState(
            sessionID: String, requestClient: SpacesDeviceAPIRequestSessionClient, authToken: String?, clientApp: SpacesDeviceClientApp
        ) -> Result<GhosttyRemoteSessionStatePayload, Error> {
            do {
                let response = try requestClient.send(
                    SpacesDeviceAPIRequest(
                        command: .state(SpacesDeviceTerminalSessionRequest(sessionID: sessionID)), authToken: authToken, clientApp: clientApp))
                guard response.ok else { throw StateFetchError.rejected(message: response.message, code: response.errorCode) }
                guard let payload = response.sessionState else { throw StateFetchError.missingState }
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
        /// made off that path and keep the default deadline. Selection commands join them: a drag
        /// commits one `setSelection` on release rather than streaming per-pixel like scroll, so it is
        /// not a hot per-keystroke path either.
        private nonisolated static func isInteractiveControlCommand(_ request: TerminalControlRequest) -> Bool {
            switch TerminalControlCommand(request: request) {
            case .send, .key, .clearScreen, .resize, .scroll, .mouseButton: true
            case .attach, .detach, .heartbeat, .takeover, .setAppearance, .setSelection, .clearSelection, .readSelectionText, .unsupported: false
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
                let deviceRequest = try TerminalPaneService.deviceTerminalControlRequest(
                    sessionID: payload.sessionID, controlRequest: payload.controlRequest)
                let controlAPIRequest = SpacesDeviceAPIRequest(command: .terminalControl(deviceRequest), authToken: authToken, clientApp: clientApp)
                let timeoutSeconds = Self.controlRequestTimeoutSeconds(for: payload.controlRequest, command: controlAPIRequest.command)
                let response = try requestClient.send(controlAPIRequest, timeoutSeconds: timeoutSeconds)
                return TerminalServiceResponse(
                    ok: response.ok, message: response.message, sessionState: response.sessionState,
                    // `selectionText` must survive this adapter: it is the sole carrier of the
                    // daemon-authoritative copy text for a `setSelection`/`readSelectionText` on a
                    // paired device's session, where the selection can extend beyond the mirror's
                    // viewport-clipped snapshot.
                    controlResponse: TerminalControlResponse(
                        ok: response.ok, message: response.message, selectionText: response.terminalSelectionText))
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

        /// Releasing the handle detaches too, not only `stop()`. A subscriber torn down without stopping —
        /// `RemoteGhosttySessionHost`'s `deinit` returns without stopping anything when it runs off the main
        /// thread — would otherwise leave its callbacks in the model's fan-out for the life of the session,
        /// so every payload would keep reaching a dead host and `listeners` could never fall empty
        /// (issue #537). `detach` removes by listener id, so detaching twice is a no-op.
        deinit { detach() }

        func stop() { detach() }
    }
#endif
