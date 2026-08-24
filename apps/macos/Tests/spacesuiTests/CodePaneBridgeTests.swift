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
    @Test func decodeRequestRejectsABodyMissingId() {
        #expect(CodePaneBridge.decodeRequest(body: ["method": "workspaceFileList"]) == nil)
    }

    @Test func decodeRequestRejectsABodyMissingMethod() {
        #expect(CodePaneBridge.decodeRequest(body: ["id": "1"]) == nil)
    }

    @Test func decodeRequestRejectsANonStringId() {
        #expect(CodePaneBridge.decodeRequest(body: ["id": 1, "method": "workspaceFileList"]) == nil)
    }

    @Test func decodeRequestRejectsNonDictionaryBody() {
        #expect(CodePaneBridge.decodeRequest(body: "not a dictionary") == nil)
    }

    @Test func isReadyRecognizesTheFireAndForgetNotification() {
        #expect(CodePaneBridge.isReady(body: ["method": "ready"]))
    }

    @Test func isReadyRejectsAnythingWithAnId() {
        #expect(!CodePaneBridge.isReady(body: ["id": "1", "method": "ready"]))
    }

    @Test func isReadyRejectsOtherMethods() {
        #expect(!CodePaneBridge.isReady(body: ["method": "workspaceFileList"]))
    }

    // MARK: - Diff scope decode

    @Test func decodeDiffScopeUncommitted() {
        #expect(CodePaneBridge.decodeDiffScope(["kind": "uncommitted"]) == .success(.uncommitted))
    }

    @Test func decodeDiffScopeBaseBranch() {
        #expect(CodePaneBridge.decodeDiffScope(["kind": "baseBranch"]) == .success(.baseBranch))
    }

    @Test func decodeDiffScopeRef() {
        #expect(CodePaneBridge.decodeDiffScope(["kind": "ref", "refName": "main"]) == .success(.ref("main")))
    }

    @Test func decodeDiffScopeRefRequiresANonEmptyRefName() {
        let result = CodePaneBridge.decodeDiffScope(["kind": "ref", "refName": ""])
        #expect(result.isInvalidArgumentFailure)
    }

    @Test func decodeDiffScopeRefRequiresARefNameAtAll() {
        let result = CodePaneBridge.decodeDiffScope(["kind": "ref"])
        #expect(result.isInvalidArgumentFailure)
    }

    @Test func decodeDiffScopeRejectsUnknownKind() {
        #expect(CodePaneBridge.decodeDiffScope(["kind": "bogus"]).isInvalidArgumentFailure)
    }

    @Test func decodeDiffScopeRejectsNonDictionary() {
        #expect(CodePaneBridge.decodeDiffScope("uncommitted").isInvalidArgumentFailure)
    }

    @Test func decodeDiffScopeRejectsNil() {
        #expect(CodePaneBridge.decodeDiffScope(nil).isInvalidArgumentFailure)
    }

    // MARK: - refName resolution

    @Test func refNameForUncommittedIsNil() {
        #expect(CodePaneBridge.refName(for: .uncommitted, workspaceBaseBranch: "main") == .success(nil))
    }

    @Test func refNameForRefIsTheLiteralRef() {
        #expect(CodePaneBridge.refName(for: .ref("feature/x"), workspaceBaseBranch: nil) == .success("feature/x"))
    }

    @Test func refNameForBaseBranchUsesTheWorkspacesConfiguredBranch() {
        #expect(CodePaneBridge.refName(for: .baseBranch, workspaceBaseBranch: "develop") == .success("develop"))
    }

    @Test func refNameForBaseBranchFailsWithoutOne() {
        #expect(CodePaneBridge.refName(for: .baseBranch, workspaceBaseBranch: nil).isInvalidArgumentFailure)
        #expect(CodePaneBridge.refName(for: .baseBranch, workspaceBaseBranch: "").isInvalidArgumentFailure)
    }

    // MARK: - InitPayload base branch encoding (round-4 Fix 5)

    /// The toolbar disables (rather than hides) the "vs base branch" option based on whether this
    /// key is present at all, so it must encode when the workspace has one...
    @Test func initPayloadEncodesBaseBranchWhenPresent() throws {
        let payload = CodePaneBridge.InitPayload(
            workspaceId: "w1", workspaceName: "My Workspace", initialMode: "diff",
            initialScope: .init(kind: "uncommitted", refName: nil), theme: "dark", baseBranch: "main", editorState: nil,
            pendingReviewComments: nil, agents: [])

        let data = try JSONEncoder().encode(payload)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["baseBranch"] as? String == "main")
    }

    /// ...and must be omitted entirely (not `"baseBranch":null`) when it has none, matching every
    /// other nil-omitted field in this payload.
    @Test func initPayloadOmitsBaseBranchKeyWhenAbsent() throws {
        let payload = CodePaneBridge.InitPayload(
            workspaceId: "w1", workspaceName: "My Workspace", initialMode: "diff",
            initialScope: .init(kind: "uncommitted", refName: nil), theme: "dark", baseBranch: nil, editorState: nil,
            pendingReviewComments: nil, agents: [])

        let data = try JSONEncoder().encode(payload)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["baseBranch"] == nil)
    }

    // MARK: - InitPayload editorState encoding (round-5 hibernation fix)

    /// Mirrors the base-branch nil-omission tests above: the web side distinguishes "no snapshot to
    /// restore" from "restore this snapshot" by whether the `editorState` key is present at all.
    @Test func initPayloadOmitsEditorStateKeyWhenAbsent() throws {
        let payload = CodePaneBridge.InitPayload(
            workspaceId: "w1", workspaceName: "My Workspace", initialMode: "diff",
            initialScope: .init(kind: "uncommitted", refName: nil), theme: "dark", baseBranch: nil, editorState: nil,
            pendingReviewComments: nil, agents: [])

        let data = try JSONEncoder().encode(payload)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["editorState"] == nil)
    }

    @Test func initPayloadEncodesEditorStateWhenPresent() throws {
        let state = CodePaneBridge.EditorState(path: "a.swift", baseSHA256: "sha-1", baseContent: "let x = 1", content: "let x = 1", dirty: true)
        let payload = CodePaneBridge.InitPayload(
            workspaceId: "w1", workspaceName: "My Workspace", initialMode: "editor",
            initialScope: .init(kind: "uncommitted", refName: nil), theme: "dark", baseBranch: nil, editorState: state,
            pendingReviewComments: nil, agents: [])

        let data = try JSONEncoder().encode(payload)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let editorState = try #require(json["editorState"] as? [String: Any])
        #expect(editorState["path"] as? String == "a.swift")
        #expect(editorState["baseSHA256"] as? String == "sha-1")
        #expect(editorState["baseContent"] as? String == "let x = 1")
        #expect(editorState["content"] as? String == "let x = 1")
        #expect(editorState["dirty"] as? Bool == true)
        #expect(editorState["conflict"] as? Bool == false)
    }

    // MARK: - editorStateChanged decode (round-5 hibernation fix)

    @Test func decodeEditorStateChangedParsesAFileSnapshot() {
        let message = CodePaneBridge.decodeEditorStateChanged(
            body: [
                "method": "editorStateChanged",
                "params": ["path": "a.swift", "baseSHA256": "sha-1", "baseContent": "let x = 0", "content": "let x = 1", "dirty": true],
            ])

        #expect(
            message
                == .file(
                    CodePaneBridge.EditorState(path: "a.swift", baseSHA256: "sha-1", baseContent: "let x = 0", content: "let x = 1", dirty: true)))
    }

    @Test func decodeEditorStateChangedParsesAConflictFlag() {
        let message = CodePaneBridge.decodeEditorStateChanged(
            body: [
                "method": "editorStateChanged",
                "params": [
                    "path": "a.swift", "baseSHA256": "sha-1", "baseContent": "let x = 0", "content": "let x = 1", "dirty": true, "conflict": true,
                ],
            ])

        #expect(
            message
                == .file(
                    CodePaneBridge.EditorState(
                        path: "a.swift", baseSHA256: "sha-1", baseContent: "let x = 0", content: "let x = 1", dirty: true, conflict: true)))
    }

    @Test func decodeEditorStateChangedDefaultsConflictToFalseWhenAbsent() {
        let message = CodePaneBridge.decodeEditorStateChanged(
            body: [
                "method": "editorStateChanged",
                "params": ["path": "a.swift", "baseSHA256": "sha-1", "baseContent": "let x = 0", "content": "let x = 1", "dirty": true],
            ])

        guard case .file(let state) = message else {
            Issue.record("expected a decoded file snapshot")
            return
        }
        #expect(state.conflict == false)
    }

    @Test func decodeEditorStateChangedTreatsNullParamsAsNoFile() {
        #expect(CodePaneBridge.decodeEditorStateChanged(body: ["method": "editorStateChanged", "params": NSNull()]) == .noFile)
    }

    @Test func decodeEditorStateChangedTreatsMissingParamsAsNoFile() {
        #expect(CodePaneBridge.decodeEditorStateChanged(body: ["method": "editorStateChanged"]) == .noFile)
    }

    @Test func decodeEditorStateChangedRejectsAnythingWithAnId() {
        #expect(
            CodePaneBridge.decodeEditorStateChanged(body: ["id": "1", "method": "editorStateChanged", "params": ["path": "a"]]) == .notThisMessage)
    }

    @Test func decodeEditorStateChangedRejectsOtherMethods() {
        #expect(CodePaneBridge.decodeEditorStateChanged(body: ["method": "ready"]) == .notThisMessage)
    }

    @Test func decodeEditorStateChangedTreatsIncompleteParamsAsNoFile() {
        #expect(CodePaneBridge.decodeEditorStateChanged(body: ["method": "editorStateChanged", "params": ["path": "a.swift"]]) == .noFile)
    }

    @Test func decodeEditorStateChangedTreatsMissingBaseContentAsNoFile() {
        #expect(
            CodePaneBridge.decodeEditorStateChanged(
                body: [
                    "method": "editorStateChanged", "params": ["path": "a.swift", "baseSHA256": "sha-1", "content": "let x = 1", "dirty": true],
                ]) == .noFile, "baseContent is required, mirroring the other snapshot fields")
    }

    // MARK: - modeChanged decode (round-5 hibernation fix)

    @Test func decodeModeChangedParsesDiffAndEditor() {
        #expect(CodePaneBridge.decodeModeChanged(body: ["method": "modeChanged", "params": ["mode": "editor"]]) == "editor")
        #expect(CodePaneBridge.decodeModeChanged(body: ["method": "modeChanged", "params": ["mode": "diff"]]) == "diff")
    }

    @Test func decodeModeChangedRejectsAnUnknownMode() {
        #expect(CodePaneBridge.decodeModeChanged(body: ["method": "modeChanged", "params": ["mode": "bogus"]]) == nil)
    }

    @Test func decodeModeChangedRejectsAnythingWithAnId() {
        #expect(CodePaneBridge.decodeModeChanged(body: ["id": "1", "method": "modeChanged", "params": ["mode": "editor"]]) == nil)
    }

    // MARK: - RPC-to-client-call mapping

    @Test func planForWorkspaceDiffDecodesItsScope() {
        let request = CodePaneBridge.Request(id: "1", method: "workspaceDiff", params: ["scope": ["kind": "uncommitted"]])

        #expect(CodePaneBridge.plan(for: request) == .success(.workspaceDiff(scope: .uncommitted)))
    }

    @Test func planForWorkspaceDiffPropagatesAScopeDecodeFailure() {
        let request = CodePaneBridge.Request(id: "1", method: "workspaceDiff", params: ["scope": ["kind": "bogus"]])

        #expect(CodePaneBridge.plan(for: request).isInvalidArgumentFailure)
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
            id: "1", method: "workspaceFileWrite",
            params: ["path": "src/a.swift", "content": "hi", "options": ["baseSHA256": "abc123"]])

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

    @Test func planForReviewCommentsSendDecodesEachEntrysIdAndRevision() {
        let request = CodePaneBridge.Request(
            id: "1", method: "reviewCommentsSend",
            params: [
                "sessionId": "agent-1", "text": "please fix",
                "comments": [["id": "c1", "revision": 0], ["id": "c2", "revision": 2]],
            ])

        #expect(
            CodePaneBridge.plan(for: request)
                == .success(
                    .reviewCommentsSend(
                        sessionID: "agent-1", text: "please fix",
                        comments: [
                            SpacesDeviceReviewCommentSendEntry(id: "c1", revision: 0),
                            SpacesDeviceReviewCommentSendEntry(id: "c2", revision: 2),
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

    @Test("mapClientError maps every SpacesDeviceErrorCode", arguments: [
        (SpacesDeviceErrorCode.notFound, CodePaneBridge.ErrorCode.notFound),
        (.invalidArgument, .invalidArgument),
        (.ownershipRejected, .invalidArgument),
        (.payloadTooLarge, .invalidArgument),
        (.unsupportedFormat, .invalidArgument),
        (.conflict, .conflict),
        (.internalError, .internalError),
        (.unauthorized, .unavailable),
        (.sessionNotRunning, .unavailable),
        (.sessionNotAvailable, .unavailable),
        (.serviceNotRunning, .unavailable),
        (.busy, .unavailable),
        (.capabilityMissing, .unavailable),
        (.misroutedRequest, .unavailable),
        (.shuttingDown, .unavailable),
        (.handingOff, .unavailable),
    ])
    func mapClientErrorMapsEveryDeviceErrorCode(deviceCode: SpacesDeviceErrorCode, bridgeCode: CodePaneBridge.ErrorCode) {
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
        let result = SpacesDeviceWorkspaceFileReadResult(base64Data: Data("hello".utf8).base64EncodedString(), sha256: "sha", size: 5, isBinaryGuess: false)

        #expect(CodePaneBridge.fileReadPayload(result) == .success(CodePaneBridge.FileReadPayload(content: "hello", sha256: "sha", size: 5)))
    }

    @Test func fileReadPayloadRejectsBinaryGuesses() {
        let result = SpacesDeviceWorkspaceFileReadResult(base64Data: Data("hello".utf8).base64EncodedString(), sha256: "sha", size: 5, isBinaryGuess: true)

        #expect(CodePaneBridge.fileReadPayload(result).isInvalidArgumentFailure)
    }

    @Test func fileReadPayloadRejectsNonUTF8Bytes() {
        let invalidUTF8 = Data([0xFF, 0xFE, 0xFD])
        let result = SpacesDeviceWorkspaceFileReadResult(base64Data: invalidUTF8.base64EncodedString(), sha256: "sha", size: 3, isBinaryGuess: false)

        #expect(CodePaneBridge.fileReadPayload(result).isInvalidArgumentFailure)
    }

    /// Round-4 Fix 1: a successful write's own hash rides along in the payload, so the client can
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
                == .success(
                    CodePaneBridge.FileWritePayload(ok: nil, conflict: true, currentSHA256: "current-sha", fileMissing: nil, sha256: nil)))
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
                id: "req-1",
                result: CodePaneBridge.FileWritePayload(ok: true, conflict: nil, currentSHA256: nil, fileMissing: nil, sha256: nil)))

        #expect(script == #"window.__spacesBridge.resolve("req-1", {"ok":true});"#)
    }

    /// The `fileMissing` conflict shape must encode without a `currentSHA256` key at all (nil-omission,
    /// not `"currentSHA256":null`) — the web side discriminates the two conflict shapes by whether
    /// that key is present.
    @Test func resolveScriptEncodesFileMissingConflictWithoutACurrentSHA256Key() throws {
        let script = try #require(
            CodePaneBridge.resolveScript(
                id: "req-1",
                result: CodePaneBridge.FileWritePayload(ok: nil, conflict: true, currentSHA256: nil, fileMissing: true, sha256: nil)))

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
        struct DecodedFileReadPayload: Decodable { let content: String; let sha256: String; let size: Int }
        let decoded = try JSONDecoder().decode(DecodedFileReadPayload.self, from: Data(resultJSON.utf8))
        #expect(decoded.content == dangerousContent)
    }

    @Test func rejectScriptSafelyEscapesQuotesAndNewlinesInTheErrorMessage() throws {
        let dangerousMessage = "failed: \"bad\"\nsecond line with a ` backtick"
        let script = CodePaneBridge.rejectScript(id: "req-1", error: CodePaneBridge.BridgeError(code: .internalError, message: dangerousMessage))

        let errorJSON = try #require(stripped(script, prefix: #"window.__spacesBridge.reject("req-1", "#, suffix: ");"))
        struct DecodedError: Decodable { let code: String; let message: String }
        let decoded = try JSONDecoder().decode(DecodedError.self, from: Data(errorJSON.utf8))
        #expect(decoded.message == dangerousMessage)
        #expect(decoded.code == "internalError")
    }

    @Test func dispatchEventScriptSafelyEscapesQuotesAndBackticksInTheEventDetail() throws {
        // The event name is always a host-controlled constant in practice; the risk this covers
        // is entirely on the detail side, so it exercises a value with the same dangerous
        // characters instead.
        let script = try #require(
            CodePaneBridge.dispatchEventScript(name: "spaces:diffSignature", detail: CodePaneBridge.DiffSignaturePayload(scopeSignature: "a\"b`c\nd")))

        let detailJSON = try #require(
            stripped(script, prefix: #"window.dispatchEvent(new CustomEvent("spaces:diffSignature", {detail: "#, suffix: "}));"))
        struct DecodedDiffSignaturePayload: Decodable { let scopeSignature: String }
        let decoded = try JSONDecoder().decode(DecodedDiffSignaturePayload.self, from: Data(detailJSON.utf8))
        #expect(decoded.scopeSignature == "a\"b`c\nd")
    }

    // MARK: - FileSignaturePayload encoding (Phase 5 Part A)

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

    // MARK: - Collected editor-state flush decode (round-6 Fix 1)

    @Test func decodeCollectedEditorStateParsesAJSONSnapshot() {
        let json = #"{"path":"foo.ts","baseSHA256":"sha","baseContent":"let x = 0;","content":"let x = 1;","dirty":true}"#

        #expect(
            CodePaneBridge.decodeCollectedEditorState(json)
                == .file(CodePaneBridge.EditorState(path: "foo.ts", baseSHA256: "sha", baseContent: "let x = 0;", content: "let x = 1;", dirty: true)))
    }

    @Test func decodeCollectedEditorStateParsesAConflictFlag() {
        let json = #"{"path":"foo.ts","baseSHA256":"sha","baseContent":"let x = 0;","content":"let x = 1;","dirty":true,"conflict":true}"#

        #expect(
            CodePaneBridge.decodeCollectedEditorState(json)
                == .file(
                    CodePaneBridge.EditorState(
                        path: "foo.ts", baseSHA256: "sha", baseContent: "let x = 0;", content: "let x = 1;", dirty: true, conflict: true)))
    }

    @Test func decodeCollectedEditorStateTreatsTheNoFileSentinelAsNoFile() {
        // `'__no_file__'` is an installed collector's own explicit "nothing open" answer — the only
        // case that should clear a stored snapshot.
        #expect(CodePaneBridge.decodeCollectedEditorState("__no_file__") == .noFile)
    }

    @Test func decodeCollectedEditorStateTreatsTheUninstalledSentinelAsNotReported() {
        // `'__uninstalled__'` means the page hasn't finished bootstrapping yet (the collector global
        // doesn't exist) — this must NOT be treated as "no file", or a teardown flush racing a
        // reactivate-then-hibernate cycle would wipe a real stored snapshot.
        #expect(CodePaneBridge.decodeCollectedEditorState("__uninstalled__") == .notReported)
    }

    @Test func decodeCollectedEditorStateTreatsNilAsNotReported() {
        // A nil result is what a genuine `evaluateJavaScript` error folds into (see
        // `CodePaneScriptEvaluator`'s doc comment) — indistinguishable from "didn't answer", so it must
        // leave the stored snapshot untouched rather than being read as "no file".
        #expect(CodePaneBridge.decodeCollectedEditorState(nil) == .notReported)
    }

    @Test func decodeCollectedEditorStateTreatsAMalformedStringAsNotReported() {
        #expect(CodePaneBridge.decodeCollectedEditorState("not json") == .notReported)
    }

    @Test func decodeCollectedEditorStateTreatsANonStringResultAsNotReported() {
        // `evaluateJavaScript`'s completion can hand back other JS value types (numbers, booleans);
        // the collect script's contract only ever produces one of the two sentinel strings or a JSON
        // snapshot string, so anything else is treated the same defensive way a malformed string is.
        #expect(CodePaneBridge.decodeCollectedEditorState(42) == .notReported)
    }

    // MARK: - Collected review-comment-state flush decode (round-16 Fix 1a)

    /// Mirrors `decodeCollectedEditorStateParsesAJSONSnapshot` exactly, for the comment surface's
    /// array-of-entries shape instead of a single file snapshot.
    @Test func decodeCollectedReviewCommentStateParsesAJSONSnapshot() {
        let json = #"[{"id":"c1","provisional":false,"filePath":"a.ts","side":"new","lineNumber":3,"lineText":"x","body":"hi"}]"#

        #expect(
            CodePaneBridge.decodeCollectedReviewCommentState(json)
                == .entries([
                    CodePaneBridge.ReviewCommentEntryPayload(
                        id: "c1", provisional: false, filePath: "a.ts", side: .new, lineNumber: 3, lineText: "x", body: "hi")
                ]))
    }

    @Test func decodeCollectedReviewCommentStateTreatsTheNoneSentinelAsNone() {
        // `'__none__'` is an installed collector's own explicit "nothing pending" answer — the only
        // case that should clear a stored snapshot. Mirrors `'__no_file__'` for the editor surface.
        #expect(CodePaneBridge.decodeCollectedReviewCommentState("__none__") == .none)
    }

    @Test func decodeCollectedReviewCommentStateTreatsTheUninstalledSentinelAsNotReported() {
        // Mirrors `decodeCollectedEditorStateTreatsTheUninstalledSentinelAsNotReported`: this must NOT
        // be treated as "nothing pending", or a teardown flush racing a reactivate-then-hibernate cycle
        // would wipe a real stored snapshot.
        #expect(CodePaneBridge.decodeCollectedReviewCommentState("__uninstalled__") == .notReported)
    }

    @Test func decodeCollectedReviewCommentStateTreatsNilAsNotReported() {
        // A nil result is what a genuine `evaluateJavaScript` error folds into (see
        // `CodePaneScriptEvaluator`'s doc comment) — indistinguishable from "didn't answer", so it must
        // leave the stored snapshot untouched rather than being read as "nothing pending".
        #expect(CodePaneBridge.decodeCollectedReviewCommentState(nil) == .notReported)
    }

    @Test func decodeCollectedReviewCommentStateTreatsAMalformedStringAsNotReported() {
        #expect(CodePaneBridge.decodeCollectedReviewCommentState("not json") == .notReported)
    }

    @Test func decodeCollectedReviewCommentStateTreatsANonStringResultAsNotReported() {
        // Mirrors `decodeCollectedEditorStateTreatsANonStringResultAsNotReported`: anything other than
        // a sentinel or a JSON array string is treated the same defensive way a malformed string is.
        #expect(CodePaneBridge.decodeCollectedReviewCommentState(42) == .notReported)
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
