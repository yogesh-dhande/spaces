import {
  FIXTURE_ALL_PATHS,
  FIXTURE_FILE_CONTENTS,
  FIXTURE_INIT_PAYLOAD,
  fixtureDiffFiles,
  fixtureHash,
} from "./fixtures";
import {
  CodePaneEditorState,
  CodePaneMode,
  DiffScope,
  DiffSignatureListener,
  SpacesBridge,
  SpacesBridgeError,
  Unsubscribe,
  WorkspaceDiffResult,
  WorkspaceFileListResult,
  WorkspaceFileReadResult,
  WorkspaceFileWriteOptions,
  WorkspaceFileWriteResult,
} from "./types";

const INIT_EVENT = "spaces:init";
const DIFF_SIGNATURE_EVENT = "spaces:diffSignature";

/** Small fixed delay so the harness's loading states are visible, without making manual testing feel sluggish. */
const MOCK_LATENCY_MS = 120;

function delay<T>(value: T): Promise<T> {
  return new Promise((resolve) => setTimeout(() => resolve(value), MOCK_LATENCY_MS));
}

function scopeKey(scope: DiffScope): string {
  return scope.kind === "ref" ? `ref:${scope.refName}` : scope.kind;
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
  private readonly files = new Map<string, { content: string; sha256: string }>(
    Object.entries(FIXTURE_FILE_CONTENTS).map(([path, content]) => [path, { content, sha256: fixtureHash(content) }]),
  );

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

  async workspaceDiff(scope: DiffScope): Promise<WorkspaceDiffResult> {
    void scopeKey(scope);
    const files = fixtureDiffFiles(scope, this.version);
    return delay({ scopeSignature: `fixture-v${this.version}`, files });
  }

  async workspaceFileRead(path: string): Promise<WorkspaceFileReadResult> {
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
    if (!entry) {
      throw new SpacesBridgeError("notFound", `No such file in the mock workspace: ${path}`);
    }
    if (entry.sha256 !== options.baseSHA256) {
      return delay({ conflict: true, currentSHA256: entry.sha256 });
    }
    const sha256 = fixtureHash(content);
    this.files.set(path, { content, sha256 });
    return delay({ ok: true, sha256 });
  }

  async workspaceFileList(query: string): Promise<WorkspaceFileListResult> {
    const q = query.trim().toLowerCase();
    const paths = q.length === 0 ? FIXTURE_ALL_PATHS : FIXTURE_ALL_PATHS.filter((p) => p.toLowerCase().includes(q));
    return delay({ paths });
  }

  subscribeDiffSignature(_scope: DiffScope, listener: DiffSignatureListener): Unsubscribe {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  }

  // The dev harness and unit tests never hibernate a real WKWebView, so there is nothing for the
  // mock to persist or rehydrate here — these two are no-ops purely to satisfy `SpacesBridge`.
  notifyEditorStateChanged(_state: CodePaneEditorState | undefined): void {}

  notifyModeChanged(_mode: CodePaneMode): void {}
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
