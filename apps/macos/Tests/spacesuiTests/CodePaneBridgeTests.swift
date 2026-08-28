import Foundation
import Testing
import spacesclientcore
import spacesdevicecore
import spacesterminalcore

@testable import spacesui

/// Covers `CodePaneBridge`'s pure decode/mapping/JS-generation logic — the whole `spacesBridge`
/// wire protocol (`CodePaneWeb/README.md`) except the actual `SpacesDeviceClient` calls, which only
/// `CodePaneContentController` makes. Nothing here touches a `WKWebView` or a live device.
@Suite struct CodePaneBridgeTests {
    private func workspaceState(
        mode: String = "diff", editorState: CodePaneBridge.EditorState? = nil, sidebarMode: String = "files", recentPaths: [String] = [],
        diffScrollSide: String? = nil, diffFocusedSide: String? = nil, diffTreeExpandedPaths: [String]? = nil,
        diffEditorState: CodePaneBridge.DiffEditorState? = nil
    ) -> CodePaneBridge.WorkspaceState {
        CodePaneBridge.WorkspaceState(
            mode: mode, scope: .uncommitted, diffLayout: "unified", diffSelectedPath: nil,
            diffTreeExpandedPaths: diffTreeExpandedPaths, diffTreeSelectedPath: nil, fileTreeExpandedPaths: [], fileTreeSelectedPath: nil, editorSidebarMode: sidebarMode,
            editorRecentPaths: recentPaths, diffScrollLine: diffScrollSide == nil ? nil : 0, diffScrollSide: diffScrollSide,
            diffFocusedPath: diffFocusedSide == nil ? nil : "diff.swift", diffFocusedLine: diffFocusedSide == nil ? nil : 0, diffFocusedSide: diffFocusedSide, editorScrollLine: nil, editorFocusedLine: nil, editorState: editorState,
            diffEditorState: diffEditorState, pendingReviewComments: nil)
    }

    private func initPayload(baseBranch: String? = nil, state: CodePaneBridge.WorkspaceState? = nil) -> CodePaneBridge.InitPayload {
        CodePaneBridge.InitPayload(
            workspaceId: "w1", workspaceName: "My Workspace", theme: "dark", baseBranch: baseBranch,
            workspaceState: state ?? workspaceState(), agents: [])
    }

    // MARK: - Request / ready decode

    @Test func decodeRequestReadsIdMethodAndParams() throws {
        let request = try #require(CodePaneBridge.decodeRequest(body: ["id": "1", "method": "workspaceFileRead", "params": ["path": "a.txt"]]))

        #expect(request.id == "1")
        #expect(request.method == "workspaceFileRead")
        #expect(request.params["path"] as? String == "a.txt")
    }

    @Test func decodeRequestDefaultsMissingParamsToEmpty() throws {
        let request = try #require(CodePaneBridge.decodeRequest(body: ["id": "1", "method": "workspaceFileList"]))

        #expect(request.params.isEmpty)
    }

    // `[String: Any]` isn't `Sendable`, so these are separate tests rather than one parameterized
    // over an `arguments:` array (Swift Testing requires `Sendable` arguments).
    @Test func decodeRequestRejectsABodyMissingId() { #expect(CodePaneBridge.decodeRequest(body: ["method": "workspaceFileList"]) == nil) }

    @Test func decodeRequestRejectsABodyMissingMethod() { #expect(CodePaneBridge.decodeRequest(body: ["id": "1"]) == nil) }

    @Test func decodeRequestRejectsANonStringId() { #expect(CodePaneBridge.decodeRequest(body: ["id": 1, "method": "workspaceFileList"]) == nil) }

    @Test func decodeRequestRejectsNonDictionaryBody() { #expect(CodePaneBridge.decodeRequest(body: "not a dictionary") == nil) }

    @Test func isReadyRecognizesTheFireAndForgetNotification() { #expect(CodePaneBridge.isReady(body: ["method": "ready"])) }

    @Test func isReadyRejectsAnythingWithAnId() { #expect(!CodePaneBridge.isReady(body: ["id": "1", "method": "ready"])) }

    @Test func isReadyRejectsOtherMethods() { #expect(!CodePaneBridge.isReady(body: ["method": "workspaceFileList"])) }

    // MARK: - Diff scope decode

    @Test func decodeDiffScopeUncommitted() { #expect(CodePaneBridge.decodeDiffScope(["kind": "uncommitted"]) == .success(.uncommitted)) }

    @Test func decodeDiffScopeLastCommit() { #expect(CodePaneBridge.decodeDiffScope(["kind": "lastCommit"]) == .success(.lastCommit)) }

    /// `baseBranch` was the pre-"last commit" committed-only scope kind; the wire no longer offers it
    /// (the Compare dialog resolves a base branch to a `ref` scope client-side instead), so it must
    /// be rejected like any other unrecognized kind rather than silently accepted.
    @Test func decodeDiffScopeRejectsBaseBranch() { #expect(CodePaneBridge.decodeDiffScope(["kind": "baseBranch"]).isInvalidArgumentFailure) }

    @Test func decodeDiffScopeRef() { #expect(CodePaneBridge.decodeDiffScope(["kind": "ref", "refName": "main"]) == .success(.ref("main"))) }

    @Test func decodeDiffScopeRefRequiresANonEmptyRefName() {
        let result = CodePaneBridge.decodeDiffScope(["kind": "ref", "refName": ""])
        #expect(result.isInvalidArgumentFailure)
    }

    @Test func decodeDiffScopeRefRequiresARefNameAtAll() {
        let result = CodePaneBridge.decodeDiffScope(["kind": "ref"])
        #expect(result.isInvalidArgumentFailure)
    }

    @Test func decodeDiffScopeRejectsUnknownKind() { #expect(CodePaneBridge.decodeDiffScope(["kind": "bogus"]).isInvalidArgumentFailure) }

    @Test func decodeDiffScopeRejectsNonDictionary() { #expect(CodePaneBridge.decodeDiffScope("uncommitted").isInvalidArgumentFailure) }

    @Test func decodeDiffScopeRejectsNil() { #expect(CodePaneBridge.decodeDiffScope(nil).isInvalidArgumentFailure) }

    // MARK: - refName resolution

    @Test func refNameForUncommittedIsNilWithoutLastCommit() {
        let (refName, lastCommit) = CodePaneBridge.refName(for: .uncommitted)
        #expect(refName == nil)
        #expect(!lastCommit)
    }

    @Test func refNameForRefIsTheLiteralRefWithoutLastCommit() {
        let (refName, lastCommit) = CodePaneBridge.refName(for: .ref("feature/x"))
        #expect(refName == "feature/x")
        #expect(!lastCommit)
    }

    @Test func refNameForLastCommitIsNilRefNameWithLastCommitSet() {
        let (refName, lastCommit) = CodePaneBridge.refName(for: .lastCommit)
        #expect(refName == nil)
        #expect(lastCommit)
    }

    // MARK: - InitPayload base branch encoding

    /// The toolbar disables (rather than hides) the "vs base branch" option based on whether this
    /// key is present at all, so it must encode when the workspace has one...
    @Test func initPayloadEncodesBaseBranchWhenPresent() throws {
        let payload = initPayload(baseBranch: "main")

        let data = try JSONEncoder().encode(payload)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["baseBranch"] as? String == "main")
    }

    /// ...and must be omitted entirely (not `"baseBranch":null`) when it has none, matching every
    /// other nil-omitted field in this payload.
    @Test func initPayloadOmitsBaseBranchKeyWhenAbsent() throws {
        let payload = initPayload()

        let data = try JSONEncoder().encode(payload)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["baseBranch"] == nil)
    }

    // MARK: - InitPayload editorState encoding

    /// The complete recovery object always crosses the wire. An absent optional editor snapshot is
    /// omitted, leaving the page to restore a clean editor while every non-optional field remains
    /// atomic with it.
    @Test func initPayloadOmitsAnAbsentEditorStateInsideWorkspaceState() throws {
        let payload = initPayload()

        let data = try JSONEncoder().encode(payload)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let state = try #require(json["workspaceState"] as? [String: Any])
        #expect(state["editorState"] == nil)
    }

    @Test func initPayloadEncodesEditorStateWhenPresent() throws {
        let state = CodePaneBridge.EditorState(path: "a.swift", baseSHA256: "sha-1", baseContent: "let x = 1", content: "let x = 1", dirty: true)
        let payload = initPayload(state: workspaceState(mode: "editor", editorState: state))

        let data = try JSONEncoder().encode(payload)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let workspaceState = try #require(json["workspaceState"] as? [String: Any])
        let editorState = try #require(workspaceState["editorState"] as? [String: Any])
        #expect(editorState["path"] as? String == "a.swift")
        #expect(editorState["baseSHA256"] as? String == "sha-1")
        #expect(editorState["baseContent"] as? String == "let x = 1")
        #expect(editorState["content"] as? String == "let x = 1")
        #expect(editorState["dirty"] as? Bool == true)
        #expect(editorState["conflict"] as? Bool == false)
    }

    @Test func editorStateRejectsAPartialSnapshot() {
        let partial = #"{"path":"a.swift","baseSHA256":"sha-1","baseContent":"let x = 1","content":"let x = 1","dirty":true}"#

        #expect((try? JSONDecoder().decode(CodePaneBridge.EditorState.self, from: Data(partial.utf8))) == nil)
    }

    @Test func diffEditorConflictPreservesItsExactCASTargetAcrossTheStrictWireState() throws {
        let changed = CodePaneBridge.DiffEditorState(
            path: "a.swift", baseSHA256: "base-sha", baseContent: "base", content: "mine", dirty: true, conflict: true,
            conflictBaseSHA256: "disk-sha")
        let deleted = CodePaneBridge.DiffEditorState(
            path: "a.swift", baseSHA256: "base-sha", baseContent: "base", content: "mine", dirty: true, conflict: true,
            conflictBaseSHA256: nil)
        let clean = CodePaneBridge.DiffEditorState(
            path: "a.swift", baseSHA256: "base-sha", baseContent: "base", content: "mine", dirty: false, conflict: false,
            conflictBaseSHA256: nil)

        let changedData = try JSONEncoder().encode(changed)
        let changedJSON = try #require(JSONSerialization.jsonObject(with: changedData) as? [String: Any])
        #expect(changedJSON["conflictBaseSHA256"] as? String == "disk-sha")

        let deletedData = try JSONEncoder().encode(deleted)
        let deletedJSON = try #require(JSONSerialization.jsonObject(with: deletedData) as? [String: Any])
        #expect(deletedJSON["conflictBaseSHA256"] is NSNull)
        let cleanData = try JSONEncoder().encode(clean)
        let cleanJSON = try #require(JSONSerialization.jsonObject(with: cleanData) as? [String: Any])
        #expect(cleanJSON["conflictBaseSHA256"] is NSNull)

        var missingTarget = changedJSON
        missingTarget.removeValue(forKey: "conflictBaseSHA256")
        let missingTargetData = try JSONSerialization.data(withJSONObject: missingTarget)
        #expect((try? JSONDecoder().decode(CodePaneBridge.DiffEditorState.self, from: missingTargetData)) == nil)

        let invalidNonConflict = CodePaneBridge.DiffEditorState(
            path: "a.swift", baseSHA256: "base-sha", baseContent: "base", content: "mine", dirty: true, conflict: false,
            conflictBaseSHA256: "disk-sha")
        let invalidEmptyTarget = CodePaneBridge.DiffEditorState(
            path: "a.swift", baseSHA256: "base-sha", baseContent: "base", content: "mine", dirty: true, conflict: true,
            conflictBaseSHA256: "")
        #expect(!CodePaneBridge.isValidWorkspaceState(workspaceState(diffEditorState: invalidNonConflict)))
        #expect(!CodePaneBridge.isValidWorkspaceState(workspaceState(diffEditorState: invalidEmptyTarget)))
        #expect(CodePaneBridge.isValidWorkspaceState(workspaceState(diffEditorState: changed)))
        #expect(CodePaneBridge.isValidWorkspaceState(workspaceState(diffEditorState: deleted)))
    }

    @Test func workspaceStateChangedRejectsUnknownEnumStringsAndMissingRequiredCollections() throws {
        let data = try JSONEncoder().encode(workspaceState())
        var params = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        params["mode"] = "unexpected"
        #expect(CodePaneBridge.decodeWorkspaceStateChanged(body: ["method": "workspaceStateChanged", "params": params]) == nil)

        params = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        params.removeValue(forKey: "fileTreeExpandedPaths")
        #expect(CodePaneBridge.decodeWorkspaceStateChanged(body: ["method": "workspaceStateChanged", "params": params]) == nil)

        params = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        params["diffScrollSide"] = "middle"
        #expect(CodePaneBridge.decodeWorkspaceStateChanged(body: ["method": "workspaceStateChanged", "params": params]) == nil)

        params = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        params["diffFocusedSide"] = "middle"
        #expect(CodePaneBridge.decodeWorkspaceStateChanged(body: ["method": "workspaceStateChanged", "params": params]) == nil)
    }

    @Test func diffTreeExpansionOmitsFreshStateAndPreservesAnExplicitCollapse() throws {
        let freshPayload = initPayload(state: workspaceState(diffTreeExpandedPaths: nil))
        let freshData = try JSONEncoder().encode(freshPayload)
        let freshJSON = try #require(JSONSerialization.jsonObject(with: freshData) as? [String: Any])
        let freshState = try #require(freshJSON["workspaceState"] as? [String: Any])
        #expect(freshState["diffTreeExpandedPaths"] == nil)

        let collapsedPayload = initPayload(state: workspaceState(diffTreeExpandedPaths: []))
        let collapsedData = try JSONEncoder().encode(collapsedPayload)
        let collapsedJSON = try #require(JSONSerialization.jsonObject(with: collapsedData) as? [String: Any])
        let collapsedState = try #require(collapsedJSON["workspaceState"] as? [String: Any])
        #expect((collapsedState["diffTreeExpandedPaths"] as? [String]) == [])
    }

    @Test func workspaceStateChangedRequiresAnAbsoluteDeadlineForStartingAgentLaunches() throws {
        let data = try JSONEncoder().encode(workspaceState())
        var params = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        params["pendingAgentLaunch"] = [
            "sessionId": "session-start", "command": "custom-agent --review", "status": "starting",
            "message": NSNull(),
        ]
        #expect(CodePaneBridge.decodeWorkspaceStateChanged(body: ["method": "workspaceStateChanged", "params": params]) == nil)

        params["pendingAgentLaunch"] = [
            "sessionId": "session-start", "command": "custom-agent --review", "status": "starting",
            "message": NSNull(), "deadlineEpochMilliseconds": 1_000,
        ]
        #expect(CodePaneBridge.decodeWorkspaceStateChanged(body: ["method": "workspaceStateChanged", "params": params]) != nil)

        params["pendingAgentLaunch"] = [
            "sessionId": "session-start", "command": "custom-agent --review", "status": "failed",
            "message": "No agent detected", "deadlineEpochMilliseconds": 1_000,
        ]
        #expect(CodePaneBridge.decodeWorkspaceStateChanged(body: ["method": "workspaceStateChanged", "params": params]) == nil)
    }

    @Test func workspaceStateCarriesEachDiffPositionWithItsSide() throws {
        let state = CodePaneBridge.WorkspaceState(
            mode: "diff", scope: .uncommitted, diffLayout: "split", diffSelectedPath: "Sources/App.swift",
            diffTreeExpandedPaths: [], diffTreeSelectedPath: "Sources/App.swift",
            fileTreeExpandedPaths: [], fileTreeSelectedPath: nil, editorSidebarMode: "files", editorRecentPaths: [],
            diffScrollLine: 17, diffScrollSide: "old", diffFocusedPath: "Sources/App.swift", diffFocusedLine: 18, diffFocusedSide: "new",
            editorScrollLine: nil, editorFocusedLine: nil, editorState: nil, diffEditorState: nil, pendingReviewComments: nil)

        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(CodePaneBridge.WorkspaceState.self, from: data)

        #expect(decoded.diffScrollSide == "old")
        #expect(decoded.diffFocusedSide == "new")
        #expect(CodePaneBridge.isValidWorkspaceState(decoded))

        var missingSide = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        missingSide.removeValue(forKey: "diffScrollSide")
        let missingSideData = try JSONSerialization.data(withJSONObject: missingSide)
        let incomplete = try JSONDecoder().decode(CodePaneBridge.WorkspaceState.self, from: missingSideData)
        #expect(!CodePaneBridge.isValidWorkspaceState(incomplete))

        var missingFocusedPath = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        missingFocusedPath.removeValue(forKey: "diffFocusedPath")
        let missingFocusedPathData = try JSONSerialization.data(withJSONObject: missingFocusedPath)
        let incompleteFocusedPosition = try JSONDecoder().decode(CodePaneBridge.WorkspaceState.self, from: missingFocusedPathData)
        #expect(!CodePaneBridge.isValidWorkspaceState(incompleteFocusedPosition))
    }

    // MARK: - InitPayload sidebar encoding

    @Test func initPayloadEncodesEditorSidebarStateInsideWorkspaceState() throws {
        let payload = initPayload(state: workspaceState(mode: "editor", sidebarMode: "changes", recentPaths: ["a.swift", "b.swift"]))

        let data = try JSONEncoder().encode(payload)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let state = try #require(json["workspaceState"] as? [String: Any])
        #expect(state["editorSidebarMode"] as? String == "changes")
        #expect(state["editorRecentPaths"] as? [String] == ["a.swift", "b.swift"])
    }

    @Test func initPayloadEncodesDiffViewportSidesInsideWorkspaceState() throws {
        let payload = initPayload(state: workspaceState(diffScrollSide: "old", diffFocusedSide: "new"))

        let data = try JSONEncoder().encode(payload)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let state = try #require(json["workspaceState"] as? [String: Any])
        #expect(state["diffScrollSide"] as? String == "old")
        #expect(state["diffFocusedSide"] as? String == "new")
    }

    // MARK: - renderMetric decode

    @Test func decodeRenderMetricParsesABoundedMilestone() {
        let metric = CodePaneBridge.decodeRenderMetric(body: [
            "method": "renderMetric",
            "params": ["kind": "diff", "trigger": "scope", "elapsedMs": 42, "fetchElapsedMs": 17, "fileCount": 3, "contentBytes": 8192],
        ])

        #expect(
            metric
                == CodePaneBridge.RenderMetric(
                    kind: .diff, trigger: .scope, elapsedMS: 42, fetchElapsedMS: 17,
                    bridgeElapsedMS: nil, decodeElapsedMS: nil, updateElapsedMS: nil, paintElapsedMS: nil,
                    fileCount: 3, contentBytes: 8192,
                    path: nil, fileIndex: nil, selectedPriority: false, chunkCount: nil,
                    mode: nil, scope: nil, layout: nil, scrollTop: nil, focusedLine: nil, dirty: nil))
    }

    @Test func decodeRenderMetricParsesPerFileStreamingTimings() {
        let metric = CodePaneBridge.decodeRenderMetric(body: [
            "method": "renderMetric",
            "params": [
                "kind": "diff", "trigger": "filePatch", "elapsedMs": 42, "fileCount": 3, "contentBytes": 8192,
                "bridgeElapsedMs": 11, "decodeElapsedMs": 7, "updateElapsedMs": 5, "paintElapsedMs": 19,
            ],
        ])

        #expect(metric?.bridgeElapsedMS == 11)
        #expect(metric?.decodeElapsedMS == 7)
        #expect(metric?.updateElapsedMS == 5)
        #expect(metric?.paintElapsedMS == 19)
    }

    @Test func decodeRenderMetricRejectsUnknownKindsAndRequestMessages() {
        #expect(
            CodePaneBridge.decodeRenderMetric(body: [
                "method": "renderMetric", "params": ["kind": "other", "trigger": "initial", "elapsedMs": 1, "fileCount": 0, "contentBytes": 0],
            ]) == nil)
        #expect(
            CodePaneBridge.decodeRenderMetric(body: [
                "method": "renderMetric",
                "params": [
                    "kind": "diff", "trigger": "initial", "elapsedMs": 1, "fetchElapsedMs": 2, "fileCount": 0, "contentBytes": 0,
                ],
            ]) == nil)
        #expect(
            CodePaneBridge.decodeRenderMetric(body: [
                "id": "1", "method": "renderMetric",
                "params": ["kind": "diff", "trigger": "initial", "elapsedMs": 1, "fileCount": 0, "contentBytes": 0],
            ]) == nil)
    }

    @Test func decodeRenderMetricRejectsNegativeOrExcessiveValues() {
        #expect(
            CodePaneBridge.decodeRenderMetric(body: [
                "method": "renderMetric", "params": ["kind": "editor", "trigger": "fileOpen", "elapsedMs": -1, "fileCount": 1, "contentBytes": 1],
            ]) == nil)
        #expect(
            CodePaneBridge.decodeRenderMetric(body: [
                "method": "renderMetric",
                "params": ["kind": "editor", "trigger": "fileOpen", "elapsedMs": 1, "fileCount": 1, "contentBytes": 5 * 1024 * 1024 * 1024],
            ]) == nil)
        #expect(
            CodePaneBridge.decodeRenderMetric(body: [
                "method": "renderMetric",
                "params": ["kind": "diff", "trigger": "filePatch", "elapsedMs": 10, "fileCount": 1, "contentBytes": 1, "updateElapsedMs": 11],
            ]) == nil)
    }

    // MARK: - RPC-to-client-call mapping

    @Test func planForWorkspaceDiffManifestChunkDecodesItsScope() {
        let request = CodePaneBridge.Request(id: "1", method: "workspaceDiffManifestChunk", params: ["scope": ["kind": "uncommitted"], "fileIndex": 0])

        #expect(CodePaneBridge.plan(for: request) == .success(.workspaceDiffManifestChunk(scope: .uncommitted, manifestID: nil, fileIndex: 0)))
    }

    @Test func planForWorkspaceDiffManifestChunkBindsContinuationCursor() {
        let request = CodePaneBridge.Request(
            id: "1", method: "workspaceDiffManifestChunk", params: ["scope": ["kind": "lastCommit"], "manifestID": "manifest-1", "fileIndex": 42])

        #expect(CodePaneBridge.plan(for: request) == .success(.workspaceDiffManifestChunk(scope: .lastCommit, manifestID: "manifest-1", fileIndex: 42)))
    }

    @Test func planForWorkspaceDiffManifestChunkPropagatesAScopeDecodeFailure() {
        let request = CodePaneBridge.Request(id: "1", method: "workspaceDiffManifestChunk", params: ["scope": ["kind": "bogus"], "fileIndex": 0])

        #expect(CodePaneBridge.plan(for: request).isInvalidArgumentFailure)
    }

    @Test func planForWorkspaceDiffFileChunkBindsTheManifestAndTransfer() {
        let request = CodePaneBridge.Request(
            id: "1", method: "workspaceDiffFileChunk",
            params: [
                "scope": ["kind": "ref", "refName": "main"], "manifestID": "manifest-1", "relativePath": "Sources/App.swift",
                "byteOffset": 1024, "transferID": "transfer-1",
            ])

        #expect(
            CodePaneBridge.plan(for: request)
                == .success(
                    .workspaceDiffFileChunk(
                        scope: .ref("main"), manifestID: "manifest-1", relativePath: "Sources/App.swift", byteOffset: 1024,
                        transferID: "transfer-1")))
    }

    @Test func planRejectsAChunkWithoutTheManifestThatOwnsIt() {
        let request = CodePaneBridge.Request(
            id: "1", method: "workspaceDiffFileChunk",
            params: ["scope": ["kind": "uncommitted"], "relativePath": "Sources/App.swift", "byteOffset": 0])

        #expect(CodePaneBridge.plan(for: request).isInvalidArgumentFailure)
    }

    @Test func planForWorkspaceDiffFileChunkCancelBindsTheManifestAndTransfer() {
        let request = CodePaneBridge.Request(
            id: "1", method: "workspaceDiffFileChunkCancel",
            params: [
                "scope": ["kind": "lastCommit"], "manifestID": "manifest-1", "relativePath": "Sources/App.swift", "byteOffset": 2048,
                "transferID": "transfer-1",
            ])

        #expect(
            CodePaneBridge.plan(for: request)
                == .success(
                    .workspaceDiffFileChunkCancel(
                        scope: .lastCommit, manifestID: "manifest-1", relativePath: "Sources/App.swift", byteOffset: 2048,
                        transferID: "transfer-1")))
    }

    @Test func planForWorkspaceDiffManifestReleaseBindsItsScope() {
        let request = CodePaneBridge.Request(
            id: "1", method: "workspaceDiffManifestRelease",
            params: ["scope": ["kind": "uncommitted"], "manifestID": "manifest-1"])

        #expect(CodePaneBridge.plan(for: request) == .success(.workspaceDiffManifestRelease(scope: .uncommitted, manifestID: "manifest-1")))
    }

    @Test func planRejectsAManifestReleaseWithoutAManifestID() {
        let request = CodePaneBridge.Request(id: "1", method: "workspaceDiffManifestRelease", params: ["scope": ["kind": "uncommitted"]])

        #expect(CodePaneBridge.plan(for: request).isInvalidArgumentFailure)
    }

    /// Unlike every other RPC method here, `workspaceFileList` carries no per-request params at all —
    /// the workspace is implied by the pane's own `workspaceID`, so decoding must succeed regardless
    /// of what `params` holds.
    @Test func planForWorkspaceFileListRequiresNoParams() {
        let request = CodePaneBridge.Request(id: "1", method: "workspaceFileList", params: [:])

        #expect(CodePaneBridge.plan(for: request) == .success(.workspaceFileList))
    }

    @Test func planForWorkspaceFileRead() {
        let request = CodePaneBridge.Request(id: "1", method: "workspaceFileRead", params: ["path": "src/a.swift"])

        #expect(CodePaneBridge.plan(for: request) == .success(.workspaceFileRead(path: "src/a.swift")))
    }

    @Test func planForWorkspaceFileReadRequiresAPath() {
        let request = CodePaneBridge.Request(id: "1", method: "workspaceFileRead", params: [:])

        #expect(CodePaneBridge.plan(for: request).isInvalidArgumentFailure)
    }

    @Test func planForWorkspaceFileWrite() {
        let request = CodePaneBridge.Request(
            id: "1", method: "workspaceFileWrite", params: ["path": "src/a.swift", "content": "hi", "options": ["baseSHA256": "abc123"]])

        #expect(CodePaneBridge.plan(for: request) == .success(.workspaceFileWrite(path: "src/a.swift", content: "hi", baseSHA256: "abc123")))
    }

    // `[String: Any]` isn't `Sendable`, so these are separate tests rather than one parameterized
    // over an `arguments:` array (Swift Testing requires `Sendable` arguments).
    @Test func planForWorkspaceFileWriteRequiresPath() {
        let request = CodePaneBridge.Request(id: "1", method: "workspaceFileWrite", params: [:])
        #expect(CodePaneBridge.plan(for: request).isInvalidArgumentFailure)
    }

    @Test func planForWorkspaceFileWriteRequiresContent() {
        let request = CodePaneBridge.Request(id: "1", method: "workspaceFileWrite", params: ["path": "a"])
        #expect(CodePaneBridge.plan(for: request).isInvalidArgumentFailure)
    }

    @Test func planForWorkspaceFileWriteRequiresOptions() {
        let request = CodePaneBridge.Request(id: "1", method: "workspaceFileWrite", params: ["path": "a", "content": "hi"])
        #expect(CodePaneBridge.plan(for: request).isInvalidArgumentFailure)
    }

    /// `baseSHA256` is optional, not required: an absent (or JSON `null`) `options.baseSHA256` is the
    /// wire's "create" convention (see `Plan.workspaceFileWrite`'s doc comment) — "Keep mine" uses this
    /// to recreate a file the daemon reports as missing, so this must succeed with `nil`, not reject.
    @Test func planForWorkspaceFileWriteTreatsAMissingBaseSHA256AsCreate() {
        let request = CodePaneBridge.Request(id: "1", method: "workspaceFileWrite", params: ["path": "a", "content": "hi", "options": [:]])
        #expect(CodePaneBridge.plan(for: request) == .success(.workspaceFileWrite(path: "a", content: "hi", baseSHA256: nil)))
    }

    @Test func planForWorkspaceFileWriteTreatsAJSONNullBaseSHA256AsCreate() {
        let request = CodePaneBridge.Request(
            id: "1", method: "workspaceFileWrite", params: ["path": "a", "content": "hi", "options": ["baseSHA256": NSNull()]])
        #expect(CodePaneBridge.plan(for: request) == .success(.workspaceFileWrite(path: "a", content: "hi", baseSHA256: nil)))
    }

    @Test func planForWorkspaceFileList() {
        let request = CodePaneBridge.Request(id: "1", method: "workspaceFileList", params: ["query": "foo"])

        #expect(CodePaneBridge.plan(for: request) == .success(.workspaceFileList))
    }

    /// Mirrors `planForWorkspaceFileListRequiresNoParams`: `workspaceRefList` carries no per-request
    /// params either, since the workspace is implied by the pane's own `workspaceID`.
    @Test func planForWorkspaceRefListRequiresNoParams() {
        let request = CodePaneBridge.Request(id: "1", method: "workspaceRefList", params: [:])

        #expect(CodePaneBridge.plan(for: request) == .success(.workspaceRefList))
    }

    @Test func planForReviewCommentsSendDecodesEachEntrysIdAndRevision() {
        let request = CodePaneBridge.Request(
            id: "1", method: "reviewCommentsSend",
            params: ["sessionId": "agent-1", "text": "please fix", "comments": [["id": "c1", "revision": 0], ["id": "c2", "revision": 2]]])

        #expect(
            CodePaneBridge.plan(for: request)
                == .success(
                    .reviewCommentsSend(
                        sessionID: "agent-1", text: "please fix",
                        comments: [
                            SpacesDeviceReviewCommentSendEntry(id: "c1", revision: 0), SpacesDeviceReviewCommentSendEntry(id: "c2", revision: 2),
                        ])))
    }

    @Test func planForReviewCommentsSendRequiresANonEmptyComments() {
        let request = CodePaneBridge.Request(id: "1", method: "reviewCommentsSend", params: ["sessionId": "agent-1", "text": "hi", "comments": []])
        #expect(CodePaneBridge.plan(for: request).isInvalidArgumentFailure)
    }

    @Test func planForReviewCommentsSendRequiresEveryEntrysRevision() {
        let request = CodePaneBridge.Request(
            id: "1", method: "reviewCommentsSend", params: ["sessionId": "agent-1", "text": "hi", "comments": [["id": "c1"]]])
        #expect(CodePaneBridge.plan(for: request).isInvalidArgumentFailure)
    }

    @Test func planRejectsAnUnknownMethod() {
        let request = CodePaneBridge.Request(id: "1", method: "bogusMethod", params: [:])

        #expect(CodePaneBridge.plan(for: request).isInvalidArgumentFailure)
    }

    // MARK: - Client error mapping

    @Test func mapClientErrorPassesThroughTheRejectionMessage() {
        let error = CodePaneBridge.mapClientError(SpacesDeviceClientError.requestRejected(message: "nope", code: .notFound))

        #expect(error == CodePaneBridge.BridgeError(code: .notFound, message: "nope"))
    }

    @Test(
        "mapClientError maps every SpacesDeviceErrorCode",
        arguments: [
            (SpacesDeviceErrorCode.notFound, CodePaneBridge.ErrorCode.notFound), (.invalidArgument, .invalidArgument),
            (.ownershipRejected, .invalidArgument), (.payloadTooLarge, .invalidArgument), (.unsupportedFormat, .invalidArgument),
            (.conflict, .conflict), (.internalError, .internalError), (.unauthorized, .unavailable), (.sessionNotRunning, .unavailable),
            (.sessionNotAvailable, .unavailable), (.serviceNotRunning, .unavailable), (.busy, .unavailable), (.capabilityMissing, .unavailable),
            (.misroutedRequest, .unavailable), (.shuttingDown, .unavailable), (.handingOff, .unavailable),
        ]) func mapClientErrorMapsEveryDeviceErrorCode(deviceCode: SpacesDeviceErrorCode, bridgeCode: CodePaneBridge.ErrorCode)
    {
        let error = CodePaneBridge.mapClientError(SpacesDeviceClientError.requestRejected(message: "m", code: deviceCode))

        #expect(error.code == bridgeCode)
    }

    @Test func mapClientErrorTreatsANilCodeAsInternalError() {
        let error = CodePaneBridge.mapClientError(SpacesDeviceClientError.requestRejected(message: "m", code: nil))

        #expect(error.code == .internalError)
    }

    @Test func mapClientErrorTreatsNonRejectionClientErrorsAsUnavailable() {
        let error = CodePaneBridge.mapClientError(SpacesDeviceClientError.missingOverview)

        #expect(error.code == .unavailable)
    }

    @Test func mapClientErrorTreatsAnyOtherErrorAsUnavailable() {
        struct SomeOtherError: Error {}
        let error = CodePaneBridge.mapClientError(SomeOtherError())

        #expect(error.code == .unavailable)
    }

    // MARK: - Result payload shaping

    @Test func fileReadPayloadDecodesUTF8Text() {
        let result = SpacesDeviceWorkspaceFileReadResult(
            base64Data: Data("hello".utf8).base64EncodedString(), sha256: "sha", size: 5, isBinaryGuess: false)

        #expect(CodePaneBridge.fileReadPayload(result) == .success(CodePaneBridge.FileReadPayload(content: "hello", sha256: "sha", size: 5)))
    }

    @Test func fileReadPayloadRejectsBinaryGuesses() {
        let result = SpacesDeviceWorkspaceFileReadResult(
            base64Data: Data("hello".utf8).base64EncodedString(), sha256: "sha", size: 5, isBinaryGuess: true)

        #expect(CodePaneBridge.fileReadPayload(result).isInvalidArgumentFailure)
    }

    @Test func fileReadPayloadRejectsNonUTF8Bytes() {
        let invalidUTF8 = Data([0xFF, 0xFE, 0xFD])
        let result = SpacesDeviceWorkspaceFileReadResult(base64Data: invalidUTF8.base64EncodedString(), sha256: "sha", size: 3, isBinaryGuess: false)

        #expect(CodePaneBridge.fileReadPayload(result).isInvalidArgumentFailure)
    }

    /// A successful write's own hash rides along in the payload, so the client can
    /// adopt it as the next CAS baseline directly instead of racing a re-read against another writer.
    @Test func fileWritePayloadOnSuccessCarriesTheWritesOwnHash() {
        let result = SpacesDeviceWorkspaceFileWriteResult(didWrite: true, sha256: "new-sha")

        #expect(
            CodePaneBridge.fileWritePayload(result)
                == .success(CodePaneBridge.FileWritePayload(ok: true, conflict: nil, currentSHA256: nil, fileMissing: nil, sha256: "new-sha")))
    }

    @Test func fileWritePayloadOnCASConflict() {
        let result = SpacesDeviceWorkspaceFileWriteResult(didWrite: false, currentSHA256: "current-sha")

        #expect(
            CodePaneBridge.fileWritePayload(result)
                == .success(CodePaneBridge.FileWritePayload(ok: nil, conflict: true, currentSHA256: "current-sha", fileMissing: nil, sha256: nil)))
    }

    /// A CAS conflict is a typed result, never a thrown error — `fileWritePayload`, not
    /// `mapClientError`, is the only place it's handled.
    @Test func fileWritePayloadNeverProducesAConflictErrorCode() {
        let result = SpacesDeviceWorkspaceFileWriteResult(didWrite: false, currentSHA256: "current-sha")

        guard case .success(let payload) = CodePaneBridge.fileWritePayload(result) else {
            Issue.record("expected a successful conflict payload, not a BridgeError")
            return
        }
        #expect(payload.conflict == true)
    }

    /// A deleted-after-read file is a legitimate conflict, not a daemon-invariant violation: the
    /// write can't proceed (nothing to compare the expected hash against), and the payload says so
    /// via `fileMissing` instead of surfacing an internalError.
    @Test func fileWritePayloadOnDeletedFileReportsFileMissingConflict() {
        let result = SpacesDeviceWorkspaceFileWriteResult(didWrite: false)

        #expect(
            CodePaneBridge.fileWritePayload(result)
                == .success(CodePaneBridge.FileWritePayload(ok: nil, conflict: true, currentSHA256: nil, fileMissing: true, sha256: nil)))
    }

    // MARK: - JS generation: JSON-safety

    @Test func resolveScriptEncodesTheIdAndResultAsJSON() throws {
        let script = try #require(
            CodePaneBridge.resolveScript(
                id: "req-1", result: CodePaneBridge.FileWritePayload(ok: true, conflict: nil, currentSHA256: nil, fileMissing: nil, sha256: nil)))

        #expect(script == #"window.__spacesBridge.resolve("req-1", {"ok":true});"#)
    }

    /// The `fileMissing` conflict shape must encode without a `currentSHA256` key at all (nil-omission,
    /// not `"currentSHA256":null`) — the web side discriminates the two conflict shapes by whether
    /// that key is present.
    @Test func resolveScriptEncodesFileMissingConflictWithoutACurrentSHA256Key() throws {
        let script = try #require(
            CodePaneBridge.resolveScript(
                id: "req-1", result: CodePaneBridge.FileWritePayload(ok: nil, conflict: true, currentSHA256: nil, fileMissing: true, sha256: nil)))

        #expect(script == #"window.__spacesBridge.resolve("req-1", {"conflict":true,"fileMissing":true});"#)
    }

    @Test func rejectScriptEncodesTheIdAndErrorAsJSON() {
        let script = CodePaneBridge.rejectScript(id: "req-1", error: CodePaneBridge.BridgeError(code: .notFound, message: "missing"))

        #expect(script == #"window.__spacesBridge.reject("req-1", {"code":"notFound","message":"missing"});"#)
    }

    @Test func dispatchEventScriptEncodesTheNameAndDetailAsJSON() throws {
        let script = try #require(CodePaneBridge.dispatchEventScript(name: "spaces:theme", detail: CodePaneBridge.ThemePayload(theme: "dark")))

        #expect(script == #"window.dispatchEvent(new CustomEvent("spaces:theme", {detail: {"theme":"dark"}}));"#)
    }

    /// The load-bearing case: content containing a double quote, a newline, and a backtick must
    /// never be spliced into the generated JS unescaped — this is exactly why the implementation
    /// goes through `JSONEncoder`/`JSONSerialization` instead of string interpolation. `id` is a
    /// fixed simple token here (real ids are host-generated UUIDs), so the known
    /// `window.__spacesBridge.resolve("req-1", ` / `);` wrapper can be stripped directly, isolating
    /// exactly the JSON text produced from `dangerousContent` for a real round-trip decode.
    @Test func resolveScriptSafelyEscapesQuotesNewlinesAndBackticksInContent() throws {
        let dangerousContent = "line one\nline two with \"quotes\" and a ` backtick"
        let payload = CodePaneBridge.FileReadPayload(content: dangerousContent, sha256: "sha", size: dangerousContent.utf8.count)

        let script = try #require(CodePaneBridge.resolveScript(id: "req-1", result: payload))

        let resultJSON = try #require(stripped(script, prefix: #"window.__spacesBridge.resolve("req-1", "#, suffix: ");"))
        struct DecodedFileReadPayload: Decodable {
            let content: String
            let sha256: String
            let size: Int
        }
        let decoded = try JSONDecoder().decode(DecodedFileReadPayload.self, from: Data(resultJSON.utf8))
        #expect(decoded.content == dangerousContent)
    }

    @Test func rejectScriptSafelyEscapesQuotesAndNewlinesInTheErrorMessage() throws {
        let dangerousMessage = "failed: \"bad\"\nsecond line with a ` backtick"
        let script = CodePaneBridge.rejectScript(id: "req-1", error: CodePaneBridge.BridgeError(code: .internalError, message: dangerousMessage))

        let errorJSON = try #require(stripped(script, prefix: #"window.__spacesBridge.reject("req-1", "#, suffix: ");"))
        struct DecodedError: Decodable {
            let code: String
            let message: String
        }
        let decoded = try JSONDecoder().decode(DecodedError.self, from: Data(errorJSON.utf8))
        #expect(decoded.message == dangerousMessage)
        #expect(decoded.code == "internalError")
    }

    @Test func dispatchEventScriptSafelyEscapesQuotesAndBackticksInTheEventDetail() throws {
        // The event name is always a host-controlled constant in practice; the risk this covers
        // is entirely on the detail side, so it exercises a value with the same dangerous
        // characters instead.
        let script = try #require(
            CodePaneBridge.dispatchEventScript(name: "spaces:diffSignature", detail: CodePaneBridge.DiffSignaturePayload(scopeSignature: "a\"b`c\nd"))
        )

        let detailJSON = try #require(
            stripped(script, prefix: #"window.dispatchEvent(new CustomEvent("spaces:diffSignature", {detail: "#, suffix: "}));"))
        struct DecodedDiffSignaturePayload: Decodable { let scopeSignature: String }
        let decoded = try JSONDecoder().decode(DecodedDiffSignaturePayload.self, from: Data(detailJSON.utf8))
        #expect(decoded.scopeSignature == "a\"b`c\nd")
    }

    // MARK: - FileSignaturePayload encoding

    @Test func fileSignaturePayloadOmitsSha256WhenMissingIsTrue() throws {
        let payload = CodePaneBridge.FileSignaturePayload(path: "foo.ts", sha256: nil, missing: true)

        let data = try JSONEncoder().encode(payload)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["path"] as? String == "foo.ts")
        #expect(json["missing"] as? Bool == true)
        #expect(json["sha256"] == nil, "sha256 must be omitted (not sent as JSON null) when the file is missing")
    }

    @Test func fileSignaturePayloadIncludesSha256WhenPresent() throws {
        let payload = CodePaneBridge.FileSignaturePayload(path: "foo.ts", sha256: "sha-1", missing: false)

        let data = try JSONEncoder().encode(payload)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["path"] as? String == "foo.ts")
        #expect(json["sha256"] as? String == "sha-1")
        #expect(json["missing"] as? Bool == false)
    }

    @Test func dispatchEventScriptSafelyEscapesQuotesInAFileSignaturePayloadsPath() throws {
        let script = try #require(
            CodePaneBridge.dispatchEventScript(
                name: "spaces:fileSignature", detail: CodePaneBridge.FileSignaturePayload(path: "a\"b`c\nd", sha256: "sha-1", missing: false)))

        let detailJSON = try #require(
            stripped(script, prefix: #"window.dispatchEvent(new CustomEvent("spaces:fileSignature", {detail: "#, suffix: "}));"))
        struct DecodedFileSignaturePayload: Decodable { let path: String }
        let decoded = try JSONDecoder().decode(DecodedFileSignaturePayload.self, from: Data(detailJSON.utf8))
        #expect(decoded.path == "a\"b`c\nd")
    }

}

// MARK: - Result convenience

extension Result where Failure == CodePaneBridge.BridgeError {
    fileprivate var isInvalidArgumentFailure: Bool {
        guard case .failure(let error) = self else { return false }
        return error.code == .invalidArgument
    }
}

/// Strips a known literal prefix/suffix off `text`, or `nil` if either isn't present — used to pull
/// the JSON argument back out of a generated script for a round-trip decode.
private func stripped(_ text: String, prefix: String, suffix: String) -> String? {
    guard text.hasPrefix(prefix), text.hasSuffix(suffix) else { return nil }
    return String(text.dropFirst(prefix.count).dropLast(suffix.count))
}
