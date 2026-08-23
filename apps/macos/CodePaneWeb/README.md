# Code Pane Web

The code pane's web bundle: a self-contained plugin (Diff review + Editor modes) that runs
inside the macOS app's WKWebView and talks to the Swift host only through the typed
`window.spaces` bridge. Built with Vite + TypeScript, rendering with `@pierre/diffs`
(Shiki-based).

Nothing in this bundle makes a network request at runtime; it is loaded from `file://` and
every asset path in the built output is relative.

## Build and dev harness

```sh
npm install
npm run build       # tsc --noEmit, then vite build -> ../Sources/spacesui/Resources/CodePane/
npm run typecheck   # tsc --noEmit only
npm run test        # vitest run
npm run dev         # dev harness: mock bridge + fixture diff, at the printed localhost URL
```

`npm run build` emits directly into `apps/macos/Sources/spacesui/Resources/CodePane/`
(`vite.config.ts`'s `build.outDir`, with `emptyOutDir: true`), which is a `.copy` resource of
the `spacesui` SwiftPM target (`apps/macos/Package.swift`) and is bundled into the app at
`Bundle.module`. That output is checked into the repo, so building or testing the Swift app
never requires node — only editing this web bundle does, which then requires rerunning
`npm run build` and committing the refreshed output alongside the source change.

`npm run dev` runs against `MockSpacesBridge` (`src/bridge/mockBridge.ts`) instead of the real
WKWebView bridge, seeded with a realistic fixture diff (`src/bridge/fixtures.ts`: a modified
file, a rename, an addition, a deletion, an untracked file, a binary file, and a
daemon-truncated file). A floating "Simulate remote change" button
(`src/dev/harnessControls.ts`) fires a `spaces:diffSignature` event so the live-refresh path
(preserve scroll, re-fetch, re-render) is exercisable without a real daemon or git repo. The
harness controls and the mock bridge/fixtures are dev-only: `src/bridge/index.ts` dynamically
imports the mock only under `import.meta.env.DEV`, so Rollup tree-shakes all of it out of the
production build.

## Bridge contract

`window.spaces` (typed in `src/bridge/types.ts`) is the plugin's only way to reach the host:

- `workspaceDiff(scope)` — a `DiffScope` (`{kind:"uncommitted"}` / `{kind:"baseBranch"}` /
  `{kind:"ref", refName}`) in, a file list plus an opaque `scopeSignature` out.
- `workspaceFileRead(path)` — content, `sha256`, size.
- `workspaceFileWrite(path, content, {baseSHA256})` — compare-and-swap write; returns
  `{ok:true, sha256}` (the hash of exactly what was just written, adopted directly as the next
  save's CAS baseline) or `{conflict:true, currentSHA256}` (`currentSHA256` omitted and
  `fileMissing:true` set instead when the file was deleted out from under the write). Never
  throws for a stale write — a conflict is a normal result, not an error.
- `workspaceFileList(query)` — path search for the Editor mode file picker. **The daemon
  endpoint behind this does not exist yet** (see Open items); only the mock implements it today.
- `subscribeDiffSignature(scope, listener)` — returns an unsubscribe function. Only one scope
  is observed at a time; calling it again is expected to replace the previous subscription's
  effective scope rather than layer another live one.

Every rejected call is a `SpacesBridgeError` with a `code` (`notFound` / `invalidArgument` /
`conflict` / `internalError` / `unavailable`), never a bare string or generic `Error` — callers
branch on `.code`.

### Wire protocol (what the Swift host implements)

- **Requests (JS -> Swift):** one message handler,
  `window.webkit.messageHandlers.spacesBridge.postMessage({id, method, params})`. `id` is a
  string the JS side generates to correlate the reply.
- **Replies (Swift -> JS):** the host evaluates JS calling `window.__spacesBridge.resolve(id,
  result)` or `window.__spacesBridge.reject(id, {code, message})`. `__spacesBridge` is installed
  by `realBridge.ts` as an import-time side effect, before anything else runs, so there is no
  race between a reply arriving and the resolver existing.
- **Ready (JS -> Swift, fire-and-forget):** the same message handler with `{method:"ready"}`
  and no `id`, sent once after the plugin's `spaces:init` listener is attached. The host must
  wait for this before dispatching `spaces:init` — the plugin renders nothing until it arrives.
- **State pushes (JS -> Swift, fire-and-forget):** the same message handler, no `id`, sent so the
  host can rebuild a hibernated pane without losing what the user was doing:
  - `{method:"editorStateChanged", params}` — the Editor mode's open-file snapshot,
    `{path, baseSHA256, content, dirty}` (`CodePaneEditorState`), or `params: null` when the
    editor has no open file. Sent immediately on open/save/conflict, and debounced (~500ms
    trailing) on every buffer edit — see `src/app/editorView.ts`'s class doc comment.
  - `{method:"modeChanged", params:{mode}}` — the live Diff/Editor mode, sent immediately on
    every toolbar toggle.

  The host holds only the latest of each in memory on the pane's controller (which survives
  hibernation, unlike the `WKWebView`), and hands both back through the next `spaces:init` (see
  below) — see docs/implementation.md's hibernation section for the full rehydration model.
- **Teardown pull (Swift -> JS, synchronous):** `window.__spacesCollectEditorState` — a global
  function the host calls via `evaluateJavaScript`'s return value (not the message handler) at
  teardown, to flush whatever the editor holds at that exact instant into the snapshot above.
  This closes the one gap the debounced push above can't cover: a buffer edit still inside its
  ~500ms window when the page is torn down. Returns the `CodePaneEditorState` JSON-stringified,
  or `null` when no file is open — see `EditorView.collectStateForFlush` and
  docs/implementation.md's hibernation section.
- **Push events (Swift -> JS):** `window.dispatchEvent(new CustomEvent(name, {detail}))` for:
  - `spaces:init` (once, at startup, listened for with `{once: true}`): detail is
    `CodePaneInitPayload` — `workspaceId`, `workspaceName`, `initialMode` (`"diff"` \|
    `"editor"`, the pane's live mode — see `modeChanged` above), `initialScope` (a `DiffScope`),
    `theme` (`"light"` \| `"dark"`, the appearance in effect at startup; nothing here reads
    `prefers-color-scheme`), `baseBranch` (the workspace's configured base branch name, omitted
    for a workspace with none), and `editorState` (a `CodePaneEditorState`, omitted when the host
    holds no snapshot for this pane — see `editorStateChanged` above). The toolbar's "vs base
    branch" scope option is disabled, rather than hidden, when `baseBranch` is absent.
  - `spaces:theme` (any time the host's effective appearance changes thereafter): detail is
    `{theme}` (`"light"` \| `"dark"`). A separate event from `spaces:init` because the plugin's
    `spaces:init` listener is one-shot; a later appearance change re-dispatching `spaces:init`
    itself would have no listener left to receive it.
  - `spaces:diffSignature` (any time the active scope's git state changes): detail is
    `{scopeSignature}`. The host dedupes this end-to-end (it never re-announces a signature it
    already delivered for the current scope), so a `workspaceDiff` pull that fails after one of
    these events is never retried by anything upstream — `refreshDiff` in `root.ts` retries it
    itself, with a bounded exponential backoff (1s floor, doubling, 30s cap, reset on the next
    success) guarded by the same latest-wins request token the stale-response guard uses.

## Diff mode

A file-list sidebar plus a single `@pierre/diffs` `CodeView` holding every changed file, in
order, as one virtualized scrolling region (`src/app/diffView.ts`) — not a two-region layout.
Diffable files become `CodeViewDiffItem`s via `processFile()`; binary, truncated, and
unparseable files become synthetic plaintext placeholder items instead, so every sidebar row
(diffable or not) can jump to its file the same way. Untracked files arrive from the bridge as
git's own synthetic "new file" patches, so they render as pure additions with no `oldFile`
side. A scope switch replaces the file set outright; a `spaces:diffSignature` event re-fetches
and re-renders while preserving scroll position. Split/unified is `diffStyle` on `CodeView`, not
the `layout` option (that one only controls padding/gap).

## Editor mode

An open-file bar (`src/app/editorView.ts`) feeding a single-item, edit-mode `CodeView`. Two ways
in: typing a full path and pressing Return (always works, straight through `workspaceFileRead`),
or picking a result from the debounced `workspaceFileList` search — see the open item below for
why that one degrades to a quiet hint today. Save goes through the CAS `workspaceFileWrite`; on a
conflict the UI shows a non-blocking banner and disables Save without discarding the user's
edits — resolving a conflict (full merge UI) is Phase 5's scope, out of scope here. A successful
save adopts the write result's own `sha256` directly as the CAS baseline for the next save, with
no re-read round trip.

An open file's path, CAS baseline, and buffer survive the pane hibernating (a tab or workspace
switch away and back): `editorView.ts` pushes `editorStateChanged` to the host on every discrete
transition and (debounced) on buffer edits, and the host additionally pulls the live snapshot
synchronously at teardown via `window.__spacesCollectEditorState`, so an edit still inside the
debounce window is never lost to a hibernation racing the timer. The host rehydrates the result
through the next `spaces:init` — see the wire protocol section above and docs/implementation.md's
hibernation section. An app restart, not just hibernation, does lose an unsaved buffer: the
snapshot is memory-only on the host side, with no disk persistence.

## Toolbar

One 30pt strip (`src/app/toolbar.ts`), Variant A from the picked mockup: a Diff|Editor toggle
visible in both modes; in Diff mode, a scope segmented control (Uncommitted / vs base branch /
vs ref…, the last opening an inline ref/SHA input) and a Split|Unified toggle. The trailing
region renders an empty placeholder (`.agent-slot`) reserved for Phase 4's assigned-agent
dropdown and "Send batch" button — nothing is drawn there yet.

## Language set and bundle size

`src/theme/index.ts` preloads Shiki for a fixed set: `typescript`, `javascript`, `tsx`, `jsx`,
`swift`, `python`, `go`, `rust`, `c`, `cpp`, `objective-c`, `json`, `yaml`, `toml`, `html`,
`css`, `markdown`, `shellscript`, `sql`, plus `text` as the fallback. Every call site that hands
a file to `CodeView` (`diffView.ts`, `editorView.ts`) explicitly sets `lang` via
`resolveAllowedLanguage()` rather than letting `@pierre/diffs` auto-detect it from the filename:
auto-detection can resolve to any of Shiki's ~180 bundled languages, and the shared highlighter
only has the set above attached, so an unresolved language would make the highlighter throw and
`@pierre/diffs` would render a visible error box in its place (its default
`disableErrorHandling: false` behavior) instead of the plaintext fallback this bundle wants.
Forcing `lang` explicitly (falling back to `"text"` for anything outside the set) is what makes
the plaintext fallback actually plaintext.

`@pierre/diffs`'s language resolver (`resolveLanguage.js`) statically imports Shiki's full
`bundledLanguages` map from the `shiki` package; this is a closed set of dynamic `import()`
targets that Rollup must code-split into a chunk per language regardless of which ones
`preloadHighlighter` is ever asked to load. There's no public `@pierre/diffs` option to swap in
a scoped highlighter that only knows about these files. As a result the built output is ~11MB
across ~320 files, but only the entry chunk (~740KB) and its CSS load eagerly — `index.html` has
a single `<script type="module">` tag and no `modulepreload` hints — and `resolveAllowedLanguage`
guarantees only the 19 whitelisted languages' chunks can ever actually be requested at runtime,
since anything else resolves to `"text"` first. The remaining ~300 files sit on disk unused.
Aliasing `shiki`'s `bundledLanguages` export to a hand-curated subset (Shiki's documented
"fine-grained bundle" pattern) would shrink the built output to just the 19 languages, but requires
re-exporting the rest of `shiki`'s value exports that `@pierre/diffs` also imports from the
same specifier, reaching into a third-party package's unexported deep paths — left as an open
decision rather than done unilaterally (see Open items).

## Tests

`npm run test` (Vitest + jsdom): `test/bridge.test.ts` covers the real bridge's promise
correlation (including out-of-order replies), unknown-error-code normalization to
`internalError`, dropped replies for untracked ids, `unavailable` when the WKWebView handler
isn't installed, and the mock bridge's CAS conflict/success shapes and signature-event
subscribe/unsubscribe/dedup behavior. `test/state.test.ts` covers `codePaneReducer` for all five
actions and `initialState`. `test/editorView.test.ts` covers the open-file picker's direct-path
Enter-to-open flow, its error surfacing on a rejected read, and the quiet-hint degradation when
`workspaceFileList` is unavailable (`@pierre/diffs`' `CodeView`/`Editor` are stubbed out — these
tests are about the picker's own logic, not the diff-rendering library), a save adopting the
write result's own hash as the next CAS baseline with no intervening file read, the
`editorStateChanged` push firing immediately on open/save/conflict and debounced on edits, and
`restoreState` rehydrating a dirty snapshot without a disk re-read versus re-reading a clean one
from `path`, and `collectStateForFlush` returning the latest buffer (including an edit still
inside the debounce window) or `null` with no file open. `test/root.test.ts` covers `refreshDiff`'s
stale-response guard (a slower, superseded scope's reply, success or error, never overwrites a
newer scope's already-applied result), its bounded-backoff retry on a failed pull (floor, doubling,
cap, reset-on-success, and a scope switch superseding a pending retry), and the `modeChanged` push
firing on every toolbar toggle. `test/toolbar.test.ts` covers
the "vs base branch" option's disabled/enabled state and label based on whether `baseBranch` is
present, and that a click reaching a disabled button never fires `onScopeChange`.

## Open items (Swift-host integration)

- **`workspaceFileList` has no daemon endpoint yet.** The bridge contract, mock, and Editor
  mode's search are built against the shape in `src/bridge/types.ts`; real usage rejects
  `unavailable` until that endpoint lands, and the picker degrades to a quiet hint pointing at
  the direct-path Return-to-open flow instead.
- **Phase 4** (assigned-agent dropdown, "Send batch" button, comment surface) and **Phase 5**
  (merge conflict resolution UI) are out of scope here; the toolbar's `.agent-slot` and the
  editor's conflict banner are the only hooks left for them.
- **The file-list sidebar is not in Variant A's literal mockup markup** — Variant A's own
  markup has no file-picker chrome, so this bundle borrows Variant B's `.rail`/`.rr` token and
  metric vocabulary for it (see comments in `src/styles/app.css`), since a file list is a hard
  functional requirement of Diff mode regardless of which toolbar variant was picked.
  Confirming this deviation against the mockup's intent is worth a look before Swift-host
  integration locks in the pane's overall layout.
  - **Shiki bundle size**, discussed above: whether the ~11MB/~320-file built output (only
  ~740KB of which loads eagerly) is acceptable as-is, or worth a `shiki` aliasing pass to
  physically shrink it to the 19 languages.
