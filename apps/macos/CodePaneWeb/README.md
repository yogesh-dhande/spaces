# Code Pane Web

The code pane's web bundle: a self-contained plugin (Diff review + Editor modes) that runs
inside the macOS app's WKWebView and talks to the Swift host only through the typed
`window.spaces` bridge. Built with Vite + TypeScript, rendering with `@pierre/diffs`
(Shiki-based).

Nothing in this bundle makes a network request at runtime; it is served to the WKWebView over the
app's `spaces-codepane` custom URL scheme by a `WKURLSchemeHandler` reading the checked-in
`Resources/CodePane` bundle, and every asset path in the built output is relative.

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
- `workspaceFileList()` — the full workspace file listing, backing Editor mode's Files tree and
  the ⌘P quick-open overlay's fuzzy search. Callers (`editorSidebar.ts`, `quickOpen.ts`) fetch this
  lazily through the shared `WorkspaceFileListCache`, which keeps at most one bridge call
  outstanding at a time across `get()` and `getFresh()` and does not cache a failed fetch. It runs
  on the daemon's per-workspace serial git queue (shared with file reads/saves/diffs), so a call
  arriving while one is already in flight can never come back sooner than one chained after it:
  `invalidate()` therefore never starts a request of its own while one is in flight, instead
  marking it stale and letting any number of `invalidate()`/`get()`/`getFresh()` calls that arrive
  before it settles collapse into exactly one trailing refetch, fired the instant it does. It is
  invalidated on every diff-signature push, but that push only ever fires once a `workspaceDiff`
  fetch has succeeded — a non-git workspace or a pane still on its first Editor render never gets
  one — so `getFresh()` additionally revalidates in the background, stale-while-revalidate style, at
  the moments the listing is actually shown (⌘P opening, the Files tab becoming visible): callers
  keep rendering the cached value while `getFresh()`'s returned promise resolves to a fresh one, and
  a failed revalidation leaves the previous cached value in place. The invalidating push itself also
  asks an already-open ⌘P overlay to refetch right away (`QuickOpen.refreshListing()`, called from
  `root.ts` ungated on pane mode — unlike the Files tab's own editor-mode-gated refresh): the cache's
  invalidation only affects the *next* caller, so an overlay whose `getFresh()` call already
  resolved (or was in flight) before the push would otherwise sit on a stale listing until closed
  and reopened. Each consumer paints its own local copy of the last listing it saw synchronously at
  show time, before its `getFresh()` call resolves — which leaves a consumer that has never rendered
  before blank even when the OTHER consumer already populated this cache (e.g. ⌘P in Diff mode
  fetches a listing, then the Files tab's first show has nothing of its own yet). `snapshot()`
  exposes the cache's own last successfully fetched listing (regardless of invalidation; never
  cleared by `invalidate()`, since stale-while-revalidate means the pre-invalidation listing is still
  worth showing until the refetch lands) so a consumer can seed its local copy from it before
  painting, whichever consumer originally fetched it.
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
  - `{method:"editorUIStateChanged", params}` — Editor mode's sidebar toggle and recent-files
    list, `{sidebarMode, recentPaths}` (`CodePaneEditorUIState`). Owned by `root.ts` (not
    `EditorView`), since every event that changes it — the Files/Changes toggle, a successful open
    from any of the three entry points (⌘P overlay, Files tree, Changes list) — is already routed
    through there. Sent immediately, with no debounce, since this state changes only on discrete
    user actions rather than continuous typing.
  - `{method:"renderMetric", params}` — a validated diagnostic milestone after the diff or editor
    has committed DOM work and crossed two animation frames. `params` is `{kind, trigger,
    elapsedMs, fileCount, contentBytes}`; the native host records it only in the existing DEBUG
    performance log. `contentBytes` is exact for the ASCII E2E scale fixtures and an intentionally
    constant-time JavaScript string-unit approximation for arbitrary Unicode patches, avoiding an
    up-to-8 MiB re-encode on the UI thread merely for observability.

  The host holds only the latest of each in memory on the pane's controller (which survives
  hibernation, unlike the `WKWebView`), and hands all three back through the next `spaces:init`
  (see below) — see docs/implementation.md's hibernation section for the full rehydration model.
- **Teardown pull (Swift -> JS, synchronous):** `window.__spacesCollectEditorState` — a global
  function the host calls via `evaluateJavaScript`'s return value (not the message handler) at
  teardown, to flush whatever the editor holds at that exact instant into the snapshot above.
  This closes the one gap the debounced push above can't cover: a buffer edit still inside its
  ~500ms window when the page is torn down. Returns the `CodePaneEditorState` JSON-stringified,
  or `null` when no file is open — see `EditorView.collectStateForFlush` and
  docs/implementation.md's hibernation section.
  - `window.__spacesCollectEditorUIState` mirrors the mechanism, for `editorUIStateChanged`'s
    state: since `root.ts` owns that state directly with no debounce, this simply reads its live
    in-memory value synchronously (no async race to close) and returns it JSON-stringified —
    never `null`, since `{sidebarMode: "files", recentPaths: []}` is always a valid value.
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
    holds no snapshot for this pane — see `editorStateChanged` above), `editorUIState` (a
    `CodePaneEditorUIState`, omitted when the host holds no snapshot — defaults to
    `{sidebarMode: "files", recentPaths: []}` when absent; see `editorUIStateChanged` above), and
    `pendingReviewComments`
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
  - `spaces:setMode` (any time the host wants an already-open pane to switch its live Diff/Editor
    mode, e.g. reusing the pane for a different navigation gesture): detail is `{mode}`. The
    counterpart to `modeChanged` (JS -> Swift, see above): the listener dispatches the exact same
    `setMode` action a toolbar click does, so `notifyModeChanged` echoes back out to the host the
    same way, keeping the host's own mirror of this pane's mode a read of the page's own report
    rather than something the host sets speculatively. A no-op when `mode` already matches the
    pane's current mode.
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

A read-only open-file bar (`src/app/editorView.ts`, `.editor-path`, showing the open path or a
"⌘P to open a file" hint) feeding a single-item, edit-mode `CodeView`, plus a sidebar
(`src/app/editorSidebar.ts`) sharing the same `.file-list` element Diff mode's changed-files list
occupies (Design K). The sidebar's Files/Changes segmented header toggles between a full workspace
listing (`filesTree.ts`, lazily fetched through `WorkspaceFileListCache`, no per-file status since
every listed file is unchanged by definition) and the SAME changed-files DOM node Diff mode
renders — reparented, not re-rendered, so its click behavior carries over untouched. Unlike Diff
mode's small changed-files tree, which renders fully expanded, the Files tree's directories start
collapsed and materialize a directory's `.dir-children` DOM only on that directory's first expand —
a listing capped at 50,000 paths can't afford to build every row and listener up front.
`renderFilesTree` returns a `FilesTreeHandle`; `EditorSidebar.setSelectedPath` calls its
`setSelected(path)` on every file open to move the highlight in place (expanding and materializing
just the new path's ancestor chain), instead of re-rendering the whole tree. `EditorSidebar`'s
constructor never starts that listing fetch itself — every pane constructs one, including a
diff-only pane that never shows it, and firing the fetch there would send an up-to-50,000-path
`workspaceFileList` RPC down the daemon's shared per-workspace serial git queue for nothing. The
fetch starts the first time the sidebar is actually shown instead: `reattach()` (root.ts calls it on
every Diff→Editor mode transition, and once more right after the initial render for a pane that
starts or is rehydrated directly into Editor mode) and the Files/Changes toggle's own `setMode()`.

The only way to open a file is `EditorView.open(path)` (Design O), called from three entry points:
the ⌘P quick-open overlay (`src/app/quickOpen.ts`, a centered floating panel available in both Diff
and Editor mode — before typing it lists `recentPaths` most-recently-opened first, filtered against
the workspace listing unless that listing is truncated (a recent path's absence from a partial
listing isn't evidence the file is gone); while typing it fuzzy-matches the full listing via
`fuzzyMatch.ts` and highlights the matched characters), the Files tree, or the Changes list. In Diff
mode, opening a file already in the current diff stays in Diff mode and jumps to it there; a file
outside the diff switches to Editor mode. Opening a DIFFERENT file while the buffer is dirty shows a
non-blocking discard-consent banner instead of silently replacing it; re-picking the file that's
already open while dirty (its own row again, or ⌘P again) is a no-op instead — nothing to open that
isn't already showing, and the banner's accept action would otherwise reread disk and destroy the
very edit it claims to protect. A standing conflict (dirty for as long as it stands) is a no-op the
same way. Every successful open records into
`recentPaths` (deduped, most-recent-first, capped at 12): for an Editor-mode open this is driven by
`EditorView`'s `onFileOpened` callback, which only fires once `loadFile()` actually completes —
never for a refused (dirty-buffer) or failed open — while a Diff-mode jump records inline, since a
jump to a file already in the diff is synchronous and cannot fail.

Save goes through the CAS `workspaceFileWrite`; on a conflict the UI shows a non-blocking banner
(`.banner.error`, the same element opening a missing/unreadable file also uses) and disables Save
without discarding the user's edits — resolving a conflict (full merge UI) is Phase 5's scope, out
of scope here. A successful save adopts the write result's own `sha256` directly as the CAS
baseline for the next save, with no re-read round trip.

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
actions and `initialState`. `test/fuzzyMatch.test.ts` covers the ⌘P overlay's scorer directly:
subsequence matching (including the empty-query and no-match cases), case-insensitive matching
with indices reported into the original text, and that a consecutive run, a path/word
segment-start match, and a basename match each score higher than an equivalent match without that
property. `test/editorView.test.ts` covers the public `open(path)` entry point's dirty-buffer
discard-consent gating (including a second `open()` call while already dirty re-targeting the
banner to the newer path); re-picking the file already open while dirty is a no-op instead — no
banner, no re-read, the edit left intact — the same way during a standing conflict; its error
surfacing on a rejected read via the `.banner.error` element,
a save adopting the write result's own hash as the next CAS baseline with no intervening file
read, the `editorStateChanged` push firing immediately on open/save/conflict and debounced on
edits, and `restoreState` rehydrating a dirty snapshot without a disk re-read versus re-reading a
clean one from `path`, and `collectStateForFlush` returning the latest buffer (including an edit
still inside the debounce window) or `null` with no file open (`@pierre/diffs`' `CodeView`/`Editor`
are stubbed out — these tests are about `EditorView`'s own logic, not the diff-rendering library).
`test/pathTree.test.ts` and `test/filesTree.test.ts` cover the Files tab's directory-tree builder
and renderer (root-level files, nesting, single-child-chain compaction, compaction stopping at a
branch point) with the same behavior `test/fileTree.test.ts` already covers for Diff mode's own
tree builder, plus the renderer's own collapsed-by-default/lazy-materialize contract: no descendant
DOM before a directory's first expand, element identity preserved across toggles and across
`FilesTreeHandle.setSelected` calls, and `setSelected` expanding just the target path's ancestor
chain. `test/workspaceFileListCache.test.ts` covers the shared cache's lazy-fetch-once,
concurrent-caller dedup, not-caching-a-failed-fetch, and `invalidate()` behavior, plus `getFresh()`'s
stale-while-revalidate contract (serving the cached value while a deduped background refetch is in
flight, the refetch's result replacing the cache on success, and a failed refetch leaving the
previous cached value untouched), and the single-flight/trailing-refetch contract: any number of
`invalidate()`, `get()`, and `getFresh()` calls arriving while one bridge call is in flight collapse
into exactly one trailing call fired once it settles — whether it succeeds or fails — never one per
caller or per invalidation, and `snapshot()`'s own contract: `undefined` before any fetch, the last
successful result afterward (including one whose generation went stale), surviving `invalidate()`,
and updating once a revalidation resolves. `test/editorSidebar.test.ts` covers the Files/Changes toggle
(including `onModeChange` firing and the toggle's `on` class), the Changes tab reparenting the same
`changesListEl` node rather than re-rendering it, that construction itself never fetches the
workspace listing regardless of which tab it starts on, the Files tab's lazy fetch first firing on
`reattach()` or on switching into the Files tab (including the cache being re-consulted on
`refreshFilesListing()` and on `reattach()`, and revalidating in the background via `getFresh()`
even without an explicit `invalidate()` first), the truncated note's visibility, switching to
the Changes tab while a Files fetch is still pending not letting that stale fetch touch the
truncation note once it resolves, and seeding `this.paths`/`this.truncated` (and the truncation
note) from the shared cache's `snapshot()` at construction and on every Files show, so a sidebar
that has never fetched a listing itself still paints one another consumer already fetched, before
its own revalidation resolves. `test/quickOpen.test.ts` covers the
overlay's ⌘P open/Escape-close keybinding, the before-typing recents list (most-recent-first,
filtered against the workspace listing, falling back to unfiltered before the listing has loaded or
when the loaded listing is truncated), fuzzy search while typing, arrow-key navigation, Enter-to-open,
open semantics in both modes (Diff mode jumps to an in-diff file and stays in Diff mode; anything
else opens in Editor mode), re-showing the overlay with an already-cached listing revalidating
in the background and re-rendering once a newly-added file lands, and `computeFuzzyMatches`'s
candidate-narrowing optimization (an extending keystroke rescans only the previous keystroke's
match set rather than the full cached listing — asserted both behaviorally, via equivalence with a
fresh query and a backspace reappearance, and directly, via a `fuzzyMatch` call-count spy — and a
listing refresh resets that narrowed state so a query typed before the refresh still matches
against the new listing), and seeding from the shared cache's `snapshot()` on `show()` so an
overlay that has never fetched a listing itself fuzzy-matches against one another consumer already
fetched, immediately and before its own revalidation resolves. `test/fuzzyMatch.test.ts` also covers the scorer's fast subsequence
pre-check returning `null` before the DP runs. `test/root.test.ts` covers `refreshDiff`'s
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
and updating the toolbar; a diff-signature push while the pane is in Diff mode invalidates the
shared file-listing cache without fetching a fresh listing for the Files tab, with that fetch
instead happening on the next transition into Editor mode (a pane sitting in Diff mode never
fetches the listing at all, including at mount, since `EditorSidebar`'s constructor never starts
that fetch itself) — except that the same push still refetches for an already-open ⌘P overlay
regardless of pane mode, since the overlay itself is reachable from Diff mode too; a pane that
starts, or is rehydrated, directly into Editor mode still gets that first fetch even though it never
goes through the mode-toggle dispatch that would otherwise trigger it; and a Changes-tab sidebar
survives a Diff→Editor round trip instead of coming back blank (Diff mode's own render reparents the
shared list node out of the sidebar without the sidebar ever re-rendering on that reparent). A
further `test/root.test.ts` suite
covers Design K/O's Files/Changes sidebar and recent-files recording: opening a file from the Files
tree records it as `recentPaths`' sole entry and pushes the update via `notifyEditorUIStateChanged`;
opening a second, different file puts it first without dropping the one already recorded; re-opening
an already-recent path moves it to the front instead of duplicating it; the list is capped at 12
entries, dropping the oldest; toggling Files/Changes pushes the updated `sidebarMode` independent of
`recentPaths`; a refused (dirty-buffer) open and a failed read both record nothing, while clicking
the discard-consent banner's own action records the target path only once that open actually
succeeds; and a Diff-mode ⌘P jump to a file already in the diff records it into `recentPaths` just
as an Editor-mode open does. `test/toolbar.test.ts` covers the "vs base branch" option's
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

- **`workspaceFileList`'s daemon endpoint is owned on the Swift host side.** The web bundle's
  `realBridge.ts` sends it as a plain RPC passthrough with no fallback or degraded rendering of
  its own (see `WorkspaceFileListCache`'s failed-fetch-is-not-cached contract) — the Files tab
  and the ⌘P overlay simply retry on the next trigger if a call fails. Confirming the host-side
  endpoint itself is implemented and wired is outside this bundle's scope.
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
