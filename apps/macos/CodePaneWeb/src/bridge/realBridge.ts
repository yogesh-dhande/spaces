import {
  CodePaneRenderMetric,
  CodePaneWorkspaceState,
  DiffScope,
  DiffSignatureEvent,
  DiffSignatureListener,
  FileSignatureEvent,
  FileSignatureListener,
  ReviewCommentSendEntry,
  ReviewCommentUpsertInput,
  SpacesBridge,
  SpacesBridgeError,
  SpacesErrorCode,
  SpacesReviewComment,
  Unsubscribe,
  StartWorkspaceCommandResult,
  WorkspaceDiffFileChunkResult,
  WorkspaceDiffManifestChunkResult,
  WorkspaceFileListResult,
  WorkspaceFileReadResult,
  WorkspaceFileReadPurpose,
  WorkspaceFileWriteOptions,
  WorkspaceFileWriteResult,
  WorkspaceRefListResult,
} from "./types";

/**
 * Real bridge: talks to the Swift host through `window.webkit.messageHandlers`.
 *
 * Wire protocol (see README.md "Bridge wire protocol" for the authoritative
 * copy the Swift host implements against):
 *
 *   JS -> Swift (request/response): a single message handler,
 *     `window.webkit.messageHandlers.spacesBridge.postMessage({ id, method, params })`.
 *     `id` is a string the JS side generates and correlates the reply with.
 *
 *   Swift -> JS (reply): the host evaluates JS that calls
 *     `window.__spacesBridge.resolve(id, result)` or
 *     `window.__spacesBridge.reject(id, { code, message })`. This object is
 *     installed by this module as a side effect of import, before anything
 *     else runs, so there is no race between a reply arriving and the
 *     resolver existing.
 *
 *   JS -> Swift (lifecycle, fire-and-forget): the same message handler with
 *     `{ method: "ready" }` and no `id`. The host waits for this before
 *     dispatching `spaces:init` (below), so the page's listener is always
 *     attached first.
 *
 *   Swift -> JS (push events): `window.dispatchEvent(new CustomEvent(name,
 *     { detail }))` for three event names — `spaces:init` (once, at startup,
 *     detail: CodePaneInitPayload), `spaces:diffSignature` (any time the
 *     active scope's git state changes, detail: DiffSignatureEvent), and
 *     `spaces:fileSignature` (any time the editor's currently open file
 *     changes or is deleted on disk, detail: FileSignatureEvent). The host
 *     decides which path `spaces:fileSignature` tracks based on
 *     `workspaceFileRead` completions marked with the `editor` purpose; inline
 *     diff reads use `inlineDiff` and never retarget that watcher.
 *
 *   JS -> Swift (state pushes, fire-and-forget): the same message handler,
 *     no `id`. `workspaceStateChanged` atomically carries all workspace-local
 *     recovery state, including mode, editor source state, sidebar state,
 *     diff edit state, comments, and agent launch tracking.
 */

type PendingCall = {
  resolve(value: unknown): void;
  reject(error: SpacesBridgeError): void;
};

const DIFF_SIGNATURE_EVENT = "spaces:diffSignature";
const FILE_SIGNATURE_EVENT = "spaces:fileSignature";

interface SpacesBridgeCallbacks {
  resolve(id: string, result: unknown): void;
  reject(id: string, error: { code: string; message: string }): void;
}

declare global {
  interface Window {
    __spacesBridge?: SpacesBridgeCallbacks;
    webkit?: {
      messageHandlers?: {
        spacesBridge?: {
          postMessage(message: unknown): void;
        };
      };
    };
  }
}

function isSpacesErrorCode(value: string): value is SpacesErrorCode {
  return (
    value === "notFound" ||
    value === "invalidArgument" ||
    value === "conflict" ||
    value === "internalError" ||
    value === "unavailable"
  );
}

class RealSpacesBridge implements SpacesBridge {
  private nextId = 0;
  private readonly pending = new Map<string, PendingCall>();

  constructor() {
    window.__spacesBridge = {
      resolve: (id, result) => this.settle(id, (call) => call.resolve(result)),
      reject: (id, error) =>
        this.settle(id, (call) => {
          const code = isSpacesErrorCode(error.code) ? error.code : "internalError";
          call.reject(new SpacesBridgeError(code, error.message));
        }),
    };
  }

  private settle(id: string, apply: (call: PendingCall) => void): void {
    const call = this.pending.get(id);
    if (!call) {
      // A reply for a call we no longer track (already settled, or the id
      // was never ours). Nothing to do: dropping it is safe since no one is
      // awaiting it.
      return;
    }
    this.pending.delete(id);
    apply(call);
  }

  private post(method: string, params: unknown): Promise<unknown> {
    const handler = window.webkit?.messageHandlers?.spacesBridge;
    if (!handler) {
      return Promise.reject(
        new SpacesBridgeError("unavailable", "window.webkit.messageHandlers.spacesBridge is not installed"),
      );
    }
    const id = `${++this.nextId}`;
    const promise = new Promise<unknown>((resolve, reject) => {
      this.pending.set(id, { resolve, reject });
    });
    handler.postMessage({ id, method, params });
    return promise;
  }

  /** Fire-and-forget lifecycle notification; see class doc comment. */
  notifyReady(): void {
    const handler = window.webkit?.messageHandlers?.spacesBridge;
    handler?.postMessage({ method: "ready" });
  }

  /** Persists one complete workspace-local recovery document. Nullability is normalized here so
   * WKWebView's structured clone cannot drop a meaningful "no state" field. */
  notifyWorkspaceStateChanged(state: CodePaneWorkspaceState): void {
    const handler = window.webkit?.messageHandlers?.spacesBridge;
    handler?.postMessage({ method: "workspaceStateChanged", params: state });
  }

  /** Fire-and-forget browser render milestone; the host writes it to the existing DEBUG perf log. */
  notifyRenderMetric(metric: CodePaneRenderMetric): void {
    const handler = window.webkit?.messageHandlers?.spacesBridge;
    handler?.postMessage({ method: "renderMetric", params: metric });
  }

  async workspaceDiffManifestChunk(
    scope: DiffScope,
    request: { manifestID?: string; fileIndex: number },
  ): Promise<WorkspaceDiffManifestChunkResult> {
    return (await this.post("workspaceDiffManifestChunk", { scope, ...request })) as WorkspaceDiffManifestChunkResult;
  }

  async workspaceDiffFileChunk(
    scope: DiffScope,
    request: { manifestID: string; relativePath: string; byteOffset: number; transferID?: string },
  ): Promise<WorkspaceDiffFileChunkResult> {
    return (await this.post("workspaceDiffFileChunk", { scope, ...request })) as WorkspaceDiffFileChunkResult;
  }

  async workspaceDiffFileChunkCancel(
    scope: DiffScope,
    request: { manifestID: string; relativePath: string; byteOffset: number; transferID: string },
  ): Promise<void> {
    await this.post("workspaceDiffFileChunkCancel", { scope, ...request });
  }

  async workspaceDiffManifestRelease(scope: DiffScope, request: { manifestID: string }): Promise<void> {
    await this.post("workspaceDiffManifestRelease", { scope, ...request });
  }

  async workspaceFileRead(path: string, purpose: WorkspaceFileReadPurpose): Promise<WorkspaceFileReadResult> {
    return (await this.post("workspaceFileRead", { path, purpose })) as WorkspaceFileReadResult;
  }

  async workspaceFileWrite(
    path: string,
    content: string,
    options: WorkspaceFileWriteOptions,
  ): Promise<WorkspaceFileWriteResult> {
    // `baseSHA256: undefined` (the "create" convention) is normalized to `null` here for the same
    // reason workspace-state JSON normalizes nullable values: postMessage's structured-clone
    // step drops `undefined`-valued properties entirely, which would make "create" indistinguishable
    // from "the params object never had this key" on the Swift side.
    return (await this.post("workspaceFileWrite", {
      path,
      content,
      options: { baseSHA256: options.baseSHA256 ?? null },
    })) as WorkspaceFileWriteResult;
  }

  async workspaceFileList(): Promise<WorkspaceFileListResult> {
    return (await this.post("workspaceFileList", {})) as WorkspaceFileListResult;
  }

  async workspaceRefList(): Promise<WorkspaceRefListResult> {
    return (await this.post("workspaceRefList", {})) as WorkspaceRefListResult;
  }

  async reviewCommentList(): Promise<SpacesReviewComment[]> {
    return (await this.post("reviewCommentList", {})) as SpacesReviewComment[];
  }

  async reviewCommentUpsert(input: ReviewCommentUpsertInput): Promise<SpacesReviewComment> {
    return (await this.post("reviewCommentUpsert", input)) as SpacesReviewComment;
  }

  async reviewCommentDelete(id: string): Promise<void> {
    // The reply is an ack (`{ok:true}`); nothing here needs it beyond confirming the call settled.
    await this.post("reviewCommentDelete", { id });
  }

  async reviewCommentsSend(sessionId: string, text: string, comments: ReviewCommentSendEntry[]): Promise<void> {
    await this.post("reviewCommentsSend", { sessionId, text, comments });
  }

  async startWorkspaceCommand(command: string): Promise<StartWorkspaceCommandResult> {
    return (await this.post("startWorkspaceCommand", { command })) as StartWorkspaceCommandResult;
  }

  async resumeWorkspaceCommandTracking(sessionId: string): Promise<StartWorkspaceCommandResult> {
    return (await this.post("resumeWorkspaceCommandTracking", { sessionId })) as StartWorkspaceCommandResult;
  }

  subscribeDiffSignature(_scope: DiffScope, listener: DiffSignatureListener): Unsubscribe {
    // Only one scope is ever live at a time (see types.ts doc comment on
    // subscribeDiffSignature), so this listens for the one global event
    // rather than filtering by scope.
    const handler = (event: Event) => {
      const detail = (event as CustomEvent<DiffSignatureEvent>).detail;
      if (detail && typeof detail.scopeSignature === "string") {
        listener(detail);
      }
    };
    window.addEventListener(DIFF_SIGNATURE_EVENT, handler);
    return () => window.removeEventListener(DIFF_SIGNATURE_EVENT, handler);
  }

  subscribeFileSignature(_path: string, listener: FileSignatureListener): Unsubscribe {
    // Mirrors subscribeDiffSignature exactly: the host, not this call, decides which path the
    // one live `spaces:fileSignature` stream tracks (driven by editor-purpose workspaceFileRead
    // completions — see types.ts doc comment), so this never messages Swift, it only listens for
    // the one global event.
    const handler = (event: Event) => {
      const detail = (event as CustomEvent<FileSignatureEvent>).detail;
      if (detail && typeof detail.path === "string" && typeof detail.missing === "boolean") {
        listener(detail);
      }
    };
    window.addEventListener(FILE_SIGNATURE_EVENT, handler);
    return () => window.removeEventListener(FILE_SIGNATURE_EVENT, handler);
  }
}

/**
 * Construct the real bridge and send the "ready" lifecycle notification.
 * Call once, from main.ts, after `window.spaces` is assigned and the
 * `spaces:init` listener (see app/root.ts) is already attached.
 */
export function createRealBridge(): SpacesBridge & { notifyReady(): void } {
  return new RealSpacesBridge();
}
