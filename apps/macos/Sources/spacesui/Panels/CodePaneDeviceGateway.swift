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

/// Seam over the `SpacesDeviceClient` calls whose completions `CodePaneContentController`'s
/// staleness guards (page generation, diff-request token, diff-signature subscription generation)
/// protect against races with hibernation and scope changes, plus the review-comment CRUD/send
/// calls (kept here too, rather than called directly like `workspaceFileRead`/`workspaceFileWrite`
/// are, so `CodePaneContentControllerTests` can assert exactly which comment/args a dispatched RPC
/// resolves to without a live device).
protocol CodePaneDeviceGateway: Sendable {
    func workspaceDiff(workspaceID: String, refName: String?, device: SpacesPairedDeviceRecord) async throws -> SpacesDeviceWorkspaceDiffResult

    func subscribeWorkspaceDiffSignature(
        workspaceID: String, refName: String?, device: SpacesPairedDeviceRecord,
        onFrame: @escaping @Sendable (SpacesDeviceWorkspaceDiffSignatureFrame) -> Void,
        onDisconnect: @escaping @Sendable ((any Error)?) -> Void
    ) async throws -> any CodePaneDiffSignatureStreamHandle

    func workspaceReviewCommentList(workspaceID: String, device: SpacesPairedDeviceRecord) async throws -> [SpacesDeviceReviewComment]

    func workspaceReviewCommentUpsert(
        workspaceID: String, id: String?, filePath: String, side: SpacesDeviceReviewCommentSide, lineNumber: Int, lineText: String, body: String,
        device: SpacesPairedDeviceRecord
    ) async throws -> SpacesDeviceReviewComment

    func workspaceReviewCommentDelete(workspaceID: String, id: String, device: SpacesPairedDeviceRecord) async throws -> SpacesDeviceAPIResponse

    func workspaceReviewCommentsSend(
        workspaceID: String, sessionID: String, text: String, comments: [SpacesDeviceReviewCommentSendEntry], device: SpacesPairedDeviceRecord
    ) async throws -> SpacesDeviceAPIResponse
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

    func workspaceReviewCommentList(workspaceID: String, device: SpacesPairedDeviceRecord) async throws -> [SpacesDeviceReviewComment] {
        try await Task.detached(priority: .userInitiated) {
            try SpacesDeviceClient.workspaceReviewCommentList(workspaceID: workspaceID, device: device)
        }.value
    }

    func workspaceReviewCommentUpsert(
        workspaceID: String, id: String?, filePath: String, side: SpacesDeviceReviewCommentSide, lineNumber: Int, lineText: String, body: String,
        device: SpacesPairedDeviceRecord
    ) async throws -> SpacesDeviceReviewComment {
        try await Task.detached(priority: .userInitiated) {
            try SpacesDeviceClient.workspaceReviewCommentUpsert(
                workspaceID: workspaceID, id: id, filePath: filePath, side: side, lineNumber: lineNumber, lineText: lineText, body: body,
                device: device)
        }.value
    }

    func workspaceReviewCommentDelete(workspaceID: String, id: String, device: SpacesPairedDeviceRecord) async throws -> SpacesDeviceAPIResponse {
        try await Task.detached(priority: .userInitiated) {
            try SpacesDeviceClient.workspaceReviewCommentDelete(workspaceID: workspaceID, id: id, device: device)
        }.value
    }

    func workspaceReviewCommentsSend(
        workspaceID: String, sessionID: String, text: String, comments: [SpacesDeviceReviewCommentSendEntry], device: SpacesPairedDeviceRecord
    ) async throws -> SpacesDeviceAPIResponse {
        try await Task.detached(priority: .userInitiated) {
            try SpacesDeviceClient.workspaceReviewCommentsSend(
                workspaceID: workspaceID, sessionID: sessionID, text: text, comments: comments, device: device)
        }.value
    }
}
