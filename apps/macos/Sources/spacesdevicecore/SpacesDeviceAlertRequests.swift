import Foundation

/// Dismisses alerts by key. A `comebacklater:` key clears that row's flag; any other key is recorded
/// only while it is still an alert candidate of the daemon's current overview, so a stale key from a
/// slow client cannot accumulate.
public struct SpacesDeviceDismissAlertsRequest: Codable, Sendable, Equatable {
    public let keys: [String]

    public init(keys: [String]) { self.keys = keys }
}

/// Reports that the user stayed on a terminal session long enough to count as having looked at it.
public struct SpacesDeviceVisitTerminalSessionRequest: Codable, Sendable, Equatable {
    public let sessionID: String
    /// How long the session has been focused when the client reports. The daemon derives the visit's
    /// start as now minus this, so the comparison with a flag's `flaggedAt` uses only the daemon's clock
    /// and never a client's.
    public let focusedForSeconds: Double
    /// The alert keys whose dwell completed. The device acts on no other key.
    public let keys: [String]

    public init(sessionID: String, focusedForSeconds: Double, keys: [String]) {
        self.sessionID = sessionID
        self.focusedForSeconds = focusedForSeconds
        self.keys = keys
    }
}

/// Sets or clears the Come Back Later flag on one row. Setting an already-set flag refreshes its time.
public struct SpacesDeviceSetComeBackLaterRequest: Codable, Sendable, Equatable {
    public let rowKind: SpacesDeviceComeBackLaterRowKind
    public let rowID: String
    public let isOn: Bool

    public init(rowKind: SpacesDeviceComeBackLaterRowKind, rowID: String, isOn: Bool) {
        self.rowKind = rowKind
        self.rowID = rowID
        self.isOn = isOn
    }
}
