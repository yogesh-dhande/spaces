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
  /** The sha256 the caller last read. The write is rejected as a conflict if the file's current sha256 no longer matches (compare-and-swap). */
  baseSHA256: string;
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

/** Unsubscribe function returned by `subscribeDiffSignature`. */
export type Unsubscribe = () => void;

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
}

/** Theme the Swift host reports at init and on subsequent appearance changes. */
export type CodePaneTheme = "light" | "dark";

export type CodePaneMode = "diff" | "editor";

/** One editor's open-file snapshot: mirrors `CodePaneBridge.EditorState` on the Swift side. Pushed
 *  fire-and-forget via `notifyEditorStateChanged` and rehydrated through `spaces:init`'s
 *  `editorState` field after a hibernation cycle. Kept small and focused since Phase 5's merge
 *  model builds on this same snapshot. */
export interface CodePaneEditorState {
  path: string;
  baseSHA256: string;
  content: string;
  dirty: boolean;
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
}

/**
 * Detail of the `spaces:theme` event (see README.md), dispatched whenever the host's effective
 * appearance changes after startup. `spaces:init`'s own `theme` field only covers the appearance
 * at that one-shot event's delivery.
 */
export interface CodePaneThemeChangedEvent {
  theme: CodePaneTheme;
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
  }
}
