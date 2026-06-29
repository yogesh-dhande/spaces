import Foundation
import systembridge

/// Backs an orchestrator's desktop window-ID lookups with the client database.
///
/// Desktop (yabai) window IDs are client/desktop-local and recorded only for the local device, so
/// this always scopes to `SpacesPairedDeviceRecord.localDeviceID`. It lives in `spacesclientcore`
/// (not the GUI) because every local process that drives desktop focus through an in-process
/// orchestrator — the app, the `spacese2e` harness, any CLI — must share the same window-ID store;
/// otherwise one process captures a window ID the next cannot see. Injecting it into a local
/// `SQLiteStore` lets those processes focus/track desktop windows without persisting any desktop
/// state in the daemon database, identically whether the daemon is local or remote (a remote daemon
/// has no local store and so no window IDs, which is correct).
public final class ClientDesktopWindowIDStore: DesktopWindowIDStore {
    private let deviceID: String

    public init(deviceID: String = SpacesPairedDeviceRecord.localDeviceID) { self.deviceID = deviceID }

    public func desktopWindowID(workspaceID: String, runtimeTargetID: String) throws -> Int? {
        try SpacesClientDatabase.withDefaultDatabase {
            try $0.desktopWindowID(deviceID: deviceID, workspaceID: workspaceID, runtimeTargetID: runtimeTargetID)
        }
    }

    public func setDesktopWindowID(workspaceID: String, runtimeTargetID: String, windowID: Int) throws {
        try SpacesClientDatabase.withDefaultDatabase {
            try $0.setDesktopWindowID(deviceID: deviceID, workspaceID: workspaceID, runtimeTargetID: runtimeTargetID, windowID: windowID)
        }
    }

    public func clearDesktopWindowID(workspaceID: String, runtimeTargetID: String) throws {
        try SpacesClientDatabase.withDefaultDatabase {
            try $0.clearDesktopWindowID(deviceID: deviceID, workspaceID: workspaceID, runtimeTargetID: runtimeTargetID)
        }
    }

    public func desktopWindowMatches(windowID: Int) throws -> [(workspaceID: String, runtimeTargetID: String)] {
        try SpacesClientDatabase.withDefaultDatabase { try $0.desktopWindowIDMatches(deviceID: deviceID, windowID: windowID) }
    }
}
