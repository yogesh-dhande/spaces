import {
  FIXTURE_AGENTS,
  FIXTURE_ALL_PATHS,
  FIXTURE_FILE_CONTENTS,
  FIXTURE_INIT_PAYLOAD,
  FIXTURE_REF_LIST,
  fixtureDiffFiles,
  fixtureHash,
} from "./fixtures";
import {
  CodePaneAgentsChangedEvent,
  CodePaneEditorState,
  CodePaneEditorUIState,
  CodePaneMode,
  DiffScope,
  DiffSignatureListener,
  FileSignatureListener,
  ReviewCommentSendEntry,
  ReviewCommentUpsertInput,
  SpacesBridge,
  SpacesBridgeError,
  SpacesReviewComment,
  Unsubscribe,
  WorkspaceDiffResult,
  WorkspaceFileListResult,
  WorkspaceFileReadResult,
  WorkspaceFileWriteOptions,
  WorkspaceFileWriteResult,
  WorkspaceRefListResult,
} from "./types";

const INIT_EVENT = "spaces:init";
const DIFF_SIGNATURE_EVENT = "spaces:diffSignature";
const AGENTS_EVENT = "spaces:agents";

let nextCommentId = 0;

/** Small fixed delay so the harness's loading states are visible, without making manual testing feel sluggish. */
const MOCK_LATENCY_MS = 120;

function delay<T>(value: T): Promise<T> {
  return new Promise((resolve) => setTimeout(() => resolve(value), MOCK_LATENCY_MS));
}

/**
 * In-memory implementation of `SpacesBridge` over static fixture data, used
 * by the `npm run dev` harness and by `test/bridge.test.ts`. Mirrors the real
 * bridge's event-based lifecycle (a `notifyReady` call that triggers a
 * `spaces:init` dispatch) so `app/root.ts` has exactly one startup path
 * regardless of which bridge implementation is behind `window.spaces`.
 */
export class MockSpacesBridge implements SpacesBridge {
  private version = 0;
  private readonly listeners = new Set<DiffSignatureListener>();
  private readonly fileSignatureListeners = new Set<FileSignatureListener>();
  /** The path most recently passed to `workspaceFileRead`: this is what the harness's "currently
   *  open in the editor" file is, for `simulateFileChange`/`simulateFileDeleted` to act against —
   *  mirroring how the real host tracks which path its one live `spaces:fileSignature` stream
   *  points at (driven by `workspaceFileRead` completions, per types.ts's doc comment). */
  private currentReadPath: string | undefined;
  private readonly files = new Map<string, { content: string; sha256: string }>(
    Object.entries(FIXTURE_FILE_CONTENTS).map(([path, content]) => [path, { content, sha256: fixtureHash(content) }]),
  );
  private readonly comments = new Map<string, SpacesReviewComment>();

  notifyReady(): void {
    queueMicrotask(() => {
      window.dispatchEvent(new CustomEvent(INIT_EVENT, { detail: FIXTURE_INIT_PAYLOAD }));
    });
  }

  /** Dev-harness-only control, not part of `SpacesBridge`: advances the fixture diff and emits a signature-change event, simulating a git state change made outside the pane. */
  simulateSignatureChange(): void {
    this.version += 1;
    const scopeSignature = `fixture-v${this.version}`;
    for (const listener of this.listeners) {
      listener({ scopeSignature });
    }
    window.dispatchEvent(new CustomEvent(DIFF_SIGNATURE_EVENT, { detail: { scopeSignature } }));
  }

  /** Dev-harness-only control, not part of `SpacesBridge`: cycles the running-agent set (two agents
   *  -> one -> none -> two) and emits `spaces:agents`, so the assigned-agent dropdown's manual-pick,
   *  auto-default, and no-agent-disables-sending states are all exercisable without a real daemon. */
  simulateAgentsChange(): void {
    const cycle = [FIXTURE_AGENTS, FIXTURE_AGENTS.slice(0, 1), []];
    const currentIndex = cycle.findIndex((set) => set.length === this.lastAgentsLength);
    const next = cycle[(currentIndex + 1) % cycle.length]!;
    this.lastAgentsLength = next.length;
    const detail: CodePaneAgentsChangedEvent = { agents: next };
    window.dispatchEvent(new CustomEvent(AGENTS_EVENT, { detail }));
  }

  private lastAgentsLength = FIXTURE_AGENTS.length;

  async workspaceDiff(scope: DiffScope): Promise<WorkspaceDiffResult> {
    const files = fixtureDiffFiles(scope, this.version);
    return delay({ scopeSignature: `fixture-v${this.version}`, files });
  }

  async workspaceFileRead(path: string): Promise<WorkspaceFileReadResult> {
    // Track this as the harness's "currently open" path regardless of outcome below, mirroring
    // the real host: a read attempt (even one that turns out notFound) is what points the one
    // live file-signature stream at this path.
    this.currentReadPath = path;
    const entry = this.files.get(path);
    if (!entry) {
      throw new SpacesBridgeError("notFound", `No such file in the mock workspace: ${path}`);
    }
    return delay({ content: entry.content, sha256: entry.sha256, size: entry.content.length });
  }

  async workspaceFileWrite(
    path: string,
    content: string,
    options: WorkspaceFileWriteOptions,
  ): Promise<WorkspaceFileWriteResult> {
    const entry = this.files.get(path);
    if (options.baseSHA256 === undefined) {
      // "Create" convention: succeeds only if nothing currently exists at this path. Used by the
      // conflict compare view's "Keep mine" action to recreate a file deleted on disk.
      if (entry) {
        return delay({ conflict: true, currentSHA256: entry.sha256 });
      }
    } else if (!entry) {
      // The file was deleted on disk after it was last read — nothing to compare hashes against.
      return delay({ conflict: true, fileMissing: true });
    } else if (entry.sha256 !== options.baseSHA256) {
      return delay({ conflict: true, currentSHA256: entry.sha256 });
    }
    const sha256 = fixtureHash(content);
    this.files.set(path, { content, sha256 });
    return delay({ ok: true, sha256 });
  }

  async workspaceFileList(): Promise<WorkspaceFileListResult> {
    return delay({ paths: FIXTURE_ALL_PATHS, truncated: false });
  }

  async workspaceRefList(): Promise<WorkspaceRefListResult> {
    return delay(FIXTURE_REF_LIST);
  }

  subscribeDiffSignature(_scope: DiffScope, listener: DiffSignatureListener): Unsubscribe {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  }

  subscribeFileSignature(_path: string, listener: FileSignatureListener): Unsubscribe {
    this.fileSignatureListeners.add(listener);
    return () => this.fileSignatureListeners.delete(listener);
  }

  /** Dev-harness-only control, not part of `SpacesBridge`: mutates the mock's file-content map for
   *  whatever path is currently open (see `currentReadPath`) to `newContent`, and fires every
   *  `subscribeFileSignature` listener with the new hash — simulating a disk edit made outside the
   *  pane (e.g. another editor, or an agent). A no-op if nothing has been read yet. */
  simulateFileChange(newContent: string): void {
    const path = this.currentReadPath;
    if (path === undefined) return;
    const sha256 = fixtureHash(newContent);
    this.files.set(path, { content: newContent, sha256 });
    for (const listener of this.fileSignatureListeners) {
      listener({ path, sha256, missing: false });
    }
  }

  /** Dev-harness-only control, not part of `SpacesBridge`: removes whatever path is currently open
   *  (see `currentReadPath`) from the mock's file-content map, and fires every
   *  `subscribeFileSignature` listener with `missing: true` — simulating the file being deleted on
   *  disk outside the pane. A no-op if nothing has been read yet. */
  simulateFileDeleted(): void {
    const path = this.currentReadPath;
    if (path === undefined) return;
    this.files.delete(path);
    for (const listener of this.fileSignatureListeners) {
      listener({ path, sha256: undefined, missing: true });
    }
  }

  async reviewCommentList(): Promise<SpacesReviewComment[]> {
    const drafts = [...this.comments.values()].sort((a, b) => a.createdAt.localeCompare(b.createdAt));
    return delay(drafts);
  }

  async reviewCommentUpsert(input: ReviewCommentUpsertInput): Promise<SpacesReviewComment> {
    if (input.filePath.length === 0 || input.side === undefined || input.lineNumber === undefined) {
      throw new SpacesBridgeError("invalidArgument", "filePath, side, and lineNumber are required");
    }
    const now = new Date().toISOString();
    if (input.id !== undefined) {
      const existing = this.comments.get(input.id);
      if (!existing) {
        throw new SpacesBridgeError("notFound", `No such draft comment: ${input.id}`);
      }
      const updated: SpacesReviewComment = {
        ...existing,
        filePath: input.filePath,
        side: input.side,
        lineNumber: input.lineNumber,
        lineText: input.lineText,
        body: input.body,
        // Mirrors the daemon's upsert: every update bumps `revision`, the send endpoint's concurrency
        // token (see `SpacesReviewComment.revision`'s doc comment) — a fresh draft below starts at `0`.
        revision: existing.revision + 1,
      };
      this.comments.set(updated.id, updated);
      return delay(updated);
    }
    const created: SpacesReviewComment = {
      id: `mock-comment-${++nextCommentId}`,
      filePath: input.filePath,
      side: input.side,
      lineNumber: input.lineNumber,
      lineText: input.lineText,
      body: input.body,
      createdAt: now,
      revision: 0,
    };
    this.comments.set(created.id, created);
    return delay(created);
  }

  async reviewCommentDelete(id: string): Promise<void> {
    if (!this.comments.delete(id)) {
      throw new SpacesBridgeError("notFound", `No such draft comment: ${id}`);
    }
    await delay(undefined);
  }

  async reviewCommentsSend(sessionId: string, _text: string, comments: ReviewCommentSendEntry[]): Promise<void> {
    void sessionId; // the mock has no terminal-session registry to validate a session against
    if (comments.length === 0) {
      throw new SpacesBridgeError("invalidArgument", "comments must be non-empty");
    }
    const missing = comments.find((entry) => !this.comments.has(entry.id));
    if (missing !== undefined) {
      throw new SpacesBridgeError("notFound", `No such draft comment: ${missing.id}`);
    }
    // Mirrors the daemon's version-echo check: a stale `revision` means this client's view of the
    // draft is behind another edit, so reject before touching anything rather than sending stale text.
    const stale = comments.find((entry) => this.comments.get(entry.id)!.revision !== entry.revision);
    if (stale !== undefined) {
      throw new SpacesBridgeError("conflict", `Comment '${stale.id}' changed since it was last read.`);
    }
    // Both-or-neither: validated above before any mutation, so a rejection never leaves a partial
    // send applied.
    for (const entry of comments) this.comments.delete(entry.id);
    await delay(undefined);
  }

  // The dev harness and unit tests never hibernate a real WKWebView, so there is nothing for the
  // mock to persist or rehydrate here — these two are no-ops purely to satisfy `SpacesBridge`.
  notifyEditorStateChanged(_state: CodePaneEditorState | undefined): void {}

  notifyModeChanged(_mode: CodePaneMode): void {}

  notifyEditorUIStateChanged(_state: CodePaneEditorUIState): void {}
}

let lastInstance: MockSpacesBridge | undefined;

/** Constructed once by `bridge/index.ts`'s dev-only branch. `dev/harnessControls.ts` reaches back into this instance to expose the "simulate remote change" control described in Phase 3 item 5, without adding a dev-only method to the shared `SpacesBridge` contract. */
export function createMockBridge(): MockSpacesBridge {
  lastInstance = new MockSpacesBridge();
  return lastInstance;
}

export function getMockBridgeForHarness(): MockSpacesBridge | undefined {
  return lastInstance;
}
