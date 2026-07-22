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
///
/// The daemon runs its terminal I/O engine on the main actor, so this service never touches SQLite on
/// the main actor: every store read/write runs in a detached `.utility` task (matching the sibling
/// device-runtime services), and only Sendable results cross back to the main actor, where the service's
/// decision logic, stream set, timers, and snapshots live. The one exception is delivery: an actual
/// transition is handed to `AgentNotificationEngine`, whose store access is inseparable from the
/// daemon-owned, main-only `deliver` (terminal-send) closure, so that store is opened on the main actor —
/// but only when a real transition fires (rare and already network-gated), never on the reconcile hot path.
@MainActor public final class RemoteAgentWatchService {
    private let databasePath: String
    private let transport: RemoteAgentWatchTransport
    /// Injects a rendered line into a local subscriber terminal — the same terminal-send path a
    /// `terminal send` uses. Throwing means the subscriber session is gone, which the engine reads as the
    /// watch edge having vanished. The daemon's implementation returns promptly (it defers the actual
    /// engine send onto a background delivery queue when called on the main actor), so this stays a plain
    /// synchronous closure.
    private let deliver: @Sendable (_ subscriberTerminalSessionID: String, _ line: String) throws -> Void
    private let logError: @Sendable (String) -> Void

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
    /// Devices with a `listAgentSessions` pull (plus its `applyRows` apply) in flight. Both the pull and
    /// the apply are serialized per device: responses of overlapping pulls could complete out of order
    /// and apply a stale listing over a newer one, and `applyRows` now has its own suspension points
    /// (the off-main store reads/writes), so the in-flight flag is held until the apply finishes.
    private var listingInFlight: Set<String> = []
    /// Devices whose overview signaled during an in-flight pull; one coalesced follow-up pull runs
    /// when the in-flight one completes.
    private var listingQueued: Set<String> = []
    /// Serializes `reconcile()` the same way `WorktreeDiscoveryService` serializes its scans. Reconcile
    /// reads the desired device set off the main actor and only then adjusts streams/baselines, so two
    /// overlapping reconciles could each act on a different (possibly stale) `desired` — e.g. one tears a
    /// device's stream down for being unsubscribed while the other, holding an older read, reopens it. A
    /// reconcile requested while one is in flight collapses into a single trailing re-run, which always
    /// reads the freshest state and converges.
    private var reconcileInFlight = false
    private var reconcilePending = false
    private var isStopped = false
    /// Delay before a failed connect, a dropped stream, or a failed listing pull retries through
    /// `reconcile()`. Internal so behavior tests can shorten it instead of waiting out real seconds.
    var reconnectDelay: Duration = .seconds(5)

    public init(
        databasePath: String, transport: RemoteAgentWatchTransport,
        deliver: @escaping @Sendable (_ subscriberTerminalSessionID: String, _ line: String) throws -> Void,
        logError: @escaping @Sendable (String) -> Void
    ) {
        self.databasePath = databasePath
        self.transport = transport
        self.deliver = deliver
        self.logError = logError
    }

    public func start() {
        // Seed the in-memory baselines from the persisted mirror before the first reconcile, so the
        // first listing of each still-watched device diffs against what the previous daemon run had
        // reported and surfaces transitions from the downtime window. The load runs off the main actor;
        // a seed that arrives (via `seedBaseline`) while it is in flight is a fresher validation row, so
        // the merge never clobbers an entry already present — it only fills in devices/children the
        // persisted mirror still knows about.
        let databasePath = databasePath
        Task { @MainActor [weak self] in
            let result = await Task.detached(priority: .utility) { () -> Result<[String: [String: SpacesDeviceAgentSessionRow]], any Error> in
                Result { try SQLiteStore(path: databasePath).agentRemoteWatchBaselines() }
            }.value
            guard let self, !self.isStopped else { return }
            switch result {
            case .success(let baselines):
                for (deviceID, baseline) in baselines {
                    for (childTerminalSessionID, row) in baseline where self.snapshots[deviceID]?[childTerminalSessionID] == nil {
                        self.snapshots[deviceID, default: [:]][childTerminalSessionID] = row
                    }
                }
            case .failure(let error):
                self.logError("spacesd remote_agent_watch_error op=load_baselines error=\(error)\n")
            }
            self.reconcile()
        }
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
    /// mirror is updated off the main actor the same way `applyRows` does (whole-device replace), keeping
    /// the seed durable across a daemon restart in the window before the first listing.
    ///
    /// The in-memory seed is applied synchronously on the main actor (only the persist is deferred off
    /// it), so the interleavings below still hold — a seed lands in `snapshots` before any concurrent
    /// pull's continuation resumes:
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
        let baseline = snapshots[deviceID] ?? [:]
        let databasePath = databasePath
        Task { @MainActor [weak self] in
            let result = await Task.detached(priority: .utility) { () -> Result<Void, any Error> in
                Result { try SQLiteStore(path: databasePath).replaceAgentRemoteWatchBaseline(deviceID: deviceID, baseline: baseline) }
            }.value
            if case .failure(let error) = result {
                self?.logError("spacesd remote_agent_watch_error op=seed_baseline device=\(deviceID) error=\(error)\n")
            }
        }
    }

    /// Reconciles the open stream set against the current watch edges: opens a stream for every newly
    /// watched device, tears one down when a device's last edge is removed, and pulls a fresh listing
    /// for still-streaming devices so a freshly added edge's first transition is diffed against the
    /// baseline the subscribe seeded (or, absent a seed, is swallowed as that agent's first observation).
    ///
    /// The desired device set is read off the main actor, so `reconcile()` is serialized (see
    /// `reconcileInFlight`): a request arriving mid-reconcile collapses into one trailing re-run.
    public func reconcile() {
        guard !isStopped else { return }
        guard !reconcileInFlight else {
            reconcilePending = true
            return
        }
        reconcileInFlight = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            repeat {
                self.reconcilePending = false
                await self.reconcileOnce()
            } while self.reconcilePending && !self.isStopped
            self.reconcileInFlight = false
        }
    }

    private func reconcileOnce() async {
        let databasePath = databasePath
        let result = await Task.detached(priority: .utility) { () -> Result<[String], any Error> in
            Result { try SQLiteStore(path: databasePath).agentRemoteSubscriptionDeviceIDs() }
        }.value
        guard !isStopped else { return }
        let desired: Set<String>
        switch result {
        case .success(let ids): desired = Set(ids)
        case .failure(let error):
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
        var retiredBaselines: [String] = []
        for deviceID in snapshots.keys where !desired.contains(deviceID) {
            snapshots[deviceID] = nil
            retiredBaselines.append(deviceID)
        }
        listingQueued = listingQueued.filter(desired.contains)
        for deviceID in desired where streams[deviceID] == nil && !connecting.contains(deviceID) { openStream(deviceID: deviceID) }
        for deviceID in desired where streams[deviceID] != nil { requestListing(deviceID: deviceID) }
        await deletePersistedBaselines(retiredBaselines)
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
            guard !self.isStopped else {
                if case .connected(let handle) = result { handle.stop() }
                return
            }
            switch result {
            case .deviceUnpaired:
                // The device is no longer paired: its edges can never be served, so drop them loudly
                // rather than retry a stream to a device that is gone. `connecting` is held across the
                // (off-main) edge drop so a concurrent reconcile does not reopen a stream to it.
                self.logError("spacesd remote_agent_watch device=\(deviceID) unpaired dropping_edges\n")
                await self.dropAllEdges(deviceID: deviceID)
                self.connecting.remove(deviceID)
            case .unavailable(let reason):
                self.connecting.remove(deviceID)
                self.logError("spacesd remote_agent_watch device=\(deviceID) connect_unavailable reason=\(reason) scheduling_retry\n")
                self.scheduleReconnect()
            case .connected(let handle):
                // The device's last edge may have been removed while the connect was in flight. `connecting`
                // stays set across this off-main check so a concurrent reconcile cannot start a second connect
                // in the window before the stream is recorded.
                let stillWatched = await self.deviceIsStillWatched(deviceID)
                self.connecting.remove(deviceID)
                guard !self.isStopped, stillWatched else {
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
    /// baseline. At most one pull-and-apply runs per device; a signal arriving mid-pull coalesces into a
    /// single follow-up pull, so responses always apply in pull order and a stale listing can never
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
            // The in-flight flag is held across the apply (which has its own suspension points), so a
            // signal arriving during it coalesces into `listingQueued` instead of racing a second apply.
            if !self.isStopped, self.streams[deviceID] != nil {
                switch result {
                case .success(let rows):
                    await self.applyRows(deviceID: deviceID, rows: rows)
                case .failure(RemoteAgentWatchListingError.deviceUnpaired):
                    // The device unpaired while its overview stream stayed connected, so the connect
                    // path's `.deviceUnpaired` handling — which only runs on a fresh connect — never
                    // fires again for it. Mirror that handling here instead of retrying a listing pull
                    // against a device that can never resolve again: stop the stream and drop the
                    // edges. No follow-up pull: a dropped device has nothing left to pull for.
                    self.logError("spacesd remote_agent_watch device=\(deviceID) unpaired dropping_edges\n")
                    let stream = self.streams.removeValue(forKey: deviceID)
                    stream?.stop()
                    await self.dropAllEdges(deviceID: deviceID)
                case .failure:
                    // The overview signal that drove this pull may have been the only cue for a
                    // transition, and with the stream still healthy nothing else would re-pull, so a
                    // failed pull schedules its own retry. The baseline did not advance, so the retried
                    // listing still diffs against the last reported state.
                    self.logError("spacesd remote_agent_watch device=\(deviceID) list_agent_sessions_failed scheduling_retry\n")
                    self.scheduleReconnect()
                }
            }
            self.listingInFlight.remove(deviceID)
            let followUpQueued = self.listingQueued.remove(deviceID) != nil
            // Only follow up a device whose stream is still live: an unpaired/dropped device is gone.
            if followUpQueued, !self.isStopped, self.streams[deviceID] != nil { self.requestListing(deviceID: deviceID) }
        }
    }

    private func applyRows(deviceID: String, rows: [SpacesDeviceAgentSessionRow]) async {
        let databasePath = databasePath
        let watchedResult = await Task.detached(priority: .utility) { () -> Result<Set<String>, any Error> in
            Result { Set(try SQLiteStore(path: databasePath).agentRemoteSubscriptions(deviceID: deviceID).map(\.agentSessionID)) }
        }.value
        guard !isStopped, streams[deviceID] != nil else { return }
        let watched: Set<String>
        switch watchedResult {
        case .success(let ids): watched = ids
        case .failure(let error):
            logError("spacesd remote_agent_watch_error op=apply_rows device=\(deviceID) error=\(error)\n")
            return
        }
        let previous = snapshots[deviceID] ?? [:]
        let result = RemoteAgentSnapshotDiff.diff(previous: previous, newRows: rows, watchedTerminalSessionIDs: watched)
        snapshots[deviceID] = result.snapshot

        // Delivery boundary: `AgentNotificationEngine` interleaves store reads/writes with the
        // daemon-owned, main-only `deliver` (terminal-send) closure, so the whole delivery runs on the
        // main actor and opens its store here — but only when there is a real transition to deliver
        // (rare and already network-gated), never on the reconcile hot path. Pure store I/O (the watched
        // read above and the edge/baseline persistence below) is the only thing that moves off-main.
        var exitedTerminalSessionIDs: [String] = []
        if !result.transitions.isEmpty {
            do {
                let store = try SQLiteStore(path: databasePath)
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
                    // The remote child is gone and its terminating line has been delivered or queued, so
                    // its edges are torn down after the loop (off-main) — the watch is complete.
                    if transition.kind == .exited { exitedTerminalSessionIDs.append(transition.terminalSessionID) }
                }
            } catch {
                logError("spacesd remote_agent_watch_error op=apply_rows device=\(deviceID) error=\(error)\n")
            }
        }

        // Drop completed watch edges and mirror the baseline off the main actor, after the transitions
        // were delivered or queued (both durable), so a crash in between re-emits rather than silently
        // drops. Only a real change writes the baseline: the write signals databaseDidChange, which drives
        // reconcile back through here — an unconditional mirror would loop pull → write → signal → pull.
        let snapshotChanged = previous != result.snapshot
        guard snapshotChanged || !exitedTerminalSessionIDs.isEmpty else { return }
        let baseline = result.snapshot
        let persistResult = await Task.detached(priority: .utility) { () -> Result<Void, any Error> in
            Result {
                let store = try SQLiteStore(path: databasePath)
                for terminalSessionID in exitedTerminalSessionIDs {
                    try? store.deleteAgentRemoteSubscriptions(deviceID: deviceID, agentSessionID: terminalSessionID)
                }
                if snapshotChanged { try store.replaceAgentRemoteWatchBaseline(deviceID: deviceID, baseline: baseline) }
            }
        }.value
        if case .failure(let error) = persistResult {
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

    /// Drops every watch edge for `deviceID` and retires its baseline (in memory and persisted). All the
    /// store work runs in one detached task; the in-memory snapshot is cleared on the main actor after.
    private func dropAllEdges(deviceID: String) async {
        let databasePath = databasePath
        let result = await Task.detached(priority: .utility) { () -> Result<Void, any Error> in
            Result {
                let store = try SQLiteStore(path: databasePath)
                for edge in try store.agentRemoteSubscriptions(deviceID: deviceID) {
                    try store.deleteAgentRemoteSubscription(
                        subscriberTerminalSessionID: edge.subscriberTerminalSessionID, deviceID: deviceID, agentSessionID: edge.agentSessionID)
                }
                try store.deleteAgentRemoteWatchBaseline(deviceID: deviceID)
            }
        }.value
        if case .failure(let error) = result {
            logError("spacesd remote_agent_watch_error op=drop_edges device=\(deviceID) error=\(error)\n")
        }
        snapshots[deviceID] = nil
    }

    private func deletePersistedBaselines(_ deviceIDs: [String]) async {
        guard !deviceIDs.isEmpty else { return }
        let databasePath = databasePath
        let result = await Task.detached(priority: .utility) { () -> Result<Void, any Error> in
            Result {
                let store = try SQLiteStore(path: databasePath)
                for deviceID in deviceIDs { try store.deleteAgentRemoteWatchBaseline(deviceID: deviceID) }
            }
        }.value
        if case .failure(let error) = result {
            logError("spacesd remote_agent_watch_error op=delete_baseline error=\(error)\n")
        }
    }

    private func deviceIsStillWatched(_ deviceID: String) async -> Bool {
        let databasePath = databasePath
        return await Task.detached(priority: .utility) { () -> Bool in
            ((try? SQLiteStore(path: databasePath).agentRemoteSubscriptions(deviceID: deviceID)) ?? []).isEmpty == false
        }.value
    }

    // MARK: - Test introspection

    /// The devices with a live overview stream. Internal so behavior tests can await async
    /// connect/disconnect handling deterministically instead of sleeping.
    var debugStreamingDeviceIDs: [String] { Array(streams.keys) }

    /// The retained baseline for `deviceID`. Internal so behavior tests can await baseline
    /// application deterministically instead of sleeping.
    func debugSnapshot(deviceID: String) -> [String: SpacesDeviceAgentSessionRow]? { snapshots[deviceID] }
}
