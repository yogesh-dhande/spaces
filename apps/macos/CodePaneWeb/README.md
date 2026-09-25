# Code Pane Web

The Editor's web bundle: Diff and Editor modes, running inside the macOS app's `WKWebView` and
reaching the host only through the typed `window.spaces` bridge. Vite and TypeScript, rendering
with `@pierre/diffs` (Shiki-based).

This README owns the package workflow, the JS/Swift wire protocol, and the constraints of the
bundle itself. Elsewhere:

| Topic | Where |
| --- | --- |
| What the Editor does for the user | `docs/spec.md` (the Editor rules) |
| Native hosting, diff transfer, persistence, previews, autosave, and why | `docs/implementation.md` (Editor integration, Editor previews, Editor autosave) |
| Per-method bridge semantics | doc comments on `SpacesBridge` in `src/bridge/types.ts` |
| Host side of the bridge | `apps/macos/Sources/spacesui/Panels/CodePaneBridge.swift` (decode, dispatch, replies) and `CodePaneContentController.swift` (events, lifecycle) |

## Layout

- `src/main.ts` installs the WebKit `getComposedRanges` shim, preloads the highlighter, and mounts
  `src/app/root.ts`, which wires every view to the bridge.
- `src/app/`: the views and their DOM-free helpers (diff, editor, previews, trees, comments,
  autosave).
- `src/bridge/`: the bridge contract (`types.ts`), the WKWebView implementation (`realBridge.ts`),
  and the dev-only mock and fixtures.
- `src/theme/`, `src/styles/`: highlighter setup and CSS tokens. Appearance comes only from the
  host (`spaces:init`'s `theme`, then `spaces:theme`) stamped on `<html data-theme>`; the bundle
  never reads `prefers-color-scheme`.

## Build and dev harness

```sh
npm install
npm run build       # tsc --noEmit, then vite build -> ../Sources/spacesui/Resources/CodePane/
npm run typecheck   # tsc --noEmit only
npm run test        # vitest run (jsdom)
npm run dev         # dev harness: mock bridge + fixture diff at the printed localhost URL
npm run icons       # regenerate the file-type icon sprite from vscode-icons (needs network)
```

`npm run build` empties and rewrites `apps/macos/Sources/spacesui/Resources/CodePane/`, a `.copy`
resource of the `spacesui` SwiftPM target. That output is checked in, so Swift builds and tests
never need node. A change to this bundle ships only when the rebuilt output is committed with it.
Neither `scripts/verify.sh` nor CI runs this package's tests, typecheck, or build, so run
`npm run test` and `npm run build` locally before committing a change here.

`npm run dev` runs against `MockSpacesBridge` (`src/bridge/mockBridge.ts`) with a fixture diff
(`src/bridge/fixtures.ts`) covering every entry kind: modified, renamed, added, deleted, untracked,
binary, nested checked-out submodules, and a submodule pointer that is not checked out. Floating
controls (`src/dev/harnessControls.ts`) simulate host pushes without a daemon: Simulate remote
change (a diff-signature push), Cycle agents, Change file on disk, Delete file on disk, and Toggle
live refresh error. The mock, fixtures, and controls load only under `import.meta.env.DEV`, so
Rollup drops them from the production build.

Tests live in `test/`. `root.test.ts`, `diffView.test.ts`, and `editorView.test.ts` stub
`@pierre/diffs` to test the pane's own logic; the `*.pierre.test.ts` files run against the real
renderer for behavior that depends on it (shadow-DOM event paths, the library's own key handling).

## Serving and the no-network rule

The page is served over the `spaces-codepane` custom scheme by `CodePaneSchemeHandler`, which
reads the checked-in bundle and refuses paths outside it. A `file://` origin is opaque, so WebKit
would block the CORS-fetched module script and stylesheet and the page would never send `ready`.
Every asset path in the build is relative (`base: "./"`).

Nothing in the bundle makes a network request at runtime. Icons are inlined, highlighter chunks
load from the same origin, and a Markdown preview resolves images and links only to workspace
files read through the bridge; anything else renders as inert text.

## Bridge wire protocol

One `WKScriptMessageHandler` named `spacesBridge` carries every JS-to-Swift message; Swift answers
by evaluating JS.

- **Request (JS to Swift):** `postMessage({id, method, params})`. Every promise-returning
  `SpacesBridge` method posts its own name as `method`; `CodePaneBridge.decodeRequest` drops a
  message without `id` or `method`, since there is nothing to reply to.
- **Reply (Swift to JS):** `window.__spacesBridge.resolve(id, result)` or
  `window.__spacesBridge.reject(id, {code, message})`. `realBridge.ts` installs `__spacesBridge`
  at import, before anything else runs, so a reply can never beat its resolver. A reply for an
  unknown id is dropped.
- **Errors:** every rejection is a `SpacesBridgeError` whose `code` is `notFound`,
  `invalidArgument`, `conflict`, `internalError`, or `unavailable`; an unknown code becomes
  `internalError`, and a missing message handler rejects `unavailable`. Callers branch on `code`.
  A compare-and-swap write that loses is a normal `{conflict: true}` result, not an error.
- **Notifications (JS to Swift, no `id`, no reply):**
  - `ready`: sent once the `spaces:init` listener is attached. The host dispatches nothing before
    it, and the page renders nothing before `spaces:init`.
  - `workspaceStateChanged` with one complete `CodePaneWorkspaceState`: debounced (250 ms) for
    continuous changes, immediate for discrete ones. The host persists the latest document per
    `(deviceID, workspaceID)`. There is no other state channel.
  - `editsFlushed` with `{token}`: the answer to one `spaces:flushEdits`.
  - `unsubscribeFileSignature`: ends the file-signature stream. It carries no path, so the page
    can never name a file the host is not already watching.
  - `retargetFileSignature` with `{from, to}`: moves the stream after a confirmed rename or move.
  - `renderMetric`: bounded timing and size metadata for the native DEBUG performance log; never
    source text.
- **Teardown pull (Swift to JS, synchronous):** `window.__spacesCollectWorkspaceState()` returns
  the current state document as JSON, so hibernation and close capture edits still inside the
  debounce window. The host sends the stored document back in the next `spaces:init`.
- **Events (Swift to JS):** `window.dispatchEvent(new CustomEvent(name, {detail}))`.
  - `spaces:init` (once, after `ready`): `CodePaneInitPayload` with the workspace id and name, the
    restored `workspaceState`, `theme`, optional `baseBranch`, `isGitRepository` (false suppresses
    every diff fetch and the diff-signature subscription), `isLocalWorkspace`, and running
    `agents`. The page applies the restored state before its first manifest and listing requests.
  - `spaces:theme`, `spaces:agents` (full replacement list, so the page keeps a still-valid
    selection or reapplies its default-agent rule), `spaces:agentStartStatus` (`detected`,
    `exited`, or `timedOut` for a started command), `spaces:setMode`.
  - `spaces:flushEdits` with `{token}` before quit or pane teardown; the page writes what is
    unsaved and answers `editsFlushed` once per token.
  - `spaces:diffSignature` (active scope's git signature), `spaces:fileListSignature` (workspace
    listing membership), and `spaces:fileSignature` (the open file changed or was deleted). These
    are "go look" signals that never carry content. The first two carry `liveRefreshError` on
    every frame while the daemon's watcher for the workspace is down.

Rules the protocol relies on:

- `subscribeDiffSignature`, `subscribeFileSignature`, and `subscribeFileListSignature` only attach
  a page listener; they send nothing. One diff scope is observed at a time.
- The host's single file-signature stream follows the last successful `editor`-purpose
  `workspaceFileRead`, or a `retargetFileSignature` the host applies only while the stream still
  follows `from`. `inlineDiff` reads, `workspaceRevisionFileRead`, and `workspaceImageRead` never
  point it.
- Reads and writes name a purpose. `workspaceFileWrite`'s purpose (`editor`, `inlineDiff`,
  `createFile`) selects how the host resolves the path, so `realBridge.ts` rejects a write without
  one rather than inferring it.
- `postMessage`'s structured clone drops `undefined` properties, so values whose absence means
  something (`baseSHA256` for the create convention, nullable state fields) are sent as `null`.

## Language set and bundle size

`src/theme/index.ts` preloads Shiki for a fixed set (TypeScript, JavaScript, TSX, JSX, Swift,
Python, Go, Rust, C, C++, Objective-C, JSON, YAML, TOML, HTML, CSS, Markdown, shell, SQL, plus
`text`). Every call site that hands a file to `CodeView` sets `lang` from
`resolveAllowedLanguage()`, which maps anything outside the set to `text`. Letting `@pierre/diffs`
auto-detect would pick a language the shared highlighter never loaded, and the library renders a
visible error box in place of the file instead of plain text.

`@pierre/diffs` imports Shiki's full bundled-language map, so Rollup emits a chunk for every Shiki
language: the build is about 12 MB across about 320 files. Only the entry chunk (about 1.2 MB,
about 380 KB gzipped, of which about 140 KB is the icon sprite) and its CSS load eagerly;
`index.html` has one module script and no preload hints, and `resolveAllowedLanguage` means only
the whitelisted languages' chunks are ever requested. The shipped size is an accepted trade-off:
shrinking it would mean aliasing `shiki`'s bundled-language export to a curated subset, which
reaches into the package's unexported paths, for chunks the app never loads.

## File-type icons

File rows in the Files tree and the Changes list carry an icon from the MIT-licensed
[vscode-icons](https://github.com/vscode-icons/vscode-icons) pack. `npm run icons`
(`scripts/generate-file-type-icons.mjs`) fetches the pinned pack commit, resolves the script's
`ICON_SEEDS` through the pack's own manifest, and writes three checked-in files:
`src/app/fileTypeIconSprite.ts` (one namespaced `<symbol>` per icon, inlined and referenced by a
`<use>` per row), `src/app/fileTypeIconTable.ts` (every name and extension the pack maps to those
icons), and `public/vscode-icons-LICENSE.txt`, which Vite copies into the bundle so the notice
ships beside the art. The generator is deliberately outside `npm run build`, which stays offline
and reproducible; rerun it only to move the pinned commit or change the seeds, and commit its
output.
