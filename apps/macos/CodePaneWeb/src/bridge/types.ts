/**
 * The `window.spaces` bridge contract.
 *
 * This is the only surface the code pane plugin talks to the host through.
 * Two implementations exist:
 *   - `realBridge.ts` — bridges to `window.webkit.messageHandlers`, for the
 *     WKWebView the Swift host actually runs the plugin in.
 *   - `mockBridge.ts` — an in-memory implementation over static fixtures, for
 *     the `npm run dev` harness and for unit tests.
 *
 * See README.md for the wire protocol (message handler name, event names,
 * the init payload) that `realBridge.ts` assumes the Swift host implements.
 */

/** A file's change kind within a diff. Untracked files are reported as `untracked` and rendered as additions (no `oldFile` side). */
export type FileChangeStatus = "added" | "modified" | "deleted" | "renamed" | "untracked";

/**
 * What a diff is computed against. The task that specified this contract
 * sketched the wire shape as a loose `{ refName?: string }`; this bridge
 * models the three scope kinds explicitly as a discriminated union instead,
 * since an optional string can't unambiguously distinguish "uncommitted"
 * from "vs base branch" from "vs a specific ref". `refName` is present only
 * for `kind: "ref"`.
 */
export type DiffScope =
  | { kind: "uncommitted" }
  | { kind: "baseBranch" }
  | { kind: "ref"; refName: string };

/** One file entry in a `workspaceDiff` result. */
export interface DiffFileEntry {
  /** Workspace-relative path of the file's current (new) side. */
  path: string;
  /** Previous path, present only when `status` is `"renamed"`. */
  oldPath?: string;
  status: FileChangeStatus;
  /** Git unified diff patch text for this file. Absent when `isBinary` or `truncated` is true. */
  patch?: string;
  isBinary: boolean;
  /** True when the daemon capped the patch (e.g. an oversized generated file) and omitted `patch`. */
  truncated: boolean;
  oldSHA?: string;
  newSHA?: string;
}

export interface WorkspaceDiffResult {
  /** Opaque signature identifying this exact diff result. Changes whenever the underlying git state for this scope changes; used to detect staleness and to dedupe signature-change events. */
  scopeSignature: string;
  files: DiffFileEntry[];
}

export interface WorkspaceFileReadResult {
  content: string;
  sha256: string;
  size: number;
}

export interface WorkspaceFileWriteOptions {
  /**
   * The sha256 the caller last read. The write is rejected as a conflict if the file's current
   * sha256 no longer matches (compare-and-swap). `undefined` invokes the daemon's "create"
   * convention instead: the write succeeds only if nothing currently exists at `path`, and is
   * rejected as a conflict (with `currentSHA256`) if something does. This is what lets the
   * editor's conflict compare view's "Keep mine" action recreate a file that was deleted on disk
   * — there is no prior hash to compare against, only "did anyone else recreate it first".
   */
  baseSHA256: string | undefined;
}

export interface WorkspaceFileWriteOk {
  ok: true;
  /**
   * The daemon's sha256 of exactly what it just wrote. The caller adopts this directly as the next
   * CAS baseline instead of re-reading the file: the buffer the user sees is exactly what was
   * written, so the pair (buffer, write hash) is self-consistent by construction, and a re-read
   * racing another writer (e.g. an agent) in between would silently adopt that writer's hash while
   * keeping the user's own unsaved buffer — the next save would then pass CAS and overwrite it.
   */
  sha256: string;
}

export interface WorkspaceFileWriteConflict {
  conflict: true;
  /** Absent when `fileMissing` is set — a deleted file has no current hash to show. */
  currentSHA256?: string;
  /** The file was deleted on disk after it was last read; there is nothing to compare hashes against. */
  fileMissing?: true;
}

export type WorkspaceFileWriteResult = WorkspaceFileWriteOk | WorkspaceFileWriteConflict;

export interface WorkspaceFileListResult {
  paths: string[];
}

export interface DiffSignatureEvent {
  scopeSignature: string;
}

export type DiffSignatureListener = (event: DiffSignatureEvent) => void;

/**
 * One file's on-disk signature, pushed whenever the host detects it changed while the editor
 * has it open. `sha256` is `undefined` iff `missing` is `true` (the file was deleted on disk);
 * otherwise it is the disk content's current hash. This never carries the disk content itself —
 * the editor always does its own fresh `workspaceFileRead` to fetch it, so this event is just a
 * "go look" signal, not a data payload.
 */
export interface FileSignatureEvent {
  path: string;
  sha256: string | undefined;
  missing: boolean;
}

export type FileSignatureListener = (event: FileSignatureEvent) => void;

/** Unsubscribe function returned by `subscribeDiffSignature`/`subscribeFileSignature`. */
export type Unsubscribe = () => void;

/** One line's side within a diff: `"old"` is the deletion side, `"new"` is the addition side.
 *  `@pierre/diffs`' own `AnnotationSide`/`SelectionSide` types use `"deletions"`/`"additions"`
 *  instead — see `reviewComments.ts`'s `toAnnotationSide`/`fromAnnotationSide` for the mapping at
 *  the one boundary that needs it (diffView.ts). This bridge stays on the host's own vocabulary. */
export type ReviewCommentSide = "old" | "new";

/** A draft code-review comment anchored to one diff line. The daemon is the sole source of truth
 *  (see `SpacesBridge.reviewComment*` below) — there is no web-local draft store beyond in-memory
 *  render state pulled from `reviewCommentList` and kept in sync by local mutations. */
export interface SpacesReviewComment {
  id: string;
  filePath: string;
  side: ReviewCommentSide;
  lineNumber: number;
  /** The diff line's content at the moment this comment was created, used to re-anchor the
   *  comment against a live diff refresh (see `reviewComments.ts`'s `reanchorComments`). */
  lineText: string;
  body: string;
  createdAt: string;
  /** Monotonic edit counter, bumped by the daemon on every save. This is what `reviewCommentsSend`
   *  echoes back as the concurrency token (see `ReviewCommentSendEntry`) — not a timestamp, since the
   *  daemon's `updatedAt` has whole-second resolution and two edits within the same second wouldn't
   *  change it. There is no user-facing display of edit recency in v1, so no timestamp is carried here. */
  revision: number;
}

/** `reviewCommentUpsert`'s input: `id` omitted creates a new draft, present updates an existing one. */
export interface ReviewCommentUpsertInput {
  id?: string;
  filePath: string;
  side: ReviewCommentSide;
  lineNumber: number;
  lineText: string;
  body: string;
}

/** round-16 Fix 1a: one entry in a teardown comment-state snapshot — see
 *  `CommentsController.collectStateForFlush`/`restorePendingState` and `CodePaneInitPayload`'s
 *  `pendingReviewComments` field. `provisional` distinguishes a never-persisted local-only draft
 *  (recreated as a fresh local card on rehydrate) from a persisted draft whose live, unsaved text is
 *  merely seeded into the rehydrated controller's `liveBodies` ahead of `loadInitial()`. `body` is
 *  always the live, in-progress text at teardown, not the last-persisted value. */
export interface PendingReviewCommentEntry {
  id: string;
  provisional: boolean;
  filePath: string;
  side: ReviewCommentSide;
  lineNumber: number;
  lineText: string;
  body: string;
}

/** A running agent this pane's workspace can send comments to. */
export interface CodePaneAgentSummary {
  id: string;
  label: string;
  sessionId: string;
}

/** One comment named in a `reviewCommentsSend` call: its id plus the `revision` this caller last saw
 *  for it. The daemon compares this against the draft's current `revision` before sending anything,
 *  so a comment edited (by this client or another surface) since it was last read is rejected as a
 *  `conflict` instead of being sent with stale text. */
export interface ReviewCommentSendEntry {
  id: string;
  revision: number;
}

export type SpacesErrorCode = "notFound" | "invalidArgument" | "conflict" | "internalError" | "unavailable";

export interface SpacesErrorShape {
  code: SpacesErrorCode;
  message: string;
}

/** Every bridge call rejects with this (never a bare string or a generic Error), so callers can branch on `.code`. */
export class SpacesBridgeError extends Error implements SpacesErrorShape {
  readonly code: SpacesErrorCode;

  constructor(code: SpacesErrorCode, message: string) {
    super(message);
    this.name = "SpacesBridgeError";
    this.code = code;
  }

  static isSpacesBridgeError(value: unknown): value is SpacesBridgeError {
    return value instanceof SpacesBridgeError;
  }
}

export interface SpacesBridge {
  workspaceDiff(scope: DiffScope): Promise<WorkspaceDiffResult>;
  workspaceFileRead(path: string): Promise<WorkspaceFileReadResult>;
  workspaceFileWrite(path: string, content: string, options: WorkspaceFileWriteOptions): Promise<WorkspaceFileWriteResult>;
  /**
   * Pending: the daemon endpoint behind this does not exist yet (see
   * README.md open items). Real usage today goes through the mock only; the
   * shape is defined here so the Editor mode file picker has a stable
   * contract to build against ahead of the daemon side landing.
   */
  workspaceFileList(query: string): Promise<WorkspaceFileListResult>;
  /**
   * Subscribe to diff-signature-changed push events for a scope. The
   * returned function unsubscribes. Only one scope is observed at a time in
   * v1 (the code pane shows one scope at once), so a later call replaces the
   * earlier subscription's effective scope rather than layering multiple
   * live subscriptions — see README.md for the event-delivery mechanism.
   */
  subscribeDiffSignature(scope: DiffScope, listener: DiffSignatureListener): Unsubscribe;
  /**
   * Subscribe to file-signature-changed push events for the editor's currently open file. The
   * returned function unsubscribes. Only one path is observed at a time (mirroring
   * `subscribeDiffSignature`'s one-scope-at-a-time model) — the host decides which path the
   * underlying stream points at, driven by `workspaceFileRead` completions, so there is no
   * explicit subscribe/unsubscribe RPC here; see README.md for the event-delivery mechanism.
   */
  subscribeFileSignature(path: string, listener: FileSignatureListener): Unsubscribe;
  /**
   * Fire-and-forget push (like the startup `ready` notification — no reply): tells the host the
   * editor's current open-file snapshot, so it survives this pane's next hibernation cycle (see
   * README.md "Editor state survives hibernation"). `undefined` the moment the editor has no open
   * file. `EditorView` debounces this (~500ms trailing) on buffer edits and sends it immediately
   * on the discrete transitions (open, save, conflict) — see its call sites.
   */
  notifyEditorStateChanged(state: CodePaneEditorState | undefined): void;
  /**
   * Fire-and-forget push telling the host the pane's live mode, so a hibernated pane restores to
   * whichever mode the user last left it in rather than resetting to `initialMode`'s original
   * value.
   */
  notifyModeChanged(mode: CodePaneMode): void;
  /** All of this workspace's draft comments, ordered by `createdAt` (server-enforced). Called once
   *  on mount to rehydrate the comment surface — see `root.ts` and `reviewComments.ts`'s doc
   *  comments for why this is not re-fetched on every diff refresh. */
  reviewCommentList(): Promise<SpacesReviewComment[]>;
  /** Creates (no `id`) or updates (with `id`) one draft comment. Rejects `invalidArgument` if a
   *  required field is missing, `notFound` if `id` belongs to another workspace or already names a
   *  sent (non-draft) comment. */
  reviewCommentUpsert(input: ReviewCommentUpsertInput): Promise<SpacesReviewComment>;
  /** Deletes one draft comment. Rejects `notFound` for an unknown or foreign id. */
  reviewCommentDelete(id: string): Promise<void>;
  /**
   * Writes `text` into terminal session `sessionId` (must belong to this workspace and be running),
   * then — only once that write succeeds — marks every comment in `comments` (must be non-empty)
   * sent. The guarantee this gives is send-then-archive ordering: a comment is never archived unless
   * its text was actually sent. The converse isn't guaranteed (a daemon crash between the write and
   * the archive step would leave a sent comment still a draft) — an accepted low-probability gap,
   * since a client whose send didn't resolve already has to reconcile by re-reading `reviewCommentList`.
   * Each entry's `revision` must match the draft's current one or the whole call rejects `conflict`
   * before anything is sent (see `ReviewCommentSendEntry`). On any rejection every named comment
   * stays a draft exactly as it was; callers must not optimistically remove drafts before this resolves.
   */
  reviewCommentsSend(sessionId: string, text: string, comments: ReviewCommentSendEntry[]): Promise<void>;
}

/** Theme the Swift host reports at init and on subsequent appearance changes. */
export type CodePaneTheme = "light" | "dark";

export type CodePaneMode = "diff" | "editor";

/** One editor's open-file snapshot: mirrors `CodePaneBridge.EditorState` on the Swift side. Pushed
 *  fire-and-forget via `notifyEditorStateChanged` and rehydrated through `spaces:init`'s
 *  `editorState` field after a hibernation cycle.
 *
 *  `baseContent` is the content at the current CAS baseline (`baseSHA256`) — needed so a
 *  rehydrated pane can still diff3-merge a disk change that arrives right after rehydration,
 *  without a redundant read. While in conflict, this doubles as the compare view's disk side, so a
 *  rehydrated conflict can render its compare view without a redundant read either. `conflict` must
 *  survive hibernation (a conflict the user hasn't resolved yet should still show as a conflict
 *  after a reload), so it is part of this snapshot. The auto-merge's undo snapshot
 *  (`pendingMergeUndo` on the editor side) is deliberately NOT part of this state: it is cheap to
 *  lose (simply not offering Undo after a hibernation cycle), and keeping it out avoids doubling
 *  this payload's size on every debounced push.
 *
 *  This snapshot also can't distinguish "changed on disk" from "deleted on disk" for a rehydrated
 *  conflict (there is no `diskMissing` field here — see the editor-side field's own doc comment for
 *  why). A rehydrated conflict always renders with the "changed" wording as an approximation; it
 *  self-corrects the moment a fresh `spaces:fileSignature` event or a compare-view action
 *  re-derives the real state. */
export interface CodePaneEditorState {
  path: string;
  baseSHA256: string;
  baseContent: string;
  content: string;
  dirty: boolean;
  conflict: boolean;
}

/**
 * Payload the Swift host delivers once, at startup, via the `spaces:init`
 * event (see README.md). Nothing in the plugin renders before this arrives.
 */
export interface CodePaneInitPayload {
  workspaceId: string;
  workspaceName: string;
  initialMode: CodePaneMode;
  initialScope: DiffScope;
  theme: CodePaneTheme;
  /** The workspace's configured base branch name, absent when it has none — lets the toolbar
   *  disable (and label) the "vs base branch" scope instead of always offering an option the host
   *  is guaranteed to reject. */
  baseBranch?: string;
  /** The host-held editor-state snapshot from before this pane's most recent hibernation cycle,
   *  absent when there is none (a pane's first-ever load, or one whose editor never opened a
   *  file). See `EditorView.restoreState`'s doc comment for the rehydration rules. */
  editorState?: CodePaneEditorState;
  /** round-16 Fix 1a: the host-held snapshot of comment text typed but not yet persisted before this
   *  pane's most recent teardown, absent when there is none. See
   *  `CommentsController.restorePendingState`'s doc comment for the rehydration rules — mirrors
   *  `editorState` above but for the comment surface. */
  pendingReviewComments?: PendingReviewCommentEntry[];
  /** Agents running in this workspace at startup, for the assigned-agent dropdown (see
   *  `reviewComments.ts`'s `selectDefaultAgentId`). Kept current after startup by `spaces:agents`. */
  agents: CodePaneAgentSummary[];
}

/**
 * Detail of the `spaces:theme` event (see README.md), dispatched whenever the host's effective
 * appearance changes after startup. `spaces:init`'s own `theme` field only covers the appearance
 * at that one-shot event's delivery.
 */
export interface CodePaneThemeChangedEvent {
  theme: CodePaneTheme;
}

/** Detail of the `spaces:agents` event (see README.md), dispatched whenever the set of agents
 *  running in this workspace changes after startup. */
export interface CodePaneAgentsChangedEvent {
  agents: CodePaneAgentSummary[];
}

declare global {
  interface Window {
    spaces?: SpacesBridge;
    /**
     * Host-pulled counterpart to `notifyEditorStateChanged`'s push: the Swift host calls this
     * synchronously (via `evaluateJavaScript`'s return value, not the message channel) at teardown
     * to flush whatever the editor holds at that instant, closing the race where a buffer edit is
     * still inside `EditorView`'s ~500ms debounce window when the page is torn down. Returns the
     * exact `editorStateChanged` payload shape (`CodePaneEditorState`) JSON-stringified, or `null`
     * when no file is open — wired in `root.ts` at the point the `EditorView` instance is
     * constructed, so it always reads that instance's live state. See README.md "Editor state
     * survives hibernation".
     */
    __spacesCollectEditorState?: () => string | null;
    /** round-16 Fix 1a: mirrors `__spacesCollectEditorState` above, but for the comment surface —
     *  see `CommentsController.collectStateForFlush`'s doc comment. Returns the exact
     *  `PendingReviewCommentEntry[]` JSON-stringified, or `null` when nothing is pending. Wired in
     *  `root.ts` at the point the `CommentsController` instance is constructed. */
    __spacesCollectReviewCommentState?: () => string | null;
  }
}
