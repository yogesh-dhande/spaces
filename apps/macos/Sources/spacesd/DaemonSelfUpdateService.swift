import Foundation
import spacesterminalcore
import workspacecore

/// Lets an installed Linux release daemon check its channel for a newer release and install it on request.
///
/// Availability and progress are facts this daemon reports in its `TerminalServiceDaemonStatus`; clients
/// never derive them. The status builders read `DaemonSelfUpdateStatusCache`, which this service refreshes
/// whenever its view changes, so building a status does no I/O.
///
/// The install itself is the bundled `spaces-install-linux.sh` of the running release (the same signed,
/// checksum-verified path as the website installer), run as a transient systemd user unit. A unit lives
/// outside the daemon's cgroup and pid, so it survives the exec handoff that applies the update and is
/// reaped by systemd instead of lingering as a zombie under the new image. Its log is the source of truth
/// for progress (see `DaemonSelfUpdateProgressDerivation`).
final class DaemonSelfUpdateService: DaemonSelfUpdateControlling, @unchecked Sendable {
    /// Fixed so a second launch fails while a run is in flight.
    static let unitName = "spacesd-self-update"
    static let checkInterval: TimeInterval = 6 * 60 * 60
    static let initialCheckDelay: TimeInterval = 5
    static let failedCheckRetryInterval: TimeInterval = 10 * 60

    private let runningVersion: String
    private let installerURL: URL
    private let logURL: URL
    private let stateURL: URL
    private let cache: DaemonSelfUpdateStatusCache

    private let lock = NSLock()
    /// The persisted choice; nil until the user picks one or the first check decides a default.
    private var channel: DaemonUpdateChannel?
    /// Newest version on the effective channel from the last successful check.
    private var feedVersion: String?
    private var runState: DaemonSelfUpdateRunState?
    private var progress: DaemonSelfUpdateProgress?
    private var nextCheckAt = Date.distantFuture
    private var checkInFlight = false
    private var started = false

    init(runningVersion: String, installerURL: URL, runtimeDirectory: URL, cache: DaemonSelfUpdateStatusCache = .shared) {
        self.runningVersion = runningVersion
        self.installerURL = installerURL
        logURL = runtimeDirectory.appendingPathComponent("daemon-self-update.log", isDirectory: false)
        stateURL = runtimeDirectory.appendingPathComponent("daemon-self-update.json", isDirectory: false)
        self.cache = cache
        channel = Self.storedChannel()
        runState = Self.readRunState(at: stateURL)
    }

    /// The service for this process, or nil when this daemon cannot update itself: only a Linux daemon
    /// running an installed release (`<root>/releases/<version>/bin/`, with its bundled installer) can.
    /// macOS daemons update through Sparkle and development builds have no installed release to replace.
    static func makeIfSupported() -> DaemonSelfUpdateService? {
        #if os(Linux)
            guard let profile = try? SpacesProfile.current(), profile.isInstalledProfile,
                let executableURL = Bundle.main.executableURL,
                let installerURL = DaemonSelfUpdateInstallLayout.installerURL(forExecutable: executableURL),
                FileManager.default.fileExists(atPath: installerURL.path)
            else { return nil }
            return DaemonSelfUpdateService(
                runningVersion: AppVersion.current, installerURL: installerURL,
                runtimeDirectory: URL(fileURLWithPath: profile.runtimeDirectory, isDirectory: true))
        #else
            return nil
        #endif
    }

    /// Publishes the first status, schedules the first check, and settles the run a previous daemon
    /// process left behind.
    func start() {
        lock.lock()
        guard !started else {
            lock.unlock()
            return
        }
        started = true
        nextCheckAt = Date().addingTimeInterval(Self.initialCheckDelay)
        lock.unlock()
        publish()
        SpacesBlockingIOThread.spawn(name: "spacesd.selfupdate.recover") { [self] in settleInheritedRun() }
    }

    /// Called every second from the lifecycle timer. Re-reads the runner's log while a run is in flight and
    /// starts a feed check when one is due; the check itself runs off the timer's thread.
    func tick(now: Date = Date()) {
        refreshProgressIfRunning()
        lock.lock()
        let due = started && !checkInFlight && now >= nextCheckAt
        if due { checkInFlight = true }
        lock.unlock()
        if due { SpacesBlockingIOThread.spawn(name: "spacesd.selfupdate.check") { [self] in performCheck() } }
    }

    // MARK: - DaemonSelfUpdateControlling

    func startUpdate() -> DaemonSelfUpdateStartOutcome {
        lock.lock()
        let running = runState != nil && progress != nil && progress?.step != .failed
        let feed = feedVersion
        lock.unlock()
        if running { return .alreadyRunning }
        guard let target = availableVersion(feed: feed) else { return .upToDate }
        // A unit that outlived the daemon that launched it still owns the log; never clobber it.
        if isRunnerActive() { return .alreadyRunning }

        let state = DaemonSelfUpdateRunState(targetVersion: target)
        do {
            try? FileManager.default.removeItem(at: logURL)
            try JSONEncoder().encode(state).write(to: stateURL, options: .atomic)
        } catch { return .launchFailed("Couldn't record the update to run.") }

        // The wrapper appends `step exited <status>`, the one line that tells a reader the installer is done.
        // The paths arrive as `$0 $1 $2` positional arguments, so none of them needs shell quoting.
        let wrapper = #"exec >"$0" 2>&1; bash "$1" "$2"; echo "spaces-install-linux: step exited $?""#
        // `--collect` unloads the transient unit even after a failed run, so the fixed unit name is free for the next attempt.
        let launch = runProcess(
            [
                "systemd-run", "--user", "--collect", "--quiet", "--unit=\(Self.unitName)", "bash", "-c", wrapper, logURL.path,
                installerURL.path, target,
            ], Self.systemdCommandTimeoutSeconds)
        guard let launch, launch.status == 0 else {
            try? FileManager.default.removeItem(at: stateURL)
            let detail = launch.flatMap { String(decoding: $0.output, as: UTF8.self).split(whereSeparator: \.isNewline).first.map(String.init) }
            return .launchFailed(detail.map { "Couldn't start the update: \($0)" } ?? "Couldn't start the update.")
        }

        lock.lock()
        runState = state
        progress = DaemonSelfUpdateProgress(targetVersion: target, step: .downloading, receivedBytes: 0, totalBytes: nil)
        lock.unlock()
        publish()
        return .started
    }

    func setChannel(_ newChannel: DaemonUpdateChannel) throws {
        let store = try SQLiteStore(path: try DatabaseLocator.defaultPath())
        lock.lock()
        do {
            try store.setSetting(key: SettingsKey.daemonUpdateChannel, value: newChannel.rawValue)
        } catch {
            lock.unlock()
            throw error
        }
        channel = newChannel
        feedVersion = nil
        nextCheckAt = Date()
        lock.unlock()
        publish()
        tick()
    }

    // MARK: - Feed check

    private func performCheck() {
        lock.lock()
        var effectiveChannel = channel
        lock.unlock()

        var stableVersion: String?
        if effectiveChannel == nil {
            // Decided once, from the stable feed, and persisted so the answer survives the update.
            guard let stable = Self.fetchFeedVersion(for: .stable, run: runProcess),
                let decided = DaemonSelfUpdateFeed.defaultChannel(runningVersion: runningVersion, stableFeedVersion: stable)
            else { return finishCheck(usedChannel: .stable, feedVersion: nil) }
            // The save happens under the same lock `setChannel` saves under, and only while no channel is
            // set: a choice the user made while the fetch was in flight must win in the database too, or
            // the next restart would silently follow the inferred default.
            lock.lock()
            if channel == nil {
                do {
                    let store = try SQLiteStore(path: try DatabaseLocator.defaultPath())
                    try store.setSetting(key: SettingsKey.daemonUpdateChannel, value: decided.rawValue)
                } catch {
                    lock.unlock()
                    Self.log("daemon update channel could not be saved: \(error)")
                    return finishCheck(usedChannel: .stable, feedVersion: nil)
                }
                channel = decided
            }
            effectiveChannel = channel
            lock.unlock()
            stableVersion = stable
        }

        let used = effectiveChannel ?? .stable
        let feed = used == .stable && stableVersion != nil ? stableVersion : Self.fetchFeedVersion(for: used, run: runProcess)
        finishCheck(usedChannel: used, feedVersion: feed)
    }

    private func finishCheck(usedChannel: DaemonUpdateChannel, feedVersion feed: String?) {
        let now = Date()
        lock.lock()
        checkInFlight = false
        if (channel ?? .stable) != usedChannel {
            // The channel changed mid-check, so the answer belongs to the old one; check again.
            nextCheckAt = now
            lock.unlock()
            return
        }
        if let feed {
            feedVersion = feed
            nextCheckAt = now.addingTimeInterval(Self.checkInterval)
        } else {
            // Keep the last known value: a failed check says nothing about what is available.
            nextCheckAt = now.addingTimeInterval(Self.failedCheckRetryInterval)
        }
        lock.unlock()
        publish()
    }

    private static func fetchFeedVersion(
        for channel: DaemonUpdateChannel, run: ([String], TimeInterval) -> DaemonSelfUpdateCommand.Output?
    ) -> String? {
        // Silent without `-S`, so a successful run's interleaved output is exactly the feed document.
        guard
            let output = run(
                ["curl", "-fsL", "--max-time", "30", DaemonSelfUpdateFeed.url(for: channel).absoluteString], feedCommandTimeoutSeconds),
            output.status == 0
        else { return nil }
        return DaemonSelfUpdateFeed.parseVersion(from: output.output)
    }

    // MARK: - Run progress

    private func refreshProgressIfRunning() {
        lock.lock()
        let state = runState
        let current = progress
        lock.unlock()
        guard let state, let current, current.step != .failed else { return }

        let result = DaemonSelfUpdateProgressDerivation.derive(
            logText: readLog(), targetVersion: state.targetVersion, runningVersion: runningVersion, archiveSize: Self.fileSize(atPath:))
        if result.isRunSpent { clearRunFiles() }
        lock.lock()
        let changed = result.progress != progress || result.isRunSpent
        if runState == state {
            progress = result.progress
            if result.isRunSpent { runState = nil }
        }
        lock.unlock()
        if changed { publish() }
    }

    /// A previous daemon process may have launched a run: the update itself restarts the daemon, and a
    /// run can also be cut short. A run whose target this process already runs is spent. A run with no
    /// `exited` line, an older running version and no live runner unit never finished and never will.
    private func settleInheritedRun() {
        lock.lock()
        let state = runState
        lock.unlock()
        guard let state else { return }

        let logText = readLog()
        var settledProgress: DaemonSelfUpdateProgress?
        var spent = false
        if let recovered = DaemonSelfUpdateProgressDerivation.recoveredProgress(
            logText: logText, targetVersion: state.targetVersion, runningVersion: runningVersion, runnerUnitIsActive: isRunnerActive())
        {
            settledProgress = recovered
        } else {
            let result = DaemonSelfUpdateProgressDerivation.derive(
                logText: logText, targetVersion: state.targetVersion, runningVersion: runningVersion, archiveSize: Self.fileSize(atPath:))
            settledProgress = result.progress
            spent = result.isRunSpent
        }
        if spent { clearRunFiles() }
        lock.lock()
        if runState == state {
            progress = settledProgress
            if spent { runState = nil }
        }
        lock.unlock()
        publish()
    }

    private func clearRunFiles() {
        try? FileManager.default.removeItem(at: logURL)
        try? FileManager.default.removeItem(at: stateURL)
    }

    // MARK: - Status

    /// The feed's version when it is newer than both the running build and the build already installed
    /// beside it: a run that finished but has not restarted yet leaves nothing more to offer.
    private func availableVersion(feed: String?) -> String? {
        guard let feed, let available = DaemonSelfUpdateFeed.availableVersion(runningVersion: runningVersion, feedVersion: feed) else { return nil }
        if let installed = InstalledSpacesVersion.current(), !SpacesWireProtocol.isVersion(installed, olderThan: available) { return nil }
        return available
    }

    private func publish() {
        lock.lock()
        let status = (channel ?? .stable, feedVersion, progress)
        lock.unlock()
        cache.store(DaemonSelfUpdateStatus(channel: status.0, availableVersion: availableVersion(feed: status.1), progress: status.2))
    }

    // MARK: - Files and processes

    private func readLog() -> String { (try? String(contentsOf: logURL, encoding: .utf8)) ?? "" }

    private static func fileSize(atPath path: String) -> Int64? {
        (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value
    }

    private static func readRunState(at url: URL) -> DaemonSelfUpdateRunState? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(DaemonSelfUpdateRunState.self, from: data)
    }

    private static func storedChannel() -> DaemonUpdateChannel? {
        guard let path = try? DatabaseLocator.defaultPath(), let store = try? SQLiteStore(path: path),
            let raw = try? store.setting(key: SettingsKey.daemonUpdateChannel)
        else { return nil }
        return DaemonUpdateChannel(rawValue: raw)
    }

    private func isRunnerActive() -> Bool {
        runProcess(["systemctl", "--user", "is-active", "--quiet", Self.unitName], Self.systemdCommandTimeoutSeconds)?.status == 0
    }

    /// The bound only stops a wedged command from holding its caller. The systemd commands run on the
    /// Device API's state queue when a client presses Update, so they get a tight one; the feed fetch runs
    /// on its own thread and is already capped by curl's `--max-time 30`.
    private static let systemdCommandTimeoutSeconds: TimeInterval = 10
    private static let feedCommandTimeoutSeconds: TimeInterval = 45

    private func runProcess(_ arguments: [String], _ timeoutSeconds: TimeInterval) -> DaemonSelfUpdateCommand.Output? {
        DaemonSelfUpdateCommand.run(arguments, timeoutSeconds: timeoutSeconds)
    }

    private static func log(_ message: String) { FileHandle.standardError.write(Data("spacesd: \(message)\n".utf8)) }
}
