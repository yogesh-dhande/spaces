import Foundation
import spacesclientcore

/// Narrow persistence seam for the native Editor controller. Keeping the storage transport here
/// lets controller tests exercise workspace replacement without mutating the test process's real
/// client profile.
protocol CodePaneWorkspaceStateStoring: AnyObject, Sendable {
    /// Stable for every controller that addresses the same client-local document. It scopes the
    /// in-process recovery cache; it is not persisted or sent to the daemon.
    var workspaceStateStorageKey: String { get }
    func stateJSON(workspaceID: String) throws -> String?
    func setStateJSON(_ stateJSON: String, workspaceID: String) throws
}

final class ClientCodePaneWorkspaceStateStorage: CodePaneWorkspaceStateStoring, @unchecked Sendable {
    private let store: ClientCodePaneWorkspaceStateStore
    private let deviceID: String

    init(deviceID: String) {
        self.deviceID = deviceID
        store = ClientCodePaneWorkspaceStateStore(deviceID: deviceID)
    }

    static func storageKey(deviceID: String) -> String { "client-code-pane-state:\(deviceID)" }

    var workspaceStateStorageKey: String { Self.storageKey(deviceID: deviceID) }

    func stateJSON(workspaceID: String) throws -> String? { try store.stateJSON(workspaceID: workspaceID) }

    func setStateJSON(_ stateJSON: String, workspaceID: String) throws {
        try store.setStateJSON(stateJSON, workspaceID: workspaceID)
    }
}

/// Test-only sink. Production always supplies `ClientCodePaneWorkspaceStateStorage`.
final class DiscardingCodePaneWorkspaceStateStorage: CodePaneWorkspaceStateStoring, @unchecked Sendable {
    private let storageID = UUID().uuidString

    var workspaceStateStorageKey: String { "discarding-code-pane-state:\(storageID)" }
    func stateJSON(workspaceID: String) throws -> String? { nil }
    func setStateJSON(_ stateJSON: String, workspaceID: String) throws {}
}
