import spacesclientcore
import spacesdevicecore

/// A live diff-signature subscription handle. `CodePaneContentController` only ever calls `stop()` on
/// whatever `subscribeWorkspaceDiffSignature` hands back, so that single method is the seam it
/// depends on rather than the concrete, network-performing client — a test substitutes a handle that
/// just records whether/how many times it was stopped.
protocol CodePaneDiffSignatureStreamHandle: AnyObject, Sendable {
    func stop()
}

extension SpacesDeviceWorkspaceDiffSignatureStreamClient: CodePaneDiffSignatureStreamHandle {}

/// Seam over the two `SpacesDeviceClient` calls whose completions `CodePaneContentController`'s
/// staleness guards (page generation, diff-request token, diff-signature subscription generation)
/// protect against races with hibernation and scope changes. `workspaceFileRead`/`workspaceFileWrite`
/// call `SpacesDeviceClient` directly (see the controller) because they share the same `reply`
/// plumbing without exercising any of those guards themselves — only diff fetch/subscribe do, so
/// only those two are worth a test seam.
protocol CodePaneDeviceGateway: Sendable {
    func workspaceDiff(workspaceID: String, refName: String?, device: SpacesPairedDeviceRecord) async throws -> SpacesDeviceWorkspaceDiffResult

    func subscribeWorkspaceDiffSignature(
        workspaceID: String, refName: String?, device: SpacesPairedDeviceRecord,
        onFrame: @escaping @Sendable (SpacesDeviceWorkspaceDiffSignatureFrame) -> Void,
        onDisconnect: @escaping @Sendable ((any Error)?) -> Void
    ) async throws -> any CodePaneDiffSignatureStreamHandle
}

/// Forwards to `SpacesDeviceClient`'s real, network-performing static methods, off the caller's task
/// via `Task.detached` — matching how these calls ran before this seam existed, so wrapping them in
/// `async` changes nothing about where the blocking I/O actually executes.
struct LiveCodePaneDeviceGateway: CodePaneDeviceGateway {
    func workspaceDiff(workspaceID: String, refName: String?, device: SpacesPairedDeviceRecord) async throws -> SpacesDeviceWorkspaceDiffResult {
        try await Task.detached(priority: .userInitiated) {
            try SpacesDeviceClient.workspaceDiff(workspaceID: workspaceID, refName: refName, device: device)
        }.value
    }

    func subscribeWorkspaceDiffSignature(
        workspaceID: String, refName: String?, device: SpacesPairedDeviceRecord,
        onFrame: @escaping @Sendable (SpacesDeviceWorkspaceDiffSignatureFrame) -> Void,
        onDisconnect: @escaping @Sendable ((any Error)?) -> Void
    ) async throws -> any CodePaneDiffSignatureStreamHandle {
        try await Task.detached(priority: .utility) {
            try SpacesDeviceClient.subscribeWorkspaceDiffSignature(
                workspaceID: workspaceID, refName: refName, device: device, onFrame: onFrame, onDisconnect: onDisconnect)
        }.value
    }
}
