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

        private let device: SpacesPairedDeviceRecord
        private let sessionID: String
        private let clientApp: SpacesDeviceClientApp
        private let authToken: String?
        private let certificateFingerprint: String
        private let requestClient: SpacesDeviceAPIRequestSessionClient

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
        private var lastSubscriptionAttemptAt: Date?
        private var refreshInFlight = false
        private var stateRefreshRetryTask: Task<Void, Never>?

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
            authToken = preparedCredentials.authToken
            requestClient = try SpacesDeviceAPIRequestSessionClient(
                host: device.host, port: device.port, certificateFingerprint: preparedCredentials.certificateFingerprint)
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
                requestClient.cancel()
            }
        }

        // MARK: TerminalSessionStateProviding

        func refreshState() {
            guard !refreshInFlight else { return }
            refreshInFlight = true
            let sessionID = self.sessionID
            let authToken = self.authToken
            let clientApp = self.clientApp
            let requestClient = self.requestClient
            Task { @MainActor [weak self] in
                let result = await Task.detached(priority: .userInitiated) {
                    Self.fetchState(sessionID: sessionID, requestClient: requestClient, authToken: authToken, clientApp: clientApp)
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
            let authToken = self.authToken
            let clientApp = self.clientApp
            let requestClient = self.requestClient
            return { request in
                try Self.sendTerminalServiceRequest(
                    request, defaultSessionID: sessionID, requestClient: requestClient, authToken: authToken, clientApp: clientApp)
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
            let requestClient = self.requestClient
            let request = SpacesDeviceAPIRequest(
                command: .terminalPasteImage(
                    SpacesDeviceTerminalPasteImageRequest(
                        sessionID: sessionID, clientID: clientID, ownerEpoch: ownerEpoch, fileExtension: image.fileExtension,
                        imageData: image.imageData)), authToken: authToken, clientApp: clientApp)
            return try await Task.detached(priority: .userInitiated) {
                let response = try requestClient.send(request)
                return TerminalControlResponse(ok: response.ok, message: response.message)
            }.value
        }

        /// Fetches a suffix of the session's persisted output transcript for the render host's
        /// client-local ended-session scrollback replay. Read-only; routes through the owning device's
        /// Device API endpoint like every other request, so it serves local and remote sessions alike.
        func fetchTranscript(maxBytes: Int) async throws -> Data {
            let sessionID = self.sessionID
            let authToken = self.authToken
            let clientApp = self.clientApp
            let requestClient = self.requestClient
            return try await Task.detached(priority: .userInitiated) {
                let response = try requestClient.send(
                    SpacesDeviceAPIRequest(
                        command: .terminalTranscript(SpacesDeviceTerminalTranscriptRequest(sessionID: sessionID, maxBytes: maxBytes)),
                        authToken: authToken, clientApp: clientApp))
                guard response.ok, let transcript = response.terminalTranscript else { throw SpacesDeviceClientError.unavailable(response.message) }
                return transcript.data
            }.value
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
            if streamClient != nil { return }
            if let lastSubscriptionAttemptAt, now.timeIntervalSince(lastSubscriptionAttemptAt) < 0.5 { return }
            lastSubscriptionAttemptAt = now
            // Catch up unconditionally, before (and independent of) the subscribe below.
            // The daemon only streams live sessions, so an ended session's subscribe is
            // rejected — but its `.state` response still carries the final render the host
            // needs, and that response must be applied even when no live stream attaches.
            refreshState()
            let request = SpacesDeviceAPIRequest(
                command: .subscribe(SpacesDeviceTerminalSubscriptionRequest(sessionID: sessionID, clientID: nil)), authToken: authToken,
                clientApp: clientApp)
            do {
                let client = try SpacesDeviceAPIStateStreamClient(
                    request: request, host: device.host, port: Int(device.port), certificateFingerprint: certificateFingerprint,
                    onEvent: { [weak self] payload in Task { @MainActor [weak self] in self?.apply(payload) } },
                    onDisconnect: { [weak self] error in Task { @MainActor [weak self] in self?.handleStreamDisconnect(error) } })
                try client.start()
                streamClient = client
            } catch {
                // A transient subscribe failure on a live session would otherwise strand
                // existing listeners with only the one-shot catch-up and no live updates,
                // because the render host has already taken its `ListenerHandle` and will
                // not ask to subscribe again. Schedule the same model-owned retry the
                // disconnect path uses.
                streamClient = nil
                scheduleReconnect()
            }
        }

        private func handleStreamDisconnect(_ error: (any Error)?) {
            // Keep listeners attached through a subscribe drop: the asynchronous catch-up
            // `.state` (the final render for an ended session) must still reach them, and
            // not notifying listeners keeps the render host from re-registering and
            // accumulating duplicates. The model owns reconnection.
            streamClient = nil
            scheduleReconnect()
        }

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

    /// Handle returned to a fan-out subscriber. Stopping it detaches that listener
    /// from the model's shared subscription without tearing the stream down for
    /// other listeners.
    private final class ListenerHandle: TerminalRemoteStateStreamClient, @unchecked Sendable {
        private let detach: @Sendable () -> Void

        init(detach: @escaping @Sendable () -> Void) { self.detach = detach }

        func stop() { detach() }
    }
#endif
