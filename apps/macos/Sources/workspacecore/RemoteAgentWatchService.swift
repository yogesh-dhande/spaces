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
    /// Monotonic per-device version, bumped on every main-actor mutation that actually changes
    /// `snapshots[deviceID]`'s content (seed, applyRows apply, retirement) — never on a content-identical
    /// replace, e.g. an applyRows apply whose listing reports back exactly the retained snapshot. Two
    /// consumers:
    ///  - `applyRows` captures it before its off-main watched-set read and re-checks after: a `seedBaseline`
    ///    (or a retirement) that lands during that suspension makes the just-read watched set — and thus the
    ///    watched-filtered snapshot `applyRows` would blindly write — stale, which would silently drop the
    ///    freshly seeded child. On a mismatch `applyRows` aborts without touching the snapshot and coalesces
    ///    a fresh listing that re-reads rows and the watched set against the updated snapshot.
    ///  - every durable baseline write is stamped with the generation it reflects; a write is skipped when a
    ///    newer mutation has already superseded it (that newer mutation enqueued its own later-chained write),
    ///    so a burst collapses to a single write of the latest snapshot and the mirror converges to it. Not
    ///    bumping on an unchanged apply is load-bearing here: bumping unconditionally would make an older
    ///    write still queued behind a slower one on the same device's chain — e.g. a `seedBaseline` — look
    ///    superseded and skip once its turn comes up, even though nothing about the snapshot actually
    ///    changed and that queued write is still the correct baseline to persist.
    private var snapshotGeneration: [String: Int] = [:]
    /// Per-device tail of the serial durable-baseline write chain. `Task.detached` gives no ordering, so two
    /// rapid seeds {A} then {A,B} could otherwise commit in reverse and strand B in the persisted mirror.
    /// Chaining every baseline write (seed, applyRows persist, retirement delete) behind the previous one for
    /// the same device makes them commit in main-actor enqueue order — which, because main-actor mutations are
    /// serialized, is latest-wins order. Cleared on `stop()`; in-flight writes still drain to completion so the
    /// mirror reflects the last in-memory snapshot across a daemon restart.
    private var baselineWriteChain: [String: Task<Void, Never>] = [:]
    /// Handle to `start()`'s off-main baseline-load task (load persisted mirror → merge with any seed
    /// already landed → persist the union). Retained only so `drainStartupLoadForTesting()` can await it
    /// deterministically instead of a test polling `debugSnapshot` under a wall-clock ceiling; production
    /// never reads this field. `nil` before `start()` is called.
    private var startupBaselineLoadTask: Task<Void, Never>?
    /// Handle to just the off-main READ half of `start()`'s baseline load (before the merge). Every durable
    /// baseline write awaits this first (see `enqueueBaselineWrite`): the read loads the persisted mirror, and
    /// a write that reaches disk before it runs is a whole-device replace over children the read hasn't merged
    /// in yet, silently destroying them. `nil` before `start()` is called, in which case the gate is a no-op.
    private var startupBaselineReadTask: Task<Result<[String: [String: SpacesDeviceAgentSessionRow]], any Error>, Never>?
    private var isStopped = false
    /// Delay before a failed connect, a dropped stream, or a failed listing pull retries through
    /// `reconcile()`. Internal so behavior tests can shorten it instead of waiting out real seconds.
    var reconnectDelay: Duration = .seconds(5)
    /// Fired inside `applyRows` immediately after its off-main watched-set read resumes on the main actor,
    /// so a behavior test can deterministically land a `seedBaseline` in exactly that suspension window and
    /// prove the stale-watched-set race is aborted rather than dropping the seeded child. `nil` (a no-op) in
    /// production.
    var didReadWatchedSetForTest: (@MainActor (String) async -> Void)?
    /// Fired inside `applyRows` immediately after the off-main exited-edge deletion resumes on the main actor
    /// and before this apply enqueues its durable baseline write, so a behavior test can deterministically land
    /// a `seedBaseline` in that suspension window and prove the apply's write is stamped with the generation its
    /// (pre-seed) snapshot reflects — losing the supersession gate to the seed's merged write — rather than a
    /// stale re-read that would clobber the freshly seeded child's baseline. `nil` (a no-op) in production.
    var didDropExitedEdgesForTest: (@MainActor (String) async -> Void)?

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
        // persisted mirror still knows about. When the merge adds a mirror-missing child (a seed's child),
        // it persists the merged union so the durable mirror matches memory; a clean startup that merely
        // refills the loaded baseline into an empty snapshot writes nothing.
        let databasePath = databasePath
        // .userInitiated, matching the connect/listing pulls: this load gates delivering the
        // downtime window's transitions after a daemon restart, and .utility work can be
        // starved for tens of seconds on a saturated machine, delaying that readiness. Stored
        // separately from `startupBaselineLoadTask` so `enqueueBaselineWrite` can await just the
        // read — awaiting the whole load task would deadlock the write it itself enqueues below.
        let readTask = Task.detached(priority: .userInitiated) { () -> Result<[String: [String: SpacesDeviceAgentSessionRow]], any Error> in
            Result { try SQLiteStore(path: databasePath).agentRemoteWatchBaselines() }
        }
        startupBaselineReadTask = readTask
        startupBaselineLoadTask = Task { @MainActor [weak self] in
            let result = await readTask.value
            guard let self, !self.isStopped else { return }
            switch result {
            case .success(let baselines):
                for (deviceID, baseline) in baselines {
                    var filledAnyEntry = false
                    for (childTerminalSessionID, row) in baseline where self.snapshots[deviceID]?[childTerminalSessionID] == nil {
                        self.snapshots[deviceID, default: [:]][childTerminalSessionID] = row
                        filledAnyEntry = true
                    }
                    // Only a device whose merge actually filled entries changed `snapshots`, so only it bumps
                    // the generation (keeping the "every snapshots mutation bumps generation" invariant).
                    guard filledAnyEntry else { continue }
                    let generation = self.bumpSnapshotGeneration(deviceID)
                    let merged = self.snapshots[deviceID] ?? [:]
                    // A `seedBaseline` landing during the off-main load enqueued its own write of {seeded} stamped
                    // with an earlier generation; this later-chained, newer-generation write of the full merged
                    // union {seeded ∪ loaded} supersedes it at the gate, so the durable mirror ends up matching
                    // the in-memory snapshot instead of stranding either the seed's or the loaded children. Skip
                    // the write on the common clean-startup path, where the merge merely refilled the loaded
                    // baseline into an empty snapshot and nothing diverges — an unconditional self-write would
                    // also risk the pull → write → signal → pull loop `applyRows` guards against.
                    guard merged != baseline else { continue }
                    self.enqueueBaselineWrite(deviceID: deviceID, generation: generation, op: "persist_merged_baseline") { store in
                        try store.replaceAgentRemoteWatchBaseline(deviceID: deviceID, baseline: merged)
                    }
                }
            case .failure(let error): self.logError("spacesd remote_agent_watch_error op=load_baselines error=\(error)\n")
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
        // Drop the chain handles but let their unstructured tasks run to completion: any baseline write still
        // in flight (e.g. a just-committed seed) must reach disk so a restarted daemon sees it. `snapshots`
        // is cleared but `snapshotGeneration` is deliberately retained so a draining write's supersession gate
        // still evaluates correctly.
        baselineWriteChain.removeAll()
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
        let generation = bumpSnapshotGeneration(deviceID)
        let baseline = snapshots[deviceID] ?? [:]
        // Two rapid seeds must not commit out of order, so the durable write is serialized per device rather
        // than fired as an independent detached task.
        enqueueBaselineWrite(deviceID: deviceID, generation: generation, op: "seed_baseline") { store in
            try store.replaceAgentRemoteWatchBaseline(deviceID: deviceID, baseline: baseline)
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
        // desired-set membership rather than alongside stream teardown. Collect the retired device ids before
        // mutating `snapshots` to avoid mutating the dictionary mid-iteration. The persisted-mirror delete goes
        // through the same per-device chain as the replace writes, so a retirement can never race and resurrect
        // a still-in-flight seed's baseline.
        for deviceID in snapshots.keys.filter({ !desired.contains($0) }) {
            snapshots[deviceID] = nil
            let generation = bumpSnapshotGeneration(deviceID)
            enqueueBaselineWrite(deviceID: deviceID, generation: generation, op: "delete_baseline") { store in
                try store.deleteAgentRemoteWatchBaseline(deviceID: deviceID)
            }
        }
        listingQueued = listingQueued.filter(desired.contains)
        for deviceID in desired where streams[deviceID] == nil && !connecting.contains(deviceID) { openStream(deviceID: deviceID) }
        for deviceID in desired where streams[deviceID] != nil { requestListing(deviceID: deviceID) }
    }

    private func openStream(deviceID: String) {
        connecting.insert(deviceID)
        let transport = transport
        let onSignal: @Sendable () -> Void = { [weak self] in Task { @MainActor in self?.handleOverviewSignal(deviceID: deviceID) } }
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
                case .success(let rows): await self.applyRows(deviceID: deviceID, rows: rows)
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
        let generationAtEntry = snapshotGeneration[deviceID] ?? 0
        let watchedResult = await Task.detached(priority: .utility) { () -> Result<Set<String>, any Error> in
            Result { Set(try SQLiteStore(path: databasePath).agentRemoteSubscriptions(deviceID: deviceID).map(\.agentSessionID)) }
        }.value
        await didReadWatchedSetForTest?(deviceID)
        guard !isStopped, streams[deviceID] != nil else { return }
        // A snapshot mutation landed on the main actor while the watched-set read was suspended off it — a
        // `seedBaseline` for a newly subscribed child, or a retirement. The watched set just read is therefore
        // stale: it may omit the seeded child, and the diff below filters the next snapshot to that watched
        // set, so blindly writing it would drop the child from the in-memory baseline and lose its next
        // transition (it would re-seed silently). Abort without touching the snapshot and coalesce a fresh
        // listing, which re-reads both the rows and the watched set against the now-updated snapshot.
        guard (snapshotGeneration[deviceID] ?? 0) == generationAtEntry else {
            listingQueued.insert(deviceID)
            return
        }
        let watched: Set<String>
        switch watchedResult {
        case .success(let ids): watched = ids
        case .failure(let error):
            logError("spacesd remote_agent_watch_error op=apply_rows device=\(deviceID) error=\(error)\n")
            return
        }
        let previous = snapshots[deviceID] ?? [:]
        let result = RemoteAgentSnapshotDiff.diff(previous: previous, newRows: rows, watchedTerminalSessionIDs: watched)
        let snapshotChanged = previous != result.snapshot
        snapshots[deviceID] = result.snapshot
        // An unchanged listing (every watched child reports back exactly what is already retained) is not
        // a real mutation of `snapshots[deviceID]`, so it must not bump the generation. Bumping here
        // unconditionally would make an older write still queued on the per-device baseline chain — e.g. a
        // `seedBaseline` stamped with the pre-bump generation, chained behind a slower earlier write —
        // look superseded and skip once its turn on the chain comes up, even though nothing about the
        // snapshot changed and that queued write is still exactly the baseline that must land on disk. See
        // `snapshotGeneration`'s doc for the supersession invariant this preserves.
        //
        // Capture the generation this snapshot reflects here, before the exited-edge suspension below, and
        // stamp the durable write with it rather than re-reading `snapshotGeneration` after that suspension.
        // A `seedBaseline` landing in the suspension bumps the generation and enqueues its own later-chained
        // write of the merged baseline; keeping this apply's write stamped with the pre-seed generation lets
        // it lose the supersession gate to that seed's write instead of clobbering the freshly seeded child's
        // durable baseline with this pre-seed snapshot.
        let generation = snapshotChanged ? bumpSnapshotGeneration(deviceID) : (snapshotGeneration[deviceID] ?? 0)

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
                        logError(
                            "spacesd remote_agent_watch device=\(deviceID) deliver_failed agent=\(transition.terminalSessionID) error=\(error)\n")
                    }
                    // The remote child is gone and its terminating line has been delivered or queued, so
                    // its edges are torn down after the loop (off-main) — the watch is complete.
                    if transition.kind == .exited { exitedTerminalSessionIDs.append(transition.terminalSessionID) }
                }
            } catch { logError("spacesd remote_agent_watch_error op=apply_rows device=\(deviceID) error=\(error)\n") }
        }

        // Drop completed watch edges and mirror the baseline, after the transitions were delivered or queued
        // (both durable), so a crash in between re-emits rather than silently drops. Only a real change writes
        // the baseline: the write signals databaseDidChange, which drives reconcile back through here — an
        // unconditional mirror would loop pull → write → signal → pull.
        guard snapshotChanged || !exitedTerminalSessionIDs.isEmpty else { return }
        // The exited children's subscription edges are an independent table from the baseline mirror, so they
        // are torn down in their own off-main task rather than on the baseline chain.
        if !exitedTerminalSessionIDs.isEmpty {
            let exited = exitedTerminalSessionIDs
            let dropResult = await Task.detached(priority: .utility) { () -> Result<Void, any Error> in
                Result {
                    let store = try SQLiteStore(path: databasePath)
                    for terminalSessionID in exited {
                        try? store.deleteAgentRemoteSubscriptions(deviceID: deviceID, agentSessionID: terminalSessionID)
                    }
                }
            }.value
            if case .failure(let error) = dropResult {
                logError("spacesd remote_agent_watch_error op=drop_exited_edges device=\(deviceID) error=\(error)\n")
            }
        }
        await didDropExitedEdgesForTest?(deviceID)
        // Serialize the baseline mirror per device so this apply cannot commit out of order with a concurrent
        // seed's write (or another apply's). Stamped with `generation` — the value captured above before the
        // exited-edge suspension, the generation this apply's snapshot reflects — not a fresh re-read: a seed
        // that lands in that suspension (or after the enqueue) bumps past `generation` and enqueues its own
        // later-chained write, which then supersedes this one at the gate instead of this pre-seed snapshot
        // clobbering the seed's merged baseline.
        if snapshotChanged {
            let baseline = result.snapshot
            enqueueBaselineWrite(deviceID: deviceID, generation: generation, op: "persist_baseline") { store in
                try store.replaceAgentRemoteWatchBaseline(deviceID: deviceID, baseline: baseline)
            }
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

    /// Drops every watch edge for `deviceID` and retires its baseline (in memory and persisted). The
    /// subscription-edge deletes are awaited in one detached task because callers hold `connecting` across this
    /// call to keep a concurrent reconcile from reopening a stream while the edges still exist; the baseline
    /// mirror delete goes on the per-device chain so it cannot race and resurrect a concurrent seed's write.
    private func dropAllEdges(deviceID: String) async {
        let databasePath = databasePath
        let result = await Task.detached(priority: .utility) { () -> Result<Void, any Error> in
            Result {
                let store = try SQLiteStore(path: databasePath)
                for edge in try store.agentRemoteSubscriptions(deviceID: deviceID) {
                    try store.deleteAgentRemoteSubscription(
                        subscriberTerminalSessionID: edge.subscriberTerminalSessionID, deviceID: deviceID, agentSessionID: edge.agentSessionID)
                }
            }
        }.value
        if case .failure(let error) = result { logError("spacesd remote_agent_watch_error op=drop_edges device=\(deviceID) error=\(error)\n") }
        snapshots[deviceID] = nil
        let generation = bumpSnapshotGeneration(deviceID)
        enqueueBaselineWrite(deviceID: deviceID, generation: generation, op: "drop_edges_baseline") { store in
            try store.deleteAgentRemoteWatchBaseline(deviceID: deviceID)
        }
    }

    /// Appends a durable baseline mutation for `deviceID` to its serial write chain (see `baselineWriteChain`).
    /// The write only runs if `generation` is still the device's latest snapshot generation — a newer mutation
    /// has its own later-chained write, so a superseded one is skipped and a burst collapses to a single write
    /// of the final snapshot. `write` runs off the main actor (the daemon keeps SQLite off its main terminal
    /// engine); only the chaining and the supersession gate touch main-actor state. The write is allowed to run
    /// even after `stop()` so an in-flight seed still reaches disk for the next daemon run.
    ///
    /// Every write also awaits `start()`'s baseline read first (`startupBaselineReadTask`), before the chain
    /// wait and the supersession check: that read loads the persisted mirror, and a write — e.g. a seed's
    /// whole-device replace — reaching disk before it runs would clobber the not-yet-merged children the
    /// mirror still holds, losing them from disk with nothing left to notice. `nil` (no `start()`, or the
    /// read already finished) proceeds immediately.
    private func enqueueBaselineWrite(deviceID: String, generation: Int, op: String, _ write: @escaping @Sendable (SQLiteStore) throws -> Void) {
        let previous = baselineWriteChain[deviceID]
        let readTask = startupBaselineReadTask
        let databasePath = databasePath
        let logError = logError
        baselineWriteChain[deviceID] = Task { @MainActor [weak self] in
            _ = await readTask?.value
            _ = await previous?.value
            if let self, self.snapshotGeneration[deviceID] != generation { return }
            let result = await Task.detached(priority: .utility) { () -> Result<Void, any Error> in
                Result { try write(SQLiteStore(path: databasePath)) }
            }.value
            if case .failure(let error) = result { logError("spacesd remote_agent_watch_error op=\(op) device=\(deviceID) error=\(error)\n") }
        }
    }

    @discardableResult private func bumpSnapshotGeneration(_ deviceID: String) -> Int {
        let next = (snapshotGeneration[deviceID] ?? 0) + 1
        snapshotGeneration[deviceID] = next
        return next
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

    /// Awaits `start()`'s baseline-load task to completion, then awaits every per-device durable-write
    /// chain tail (see `baselineWriteChain`) so a seed-merged union the load persisted has actually
    /// landed on disk, not just in memory. The load enqueues its baseline write(s) synchronously before
    /// returning (no `await` between the merge loop and the task's completion), so by the time
    /// `startupBaselineLoadTask` resolves, `baselineWriteChain` already holds the load's chain tail for
    /// every device it touched — and each chain tail's own `await previous?.value` already accounts for
    /// anything it was chained behind (e.g. a seed's write that raced the load), so awaiting the tails
    /// here needs no extra bookkeeping. The seam a test drains after `start()` + a racing `seedBaseline`
    /// instead of polling `debugSnapshot`/the persisted mirror under a wall-clock ceiling. `nil` (a
    /// no-op) if `start()` was never called.
    func drainStartupLoadForTesting() async {
        await startupBaselineLoadTask?.value
        for task in baselineWriteChain.values { await task.value }
    }
}
