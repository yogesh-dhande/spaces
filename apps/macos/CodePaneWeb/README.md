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
file, a rename, an addition, a deletion, an untracked file, and a binary file). A floating
"Simulate remote change" button
(`src/dev/harnessControls.ts`) fires a `spaces:diffSignature` event so the live-refresh path
(preserve scroll, re-fetch, re-render) is exercisable without a real daemon or git repo. The
harness controls and the mock bridge/fixtures are dev-only: `src/bridge/index.ts` dynamically
imports the mock only under `import.meta.env.DEV`, so Rollup tree-shakes all of it out of the
production build.

## Bridge contract

`window.spaces` (typed in `src/bridge/types.ts`) is the plugin's only way to reach the host:

- `workspaceDiffManifestChunk(scope, {manifestID?, fileIndex})` — one bounded metadata page for the
  requested `DiffScope`, plus its `manifestID` and `scopeSignature`. The initial page creates the
  manifest; later pages echo its id and semantic file-index cursor until no next cursor remains. The
  manifest freezes the file enumeration and comparison plan for one refresh; it does not contain patch bytes.
- `workspaceDiffFileChunk(scope, {manifestID, relativePath, byteOffset, transferID?})` — one bounded
  raw-byte range of a file's patch, returned as base64. A first request creates that file's transfer;
  later requests echo its `transferID` until EOF. `workspaceDiffFileChunkCancel` cancels an active
  transfer, and `workspaceDiffManifestRelease` releases the manifest and its transfers.
- `workspaceFileRead(path, purpose, comparison?)` — content, `sha256`, size. `editor` makes the
  native host's single file-signature watcher follow the standalone editor; `inlineDiff` does not
  retarget that watcher. An inline-diff request with an immutable `comparison.baseRevision` also
  returns Git-filtered `comparisonOldContent` for that revision (and its optional rename
  `oldPath`), without adding old text to the streamed patch. Every caller must identify one of
  these purposes.
- `workspaceRevisionFileRead({path, revision, oldPath?})` — the exact live-checkout `content`,
  `sha256`, and size whose Git-filter-aware equivalence was checked against the manifest-pinned
  revision, plus the first-parent filtered `comparisonOldContent` (using `oldPath` for renames).
  The revision target is existence/type checked but never transferred. Last Commit inline editing
  uses this one response as its CAS baseline and guard, so it never races a separate live read;
  it never moves the standalone editor watcher.
- `workspaceFileWrite(path, content, {baseSHA256, purpose})` — compare-and-swap write. `inlineDiff`
  rejects symbolic-link components so the patch's path cannot save into its link target; `editor`
  retains contained-link workspace editing. It returns
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
  invalidated on every diff-signature push, but that push only ever fires once a `workspaceDiffManifestChunk`
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
- **State pushes (JS -> Swift, fire-and-forget):** the same message handler receives
  `{method:"workspaceStateChanged", params: CodePaneWorkspaceState}`. The web app debounces
  continuous edits and immediately reports discrete changes through one complete, self-contained
  workspace document; the host persists the latest document keyed by `(deviceID, workspaceID)`.
  There are no separate Editor, mode, or Editor-UI state notification streams.
- **Render metrics (JS -> Swift, fire-and-forget):** `{method:"renderMetric", params}` reports
  validated post-render diagnostics to the native DEBUG performance log. It contains only bounded
  timing and aggregate-size metadata, not source text.
- **Edit flush (Swift -> JS, then JS -> Swift, fire-and-forget):** the host dispatches
  `spaces:flushEdits` with `{token}` when it is about to quit or tear the pane down; the page
  writes whatever is still unsaved and answers on the same message handler with
  `{method:"editsFlushed", params:{token}}`, once per token and with no `id`.
- **Teardown pull (Swift -> JS, synchronous):**
  `window.__spacesCollectWorkspaceState` returns the current complete workspace-state document as
  JSON text. The host uses it before hibernation or close to capture edits inside the debounce window;
  rendered patches and DOM state are not included. The persisted document is sent back in the next
  `spaces:init`.
- **Push events (Swift -> JS):** `window.dispatchEvent(new CustomEvent(name, {detail}))`
  carries:
  - `spaces:init` once, after the page sends `ready`. Its `CodePaneInitPayload` includes
    `workspaceId`, `workspaceName`, the restored `workspaceState`, current `theme`, optional
    `baseBranch`, and the workspace's running `agents`. The restored state is applied before the
    initial manifest and file-list requests, so the page can restore selection, tree context,
    scroll/focus, buffers, comments, and agent/launch state while fresh patch bytes stream in.
  - `spaces:agents` whenever the workspace's running-agent set changes; the full replacement
    `{agents}` list lets the comments controller preserve a valid selection or reapply its
    default-agent rule.
  - `spaces:agentStartStatus` for a started command's session, with `detected`, `exited`, or
    `timedOut` status. A detected hook-backed agent becomes assignable; an exited or timed-out
    command remains available to retry and is shown as not detected.
  - `spaces:setMode` when the native host asks the page to switch modes, and `spaces:theme`
    when effective appearance changes.
  - `spaces:flushEdits` when the host needs unsaved edits written before it quits or tears the
    pane down; the page answers with `editsFlushed` (see the edit-flush entry above).
  - `spaces:diffSignature` when the active scope's git signature changes. The page refreshes by
    requesting a new manifest; stale responses are ignored and transient typed/untyped failures use
    the bounded retry path, while durable request errors remain visible.

## Editor changes view

The Editor's Changes view has a file-list sidebar and one `@pierre/diffs` `CodeView` holding
all changed files in order as one virtualized scrolling region (`src/app/diffView.ts`). A
complete `workspaceDiffManifestChunk` metadata sequence paints the sidebar and queued file rows. Patches
then arrive through per-file `workspaceDiffFileChunk` transfers: one file streams at a time in
bounded 4 MiB chunks, the selected queued file can be promoted, and incoming UTF-8 bytes are
decoded incrementally. A binary entry has an explicit non-commentable placeholder; textual
patches have no daemon truncation or aggregate UI cap. Untracked files render as additions with
no old side. Scope/signature refreshes release the old manifest and replace it with a new
metadata-first generation while preserving the relevant selection and scroll context.

## Editor mode

A read-only open-file bar (`src/app/editorView.ts`, `.editor-path`) feeds a single-item,
edit-mode `CodeView`, with an Editor sidebar sharing the Changes list element.
Files uses a lazily fetched full workspace listing and a collapsed, lazy-materialized directory
tree; that listing is sorted and capped at 50,000 paths with a `truncated` flag. Changes
reparents the existing changed-files list, so toggling the sidebar does not rebuild its rows.
The shared tree state and selected file are restored from the workspace document.

The ⌘P quick-open overlay, Files tree, and Changes list all call `EditorView.open(path)`.
Opening a file already in the current Changes set keeps the Changes view and focuses that file;
opening any other file uses Editor mode. A different-file open while the buffer is dirty flushes
the pending save first and proceeds once the buffer is clean; a save that fails or is blocked
refuses the open and reports that reason, so there is no discard consent to give. Reselecting the
already-open file is a no-op. Successful opens update the most-recent-first recent-path list.

The new/right side of a changed file is editable through the library's line editor, and edits
save themselves. `src/app/autosave.ts` schedules a write 800 ms after the last keystroke, keeps a
single write in flight, and retries a failed write with exponential backoff between 1 s and 30 s.
A write uses the captured CAS baseline, adopts the returned hash on success, and leaves the edit
session open. There are no Save or Cancel buttons: the one save affordance is a status chip in
the inline edit header and in Editor mode's top bar, reading `Unsaved`, `Saving…`, `Saved`,
`Save blocked: <reason>`, or `Save failed: <reason> · retry in <N> s` with a Retry now action,
and absent while there is nothing to report. ⌘S flushes the pending write immediately. Esc ends
the edit session, saving first when the buffer is dirty. Clicking into another file's lines
flushes the open session and switches once it is clean. Quitting is one event pair: the host
dispatches `spaces:flushEdits` with a token, the page awaits the flush in flight and answers with
`editsFlushed` carrying that token.

A concurrent change produces the merge/conflict UI without discarding the user's buffer: clean
buffers reload, non-overlapping edits merge with Undo, overlapping or deleted-file edits show
the compare view with Keep mine and Take disk/Close without saving actions. A standing conflict
blocks autosave with that reason, and because the autosave that follows a merge keeps the session
open, the merge's Undo offer stays available after the merged content is written.

The complete workspace document is collected through `window.__spacesCollectWorkspaceState` and
persisted by the host per `(deviceID, workspaceID)`; it includes mode, scope, layout, tree and
file selection/scroll/focus (with each diff position paired to its old/new side), open buffers and
baselines, review-comment drafts, agent selection, and pending agent launch. Patch bodies and rendered DOM remain ephemeral, so restored Editor
state is combined with a fresh manifest and fresh file transfers.

## Toolbar

One compact strip (`src/app/toolbar.ts`) provides the Editor mode toggle and, in the Changes
view, scope and split/unified controls. The agent slot stays compact: with no running agent it
shows a `Start agent…` button; with running agents it shows the assigned-agent selector plus a
separated `Start new…` action. The command dialog accepts an arbitrary command and Run starts it
in a background workspace terminal without moving Editor focus. It reports Starting while waiting
for hook-backed detection, then clears on detection or shows `No agent detected` after exit or
timeout while retaining the command and failure feedback for retry, including after app restart.

The comment send action is disabled unless a running agent is assigned and there is sendable draft
text. The composer and send controls explain that comments require a running, assigned agent;
starting an agent from the toolbar does not implicitly send comments.

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
- **Drafts survive a pane hibernating or closing, not just a live diff refresh.** The unified
  workspace-state collector includes pending comment text, including a focused card whose textarea
  has not blurred. The native host persists that document per workspace and restores it before the
  replacement page loads its daemon draft list; provisional cards receive fresh local ids, while
  persisted drafts overlay their in-progress body until the normal blur path saves it.
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
actions and `initialState`. `test/autosave.test.ts` covers `AutosaveScheduler`
(`src/app/autosave.ts`) in isolation: the 800 ms debounce, coalescing edits made during a write
into one follow-up write, the backoff schedule and its countdown, a blocked host writing nothing,
and `flush`/`cancel`. `test/fuzzyMatch.test.ts` covers the ⌘P overlay's scorer directly:
subsequence matching (including the empty-query and no-match cases), case-insensitive matching
with indices reported into the original text, and that a consecutive run, a path/word
segment-start match, and a basename match each score higher than an equivalent match without that
property. `test/editorView.test.ts` covers autosave in Editor mode: one write 800 ms after the last
keystroke against the load's hash with the chip stepping through dirty, saving, and saved; a
failed write reporting its countdown and retrying on its own backoff, with Retry now writing
immediately; no Save button in any state; and the public `open(path)` entry point flushing the
dirty buffer before it reads the new file, with a failed or conflict-blocked write refusing the
open and reporting that reason. Re-picking the file already open while dirty is a no-op, no
re-read, the edit left intact, the same way during a standing conflict. It also covers its error
surfacing on a rejected read via the `.banner.error` element,
a save adopting the write result's own hash as the next CAS baseline with no intervening file
read, the unified `workspaceStateChanged` snapshot being updated immediately for discrete changes
and debounced for edits, and `restoreState` rehydrating a dirty snapshot without a disk re-read versus re-reading a
clean one from `path`, with the workspace-state collector capturing an edit still inside the
debounce window (`@pierre/diffs`' `CodeView`/`Editor`
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
switch superseding a pending retry); the unified workspace-state snapshot reflecting every toolbar
toggle, and the `spaces:agents` listener re-running the auto-default rule
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
covers the Files/Changes sidebar and recent-files recording: opening a file from the Files
tree records it as `recentPaths`' sole entry and updates the unified workspace-state snapshot;
opening a second, different file puts it first without dropping the one already recorded; re-opening
an already-recent path moves it to the front instead of duplicating it; the list is capped at 12
entries, dropping the oldest; toggling Files/Changes pushes the updated `sidebarMode` independent of
`recentPaths`; an open refused by a failed write and a failed read both record nothing, while an
open the pending write clears records the target path once that open actually succeeds; and a
Diff-mode ⌘P jump to a file already in the diff records it into `recentPaths` just
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

## Open items

- **The file-list sidebar is not in Variant A's literal mockup markup** — Variant A's own
  markup has no file-picker chrome, so this bundle borrows Variant B's `.rail`/`.rr` token and
  metric vocabulary for it (see comments in `src/styles/app.css`), since a file list is a hard
  functional requirement of Diff mode regardless of which toolbar variant was picked.
  Confirming this deviation against the mockup's intent is worth a look before Swift-host
  integration locks in the pane's overall layout.
  - **Shiki bundle size**, discussed above: whether the ~11MB/~320-file built output (only
  ~740KB of which loads eagerly) is acceptable as-is, or worth a `shiki` aliasing pass to
  physically shrink it to the 19 languages.
