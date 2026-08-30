import Foundation
import WebKit
import spacesclientcore
import spacesdevicecore
import spacesterminalcore

/// Pure decode/mapping/JS-generation logic for the code pane's `spacesBridge` message channel
/// (see `CodePaneWeb/README.md` for the wire protocol this implements). Kept free of `WKWebView`
/// so it is unit-testable without a live web view — `CodePaneContentController` is the only
/// caller, and owns the actual `WKScriptMessageHandler` and RPC-to-client-call wiring.
enum CodePaneBridge {
    /// The five error codes the web bridge's `SpacesBridgeError` recognizes (`CodePaneWeb/src/bridge/types.ts`'s
    /// `SpacesErrorCode`). Any other string on the JS side normalizes to `internalError` there, so
    /// the host never needs to send anything else.
    enum ErrorCode: String {
        case notFound
        case invalidArgument
        case conflict
        case internalError
        case unavailable
    }

    /// A typed rejection for one bridge call. Distinct from `SpacesDeviceClientError`: this is the
    /// shape that actually crosses the wire back to JS, after `mapClientError` has collapsed the
    /// client layer's own error surface down to the bridge's five codes.
    struct BridgeError: Error, Equatable {
        let code: ErrorCode
        let message: String
    }

    /// A parsed `{id, method, params}` request awaiting a reply. `params` stays a loosely-typed
    /// `[String: Any]` — `scope`/`options` arrive as nested dictionaries — and each per-method
    /// handler below picks the fields it needs back out of it. `ready` (no `id`, no reply
    /// expected) is recognized separately by `isReady(body:)` rather than through this type.
    struct Request {
        let id: String
        let method: String
        let params: [String: Any]
    }

    /// Decodes one `WKScriptMessage.body`. Returns `nil` when the body isn't a well-formed request
    /// at all (missing `id`/`method`) — there is nothing to correlate a reply with, so the caller
    /// drops it silently rather than guessing an id to reject.
    static func decodeRequest(body: Any) -> Request? {
        guard let dict = body as? [String: Any], let id = dict["id"] as? String, let method = dict["method"] as? String else { return nil }
        return Request(id: id, method: method, params: dict["params"] as? [String: Any] ?? [:])
    }

    /// Whether a message body is the fire-and-forget `{method:"ready"}` lifecycle notification
    /// (no `id`, so it is never a `Request`).
    static func isReady(body: Any) -> Bool {
        guard let dict = body as? [String: Any] else { return false }
        return dict["id"] == nil && dict["method"] as? String == "ready"
    }

    /// One editor's open-file snapshot inside the complete workspace state and `InitPayload`.
    /// Mirrors `CodePaneWeb/src/bridge/types.ts`'s
    /// `CodePaneEditorState`: `baseContent` is the file's content as of `baseSHA256` (the merge
    /// base for external-change reconciliation), and `conflict` is whether the web app's
    /// own merge attempt left unresolved markers in `content`.
    struct EditorState: Codable, Equatable, Sendable {
        let path: String
        let baseSHA256: String
        let baseContent: String
        let content: String
        let dirty: Bool
        let conflict: Bool

        init(path: String, baseSHA256: String, baseContent: String, content: String, dirty: Bool, conflict: Bool = false) {
            self.path = path
            self.baseSHA256 = baseSHA256
            self.baseContent = baseContent
            self.content = content
            self.dirty = dirty
            self.conflict = conflict
        }
    }

    /// Diff mode's inline editor snapshot. Unlike the regular Editor buffer, an inline conflict
    /// needs the exact disk hash that the read-only comparison displays: Keep mine must CAS against
    /// that snapshot after hibernation, while `nil` means the file was deleted and may be recreated.
    struct DiffEditorState: Codable, Equatable, Sendable {
        let path: String
        let baseSHA256: String
        let baseContent: String
        /// The comparison's old side is independent of the writable disk baseline. It remains
        /// stable while an inline edit is restored or reconciled so the diff keeps its original
        /// highlighting rather than comparing the file against its current contents.
        let comparisonOldContent: String?
        let content: String
        let dirty: Bool
        let conflict: Bool
        let conflictBaseSHA256: String?

        init(
            path: String, baseSHA256: String, baseContent: String, comparisonOldContent: String?, content: String, dirty: Bool, conflict: Bool = false,
            conflictBaseSHA256: String? = nil
        ) {
            self.path = path
            self.baseSHA256 = baseSHA256
            self.baseContent = baseContent
            self.comparisonOldContent = comparisonOldContent
            self.content = content
            self.dirty = dirty
            self.conflict = conflict
            self.conflictBaseSHA256 = conflictBaseSHA256
        }

        private enum CodingKeys: String, CodingKey {
            case path, baseSHA256, baseContent, comparisonOldContent, content, dirty, conflict, conflictBaseSHA256
        }

        /// This bridge accepts one persisted snapshot shape: these fields are required-nullable.
        /// Decoding with `decode`, rather than `decodeIfPresent`, rejects a missing comparison
        /// side or deletion target instead of inventing context that could make an unsafe save.
        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            path = try container.decode(String.self, forKey: .path)
            baseSHA256 = try container.decode(String.self, forKey: .baseSHA256)
            baseContent = try container.decode(String.self, forKey: .baseContent)
            comparisonOldContent = try container.decode(String?.self, forKey: .comparisonOldContent)
            content = try container.decode(String.self, forKey: .content)
            dirty = try container.decode(Bool.self, forKey: .dirty)
            conflict = try container.decode(Bool.self, forKey: .conflict)
            conflictBaseSHA256 = try container.decode(String?.self, forKey: .conflictBaseSHA256)
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(path, forKey: .path)
            try container.encode(baseSHA256, forKey: .baseSHA256)
            try container.encode(baseContent, forKey: .baseContent)
            if let comparisonOldContent {
                try container.encode(comparisonOldContent, forKey: .comparisonOldContent)
            } else {
                try container.encodeNil(forKey: .comparisonOldContent)
            }
            try container.encode(content, forKey: .content)
            try container.encode(dirty, forKey: .dirty)
            try container.encode(conflict, forKey: .conflict)
            if let conflictBaseSHA256 {
                try container.encode(conflictBaseSHA256, forKey: .conflictBaseSHA256)
            } else {
                try container.encodeNil(forKey: .conflictBaseSHA256)
            }
        }
    }

    /// The complete workspace-local Editor recovery snapshot. It is sent as one value at page
    /// startup and whenever the web surface changes its location or an unsaved buffer. Keeping the
    /// state together makes a retarget/restart atomic from the user's point of view: a restored
    /// mode, scope, viewport, and dirty buffer always describe the same moment. Patches and DOM
    /// state are deliberately absent; those are freshly streamed after restore.
    struct WorkspaceState: Codable, Equatable, Sendable {
        struct Scope: Codable, Equatable, Sendable {
            let kind: String
            let refName: String?

            static let uncommitted = Scope(kind: "uncommitted", refName: nil)
        }

        let mode: String
        let scope: Scope
        let diffLayout: String
        let diffSelectedPath: String?
        /// `nil` means the user has not changed the diff tree, so the page should use its own
        /// initial expansion. An empty array is an explicit choice to collapse every group.
        let diffTreeExpandedPaths: [String]?
        let diffTreeSelectedPath: String?
        let fileTreeExpandedPaths: [String]
        let fileTreeSelectedPath: String?
        let editorSidebarMode: String
        let editorRecentPaths: [String]
        let diffScrollLine: Int?
        let diffScrollSide: String?
        let diffFocusedPath: String?
        let diffFocusedLine: Int?
        let diffFocusedSide: String?
        let editorScrollLine: Int?
        let editorFocusedLine: Int?
        let editorState: EditorState?
        let diffEditorState: DiffEditorState?
        let pendingReviewComments: [ReviewCommentEntryPayload]?
        let selectedAgentSessionId: String?
        let pendingAgentLaunch: PendingAgentLaunch?

        init(
            mode: String, scope: Scope, diffLayout: String, diffSelectedPath: String?, diffTreeExpandedPaths: [String]?,
            diffTreeSelectedPath: String?, fileTreeExpandedPaths: [String], fileTreeSelectedPath: String?, editorSidebarMode: String,
            editorRecentPaths: [String], diffScrollLine: Int?, diffScrollSide: String?, diffFocusedPath: String?, diffFocusedLine: Int?,
            diffFocusedSide: String?, editorScrollLine: Int?, editorFocusedLine: Int?, editorState: EditorState?, diffEditorState: DiffEditorState?,
            pendingReviewComments: [ReviewCommentEntryPayload]?, selectedAgentSessionId: String? = nil, pendingAgentLaunch: PendingAgentLaunch? = nil
        ) {
            self.mode = mode
            self.scope = scope
            self.diffLayout = diffLayout
            self.diffSelectedPath = diffSelectedPath
            self.diffTreeExpandedPaths = diffTreeExpandedPaths
            self.diffTreeSelectedPath = diffTreeSelectedPath
            self.fileTreeExpandedPaths = fileTreeExpandedPaths
            self.fileTreeSelectedPath = fileTreeSelectedPath
            self.editorSidebarMode = editorSidebarMode
            self.editorRecentPaths = editorRecentPaths
            self.diffScrollLine = diffScrollLine
            self.diffScrollSide = diffScrollSide
            self.diffFocusedPath = diffFocusedPath
            self.diffFocusedLine = diffFocusedLine
            self.diffFocusedSide = diffFocusedSide
            self.editorScrollLine = editorScrollLine
            self.editorFocusedLine = editorFocusedLine
            self.editorState = editorState
            self.diffEditorState = diffEditorState
            self.pendingReviewComments = pendingReviewComments
            self.selectedAgentSessionId = selectedAgentSessionId
            self.pendingAgentLaunch = pendingAgentLaunch
        }
    }

    /// The durable portion of a Start Agent interaction. Its command is local-only recovery data,
    /// never a daemon configuration; `sessionId` remains present after failure so the user can still
    /// inspect the background terminal that ran it.
    struct PendingAgentLaunch: Codable, Equatable, Sendable {
        let sessionId: String?
        let command: String
        let status: String
        let message: String?
        /// Absolute Unix milliseconds. A relaunch resumes the original readiness budget instead of
        /// giving one command a fresh timeout each time its Editor is rebuilt.
        let deadlineEpochMilliseconds: Int64?
    }

    /// Reject malformed complete snapshots as a whole. There is no field-by-field recovery path:
    /// persisting a partial state would restore a UI combination the page never produced.
    static func isValidWorkspaceState(_ state: WorkspaceState) -> Bool {
        guard ["diff", "editor"].contains(state.mode), ["unified", "split"].contains(state.diffLayout),
            ["files", "changes"].contains(state.editorSidebarMode), state.diffScrollLine.map({ $0 >= 0 }) ?? true,
            state.diffScrollSide.map({ ["old", "new"].contains($0) }) ?? true, state.diffFocusedLine.map({ $0 >= 0 }) ?? true,
            state.diffFocusedSide.map({ ["old", "new"].contains($0) }) ?? true, (state.diffSelectedPath == nil) == (state.diffScrollLine == nil),
            (state.diffScrollLine == nil) == (state.diffScrollSide == nil), (state.diffFocusedPath == nil) == (state.diffFocusedLine == nil),
            (state.diffFocusedLine == nil) == (state.diffFocusedSide == nil), state.editorScrollLine.map({ $0 >= 0 }) ?? true,
            state.editorFocusedLine.map({ $0 >= 0 }) ?? true
        else { return false }
        switch state.scope.kind {
        case "uncommitted", "lastCommit": guard state.scope.refName == nil else { return false }
        case "ref": guard let refName = state.scope.refName, !refName.isEmpty else { return false }
        default: return false
        }
        if let pending = state.pendingAgentLaunch {
            guard ["starting", "failed"].contains(pending.status), !pending.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return false
            }
            switch pending.status {
            case "starting":
                guard let sessionID = pending.sessionId, !sessionID.isEmpty, let deadline = pending.deadlineEpochMilliseconds, deadline >= 0 else {
                    return false
                }
            case "failed": guard pending.deadlineEpochMilliseconds == nil else { return false }
            default: return false
            }
        }
        if let diffEditorState = state.diffEditorState {
            // A non-nil target means the conflict comparison read a particular disk version, and
            // Keep mine must CAS against that exact version. A nil target is reserved for a
            // deleted file (or an ordinary, non-conflicting inline buffer); it must never be
            // invented for a malformed changed-file conflict.
            guard diffEditorState.conflictBaseSHA256?.isEmpty != true, diffEditorState.conflict || diffEditorState.conflictBaseSHA256 == nil else {
                return false
            }
        }
        return true
    }

    /// The single collector superseding the independent editor/sidebar/comment collectors. A page
    /// that has not installed the collector must never erase an older recovery document.
    static let collectWorkspaceStateScript =
        "typeof window.__spacesCollectWorkspaceState === 'function' ? (window.__spacesCollectWorkspaceState() ?? '__none__') : '__uninstalled__'"

    enum CollectedWorkspaceState: Equatable {
        case notReported
        case none
        case state(WorkspaceState)
    }

    static func decodeCollectedWorkspaceState(_ result: Any?) -> CollectedWorkspaceState {
        guard let jsonString = result as? String else { return .notReported }
        if jsonString == "__uninstalled__" { return .notReported }
        if jsonString == "__none__" { return .none }
        guard let data = jsonString.data(using: .utf8), let state = try? JSONDecoder().decode(WorkspaceState.self, from: data),
            isValidWorkspaceState(state)
        else { return .notReported }
        return .state(state)
    }

    /// Decodes the complete live workspace-state notification. Its `params` is intentionally the
    /// same object as `WorkspaceState`, so live persistence and teardown persistence cannot drift.
    static func decodeWorkspaceStateChanged(body: Any) -> WorkspaceState? {
        guard let dict = body as? [String: Any], dict["id"] == nil, dict["method"] as? String == "workspaceStateChanged", let params = dict["params"],
            JSONSerialization.isValidJSONObject(params), let data = try? JSONSerialization.data(withJSONObject: params)
        else { return nil }
        guard let state = try? JSONDecoder().decode(WorkspaceState.self, from: data), isValidWorkspaceState(state) else { return nil }
        return state
    }

    /// One locally pending review-comment entry, carried as part of the complete workspace recovery
    /// document rather than through a separate notification or collector.
    struct ReviewCommentEntryPayload: Codable, Equatable, Sendable {
        let id: String
        let provisional: Bool
        let filePath: String
        let side: SpacesDeviceReviewCommentSide
        let lineNumber: Int
        let lineText: String
        let body: String
    }

    /// One browser-complete milestone from the bundled page. Values are intentionally bounded at
    /// this trust boundary: this channel is diagnostic-only and must never become an unbounded log
    /// or formatting surface if a stale/corrupt page sends malformed data.
    struct RenderMetric: Equatable {
        enum Kind: String { case diff, editor }
        enum Trigger: String {
            case initial, scope, workspaceChange, fileOpen
            case manifest, filePatch, complete, workspaceStateRestored, diffEdit, diffEditSave, diffEditCancel
        }

        let kind: Kind
        let trigger: Trigger
        let elapsedMS: Int
        let fetchElapsedMS: Int?
        let bridgeElapsedMS: Int?
        let decodeElapsedMS: Int?
        let updateElapsedMS: Int?
        let paintElapsedMS: Int?
        let fileCount: Int
        let contentBytes: Int
        let path: String?
        let fileIndex: Int?
        let selectedPriority: Bool
        let chunkCount: Int?
        let mode: String?
        let scope: String?
        let layout: String?
        let scrollTop: Int?
        let focusedLine: Int?
        let dirty: Bool?
    }

    static func decodeRenderMetric(body: Any) -> RenderMetric? {
        guard let dict = body as? [String: Any], dict["id"] == nil, dict["method"] as? String == "renderMetric",
            let params = dict["params"] as? [String: Any], let kindRaw = params["kind"] as? String, let kind = RenderMetric.Kind(rawValue: kindRaw),
            let triggerRaw = params["trigger"] as? String, let trigger = RenderMetric.Trigger(rawValue: triggerRaw),
            let elapsedMS = params["elapsedMs"] as? Int, (0...600_000).contains(elapsedMS), let fileCount = params["fileCount"] as? Int,
            (0...1_000_000).contains(fileCount), let contentBytes = params["contentBytes"] as? Int,
            (0...(4 * 1024 * 1024 * 1024)).contains(contentBytes)
        else { return nil }
        let fetchElapsedMS = params["fetchElapsedMs"] as? Int
        let bridgeElapsedMS = params["bridgeElapsedMs"] as? Int
        let decodeElapsedMS = params["decodeElapsedMs"] as? Int
        let updateElapsedMS = params["updateElapsedMs"] as? Int
        let paintElapsedMS = params["paintElapsedMs"] as? Int
        let path = params["path"] as? String
        let fileIndex = params["fileIndex"] as? Int
        let selectedPriority = params["selectedPriority"] as? Bool ?? false
        let chunkCount = params["chunkCount"] as? Int
        let mode = params["mode"] as? String
        let scope = params["scope"] as? String
        let layout = params["layout"] as? String
        let scrollTop = params["scrollTop"] as? Int
        let focusedLine = params["focusedLine"] as? Int
        let dirty = params["dirty"] as? Bool
        guard fetchElapsedMS.map({ (0...elapsedMS).contains($0) }) ?? true, bridgeElapsedMS.map({ (0...elapsedMS).contains($0) }) ?? true,
            decodeElapsedMS.map({ (0...elapsedMS).contains($0) }) ?? true, updateElapsedMS.map({ (0...elapsedMS).contains($0) }) ?? true,
            paintElapsedMS.map({ (0...elapsedMS).contains($0) }) ?? true, path.map({ !$0.isEmpty && $0.utf8.count <= 4_096 }) ?? true,
            fileIndex.map({ (0...1_000_000).contains($0) }) ?? true, chunkCount.map({ (0...1_000_000).contains($0) }) ?? true,
            mode.map({ $0 == "diff" || $0 == "editor" }) ?? true, scope.map({ !$0.isEmpty && $0.utf8.count <= 1_024 }) ?? true,
            layout.map({ $0 == "unified" || $0 == "split" }) ?? true, scrollTop.map({ (0...10_000_000).contains($0) }) ?? true,
            focusedLine.map({ (1...10_000_000).contains($0) }) ?? true
        else { return nil }
        return RenderMetric(
            kind: kind, trigger: trigger, elapsedMS: elapsedMS, fetchElapsedMS: fetchElapsedMS, bridgeElapsedMS: bridgeElapsedMS,
            decodeElapsedMS: decodeElapsedMS, updateElapsedMS: updateElapsedMS, paintElapsedMS: paintElapsedMS, fileCount: fileCount,
            contentBytes: contentBytes, path: path, fileIndex: fileIndex, selectedPriority: selectedPriority, chunkCount: chunkCount, mode: mode,
            scope: scope, layout: layout, scrollTop: scrollTop, focusedLine: focusedLine, dirty: dirty)
    }

    // MARK: - Diff scope

    /// The three `DiffScope` kinds `CodePaneWeb/src/bridge/types.ts` defines.
    enum DiffScope: Equatable {
        case uncommitted
        case lastCommit
        case ref(String)
    }

    /// Decodes a `DiffScope` from its wire shape: `{kind:"uncommitted"}`, `{kind:"lastCommit"}`, or
    /// `{kind:"ref", refName}`.
    static func decodeDiffScope(_ value: Any?) -> Result<DiffScope, BridgeError> {
        guard let dict = value as? [String: Any], let kind = dict["kind"] as? String else {
            return .failure(BridgeError(code: .invalidArgument, message: "Missing or invalid diff scope."))
        }
        switch kind {
        case "uncommitted": return .success(.uncommitted)
        case "lastCommit": return .success(.lastCommit)
        case "ref":
            guard let refName = dict["refName"] as? String, !refName.isEmpty else {
                return .failure(BridgeError(code: .invalidArgument, message: "A \"ref\" scope requires a non-empty refName."))
            }
            return .success(.ref(refName))
        default: return .failure(BridgeError(code: .invalidArgument, message: "Unknown diff scope kind \"\(kind)\"."))
        }
    }

    /// Resolves a `DiffScope` to the `(refName, lastCommit)` pair `workspaceDiffManifestChunk`/
    /// `subscribeWorkspaceDiffSignature` take: `(nil, false)` for uncommitted-vs-HEAD, `(nil, true)` for
    /// the committed-only last-commit scope, or `(refName, false)` for the literal ref/SHA text of `.ref`.
    static func refName(for scope: DiffScope) -> (refName: String?, lastCommit: Bool) {
        switch scope {
        case .uncommitted: return (nil, false)
        case .lastCommit: return (nil, true)
        case .ref(let refName): return (refName, false)
        }
    }

    // MARK: - RPC-to-client-call mapping

    // The Editor is an unshipped feature, so these manifest/file-chunk methods are the singular
    // diff wire protocol. There is intentionally no legacy `workspaceDiff` path or mixed-version
    // capability negotiation to preserve here.

    /// What a decoded `Request` asks the host to do, in terms independent of `SpacesDeviceClient` —
    /// this is the pure "which call, with which arguments" mapping, so it's testable without a
    /// live device or network. `CodePaneContentController` switches over this to make the actual
    /// client call.
    enum Plan: Equatable {
        case workspaceDiffManifestChunk(scope: DiffScope, manifestID: String?, fileIndex: Int)
        case workspaceDiffFileChunk(scope: DiffScope, manifestID: String, relativePath: String, byteOffset: Int, transferID: String?)
        case workspaceDiffFileChunkCancel(scope: DiffScope, manifestID: String, relativePath: String, byteOffset: Int, transferID: String)
        case workspaceDiffManifestRelease(scope: DiffScope, manifestID: String)
        /// `ownsFileSignature` is true only for the standalone Editor's read; inline diff reads must
        /// not retarget the one native file-signature watcher away from that Editor file.
        case workspaceFileRead(
            path: String, ownsFileSignature: Bool, comparisonBaseRevision: String?, oldPath: String?, requiresDirectPath: Bool)
        /// Reads a file from the immutable target revision attached to last-commit diff metadata. It must
        /// not affect the standalone Editor's live working-tree file-signature subscription.
        case workspaceRevisionFileRead(path: String, revision: String, oldPath: String?)
        /// `baseSHA256` is `nil` for the "create" convention (see `WorkspaceFileWriteOptions.baseSHA256`
        /// in `CodePaneWeb/src/bridge/types.ts`): the write must fail as a conflict unless the target
        /// path does not exist yet. This is how "Keep mine" recreates a file the daemon reports as
        /// missing (see `FileWritePayload`'s `fileMissing` case) instead of being unable to ever write
        /// past that state.
        case workspaceFileWrite(path: String, content: String, baseSHA256: String?, requiresDirectPath: Bool)
        /// Lists every path in the workspace's checkout, for the Editor pane's file tree and
        /// quick-open. No params.
        case workspaceFileList
        /// Lists the branches and recent commits the Compare dialog's ref search offers. No params.
        case workspaceRefList
        case reviewCommentList
        /// `commentID` is `nil` for a new draft — the daemon mints its id — or names an existing
        /// draft this workspace owns when the web app is editing one.
        case reviewCommentUpsert(
            commentID: String?, filePath: String, side: SpacesDeviceReviewCommentSide, lineNumber: Int, lineText: String, body: String)
        case reviewCommentDelete(commentID: String)
        /// `comments` pairs each id with the `revision` the web app's local mirror last saw for it —
        /// the daemon's stale-version check (see `SpacesDeviceWorkspaceReviewCommentsSendRequest`).
        case reviewCommentsSend(sessionID: String, text: String, comments: [SpacesDeviceReviewCommentSendEntry])
        case startWorkspaceCommand(command: String)
        case resumeWorkspaceCommandTracking(sessionID: String)
    }

    /// Maps a decoded request to a `Plan`, or a `BridgeError` if its method is unrecognized or its
    /// params are missing/malformed. An unknown method is rejected with `invalidArgument`.
    static func plan(for request: Request) -> Result<Plan, BridgeError> {
        switch request.method {
        case "workspaceDiffManifestChunk":
            let manifestID = request.params["manifestID"] as? String
            guard let fileIndex = request.params["fileIndex"] as? Int, fileIndex >= 0, manifestID?.isEmpty != true else {
                return .failure(
                    BridgeError(
                        code: .invalidArgument,
                        message: "workspaceDiffManifestChunk requires a non-negative fileIndex and a non-empty manifestID when supplied."))
            }
            return decodeDiffScope(request.params["scope"]).map {
                .workspaceDiffManifestChunk(scope: $0, manifestID: manifestID, fileIndex: fileIndex)
            }
        case "workspaceDiffFileChunk":
            guard let manifestID = request.params["manifestID"] as? String, !manifestID.isEmpty,
                let relativePath = request.params["relativePath"] as? String, !relativePath.isEmpty,
                let byteOffset = request.params["byteOffset"] as? Int, byteOffset >= 0
            else {
                return .failure(
                    BridgeError(
                        code: .invalidArgument, message: "workspaceDiffFileChunk requires manifestID, relativePath, and a non-negative byteOffset."))
            }
            return decodeDiffScope(request.params["scope"]).map {
                .workspaceDiffFileChunk(
                    scope: $0, manifestID: manifestID, relativePath: relativePath, byteOffset: byteOffset,
                    transferID: request.params["transferID"] as? String)
            }
        case "workspaceDiffFileChunkCancel":
            guard let manifestID = request.params["manifestID"] as? String, !manifestID.isEmpty,
                let relativePath = request.params["relativePath"] as? String, !relativePath.isEmpty,
                let byteOffset = request.params["byteOffset"] as? Int, byteOffset >= 0, let transferID = request.params["transferID"] as? String,
                !transferID.isEmpty
            else {
                return .failure(
                    BridgeError(
                        code: .invalidArgument,
                        message: "workspaceDiffFileChunkCancel requires manifestID, relativePath, a non-negative byteOffset, and transferID."))
            }
            return decodeDiffScope(request.params["scope"]).map {
                .workspaceDiffFileChunkCancel(
                    scope: $0, manifestID: manifestID, relativePath: relativePath, byteOffset: byteOffset, transferID: transferID)
            }
        case "workspaceDiffManifestRelease":
            guard let manifestID = request.params["manifestID"] as? String, !manifestID.isEmpty else {
                return .failure(BridgeError(code: .invalidArgument, message: "workspaceDiffManifestRelease requires manifestID."))
            }
            return decodeDiffScope(request.params["scope"]).map { .workspaceDiffManifestRelease(scope: $0, manifestID: manifestID) }
        case "workspaceFileRead":
            // Every caller identifies whether this read belongs to the standalone Editor or to the
            // transient inline diff editor. Keeping that intent on the wire prevents the latter's
            // workspace-file lookup from stealing the Editor's sole native signature stream.
            guard let path = request.params["path"] as? String, let purpose = request.params["purpose"] as? String else {
                return .failure(BridgeError(code: .invalidArgument, message: "workspaceFileRead requires a path and purpose."))
            }
            switch purpose {
            case "editor":
                return .success(
                    .workspaceFileRead(path: path, ownsFileSignature: true, comparisonBaseRevision: nil, oldPath: nil, requiresDirectPath: false))
            case "inlineDiff":
                let comparisonBaseRevision = request.params["comparisonBaseRevision"] as? String
                let oldPath = request.params["oldPath"] as? String
                return .success(.workspaceFileRead(
                    path: path, ownsFileSignature: false, comparisonBaseRevision: comparisonBaseRevision, oldPath: oldPath, requiresDirectPath: true))
            default: return .failure(BridgeError(code: .invalidArgument, message: "workspaceFileRead purpose must be editor or inlineDiff."))
            }
        case "workspaceRevisionFileRead":
            guard let path = request.params["path"] as? String, let revision = request.params["revision"] as? String else {
                return .failure(BridgeError(code: .invalidArgument, message: "workspaceRevisionFileRead requires a path and revision."))
            }
            return .success(.workspaceRevisionFileRead(path: path, revision: revision, oldPath: request.params["oldPath"] as? String))
        case "workspaceFileWrite":
            // `options.baseSHA256` is optional: absent or JSON `null` (the wire's "create" convention
            // — see realBridge.ts's `workspaceFileWrite`) both fall out of `as? String` as `nil` here,
            // which is exactly the `Plan` case's own "create" meaning — no separate null-check needed.
            guard let path = request.params["path"] as? String, let content = request.params["content"] as? String,
                let options = request.params["options"] as? [String: Any]
            else { return .failure(BridgeError(code: .invalidArgument, message: "workspaceFileWrite requires a path, content, and options.")) }
            let baseSHA256 = options["baseSHA256"] as? String
            guard let purpose = options["purpose"] as? String else {
                return .failure(BridgeError(code: .invalidArgument, message: "workspaceFileWrite options require a purpose."))
            }
            let requiresDirectPath: Bool
            switch purpose {
            case "editor": requiresDirectPath = false
            case "inlineDiff": requiresDirectPath = true
            default:
                return .failure(BridgeError(code: .invalidArgument, message: "workspaceFileWrite purpose must be editor or inlineDiff."))
            }
            return .success(.workspaceFileWrite(path: path, content: content, baseSHA256: baseSHA256, requiresDirectPath: requiresDirectPath))
        case "workspaceFileList": return .success(.workspaceFileList)
        case "workspaceRefList": return .success(.workspaceRefList)
        case "reviewCommentList": return .success(.reviewCommentList)
        case "reviewCommentUpsert":
            guard let filePath = request.params["filePath"] as? String, let sideRaw = request.params["side"] as? String,
                let side = SpacesDeviceReviewCommentSide(rawValue: sideRaw), let lineNumber = request.params["lineNumber"] as? Int,
                let lineText = request.params["lineText"] as? String, let body = request.params["body"] as? String
            else {
                return .failure(
                    BridgeError(code: .invalidArgument, message: "reviewCommentUpsert requires filePath, side, lineNumber, lineText, and body."))
            }
            let commentID = request.params["id"] as? String
            return .success(
                .reviewCommentUpsert(commentID: commentID, filePath: filePath, side: side, lineNumber: lineNumber, lineText: lineText, body: body))
        case "reviewCommentDelete":
            guard let commentID = request.params["id"] as? String else {
                return .failure(BridgeError(code: .invalidArgument, message: "reviewCommentDelete requires an id."))
            }
            return .success(.reviewCommentDelete(commentID: commentID))
        case "reviewCommentsSend":
            guard let sessionID = request.params["sessionId"] as? String, let text = request.params["text"] as? String,
                let rawComments = request.params["comments"] as? [[String: Any]], !rawComments.isEmpty
            else {
                return .failure(
                    BridgeError(code: .invalidArgument, message: "reviewCommentsSend requires sessionId, text, and a non-empty comments."))
            }
            var comments: [SpacesDeviceReviewCommentSendEntry] = []
            for raw in rawComments {
                guard let id = raw["id"] as? String, let revision = raw["revision"] as? Int else {
                    return .failure(BridgeError(code: .invalidArgument, message: "Each reviewCommentsSend entry requires an id and revision."))
                }
                comments.append(SpacesDeviceReviewCommentSendEntry(id: id, revision: revision))
            }
            return .success(.reviewCommentsSend(sessionID: sessionID, text: text, comments: comments))
        case "startWorkspaceCommand":
            guard let command = request.params["command"] as? String, !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .failure(BridgeError(code: .invalidArgument, message: "startWorkspaceCommand requires a command."))
            }
            return .success(.startWorkspaceCommand(command: command))
        case "resumeWorkspaceCommandTracking":
            guard let sessionID = request.params["sessionId"] as? String, !sessionID.isEmpty else {
                return .failure(BridgeError(code: .invalidArgument, message: "resumeWorkspaceCommandTracking requires a sessionId."))
            }
            return .success(.resumeWorkspaceCommandTracking(sessionID: sessionID))
        default: return .failure(BridgeError(code: .invalidArgument, message: "Unknown method \"\(request.method)\"."))
        }
    }

    // MARK: - Client error mapping

    /// Maps any error thrown by a `SpacesDeviceClient` call to the bridge's five-code error shape.
    /// A CAS write conflict is never routed through here — it's a normal typed result
    /// (`{conflict:true, currentSHA256}`), not a thrown error; see `fileWritePayload`.
    static func mapClientError(_ error: Error) -> BridgeError {
        guard let clientError = error as? SpacesDeviceClientError else { return BridgeError(code: .unavailable, message: error.localizedDescription) }
        guard case .requestRejected(let message, let code) = clientError else {
            // missingLocalBootstrap / missingOverview / missingCertificateFingerprint: all describe
            // the device or its credentials being unreachable right now, not a bad request.
            return BridgeError(code: .unavailable, message: clientError.localizedDescription)
        }
        return BridgeError(code: bridgeErrorCode(for: code), message: message)
    }

    /// `SpacesDeviceErrorCode` has 14 cases; the bridge has 5. A code the daemon refused the
    /// request outright with (bad input, or something about the target it rejected) maps to
    /// `invalidArgument`; `.conflict` (a stale version echo, e.g. `reviewCommentsSend`'s `revision`
    /// check) maps to the bridge's own `.conflict`; anything about the device/session/service not
    /// presently being reachable or ready maps to `unavailable`; `nil` (no code attached) or
    /// `internalError` map to `internalError`.
    private static func bridgeErrorCode(for code: SpacesDeviceErrorCode?) -> ErrorCode {
        guard let code else { return .internalError }
        switch code {
        case .notFound: return .notFound
        case .invalidArgument, .ownershipRejected, .payloadTooLarge, .unsupportedFormat: return .invalidArgument
        case .conflict: return .conflict
        case .internalError: return .internalError
        case .unauthorized, .sessionNotRunning, .sessionNotAvailable, .serviceNotRunning, .busy, .capabilityMissing, .misroutedRequest, .shuttingDown,
            .handingOff:
            return .unavailable
        }
    }

    // MARK: - Result payload shaping

    /// `workspaceFileRead`'s wire shape (`content`, `sha256`, `size`) doesn't match
    /// `SpacesDeviceWorkspaceFileReadResult`'s (`base64Data`, `isBinaryGuess`), so this decodes the
    /// base64 to UTF-8 text. A file the daemon guesses is binary, or whose bytes aren't valid
    /// UTF-8, is rejected: Editor mode is text-only and the wire contract has no binary variant.
    struct FileReadPayload: Encodable, Equatable {
        let content: String
        let sha256: String
        let size: Int
        let comparisonOldContent: String?

        init(content: String, sha256: String, size: Int, comparisonOldContent: String? = nil) {
            self.content = content
            self.sha256 = sha256
            self.size = size
            self.comparisonOldContent = comparisonOldContent
        }

        private enum CodingKeys: String, CodingKey {
            case content, sha256, size, comparisonOldContent
        }

        // `comparisonOldContent` is required-nullable on the web bridge. In particular, an added
        // file has no old side; omitting the key would be indistinguishable from a malformed response.
        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(content, forKey: .content)
            try container.encode(sha256, forKey: .sha256)
            try container.encode(size, forKey: .size)
            if let comparisonOldContent {
                try container.encode(comparisonOldContent, forKey: .comparisonOldContent)
            } else {
                try container.encodeNil(forKey: .comparisonOldContent)
            }
        }
    }

    static func fileReadPayload(_ result: SpacesDeviceWorkspaceFileReadResult) -> Result<FileReadPayload, BridgeError> {
        guard !result.isBinaryGuess, let data = Data(base64Encoded: result.base64Data), let content = String(data: data, encoding: .utf8) else {
            return .failure(BridgeError(code: .invalidArgument, message: "This file cannot be opened as text."))
        }
        let comparisonOldContent: String?
        if let encoded = result.comparisonOldBase64Data {
            guard let comparisonData = Data(base64Encoded: encoded), let comparison = String(data: comparisonData, encoding: .utf8) else {
                return .failure(BridgeError(code: .invalidArgument, message: "This file cannot be opened as text."))
            }
            comparisonOldContent = comparison
        } else {
            comparisonOldContent = nil
        }
        return .success(FileReadPayload(
            content: content, sha256: result.sha256, size: result.size,
            comparisonOldContent: comparisonOldContent))
    }

    struct RevisionFileReadPayload: Encodable, Equatable {
        let content: String
        let sha256: String
        let size: Int
        let isWorktreeEquivalentToRevision: Bool
        let comparisonOldContent: String?

        private enum CodingKeys: String, CodingKey {
            case content, sha256, size, isWorktreeEquivalentToRevision, comparisonOldContent
        }

        // See `FileReadPayload`: this specialized Last Commit response has the same strict
        // required-nullable old-side contract for an added file.
        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(content, forKey: .content)
            try container.encode(sha256, forKey: .sha256)
            try container.encode(size, forKey: .size)
            try container.encode(isWorktreeEquivalentToRevision, forKey: .isWorktreeEquivalentToRevision)
            if let comparisonOldContent {
                try container.encode(comparisonOldContent, forKey: .comparisonOldContent)
            } else {
                try container.encodeNil(forKey: .comparisonOldContent)
            }
        }
    }

    static func revisionFileReadPayload(_ result: SpacesDeviceWorkspaceRevisionFileReadResult) -> Result<RevisionFileReadPayload, BridgeError> {
        guard !result.worktreeFile.isBinaryGuess,
            let worktreeData = Data(base64Encoded: result.worktreeFile.base64Data),
            let worktreeContent = String(data: worktreeData, encoding: .utf8)
        else {
            return .failure(BridgeError(code: .invalidArgument, message: "This file cannot be opened as text."))
        }
        let comparisonOldContent: String?
        if let encoded = result.comparisonOldBase64Data {
            guard let data = Data(base64Encoded: encoded), let content = String(data: data, encoding: .utf8) else {
                return .failure(BridgeError(code: .invalidArgument, message: "This file cannot be opened as text."))
            }
            comparisonOldContent = content
        } else {
            comparisonOldContent = nil
        }
        return .success(.init(
            content: worktreeContent, sha256: result.worktreeFile.sha256, size: result.worktreeFile.size,
            isWorktreeEquivalentToRevision: result.isWorktreeEquivalentToRevision, comparisonOldContent: comparisonOldContent))
    }

    /// `workspaceFileWrite`'s wire shape is `{ok:true, sha256}`, `{conflict:true, currentSHA256}`, or
    /// `{conflict:true, fileMissing:true}` — the client discriminates via `"conflict" in result`, so a
    /// successful write must omit `conflict` entirely rather than sending `conflict:false`. Relying on
    /// `encodeIfPresent`'s nil-omission (via `Optional` properties) produces all three shapes from one
    /// struct. `sha256` on a success is the daemon's hash of exactly what it just wrote, so the client
    /// can adopt it as the next CAS baseline directly instead of re-reading the file — a re-read racing
    /// an agent's own write in between would silently adopt the agent's hash while keeping the user's
    /// unsaved buffer, and the next save would then pass CAS and overwrite the agent's change.
    struct FileWritePayload: Encodable, Equatable {
        let ok: Bool?
        let conflict: Bool?
        let currentSHA256: String?
        let fileMissing: Bool?
        let sha256: String?
    }

    static func fileWritePayload(_ result: SpacesDeviceWorkspaceFileWriteResult) -> Result<FileWritePayload, BridgeError> {
        if result.didWrite { return .success(FileWritePayload(ok: true, conflict: nil, currentSHA256: nil, fileMissing: nil, sha256: result.sha256)) }
        // A nil current hash on a failed write means the daemon found no file at all where the CAS
        // check expected one — i.e. it was deleted after the editor last read it. That's a legitimate
        // conflict, not a daemon bug: the write still can't proceed (there's nothing to compare the
        // expected hash against), so it's reported the same way an ordinary hash-mismatch conflict is,
        // just without a `currentSHA256` to show.
        guard let currentSHA256 = result.currentSHA256 else {
            return .success(FileWritePayload(ok: nil, conflict: true, currentSHA256: nil, fileMissing: true, sha256: nil))
        }
        return .success(FileWritePayload(ok: nil, conflict: true, currentSHA256: currentSHA256, fileMissing: nil, sha256: nil))
    }

    /// The success reply for `reviewCommentDelete`/`reviewCommentsSend`: both are pure side effects
    /// with nothing worth handing back beyond confirmation.
    struct AckPayload: Encodable, Equatable { let ok = true }

    /// The immediate result of launching an arbitrary command. A session is always retained even
    /// when it later exits or never identifies as an agent, so the web surface can keep the entered
    /// command and show a useful failure without losing the terminal available for inspection.
    struct StartWorkspaceCommandPayload: Encodable, Equatable {
        let sessionId: String
        let status: String
        let deadlineEpochMilliseconds: Int64
    }

    // MARK: - JS generation

    // `.sortedKeys` makes the emitted JS deterministic (Swift's default key order for synthesized
    // `Encodable` conformances follows per-process string hash seeding, not declaration order) — the
    // JS/JSON consumer never cares about key order, so sorting is free and only removes flakiness.
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    /// Builds the JS the host evaluates to resolve a pending call. `nil` only if `result` somehow
    /// fails to encode (an `Encodable` conformance bug), in which case the caller should reject
    /// instead — there is no reply worth sending.
    ///
    /// Safety: `id` and `result` are both encoded through `JSONEncoder`/`JSONSerialization`, whose
    /// own escaping (`\"`, `\n`, ...) makes the produced text safe to splice into a JS call
    /// expression regardless of what characters the underlying content contains (quotes,
    /// newlines, backticks) — this must never be built by string interpolation instead.
    static func resolveScript<T: Encodable>(id: String, result: T) -> String? {
        guard let resultJSON = jsonLiteral(result) else { return nil }
        return "window.__spacesBridge.resolve(\(jsonLiteral(forString: id)), \(resultJSON));"
    }

    /// Builds the JS the host evaluates to reject a pending call with `error`.
    static func rejectScript(id: String, error: BridgeError) -> String {
        let errorJSON = jsonLiteral(ErrorPayload(code: error.code.rawValue, message: error.message)) ?? #"{"code":"internalError","message":""}"#
        return "window.__spacesBridge.reject(\(jsonLiteral(forString: id)), \(errorJSON));"
    }

    private struct ErrorPayload: Encodable {
        let code: String
        let message: String
    }

    private static func jsonLiteral(_ value: some Encodable) -> String? {
        guard let data = try? encoder.encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// A bare string (a reply `id`, or a `CustomEvent` name below) isn't an `Encodable` struct, so
    /// it goes through `JSONSerialization` with `.fragmentsAllowed` (top-level JSON values other
    /// than object/array) instead of `JSONEncoder`. Encoding a native Swift `String` to JSON text
    /// cannot practically fail — the guard exists only to satisfy the throwing API, not because a
    /// real failure is expected.
    private static func jsonLiteral(forString value: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]),
            let text = String(data: data, encoding: .utf8)
        else { return "\"\"" }
        return text
    }

    // MARK: - Push events

    /// `spaces:init`'s detail (`CodePaneWeb/src/bridge/types.ts`'s `CodePaneInitPayload`), dispatched once at
    /// startup after the web app's `ready` message arrives.
    struct InitPayload: Encodable, Equatable {
        let workspaceId: String
        let workspaceName: String
        let theme: String
        /// The workspace's configured base branch, nil-omitted when it has none. Drives the toolbar's
        /// one-click "vs <base>" preset and the ref dialog's base badge.
        let baseBranch: String?
        /// The client-local, durable recovery state for this workspace. This is the only restore
        /// payload; independently-restored editor/sidebar/comment fields are deliberately not sent
        /// so the page never combines values from different moments.
        let workspaceState: WorkspaceState
        /// Coding agents running in this workspace right now, for the toolbar's assigned-agent
        /// dropdown (auto-default when exactly one, disabled sending with a reason when empty). Kept
        /// in sync after startup by `spaces:agents` (see `AgentsPayload` below).
        let agents: [AgentPayload]
    }

    /// One running agent, as sent in `InitPayload.agents` and `AgentsPayload.agents`. Mirrors
    /// `CodePaneRunningAgent`; `sessionId` is what `reviewCommentsSend` writes into.
    struct AgentPayload: Encodable, Equatable {
        let id: String
        let label: String
        let sessionId: String
    }

    /// `spaces:theme`'s detail, dispatched whenever the app's effective light/dark appearance changes after
    /// startup (`spaces:init` itself only ever fires once — see `CodePaneWeb/src/app/root.ts`).
    struct ThemePayload: Encodable, Equatable { let theme: String }

    /// `spaces:setMode`'s detail, dispatched to ask an already-loaded pane to switch its live
    /// Diff/Editor mode. The following complete `workspaceStateChanged` notification is the single
    /// authoritative acknowledgement persisted by `CodePaneContentController`.
    struct SetModePayload: Encodable, Equatable { let mode: String }

    /// `spaces:diffSignature`'s detail, dispatched whenever the subscribed scope's git state changes.
    struct DiffSignaturePayload: Encodable, Equatable { let scopeSignature: String }

    /// `spaces:fileSignature`'s detail, dispatched whenever the currently-open file's on-disk content
    /// changes or the file disappears. Mirrors `CodePaneWeb/src/bridge/types.ts`'s `FileSignatureEvent`:
    /// `path` self-identifies the file this event is about (unlike `DiffSignaturePayload`, which needs
    /// no such field since only one diff scope is ever live at a time), and `sha256` is nil-omitted
    /// when `missing` is `true` — there is no content to hash.
    struct FileSignaturePayload: Encodable, Equatable {
        let path: String
        let sha256: String?
        let missing: Bool
    }

    /// `spaces:fileListSignature`'s detail, dispatched whenever the authoritative
    /// `workspaceFileList` result changes for this workspace.
    struct FileListSignaturePayload: Encodable, Equatable { let fileListSignature: String }

    /// `spaces:agents`'s detail, dispatched whenever this workspace's running-agent set changes after
    /// startup (`spaces:init`'s `agents` field carries the set at page-load time).
    struct AgentsPayload: Encodable, Equatable { let agents: [AgentPayload] }

    /// A terminal-command lifecycle event. The start RPC only reports `starting`, because returning
    /// before the terminal exists would prevent its required background-tab insertion. Later events
    /// are keyed by that exact terminal id so concurrent Editor panes never auto-assign one another's
    /// newly detected agents.
    struct AgentStartStatusPayload: Encodable, Equatable {
        let sessionId: String
        let status: String
        let agent: AgentPayload?
        let message: String?
    }

    struct WorkspaceStatePayload: Encodable, Equatable { let workspaceState: WorkspaceState }

    /// Builds the JS the host evaluates to dispatch one of the push events above. `nil` only if
    /// `detail` somehow fails to encode.
    static func dispatchEventScript<T: Encodable>(name: String, detail: T) -> String? {
        guard let detailJSON = jsonLiteral(detail) else { return nil }
        return "window.dispatchEvent(new CustomEvent(\(jsonLiteral(forString: name)), {detail: \(detailJSON)}));"
    }
}

/// The one seam `CodePaneContentController` uses to stay testable without a live `WKWebView`:
/// everything upstream of "run this JS string" is the pure logic in `CodePaneBridge` above.
@MainActor protocol CodePaneScriptEvaluator: AnyObject {
    func evaluateCodePaneScript(_ script: String)
    /// Value-returning variant for scripts whose answer the host actually needs back — the teardown
    /// complete workspace-state collector is its value-returning caller.
    /// `evaluateCodePaneScript(_:)` above is fire-and-forget and cannot answer.
    func evaluateCodePaneScript(_ script: String, completion: @escaping @MainActor (Any?) -> Void)
}

extension WKWebView: CodePaneScriptEvaluator {
    func evaluateCodePaneScript(_ script: String) { evaluateJavaScript(script, completionHandler: nil) }
    /// `evaluateJavaScript(_:completionHandler:)`'s completion handler is documented to run on the
    /// main thread, so `assumeIsolated` is a safe (non-crashing) bridge from that non-isolated
    /// callback type back onto the actor this protocol otherwise requires. A genuine JS error folds
    /// into a `nil` result rather than being surfaced separately, so the complete-state collector
    /// leaves the last durable recovery document intact.
    func evaluateCodePaneScript(_ script: String, completion: @escaping @MainActor (Any?) -> Void) {
        evaluateJavaScript(script) { result, _ in MainActor.assumeIsolated { completion(result) } }
    }
}
