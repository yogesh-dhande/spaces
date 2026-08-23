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
- `reviewCommentList()` — every draft comment in the workspace, called once from `root.ts` after
  mount to rehydrate `CommentsController`'s in-memory mirror; never called again afterward (see
  "Comments" below for why).
- `reviewCommentUpsert({id?, filePath, side, lineNumber, lineText, body})` — creates a draft when
  `id` is omitted, updates one in place when present. Rejects `notFound` for an `id` with no
  matching draft.
- `reviewCommentDelete(id)` — deletes one draft.
- `reviewCommentsSend(sessionId, text, comments)` — sends `text` to the agent session, then, only
  once that write succeeds, archives every draft named in `comments` (each entry an `{id,
  revision}` pair; the daemon rejects `conflict` if a draft's current `revision` no longer
  matches, before sending anything). A rejection leaves every named draft exactly as it was; the
  caller must not remove them from its own state before this resolves. The guarantee is
  send-then-archive ordering, not two-way atomicity — see "Send failure leaves drafts untouched"
  below.

`SpacesReviewComment` (a draft, as returned by `reviewCommentList`/`reviewCommentUpsert`):
`{id, filePath, side, lineNumber, lineText, body, createdAt, revision}`. `revision` is a monotonic
counter the daemon bumps on every update, used as the send-concurrency token in place of a
timestamp (see docs/implementation.md for why a timestamp can't distinguish two edits inside the
same second).

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
  - `window.__spacesCollectReviewCommentState` mirrors the mechanism exactly, for comment drafts:
    there is no continuous push for draft text (unlike `editorStateChanged` above), so this
    synchronous teardown pull is the only way a not-yet-blurred keystroke reaches the host at all.
    Returns a JSON-stringified `PendingReviewCommentEntry[]` (one entry per draft with unsaved
    live text — a still-provisional card with non-empty text, or a persisted draft whose live text
    differs from its last save), or `null` when nothing qualifies — see
    `CommentsController.collectStateForFlush` and docs/implementation.md's hibernation section.
- **Push events (Swift -> JS):** `window.dispatchEvent(new CustomEvent(name, {detail}))` for:
  - `spaces:init` (once, at startup, listened for with `{once: true}`): detail is
    `CodePaneInitPayload` — `workspaceId`, `workspaceName`, `initialMode` (`"diff"` \|
    `"editor"`, the pane's live mode — see `modeChanged` above), `initialScope` (a `DiffScope`),
    `theme` (`"light"` \| `"dark"`, the appearance in effect at startup; nothing here reads
    `prefers-color-scheme`), `baseBranch` (the workspace's configured base branch name, omitted
    for a workspace with none), `editorState` (a `CodePaneEditorState`, omitted when the host
    holds no snapshot for this pane — see `editorStateChanged` above), and `pendingReviewComments`
    (a `PendingReviewCommentEntry[]`, omitted when the host holds no such snapshot — see
    `__spacesCollectReviewCommentState` above; seeded into `CommentsController` via
    `restorePendingState` before `loadInitial()`'s network call, so a teardown racing that call
    can't discard the seeded text). The toolbar's "vs base
    branch" scope option is disabled, rather than hidden, when `baseBranch` is absent. `agents`
    is the array of currently running agents in the workspace (`CodePaneAgentSummary`:
    `{id, label, sessionId}`), seeding the toolbar's assigned-agent picker at startup.
  - `spaces:agents` (any time the workspace's set of running agents changes thereafter): detail is
    `{agents}`, the full replacement list (no web-side dedupe). If the currently selected agent id
    is no longer present, `CommentsController` re-runs the same auto-default rule used at init
    (`selectDefaultAgentId`); if it is still present, the selection is left alone.
  - `spaces:theme` (any time the host's effective appearance changes thereafter): detail is
    `{theme}` (`"light"` \| `"dark"`). A separate event from `spaces:init` because the plugin's
    `spaces:init` listener is one-shot; a later appearance change re-dispatching `spaces:init`
    itself would have no listener left to receive it.
  - `spaces:diffSignature` (any time the active scope's git state changes): detail is
    `{scopeSignature}`. The host dedupes this end-to-end (it never re-announces a signature it
    already delivered for the current scope), so a `workspaceDiff` pull that fails after one of
    these events is never retried by anything upstream unless `refreshDiff` in `root.ts` decides to
    retry it itself. It classifies the rejection first: a typed `SpacesBridgeError` means the
    daemon decoded the request and rejected it for a durable reason (a bad/deleted ref, a gone
    workspace, ...), so the identical request would fail the identical way on every retry —
    `refreshDiff` renders that message in place of the file list instead, and does not retry. The
    two exceptions within that typed set are the `unavailable` and `internalError` codes. The Swift
    host's `CodePaneBridge.mapClientError` collapses every not-reachable/not-ready client failure
    (device offline, daemon mid-restart, connection not yet established) into `unavailable`; the
    daemon returns `internalError` for its own transient git trouble (a wedged or timed-out git
    subprocess) while a caller-supplied ref that simply does not resolve is validated separately and
    rejected as `invalidArgument` instead (see `assertRefIsResolvable` in
    `SpacesDeviceWorkspaceGit.swift`), so `internalError` is never used for a bad ref. Unlike every
    other typed code, both describe a transient condition rather than a durable rejection of this
    request — `refreshDiff` renders either one (so the user sees why the pane is empty) but also
    retries it with the same bounded backoff as an untyped failure. Any other (untyped) rejection is
    treated as a transport-level hiccup that retrying might resolve, and gets the bounded exponential
    backoff (1s floor, doubling, 30s cap, reset on the next success or on a rendered permanent error)
    guarded by the same latest-wins request token the stale-response guard uses. Either way, a later
    scope switch or `spaces:diffSignature` event calls `refreshDiff` fresh on its own, which is what
    recovers a pane out of the rendered-error state — for the retried `unavailable`/`internalError`
    cases, the background retry loop can also recover it without waiting for either of those.

## Diff mode

A file-list sidebar plus a single `@pierre/diffs` `CodeView` holding every changed file, in
order, as one virtualized scrolling region (`src/app/diffView.ts`) — not a two-region layout.
Diffable files become `CodeViewDiffItem`s via `processFile()`; binary, truncated, and
unparseable files become synthetic plaintext placeholder items instead, so every sidebar row
(diffable or not) can jump to its file the same way. Untracked files arrive from the bridge as
git's own synthetic "new file" patches, so they render as pure additions with no `oldFile`
side. A scope switch clears the file list and diff area to a loading state synchronously (comments
collapse to the tray, re-anchoring once the new files land) before its `refreshDiff` fetch
replaces the file set outright; a `spaces:diffSignature` event re-fetches and re-renders while
preserving scroll position. Split/unified is `diffStyle` on `CodeView`, not
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
region (`.agent-slot`, empty in Editor mode — comments are diff-mode only) renders the
assigned-agent picker and "Send batch · n" button: a static label when exactly one agent runs, a
`<select>` (with a disabled placeholder option) when more than one runs, and nothing sendable when
zero run. "Send batch" is disabled, with an explanatory `title`, whenever there is no running
agent, no agent selected, or zero drafts with a non-empty body; otherwise it sends every current
draft via `CommentsController.sendBatch()`.

## Comments

Diff-mode-only line comments (`src/app/commentsController.ts`, `src/app/reviewComments.ts`), owned
end to end by `CommentsController`:

- **Draft = the unit.** A draft attaches to a `(filePath, side, lineNumber, lineText)` and renders
  as an inline card under that line, via `@pierre/diffs`' `renderAnnotation`/`onGutterUtilityClick`
  hooks (`DiffCommentHooks` in `src/app/diffView.ts`). Every draft is always part of the batch —
  there is no separate batched/unbatched data state. "Send to `<agent>`" on a card sends that one
  draft immediately; "Add to batch" only hides the card (tracked in `collapsedIds`, UI-only) and
  moves it into the tray; clicking its tray row un-hides it. "Send batch · n" in the toolbar sends
  every current draft with a non-empty body in one call.
- **Creation and persistence.** The gutter's hover affordance opens a new card immediately with no
  RPC — the daemon rejects an empty-body `reviewCommentUpsert` outright, so a just-opened card is
  *provisional*: rendered under a local id, sendable/batchable state stays off, and nothing exists
  server-side yet. The body is saved via `reviewCommentUpsert` on the textarea's `blur` only (no
  per-keystroke save, no debounce timer); the first successful save for a provisional card omits
  `id` to create it and adopts the response's server-assigned id as the card's key from then on,
  every save after that updates by that id. A draft emptied back out (or never typed into) is
  discarded silently on blur — deleted server-side if it had already been persisted, or just dropped
  from the local mirror with no RPC at all if it was still provisional. Clicking a card's Send or
  Delete button fires *after* that same click's `mousedown` has already blurred the textarea, so a
  card action always waits for that blur's in-flight persist to resolve before acting, then resolves
  its own (possibly now-stale, pre-re-keying) id through `CommentsController.resolveId` — this is
  what makes a provisional card's persist-then-immediately-send or persist-then-immediately-delete
  behave as one operation on the server-assigned id rather than racing it.
- **In-progress text and focus survive a live diff refresh.** A diff refresh
  (`CommentsController.setFiles`/`refresh`) rebuilds every card's DOM node from scratch, but a
  card's not-yet-blurred keystrokes are tracked separately (`liveBodies`) and taken over
  `comment.body` when a card is rebuilt, and the focused card's id and caret position are captured
  before the rebuild and restored after it — so typing through a refresh (or a refresh landing
  mid-keystroke) never drops what was typed or moves focus.
- **Rehydration vs. re-anchoring.** `reviewCommentList()` is called exactly once, from `root.ts`
  after mount (workspace-scoped, independent of the active scope/mode). Its response is merged into
  the in-memory mirror rather than replacing it outright: response rows first, then any current
  local draft whose (alias-resolved) id isn't already in the response — so a draft created, or a
  persist that completes and re-keys a provisional id, while that one `reviewCommentList` call is
  still in flight is kept rather than clobbered, without being duplicated once the response catches
  up to it. Every subsequent create/edit/delete/send updates the in-memory mirror directly; a live diff refresh
  (`CommentsController.setFiles`) only re-anchors the existing drafts against the new file set via
  `reanchorComments` (`src/app/reviewComments.ts`, DOM-free and unit-tested in isolation) — it never
  re-fetches, since a slow `reviewCommentList` reply racing a local mutation could otherwise revert
  it. Re-anchoring rule: an exact `(filePath, side, lineNumber, lineText)` match stays put; else the
  nearest same-file/same-side line whose text still matches floats there (ties break toward the
  smaller line number); else the comment is `outdated` and pins near its file's header (or is
  tray-only if the file itself is gone).
- **Send failure leaves drafts untouched.** `reviewCommentsSend` archives its named drafts only
  after its terminal write succeeds (send-then-archive ordering, not two-way atomicity — see the
  Bridge contract section above); `CommentsController` never removes a draft from its local mirror
  before the call resolves, so a rejection surfaces an error banner with every draft exactly as it
  was. A rejection typed `conflict`, `invalidArgument`, or `notFound` specifically proves the
  mirror is stale — a `conflict` means one or more entries' `revision` no longer matched the
  daemon's, `invalidArgument`/`notFound` mean a named comment was already sent, deleted, or never
  existed the way the mirror thought — so `CommentsController` also re-fetches every draft from
  `reviewCommentList()` before re-rendering (see `CommentsController.reconcileMirrorAfterRejection`,
  called from both `handleSendFailure` and `deleteDraft`'s failure path). Every other rejection —
  a non-typed transport failure, or a `SpacesBridgeError` coded `internalError`/`unavailable` —
  proves nothing about staleness and skips the re-fetch.
- **Drafts survive a pane hibernating or closing, not just a live diff refresh.** On top of the
  in-progress-text/focus survival above (which only covers a refresh while the page stays alive),
  a not-yet-blurred keystroke also survives the page itself being torn down: the host's teardown
  pull (`__spacesCollectReviewCommentState`, see the wire protocol section above) asks
  `CommentsController.collectStateForFlush` for a snapshot right before the `WKWebView` goes away,
  and the replacement page's `root.ts` seeds it back via `restorePendingState` before its own
  `loadInitial()` call. A still-provisional card is recreated as a fresh local draft under a new id
  (the pre-teardown id is never reused); a persisted draft's live text is seeded into `liveBodies`
  ahead of the list response, so the card renders the in-progress text immediately and the next
  blur persists it through the normal path. Mirrors `editorState`'s own hibernation-survival model
  in Editor mode above — see docs/implementation.md's hibernation section for the full mechanism
  (generation-guarded flush, the three-way sentinel decode, and the mutation-RPC counter that also
  defers `ready` behind an in-flight send/upsert/delete).
- **A context-line click always anchors to the new side.** Split layout's gutter reports a
  context row's click as the old (deletions) side even though the line is unchanged;
  `reviewComments.ts`'s `canonicalizeContextAnchor` (used by `diffView.ts`'s `requestNewComment`)
  rewrites such a click to its new-side `(side, lineNumber)` before it ever becomes a stored
  anchor, so `formatReviewCommentsText`'s "(removed line)" suffix only ever labels a genuine
  deletion, never a still-present context line whose old-side line number could also have drifted
  from the current file's own numbering.
- **`sendBatch` reads last-saved bodies, not live keystrokes** — see the doc comment on
  `CommentsController.sendBatch` for why a card mid-edit that has not yet blurred is accepted to
  send its last-saved body rather than in-progress typing.

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
newer scope's already-applied result); its permanent-vs-transient failure classification (a typed
`SpacesBridgeError` renders in place of the file list with no retry scheduled, an untyped rejection
keeps retrying, a scope switch out of a rendered permanent error fetches the new scope normally,
and the typed `unavailable` and `internalError` codes are the exceptions that both render and
retry, while a typed `invalidArgument` — e.g. a ref the daemon could not resolve — still renders
with no retry scheduled); its
bounded-backoff retry on a transient failure (floor, doubling, cap, reset-on-success, and a scope
switch superseding a pending retry); the `modeChanged` push
firing on every toolbar toggle, and the `spaces:agents` listener re-running the auto-default rule
and updating the toolbar. `test/toolbar.test.ts` covers the "vs base branch" option's
disabled/enabled state and label based on whether `baseBranch` is present, that a click reaching a
disabled button never fires `onScopeChange`, and the agent slot's three renderings (single-agent
label, multi-agent select with a disabled placeholder, empty in Editor mode) plus "Send batch"'s
three disabled-reason states and its enabled click-through. `test/reviewComments.test.ts` covers
the pure logic in `src/app/reviewComments.ts` in isolation: `extractDiffLines`'s per-side line
extraction from a raw patch, `reanchorComments`'s exact-match/nearest-match/tie-break/outdated/
file-gone cases, `selectDefaultAgentId`'s every branch (auto-select-one, none-when-zero-or-many,
keep-a-manual-pick, re-default-when-it-disappears), `formatReviewCommentsText`'s exact send-text
shape (single comment, removed-line suffix, multi-comment join), and the `toAnnotationSide`/
`fromAnnotationSide` round trip. `test/commentsController.test.ts` covers `CommentsController`
against a hand-built fake `SpacesBridge`: card create/edit/delete RPC round-trips (including
blur-only persistence and silent discard of an empty draft), send-one and send-batch (including a
rejected send leaving drafts unchanged and surfacing the error banner), the no-running-agent
disabled state, and `onAgentsChanged` re-running the auto-default rule.

## Open items (Swift-host integration)

- **`workspaceFileList` has no daemon endpoint yet.** The bridge contract, mock, and Editor
  mode's search are built against the shape in `src/bridge/types.ts`; real usage rejects
  `unavailable` until that endpoint lands, and the picker degrades to a quiet hint pointing at
  the direct-path Return-to-open flow instead.
- **Phase 5** (merge conflict resolution UI) is out of scope here; the editor's conflict banner
  is the only hook left for it.
- **The file-list sidebar is not in Variant A's literal mockup markup** — Variant A's own
  markup has no file-picker chrome, so this bundle borrows Variant B's `.rail`/`.rr` token and
  metric vocabulary for it (see comments in `src/styles/app.css`), since a file list is a hard
  functional requirement of Diff mode regardless of which toolbar variant was picked.
  Confirming this deviation against the mockup's intent is worth a look before Swift-host
  integration locks in the pane's overall layout.
  - **Shiki bundle size**, discussed above: whether the ~11MB/~320-file built output (only
  ~740KB of which loads eagerly) is acceptable as-is, or worth a `shiki` aliasing pass to
  physically shrink it to the 19 languages.
