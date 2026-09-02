import AppKit
import Foundation
import spacesclientcore
import spacesdevicecore
import spacesterminalcore
import spacesterminalghostty
import spacesterminalui
import workspacecore

/// Owns the terminal-pane domain: building a session's device-backed state model and pane content,
/// preparing and resolving pane open requests, sending Device API terminal-control requests, closing
/// panes, the pane-policy pure decision functions (what an open/close/hold does to the panel layout,
/// whether a device may be acted on), and the built-in (local ad hoc) terminal session launcher and
/// terminator registered with `WorkspaceOrchestrator`. Extracted from `AppKitController` as a
/// behavior-preserving move (part of the ongoing decomposition of that type); `AppKitController` holds
/// this as `terminalPanes` and reaches it as `host.terminalPanes` from other files (`PanelCoordinator`,
/// `SidebarController`, `AppKitController+TerminalTextSize`, `AppKitController+TerminalPaneContent`,
/// `DeviceTerminalSessionStateModel`) that open or close panes, gate daemon-backed terminal controls
/// on the pane-policy rules, or send device terminal control requests. `AppKitController` itself
/// registers the built-in session terminator with the orchestrator and calls the pane-policy statics
/// from its own IPC handlers and quit-time bookkeeping, staying the host for everything device
/// resolution, sidebar/overview state, and error presentation that the terminal-pane domain reads but
/// does not own.
@MainActor final class TerminalPaneService {
    unowned let host: AppKitController

    init(host: AppKitController) {
        self.host = host
    }

    /// A one-shot, thread-safe box a background thread's `performBuiltInTerminalSessionWorkOnMainThread`
    /// call sets once the main-actor work it dispatched finishes, so the calling thread's semaphore wait
    /// below has somewhere safe to read the result from.
    private final class MainThreadResultBox<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var result: Result<T, Error>?

        func set(_ result: Result<T, Error>) {
            lock.lock()
            self.result = result
            lock.unlock()
        }

        func get() -> Result<T, Error>? {
            lock.lock()
            defer { lock.unlock() }
            return result
        }
    }

    enum TerminalQuitPolicy: Equatable, Sendable {
        case quitImmediately
        case promptForLiveSessions(count: Int)
    }

    /// The app-wide terminal text size every open pane renders at, loaded from the profile at launch
    /// and moved by the focused pane's zoom keys (see `AppKitController+TerminalTextSize`).
    var terminalTextSize: TerminalTextSize = .default

    /// Transitional alias: `TerminalSessionSummaryMatch` stays on `AppKitController` because both
    /// host-only code (`resolveSessionSummaryMatch`, `resolveTerminalSessionPaneOpenRequest`,
    /// `resolveRemoteTerminalSessionMatch`) and this service's code build and read it. Kept rather than
    /// rewritten everywhere so both sides can spell it unqualified or `TerminalPaneService`-qualified.
    typealias TerminalSessionSummaryMatch = AppKitController.TerminalSessionSummaryMatch

    /// Transitional alias: `DeviceTerminalOpenRequest` stays on `AppKitController` because it is the
    /// general terminal-open payload, built and read well beyond the terminal-pane domain (window focus
    /// resolution, device window shortcuts, automation run resolution, IPC decoding). Kept rather than
    /// rewritten everywhere so this service's pane-open code can spell it unqualified.
    typealias DeviceTerminalOpenRequest = AppKitController.DeviceTerminalOpenRequest

    nonisolated private static func terminalSessionLaunchConfiguration(sessionID: String, summary: SpacesDeviceTerminalSessionSummary)
        -> TerminalSessionLaunchConfiguration
    {
        TerminalSessionLaunchConfiguration(
            sessionID: sessionID, backend: summary.backend, lifetimePolicy: summary.lifetimePolicy, title: summary.title,
            workingDirectory: summary.workingDirectory, shell: summary.shell, command: summary.command, createdAt: summary.createdAt,
            workspaceID: summary.workspaceID, kind: AppKitController.terminalSessionKind(rowKind: summary.rowKind))
    }

    nonisolated private static func terminalSessionRuntimeState(sessionID: String, summary: SpacesDeviceTerminalSessionSummary)
        -> TerminalSessionRuntimeState
    {
        TerminalSessionRuntimeState(
            sessionID: sessionID, backend: summary.backend, servicePID: summary.servicePID, childPID: summary.childPID, state: summary.state,
            updatedAt: summary.updatedAt, title: summary.title, workingDirectory: summary.workingDirectory, bellAt: summary.bellAt)
    }

    /// Builds the device-backed terminal state model for a session, seeding launch
    /// configuration and runtime state from the caller's known values or, failing that,
    /// the loaded device overview or an off-main cold overview lookup prepared by the
    /// caller. The model fetches the rest through the owning device's Device API, so the
    /// mac GUI never opens `spaces.db`.
    private func makeTerminalSessionStateModel(
        sessionID: String, seedDevice: SpacesPairedDeviceRecord? = nil, seedLaunchConfiguration: TerminalSessionLaunchConfiguration? = nil,
        seedInitialRuntimeState: TerminalSessionRuntimeState? = nil, resolvedSummaryMatch: TerminalSessionSummaryMatch? = nil,
        preparedCredentials: DeviceTerminalSessionStateModel.PreparedCredentials
    ) throws -> DeviceTerminalSessionStateModel {
        let summaryMatch = host.terminalSessionSummaryMatch(sessionID: sessionID) ?? resolvedSummaryMatch
        guard let device = seedDevice ?? summaryMatch?.device ?? host.terminalSessionOwningDevice(sessionID: sessionID) else {
            throw AppKitController.deviceNotLoadedError()
        }
        // The launch configuration carries the daemon's real shell/command, which the live
        // Device API state payload never resends (it carries only title/cwd/runtime). It must
        // come from the caller's seed or the device overview — fabricating a placeholder here
        // would leave the window summary showing the wrong launch command for the session's
        // lifetime.
        guard
            let launchConfiguration = seedLaunchConfiguration
                ?? summaryMatch.map({ Self.terminalSessionLaunchConfiguration(sessionID: sessionID, summary: $0.summary) })
        else { throw AppKitController.terminalSessionNotFoundError() }
        let initialRuntimeState =
            seedInitialRuntimeState ?? summaryMatch.map { Self.terminalSessionRuntimeState(sessionID: sessionID, summary: $0.summary) }
        return try DeviceTerminalSessionStateModel(
            device: device, sessionID: sessionID, launchConfiguration: launchConfiguration, initialRuntimeState: initialRuntimeState,
            initialAttachmentSnapshot: summaryMatch?.summary.attachmentSnapshot,
            clientApp: SpacesDeviceClient.macOSClientApp(appVersion: AppVersion.short), preparedCredentials: preparedCredentials)
    }

    func prepareTerminalPaneOpenRequest(_ request: DeviceTerminalOpenRequest) async -> Result<DeviceTerminalOpenRequest, Error> {
        if request.preparedCredentials != nil { return .success(request) }
        // Opening a pane connects to the owning daemon, so an unreachable device is refused here with
        // the same named-and-offline message its other actions carry rather than a generic not-loaded
        // one the user can see they are not in.
        let requestedDeviceID = request.deviceID ?? host.deviceID(forWorkspaceID: request.workspaceID)
        guard let requestedDeviceID, let device = host.deviceForMutation(deviceID: requestedDeviceID) else {
            return .failure(host.deviceUnavailableError(deviceID: requestedDeviceID))
        }
        let clientApp = SpacesDeviceClient.macOSClientApp(appVersion: AppVersion.short)
        let isLocalDevice = device.id == SpacesPairedDeviceRecord.localDeviceID
        // For the local device, re-resolve the daemon's current Device API port (and ensure it is
        // running) the way the CLI does per request. The stored paired_devices row goes stale when
        // the local daemon idle-shuts-down and rebinds a port; seeding the fresh endpoint here — off
        // the main actor, before the model and its request client are built — keeps the pane's first
        // control connect fast instead of blocking the main actor on a dead port. The bootstrap goes
        // through the process-wide single-flight shared with the models' recovery paths: pane
        // restoration prepares many panes concurrently, and uncoalesced bootstraps presenting the
        // same stale token would each mint a distinct replacement, seeding all but the last-prepared
        // pane with an already-revoked token. Best-effort: a failed re-resolution falls back to the
        // stored row, and the model's connect-time recovery still heals the port later.
        let refreshedLocalDevice = isLocalDevice ? await LocalDeviceRecoveryBootstrap.run(clientApp: clientApp)?.record : nil
        let result: Result<DeviceTerminalSessionStateModel.PreparedCredentials, Error> = await Task.detached(priority: .userInitiated) {
            do {
                // Resolve credentials from the same record the endpoint came from: the bootstrap above may
                // have re-paired against a daemon whose TLS identity rotated, so `resolveCredentials` must
                // read the refreshed record's fingerprint. Resolving before the bootstrap would pair the
                // rotated daemon's fresh host/port with the stale token file's fingerprint — its
                // re-bootstrap branch only fires on a missing token — and pin-fail every connect.
                let credentials = try DeviceTerminalSessionStateModel.resolveCredentials(
                    context: DeviceRequestContext(device: refreshedLocalDevice ?? device, clientApp: clientApp))
                return .success(credentials)
            } catch { return .failure(error) }
        }.value
        return result.map { credentials in request.prepared(credentials: credentials, resolvedLocalDevice: refreshedLocalDevice) }
    }

    /// The pane open request for a session resolved to its owning device, pinning `deviceID` so the
    /// pane attaches to that device — remote or local — regardless of the request's later workspace
    /// device lookup. Shared by the cold-resolve path and the remote deep-link open.
    nonisolated static func terminalSessionPaneOpenRequest(from match: TerminalSessionSummaryMatch) -> DeviceTerminalOpenRequest {
        terminalSessionPaneOpenRequest(summary: match.summary, deviceID: match.device.id)
    }

    nonisolated static func terminalSessionPaneOpenRequest(summary: SpacesDeviceTerminalSessionSummary, deviceID: String) -> DeviceTerminalOpenRequest
    {
        return DeviceTerminalOpenRequest(
            workspaceID: summary.workspaceID, deviceID: deviceID, sessionID: summary.id, title: summary.title,
            workingDirectory: summary.workingDirectory, kind: AppKitController.terminalSessionKind(rowKind: summary.rowKind), shell: summary.shell,
            command: summary.command, initialState: summary.state, servicePID: summary.servicePID, childPID: summary.childPID,
            createdAt: summary.createdAt, updatedAt: summary.updatedAt)
    }

    /// Builds the live terminal content controller for a pane: a device-backed terminal
    /// state model plus the Device API control closures, hosted by the window-independent
    /// pane view controller. Local and remote sessions share this one path. Returns nil
    /// (surfacing the error) when the session's paths or state model cannot be built.
    /// - Parameter focusIntent: The intent of the open needing this content, so a construction failure is
    ///   reported the same way a preparation failure is: modally only for an open the user is waiting on.
    func makeTerminalPaneContent(request: DeviceTerminalOpenRequest, focusIntent: TerminalOpenFocusIntent) -> TerminalPaneContentController? {
        let sessionID = request.sessionID
        do {
            let paths = try TerminalSessionPaths.forSession(id: sessionID)
            // A global-window pane can mix devices, so its request carries deviceID
            // directly; otherwise it derives from the request's workspace. The id is the pane
            // descriptor's device key and decides local-vs-remote link handling, so a workspace
            // no loaded section claims raises not-loaded instead of being treated as local.
            guard let resolvedDeviceID = request.deviceID ?? host.deviceID(forWorkspaceID: request.workspaceID) else {
                throw AppKitController.deviceNotLoadedError()
            }
            // Prefer the local device endpoint re-resolved during preparation (current port, daemon
            // ensured running) over the possibly-stale stored row, so the model's request client and
            // subscription stream target a live port from the start (issue #185). Remote devices carry
            // `nil` here and use the stored record.
            let device = request.resolvedLocalDevice ?? host.deviceForMutation(deviceID: resolvedDeviceID)
            guard let preparedCredentials = request.preparedCredentials else {
                throw WorkspaceError.invalidArgument(message: "Terminal credentials are still preparing.")
            }
            let summary = host.terminalSessionSummaryMatch(sessionID: sessionID)?.summary
            let createdAt = request.createdAt ?? iso8601Formatter.string(from: Date())
            // The seed launch configuration wins over the state model's own summary lookup,
            // and the live Device API state payload never resends shell/command, so seed one
            // only when a real shell is known — from the request (resolved from the source
            // overview) or the loaded summary for a row-built request. Fabricating a
            // "/bin/bash" placeholder here would mislabel the pane's launch command for the
            // session's lifetime; with no seed the state model builds from the loaded summary
            // and a session unknown to both surfaces an error instead.
            let launchConfiguration = (request.shell ?? summary?.shell).map { shell in
                TerminalSessionLaunchConfiguration(
                    sessionID: sessionID, backend: .ghosttyEmbedded, title: request.title, workingDirectory: request.workingDirectory, shell: shell,
                    command: request.command ?? summary?.command, createdAt: createdAt, workspaceID: request.workspaceID, kind: request.kind)
            }
            let initialRuntimeState = request.initialState.map {
                TerminalSessionRuntimeState(
                    sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: request.servicePID ?? 0, childPID: request.childPID, state: $0,
                    updatedAt: request.updatedAt ?? createdAt, title: request.title, workingDirectory: request.workingDirectory)
            }
            let stateModel = try makeTerminalSessionStateModel(
                sessionID: sessionID, seedDevice: device, seedLaunchConfiguration: launchConfiguration, seedInitialRuntimeState: initialRuntimeState,
                resolvedSummaryMatch: nil, preparedCredentials: preparedCredentials)
            let requestSender = stateModel.terminalServiceRequestSender
            let applyControlState = stateModel.controlStateApplier
            let agentSignalHandler: RemoteGhosttyAgentSignalHandler = { [weak self] events in
                guard let self else { return [String]() }
                return self.applyRemoteAgentSignals(events)
            }
            let remoteClientStore = RemoteTerminalWindowClientStore()
            // Reuse the owner client id this device stored on its last successful owner attach/takeover
            // for this session so a relaunch of this Mac (e.g. after an app upgrade) presents the same id
            // and silently reclaims the still-running session's orphaned `localWindow` owner attachment.
            // Keyed by the local device id; a stale mapping is inert since it matches no current owner.
            let ownerClientIDStore = ClientTerminalOwnerClientIDStore()
            let reusableOwnerClientID = try? ownerClientIDStore.clientID(sessionID: sessionID)
            // Resolved once here (this runs on the main actor); the attach closure is @Sendable and may
            // run off-main, so it cannot read NSApp. Seeds the shared appearance store, which the attach
            // reads when it fires and the broadcast path advances on a mid-session appearance change
            // (settings picker or an OS flip while on `.system`) — so an appearance change that lands
            // before the pane attaches is carried by the attach, and one after it re-themes the live
            // session without waiting for a reopen.
            let themeAppearance: ThemeAppearance = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light
            let appearanceStore = SessionAppearanceStore(themeAppearance)
            let attachClientAction: @Sendable (TerminalClient, TerminalAttachmentMode) throws -> Void = { client, attachmentMode in
                remoteClientStore.set(client.id)
                let response = try Self.sendDeviceTerminalControl(
                    sessionID: sessionID,
                    request: TerminalControlRequest(
                        command: .attach(
                            TerminalControlAttachPayload(client: client, attachmentMode: attachmentMode, appearance: appearanceStore.current()))),
                    requestSender: requestSender, refreshStateAfterControl: true, applyState: applyControlState)
                guard response.ok else { throw WorkspaceError.invalidArgument(message: response.message) }
                // Persist the owner client id only once the daemon confirms this client attached as
                // OWNER, so a relaunch of this Mac reuses it and silently reclaims the still-running
                // session's orphaned owner attachment. Not optimistic: response.ok means the daemon
                // recorded this client as the owner attachment.
                if attachmentMode == .owner { try? ownerClientIDStore.setClientID(sessionID: sessionID, clientID: client.id) }
            }
            let detachClientAction: @Sendable (String) throws -> Void = { clientID in
                if remoteClientStore.current() == clientID { remoteClientStore.set(nil) }
                let response = try Self.sendDeviceTerminalControl(
                    sessionID: sessionID, request: TerminalControlRequest(command: .detach(TerminalControlClientPayload(clientID: clientID))),
                    requestSender: requestSender, refreshStateAfterControl: true, applyState: applyControlState)
                guard response.ok else { throw WorkspaceError.invalidArgument(message: response.message) }
            }
            let sendInputAction: @Sendable (String, Bool) throws -> TerminalControlResponse = { text, appendNewline in
                guard let clientID = remoteClientStore.current() else {
                    return TerminalControlResponse(ok: false, message: "Terminal pane is not attached.")
                }
                return try Self.sendDeviceTerminalControl(
                    sessionID: sessionID,
                    request: TerminalControlRequest(
                        command: .send(
                            TerminalControlSendPayload(text: text, bytes: nil, clientID: clientID, ownerEpoch: nil, appendNewline: appendNewline))),
                    requestSender: requestSender, applyState: applyControlState)
            }
            let sendKeyAction: @Sendable (String) throws -> TerminalControlResponse = { key in
                guard let clientID = remoteClientStore.current() else {
                    return TerminalControlResponse(ok: false, message: "Terminal pane is not attached.")
                }
                return try Self.sendDeviceTerminalControl(
                    sessionID: sessionID,
                    request: TerminalControlRequest(command: .key(TerminalControlKeyPayload(key: key, clientID: clientID, ownerEpoch: nil))),
                    requestSender: requestSender, applyState: applyControlState)
            }
            let pasteImageAction: @MainActor (TerminalPasteboardImage) async throws -> TerminalControlResponse = { image in
                guard let clientID = remoteClientStore.current() else {
                    return TerminalControlResponse(ok: false, message: "Terminal pane is not attached.")
                }
                // Send whatever owner epoch the cached payload carries, absent included: a payload with no
                // render owner epoch (an owner change, or an input-reason payload) means this paste is not
                // epoch-gated, exactly like every other input path this pane sends.
                return try await stateModel.pasteImage(image, clientID: clientID, ownerEpoch: stateModel.latestRemoteStatePayload?.renderOwnerEpoch)
            }
            let takeoverAction: @Sendable (String) throws -> TerminalControlResponse = { clientID in
                let response = try Self.sendDeviceTerminalControl(
                    sessionID: sessionID, request: TerminalControlRequest(command: .takeover(TerminalControlClientPayload(clientID: clientID))),
                    requestSender: requestSender, refreshStateAfterControl: true, applyState: applyControlState)
                // A successful takeover transfers ownership to this client on the daemon via
                // `transferOwnership` (not a re-attach through `attachClientAction`), so persist the
                // owner id here too — otherwise the reclaimed-after-takeover id would not survive a
                // relaunch.
                if response.ok { try? ownerClientIDStore.setClientID(sessionID: sessionID, clientID: clientID) }
                return response
            }
            // Re-themes this session to a new app appearance mid-session (see `applyAppearanceToLiveSession`).
            // Reuses the pane's captured request sender and `remoteClientStore` clientID, mirroring the input
            // closures above. The dedupe/desired state lives in `appearanceStore`, which the attach also reads,
            // so a change that arrives before attach is recorded here and carried by the pending attach.
            let setAppearanceAction: (ThemeAppearance) -> Void = { appearance in
                appearanceStore.set(
                    Self.applyAppearanceToLiveSession(
                        appearance, sessionID: sessionID, clientID: remoteClientStore.current(), lastAppliedAppearance: appearanceStore.current(),
                        requestSender: requestSender, applyState: applyControlState))
            }
            // The mirror view's link handler is captured when the pane is built, but the coordinator that
            // routes clicks needs the pane's view for its banner and so can only be built afterward. The
            // handler box bridges that ordering: the session-host provider reads it lazily on the first
            // link click, long after the coordinator has been attached below.
            let linkOpenBox = TerminalLinkOpenHandlerBox()
            let pane = TerminalSessionPaneViewController(
                sessionID: sessionID, paths: paths, stateProvider: stateModel, preferredAttachmentMode: .owner, performInitialRefresh: false,
                reusableOwnerClientID: reusableOwnerClientID, sendInputAction: sendInputAction, sendKeyAction: sendKeyAction,
                pasteImageAction: pasteImageAction, takeoverAction: takeoverAction, attachClientAction: attachClientAction,
                detachClientAction: detachClientAction,
                onCloseClientDetached: { [weak host] ownedOrEnded in
                    host?.stopAdHocBuiltInTerminalSessionIfBareShell(sessionID: sessionID, closedPaneOwnedOrEnded: ownedOrEnded)
                },
                sessionHostProvider: { launchConfiguration, paths in
                    Self.terminalSessionHost(
                        launchConfiguration: launchConfiguration, paths: paths, terminalServiceRequestSender: requestSender,
                        stateStreamSubscriber: stateModel.makeHostStateStreamSubscriber(),
                        transcriptProvider: { [weak stateModel] maxBytes in
                            guard let stateModel else { throw WorkspaceError.invalidArgument(message: "Terminal state model was released.") }
                            return try await stateModel.fetchTranscript(maxBytes: maxBytes)
                        }, agentSignalHandler: agentSignalHandler, linkOpenHandler: { [linkOpenBox] rawLink in linkOpenBox.open(rawLink) },
                        // A keystroke that cannot reach the device is the pane's earliest evidence its link
                        // is gone; the state model owns that verdict, so the raw failure goes there rather
                        // than being classified or acted on at the render host. `reportFailedInputSend` is
                        // main-actor-isolated and this handler is not, so `await` straight into it — its
                        // return value is exactly the `RemoteGhosttyInputFailureHandler` contract (whether
                        // the failure proves the link is gone), and the host awaits it to decide whether to
                        // drop this pane's queued input.
                        inputFailureHandler: { [weak stateModel] error in await stateModel?.reportFailedInputSend(error) ?? false })
                })
            let linkOpenCoordinator = TerminalLinkOpenCoordinator(
                sessionID: sessionID, deviceID: resolvedDeviceID, isLocalDevice: resolvedDeviceID == SpacesPairedDeviceRecord.localDeviceID,
                workingDirectoryProvider: { [weak stateModel] in
                    let payload = stateModel?.latestRemoteStatePayload
                    return Self.terminalLinkWorkingDirectory(
                        runtimeState: stateModel?.currentRuntimeState ?? payload?.runtimeState, streamedWorkingDirectory: payload?.workingDirectory,
                        launchWorkingDirectory: stateModel?.currentLaunchConfiguration?.workingDirectory,
                        requestWorkingDirectory: request.workingDirectory)
                }, requestSender: requestSender, banner: pane.banner,
                openSpacesTerminalLink: { [weak host] link in host?.handleTerminalDeepLink(link) })
            linkOpenBox.coordinator = linkOpenCoordinator
            let content = TerminalPaneContentController(
                descriptor: .terminalSession(deviceID: resolvedDeviceID, sessionID: sessionID), workspaceID: request.workspaceID,
                sessionID: sessionID, pane: pane, setAppearanceAction: setAppearanceAction,
                terminalTextZoomAction: { [weak host] command in host?.adjustTerminalTextSize(command) }, linkOpenCoordinator: linkOpenCoordinator)
            // The size is app-wide and already loaded, so a pane opens at it rather than at the default
            // and waiting for the next change.
            content.applyTerminalTextSize(terminalTextSize)
            return content
        } catch {
            reportTerminalPaneOpenFailure(error, focusIntent: focusIntent)
            return nil
        }
    }

    private final class RemoteTerminalWindowClientStore: @unchecked Sendable {
        private let lock = NSLock()
        private var clientID: String?

        func set(_ clientID: String?) {
            lock.lock()
            self.clientID = clientID
            lock.unlock()
        }

        func current() -> String? {
            lock.lock()
            defer { lock.unlock() }
            return clientID
        }
    }

    /// Per-session, thread-safe appearance state shared between a live pane's attach closure (which
    /// reads it when the client attaches, off the main actor) and the appearance-broadcast path (which
    /// advances it on an app appearance change). One value across both means an appearance change that
    /// lands before the pane attaches is carried by the pending attach rather than lost, and it doubles
    /// as the per-session dedupe state for `applyAppearanceToLiveSession`.
    private final class SessionAppearanceStore: @unchecked Sendable {
        private let lock = NSLock()
        private var appearance: ThemeAppearance

        init(_ appearance: ThemeAppearance) { self.appearance = appearance }

        func set(_ appearance: ThemeAppearance) {
            lock.lock()
            self.appearance = appearance
            lock.unlock()
        }

        func current() -> ThemeAppearance {
            lock.lock()
            defer { lock.unlock() }
            return appearance
        }
    }

    nonisolated static func terminalLinkWorkingDirectory(
        runtimeState: TerminalSessionRuntimeState?, streamedWorkingDirectory: String?, launchWorkingDirectory: String?,
        requestWorkingDirectory: String
    ) -> String {
        if let liveWorkingDirectory = liveTerminalWorkingDirectory(runtimeState: runtimeState) { return liveWorkingDirectory }
        if let workingDirectory = normalizedTerminalWorkingDirectory(runtimeState?.workingDirectory) { return workingDirectory }
        if let workingDirectory = normalizedTerminalWorkingDirectory(streamedWorkingDirectory) { return workingDirectory }
        if let workingDirectory = normalizedTerminalWorkingDirectory(launchWorkingDirectory) { return workingDirectory }
        return requestWorkingDirectory
    }

    private nonisolated static func liveTerminalWorkingDirectory(runtimeState: TerminalSessionRuntimeState?) -> String? {
        guard let runtimeState else { return nil }
        if let foregroundPID = runtimeState.foregroundPID, let cwd = TerminalForegroundProcessInspector.workingDirectory(pid: foregroundPID) {
            return cwd
        }
        if let childPID = runtimeState.childPID, let cwd = TerminalForegroundProcessInspector.workingDirectory(pid: childPID) { return cwd }
        return nil
    }

    private nonisolated static func normalizedTerminalWorkingDirectory(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    // ISO8601DateFormatter construction is expensive and `makeTerminalPaneContent` is the only reader,
    // so one lazily-built instance is shared across every pane it builds rather than allocating a fresh
    // formatter per call. `AppKitController` keeps its own separate `staticISO8601Formatter` for its
    // nonisolated overview-mapping helpers, which cannot reach this instance-scoped one.
    private lazy var iso8601Formatter: ISO8601DateFormatter = ISO8601DateFormatter()

    /// Starts a fresh ad hoc terminal session on the workspace's owning daemon and
    /// resolves the pane open request for panel entry points.
    func createTerminalSessionForPane(workspaceID: String, completion: @escaping (DeviceTerminalOpenRequest?) -> Void) {
        guard let device = host.deviceForWorkspaceMutation(workspaceID: workspaceID) else {
            host.showWorkspaceDeviceUnavailableError(workspaceID: workspaceID)
            completion(nil)
            return
        }
        // This Task can outlive the moment it was scheduled: it suspends on the await below and may
        // resume much later. `host` is `unowned` on this service, which is only safe to read while
        // something else is guaranteed to keep the host alive; a suspended Task is not that guarantee.
        // Capturing `host` strongly here evaluates the capture synchronously at Task creation, while the
        // host is certainly alive, so the Task pins its own strong reference for its whole lifetime
        // instead of re-reading the unowned property after resuming.
        Task { @MainActor [weak self, host] in
            guard self != nil else {
                completion(nil)
                return
            }
            let epoch = host.panelCoordinator.paneReplacementEpoch
            let result = await AppKitController.deviceMutation(device: device) { device in
                try SpacesDeviceClient.openWorkspaceTerminal(
                    workspaceID: workspaceID,
                    context: DeviceRequestContext(device: device, clientApp: SpacesDeviceClient.macOSClientApp(appVersion: AppVersion.short)))
            }
            switch result {
            case .success(let response):
                host.applyDeviceMutationResponse(response, deviceID: device.id, epoch: epoch, selectedWorkspaceID: workspaceID)
                guard let request = host.terminalOpenRequest(fromMutationResponse: response, workspaceID: workspaceID) else {
                    completion(nil)
                    return
                }
                completion(request)
            case .failure(let error):
                host.showError(error)
                completion(nil)
            }
        }
    }

    nonisolated static func deviceTerminalControlRequest(sessionID: String, controlRequest request: TerminalControlRequest) throws
        -> SpacesDeviceTerminalControlRequest
    {
        guard request.bytes == nil else {
            throw WorkspaceError.invalidArgument(message: "Raw byte terminal control is not supported for active remote devices.")
        }
        let command = request.commandValue
        guard let action = SpacesDeviceTerminalControlAction(rawValue: command.name) else {
            throw WorkspaceError.invalidArgument(message: "Unsupported remote terminal command '\(command.name)'.")
        }
        return SpacesDeviceTerminalControlRequest(
            action: action, sessionID: sessionID, clientID: request.clientID, client: request.client, attachmentMode: request.attachmentMode,
            text: request.text, key: request.key, columns: request.columns, rows: request.rows, ownerEpoch: request.ownerEpoch,
            resizeSerial: request.resizeSerial, scrollHorizontal: request.scrollHorizontal, scrollVertical: request.scrollVertical,
            scrollMods: request.scrollMods, scrollPointerX: request.scrollPointerX, scrollPointerY: request.scrollPointerY,
            scrollPointerMods: request.scrollPointerMods, mouseButton: request.mouseButton, mousePressed: request.mousePressed,
            mousePointerX: request.mousePointerX, mousePointerY: request.mousePointerY, mousePointerMods: request.mousePointerMods,
            appendNewline: request.appendNewline, asPaste: request.asPaste, appearance: request.appearance,
            selectionStartColumn: request.selectionStartColumn, selectionStartRow: request.selectionStartRow,
            selectionEndColumn: request.selectionEndColumn, selectionEndRow: request.selectionEndRow, selectionRectangle: request.selectionRectangle)
    }

    /// Issues a terminal control request to the session's owning device and returns
    /// the control response. When the response carries session state (notably a
    /// successful takeover), it is applied to the state model immediately so the
    /// window reflects the new owner without waiting for the live subscription.
    ///
    /// Attachment-changing controls (attach/detach, and takeover when the daemon
    /// omits the post-takeover render) do not echo session state, so
    /// `refreshStateAfterControl` fetches the post-control state and applies the new
    /// ownership directly. This forces the state model off its pre-control attachment
    /// snapshot at once rather than depending on the live subscription to redeliver
    /// the change — the subscription may be connecting or reconnecting during window
    /// open/close, which would otherwise leave the window showing the wrong owner (or
    /// retrying attachments) until another stream event arrives. The follow-up fetch
    /// is best-effort: the control already succeeded, and a stale-by-emission payload
    /// is dropped by the model, so a failed refresh falls back to the subscription
    /// instead of failing the completed control.
    nonisolated static func sendDeviceTerminalControl(
        sessionID: String, request: TerminalControlRequest, requestSender: RemoteGhosttyTerminalServiceRequestSender,
        refreshStateAfterControl: Bool = false, applyState: @Sendable (GhosttyRemoteSessionStatePayload) -> Void
    ) throws -> TerminalControlResponse {
        let response = try requestSender(TerminalServiceRequest(command: .control(.init(sessionID: sessionID, controlRequest: request))))
        guard response.ok else { throw WorkspaceError.invalidArgument(message: response.message) }
        if let sessionState = response.sessionState {
            applyState(sessionState)
        } else if refreshStateAfterControl,
            let stateResponse = try? requestSender(TerminalServiceRequest(command: .state(.init(sessionID: sessionID)))),
            let sessionState = stateResponse.sessionState
        {
            applyState(sessionState)
        }
        return response.controlResponse ?? TerminalControlResponse(ok: response.ok, message: response.message)
    }

    /// Re-themes one live session to `appearance` by sending `setAppearance`, and returns the appearance the
    /// session's store should now carry. A redundant re-theme (already on `appearance`) sends nothing and keeps
    /// the value. When no client is attached yet the send is skipped but the value still advances to `appearance`
    /// so the pending attach carries it — otherwise a change that lands before attach would be lost, and later
    /// broadcasts of the actual variant would dedupe against a stale value until the next flip. `clientID` is
    /// trace-only for setAppearance — appearance is deliberately not owner-gated — but the daemon still expects
    /// one. Best-effort: a failed send returns `lastAppliedAppearance` unchanged so the next flip retries it.
    nonisolated static func applyAppearanceToLiveSession(
        _ appearance: ThemeAppearance, sessionID: String, clientID: String?, lastAppliedAppearance: ThemeAppearance,
        requestSender: RemoteGhosttyTerminalServiceRequestSender, applyState: @Sendable (GhosttyRemoteSessionStatePayload) -> Void
    ) -> ThemeAppearance {
        guard appearance != lastAppliedAppearance else { return lastAppliedAppearance }
        guard let clientID else { return appearance }
        do {
            _ = try sendDeviceTerminalControl(
                sessionID: sessionID,
                request: TerminalControlRequest(
                    command: .setAppearance(TerminalControlSetAppearancePayload(clientID: clientID, appearance: appearance))),
                requestSender: requestSender, applyState: applyState)
            return appearance
        } catch { return lastAppliedAppearance }
    }

    private func applyRemoteAgentSignals(_ events: [TerminalServiceAgentSignalEvent]) -> [String] {
        // Agent state is recorded by the daemon that owns the session and reaches this
        // client through the overview, so the window only acknowledges delivery to
        // release the owning terminal service's signal queue.
        events.map(\.id)
    }

    /// Pure kind resolution over the loaded device overviews: top-level sessions carry
    /// their row kind, and process/agent rows identify configured workspace sessions.
    /// Automation runs are also consulted before falling back to `.shell`: a run's own
    /// command session resolves to `.automation` and any coding agent it spawned resolves
    /// to `.agent`. This keeps retained sessions correctly typed after their live workspace
    /// runtime target leaves the overview.
    nonisolated static func terminalSessionKind(sessionID: String, overviews: [SpacesDeviceOverviewPayload]) -> TerminalSessionKind {
        for overview in overviews {
            if let session = overview.sessions.first(where: { $0.id == sessionID }) {
                return AppKitController.terminalSessionKind(rowKind: session.rowKind)
            }
            for workspace in overview.workspaces {
                if workspace.processRows.contains(where: { $0.sessionID == sessionID }) { return .process }
                if workspace.codingAgentRows.contains(where: { $0.sessionID == sessionID }) { return .agent }
            }
            for run in overview.automationRuns {
                if run.terminalSessionID == sessionID { return .automation }
                if run.attributedAgents.contains(where: { $0.terminalSessionID == sessionID }) { return .agent }
            }
        }
        return .shell
    }

    /// Closes a session's pane for the close IPC and daemon-driven session
    /// termination, keeping the `terminal_window_close` perf metric the E2E harness
    /// parses.
    /// Forwards a close to the coordinator unconditionally, and decides only what to report.
    ///
    /// Deliberately not gated on the session having a pane in memory. A restart's `awaitReplacement`
    /// close is most often for a workspace the user is not viewing, whose panel has never been
    /// materialized, and that is precisely the case whose pane position the hold exists to protect: the
    /// coordinator records the hold against the persisted layout with no placement to point at. A
    /// placement gate here would swallow the disposition before it ever reached that, and the observable
    /// result is the whole bug the hold prevents, so the gate is a reporting detail only.
    ///
    /// Not private: this handler layer, rather than the coordinator underneath it, is where a swallowed
    /// disposition can hide, so it is reachable from tests.
    func closeTerminalSessionPane(sessionID: String, sessionIsTerminating: Bool = false, disposition: TerminalPaneCloseDisposition = .teardown) {
        let startedAt = Date()
        let closeDetail = "terminating=\(sessionIsTerminating ? 1 : 0) disposition=\(disposition.rawValue)"
        let route = Self.terminalPaneCloseRoute(
            hasPlacement: host.panelCoordinator.placement(forSessionID: sessionID) != nil, disposition: disposition)
        host.logPerfMetric(
            "terminal_window_close", target: "session=\(sessionID)", elapsedMS: host.windowShortcutElapsedMS(since: startedAt),
            success: route != .missingPane, detail: "route=\(route.rawValue) \(closeDetail)")
        host.panelCoordinator.closePane(forSessionID: sessionID, sessionIsTerminating: sessionIsTerminating, disposition: disposition)
    }

    /// Whether closing a terminal pane should ask the daemon to stop the ad hoc session behind it.
    /// Only an owner close does, or the close of a pane whose session has already ended (an explicit
    /// close is the user dismissing that terminal, and the ask is what removes its row): for a live
    /// session, a viewer's close leaves it with its owner, but a viewer is not a distinct case once the
    /// session has ended, since any pane of an ended session reports as ended and asks. A quit that keeps
    /// sessions running must leave every session alone. Whether the session is ad hoc at all, and whether
    /// it is idle at a bare prompt, are the daemon's to decide.
    nonisolated static func shouldRequestAdHocBareShellStopOnPaneClose(closedPaneOwnedOrEnded: Bool, isAppTerminatingAndKeepingSessions: Bool) -> Bool
    {
        guard !isAppTerminatingAndKeepingSessions else { return false }
        return closedPaneOwnedOrEnded
    }

    @MainActor static func terminalSessionHost(
        launchConfiguration: TerminalSessionLaunchConfiguration, paths: TerminalSessionPaths,
        terminalServiceRequestSender: RemoteGhosttyTerminalServiceRequestSender? = nil,
        stateStreamSubscriber: RemoteGhosttyStateStreamSubscriber? = nil, transcriptProvider: RemoteGhosttyTranscriptProvider? = nil,
        agentSignalHandler: RemoteGhosttyAgentSignalHandler? = nil, linkOpenHandler: (@MainActor (String) -> Void)? = nil,
        inputFailureHandler: RemoteGhosttyInputFailureHandler? = nil
    ) -> any TerminalGhosttySessionHosting {
        RemoteGhosttySessionHost(
            launchConfiguration: launchConfiguration, paths: paths, terminalServiceRequestSender: terminalServiceRequestSender,
            stateStreamSubscriber: stateStreamSubscriber, transcriptProvider: transcriptProvider, agentSignalHandler: agentSignalHandler,
            linkOpenHandler: linkOpenHandler, inputFailureHandler: inputFailureHandler)
    }

    nonisolated static func appBuiltInTerminalSessionLauncher(
        createSession: @escaping @Sendable (TerminalSessionLaunchConfiguration) throws -> TerminalServiceSessionSummary = {
            try TerminalService.createSession($0)
        }
    ) -> WorkspaceOrchestrator.BuiltInTerminalSessionLauncher { { launchConfiguration in try createSession(launchConfiguration) } }

    nonisolated static func terminateBuiltInTerminalSession(sessionID: String) {
        try? performBuiltInTerminalSessionWorkOnMainThread {
            (NSApp.delegate as? AppKitController)?.terminalPanes.closeTerminalSessionPane(sessionID: sessionID, sessionIsTerminating: true)
            try? TerminalService.terminateSession(id: sessionID)
        }
    }

    nonisolated static func performBuiltInTerminalSessionWorkOnMainThread<T: Sendable>(
        isMainThread: Bool = Thread.isMainThread,
        scheduler: @escaping (@escaping @Sendable () -> Void) -> Void = { action in DispatchQueue.main.async(execute: action) },
        work: @escaping @MainActor () throws -> T
    ) throws -> T {
        if isMainThread { return try MainActor.assumeIsolated { try work() } }

        let semaphore = DispatchSemaphore(value: 0)
        let resultBox = MainThreadResultBox<T>()
        scheduler {
            resultBox.set(Result { try MainActor.assumeIsolated { try work() } })
            semaphore.signal()
        }
        semaphore.wait()
        guard let result = resultBox.get() else {
            throw WorkspaceError.invalidArgument(message: "Built-in terminal main-thread work did not return a result.")
        }
        return try result.get()
    }

    nonisolated static func terminalQuitPolicy(liveTerminalSessionCount: Int) -> TerminalQuitPolicy {
        liveTerminalSessionCount > 0 ? .promptForLiveSessions(count: liveTerminalSessionCount) : .quitImmediately
    }

    nonisolated static func liveBuiltInTerminalSessions(listSessions: () throws -> [TerminalServiceSessionSummary] = TerminalService.listSessions)
        -> [TerminalServiceSessionSummary]
    { (try? listSessions()) ?? [] }

    /// Whether a terminal target may be acted on at all, given whether its session already occupies a
    /// pane and whether its owning device can service daemon-backed work. This is the line between the
    /// two operations `openOrFocusTerminalPane` performs.
    ///
    /// Focusing a pane that already exists is client-side: the pane owns its state model and renders
    /// its own disconnected notice, so an unreachable device never withholds it — an open pane on a
    /// device that dropped is exactly what that notice is for. Installing a pane the layout does not
    /// have yet can only work by attaching to the owning daemon, so it is refused while that device
    /// cannot act — and refused *before* the install, because installing adds the pane to the layout
    /// and persists it before credentials are prepared: a pane admitted here would be saved as
    /// permanently failed and would not retry when the device came back. Pure so the
    /// "focus, don't open" line is directly testable.
    nonisolated static func canOpenOrFocusTerminalPane(hasExistingPane: Bool, deviceAcceptsDaemonActions: Bool) -> Bool {
        hasExistingPane || deviceAcceptsDaemonActions
    }

    /// Whether a fresh code pane may be created for a device. Unlike
    /// `canOpenOrFocusTerminalPane`, this takes no `hasExistingPane` flag: a code pane has
    /// no daemon-side session to attach, but building its content still means installing a
    /// pane into the layout and persisting it, so a device that cannot act right now must
    /// not have one added on its behalf. `PanelCoordinator.openCodePaneInNewTab` is reached
    /// only from `openOrFocusGlobalEditorWindow`'s "nothing to reuse" branch — the
    /// "reuse an existing global pane" branch focuses (and, if needed, retargets) it and
    /// returns before creation is even considered — so this only ever needs to ask "can we
    /// create," never "can we create or is one already there." Pure for the same test-seam
    /// reason as `canOpenOrFocusTerminalPane`.
    nonisolated static func canCreateCodePane(deviceAcceptsDaemonActions: Bool) -> Bool { deviceAcceptsDaemonActions }

    /// Whether re-showing a session can stop at foregrounding its panel and restoring the caret, instead of
    /// running the open path's state fetch, attach, and ownership reclaim. All three conditions are load
    /// bearing: the pane must be the focused one in the panel's selected tab (anything else has to move
    /// focus, which re-activates the content), and it must already hold the owner attachment on a live
    /// surface — when another client owns the session, reclaiming ownership is the whole request. Pure so
    /// the line between "already here" and "go get it" is directly testable.
    nonisolated static func canRefocusTerminalPaneWithoutReattaching(
        paneIsFocused: Bool, paneIsInSelectedTab: Bool, paneHoldsOwnerAttachedSurface: Bool
    ) -> Bool { paneIsFocused && paneIsInSelectedTab && paneHoldsOwnerAttachedSurface }

    /// What opening a terminal session's pane does to the panel layout.
    enum TerminalPaneOpenAction: Equatable {
        /// Select the pane's tab, bring its panel forward, and put the caret in it.
        case focusExistingPane
        /// Leave the pane exactly where it sits: the session re-targets in place and nothing moves.
        case leaveExistingPaneInPlace
        /// Point the pane of the session this one replaces at this session, keeping its tab and split.
        case claimReplacedPane
        /// Install the pane as a new tab, selected and focused.
        case openFocusedTab
        /// Install the pane as a new tab that is neither selected nor focused.
        case installUnselectedTab
    }

    /// What a pane open does to the layout, given whether the session already has a pane, whether the
    /// session it replaces still has one, and whether the open may move focus.
    ///
    /// A session that already has its own pane is placed, so that wins over any claim: re-opening it
    /// must not go move a different pane. Claiming beats installing, which is the whole point of naming
    /// a predecessor: a restart's replacement takes over the pane the user arranged instead of arriving
    /// at the end of the tab strip. A named predecessor that no longer has a pane (the user closed it
    /// during the restart) leaves nothing to claim and falls through to the ordinary install. Pure so
    /// each of those precedences is directly testable.
    nonisolated static func terminalPaneOpenAction(hasExistingPane: Bool, hasReplaceablePane: Bool, focusIntent: TerminalOpenFocusIntent)
        -> TerminalPaneOpenAction
    {
        if hasExistingPane { return focusIntent == .focus ? .focusExistingPane : .leaveExistingPaneInPlace }
        if hasReplaceablePane { return .claimReplacedPane }
        return focusIntent == .focus ? .openFocusedTab : .installUnselectedTab
    }

    /// What an arriving `awaitReplacement` close does, given what the replacement's open already did.
    enum TerminalPaneHoldAction: Equatable {
        /// The ordinary order: hold the pane until the replacement claims it.
        case hold
        /// The replacement's open beat this close and already retargeted the pane, so there is nothing of
        /// the predecessor's left here. Consuming the marker is the whole transition: recording a hold
        /// would strand a dead id, and tearing down would kill the pane the replacement now lives in.
        case consumeClaim
        /// The replacement's open beat this close and failed, so the hold is dead on arrival and the pane
        /// is torn down now rather than held for a replacement that is not coming.
        case teardown
    }

    /// The close and the open are independent IPCs, so either can be processed first. This is the whole
    /// out-of-order half of the hold state machine, pure so all three orders are directly testable. A
    /// pending claim wins over a pending release: a claim that succeeded is authoritative about where the
    /// pane went, while a release only says an open did not claim it.
    nonisolated static func terminalPaneHoldAction(hasPendingClaim: Bool, hasPendingRelease: Bool) -> TerminalPaneHoldAction {
        if hasPendingClaim { return .consumeClaim }
        return hasPendingRelease ? .teardown : .hold
    }

    /// What a close reports, given whether the session has a pane in memory and what the daemon asked
    /// for. Reporting only: every close is forwarded to the coordinator regardless.
    enum TerminalPaneCloseRoute: String, Equatable {
        /// A materialized pane was closed or held.
        case pane
        /// No pane in memory, but a hold was recorded for the workspace's persisted layout. This is the
        /// ordinary shape for a restart of a workspace the user is not currently viewing, so it is a
        /// success rather than the nothing-to-do case below.
        case hold
        /// No pane in memory and nothing asked for, so the close found nothing to do.
        case missingPane = "missing_pane"
    }

    /// Pure so the case that used to be swallowed, a hold for a workspace with no materialized panel, is
    /// directly testable as a distinct outcome rather than as "no pane, nothing to do".
    nonisolated static func terminalPaneCloseRoute(hasPlacement: Bool, disposition: TerminalPaneCloseDisposition) -> TerminalPaneCloseRoute {
        if hasPlacement { return .pane }
        return disposition == .awaitReplacement ? .hold : .missingPane
    }

    /// The pane-close disposition a `closeTerminalSessionWindow` IPC carries. The field is required: every
    /// poster states `.teardown` or `.awaitReplacement` explicitly. A notification with no value, a blank
    /// one, or one this build does not recognize is malformed, and nil tells the caller to drop the IPC,
    /// the same as a missing session ID.
    nonisolated static func terminalPaneCloseDisposition(ipcRawValue: String?) -> TerminalPaneCloseDisposition? {
        guard let raw = ipcRawValue?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        return TerminalPaneCloseDisposition(rawValue: raw)
    }

    /// What the swap from placeholder to ready terminal does with the caret.
    enum TerminalPanePreparationFocusAction: Equatable {
        /// Leave the caret wherever the user put it.
        case none
        /// Put the caret back in this pane, because the placeholder it replaces was holding it.
        case restoreToPreparedPane
        /// Put the caret in the panel's focused pane, landing a focusing open in the terminal it asked for.
        case activatePanelFocusedPane
    }

    /// What an open's deferred work does with the caret. Credential preparation finishes long after the
    /// pane is installed, and the completion re-activates the panel's focused pane so a focusing open
    /// lands the caret in the terminal it just prepared. A non-focusing open must not do that: the user
    /// has had the whole async window to click into the sidebar or another pane, and taking the caret
    /// then is the theft the intent forbids.
    ///
    /// Withholding it unconditionally is wrong in one case, though, and it is the case where the user
    /// asked: they clicked into the waiting pane while it was still preparing, so the placeholder holds
    /// the caret, and swapping the placeholder out removes the first responder. Restoring it there is not
    /// stealing focus, it is not dropping focus the user already gave this pane. Pure so both halves are
    /// directly testable.
    nonisolated static func terminalPanePreparationFocusAction(focusIntent: TerminalOpenFocusIntent, preparedPaneHoldsKeyboardFocus: Bool)
        -> TerminalPanePreparationFocusAction
    {
        if focusIntent == .focus { return .activatePanelFocusedPane }
        return preparedPaneHoldsKeyboardFocus ? .restoreToPreparedPane : .none
    }

    /// The held predecessor an open has orphaned, if any. A replacement's open is the only thing that can
    /// release the hold its restart placed: the daemon consumed that reservation the moment it launched
    /// the replacement, so it will never send a teardown for the old session, and the client's overview
    /// pruning deliberately skips held panes. An open that names a replaced session and then fails for
    /// any reason therefore has to release the pane itself, or the terminated predecessor stays on screen
    /// for good. Pure so the "claimed it or released it" rule is directly testable.
    nonisolated static func heldPredecessorSessionToRelease(replacesSessionID: String?, openAction: TerminalPaneOpenAction?) -> String? {
        guard let replacesSessionID, openAction != .claimReplacedPane else { return nil }
        return replacesSessionID
    }

    /// Whether a retarget hands the caret to the replacement. A restart's replacement takes over the pane
    /// its predecessor occupied, and that pane may be the one the user is typing in: swapping the content
    /// tears the predecessor's view out and the first responder goes with it, so the user would be left
    /// typing into nothing by a restart running in the background. Moving the caret across is not the
    /// focus theft the intent forbids, it is keeping focus the pane already had. Pure so the one case
    /// that transfers, and the ordinary case that touches nothing, are directly testable.
    nonisolated static func terminalPaneRetargetMovesKeyboardFocusToReplacement(replacedPaneHoldsKeyboardFocus: Bool) -> Bool {
        replacedPaneHoldsKeyboardFocus
    }

    /// Whether a failed open reports itself with a modal. A user waiting on a terminal they asked for is
    /// owed the error in front of them; a programmatic launch failing in the background is not a reason
    /// to interrupt whatever the user is doing, and its pane already says so in place.
    ///
    /// One rule for every way an open can fail, not just the one it was written for: credential
    /// preparation returning an error, content construction throwing after preparation succeeded, and the
    /// owning device refusing the install. `reportTerminalPaneOpenFailure` is the single site that applies
    /// it, so a new failure mode cannot quietly reintroduce the modal.
    nonisolated static func terminalPaneOpenFailureUsesModalAlert(focusIntent: TerminalOpenFocusIntent) -> Bool { focusIntent == .focus }

    /// Reports an open's failure, modally or not at all, by the open's focus intent. The only door to
    /// `showError` on the pane-open path.
    func reportTerminalPaneOpenFailure(_ error: Error, focusIntent: TerminalOpenFocusIntent) {
        guard Self.terminalPaneOpenFailureUsesModalAlert(focusIntent: focusIntent) else { return }
        host.showError(error)
    }

    /// Whether closing a pane hands the caret to the pane that takes its place. A user closing a pane
    /// (close button, `Cmd+W`, closing its tab) is asking to carry on in that panel, so focus moves to
    /// the neighbor. A close the daemon drove (a session it terminated for a stop, a restart, or a
    /// process that exited, plus the client-side prune of sessions a device no longer retains) is not a
    /// user action at all: the user is wherever they were, possibly in another app, and pulling their
    /// caret into a terminal because some background session ended is never what they asked for. Pure so
    /// the line between the two closes is directly testable.
    nonisolated static func terminalPaneCloseMovesKeyboardFocus(sessionIsTerminating: Bool) -> Bool { !sessionIsTerminating }

    /// The focus intent an `openTerminalSessionWindow` IPC carries. The field is required: every poster
    /// states `.focus` or `.withoutFocus` explicitly. A notification with no value, a blank one, or one
    /// this build does not recognize is malformed, and nil tells the caller to drop the IPC, the same as
    /// a missing session ID. Pure so the decode is directly testable.
    nonisolated static func terminalOpenFocusIntent(ipcRawValue: String?) -> TerminalOpenFocusIntent? {
        guard let raw = ipcRawValue?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        return TerminalOpenFocusIntent(rawValue: raw)
    }
}
