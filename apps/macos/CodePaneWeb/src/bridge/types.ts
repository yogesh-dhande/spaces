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
 * from "vs the last commit" from "vs a specific ref". `refName` is present
 * only for `kind: "ref"` — populated either from the compare menu's
 * "Branch…"/"Commit or ref…" search dialog (`refSearchDialog.ts`) or typed
 * there verbatim; a bad ref surfaces through the diff fetch's existing
 * `invalidArgument` error rather than any client-side validation here.
 */
export type DiffScope =
  | { kind: "uncommitted" }
  | { kind: "lastCommit" }
  | { kind: "ref"; refName: string };

/** One changed-file identity returned by the metadata-first diff manifest. The sidebar can render
 * this immediately, before the file's patch body has been read. */
export interface DiffFileManifestEntry {
  /** Workspace-relative path of the file's current (new) side. */
  path: string;
  /** Previous path, present only when `status` is `"renamed"`. */
  oldPath?: string;
  status: FileChangeStatus;
  /** Immutable old-side tree for on-demand Git-filtered inline-edit hydration. */
  comparisonBaseRevision?: string;
}

/** One completed file patch. `patch` is absent only for a binary file. There is deliberately no
 * product truncation flag: the daemon transfers every textual patch in bounded transport chunks. */
export interface DiffFileEntry {
  /** Workspace-relative path of the file's current (new) side. */
  path: string;
  /** Previous path, present only when `status` is `"renamed"`. */
  oldPath?: string;
  status: FileChangeStatus;
  /** Git unified diff patch text for this file. Absent only when `isBinary` is true. */
  patch?: string;
  isBinary: boolean;
  /** Ephemeral client-side transfer state, never persisted with workspace recovery data. */
  patchState?: "queued" | "streaming" | "ready";
  oldSHA?: string;
  newSHA?: string;
  /** Immutable post-change revision for a tracked revision-to-revision diff. Last Commit inline
   * editing compares this exact revision with the live worktree before allowing a write. */
  targetRevision?: string;
  comparisonBaseRevision?: string;
}

/** The small first response of a progressive diff transfer. Its lease freezes the diff file
 * enumeration and scope signature for this generation. Patch bytes are generated when each file is
 * first requested, so ordinary worktree churn can be reflected until the next signature refresh. */
export interface WorkspaceDiffManifestChunkResult {
  /** Opaque daemon snapshot lease. Every file chunk must echo it; release it once this generation
   * ends so a churned worktree cannot retain an obsolete full diff plan. */
  manifestID: string;
  scopeSignature: string;
  files: DiffFileManifestEntry[];
  /** Omitted after the final metadata page. This is an entry cursor, never a byte offset. */
  nextFileIndex?: number;
}

/** The response to one bounded raw-byte patch read. `patchBase64Data` must be concatenated as bytes
 * before UTF-8 decoding: a multi-byte codepoint may straddle the 4 MiB transport boundary. */
export interface WorkspaceDiffFileChunkResult {
  scopeSignature: string;
  /** Full completed-file metadata is repeated on every chunk so the client need not infer binary
   * and rename details from the manifest. */
  file: DiffFileEntry;
  transferID?: string;
  patchBase64Data?: string;
  /** Omitted at EOF. The client echoes the value unchanged for the next chunk. */
  nextByteOffset?: number;
}

export interface WorkspaceFileReadResult {
  content: string;
  sha256: string;
  size: number;
  comparisonOldContent?: string | null;
}

/** Last Commit safety and Git-filtered comparison input. `content`/`sha256` are the exact live
 * worktree baseline that the native operation verified against the pinned revision; the target
 * blob itself is existence/type checked but never transferred. */
export interface WorkspaceRevisionFileReadResult {
  content: string;
  sha256: string;
  size: number;
  isWorktreeEquivalentToRevision: boolean;
  comparisonOldContent: string | null;
}

/** Identifies whether a file read owns the native editor file-signature watcher. */
export type WorkspaceFileReadPurpose = "editor" | "inlineDiff";

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
  /** Required on the host wire: inline diff saves reject symbolic links while ordinary Editor saves
   * retain the workspace's contained-symlink behavior. Optional here keeps lightweight test bridges
   * focused on their asserted behavior; `realBridge` rejects a missing value instead of inferring one. */
  purpose?: WorkspaceFileReadPurpose;
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
  /** Every file in the workspace, relative to the workspace root, sorted. Backs both Editor mode's
   *  Files tree and the ⌘P quick-open overlay's full-listing fuzzy search. */
  paths: string[];
  /** True when the daemon capped the listing before enumerating the whole tree. Callers surface a
   *  subtle note ("File list truncated") rather than presenting the list as complete. */
  truncated: boolean;
}

/** Backs the compare menu's "Branch…" and "Commit or ref…" search dialog (`refSearchDialog.ts`).
 *  `commits` is this workspace's recent commit history, newest first; `sha` is the full SHA-1 or
 *  SHA-256 hex object id (the dialog's own commit rows display only its first 7 characters, and a
 *  picked commit's scope carries the full sha so it never needs re-resolving). Both truncated flags mirror
 *  `WorkspaceFileListResult.truncated`'s convention: true only when the daemon capped that half of
 *  the listing before enumerating everything available. */
export interface WorkspaceRefListResult {
  branches: string[];
  branchesTruncated: boolean;
  commits: { sha: string; subject: string }[];
  commitsTruncated: boolean;
}

export interface DiffSignatureEvent {
  scopeSignature: string;
}

export type DiffSignatureListener = (event: DiffSignatureEvent) => void;

/** A browser-paint milestone reported to the native DEBUG performance log. Counts are aggregate
 *  metadata only: source text and file paths never cross this fire-and-forget channel. */
export interface CodePaneRenderMetric {
  kind: "diff" | "editor";
  trigger:
    | "initial"
    | "scope"
    | "workspaceChange"
    | "fileOpen"
    | "manifest"
    | "filePatch"
    | "complete"
    | "workspaceStateRestored"
    | "diffEdit"
    | "diffEditSave"
    | "diffEditCancel";
  elapsedMs: number;
  /** Time through the workspace data response, before DOM/model work. Present for diff metrics. */
  fetchElapsedMs?: number;
  /** Time spent awaiting native/bridge responses while streaming one file's patch. */
  bridgeElapsedMs?: number;
  /** Time spent decoding base64 chunks, feeding the UTF-8 decoder, and joining the patch. */
  decodeElapsedMs?: number;
  /** Synchronous time spent updating the diff model and inserting the completed CodeView item. */
  updateElapsedMs?: number;
  /** Time from completed CodeView insertion until the post-insertion browser-paint milestone. */
  paintElapsedMs?: number;
  fileCount: number;
  contentBytes: number;
  path?: string;
  fileIndex?: number;
  selectedPriority?: boolean;
  chunkCount?: number;
  mode?: CodePaneMode;
  /** Scope serialized for the native performance log: `uncommitted`, `lastCommit`, or `ref:<name>`. */
  scope?: string;
  layout?: "split" | "unified";
  scrollTop?: number;
  /** Logical visible/focused source line for workspace-state recovery metrics. */
  focusedLine?: number;
  dirty?: boolean;
}

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

/** One workspace listing's signature, pushed whenever the authoritative `workspaceFileList`
 *  result changes (paths added/removed, or truncation flips). This never carries the listing
 *  itself — callers still re-fetch `workspaceFileList` so Files and quick-open stay on the same
 *  contract as the ordinary pull path. */
export interface FileListSignatureEvent {
  fileListSignature: string;
}

export type FileListSignatureListener = (event: FileListSignatureEvent) => void;

/** Unsubscribe function returned by `subscribeDiffSignature`/`subscribeFileSignature`/
 *  `subscribeFileListSignature`. */
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
  /** Reads one bounded metadata page. Start with no `manifestID` and `fileIndex: 0`; echo the returned
   * id and cursor until `nextFileIndex` is absent, then begin the one-at-a-time patch reads. */
  workspaceDiffManifestChunk(
    scope: DiffScope,
    request: { manifestID?: string; fileIndex: number },
  ): Promise<WorkspaceDiffManifestChunkResult>;
  /** Reads or cancels one daemon-owned file-patch transfer. `byteOffset: 0` with no `transferID`
   * starts a transfer; later calls echo both opaque values. */
  workspaceDiffFileChunk(
    scope: DiffScope,
    request: { manifestID: string; relativePath: string; byteOffset: number; transferID?: string },
  ): Promise<WorkspaceDiffFileChunkResult>;
  workspaceDiffFileChunkCancel(
    scope: DiffScope,
    request: { manifestID: string; relativePath: string; byteOffset: number; transferID: string },
  ): Promise<void>;
  workspaceDiffManifestRelease(scope: DiffScope, request: { manifestID: string }): Promise<void>;
  /** Reads a workspace file. The default editor purpose owns the native file-signature watcher;
   * inline diff reads explicitly use `inlineDiff` and do not retarget it. */
  workspaceFileRead(
    path: string, purpose: WorkspaceFileReadPurpose, comparison?: { baseRevision: string; oldPath?: string },
  ): Promise<WorkspaceFileReadResult>;
  /** Reads a file from an immutable revision named by streamed diff metadata. This deliberately
   * has no read purpose: it must never retarget the standalone Editor's worktree watcher. */
  workspaceRevisionFileRead(request: { path: string; revision: string; oldPath?: string }): Promise<WorkspaceRevisionFileReadResult>;
  workspaceFileWrite(path: string, content: string, options: WorkspaceFileWriteOptions): Promise<WorkspaceFileWriteResult>;
  /**
   * The full workspace file listing, backing Editor mode's Files tree and the ⌘P quick-open
   * overlay. Callers fetch this lazily (first use), cache it in memory, and refetch on a
   * diff-signature push (the same signal that refreshes the diff) so files added or removed
   * outside the pane reappear without a manual refresh — see `root.ts`'s
   * `resubscribeDiffSignature`.
   */
  workspaceFileList(): Promise<WorkspaceFileListResult>;
  /**
   * Branches and recent commit history for the compare menu's "Branch…" / "Commit or ref…" search
   * dialog (`refSearchDialog.ts`). Unlike `workspaceFileList`, callers fetch this fresh every time
   * the dialog opens rather than caching it — the branch/commit lists this backs are cheap to
   * relist and go stale faster (any commit made from any surface changes them).
   */
  workspaceRefList(): Promise<WorkspaceRefListResult>;
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
   * underlying stream points at, driven by completions of `workspaceFileRead` calls with the
   * `editor` purpose; inline-diff reads use `inlineDiff` and never retarget it. There is no
   * explicit subscribe/unsubscribe RPC here; see README.md for the event-delivery mechanism.
   */
  subscribeFileSignature(path: string, listener: FileSignatureListener): Unsubscribe;
  /**
   * Subscribe to workspace-listing-signature push events for the shared `workspaceFileList`
   * cache. The host opens this only after the first successful `workspaceFileList` pull, so a
   * pane that never opens Files or quick-open never pays for background listing polls.
   */
  subscribeFileListSignature(listener: FileListSignatureListener): Unsubscribe;
  /** Atomically persists the current workspace-local recovery document. The page owns snapshot
   * construction so navigation, comment text, and either editing surface cannot race into
   * separate host writes. */
  notifyWorkspaceStateChanged(state: CodePaneWorkspaceState): void;
  /** Reports completion after browser layout/paint has had two animation frames to settle. The
   *  native host validates and records this only when DEBUG performance logging is enabled. */
  notifyRenderMetric(metric: CodePaneRenderMetric): void;
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
  /** Runs a user-entered command in a new background terminal rooted at this workspace. Agent
   * discovery remains asynchronous and arrives through the normal `spaces:agents` event. */
  startWorkspaceCommand(command: string): Promise<StartWorkspaceCommandResult>;
  /** Resumes status-event delivery for a command launch this pane was tracking before restart. */
  resumeWorkspaceCommandTracking(sessionId: string): Promise<StartWorkspaceCommandResult>;
}

/** Theme the Swift host reports at init and on subsequent appearance changes. */
export type CodePaneTheme = "light" | "dark";

export type CodePaneMode = "diff" | "editor";

/** One editor's open-file snapshot, folded into the pane's atomic workspace state and rehydrated
 *  through `spaces:init` after a hibernation cycle.
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
 *  Editor mode cannot distinguish "changed on disk" from "deleted on disk" for a rehydrated
 *  conflict (there is no `diskMissing` field here — see the editor-side field's own doc comment for
 *  why). A rehydrated editor conflict initially uses the "changed" wording and self-corrects when
 *  fresh reconciliation re-derives the disk state. Inline diff editing carries its exact conflict
 *  target in `CodePaneDiffEditorState` below. */
export interface CodePaneEditorState {
  path: string;
  baseSHA256: string;
  baseContent: string;
  content: string;
  dirty: boolean;
  conflict: boolean;
}

/** Diff mode's editable-file snapshot. A conflict must retain the exact CAS target that matches
 * the comparison the user sees: a SHA means the disk side exists, while `null` means it was deleted
 * and Keep mine must use create-if-missing. Editor mode has its own live reconciliation path, so
 * this distinction belongs only to the inline diff editor's durable state. */
export interface CodePaneDiffEditorState extends CodePaneEditorState {
  /** Immutable old side of the reviewed comparison. Unlike `baseContent`, this is never a CAS
   * baseline; Pierre retains it while the editable new side changes and across hibernation. */
  comparisonOldContent: string | null;
  conflictBaseSHA256: string | null;
}

/** Editor mode's UI-state subset (distinct from `CodePaneEditorState`'s open-file snapshot above):
 *  which sidebar list is showing and the recently opened files. It is part of the unified workspace
 *  document. */
export interface CodePaneEditorUIState {
  sidebarMode: "files" | "changes";
  /** Most-recently-opened first, deduped, capped at 12 — every successful open (⌘P overlay, Files
   *  tree, or Changes list in editor mode) records into this list. */
  recentPaths: string[];
}

/** Durable Start Agent state. The absolute deadline is minted once by native so a resumed pane
 * continues the original readiness window instead of granting a restarted command another 90
 * seconds. `starting` records its terminal session and deadline; a terminal failure preserves the
 * session for inspection but deliberately clears the deadline. */
export type PendingAgentLaunch =
  | {
      sessionId: string;
      command: string;
      status: "starting";
      message: null;
      deadlineEpochMilliseconds: number;
    }
  | {
      sessionId: string | null;
      command: string;
      status: "failed";
      message: string | null;
      deadlineEpochMilliseconds: null;
    };

/** Client-local workspace recovery data. Patch bodies and rendered DOM deliberately stay out: the
 * restored page first applies this light state, then streams a fresh manifest and file patches. */
export interface CodePaneWorkspaceState {
  mode: CodePaneMode;
  scope: DiffScope;
  diffLayout: "split" | "unified";
  /** Path paired with `diffScrollLine`/`diffScrollSide`; sidebar selection is separate state. */
  diffSelectedPath?: string | null;
  /** Omitted for a fresh workspace so the review tree uses its expanded default; an explicit empty
   * array is the user's durable choice to collapse every directory. */
  diffTreeExpandedPaths?: string[];
  diffTreeSelectedPath?: string | null;
  editorSidebarMode: "files" | "changes";
  editorRecentPaths: string[];
  /** Stored by terminal session rather than transient agent id, so comment routing survives restart. */
  selectedAgentSessionId?: string | null;
  pendingAgentLaunch: PendingAgentLaunch | null;
  fileTreeExpandedPaths: string[];
  fileTreeSelectedPath?: string | null;
  diffScrollLine?: number | null;
  /** Side paired with `diffScrollLine`; logical line numbers are independently numbered per side. */
  diffScrollSide: ReviewCommentSide | null;
  diffFocusedLine?: number | null;
  /** Path/side paired with `diffFocusedLine`, retained independently from scroll and sidebar state. */
  diffFocusedPath: string | null;
  diffFocusedSide: ReviewCommentSide | null;
  editorScrollLine?: number | null;
  editorFocusedLine?: number | null;
  editorState?: CodePaneEditorState | null;
  diffEditorState?: CodePaneDiffEditorState | null;
  pendingReviewComments?: PendingReviewCommentEntry[] | null;
}

export interface StartWorkspaceCommandResult {
  sessionId: string;
  status: "starting";
  /** Same absolute deadline persisted in `PendingAgentLaunch`; native computes it only once. */
  deadlineEpochMilliseconds: number;
}

export interface CodePaneAgentStartStatusEvent {
  sessionId: string;
  status: "detected" | "exited" | "timedOut";
  agent?: CodePaneAgentSummary;
  message?: string;
}

/**
 * Payload the Swift host delivers once, at startup, via the `spaces:init`
 * event (see README.md). Nothing in the plugin renders before this arrives.
 */
export interface CodePaneInitPayload {
  workspaceId: string;
  workspaceName: string;
  workspaceState: CodePaneWorkspaceState;
  theme: CodePaneTheme;
  /** The workspace's configured base branch name, absent when it has none — drives the compare
   *  menu's one-click preset and the "Branch…" search dialog's first-sort and "base" badge. */
  baseBranch?: string;
  /** Whether the workspace's project is a git repository. A non-git workspace has no diff to show:
   *  Diff mode renders a neutral notice instead of fetching one, the compare control is omitted, and
   *  the editor sidebar carries the Files tree alone. */
  isGitRepository: boolean;
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

/** Detail of the `spaces:setMode` event (see README.md), dispatched whenever the host wants this
 *  pane to switch its live Diff/Editor mode (e.g. reusing an already-open pane for a different
 *  navigation gesture). */
export interface CodePaneSetModeEvent {
  mode: CodePaneMode;
}

declare global {
  interface Window {
    spaces?: SpacesBridge;
    /** Returns the complete lightweight workspace recovery document for host teardown. */
    __spacesCollectWorkspaceState?: () => string;
  }
}
