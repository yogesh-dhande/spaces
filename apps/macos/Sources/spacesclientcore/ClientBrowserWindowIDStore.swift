import Foundation

/// Tracks the Chrome window containing a workspace browser-session tab in the client
/// database. A browser "window" is a client/desktop-local concept (not daemon state), so this
/// always scopes to the local device. It replaces the daemon's former
/// `extracted_window_id`: the app records the window containing each focused session tab,
/// re-focuses by that window id on the fast path, and can update the row when a user-moved
/// matching tab is adopted. `Sendable` so it can be used from a detached task.
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

    /// All tracked browser-session tab locations for a workspace, used to close them when the
    /// workspace stops.
    public func windowIDs(workspaceID: String) throws -> [(targetURL: String, windowID: Int)] {
        try SpacesClientDatabase.withDefaultDatabase { try $0.browserSessionWindowIDs(deviceID: deviceID, workspaceID: workspaceID) }
    }

    /// Tracked browser-session tab locations for several workspaces at once, read through one
    /// database handle. The window cycle's cross-device modes ask about every workspace on every
    /// keypress, so they read them together rather than opening the database per workspace.
    public func windowIDs(workspaceIDs: [String]) throws -> [String: [(targetURL: String, windowID: Int)]] {
        try SpacesClientDatabase.withDefaultDatabase { database in
            var windowIDsByWorkspace: [String: [(targetURL: String, windowID: Int)]] = [:]
            for workspaceID in workspaceIDs {
                let windowIDs = try database.browserSessionWindowIDs(deviceID: deviceID, workspaceID: workspaceID)
                if !windowIDs.isEmpty { windowIDsByWorkspace[workspaceID] = windowIDs }
            }
            return windowIDsByWorkspace
        }
    }

    public func clearAll(workspaceID: String) throws {
        try SpacesClientDatabase.withDefaultDatabase { try $0.clearBrowserSessionWindowIDs(deviceID: deviceID, workspaceID: workspaceID) }
    }
}
