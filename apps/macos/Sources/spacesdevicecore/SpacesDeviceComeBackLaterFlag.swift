import Foundation

/// The kind of workspace row a Come Back Later flag sits on. A flag is per row (not per session), so it
/// outlives the session the row currently shows.
public enum SpacesDeviceComeBackLaterRowKind: String, Codable, Sendable, Equatable, Hashable {
    case agent
    case process
    case terminal
}

/// A "come back to this later" mark the user put on one workspace row, held by the device's daemon so
/// every client sees the same flags. It surfaces as an alert (`SpacesDeviceAlertKind.comeBackLater`) until
/// a later visit to the row's session, or a dismissal of that alert, clears it.
public struct SpacesDeviceComeBackLaterFlag: Codable, Sendable, Equatable, Hashable {
    public let rowKind: SpacesDeviceComeBackLaterRowKind
    public let rowID: String
    /// ISO-8601, stamped by the daemon when the flag was set (or last refreshed).
    public let flaggedAt: String

    public init(rowKind: SpacesDeviceComeBackLaterRowKind, rowID: String, flaggedAt: String) {
        self.rowKind = rowKind
        self.rowID = rowID
        self.flaggedAt = flaggedAt
    }

    /// The flag's alert key. It carries no timestamp, so refreshing a flag keeps one alert identity.
    public var alertKey: String { Self.alertKey(rowKind: rowKind, rowID: rowID) }

    public static let alertKeyPrefix = "comebacklater:"

    public static func alertKey(rowKind: SpacesDeviceComeBackLaterRowKind, rowID: String) -> String { "\(alertKeyPrefix)\(rowKind.rawValue):\(rowID)" }

    /// The row a flag alert key names, or nil when `key` is not a flag key. Row kinds never contain `:`,
    /// while row ids may, so the split is at the first separator after the prefix.
    public static func rowReference(fromAlertKey key: String) -> (rowKind: SpacesDeviceComeBackLaterRowKind, rowID: String)? {
        guard key.hasPrefix(alertKeyPrefix) else { return nil }
        let rest = key.dropFirst(alertKeyPrefix.count)
        guard let separator = rest.firstIndex(of: ":"), let rowKind = SpacesDeviceComeBackLaterRowKind(rawValue: String(rest[..<separator])) else {
            return nil
        }
        return (rowKind, String(rest[rest.index(after: separator)...]))
    }
}
