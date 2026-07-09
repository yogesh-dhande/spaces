import Foundation
import spacesdevicecore
import spacesterminalcore

/// Drives once-per-(device, agent) auto-installation of Spaces coding-agent hooks.
///
/// On app launch (local device) and on remote pair/connect, Spaces installs hooks for agents that are
/// available on that device and that it has not auto-installed there before. Once an agent is recorded
/// for a device it is never auto-touched again, so a user who removes a hook is respected; the
/// settings UI still installs on demand. The recorded set is persisted in the client DB
/// (`ClientSettingsKey.agentHooksAutoInstalled`).
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

    /// Pure decision: given current per-agent status and the set already auto-installed for a device,
    /// returns which agents to install now and the updated recorded set. Auto-install acts only on
    /// agents that are available and not yet recorded; agents whose hooks are already present are
    /// recorded without a redundant install.
    static func plan(status: [AgentHookStatus], alreadyRecorded: Set<SupportedCodingAgentHook>)
        -> (install: [SupportedCodingAgentHook], recorded: Set<SupportedCodingAgentHook>)
    {
        let freshCandidates = status.filter { $0.available && !alreadyRecorded.contains($0.kind) }
        let install = freshCandidates.filter { !$0.hooksInstalled }.map(\.kind)
        let recorded = alreadyRecorded.union(freshCandidates.map(\.kind))
        return (install, recorded)
    }

    /// Runs the auto-install for `device`: reads status, installs any fresh agents, and persists the
    /// updated recorded set. Returns the agents installed on this pass. Throws on daemon/DB failure;
    /// callers treat a failure as "try again next connect."
    ///
    /// The device round trips run outside `recordedSettingsLock`, which guards only the marker
    /// read-modify-write: a slow or unreachable remote must not stall another device's auto-install
    /// behind a 60-second install timeout. Concurrent runs stay correct because `saveRecorded` merges
    /// per device key, and a single device is never probed concurrently (the caller holds an in-flight
    /// set per device).
    @discardableResult public static func run(
        device: SpacesPairedDeviceRecord, database: SpacesClientDatabase, clientApp: SpacesDeviceClientApp = SpacesDeviceClient.macOSClientApp(),
        profile: SpacesProfile? = nil
    ) throws -> [SupportedCodingAgentHook] {
        let status = try SpacesDeviceClient.agentHooksStatus(device: device, clientApp: clientApp, profile: profile)
        let recordedByDevice = recordedSettingsLock.withLock { loadRecorded(database: database) }
        let alreadyRecorded = Set((recordedByDevice[device.id] ?? []).compactMap(SupportedCodingAgentHook.init(rawValue:)))
        let decision = plan(status: status, alreadyRecorded: alreadyRecorded)

        guard decision.recorded != alreadyRecorded else { return [] }  // nothing new to record or install
        if !decision.install.isEmpty {
            _ = try SpacesDeviceClient.installAgentHooks(decision.install, device: device, clientApp: clientApp, profile: profile)
        }
        try saveRecorded([device.id: decision.recorded.map { $0.rawValue }.sorted()], database: database)
        return decision.install
    }

    // MARK: - Marker persistence

    static func loadRecorded(database: SpacesClientDatabase) -> [String: [String]] {
        guard let raw = try? database.setting(key: ClientSettingsKey.agentHooksAutoInstalled), let data = raw.data(using: .utf8),
            let decoded = try? JSONDecoder().decode([String: [String]].self, from: data)
        else { return [:] }
        return decoded
    }

    /// Merges `recorded` into the stored map under the lock, per device key, so a run that started
    /// from a snapshot taken before another device's run finished cannot drop that device's markers.
    static func saveRecorded(_ recorded: [String: [String]], database: SpacesClientDatabase) throws {
        try recordedSettingsLock.withLock {
            var latest = loadRecorded(database: database)
            for (deviceID, kinds) in recorded {
                latest[deviceID] = kinds.sorted()
            }
            let data = try JSONEncoder().encode(latest)
            try database.setSetting(key: ClientSettingsKey.agentHooksAutoInstalled, value: String(decoding: data, as: UTF8.self))
        }
    }
}
