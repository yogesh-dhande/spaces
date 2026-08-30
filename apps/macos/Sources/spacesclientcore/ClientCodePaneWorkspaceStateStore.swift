import Foundation

/// Stores the Editor's per-workspace recovery document on this client only. The daemon never sees
/// this document: it includes local presentation state and may include unsaved source or comment
/// text. Callers own the JSON schema so the native store does not couple `spacesclientcore` to the
/// Editor web bundle.
public struct ClientCodePaneWorkspaceStateStore: Sendable {
    private let deviceID: String

    public init(deviceID: String = SpacesPairedDeviceRecord.localDeviceID) { self.deviceID = deviceID }

    public func stateJSON(workspaceID: String) throws -> String? {
        try SpacesClientDatabase.withDefaultDatabase { try $0.codePaneWorkspaceState(deviceID: deviceID, workspaceID: workspaceID) }
    }

    public func setStateJSON(_ stateJSON: String, workspaceID: String) throws {
        try SpacesClientDatabase.withDefaultDatabase {
            try $0.writeCodePaneWorkspaceState(deviceID: deviceID, workspaceID: workspaceID, stateJSON: stateJSON)
        }
    }

    /// Removes the whole document when a workspace is deleted. Save and Discard update the document
    /// without a dirty editor buffer so its view state remains restorable. This is intentionally not
    /// used for hibernation, workspace switching, or closing the global Editor.
    public func clear(workspaceID: String) throws {
        try SpacesClientDatabase.withDefaultDatabase { try $0.deleteCodePaneWorkspaceState(deviceID: deviceID, workspaceID: workspaceID) }
    }
}
