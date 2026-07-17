import Foundation
import spacesdevicecore

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
/// unsubscribing opens or closes streams without a poll. All network access goes through the injected
/// `RemoteAgentWatchTransport`, so tests drive connect/disconnect/listing sequences with fakes.
@MainActor public final class RemoteAgentWatchService {
    private let databasePath: String
    private let transport: RemoteAgentWatchTransport
    /// Injects a rendered line into a local subscriber terminal — the same terminal-send path a
    /// `terminal send` uses. Throwing means the subscriber session is gone, which the engine reads as the
    /// watch edge having vanished. Called only on the main actor, so it is not `@Sendable`.
    private let deliver: (_ subscriberTerminalSessionID: String, _ line: String) throws -> Void
    private let logError: (String) -> Void

    private var streams: [String: any RemoteAgentOverviewStreamHandle] = [:]
    private var connecting: Set<String> = []
    /// Per-device baseline: watched child terminal session id → last-seen row. Retained across
    /// disconnects and mirrored to `agent_remote_watch_baselines` on every change, so the first
    /// listing after a reconnect — or after a daemon restart, which `start()` seeds from the persisted
    /// mirror — diffs against the last reported state and emits every transition from the outage
    /// window, including an exit, whose row is simply absent from that listing. Only a device's last
    /// watch edge being removed (or the device unpairing) retires its baseline. Replay is impossible
    /// either way: an unchanged row diffs to nothing, and a never-seen row seeds silently
    /// (`RemoteAgentSnapshotDiff`'s per-agent gating).
    private var snapshots: [String: [String: SpacesDeviceAgentSessionRow]] = [:]
    /// Devices with a `listAgentSessions` pull in flight. Pulls are serialized per device — responses
    /// of overlapping pulls could complete out of order and apply a stale listing over a newer one.
    private var listingInFlight: Set<String> = []
    /// Devices whose overview signaled during an in-flight pull; one coalesced follow-up pull runs
    /// when the in-flight one completes.
    private var listingQueued: Set<String> = []
    private var isStopped = false
    /// Delay before a failed connect, a dropped stream, or a failed listing pull retries through
    /// `reconcile()`. Internal so behavior tests can shorten it instead of waiting out real seconds.
    var reconnectDelay: Duration = .seconds(5)

    public init(
        databasePath: String, transport: RemoteAgentWatchTransport,
        deliver: @escaping (_ subscriberTerminalSessionID: String, _ line: String) throws -> Void, logError: @escaping (String) -> Void
    ) {
        self.databasePath = databasePath
        self.transport = transport
        self.deliver = deliver
        self.logError = logError
    }

    public func start() {
        // Seed the in-memory baselines from the persisted mirror before the first reconcile, so the
        // first listing of each still-watched device diffs against what the previous daemon run had
        // reported and surfaces transitions from the downtime window.
        do { snapshots = try makeStore().agentRemoteWatchBaselines() } catch {
            logError("spacesd remote_agent_watch_error op=load_baselines error=\(error)\n")
        }
        reconcile()
    }

    public func stop() {
        isStopped = true
        for (_, client) in streams { client.stop() }
        streams.removeAll()
        connecting.removeAll()
        snapshots.removeAll()
        listingInFlight.removeAll()
        listingQueued.removeAll()
    }

    /// Seeds the watch baseline for a freshly subscribed cross-device child with the row the daemon's
    /// subscribe validation already fetched, so the child has a real prior state before the watch's
    /// first listing lands. Without it, an exit or transition that happens between validation and that
    /// first listing has no baseline entry to diff against: a changed row would seed silently (transition
    /// lost) and an exit would be an unseen absence (edge never dropped). The gap is milliseconds on an
    /// already-open stream but seconds-to-minutes when the stream must first connect (TLS dial, 5s retry).
    ///
    /// Only writes when no baseline entry exists for the child. An existing retained entry — the child is
    /// already watched by another subscriber, or its baseline survived a disconnect/restart — is newer
    /// (or at worst equal) and must not be clobbered by the possibly-older validation row. The persisted
    /// mirror is updated the same way `applyRows` does (whole-device replace), keeping the seed durable
    /// across a daemon restart in the window before the first listing.
    ///
    /// Interleavings (the daemon seeds after inserting the edge, then nudges `reconcile()`; everything
    /// here runs on the main actor, so a seed completes atomically before any concurrent pull's
    /// continuation resumes):
    ///  - (a) a listing already in flight when the seed lands: `applyRows` captures `previous` from
    ///    `snapshots` at apply time, not at pull start, so the completing pull diffs against the seed —
    ///    the seed participates correctly rather than being overwritten by a stale empty baseline;
    ///  - (b) a child that exited before the first listing: the seed makes it present-in-baseline and
    ///    absent-from-listing, which `RemoteAgentSnapshotDiff` renders as `exited`, delivering the line
    ///    and dropping the edge instead of leaving it silent forever;
    ///  - (c) a subscribe for an already-watched child: the existing baseline entry is retained, so the
    ///    later listing diffs against it (nothing replays, nothing is lost).
    public func seedBaseline(deviceID: String, childTerminalSessionID: String, row: SpacesDeviceAgentSessionRow) {
        guard !isStopped else { return }
        guard snapshots[deviceID]?[childTerminalSessionID] == nil else { return }
        snapshots[deviceID, default: [:]][childTerminalSessionID] = row
        do { try makeStore().replaceAgentRemoteWatchBaseline(deviceID: deviceID, baseline: snapshots[deviceID] ?? [:]) } catch {
            logError("spacesd remote_agent_watch_error op=seed_baseline device=\(deviceID) error=\(error)\n")
        }
    }

    /// Reconciles the open stream set against the current watch edges: opens a stream for every newly
    /// watched device, tears one down when a device's last edge is removed, and pulls a fresh listing
    /// for still-streaming devices so a freshly added edge's first transition is diffed against the
    /// baseline the subscribe seeded (or, absent a seed, is swallowed as that agent's first observation).
    public func reconcile() {
        guard !isStopped else { return }
        let desired: Set<String>
        do { desired = Set(try makeStore().agentRemoteSubscriptionDeviceIDs()) } catch {
            logError("spacesd remote_agent_watch_error op=reconcile error=\(error)\n")
            return
        }
        for (deviceID, client) in streams where !desired.contains(deviceID) {
            // Remove before stopping so the disconnect callback treats it as intentional.
            streams[deviceID] = nil
            client.stop()
        }
        // Baselines outlive streams (they survive disconnects and daemon restarts), so retire them by
        // desired-set membership rather than alongside stream teardown.
        for deviceID in snapshots.keys where !desired.contains(deviceID) {
            snapshots[deviceID] = nil
            deletePersistedBaseline(deviceID: deviceID)
        }
        listingQueued = listingQueued.filter(desired.contains)
        for deviceID in desired where streams[deviceID] == nil && !connecting.contains(deviceID) { openStream(deviceID: deviceID) }
        for deviceID in desired where streams[deviceID] != nil { requestListing(deviceID: deviceID) }
    }

    private func openStream(deviceID: String) {
        connecting.insert(deviceID)
        let transport = transport
        let onSignal: @Sendable () -> Void = { [weak self] in
            Task { @MainActor in self?.handleOverviewSignal(deviceID: deviceID) }
        }
        let onDisconnect: @Sendable ((any Error)?) -> Void = { [weak self] error in
            Task { @MainActor in self?.handleDisconnected(deviceID: deviceID, error: error) }
        }
        Task { @MainActor [weak self] in
            let result = await Task.detached(priority: .userInitiated) { () -> RemoteAgentWatchConnectResult in
                transport.connect(deviceID, onSignal, onDisconnect)
            }.value
            guard let self else {
                if case .connected(let handle) = result { handle.stop() }
                return
            }
            self.connecting.remove(deviceID)
            guard !self.isStopped else {
                if case .connected(let handle) = result { handle.stop() }
                return
            }
            switch result {
            case .deviceUnpaired:
                // The device is no longer paired: its edges can never be served, so drop them loudly
                // rather than retry a stream to a device that is gone.
                self.logError("spacesd remote_agent_watch device=\(deviceID) unpaired dropping_edges\n")
                self.dropAllEdges(deviceID: deviceID)
            case .unavailable(let reason):
                self.logError("spacesd remote_agent_watch device=\(deviceID) connect_unavailable reason=\(reason) scheduling_retry\n")
                self.scheduleReconnect()
            case .connected(let handle):
                // The device's last edge may have been removed while the connect was in flight.
                guard self.deviceIsStillWatched(deviceID) else {
                    handle.stop()
                    return
                }
                self.streams[deviceID] = handle
                // The first post-connect listing goes through the same emitting diff as every other:
                // on a first connect it diffs against whatever the subscribe seeded (an empty baseline
                // seeds silently), and on a reconnect the retained baseline surfaces every transition
                // from the outage window.
                self.requestListing(deviceID: deviceID)
            }
        }
    }

    private func handleOverviewSignal(deviceID: String) {
        guard !isStopped, streams[deviceID] != nil else { return }
        requestListing(deviceID: deviceID)
    }

    /// Pulls the device's current agent listing and applies it as a diff against the retained
    /// baseline. At most one pull runs per device; a signal arriving mid-pull coalesces into a single
    /// follow-up pull, so responses always apply in pull order and a stale listing can never
    /// overwrite a newer one (e.g. re-reporting a child blocked after its resume was already seen).
    private func requestListing(deviceID: String) {
        guard !isStopped, streams[deviceID] != nil else { return }
        guard !listingInFlight.contains(deviceID) else {
            listingQueued.insert(deviceID)
            return
        }
        listingInFlight.insert(deviceID)
        let transport = transport
        Task { @MainActor [weak self] in
            let result = await Task.detached(priority: .userInitiated) { () -> Result<[SpacesDeviceAgentSessionRow], any Error> in
                Result { try transport.listAgentSessions(deviceID) }
            }.value
            guard let self else { return }
            self.listingInFlight.remove(deviceID)
            let followUpQueued = self.listingQueued.remove(deviceID) != nil
            guard !self.isStopped, self.streams[deviceID] != nil else { return }
            switch result {
            case .success(let rows):
                self.applyRows(deviceID: deviceID, rows: rows)
            case .failure(RemoteAgentWatchListingError.deviceUnpaired):
                // The device unpaired while its overview stream stayed connected, so the connect
                // path's `.deviceUnpaired` handling — which only runs on a fresh connect — never
                // fires again for it. Mirror that handling here instead of retrying a listing pull
                // against a device that can never resolve again: stop the stream and drop the
                // edges. No follow-up pull: a dropped device has nothing left to pull for.
                self.logError("spacesd remote_agent_watch device=\(deviceID) unpaired dropping_edges\n")
                let stream = self.streams.removeValue(forKey: deviceID)
                stream?.stop()
                self.dropAllEdges(deviceID: deviceID)
                return
            case .failure:
                // The overview signal that drove this pull may have been the only cue for a
                // transition, and with the stream still healthy nothing else would re-pull, so a
                // failed pull schedules its own retry. The baseline did not advance, so the retried
                // listing still diffs against the last reported state.
                self.logError("spacesd remote_agent_watch device=\(deviceID) list_agent_sessions_failed scheduling_retry\n")
                self.scheduleReconnect()
            }
            if followUpQueued { self.requestListing(deviceID: deviceID) }
        }
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
        let previous = snapshots[deviceID] ?? [:]
        let result = RemoteAgentSnapshotDiff.diff(previous: previous, newRows: rows, watchedTerminalSessionIDs: watched)
        snapshots[deviceID] = result.snapshot
        let engine = AgentNotificationEngine(store: store, deliver: deliver, logError: logError)
        for transition in result.transitions {
            do {
                if let childTransition = transition.kind.childTransition {
                    try engine.remoteChildDidTransition(
                        deviceID: deviceID, terminalSessionID: transition.terminalSessionID, row: transition.row, transition: childTransition)
                } else {
                    // resumedWorking: nothing to deliver — withdraw the child's held blocked line.
                    try engine.childDidResumeWorking(agentSessionID: transition.terminalSessionID)
                }
            } catch {
                logError("spacesd remote_agent_watch device=\(deviceID) deliver_failed agent=\(transition.terminalSessionID) error=\(error)\n")
            }
            if transition.kind == .exited {
                // The remote child is gone and its terminating line has been delivered or queued, so tear
                // its edges down — the watch is complete.
                try? store.deleteAgentRemoteSubscriptions(deviceID: deviceID, agentSessionID: transition.terminalSessionID)
            }
        }
        // Mirror the baseline after the transitions were delivered or queued (both durable), so a
        // crash in between re-emits rather than silently drops. Only a real change writes: the write
        // signals databaseDidChange, which drives reconcile back through here — an unconditional
        // mirror would loop pull → write → signal → pull.
        guard previous != result.snapshot else { return }
        do { try store.replaceAgentRemoteWatchBaseline(deviceID: deviceID, baseline: result.snapshot) } catch {
            logError("spacesd remote_agent_watch_error op=persist_baseline device=\(deviceID) error=\(error)\n")
        }
    }

    private func handleDisconnected(deviceID: String, error: (any Error)?) {
        // Ignore disconnects for streams we intentionally removed in reconcile.
        guard streams[deviceID] != nil else { return }
        // The baseline is deliberately kept: the reconnect diffs its first listing against it so
        // transitions from the outage window are delivered instead of silently re-seeded.
        streams[deviceID] = nil
        guard !isStopped else { return }
        logError(
            "spacesd remote_agent_watch device=\(deviceID) stream_disconnected error=\(error?.localizedDescription ?? "closed") scheduling_retry\n")
        scheduleReconnect()
    }

    /// Retries reconciling after a short delay so a persistently unreachable remote reconnects without
    /// spinning. `reconcile()` reopens any watched device that has no live stream.
    private func scheduleReconnect() {
        let delay = reconnectDelay
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
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
        deletePersistedBaseline(deviceID: deviceID)
    }

    private func deletePersistedBaseline(deviceID: String) {
        do { try makeStore().deleteAgentRemoteWatchBaseline(deviceID: deviceID) } catch {
            logError("spacesd remote_agent_watch_error op=delete_baseline device=\(deviceID) error=\(error)\n")
        }
    }

    private func deviceIsStillWatched(_ deviceID: String) -> Bool {
        ((try? makeStore().agentRemoteSubscriptions(deviceID: deviceID)) ?? []).isEmpty == false
    }

    private func makeStore() throws -> SQLiteStore { try SQLiteStore(path: databasePath) }

    // MARK: - Test introspection

    /// The devices with a live overview stream. Internal so behavior tests can await async
    /// connect/disconnect handling deterministically instead of sleeping.
    var debugStreamingDeviceIDs: [String] { Array(streams.keys) }

    /// The retained baseline for `deviceID`. Internal so behavior tests can await baseline
    /// application deterministically instead of sleeping.
    func debugSnapshot(deviceID: String) -> [String: SpacesDeviceAgentSessionRow]? { snapshots[deviceID] }
}
