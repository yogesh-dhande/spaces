import spacesclientcore
import spacesdevicecore
import spacesterminalcore

/// A live diff-signature subscription handle. `CodePaneContentController` only ever calls `stop()` on
/// whatever `subscribeWorkspaceDiffSignature` hands back, so that single method is the seam it
/// depends on rather than the concrete, network-performing client — a test substitutes a handle that
/// just records whether/how many times it was stopped.
protocol CodePaneDiffSignatureStreamHandle: AnyObject, Sendable { func stop() }

extension SpacesDeviceWorkspaceDiffSignatureStreamClient: CodePaneDiffSignatureStreamHandle {}

/// A live file-signature subscription handle. Mirrors `CodePaneDiffSignatureStreamHandle` exactly.
protocol CodePaneFileSignatureStreamHandle: AnyObject, Sendable { func stop() }

extension SpacesDeviceWorkspaceFileSignatureStreamClient: CodePaneFileSignatureStreamHandle {}

/// A live workspace-file-list-signature subscription handle. Mirrors the diff/file handles exactly.
protocol CodePaneFileListSignatureStreamHandle: AnyObject, Sendable { func stop() }

extension SpacesDeviceWorkspaceFileListSignatureStreamClient: CodePaneFileListSignatureStreamHandle {}

/// Seam over the `SpacesDeviceClient` calls whose completions `CodePaneContentController`'s
/// staleness guards (page generation, diff-request/file-read token, diff/file-signature subscription
/// generation) protect against races with hibernation and scope/path changes, plus the review-comment
/// CRUD/send calls and `workspaceFileWrite` (kept here too, rather than called directly, so
/// `CodePaneContentControllerTests` can assert exactly which comment/args a dispatched RPC resolves to
/// without a live device) — `workspaceFileWrite`'s completion feeds the flushed-snapshot baseline
/// adoption and the deferred-ready gate (`adoptCommittedWriteIntoEditorState`,
/// `outstandingFileWriteCount`), exactly the class of completion this seam exists for.
protocol CodePaneDeviceGateway: Sendable {
    func workspaceDiffManifestChunk(
        workspaceID: String, refName: String?, lastCommit: Bool, manifestID: String?, fileIndex: Int, device: SpacesPairedDeviceRecord
    ) async throws -> SpacesDeviceWorkspaceDiffManifestChunkResult

    func workspaceDiffFileChunk(
        workspaceID: String, refName: String?, lastCommit: Bool, manifestID: String, relativePath: String, byteOffset: Int, transferID: String?,
        device: SpacesPairedDeviceRecord
    ) async throws -> SpacesDeviceWorkspaceDiffFileChunkResult

    func cancelWorkspaceDiffFileChunk(
        workspaceID: String, refName: String?, lastCommit: Bool, manifestID: String, relativePath: String, byteOffset: Int, transferID: String,
        device: SpacesPairedDeviceRecord) async throws

    func cancelWorkspaceDiffManifest(workspaceID: String, refName: String?, lastCommit: Bool, manifestID: String, device: SpacesPairedDeviceRecord)
        async throws

    func workspaceFileRead(
        workspaceID: String, relativePath: String, comparisonBaseRevision: String?, oldPath: String?, requiresDirectPath: Bool,
        device: SpacesPairedDeviceRecord
    ) async throws
        -> SpacesDeviceWorkspaceFileReadResult

    func workspaceRevisionFileRead(workspaceID: String, revision: String, relativePath: String, oldPath: String?, device: SpacesPairedDeviceRecord) async throws
        -> SpacesDeviceWorkspaceRevisionFileReadResult

    func workspaceFileList(workspaceID: String, device: SpacesPairedDeviceRecord) async throws -> SpacesDeviceWorkspaceFileListResult

    func workspaceRefList(workspaceID: String, device: SpacesPairedDeviceRecord) async throws -> SpacesDeviceWorkspaceRefListResult

    func workspaceFileWrite(
        workspaceID: String, relativePath: String, base64Data: String, expectedSHA256: String?, requiresDirectPath: Bool,
        device: SpacesPairedDeviceRecord
    )
        async throws -> SpacesDeviceWorkspaceFileWriteResult

    func subscribeWorkspaceDiffSignature(
        workspaceID: String, refName: String?, lastCommit: Bool, device: SpacesPairedDeviceRecord,
        onFrame: @escaping @Sendable (SpacesDeviceWorkspaceDiffSignatureFrame) -> Void, onDisconnect: @escaping @Sendable ((any Error)?) -> Void
    ) async throws -> any CodePaneDiffSignatureStreamHandle

    func subscribeWorkspaceFileSignature(
        workspaceID: String, relativePath: String, device: SpacesPairedDeviceRecord,
        onFrame: @escaping @Sendable (SpacesDeviceWorkspaceFileSignatureFrame) -> Void, onDisconnect: @escaping @Sendable ((any Error)?) -> Void
    ) async throws -> any CodePaneFileSignatureStreamHandle

    func subscribeWorkspaceFileListSignature(
        workspaceID: String, device: SpacesPairedDeviceRecord, onFrame: @escaping @Sendable (SpacesDeviceWorkspaceFileListSignatureFrame) -> Void,
        onDisconnect: @escaping @Sendable ((any Error)?) -> Void
    ) async throws -> any CodePaneFileListSignatureStreamHandle

    func workspaceReviewCommentList(workspaceID: String, device: SpacesPairedDeviceRecord) async throws -> [SpacesDeviceReviewComment]

    func workspaceReviewCommentUpsert(
        workspaceID: String, id: String?, filePath: String, side: SpacesDeviceReviewCommentSide, lineNumber: Int, lineText: String, body: String,
        device: SpacesPairedDeviceRecord
    ) async throws -> SpacesDeviceReviewComment

    func workspaceReviewCommentDelete(workspaceID: String, id: String, device: SpacesPairedDeviceRecord) async throws -> SpacesDeviceAPIResponse

    func workspaceReviewCommentsSend(
        workspaceID: String, sessionID: String, text: String, comments: [SpacesDeviceReviewCommentSendEntry], device: SpacesPairedDeviceRecord
    ) async throws -> SpacesDeviceAPIResponse

    func startWorkspaceCommand(workspaceID: String, command: String, device: SpacesPairedDeviceRecord) async throws -> SpacesDeviceAPIResponse

    /// Samples only the terminal session the Editor just created. It deliberately goes through the
    /// ordinary overview on both local and remote devices: that is the one payload which combines the
    /// session runtime's foreground facts with the hook-backed coding-agent rows.
    func workspaceCommandStartSnapshot(workspaceID: String, sessionID: String, device: SpacesPairedDeviceRecord) async throws
        -> CodePaneAgentStartSnapshot
}

/// Forwards to `SpacesDeviceClient`'s real, network-performing static methods, off the caller's task
/// via `Task.detached` — matching how these calls ran before this seam existed, so wrapping them in
/// `async` changes nothing about where the blocking I/O actually executes.
struct LiveCodePaneDeviceGateway: CodePaneDeviceGateway {
    func workspaceDiffManifestChunk(
        workspaceID: String, refName: String?, lastCommit: Bool, manifestID: String?, fileIndex: Int, device: SpacesPairedDeviceRecord
    ) async throws -> SpacesDeviceWorkspaceDiffManifestChunkResult {
        try await Task.detached(priority: .userInitiated) {
            try SpacesDeviceClient.workspaceDiffManifestChunk(
                workspaceID: workspaceID, refName: refName, lastCommit: lastCommit, manifestID: manifestID, fileIndex: fileIndex,
                context: DeviceRequestContext(device: device))
        }.value
    }

    func workspaceDiffFileChunk(
        workspaceID: String, refName: String?, lastCommit: Bool, manifestID: String, relativePath: String, byteOffset: Int, transferID: String?,
        device: SpacesPairedDeviceRecord
    ) async throws -> SpacesDeviceWorkspaceDiffFileChunkResult {
        try await Task.detached(priority: .userInitiated) {
            try SpacesDeviceClient.workspaceDiffFileChunk(
                workspaceID: workspaceID, refName: refName, lastCommit: lastCommit, manifestID: manifestID, relativePath: relativePath,
                byteOffset: byteOffset, transferID: transferID, context: DeviceRequestContext(device: device))
        }.value
    }

    func cancelWorkspaceDiffFileChunk(
        workspaceID: String, refName: String?, lastCommit: Bool, manifestID: String, relativePath: String, byteOffset: Int, transferID: String,
        device: SpacesPairedDeviceRecord
    ) async throws {
        try await Task.detached(priority: .utility) {
            try SpacesDeviceClient.cancelWorkspaceDiffFileChunk(
                workspaceID: workspaceID, refName: refName, lastCommit: lastCommit, manifestID: manifestID, relativePath: relativePath,
                byteOffset: byteOffset, transferID: transferID, context: DeviceRequestContext(device: device))
        }.value
    }

    func cancelWorkspaceDiffManifest(workspaceID: String, refName: String?, lastCommit: Bool, manifestID: String, device: SpacesPairedDeviceRecord)
        async throws
    {
        try await Task.detached(priority: .utility) {
            try SpacesDeviceClient.cancelWorkspaceDiffManifest(
                workspaceID: workspaceID, refName: refName, lastCommit: lastCommit, manifestID: manifestID, context: DeviceRequestContext(device: device))
        }.value
    }

    func workspaceFileRead(
        workspaceID: String, relativePath: String, comparisonBaseRevision: String?, oldPath: String?, requiresDirectPath: Bool,
        device: SpacesPairedDeviceRecord
    ) async throws
        -> SpacesDeviceWorkspaceFileReadResult
    {
        try await Task.detached(priority: .userInitiated) {
            try SpacesDeviceClient.workspaceFileRead(
                workspaceID: workspaceID, relativePath: relativePath, comparisonBaseRevision: comparisonBaseRevision, oldPath: oldPath,
                requiresDirectPath: requiresDirectPath, context: DeviceRequestContext(device: device))
        }.value
    }

    func workspaceRevisionFileRead(workspaceID: String, revision: String, relativePath: String, oldPath: String?, device: SpacesPairedDeviceRecord) async throws
        -> SpacesDeviceWorkspaceRevisionFileReadResult
    {
        try await Task.detached(priority: .userInitiated) {
            try SpacesDeviceClient.workspaceRevisionFileRead(
                workspaceID: workspaceID, revision: revision, relativePath: relativePath, oldPath: oldPath, context: DeviceRequestContext(device: device))
        }.value
    }

    func workspaceFileList(workspaceID: String, device: SpacesPairedDeviceRecord) async throws -> SpacesDeviceWorkspaceFileListResult {
        try await Task.detached(priority: .userInitiated) {
            try SpacesDeviceClient.workspaceFileList(workspaceID: workspaceID, context: DeviceRequestContext(device: device))
        }.value
    }

    func workspaceRefList(workspaceID: String, device: SpacesPairedDeviceRecord) async throws -> SpacesDeviceWorkspaceRefListResult {
        try await Task.detached(priority: .userInitiated) {
            try SpacesDeviceClient.workspaceRefList(workspaceID: workspaceID, context: DeviceRequestContext(device: device))
        }.value
    }

    func workspaceFileWrite(
        workspaceID: String, relativePath: String, base64Data: String, expectedSHA256: String?, requiresDirectPath: Bool,
        device: SpacesPairedDeviceRecord
    )
        async throws -> SpacesDeviceWorkspaceFileWriteResult
    {
        try await Task.detached(priority: .userInitiated) {
            try SpacesDeviceClient.workspaceFileWrite(
                workspaceID: workspaceID, relativePath: relativePath, base64Data: base64Data, expectedSHA256: expectedSHA256,
                requiresDirectPath: requiresDirectPath, context: DeviceRequestContext(device: device))
        }.value
    }

    func subscribeWorkspaceDiffSignature(
        workspaceID: String, refName: String?, lastCommit: Bool, device: SpacesPairedDeviceRecord,
        onFrame: @escaping @Sendable (SpacesDeviceWorkspaceDiffSignatureFrame) -> Void, onDisconnect: @escaping @Sendable ((any Error)?) -> Void
    ) async throws -> any CodePaneDiffSignatureStreamHandle {
        try await Task.detached(priority: .utility) {
            try SpacesDeviceClient.subscribeWorkspaceDiffSignature(
                workspaceID: workspaceID, refName: refName, lastCommit: lastCommit, context: DeviceRequestContext(device: device), onFrame: onFrame,
                onDisconnect: onDisconnect)
        }.value
    }

    func subscribeWorkspaceFileSignature(
        workspaceID: String, relativePath: String, device: SpacesPairedDeviceRecord,
        onFrame: @escaping @Sendable (SpacesDeviceWorkspaceFileSignatureFrame) -> Void, onDisconnect: @escaping @Sendable ((any Error)?) -> Void
    ) async throws -> any CodePaneFileSignatureStreamHandle {
        try await Task.detached(priority: .utility) {
            try SpacesDeviceClient.subscribeWorkspaceFileSignature(
                workspaceID: workspaceID, relativePath: relativePath, context: DeviceRequestContext(device: device), onFrame: onFrame,
                onDisconnect: onDisconnect)
        }.value
    }

    func subscribeWorkspaceFileListSignature(
        workspaceID: String, device: SpacesPairedDeviceRecord, onFrame: @escaping @Sendable (SpacesDeviceWorkspaceFileListSignatureFrame) -> Void,
        onDisconnect: @escaping @Sendable ((any Error)?) -> Void
    ) async throws -> any CodePaneFileListSignatureStreamHandle {
        try await Task.detached(priority: .utility) {
            try SpacesDeviceClient.subscribeWorkspaceFileListSignature(
                workspaceID: workspaceID, context: DeviceRequestContext(device: device), onFrame: onFrame, onDisconnect: onDisconnect)
        }.value
    }

    func workspaceReviewCommentList(workspaceID: String, device: SpacesPairedDeviceRecord) async throws -> [SpacesDeviceReviewComment] {
        try await Task.detached(priority: .userInitiated) {
            try SpacesDeviceClient.workspaceReviewCommentList(workspaceID: workspaceID, context: DeviceRequestContext(device: device))
        }.value
    }

    func workspaceReviewCommentUpsert(
        workspaceID: String, id: String?, filePath: String, side: SpacesDeviceReviewCommentSide, lineNumber: Int, lineText: String, body: String,
        device: SpacesPairedDeviceRecord
    ) async throws -> SpacesDeviceReviewComment {
        try await Task.detached(priority: .userInitiated) {
            try SpacesDeviceClient.workspaceReviewCommentUpsert(
                workspaceID: workspaceID, id: id, filePath: filePath, side: side, lineNumber: lineNumber, lineText: lineText, body: body,
                context: DeviceRequestContext(device: device))
        }.value
    }

    func workspaceReviewCommentDelete(workspaceID: String, id: String, device: SpacesPairedDeviceRecord) async throws -> SpacesDeviceAPIResponse {
        try await Task.detached(priority: .userInitiated) {
            try SpacesDeviceClient.workspaceReviewCommentDelete(workspaceID: workspaceID, id: id, context: DeviceRequestContext(device: device))
        }.value
    }

    func workspaceReviewCommentsSend(
        workspaceID: String, sessionID: String, text: String, comments: [SpacesDeviceReviewCommentSendEntry], device: SpacesPairedDeviceRecord
    ) async throws -> SpacesDeviceAPIResponse {
        try await Task.detached(priority: .userInitiated) {
            try SpacesDeviceClient.workspaceReviewCommentsSend(
                workspaceID: workspaceID, sessionID: sessionID, text: text, comments: comments, context: DeviceRequestContext(device: device))
        }.value
    }

    func startWorkspaceCommand(workspaceID: String, command: String, device: SpacesPairedDeviceRecord) async throws -> SpacesDeviceAPIResponse {
        try await Task.detached(priority: .userInitiated) {
            try SpacesDeviceClient.startWorkspaceCommandSession(workspaceID: workspaceID, command: command, context: DeviceRequestContext(device: device))
        }.value
    }

    func workspaceCommandStartSnapshot(workspaceID: String, sessionID: String, device: SpacesPairedDeviceRecord) async throws
        -> CodePaneAgentStartSnapshot
    {
        let task = Task.detached(priority: .utility) { () throws -> CodePaneAgentStartSnapshot in
            let overview = try SpacesDeviceClient.overview(context: DeviceRequestContext(device: device)).overview
            let terminal = overview.sessions.first(where: { $0.id == sessionID })
            let workspace = overview.workspaces.first(where: { $0.id == workspaceID })
            let agentRow = workspace?.codingAgentRows.first(where: { row in
                row.sessionID == sessionID && row.runState == .running && row.activityState != .exited
            })
            let agent = agentRow.map { CodePaneRunningAgent(id: $0.id, label: $0.name, sessionID: sessionID) }
            let detectedKind = terminal?.foregroundDetectedAgentKind.flatMap { TerminalDetectedAgentKind(rawValue: $0) }
            let state = terminal?.state
            let bracketedPasteActive = terminal?.bracketedPasteActive ?? false
            return CodePaneAgentStartSnapshot(
                sessionFound: terminal != nil, belongsToWorkspace: terminal?.workspaceID == workspaceID, state: state, detectedKind: detectedKind,
                bracketedPasteActive: bracketedPasteActive, agent: agent)
        }
        return try await task.value
    }
}
