import {
  FIXTURE_AGENTS,
  FIXTURE_ALL_PATHS,
  FIXTURE_FILE_CONTENTS,
  FIXTURE_INIT_PAYLOAD,
  FIXTURE_REF_LIST,
  fixtureDiffFiles,
  fixtureDiffManifest,
  fixtureHash,
} from "./fixtures";
import {
  CodePaneAgentsChangedEvent,
  CodePaneRenderMetric,
  CodePaneWorkspaceState,
  DiffScope,
  DiffSignatureListener,
  FileListSignatureListener,
  FileSignatureListener,
  ReviewCommentSendEntry,
  ReviewCommentUpsertInput,
  SpacesBridge,
  SpacesBridgeError,
  SpacesReviewComment,
  Unsubscribe,
  StartWorkspaceCommandResult,
  WorkspaceDiffFileChunkResult,
  WorkspaceDiffManifestChunkResult,
  WorkspaceFileListResult,
  WorkspaceFileReadResult,
  WorkspaceRevisionFileReadResult,
  WorkspaceFileReadPurpose,
  WorkspaceFileWriteOptions,
  WorkspaceFileWriteResult,
  WorkspaceRefListResult,
} from "./types";

const INIT_EVENT = "spaces:init";
const DIFF_SIGNATURE_EVENT = "spaces:diffSignature";
const FILE_LIST_SIGNATURE_EVENT = "spaces:fileListSignature";
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
  private readonly fileListSignatureListeners = new Set<FileListSignatureListener>();
  private readonly fileSignatureListeners = new Set<FileSignatureListener>();
  /** The path most recently passed to an editor-purpose `workspaceFileRead`: this is what the
   *  harness's "currently open in the editor" file is, for `simulateFileChange`/
   *  `simulateFileDeleted` to act against. Inline-diff reads do not retarget this stream, matching
   *  the native host's single standalone-editor watcher. */
  private currentReadPath: string | undefined;
  private readonly files = new Map<string, { content: string; sha256: string }>(
    Object.entries(FIXTURE_FILE_CONTENTS).map(([path, content]) => [path, { content, sha256: fixtureHash(content) }]),
  );
  private readonly workspaceMembership = new Set<string>(FIXTURE_ALL_PATHS);
  private readonly comments = new Map<string, SpacesReviewComment>();
  private readonly patchTransfers = new Map<string, { scopeSignature: string; file: ReturnType<typeof fixtureDiffFiles>[number]; bytes: Uint8Array }>();
  private readonly manifests = new Map<string, { scope: DiffScope; scopeSignature: string }>();
  /** Start Agent readiness has one native-minted absolute deadline; resume must reuse it rather
   * than silently granting another window to the same command. */
  private readonly agentStartDeadlines = new Map<string, number>();
  /** Every `spaces:flushEdits` token this page has answered, in order. */
  readonly editsFlushedTokens: string[] = [];
  private nextManifestID = 0;
  private nextPatchTransferID = 0;

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

  async workspaceDiffManifestChunk(
    scope: DiffScope,
    request: { manifestID?: string; fileIndex: number },
  ): Promise<WorkspaceDiffManifestChunkResult> {
    let manifestID = request.manifestID;
    if (manifestID === undefined) {
      if (request.fileIndex !== 0) throw new SpacesBridgeError("invalidArgument", "manifestID is required after the initial metadata page.");
      manifestID = `mock-manifest-${this.version}-${++this.nextManifestID}`;
      this.manifests.set(manifestID, { scope, scopeSignature: `fixture-v${this.version}` });
    }
    const manifest = this.manifests.get(manifestID);
    if (!manifest || JSON.stringify(manifest.scope) !== JSON.stringify(scope)) throw new SpacesBridgeError("conflict", "Diff snapshot expired.");
    const files = fixtureDiffManifest(scope, this.version);
    const pageSize = 2;
    const page = files.slice(request.fileIndex, request.fileIndex + pageSize);
    if (request.fileIndex > files.length) throw new SpacesBridgeError("invalidArgument", "fileIndex is outside this diff manifest.");
    const nextFileIndex = request.fileIndex + page.length < files.length ? request.fileIndex + page.length : undefined;
    return delay({ manifestID, scopeSignature: manifest.scopeSignature, files: page, nextFileIndex });
  }

  async workspaceDiffFileChunk(
    scope: DiffScope,
    request: { manifestID: string; relativePath: string; byteOffset: number; transferID?: string },
  ): Promise<WorkspaceDiffFileChunkResult> {
    const manifest = this.manifests.get(request.manifestID);
    if (!manifest) throw new SpacesBridgeError("conflict", "Diff snapshot expired.");
    const signature = manifest.scopeSignature;
    let transfer = request.transferID === undefined ? undefined : this.patchTransfers.get(request.transferID);
    let transferID = request.transferID;
    if (transfer === undefined) {
      const file = fixtureDiffFiles(scope, this.version).find((entry) => entry.path === request.relativePath);
      if (!file) throw new SpacesBridgeError("notFound", `No changed file: ${request.relativePath}`);
      transferID = `mock-patch-${++this.nextPatchTransferID}`;
      transfer = { scopeSignature: signature, file, bytes: new TextEncoder().encode(file.patch ?? "") };
      this.patchTransfers.set(transferID, transfer);
    }
    if (transfer.scopeSignature !== signature) throw new SpacesBridgeError("conflict", "Diff changed while patch was streaming.");
    const chunkBytes = 4 * 1024 * 1024;
    const bytes = transfer.bytes.slice(request.byteOffset, request.byteOffset + chunkBytes);
    const nextByteOffset = request.byteOffset + bytes.length < transfer.bytes.length ? request.byteOffset + bytes.length : undefined;
    if (nextByteOffset === undefined) this.patchTransfers.delete(transferID!);
    return delay({
      scopeSignature: signature,
      file: transfer.file,
      transferID: nextByteOffset === undefined ? undefined : transferID,
      patchBase64Data: bytes.length === 0 ? undefined : uint8ArrayToBase64(bytes),
      nextByteOffset,
    });
  }

  async workspaceDiffFileChunkCancel(
    _scope: DiffScope,
    request: { manifestID: string; relativePath: string; byteOffset: number; transferID: string },
  ): Promise<void> {
    this.patchTransfers.delete(request.transferID);
    await delay(undefined);
  }

  async workspaceDiffManifestRelease(_scope: DiffScope, request: { manifestID: string }): Promise<void> {
    this.manifests.delete(request.manifestID);
    await delay(undefined);
  }

  async workspaceFileRead(path: string, purpose: WorkspaceFileReadPurpose, _comparison?: { baseRevision: string; oldPath?: string }): Promise<WorkspaceFileReadResult> {
    // Only standalone Editor reads own the harness's live watcher. Inline diff reads fetch content
    // for a separate transient editor and must not move external-change monitoring off the open file.
    if (purpose === "editor") this.currentReadPath = path;
    const entry = this.files.get(path);
    if (!entry) {
      throw new SpacesBridgeError("notFound", `No such file in the mock workspace: ${path}`);
    }
    return delay({ content: entry.content, sha256: entry.sha256, size: entry.content.length });
  }

  async workspaceRevisionFileRead(request: { path: string; revision: string; oldPath?: string }): Promise<WorkspaceRevisionFileReadResult> {
    if (!request.revision) throw new SpacesBridgeError("invalidArgument", "A revision is required.");
    const entry = this.files.get(request.path);
    if (!entry) throw new SpacesBridgeError("notFound", `No such file in the mock workspace: ${request.path}`);
    return delay({
      content: entry.content,
      sha256: entry.sha256,
      size: entry.content.length,
      isWorktreeEquivalentToRevision: true,
      comparisonOldContent: null,
    });
  }

  async workspaceFileWrite(
    path: string,
    content: string,
    options: WorkspaceFileWriteOptions,
  ): Promise<WorkspaceFileWriteResult> {
    const entry = this.files.get(path);
    const created = entry === undefined;
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
    if (created && !this.workspaceMembership.has(path)) {
      this.workspaceMembership.add(path);
      this.emitFileListSignatureChange();
    }
    return delay({ ok: true, sha256 });
  }

  async workspaceFileList(): Promise<WorkspaceFileListResult> {
    return delay({ paths: [...this.workspaceMembership].sort((a, b) => a.localeCompare(b)), truncated: false });
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

  subscribeFileListSignature(listener: FileListSignatureListener): Unsubscribe {
    this.fileListSignatureListeners.add(listener);
    return () => this.fileListSignatureListeners.delete(listener);
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
    if (this.workspaceMembership.delete(path)) this.emitFileListSignatureChange();
  }

  private emitFileListSignatureChange(): void {
    const detail = { fileListSignature: `fixture-file-list-v${++this.version}` };
    for (const listener of this.fileListSignatureListeners) listener(detail);
    window.dispatchEvent(new CustomEvent(FILE_LIST_SIGNATURE_EVENT, { detail }));
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

  // The dev harness and unit tests never hibernate a real WKWebView, so recovery is intentionally
  // in-memory-only here; the fixture init payload already models a clean first mount.
  notifyWorkspaceStateChanged(_state: CodePaneWorkspaceState): void {}

  notifyRenderMetric(_metric: CodePaneRenderMetric): void {}

  /** Recorded rather than posted: the dev harness has no host waiting on a quit flush, and tests
   * assert on the tokens the page answered with. */
  notifyEditsFlushed(token: string): void {
    this.editsFlushedTokens.push(token);
  }

  async startWorkspaceCommand(_command: string): Promise<StartWorkspaceCommandResult> {
    const sessionId = `mock-command-${Date.now()}`;
    const deadlineEpochMilliseconds = Date.now() + 90_000;
    this.agentStartDeadlines.set(sessionId, deadlineEpochMilliseconds);
    return delay({
      sessionId,
      status: "starting",
      deadlineEpochMilliseconds,
    });
  }

  async resumeWorkspaceCommandTracking(sessionId: string): Promise<StartWorkspaceCommandResult> {
    const deadlineEpochMilliseconds = this.agentStartDeadlines.get(sessionId);
    if (deadlineEpochMilliseconds === undefined) {
      throw new SpacesBridgeError("notFound", "No pending Start Agent command for this session.");
    }
    return delay({
      sessionId,
      status: "starting",
      deadlineEpochMilliseconds,
    });
  }
}

function uint8ArrayToBase64(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary);
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
