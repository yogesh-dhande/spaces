import Foundation
import spacesdevicecore

/// Resolves a user-entered device selector (`--device <name-or-id>` on the CLI, `device` on MCP
/// tools) against the profile's paired-device records. An exact ID match wins; otherwise the name
/// must match exactly one device case-insensitively. Failures list the candidates so agents can
/// self-correct without a separate discovery round trip.
public enum SpacesPairedDeviceSelection {
    public static func resolve(_ nameOrID: String, database providedDatabase: SpacesClientDatabase? = nil) throws -> SpacesPairedDeviceRecord {
        let selector = nameOrID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !selector.isEmpty else { throw SpacesClientError.invalidArgument("Device name or ID is required.") }
        let database = try providedDatabase ?? SpacesClientDatabase.defaultDatabase()
        let devices = try database.pairedDevices()
        if let exact = devices.first(where: { $0.id == selector }) { return exact }
        let nameMatches = devices.filter { $0.name.compare(selector, options: [.caseInsensitive]) == .orderedSame }
        if nameMatches.count == 1 { return nameMatches[0] }
        if nameMatches.count > 1 {
            throw SpacesClientError.invalidArgument(
                "Device name '\(selector)' matches multiple paired devices. Use the device ID:\n\(deviceRows(nameMatches))")
        }
        guard !devices.isEmpty else {
            throw SpacesClientError.invalidArgument("No device matches '\(selector)'. No devices are paired; run `spaces device pair` first.")
        }
        throw SpacesClientError.invalidArgument("No device matches '\(selector)'. Paired devices:\n\(deviceRows(devices))")
    }

    /// One tab-separated line per device: id, name, platform, the address it is currently dialed at
    /// labeled by network path, and every candidate address it may fail over to. The candidates are
    /// listed because a device that answers on one address and not another is otherwise invisible from
    /// the CLI, and diagnosing that is exactly what someone reaching for `spaces device list` is doing.
    public static func deviceRows(_ devices: [SpacesPairedDeviceRecord]) -> String {
        devices.map { device in
            let address = device.dialHost.map { "\(SpacesDeviceHostAddressKind(host: $0).label) · \($0):\(device.port)" } ?? "-"
            let candidates = device.hosts.isEmpty ? "-" : device.hosts.joined(separator: ",")
            return "\(device.id)\t\(device.name)\t\(device.platform)\t\(address)\t\(candidates)"
        }.joined(separator: "\n")
    }
}
