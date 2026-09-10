import {
  CodePaneAgentSummary,
  CodePaneInitPayload,
  DiffFileEntry,
  DiffFileManifestEntry,
  DiffScope,
  WorkspaceRefListResult,
  WorkspaceSubmodule,
} from "./types";

/**
 * Fixture data for the `npm run dev` harness and for the mock bridge's unit
 * tests. Nothing here ships in the production bundle: `mockBridge.ts` is only
 * imported from the dev-only branch in `bridge/index.ts`, which Rollup
 * tree-shakes out of `dist` (see that file's doc comment).
 */

/** Not a real SHA-256: a small deterministic string hash, good enough to give the mock CAS semantics (equality of "has content changed since last read") without pulling in a crypto dependency for fixture data. */
export function fixtureHash(content: string): string {
  let hash = 5381;
  for (let i = 0; i < content.length; i++) {
    hash = (hash * 33) ^ content.charCodeAt(i);
  }
  return `fx${(hash >>> 0).toString(16).padStart(8, "0")}`;
}

const MODIFIED_PATCH = `diff --git a/src/app/toolbar.ts b/src/app/toolbar.ts
index a1b2c3d..e4f5a6b 100644
--- a/src/app/toolbar.ts
+++ b/src/app/toolbar.ts
@@ -12,7 +12,8 @@ export function renderToolbar(state: ToolbarState): HTMLElement {
   const el = document.createElement("div");
   el.className = "pane-hdr";

-  el.appendChild(renderModeToggle(state.mode));
+  const modeToggle = renderModeToggle(state.mode);
+  el.appendChild(modeToggle);
   el.appendChild(renderScopePicker(state.scope));

   if (state.mode === "diff") {
`;

const RENAMED_PATCH = `diff --git a/src/utils/formatDate.ts b/src/utils/dateFormat.ts
similarity index 92%
rename from src/utils/formatDate.ts
rename to src/utils/dateFormat.ts
index 9c8b7a6..1d2e3f4 100644
--- a/src/utils/formatDate.ts
+++ b/src/utils/dateFormat.ts
@@ -1,5 +1,6 @@
+// Renamed from formatDate.ts to match the dateX naming used elsewhere.
 export function formatDate(date: Date): string {
   const y = date.getFullYear();
   const m = String(date.getMonth() + 1).padStart(2, "0");
   const d = String(date.getDate()).padStart(2, "0");
   return \`\${y}-\${m}-\${d}\`;
 }
`;

const ADDED_PATCH = `diff --git a/src/app/newFeature.ts b/src/app/newFeature.ts
new file mode 100644
index 0000000..7f6e5d4
--- /dev/null
+++ b/src/app/newFeature.ts
@@ -0,0 +1,6 @@
+export function newFeature(): string {
+  // Placeholder for the feature under review.
+  return "new-feature";
+}
+
+export const NEW_FEATURE_FLAG = "new-feature-enabled";
`;

const DELETED_PATCH = `diff --git a/src/legacy/oldHelper.ts b/src/legacy/oldHelper.ts
deleted file mode 100644
index 3c2b1a0..0000000
--- a/src/legacy/oldHelper.ts
+++ /dev/null
@@ -1,4 +0,0 @@
-export function oldHelper(): void {
-  // Superseded by newFeature().
-  console.log("old helper");
-}
`;

/** Untracked files have no git history to diff against; rendered as additions using a synthetic "new file" patch, matching git's own convention for `--no-index` style output. */
const UNTRACKED_PATCH = `diff --git a/notes/TODO.md b/notes/TODO.md
new file mode 100644
index 0000000..2a4b6c8
--- /dev/null
+++ b/notes/TODO.md
@@ -0,0 +1,3 @@
+# TODO
+
+- Wire up Phase 4 comment surface.
`;

/** A file nested inside the `sbc_hal` submodule fixture. */
const SBC_HAL_BUMPVERSION_PATCH = `diff --git a/.bumpversion.cfg b/.bumpversion.cfg
index 2b1c3d4..5e6f7a8 100644
--- a/.bumpversion.cfg
+++ b/.bumpversion.cfg
@@ -1,3 +1,3 @@
 [bumpversion]
-current_version = 1.4.2
+current_version = 1.4.3
 commit = True
`;

/** A file nested inside the `sbc_hal/api_commands` submodule fixture, itself nested inside `sbc_hal`. */
const UART_C_PATCH = `diff --git a/uart.c b/uart.c
index 1a2b3c4..4d5e6f7 100644
--- a/uart.c
+++ b/uart.c
@@ -8,6 +8,7 @@ int uart_init(uint32_t baud_rate) {
   uart_set_baud(baud_rate);
   uart_enable_tx();
   uart_enable_rx();
+  uart_flush();
   return 0;
 }
`;

/** An untracked file nested inside the `sbc_hal` submodule fixture. */
const EXAMPLE_PINOUT_PATCH = `diff --git a/example_pinout.md b/example_pinout.md
new file mode 100644
index 0000000..9f8e7d6
--- /dev/null
+++ b/example_pinout.md
@@ -0,0 +1,3 @@
+# Example Pinout
+
+See schematic.pdf for pin assignments.
`;

/** The full fixture file set, as returned for `scope: { kind: "uncommitted" }`. */
const UNCOMMITTED_FILES: DiffFileEntry[] = [
  {
    path: "src/app/toolbar.ts",
    status: "modified",
    patch: MODIFIED_PATCH,
    isBinary: false,
    oldSHA: "a1b2c3d",
    newSHA: "e4f5a6b",
  },
  {
    path: "src/utils/dateFormat.ts",
    oldPath: "src/utils/formatDate.ts",
    status: "renamed",
    patch: RENAMED_PATCH,
    isBinary: false,
    oldSHA: "9c8b7a6",
    newSHA: "1d2e3f4",
  },
  {
    path: "src/app/newFeature.ts",
    status: "added",
    patch: ADDED_PATCH,
    isBinary: false,
    newSHA: "7f6e5d4",
  },
  {
    path: "src/legacy/oldHelper.ts",
    status: "deleted",
    patch: DELETED_PATCH,
    isBinary: false,
    oldSHA: "3c2b1a0",
  },
  {
    path: "notes/TODO.md",
    status: "untracked",
    patch: UNTRACKED_PATCH,
    isBinary: false,
  },
  {
    path: "assets/logo.png",
    status: "modified",
    isBinary: true,
    oldSHA: "b5a4c3d",
    newSHA: "d3c4a5b",
  },
  // A nested submodule set: `sbc_hal`'s pointer row, its own changed files, a nested submodule
  // (`sbc_hal/api_commands`) checked out inside it with its own changed file, and a second
  // top-level pointer (`documentation`) that is not checked out. Exercises the dev harness's
  // read-only placeholder rows (see diffView.ts's `submoduleLabel`) and nested-file rendering
  // alongside every other fixture status. Order matters: nested entries immediately follow their
  // enclosing pointer row, matching the daemon's manifest contract.
  {
    path: "sbc_hal",
    status: "modified",
    isBinary: false,
    submodule: {
      oldCommit: "fa1d453d0f015c4446ac975bab077fe6bb0b184f",
      newCommit: "128a927b0eb3ce10dc6ffe974b5a368456f974ca",
      dirty: true,
      unmerged: false,
      checkedOut: true,
    },
  },
  {
    path: "sbc_hal/.bumpversion.cfg",
    status: "modified",
    isBinary: false,
    submodulePath: "sbc_hal",
    patch: SBC_HAL_BUMPVERSION_PATCH,
    oldSHA: "2b1c3d4",
    newSHA: "5e6f7a8",
  },
  {
    path: "sbc_hal/api_commands",
    status: "modified",
    isBinary: false,
    submodulePath: "sbc_hal",
    submodule: {
      oldCommit: "9c1e2f3a4b5c6d7e8f9a0b1c2d3e4f5a6b7c8d9e",
      newCommit: "0a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b",
      dirty: false,
      unmerged: false,
      checkedOut: true,
    },
  },
  {
    path: "sbc_hal/api_commands/uart.c",
    status: "modified",
    isBinary: false,
    submodulePath: "sbc_hal/api_commands",
    patch: UART_C_PATCH,
    oldSHA: "1a2b3c4",
    newSHA: "4d5e6f7",
  },
  {
    path: "sbc_hal/example_pinout.md",
    status: "untracked",
    isBinary: false,
    submodulePath: "sbc_hal",
    patch: EXAMPLE_PINOUT_PATCH,
  },
  // A pointer the diff nested nothing under (never initialized, missing the comparison commit, or
  // deeper than the depth guard): a sha pair with the ", not checked out" suffix and no nested
  // entries. Its flags are reported independently of that, so this fixture leaves them clear.
  {
    path: "documentation",
    status: "modified",
    isBinary: false,
    submodule: {
      oldCommit: "3f4a5b6c7d8e9f0a1b2c3d4e5f6a7b8c9d0e1f2a",
      newCommit: "4a5b6c7d8e9f0a1b2c3d4e5f6a7b8c9d0e1f2a3b",
      dirty: false,
      unmerged: false,
      checkedOut: false,
    },
  },
];

/** A second snapshot used by `simulateSignatureChange` to demonstrate a live refresh: one file's patch grows, and a new addition appears. */
const UNCOMMITTED_FILES_V2: DiffFileEntry[] = [
  {
    ...UNCOMMITTED_FILES[0]!,
    patch: `${MODIFIED_PATCH}@@ -25,6 +26,7 @@ export function renderToolbar(state: ToolbarState): HTMLElement {
   el.appendChild(renderScopeSegmentedControl(state.scope));
   el.appendChild(renderLayoutToggle(state.layout));
+  el.appendChild(renderAgentDropdownPlaceholder());
   return el;
 }
`,
  },
  ...UNCOMMITTED_FILES.slice(1),
  {
    path: "src/app/anotherChange.ts",
    status: "added",
    patch: `diff --git a/src/app/anotherChange.ts b/src/app/anotherChange.ts
new file mode 100644
index 0000000..8a9b7c6
--- /dev/null
+++ b/src/app/anotherChange.ts
@@ -0,0 +1,2 @@
+// Arrived via a simulated remote change event.
+export const ANOTHER_CHANGE = true;
`,
    isBinary: false,
    newSHA: "8a9b7c6",
  },
];

/** `lastCommit` and named-ref scopes intentionally return a smaller subset, so switching scopes in the harness visibly changes the file list. */
const LAST_COMMIT_FILES: DiffFileEntry[] = UNCOMMITTED_FILES.slice(0, 4).map((file) => ({
  ...file,
  // The harness treats this as an immutable revision identifier. The mock bridge's fixture data is
  // shared with the worktree, so Last Commit editing remains exercisable in the browser harness.
  targetRevision: "0123456789abcdef0123456789abcdef01234567",
}));

export function fixtureDiffFiles(scope: DiffScope, version: number): DiffFileEntry[] {
  if (scope.kind === "uncommitted") {
    return version % 2 === 0 ? UNCOMMITTED_FILES : UNCOMMITTED_FILES_V2;
  }
  if (scope.kind === "lastCommit") {
    return LAST_COMMIT_FILES;
  }
  // scope.kind === "ref": only "main" has fixture data; any other ref name
  // (including one of the fixture SHAs in FIXTURE_REF_LIST below) demonstrates the "No changes"
  // empty state.
  return scope.refName === "main" ? LAST_COMMIT_FILES : [];
}

/** Metadata-first counterpart to `fixtureDiffFiles`: the mock deliberately strips patch bodies so
 * dev mode exercises the same immediate-sidebar / deferred-file rendering path as production. */
export function fixtureDiffManifest(scope: DiffScope, version: number): DiffFileManifestEntry[] {
  return fixtureDiffFiles(scope, version).map(({ path, oldPath, status, submodule, submodulePath }) => ({
    path,
    oldPath,
    status,
    // `isSubmodule` is a manifest-only flag: present (true) only for a gitlink entry, absent for
    // every ordinary file, matching the wire contract's "absent otherwise" (`DiffFileManifestEntry`).
    ...(submodule !== undefined ? { isSubmodule: true as const } : {}),
    ...(submodulePath !== undefined ? { submodulePath } : {}),
  }));
}

/** Backs the mock's `workspaceRefList()` — the compare menu's "Branch…" / "Commit or ref…" search
 *  dialog fetches this fresh on every open. `commits`' shas are real 40-character SHA-1 hex hashes
 *  (of the fixture strings below), so the dialog's 7-character truncation and full-sha round trip
 *  through `DiffScope`'s `ref` kind behave exactly as they would against a real workspace. */
export const FIXTURE_REF_LIST: WorkspaceRefListResult = {
  branches: ["main", "feature/pane-toolbar", "release/1.4", "yd/review-comments"],
  branchesTruncated: false,
  commits: [
    { sha: "38afff17e4815ab309bf1d7ffca0787e805f7af8", subject: "Add compare menu to the diff pane header" },
    { sha: "df277975d2783b0e7fd4d0487d990bd60442923c", subject: "Fix conflict banner focus trap" },
    { sha: "a549a44b3316991928c80b3bee0eb916d16c9dcc", subject: "Debounce editor state pushes" },
    { sha: "51e560e4d4dacc331c2c4232a7f2d3815bfdadf5", subject: "Truncate oversized generated-file patches" },
    { sha: "6ff2a3583ee231701dfbe81b175ba2938202db7b", subject: "Seed recent-files list from init payload" },
  ],
  commitsTruncated: false,
};

/** Files readable/writable in Editor mode. Keyed by workspace-relative path. */
export const FIXTURE_FILE_CONTENTS: Record<string, string> = {
  "src/app/toolbar.ts": `export function renderToolbar(state: ToolbarState): HTMLElement {
  const el = document.createElement("div");
  el.className = "pane-hdr";

  const modeToggle = renderModeToggle(state.mode);
  el.appendChild(modeToggle);
  el.appendChild(renderScopePicker(state.scope));

  if (state.mode === "diff") {
    el.appendChild(renderScopeSegmentedControl(state.scope));
    el.appendChild(renderLayoutToggle(state.layout));
  }
  return el;
}
`,
  "src/app/newFeature.ts": `export function newFeature(): string {
  // Placeholder for the feature under review.
  return "new-feature";
}

export const NEW_FEATURE_FLAG = "new-feature-enabled";
`,
  "notes/TODO.md": `# TODO

- Wire up Phase 4 comment surface.
`,
};

/** The mock's full workspace listing (`workspaceFileList`'s `paths`), backing Editor mode's Files
 *  tree and the ⌘P quick-open overlay — broader than just the files that already have diffs or
 *  open content above. Includes the nested submodule files inline, matching the daemon's contract
 *  that `paths` carries checked-out submodule contents rather than listing them separately. */
export const FIXTURE_ALL_PATHS: string[] = [
  ...Object.keys(FIXTURE_FILE_CONTENTS),
  "src/app/editorView.ts",
  "src/app/diffView.ts",
  "src/app/fileList.ts",
  "src/bridge/types.ts",
  "src/bridge/mockBridge.ts",
  "README.md",
  "package.json",
  "sbc_hal/.bumpversion.cfg",
  "sbc_hal/api_commands/uart.c",
  "sbc_hal/example_pinout.md",
];

/** The mock's checked-out submodules, nested ones included, backing
 *  `WorkspaceFileListResult.submodules`. Each `commit` matches the pointer the corresponding
 *  fixture diff entry moved to, so the Files tree's chip and the Changes list's chip name the same
 *  commit. `documentation` is deliberately absent: its fixture pointer row is not checked out. */
export const FIXTURE_SUBMODULES: WorkspaceSubmodule[] = [
  { path: "sbc_hal", commit: "128a927b0eb3ce10dc6ffe974b5a368456f974ca" },
  { path: "sbc_hal/api_commands", commit: "0a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b" },
];

/** Two running agents by default so the harness demonstrates the manual-pick dropdown state;
 *  `simulateAgentsChange` (dev-only harness control) cycles down to one (auto-default) and to
 *  none (sending disabled) and back. */
export const FIXTURE_AGENTS: CodePaneAgentSummary[] = [
  { id: "agent-1", label: "claude · main", sessionId: "session-1" },
  { id: "agent-2", label: "codex · fix-flaky-test", sessionId: "session-2" },
];

export const FIXTURE_INIT_PAYLOAD: CodePaneInitPayload = {
  workspaceId: "fixture-workspace",
  workspaceName: "spaces-demo",
  workspaceState: {
    mode: "diff",
    scope: { kind: "uncommitted" },
    diffLayout: "unified",
    editorSidebarMode: "files",
    editorRecentPaths: [],
    selectedAgentSessionId: null,
    pendingAgentLaunch: null,
    diffTreeSelectedPath: null,
    fileTreeExpandedPaths: [],
    diffScrollSide: null,
    diffFocusedPath: null,
    diffFocusedSide: null,
  },
  theme: "dark",
  isGitRepository: true,
  // Matches FIXTURE_REF_LIST.branches so the harness's "Branch…" search dialog demonstrates the
  // "base" badge and first-sort behavior.
  baseBranch: "main",
  agents: FIXTURE_AGENTS,
};
