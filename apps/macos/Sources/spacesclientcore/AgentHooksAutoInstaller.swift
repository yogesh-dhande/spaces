import Foundation
import spacesdevicecore
import spacesterminalcore

/// What one auto-install pass did on one device.
public struct AgentHooksAutoInstallResult: Sendable, Equatable {
    /// Agents whose hooks Spaces installed on this pass and then observed present.
    public let installed: [SupportedCodingAgentHook]
    /// Agents Spaces tried to install and could not. These stay unrecorded, so the next pass retries.
    public let failures: [AgentHookInstallFailure]

    public init(installed: [SupportedCodingAgentHook], failures: [AgentHookInstallFailure]) {
        self.installed = installed
        self.failures = failures
    }
}

/// Drives once-per-(device, agent) auto-installation of Spaces coding-agent hooks.
///
/// When a device's daemon becomes usable — the local one on app launch, a remote on pair/connect —
/// Spaces installs hooks for agents that are available on that device and that it has not successfully
/// auto-installed there before. Once an agent is recorded for a device it is never auto-touched again,
/// so a user who removes a hook is respected; the settings UI still installs on demand. The recorded
/// set is persisted in the client DB (`ClientSettingsKey.agentHooksAutoInstalled`).
///
/// An agent is recorded only when its hooks are *observed installed* afterwards, never merely because
/// it was attempted. Installs land per agent, so a batch where Claude Code succeeds and Codex fails
/// must record Claude Code (auto-install is done with it) while leaving Codex to retry. Recording the
/// whole batch on success, or none of it on failure, would either strand an agent unrecorded — and so
/// reinstall its hooks after the user deliberately removed them — or permanently give up on one that
/// only needed a retry.
///
/// The network round trips (`agentHooksStatus` / `installAgentHooks`) run against the paired device's
/// daemon, so the same path covers the local Mac daemon and remote Linux daemons.
public enum AgentHooksAutoInstaller {
    private final class RecordedSettingsLock: @unchecked Sendable {
        private let lock = NSLock()

        func withLock<T>(_ body: () throws -> T) rethrows -> T {
            lock.lock()
            defer { lock.unlock() }
            return try body()
        }
    }

    private static let recordedSettingsLock = RecordedSettingsLock()

    // MARK: - Pure decisions

    /// Agents auto-install may act on now: available on the device, and not already recorded there.
    static func candidates(status: [AgentHookStatus], alreadyRecorded: Set<SupportedCodingAgentHook>) -> [AgentHookStatus] {
        status.filter { $0.available && !alreadyRecorded.contains($0.kind) }
    }

    /// Of those candidates, the ones that actually need an install. A candidate whose hooks are already
    /// present is recorded without a redundant round trip.
    static func installTargets(candidates: [AgentHookStatus]) -> [SupportedCodingAgentHook] {
        candidates.filter { !$0.hooksInstalled }.map(\.kind)
    }

    /// The recorded set after an install pass: every candidate whose hooks the device reports installed,
    /// merged into what was already recorded. A candidate that failed is absent, so it is retried.
    static func recordedAfterInstall(
        candidates: [AgentHookStatus], finalStatus: [AgentHookStatus], alreadyRecorded: Set<SupportedCodingAgentHook>
    ) -> Set<SupportedCodingAgentHook> {
        let confirmed = candidates.map(\.kind).filter { kind in
            finalStatus.first { $0.kind == kind }?.hooksInstalled == true
        }
        return alreadyRecorded.union(confirmed)
    }

    // MARK: - Run

    /// Runs the auto-install for `device`: reads status, installs any fresh agents, persists the updated
    /// recorded set and each agent's install failure (or clears it). Throws on daemon/DB failure;
    /// callers treat a failure as "try again next connect."
    ///
    /// The device round trips run outside `recordedSettingsLock`, which guards only the marker
    /// read-modify-write: a slow or unreachable remote must not stall another device's auto-install
    /// behind a 60-second install timeout. Concurrent runs stay correct because the persist step merges
    /// per device key, and a single device is never probed concurrently (the caller holds an in-flight
    /// set per device).
    @discardableResult public static func run(
        device: SpacesPairedDeviceRecord, database: SpacesClientDatabase, clientApp: SpacesDeviceClientApp = SpacesDeviceClient.macOSClientApp(),
        profile: SpacesProfile? = nil
    ) throws -> AgentHooksAutoInstallResult {
        let status = try SpacesDeviceClient.agentHooksStatus(device: device, clientApp: clientApp, profile: profile)
        let recordedByDevice = recordedSettingsLock.withLock { loadRecorded(database: database) }
        let alreadyRecorded = Set((recordedByDevice[device.id] ?? []).compactMap(SupportedCodingAgentHook.init(rawValue:)))

        let candidates = candidates(status: status, alreadyRecorded: alreadyRecorded)
        guard !candidates.isEmpty else { return AgentHooksAutoInstallResult(installed: [], failures: []) }

        let targets = installTargets(candidates: candidates)
        var finalStatus = status
        var failures: [AgentHookInstallFailure] = []
        if !targets.isEmpty {
            let outcome = try SpacesDeviceClient.installAgentHooks(targets, device: device, clientApp: clientApp, profile: profile)
            finalStatus = outcome.agents
            failures = outcome.failures
        }

        let recorded = recordedAfterInstall(candidates: candidates, finalStatus: finalStatus, alreadyRecorded: alreadyRecorded)
        let installed = targets.filter { recorded.contains($0) }
        try persist(deviceID: device.id, recorded: recorded, attempted: targets, failures: failures, database: database)
        return AgentHooksAutoInstallResult(installed: installed, failures: failures)
    }

    // MARK: - Persistence

    /// Merges this pass's markers and failure messages into the stored maps under one lock, so a run
    /// that started from a snapshot taken before another device's run finished cannot drop that
    /// device's entries.
    static func persist(
        deviceID: String, recorded: Set<SupportedCodingAgentHook>, attempted: [SupportedCodingAgentHook], failures: [AgentHookInstallFailure],
        database: SpacesClientDatabase
    ) throws {
        try recordedSettingsLock.withLock {
            var latestRecorded = loadRecorded(database: database)
            latestRecorded[deviceID] = recorded.map(\.rawValue).sorted()
            try saveRecorded(latestRecorded, database: database)
            try mergeFailures(deviceID: deviceID, attempted: attempted, failures: failures, database: database)
        }
    }

    /// Records the reason each attempted agent failed, and clears the entry for every attempted agent
    /// that did not fail — so a message never outlives the problem it describes. Called by auto-install
    /// and by the manual install in Settings, which share the one stored map.
    public static func recordInstallFailures(
        deviceID: String, attempted: [SupportedCodingAgentHook], failures: [AgentHookInstallFailure], database: SpacesClientDatabase
    ) throws {
        try recordedSettingsLock.withLock {
            try mergeFailures(deviceID: deviceID, attempted: attempted, failures: failures, database: database)
        }
    }

    /// The last install failure per agent on `deviceID`, for Settings to explain a row it could not fix.
    public static func installFailures(deviceID: String, database: SpacesClientDatabase) -> [SupportedCodingAgentHook: String] {
        let stored = recordedSettingsLock.withLock { loadFailures(database: database) }[deviceID] ?? [:]
        return Dictionary(uniqueKeysWithValues: stored.compactMap { raw, message in SupportedCodingAgentHook(rawValue: raw).map { ($0, message) } })
    }

    /// Caller must hold `recordedSettingsLock`.
    private static func mergeFailures(
        deviceID: String, attempted: [SupportedCodingAgentHook], failures: [AgentHookInstallFailure], database: SpacesClientDatabase
    ) throws {
        guard !attempted.isEmpty else { return }
        var latest = loadFailures(database: database)
        var deviceFailures = latest[deviceID] ?? [:]
        let messagesByKind = Dictionary(failures.map { ($0.kind, $0.message) }) { _, last in last }
        for kind in attempted {
            if let message = messagesByKind[kind] {
                deviceFailures[kind.rawValue] = message
            } else {
                deviceFailures.removeValue(forKey: kind.rawValue)
            }
        }
        if deviceFailures.isEmpty {
            latest.removeValue(forKey: deviceID)
        } else {
            latest[deviceID] = deviceFailures
        }
        let data = try JSONEncoder().encode(latest)
        try database.setSetting(key: ClientSettingsKey.agentHooksInstallFailures, value: String(decoding: data, as: UTF8.self))
    }

    static func loadRecorded(database: SpacesClientDatabase) -> [String: [String]] {
        decodeSetting(key: ClientSettingsKey.agentHooksAutoInstalled, database: database) ?? [:]
    }

    static func loadFailures(database: SpacesClientDatabase) -> [String: [String: String]] {
        decodeSetting(key: ClientSettingsKey.agentHooksInstallFailures, database: database) ?? [:]
    }

    private static func decodeSetting<T: Decodable>(key: String, database: SpacesClientDatabase) -> T? {
        guard let raw = try? database.setting(key: key), let data = raw.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private static func saveRecorded(_ recorded: [String: [String]], database: SpacesClientDatabase) throws {
        let data = try JSONEncoder().encode(recorded)
        try database.setSetting(key: ClientSettingsKey.agentHooksAutoInstalled, value: String(decoding: data, as: UTF8.self))
    }
}
