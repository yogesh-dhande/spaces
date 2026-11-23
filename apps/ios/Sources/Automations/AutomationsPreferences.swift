import Foundation

/// The device the Automations tab shows, remembered between launches. It is this tab's own choice, kept
/// apart from the app-wide active device: automations and their actions follow what is picked here, and
/// picking a device here changes nothing on any other tab.
struct AutomationsPreferences {
    private static let deviceKey = "spaces.mobile.automations.device"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var deviceID: String? {
        get { defaults.string(forKey: Self.deviceKey) }
        nonmutating set { defaults.set(newValue, forKey: Self.deviceKey) }
    }

    /// The device the tab shows: the remembered one while it is still paired, else the first paired one.
    static func resolvedDeviceID(remembered: String?, pairedDeviceIDs: [String]) -> String? {
        if let remembered, pairedDeviceIDs.contains(remembered) { return remembered }
        return pairedDeviceIDs.first
    }
}
