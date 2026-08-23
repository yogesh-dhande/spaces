import {
  CodePaneEditorState,
  CodePaneMode,
  DiffScope,
  DiffSignatureEvent,
  DiffSignatureListener,
  SpacesBridge,
  SpacesBridgeError,
  SpacesErrorCode,
  Unsubscribe,
  WorkspaceDiffResult,
  WorkspaceFileListResult,
  WorkspaceFileReadResult,
  WorkspaceFileWriteOptions,
  WorkspaceFileWriteResult,
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
 *     { detail }))` for two event names — `spaces:init` (once, at startup,
 *     detail: CodePaneInitPayload) and `spaces:diffSignature` (any time the
 *     active scope's git state changes, detail: DiffSignatureEvent).
 *
 *   JS -> Swift (state pushes, fire-and-forget): the same message handler,
 *     no `id`. `{ method: "editorStateChanged", params: state ?? null }`
 *     tells the host the editor's current open-file snapshot so it survives
 *     this pane's next hibernation cycle (see README.md "Editor state
 *     survives hibernation"); `{ method: "modeChanged", params: { mode } }`
 *     tells the host which mode (Diff/Editor) is live, for the same reason.
 */

type PendingCall = {
  resolve(value: unknown): void;
  reject(error: SpacesBridgeError): void;
};

const DIFF_SIGNATURE_EVENT = "spaces:diffSignature";

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

  /** Fire-and-forget state push; see class doc comment. `undefined` (no open file) is sent as
   *  `null` since `postMessage`'s structured-clone step drops `undefined`-valued properties
   *  entirely, and the Swift decoder treats "no params" the same as "explicit null". */
  notifyEditorStateChanged(state: CodePaneEditorState | undefined): void {
    const handler = window.webkit?.messageHandlers?.spacesBridge;
    handler?.postMessage({ method: "editorStateChanged", params: state ?? null });
  }

  /** Fire-and-forget state push; see class doc comment. */
  notifyModeChanged(mode: CodePaneMode): void {
    const handler = window.webkit?.messageHandlers?.spacesBridge;
    handler?.postMessage({ method: "modeChanged", params: { mode } });
  }

  async workspaceDiff(scope: DiffScope): Promise<WorkspaceDiffResult> {
    return (await this.post("workspaceDiff", { scope })) as WorkspaceDiffResult;
  }

  async workspaceFileRead(path: string): Promise<WorkspaceFileReadResult> {
    return (await this.post("workspaceFileRead", { path })) as WorkspaceFileReadResult;
  }

  async workspaceFileWrite(
    path: string,
    content: string,
    options: WorkspaceFileWriteOptions,
  ): Promise<WorkspaceFileWriteResult> {
    return (await this.post("workspaceFileWrite", { path, content, options })) as WorkspaceFileWriteResult;
  }

  async workspaceFileList(query: string): Promise<WorkspaceFileListResult> {
    return (await this.post("workspaceFileList", { query })) as WorkspaceFileListResult;
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
}

/**
 * Construct the real bridge and send the "ready" lifecycle notification.
 * Call once, from main.ts, after `window.spaces` is assigned and the
 * `spaces:init` listener (see app/root.ts) is already attached.
 */
export function createRealBridge(): SpacesBridge & { notifyReady(): void } {
  return new RealSpacesBridge();
}
