import Foundation

/// Tracks the dedicated Chrome window opened for a workspace browser session, in the client
/// database. A browser "window" is a client/desktop-local concept (not daemon state), so this
/// always scopes to the local device. It replaces the daemon's former
/// `extracted_window_id`: the app opens a dedicated window for a session once, records its id
/// here, and re-focuses that same window by id — so focus never lands on an unrelated window
/// that merely has the same URL open. `Sendable` so it can be used from a detached task.
public struct ClientBrowserWindowIDStore: Sendable {
    private let deviceID: String

    public init(deviceID: String = SpacesPairedDeviceRecord.localDeviceID) { self.deviceID = deviceID }

    public func windowID(workspaceID: String, targetURL: String) throws -> Int? {
        try SpacesClientDatabase.withDefaultDatabase {
            try $0.browserSessionWindowID(deviceID: deviceID, workspaceID: workspaceID, targetURL: targetURL)
        }
    }

    public func setWindowID(workspaceID: String, targetURL: String, windowID: Int) throws {
        try SpacesClientDatabase.withDefaultDatabase {
            try $0.setBrowserSessionWindowID(deviceID: deviceID, workspaceID: workspaceID, targetURL: targetURL, windowID: windowID)
        }
    }

    public func clearWindowID(workspaceID: String, targetURL: String) throws {
        try SpacesClientDatabase.withDefaultDatabase {
            try $0.clearBrowserSessionWindowID(deviceID: deviceID, workspaceID: workspaceID, targetURL: targetURL)
        }
    }
    /// All dedicated Chrome windows tracked for a workspace, used to close them when the
    /// workspace stops.
    public func windowIDs(workspaceID: String) throws -> [(targetURL: String, windowID: Int)] {
        try SpacesClientDatabase.withDefaultDatabase { try $0.browserSessionWindowIDs(deviceID: deviceID, workspaceID: workspaceID) }
    }

    public func clearAll(workspaceID: String) throws {
        try SpacesClientDatabase.withDefaultDatabase { try $0.clearBrowserSessionWindowIDs(deviceID: deviceID, workspaceID: workspaceID) }
    }
}
