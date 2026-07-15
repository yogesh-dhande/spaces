import Foundation
import spacesclientcore
import spacesdevicecore
import workspacecore

/// Watches coding-agent sessions on paired devices on behalf of local subscriber terminals. For every
/// paired device that has at least one `agent_remote_subscriptions` edge it holds one long-lived
/// device-overview stream — the same push transport the Mac sidebar uses. Each push is treated purely as
/// a change signal: the overview's coding-agent rows lack the note/status detail needed to tell blocked
/// from waiting or to see an exit, so the source of truth is a `listAgentSessions` pull whose successive
/// snapshots are diffed (`RemoteAgentSnapshotDiff`) to recover blocked/done/exited transitions.
/// Transitions are delivered through the shared `AgentNotificationEngine`, so a remote child's line
/// queues and flushes into the subscriber exactly like a local child's.
///
/// Modeled on `SidebarController`'s remote-overview consumer: `@MainActor` state, a detached task for the
/// blocking connect and pulls, and a 5s reconnect on disconnect/failure (the stream has no built-in
/// reconnect). `reconcile()` is driven by the daemon's `databaseDidChange` observer, so subscribing or
/// unsubscribing opens or closes streams without a poll.
@MainActor
final class RemoteAgentWatchService {
    private let databasePath: String
    private let clientApp: SpacesDeviceClientApp
    /// Injects a rendered line into a local subscriber terminal — the same terminal-send path a
    /// `terminal send` uses. Throwing means the subscriber session is gone, which the engine reads as the
    /// watch edge having vanished. Called only on the main actor, so it is not `@Sendable`.
    private let deliver: (_ subscriberTerminalSessionID: String, _ line: String) throws -> Void
    private let logError: (String) -> Void

    private var streams: [String: SpacesDeviceAPIOverviewStreamClient] = [:]
    private var connecting: Set<String> = []
    /// Per-device baseline: watched agent row id → last-seen row. Reset to empty on every (re)connect so
    /// the first post-connect snapshot re-seeds silently instead of replaying every current state.
    private var snapshots: [String: [String: SpacesDeviceAgentSessionRow]] = [:]
    private var isStopped = false

    init(
        databasePath: String, clientApp: SpacesDeviceClientApp,
        deliver: @escaping (_ subscriberTerminalSessionID: String, _ line: String) throws -> Void, logError: @escaping (String) -> Void
    ) {
        self.databasePath = databasePath
        self.clientApp = clientApp
        self.deliver = deliver
        self.logError = logError
    }

    func start() { reconcile() }

    func stop() {
        isStopped = true
        for (_, client) in streams { client.stop() }
        streams.removeAll()
        connecting.removeAll()
        snapshots.removeAll()
    }

    /// Reconciles the open stream set against the current watch edges: opens a stream for every newly
    /// watched device, tears one down when a device's last edge is removed, and refreshes the baseline of
    /// still-streaming devices so a freshly added edge captures the child's current state before its next
    /// transition (which would otherwise be swallowed as that agent's first observation).
    func reconcile() {
        guard !isStopped else { return }
        let desired: Set<String>
        do { desired = Set(try makeStore().agentRemoteSubscriptionDeviceIDs()) } catch {
            logError("spacesd remote_agent_watch_error op=reconcile error=\(error)\n")
            return
        }
        for (deviceID, client) in streams where !desired.contains(deviceID) {
            // Remove before stopping so the disconnect callback treats it as intentional.
            streams[deviceID] = nil
            snapshots[deviceID] = nil
            client.stop()
        }
        for deviceID in desired where streams[deviceID] == nil && !connecting.contains(deviceID) { openStream(deviceID: deviceID) }
        for deviceID in desired where streams[deviceID] != nil { refreshBaseline(deviceID: deviceID) }
    }

    private func openStream(deviceID: String) {
        let resolved: SpacesPairedDeviceRecord?
        do { resolved = try SpacesClientDatabase.defaultDatabase().pairedDevice(id: deviceID) } catch {
            logError("spacesd remote_agent_watch_error op=resolve_device device=\(deviceID) error=\(error)\n")
            scheduleReconnect()
            return
        }
        guard let device = resolved else {
            // The device is no longer paired: its edges can never be served, so drop them loudly rather
            // than retry a stream to a device that is gone.
            logError("spacesd remote_agent_watch device=\(deviceID) unpaired dropping_edges\n")
            dropAllEdges(deviceID: deviceID)
            return
        }
        guard pairedDeviceHasRequiredCredentials(device: device) else {
            logError("spacesd remote_agent_watch device=\(deviceID) missing_credentials scheduling_retry\n")
            scheduleReconnect()
            return
        }
        connecting.insert(deviceID)
        let clientApp = clientApp
        let onOverview: @Sendable (SpacesDeviceOverview) -> Void = { [weak self] _ in
            Task { @MainActor in self?.handleOverviewSignal(deviceID: deviceID) }
        }
        let onDisconnect: @Sendable ((any Error)?) -> Void = { [weak self] error in
            Task { @MainActor in self?.handleDisconnected(deviceID: deviceID, error: error) }
        }
        Task { @MainActor [weak self] in
            let client = await Task.detached(priority: .userInitiated) { () -> SpacesDeviceAPIOverviewStreamClient? in
                try? SpacesDeviceClient.subscribeOverview(device: device, clientApp: clientApp, onOverview: onOverview, onDisconnect: onDisconnect)
            }.value
            guard let self else {
                client?.stop()
                return
            }
            self.connecting.remove(deviceID)
            guard !self.isStopped else {
                client?.stop()
                return
            }
            guard let client else {
                self.logError("spacesd remote_agent_watch device=\(deviceID) connect_failed scheduling_retry\n")
                self.scheduleReconnect()
                return
            }
            // The device's last edge may have been removed while the connect was in flight.
            guard self.deviceIsStillWatched(deviceID) else {
                client.stop()
                return
            }
            self.streams[deviceID] = client
            self.snapshots[deviceID] = [:]
            self.refreshBaseline(deviceID: deviceID)
        }
    }

    private func handleOverviewSignal(deviceID: String) {
        guard !isStopped, streams[deviceID] != nil else { return }
        fetchRows(deviceID: deviceID, emit: true)
    }

    /// Pulls the device's current agent listing without emitting, populating any not-yet-seen baseline
    /// entries so the next real transition diffs against a known prior state.
    private func refreshBaseline(deviceID: String) {
        guard !isStopped, streams[deviceID] != nil else { return }
        fetchRows(deviceID: deviceID, emit: false)
    }

    private func fetchRows(deviceID: String, emit: Bool) {
        let resolved = try? SpacesClientDatabase.defaultDatabase().pairedDevice(id: deviceID)
        guard let device = resolved else { return }
        let clientApp = clientApp
        Task { @MainActor [weak self] in
            let rows = await Task.detached(priority: .userInitiated) { () -> [SpacesDeviceAgentSessionRow]? in
                try? SpacesDeviceClient.listAgentSessions(device: device, clientApp: clientApp)
            }.value
            guard let self, !self.isStopped, self.streams[deviceID] != nil else { return }
            guard let rows else {
                self.logError("spacesd remote_agent_watch device=\(deviceID) list_agent_sessions_failed\n")
                return
            }
            if emit { self.applyRows(deviceID: deviceID, rows: rows) } else { self.seedBaseline(deviceID: deviceID, rows: rows) }
        }
    }

    private func seedBaseline(deviceID: String, rows: [SpacesDeviceAgentSessionRow]) {
        let watched: Set<String>
        do { watched = try watchedTerminalSessionIDs(deviceID: deviceID) } catch {
            logError("spacesd remote_agent_watch_error op=seed_baseline device=\(deviceID) error=\(error)\n")
            return
        }
        var snapshot = (snapshots[deviceID] ?? [:]).filter { watched.contains($0.key) }
        for row in rows {
            guard let sessionID = row.terminalSessionID, watched.contains(sessionID), snapshot[sessionID] == nil else { continue }
            snapshot[sessionID] = row
        }
        snapshots[deviceID] = snapshot
    }

    private func applyRows(deviceID: String, rows: [SpacesDeviceAgentSessionRow]) {
        let store: SQLiteStore
        let watched: Set<String>
        do {
            store = try makeStore()
            watched = Set(try store.agentRemoteSubscriptions(deviceID: deviceID).map(\.agentSessionID))
        } catch {
            logError("spacesd remote_agent_watch_error op=apply_rows device=\(deviceID) error=\(error)\n")
            return
        }
        let result = RemoteAgentSnapshotDiff.diff(previous: snapshots[deviceID] ?? [:], newRows: rows, watchedTerminalSessionIDs: watched)
        snapshots[deviceID] = result.snapshot
        guard !result.transitions.isEmpty else { return }
        let engine = AgentNotificationEngine(store: store, deliver: deliver, logError: logError)
        for transition in result.transitions {
            do {
                try engine.remoteChildDidTransition(
                    deviceID: deviceID, terminalSessionID: transition.terminalSessionID, row: transition.row,
                    transition: transition.kind.childTransition)
            } catch {
                logError("spacesd remote_agent_watch device=\(deviceID) deliver_failed agent=\(transition.terminalSessionID) error=\(error)\n")
            }
            if transition.kind == .exited {
                // The remote child is gone and its terminating line has been delivered or queued, so tear
                // its edges down — the watch is complete.
                try? store.deleteAgentRemoteSubscriptions(deviceID: deviceID, agentSessionID: transition.terminalSessionID)
            }
        }
    }

    private func handleDisconnected(deviceID: String, error: (any Error)?) {
        // Ignore disconnects for streams we intentionally removed in reconcile.
        guard streams[deviceID] != nil else { return }
        streams[deviceID] = nil
        snapshots[deviceID] = nil
        guard !isStopped else { return }
        logError(
            "spacesd remote_agent_watch device=\(deviceID) stream_disconnected error=\(error?.localizedDescription ?? "closed") scheduling_retry\n")
        scheduleReconnect()
    }

    /// Retries reconciling after a short delay so a persistently unreachable remote reconnects without
    /// spinning. `reconcile()` reopens any watched device that has no live stream.
    private func scheduleReconnect() {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(5))
            self?.reconcile()
        }
    }

    private func dropAllEdges(deviceID: String) {
        do {
            let store = try makeStore()
            for edge in try store.agentRemoteSubscriptions(deviceID: deviceID) {
                try store.deleteAgentRemoteSubscription(
                    subscriberTerminalSessionID: edge.subscriberTerminalSessionID, deviceID: deviceID, agentSessionID: edge.agentSessionID)
            }
        } catch { logError("spacesd remote_agent_watch_error op=drop_edges device=\(deviceID) error=\(error)\n") }
        snapshots[deviceID] = nil
    }

    private func deviceIsStillWatched(_ deviceID: String) -> Bool {
        ((try? makeStore().agentRemoteSubscriptions(deviceID: deviceID)) ?? []).isEmpty == false
    }

    private func watchedTerminalSessionIDs(deviceID: String) throws -> Set<String> {
        Set(try makeStore().agentRemoteSubscriptions(deviceID: deviceID).map(\.agentSessionID))
    }

    private func makeStore() throws -> SQLiteStore { try SQLiteStore(path: databasePath) }

    /// A paired device is usable when its auth-token secret is present and its record carries the daemon's
    /// pinned TLS certificate fingerprint. Mirrors `AppKitController.pairedDeviceHasRequiredCredentials`,
    /// which is not reachable from the daemon target.
    private func pairedDeviceHasRequiredCredentials(device: SpacesPairedDeviceRecord) -> Bool {
        let hasToken = (try? SpacesDeviceCredentialStore.hasToken(deviceID: device.id)) ?? false
        return hasToken && !device.certificateFingerprint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
