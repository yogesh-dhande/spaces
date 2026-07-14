import Foundation

/// Persists the stable `TerminalClient` id this Mac uses to attach to a terminal session as OWNER,
/// in the client database. The mac app mints a fresh client id per launch, so without a stable id a
/// relaunched window (e.g. after an app upgrade) re-attaches to its still-running daemon session as a
/// viewer: the dead instance's `localWindow` owner attachment never expires and keeps ownership,
/// forcing a manual "take over" click. Reusing the stored id makes the daemon see the relaunched
/// window as the same owner, so it silently reclaims ownership through the normal attach path.
///
/// Scoped to the local device (a terminal owner "window" is a client/desktop-local concept, not
/// daemon state). The stored UUID exists only on this Mac and can only ever match THIS device's own
/// prior attachment: if another device owns the session, the stored id differs from the current
/// owner, so the pane attaches as a viewer and the manual takeover UI is unchanged — no name-string
/// heuristics and no auto-takeover of foreign owners. Keyed by (local device id, session id); session
/// ids are globally unique. A stale mapping is inert (it matches no current owner). `Sendable` so it
/// can be read at pane construction and written from the pane's detached control closures.
public struct ClientTerminalOwnerClientIDStore: Sendable {
    private let deviceID: String

    public init(deviceID: String = SpacesPairedDeviceRecord.localDeviceID) { self.deviceID = deviceID }

    public func clientID(sessionID: String) throws -> String? {
        try SpacesClientDatabase.withDefaultDatabase { try $0.terminalOwnerClientID(deviceID: deviceID, sessionID: sessionID) }
    }

    public func setClientID(sessionID: String, clientID: String) throws {
        try SpacesClientDatabase.withDefaultDatabase { try $0.setTerminalOwnerClientID(deviceID: deviceID, sessionID: sessionID, clientID: clientID) }
    }
}
