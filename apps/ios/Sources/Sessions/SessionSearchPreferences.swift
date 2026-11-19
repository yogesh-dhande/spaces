import Foundation
import spacesterminalcore

/// What the Search Sessions sheet remembers between openings: the device last searched, and the agent
/// and project filters per device (a device's agents and projects are its own, so the choices do not carry
/// across devices).
struct SessionSearchPreferences {
    private static let lastDeviceKey = "spaces.mobile.session-search.last-device"
    private static let agentsKey = "spaces.mobile.session-search.agents-by-device"

    private static let projectKey = "spaces.mobile.session-search.project-by-device"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var lastDeviceID: String? {
        get { defaults.string(forKey: Self.lastDeviceKey) }
        nonmutating set { defaults.set(newValue, forKey: Self.lastDeviceKey) }
    }

    func agents(forDeviceID deviceID: String) -> Set<CodingAgent> {
        let stored = (defaults.dictionary(forKey: Self.agentsKey) as? [String: [String]])?[deviceID] ?? []
        return Set(stored.compactMap(CodingAgent.init(rawValue:)))
    }

    func setAgents(_ agents: Set<CodingAgent>, forDeviceID deviceID: String) {
        var all = (defaults.dictionary(forKey: Self.agentsKey) as? [String: [String]]) ?? [:]
        all[deviceID] = agents.isEmpty ? nil : agents.map(\.rawValue).sorted()
        defaults.set(all, forKey: Self.agentsKey)
    }

    func projectID(forDeviceID deviceID: String) -> String? { (defaults.dictionary(forKey: Self.projectKey) as? [String: String])?[deviceID] }

    func setProjectID(_ projectID: String?, forDeviceID deviceID: String) {
        var all = (defaults.dictionary(forKey: Self.projectKey) as? [String: String]) ?? [:]
        all[deviceID] = projectID
        defaults.set(all, forKey: Self.projectKey)
    }

    /// The device the sheet opens on: the last one searched while it is still paired, else the app's active
    /// (most recently used) device, else the first paired one.
    static func initialDeviceID(lastSearched: String?, activeDeviceID: String?, pairedDeviceIDs: [String]) -> String? {
        if let lastSearched, pairedDeviceIDs.contains(lastSearched) { return lastSearched }
        if let activeDeviceID, pairedDeviceIDs.contains(activeDeviceID) { return activeDeviceID }
        return pairedDeviceIDs.first
    }
}
