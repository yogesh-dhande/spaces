import { CodePaneAgentSummary, CodePaneInitPayload, DiffFileEntry, DiffScope } from "./types";

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

/** The full fixture file set, as returned for `scope: { kind: "uncommitted" }`. */
const UNCOMMITTED_FILES: DiffFileEntry[] = [
  {
    path: "src/app/toolbar.ts",
    status: "modified",
    patch: MODIFIED_PATCH,
    isBinary: false,
    truncated: false,
    oldSHA: "a1b2c3d",
    newSHA: "e4f5a6b",
  },
  {
    path: "src/utils/dateFormat.ts",
    oldPath: "src/utils/formatDate.ts",
    status: "renamed",
    patch: RENAMED_PATCH,
    isBinary: false,
    truncated: false,
    oldSHA: "9c8b7a6",
    newSHA: "1d2e3f4",
  },
  {
    path: "src/app/newFeature.ts",
    status: "added",
    patch: ADDED_PATCH,
    isBinary: false,
    truncated: false,
    newSHA: "7f6e5d4",
  },
  {
    path: "src/legacy/oldHelper.ts",
    status: "deleted",
    patch: DELETED_PATCH,
    isBinary: false,
    truncated: false,
    oldSHA: "3c2b1a0",
  },
  {
    path: "notes/TODO.md",
    status: "untracked",
    patch: UNTRACKED_PATCH,
    isBinary: false,
    truncated: false,
  },
  {
    path: "assets/logo.png",
    status: "modified",
    isBinary: true,
    truncated: false,
    oldSHA: "b5a4c3d",
    newSHA: "d3c4a5b",
  },
  {
    path: "dist/bundle.generated.js",
    status: "modified",
    isBinary: false,
    truncated: true,
    oldSHA: "1111111",
    newSHA: "2222222",
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
    truncated: false,
    newSHA: "8a9b7c6",
  },
];

/** `vs base branch` and named-ref scopes intentionally return a smaller subset, so switching scopes in the harness visibly changes the file list. */
const BASE_BRANCH_FILES: DiffFileEntry[] = UNCOMMITTED_FILES.slice(0, 4);

export function fixtureDiffFiles(scope: DiffScope, version: number): DiffFileEntry[] {
  if (scope.kind === "uncommitted") {
    return version % 2 === 0 ? UNCOMMITTED_FILES : UNCOMMITTED_FILES_V2;
  }
  if (scope.kind === "baseBranch") {
    return BASE_BRANCH_FILES;
  }
  // scope.kind === "ref": only "main" has fixture data; any other ref name
  // demonstrates the "No changes" empty state.
  return scope.refName === "main" ? BASE_BRANCH_FILES : [];
}

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

/** Broader path universe for the `workspaceFileList` picker mock, beyond just the files that already have diffs or open content. */
export const FIXTURE_ALL_PATHS: string[] = [
  ...Object.keys(FIXTURE_FILE_CONTENTS),
  "src/app/editorView.ts",
  "src/app/diffView.ts",
  "src/app/fileList.ts",
  "src/bridge/types.ts",
  "src/bridge/mockBridge.ts",
  "README.md",
  "package.json",
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
  initialMode: "diff",
  initialScope: { kind: "uncommitted" },
  theme: "dark",
  agents: FIXTURE_AGENTS,
};
