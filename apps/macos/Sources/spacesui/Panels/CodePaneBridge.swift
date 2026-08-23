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
        guard let dict = body as? [String: Any], let id = dict["id"] as? String, let method = dict["method"] as? String else {
            return nil
        }
        return Request(id: id, method: method, params: dict["params"] as? [String: Any] ?? [:])
    }

    /// Whether a message body is the fire-and-forget `{method:"ready"}` lifecycle notification
    /// (no `id`, so it is never a `Request`).
    static func isReady(body: Any) -> Bool {
        guard let dict = body as? [String: Any] else { return false }
        return dict["id"] == nil && dict["method"] as? String == "ready"
    }

    /// One editor's open-file snapshot: the wire shape of `editorStateChanged`'s `params` and of
    /// `InitPayload`'s `editorState` field. Kept small and focused (path/hash/content/dirty only)
    /// since Phase 5's merge model builds on this same snapshot.
    struct EditorState: Codable, Equatable {
        let path: String
        let baseSHA256: String
        let content: String
        let dirty: Bool
    }

    /// Evaluated by `CodePaneContentController.flushPendingEditorState()` at teardown to pull the web
    /// app's live editor snapshot synchronously via the evaluate return value (see
    /// `CodePaneScriptEvaluator.evaluateCodePaneScript(_:completion:)`), bypassing
    /// `scheduleEditorStatePush`'s trailing debounce window entirely — the flush reads the editor's
    /// live fields directly rather than waiting on the same timer that can otherwise still be pending
    /// when a tab or workspace switch tears the page down. `typeof` distinguishes a page that hasn't
    /// finished its own bootstrap yet (the global isn't defined — answers the `'__uninstalled__'`
    /// sentinel) from an installed collector's own explicit "nothing open" answer (`null`, coalesced to
    /// the `'__no_file__'` sentinel) — see `CollectedEditorState` for why that distinction matters.
    static let collectEditorStateScript =
        "typeof window.__spacesCollectEditorState === 'function' ? (window.__spacesCollectEditorState() ?? '__no_file__') : '__uninstalled__'"

    /// Result of decoding a teardown flush's collect-script return value (see
    /// `collectEditorStateScript`). Three-way, not two-way: a pane reactivated with a dirty retained
    /// buffer can be hibernated again before the bundle's JS finishes re-bootstrapping, so a teardown
    /// flush can land before `__spacesCollectEditorState` even exists — that must NOT be treated as
    /// "no file", or it would wipe the real snapshot the host is holding from the prior hibernation.
    /// - `.notReported`: the page never got far enough to answer (collector not installed yet), or the
    ///   evaluate call itself failed (folds to a `nil` result — see `CodePaneScriptEvaluator`'s doc
    ///   comment), or the answer was a string that isn't one of the two sentinels and isn't valid JSON
    ///   either (only this host's own trusted JS ever produces this argument, so this is purely
    ///   defensive). The caller must leave whatever snapshot it already has untouched: worst case a
    ///   stale snapshot survives a genuinely-now-empty page (harmless — restore just re-renders it),
    ///   but destroying a real unsaved edit because the page hadn't booted yet is strictly worse.
    /// - `.noFile`: an installed collector's own explicit "nothing open" answer. Clearing the stored
    ///   snapshot for this case is correct.
    /// - `.file`: the given state should be stored.
    enum CollectedEditorState: Equatable {
        case notReported
        case noFile
        case file(EditorState)
    }

    /// Decodes a teardown flush's collect-script return value into `CollectedEditorState`. See that
    /// type's doc comment for the three-way split this enforces: only the `'__no_file__'` sentinel
    /// (an installed collector's own explicit answer) maps to `.noFile` — everything else that isn't
    /// well-formed `EditorState` JSON, including the `'__uninstalled__'` sentinel and a non-String
    /// result (`nil`, or any other type — this is also what an evaluate error folds into), maps to
    /// `.notReported`.
    static func decodeCollectedEditorState(_ result: Any?) -> CollectedEditorState {
        guard let jsonString = result as? String else { return .notReported }
        if jsonString == "__uninstalled__" { return .notReported }
        if jsonString == "__no_file__" { return .noFile }
        guard let data = jsonString.data(using: .utf8), let state = try? JSONDecoder().decode(EditorState.self, from: data) else {
            return .notReported
        }
        return .file(state)
    }

    /// round-16 Fix 1a: one entry in a teardown comment-state snapshot, mirroring
    /// `CodePaneWeb/src/bridge/types.ts`'s `PendingReviewCommentEntry` exactly. The wire shape of both
    /// `collectReviewCommentStateScript`'s JSON entries and `InitPayload.pendingReviewComments`.
    struct ReviewCommentEntryPayload: Codable, Equatable {
        let id: String
        let provisional: Bool
        let filePath: String
        let side: SpacesDeviceReviewCommentSide
        let lineNumber: Int
        let lineText: String
        let body: String
    }

    /// Evaluated by `CodePaneContentController.flushPendingReviewCommentState()` at teardown — mirrors
    /// `collectEditorStateScript` exactly (see its doc comment for the `typeof`/sentinel reasoning),
    /// but for the comment surface: `'__none__'` is this method's "nothing pending" sentinel, standing
    /// in for `collectEditorStateScript`'s `'__no_file__'`.
    static let collectReviewCommentStateScript =
        "typeof window.__spacesCollectReviewCommentState === 'function' ? (window.__spacesCollectReviewCommentState() ?? '__none__') : '__uninstalled__'"

    /// Result of decoding a teardown flush's comment-state collect-script return value — mirrors
    /// `CollectedEditorState` exactly (see its doc comment for the three-way discipline this
    /// enforces), with `.none` (the `'__none__'` sentinel) standing in for `.noFile`.
    enum CollectedReviewCommentState: Equatable {
        case notReported
        case none
        case entries([ReviewCommentEntryPayload])
    }

    /// Decodes a teardown flush's comment-state collect-script return value into
    /// `CollectedReviewCommentState` — mirrors `decodeCollectedEditorState` exactly, substituting the
    /// `'__none__'` sentinel for `'__no_file__'` and a JSON array for a single JSON object.
    static func decodeCollectedReviewCommentState(_ result: Any?) -> CollectedReviewCommentState {
        guard let jsonString = result as? String else { return .notReported }
        if jsonString == "__uninstalled__" { return .notReported }
        if jsonString == "__none__" { return .none }
        guard let data = jsonString.data(using: .utf8),
            let entries = try? JSONDecoder().decode([ReviewCommentEntryPayload].self, from: data)
        else {
            return .notReported
        }
        return .entries(entries)
    }

    /// Result of decoding a message body as the fire-and-forget `editorStateChanged` notification
    /// (see `CodePaneWeb/README.md`'s wire protocol).
    enum EditorStateChangedMessage: Equatable {
        /// The body isn't this message at all (wrong method, or has an `id` and so is an RPC
        /// `Request` instead) — the caller should try decoding it as something else.
        case notThisMessage
        /// The editor has no open file: `params` was `null`/absent (or, defensively, malformed).
        case noFile
        case file(EditorState)
    }

    /// Decodes a `{method:"editorStateChanged", params}` notification body.
    static func decodeEditorStateChanged(body: Any) -> EditorStateChangedMessage {
        guard let dict = body as? [String: Any], dict["id"] == nil, dict["method"] as? String == "editorStateChanged" else {
            return .notThisMessage
        }
        guard let params = dict["params"] as? [String: Any], !params.isEmpty else { return .noFile }
        guard let path = params["path"] as? String, let baseSHA256 = params["baseSHA256"] as? String,
            let content = params["content"] as? String, let dirty = params["dirty"] as? Bool
        else { return .noFile }
        return .file(EditorState(path: path, baseSHA256: baseSHA256, content: content, dirty: dirty))
    }

    /// Decodes a `{method:"modeChanged", params:{mode}}` notification body: the web app's push
    /// whenever the user toggles the in-page Diff/Editor toolbar, so the host can restore the pane
    /// to its live mode (not just the mode it was originally opened in) after hibernation. `nil`
    /// when the body isn't this message, or `params.mode` isn't a recognized value.
    static func decodeModeChanged(body: Any) -> String? {
        guard let dict = body as? [String: Any], dict["id"] == nil, dict["method"] as? String == "modeChanged",
            let params = dict["params"] as? [String: Any], let mode = params["mode"] as? String, mode == "diff" || mode == "editor"
        else { return nil }
        return mode
    }

    // MARK: - Diff scope

    /// The three `DiffScope` kinds `CodePaneWeb/src/bridge/types.ts` defines.
    enum DiffScope: Equatable {
        case uncommitted
        case baseBranch
        case ref(String)
    }

    /// Decodes a `DiffScope` from its wire shape: `{kind:"uncommitted"}`, `{kind:"baseBranch"}`, or
    /// `{kind:"ref", refName}`.
    static func decodeDiffScope(_ value: Any?) -> Result<DiffScope, BridgeError> {
        guard let dict = value as? [String: Any], let kind = dict["kind"] as? String else {
            return .failure(BridgeError(code: .invalidArgument, message: "Missing or invalid diff scope."))
        }
        switch kind {
        case "uncommitted":
            return .success(.uncommitted)
        case "baseBranch":
            return .success(.baseBranch)
        case "ref":
            guard let refName = dict["refName"] as? String, !refName.isEmpty else {
                return .failure(BridgeError(code: .invalidArgument, message: "A \"ref\" scope requires a non-empty refName."))
            }
            return .success(.ref(refName))
        default:
            return .failure(BridgeError(code: .invalidArgument, message: "Unknown diff scope kind \"\(kind)\"."))
        }
    }

    /// Resolves a `DiffScope` to the `refName` argument `workspaceDiff`/`subscribeWorkspaceDiffSignature`
    /// take: `nil` for uncommitted-vs-HEAD, the workspace's configured base branch for `.baseBranch`
    /// (rejected if the workspace has none), or the literal ref/SHA text for `.ref`.
    static func refName(for scope: DiffScope, workspaceBaseBranch: String?) -> Result<String?, BridgeError> {
        switch scope {
        case .uncommitted:
            return .success(nil)
        case .ref(let refName):
            return .success(refName)
        case .baseBranch:
            guard let workspaceBaseBranch, !workspaceBaseBranch.isEmpty else {
                return .failure(BridgeError(code: .invalidArgument, message: "This workspace has no base branch configured."))
            }
            return .success(workspaceBaseBranch)
        }
    }

    // MARK: - RPC-to-client-call mapping

    /// What a decoded `Request` asks the host to do, in terms independent of `SpacesDeviceClient` —
    /// this is the pure "which call, with which arguments" mapping, so it's testable without a
    /// live device or network. `CodePaneContentController` switches over this to make the actual
    /// client call.
    enum Plan: Equatable {
        case workspaceDiff(scope: DiffScope)
        case workspaceFileRead(path: String)
        case workspaceFileWrite(path: String, content: String, baseSHA256: String)
        /// Decodes successfully (the params are well-formed) but has no daemon endpoint yet; the
        /// controller always replies `unavailable` for this rather than attempting a client call.
        case workspaceFileList
        case reviewCommentList
        /// `commentID` is `nil` for a new draft — the daemon mints its id — or names an existing
        /// draft this workspace owns when the web app is editing one.
        case reviewCommentUpsert(
            commentID: String?, filePath: String, side: SpacesDeviceReviewCommentSide, lineNumber: Int, lineText: String, body: String)
        case reviewCommentDelete(commentID: String)
        /// `comments` pairs each id with the `revision` the web app's local mirror last saw for it —
        /// the daemon's stale-version check (see `SpacesDeviceWorkspaceReviewCommentsSendRequest`).
        case reviewCommentsSend(sessionID: String, text: String, comments: [SpacesDeviceReviewCommentSendEntry])
    }

    /// Maps a decoded request to a `Plan`, or a `BridgeError` if its method is unrecognized or its
    /// params are missing/malformed. An unknown method is rejected with `invalidArgument`.
    static func plan(for request: Request) -> Result<Plan, BridgeError> {
        switch request.method {
        case "workspaceDiff":
            return decodeDiffScope(request.params["scope"]).map { .workspaceDiff(scope: $0) }
        case "workspaceFileRead":
            guard let path = request.params["path"] as? String else {
                return .failure(BridgeError(code: .invalidArgument, message: "workspaceFileRead requires a path."))
            }
            return .success(.workspaceFileRead(path: path))
        case "workspaceFileWrite":
            guard let path = request.params["path"] as? String, let content = request.params["content"] as? String,
                let options = request.params["options"] as? [String: Any], let baseSHA256 = options["baseSHA256"] as? String
            else {
                return .failure(
                    BridgeError(code: .invalidArgument, message: "workspaceFileWrite requires a path, content, and options.baseSHA256."))
            }
            return .success(.workspaceFileWrite(path: path, content: content, baseSHA256: baseSHA256))
        case "workspaceFileList":
            return .success(.workspaceFileList)
        case "reviewCommentList":
            return .success(.reviewCommentList)
        case "reviewCommentUpsert":
            guard let filePath = request.params["filePath"] as? String, let sideRaw = request.params["side"] as? String,
                let side = SpacesDeviceReviewCommentSide(rawValue: sideRaw), let lineNumber = request.params["lineNumber"] as? Int,
                let lineText = request.params["lineText"] as? String, let body = request.params["body"] as? String
            else {
                return .failure(
                    BridgeError(
                        code: .invalidArgument, message: "reviewCommentUpsert requires filePath, side, lineNumber, lineText, and body."))
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
                    return .failure(
                        BridgeError(code: .invalidArgument, message: "Each reviewCommentsSend entry requires an id and revision."))
                }
                comments.append(SpacesDeviceReviewCommentSendEntry(id: id, revision: revision))
            }
            return .success(.reviewCommentsSend(sessionID: sessionID, text: text, comments: comments))
        default:
            return .failure(BridgeError(code: .invalidArgument, message: "Unknown method \"\(request.method)\"."))
        }
    }

    // MARK: - Client error mapping

    /// Maps any error thrown by a `SpacesDeviceClient` call to the bridge's five-code error shape.
    /// A CAS write conflict is never routed through here — it's a normal typed result
    /// (`{conflict:true, currentSHA256}`), not a thrown error; see `fileWritePayload`.
    static func mapClientError(_ error: Error) -> BridgeError {
        guard let clientError = error as? SpacesDeviceClientError else {
            return BridgeError(code: .unavailable, message: error.localizedDescription)
        }
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
        case .notFound:
            return .notFound
        case .invalidArgument, .ownershipRejected, .payloadTooLarge, .unsupportedFormat:
            return .invalidArgument
        case .conflict:
            return .conflict
        case .internalError:
            return .internalError
        case .unauthorized, .sessionNotRunning, .sessionNotAvailable, .serviceNotRunning, .busy, .capabilityMissing, .misroutedRequest,
            .shuttingDown, .handingOff:
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
    }

    static func fileReadPayload(_ result: SpacesDeviceWorkspaceFileReadResult) -> Result<FileReadPayload, BridgeError> {
        guard !result.isBinaryGuess, let data = Data(base64Encoded: result.base64Data), let content = String(data: data, encoding: .utf8) else {
            return .failure(BridgeError(code: .invalidArgument, message: "This file cannot be opened as text."))
        }
        return .success(FileReadPayload(content: content, sha256: result.sha256, size: result.size))
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
        if result.didWrite {
            return .success(FileWritePayload(ok: true, conflict: nil, currentSHA256: nil, fileMissing: nil, sha256: result.sha256))
        }
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

    private struct ErrorPayload: Encodable { let code: String; let message: String }

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
        struct Scope: Encodable, Equatable {
            let kind: String
            let refName: String?
        }
        let workspaceId: String
        let workspaceName: String
        let initialMode: String
        let initialScope: Scope
        let theme: String
        /// The workspace's configured base branch, nil-omitted when it has none. Lets the toolbar
        /// disable (and, where it labels segments, name) the "vs base branch" scope instead of
        /// always offering an option `refName(for:)` is guaranteed to reject.
        let baseBranch: String?
        /// The host-held editor-state snapshot from before this pane's most recent hibernation
        /// cycle, nil-omitted when there is none (a pane's first-ever load, or one whose editor
        /// never opened a file). See `CodePaneContentController.editorState`'s doc comment for the
        /// persistence model this rehydrates.
        let editorState: EditorState?
        /// round-16 Fix 1a: the host-held snapshot of comment text typed but not yet persisted before
        /// this pane's most recent teardown, nil-omitted when there is none. See
        /// `CodePaneContentController.pendingReviewCommentState`'s doc comment for the persistence
        /// model this rehydrates — mirrors `editorState` above but for the comment surface.
        let pendingReviewComments: [ReviewCommentEntryPayload]?
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

    /// `spaces:diffSignature`'s detail, dispatched whenever the subscribed scope's git state changes.
    struct DiffSignaturePayload: Encodable, Equatable { let scopeSignature: String }

    /// `spaces:agents`'s detail, dispatched whenever this workspace's running-agent set changes after
    /// startup (`spaces:init`'s `agents` field carries the set at page-load time).
    struct AgentsPayload: Encodable, Equatable { let agents: [AgentPayload] }

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
    /// flush's collect script (see `CodePaneBridge.collectEditorStateScript`) is this method's only
    /// caller. `evaluateCodePaneScript(_:)` above is fire-and-forget and cannot answer.
    func evaluateCodePaneScript(_ script: String, completion: @escaping @MainActor (Any?) -> Void)
}

extension WKWebView: CodePaneScriptEvaluator {
    func evaluateCodePaneScript(_ script: String) { evaluateJavaScript(script, completionHandler: nil) }
    /// `evaluateJavaScript(_:completionHandler:)`'s completion handler is documented to run on the
    /// main thread, so `assumeIsolated` is a safe (non-crashing) bridge from that non-isolated
    /// callback type back onto the actor this protocol otherwise requires. A genuine JS error folds
    /// into a `nil` result rather than being surfaced separately — see `CollectedEditorState`'s doc
    /// comment for why its only caller treats that identically to the page answering `null`.
    func evaluateCodePaneScript(_ script: String, completion: @escaping @MainActor (Any?) -> Void) {
        evaluateJavaScript(script) { result, _ in
            MainActor.assumeIsolated { completion(result) }
        }
    }
}
