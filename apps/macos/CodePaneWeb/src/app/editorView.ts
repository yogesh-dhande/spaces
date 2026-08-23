import { CodeView } from "@pierre/diffs";
import type { CodeViewItem } from "@pierre/diffs";
import { Editor } from "@pierre/diffs/edit";
import { CodePaneEditorState, SpacesBridge, SpacesBridgeError, WorkspaceFileReadResult, WorkspaceFileWriteResult } from "../bridge/types";
import { CODE_PANE_THEME_NAME, resolveAllowedLanguage } from "../theme";

const SEARCH_DEBOUNCE_MS = 150;
/** Trailing debounce for the editorStateChanged push on buffer edits (see `scheduleEditorStatePush`'s doc comment). */
const EDITOR_STATE_DEBOUNCE_MS = 500;

/**
 * Editor mode: an open-file picker feeding a single-file `@pierre/diffs`
 * `CodeView` in edit mode, saved through the CAS `workspaceFileWrite` call.
 *
 * Two ways to open a file, both funneling into the same `open()`:
 *   - Typing an exact path into the input and pressing Return, which reads
 *     it directly through `workspaceFileRead`. This always works.
 *   - Picking a result from `workspaceFileList`-backed search. That RPC has
 *     no daemon endpoint yet (see `SpacesBridge.workspaceFileList`'s doc
 *     comment) and always rejects `unavailable` today, so `search()`
 *     degrades to a quiet "type a path" hint instead of a scary error —
 *     this becomes a real progressive enhancement once the endpoint lands.
 *
 * Full merge UI for a save conflict is Phase 5's scope. Here a conflict only
 * shows a non-blocking banner and disables Save — the user's in-progress
 * edits are left untouched (not discarded), and opening a different (or the
 * same) file again is the only way to clear the conflict in v1.
 *
 * Every open/edit/save/conflict transition pushes an `editorStateChanged` notification to the
 * host (see `pushEditorStateNow`/`scheduleEditorStatePush`), so this view's state can be rebuilt
 * from the host's snapshot via `restoreState` after this pane's WKWebView is torn down and
 * recreated by a hibernation cycle.
 */
export class EditorView {
  private readonly bridge: SpacesBridge;
  private readonly input: HTMLInputElement;
  private readonly resultsList: HTMLElement;
  private readonly saveBtn: HTMLButtonElement;
  private readonly codeHost: HTMLElement;
  private readonly banner: HTMLElement;
  private codeView: CodeView | undefined;

  private currentPath: string | undefined;
  private baseSHA256: string | undefined;
  private latestContent: string | undefined;
  /** True from the first edit after an open/restore/save until the next successful save — mirrors
   *  `editorStateChanged`'s `dirty` field so a hibernation snapshot knows whether the buffer can be
   *  trusted over disk on rehydration (see `restoreState`'s doc comment). */
  private dirty = false;
  private conflict = false;
  private editGeneration = 0;
  private searchToken = 0;
  /** Bumped at the start of every `open()` call; a call whose token has been superseded by a later
   *  `open()` drops its result (success or failure) instead of clobbering whatever that later call
   *  already loaded. Same latest-wins shape as `root.ts`'s `diffRequestToken`. */
  private openGeneration = 0;
  /** True for the duration of one `save()` call. `saveBtn.disabled` alone doesn't stop re-entrancy:
   *  a second click already queued (or a programmatic `save()`) can still run before the first
   *  await yields control back to the DOM, and two overlapping CAS writes racing the same baseline
   *  would let the second silently win with a hash the first's in-flight write invalidates. */
  private saveInFlight = false;
  private searchTimer: ReturnType<typeof setTimeout> | undefined;
  private editorStatePushTimer: ReturnType<typeof setTimeout> | undefined;

  constructor(container: HTMLElement, bridge: SpacesBridge) {
    this.bridge = bridge;

    const openBar = document.createElement("div");
    openBar.className = "editor-open-bar";

    const resultsHost = document.createElement("div");
    resultsHost.className = "editor-results";

    this.input = document.createElement("input");
    this.input.type = "text";
    this.input.placeholder = "Open file…";
    this.input.addEventListener("input", () => this.scheduleSearch());
    this.input.addEventListener("focus", () => this.scheduleSearch());
    this.input.addEventListener("keydown", (event) => {
      if (event.key !== "Enter") return;
      // round-14 Comment B (accepted, no behavior change): the trim is deliberate paste-hygiene —
      // a path copied out of a terminal often carries trailing whitespace/newlines — and it does
      // make a filename with genuine leading/trailing whitespace unopenable via manual Return-entry.
      // Accepted: the search-suggestion click path (`search()`'s result rows) passes the exact
      // untrimmed path and will cover such files once `workspaceFileList` gets its real daemon
      // endpoint (see this file's doc comment).
      const path = this.input.value.trim();
      if (!path) return;
      event.preventDefault();
      this.openGated(path);
    });
    resultsHost.appendChild(this.input);

    this.resultsList = document.createElement("div");
    this.resultsList.className = "list";
    this.resultsList.style.display = "none";
    resultsHost.appendChild(this.resultsList);

    this.saveBtn = document.createElement("button");
    this.saveBtn.type = "button";
    this.saveBtn.className = "btn primary";
    this.saveBtn.textContent = "Save";
    this.saveBtn.disabled = true;
    this.saveBtn.addEventListener("click", () => void this.save());

    openBar.appendChild(resultsHost);
    openBar.appendChild(this.saveBtn);

    this.codeHost = document.createElement("div");
    this.codeHost.className = "diff-area";
    this.codeHost.style.position = "relative";

    this.banner = document.createElement("div");
    this.banner.className = "banner conflict";
    this.banner.style.display = "none";
    this.codeHost.appendChild(this.banner);

    container.appendChild(openBar);
    container.appendChild(this.codeHost);

    document.addEventListener("click", (event) => {
      if (!resultsHost.contains(event.target as Node)) {
        this.resultsList.style.display = "none";
      }
    });
  }

  private scheduleSearch(): void {
    clearTimeout(this.searchTimer);
    this.searchTimer = setTimeout(() => void this.search(), SEARCH_DEBOUNCE_MS);
  }

  private async search(): Promise<void> {
    const token = ++this.searchToken;
    let paths: string[];
    try {
      ({ paths } = await this.bridge.workspaceFileList(this.input.value));
    } catch {
      if (token !== this.searchToken) return; // a newer keystroke superseded this search
      // No daemon endpoint behind workspaceFileList yet (see this file's doc
      // comment): render the always-on alternative rather than a search
      // failure the user can do nothing about.
      this.renderMessage("Type a full path and press Return to open it.", "hint");
      return;
    }
    if (token !== this.searchToken) return; // a newer keystroke superseded this search

    if (paths.length === 0) {
      this.resultsList.replaceChildren();
      this.resultsList.style.display = "none";
      return;
    }
    this.resultsList.replaceChildren();
    for (const path of paths.slice(0, 50)) {
      const opt = document.createElement("div");
      opt.className = "opt";
      opt.textContent = path;
      opt.addEventListener("click", () => {
        this.resultsList.style.display = "none";
        this.input.value = path;
        this.openGated(path);
      });
      this.resultsList.appendChild(opt);
    }
    this.resultsList.style.display = "block";
  }

  /** Renders a single non-clickable status row into the results dropdown: a quiet
   * "how to open a file" hint when search is unavailable, or a factual error when
   * an opened path failed to read — leaving the input as-is so it can be corrected. */
  private renderMessage(text: string, kind: "hint" | "error"): void {
    this.resultsList.replaceChildren();
    const row = document.createElement("div");
    row.className = `msg ${kind}`;
    row.textContent = text;
    this.resultsList.appendChild(row);
    this.resultsList.style.display = "block";
  }

  /** Builds (once) or reuses the edit-mode `CodeView` and hands it a fresh single-file item.
   *  Shared by `open()` (disk content) and `restoreState()`'s dirty branch (a rehydrated buffer
   *  that must NOT be re-read from disk), so the two paths can't drift apart. */
  private loadIntoCodeView(path: string, content: string): void {
    if (!this.codeView) {
      this.codeView = new CodeView({
        theme: CODE_PANE_THEME_NAME,
        createEditor: (options) => new Editor(options),
        onItemEditChange: (_item, file) => {
          this.latestContent = file.contents;
          this.dirty = true;
          this.saveBtn.disabled = this.conflict;
          this.scheduleEditorStatePush();
        },
      });
      this.codeView.setup(this.codeHost);
    }

    this.editGeneration += 1;
    const item: CodeViewItem = {
      id: path,
      type: "file",
      // Forced explicitly rather than left to auto-detection; see
      // theme/index.ts's resolveAllowedLanguage doc comment.
      file: { name: path, contents: content, cacheKey: path, lang: resolveAllowedLanguage(path) },
      edit: true,
      version: this.editGeneration,
    };
    this.codeView.setItems([item]);
  }

  /**
   * Gate in front of the two user-initiated ways to open a file (Return in the path input, a
   * search-suggestion click) — `open()` itself stays ungated, since `restoreState`'s clean branch
   * calls it directly with nothing at risk (that path only ever follows a fresh restore, never an
   * in-progress edit).
   *
   * round-13 Fix 1: silently replacing the buffer here would violate the spec's unsaved-edit
   * promise (README.md: "only quitting and reopening the app loses an unsaved edit") — a save-in-
   * progress buffer must not vanish just because the user typed a different path or clicked a
   * search result. A modal confirmation is out per this codebase's design rules (no new modal
   * surfaces), so the existing non-blocking banner carries the explicit discard consent instead:
   * clicking its action is the one deliberate way to abandon the current edit, distinct from the
   * silent replace this gate refuses to do on its own.
   *
   * round-15 Fix (Bugs A+B): this upfront check is a fast path only, not the whole contract. It
   * runs before the read starts, so it cannot see dirty state that arises WHILE that read is in
   * flight (the user typing into the currently-open file during a slow remote read) — `open()`
   * itself re-checks dirty at completion and raises the identical banner if the race occurred (see
   * the completion-check comment inside `open()`). And the banner's discard button no longer clears
   * `dirty` at click time: it commits the discard only once `open()` actually succeeds, via
   * `open(path, { discard: true })`, so a read that fails after a discard click leaves the old
   * buffer correctly marked dirty rather than lying about it having been abandoned.
   */
  private openGated(path: string): void {
    if (this.dirty && this.currentPath !== undefined) {
      this.showDiscardBanner(path);
      return;
    }
    void this.open(path);
  }

  /** Renders the non-blocking discard-consent banner used by `openGated`'s gate and by `open()`'s
   *  own completion-time recheck (see both call sites' comments). Only ever called when
   *  `this.currentPath !== undefined` already holds, so reading it directly here is safe. */
  private showDiscardBanner(targetPath: string): void {
    const from = this.currentPath;
    const text = document.createElement("span");
    text.textContent = `Unsaved changes in ${from}. Save them first, or discard them to open ${targetPath}.`;
    const discardBtn = document.createElement("button");
    discardBtn.type = "button";
    discardBtn.className = "btn";
    discardBtn.textContent = "Discard edits and open";
    discardBtn.addEventListener("click", () => {
      void this.open(targetPath, { discard: true });
    });
    this.banner.className = "banner conflict";
    this.banner.replaceChildren(text, discardBtn);
    this.banner.style.display = "flex";
  }

  private async open(path: string, opts?: { discard?: boolean }): Promise<void> {
    const generation = ++this.openGeneration;
    let result: WorkspaceFileReadResult;
    try {
      result = await this.bridge.workspaceFileRead(path);
    } catch (err) {
      if (generation !== this.openGeneration) return; // a later open() already won
      const message = err instanceof SpacesBridgeError ? err.message : "Failed to open file.";
      this.renderMessage(message, "error");
      return; // leave the input editable so the user can correct the path
    }
    if (generation !== this.openGeneration) return; // a later open() already won
    if (!opts?.discard && this.dirty && this.currentPath !== undefined) {
      // Bug A fix: a DIFFERENT open (openGated's own upfront check, which ran before this read
      // started) cannot see dirty state that arises WHILE this read is in flight — the user may
      // type into the currently-open file during the seconds a remote read can take. Rechecking
      // here, at completion, is what actually closes that race, showing the identical consent
      // banner instead of silently replacing the buffer.
      //
      // The `!opts?.discard` guard is required, not optional: Bug B's fix (above) stops clearing
      // `dirty` at the discard button's click time, deferring that clear to this function's own
      // success path. Without this guard, a discard-open's own completion would see
      // `this.dirty === true` (never cleared before the call) and treat its OWN replacement as a
      // conflict, re-raising the very banner the user just dismissed — forever, since every
      // subsequent discard attempt would hit the same unmet condition. The flag marks "this call IS
      // the user's chosen resolution of that conflict, do not re-litigate it."
      this.showDiscardBanner(path);
      return;
    }
    this.resultsList.replaceChildren();
    this.resultsList.style.display = "none";
    this.input.value = path;
    this.currentPath = path;
    this.baseSHA256 = result.sha256;
    this.latestContent = result.content;
    this.dirty = false;
    this.conflict = false;
    this.banner.style.display = "none";
    this.saveBtn.disabled = true;

    this.loadIntoCodeView(path, result.content);
    // Immediate, not debounced: a file open is a discrete transition, not a buffer edit.
    this.pushEditorStateNow();
  }

  /**
   * Rehydrates the editor from the host's post-hibernation snapshot (`spaces:init`'s
   * `editorState` field, see README.md "Editor state survives hibernation"). Called once at
   * startup, before anything else touches this view.
   *
   * - `state` absent: nothing to restore — blank editor, same as a pane's first-ever load.
   * - `state.dirty`: the buffer had unsaved edits when the pane last hibernated. Restoring the
   *   exact buffer + CAS baseline the host held, with NO disk re-read, is what makes those edits
   *   survive — a re-read here would silently discard them in favor of whatever is on disk.
   * - not dirty: only the path is worth restoring — the buffer matched disk when it was pushed, so
   *   a fresh read of the (possibly now-stale) clean copy wins, through the normal `open()` path
   *   (same error handling, same immediate re-push).
   */
  async restoreState(state: CodePaneEditorState | undefined): Promise<void> {
    if (!state) return;
    if (!state.dirty) {
      await this.open(state.path);
      return;
    }
    this.input.value = state.path;
    this.currentPath = state.path;
    this.baseSHA256 = state.baseSHA256;
    this.latestContent = state.content;
    this.dirty = true;
    this.conflict = false;
    this.banner.style.display = "none";
    this.saveBtn.disabled = false; // mirrors onItemEditChange's post-edit state: unsaved edits exist
    this.loadIntoCodeView(state.path, state.content);
    // No push here: this is a same-value echo of the snapshot the host already holds, not a new
    // state transition — pushing it back would be a no-op round trip.
  }

  /** Builds the editor's current open-file snapshot, or `undefined` when no file is open. Shared by
   *  `pushEditorStateNow` (the push path) and `collectStateForFlush` (the host's teardown pull), so
   *  the two can't disagree about what "current state" means. */
  private collectEditorState(): CodePaneEditorState | undefined {
    if (!this.currentPath || this.baseSHA256 === undefined || this.latestContent === undefined) {
      return undefined;
    }
    return {
      path: this.currentPath,
      baseSHA256: this.baseSHA256,
      content: this.latestContent,
      dirty: this.dirty,
    };
  }

  /** Sends the editor's current open-file snapshot (or `undefined` when no file is open) to the
   *  host immediately, bypassing the debounce timer. Called on every discrete transition (open,
   *  save, conflict) rather than just left to the debounced path, so those transitions can't be
   *  lost to a hibernation racing the trailing timer. The payload is at most the file's content
   *  (already capped at the existing 10 MiB `workspaceFileRead` limit; real sources are typically
   *  KBs) — the extra postMessage/structured-clone cost on every edit is accepted as cheap relative
   *  to losing the user's buffer. */
  private pushEditorStateNow(): void {
    clearTimeout(this.editorStatePushTimer);
    this.bridge.notifyEditorStateChanged(this.collectEditorState());
  }

  /** Trailing debounce for the push on buffer edits: a keystroke-by-keystroke push would be wasted
   *  work between keystrokes, while the immediate pushes above already cover every transition that
   *  can't tolerate the delay. A buffer edit inside this window used to be at risk of loss if a
   *  hibernating teardown landed before the timer fired; that race is closed by
   *  `window.__spacesCollectEditorState` (wired to `collectStateForFlush` in root.ts), which the
   *  Swift host pulls synchronously at teardown regardless of where this timer is. */
  private scheduleEditorStatePush(): void {
    clearTimeout(this.editorStatePushTimer);
    this.editorStatePushTimer = setTimeout(() => this.pushEditorStateNow(), EDITOR_STATE_DEBOUNCE_MS);
  }

  /** Host-pulled counterpart to the push path: called synchronously (no debounce, no async work)
   *  by `window.__spacesCollectEditorState` at teardown, so it always reflects whatever the buffer
   *  holds at that exact instant, including an edit still inside `scheduleEditorStatePush`'s window.
   *  Returns the JSON-stringified `CodePaneEditorState`, or `null` when no file is open — matching
   *  `decodeCollectedEditorState`'s expectations on the Swift side. */
  collectStateForFlush(): string | null {
    const state = this.collectEditorState();
    return state ? JSON.stringify(state) : null;
  }

  private async save(): Promise<void> {
    if (!this.currentPath || this.latestContent === undefined || !this.baseSHA256) return;
    // Re-entrancy guard: a second save() (a queued click, or a programmatic call) can still start
    // before this call's first await yields control back to the DOM, which would submit two CAS
    // writes against the same baseline from the same tab. Disabling the button is the visible half
    // of this; the flag is the half that actually blocks it.
    if (this.saveInFlight) return;
    this.saveInFlight = true;
    this.saveBtn.disabled = true;
    // Captured before the await, alongside `submitted` below: identifies which file this save
    // belongs to. If the user opens a different file before this write resolves, `openGeneration`
    // moves on and this call's completion must not touch `baseSHA256`/`dirty`/`conflict`/the banner/
    // `saveBtn` — all of those now describe the newly opened file, not this one.
    const generation = this.openGeneration;
    try {
      // Captured before the await: this exact string is what's being submitted, and (per the
      // success arm below) what ends up on disk. `this.latestContent` can move on underneath this
      // call if the user keeps typing while the write is in flight — the two must not be conflated.
      const submitted = this.latestContent;
      let result: WorkspaceFileWriteResult;
      try {
        result = await this.bridge.workspaceFileWrite(this.currentPath, submitted, {
          baseSHA256: this.baseSHA256,
        });
      } catch (err) {
        if (generation !== this.openGeneration) return; // a later open() already won; this failure is moot
        // A rejected write (offline device, timeout, daemon error — e.g. a `SpacesBridgeError` with
        // code `unavailable`) never got a decodable answer from the daemon at all, unlike the
        // `conflict` branch below which is a durable CAS rejection the daemon *did* decode and
        // apply its rules to. Treat it as transient: surface it factually but do NOT set
        // `this.conflict` — a real conflict permanently disables Save until the next open(); this
        // must not latch the same way, since a retry of the exact same write can still succeed.
        const message = err instanceof SpacesBridgeError ? err.message : "Failed to save file.";
        // "error" styling (not "conflict") keeps this visually distinct from a real CAS conflict —
        // see the conflict arm below, which sets its own class back explicitly since the banner
        // element no longer has a fixed class after this arm can run.
        this.banner.className = "banner error";
        this.banner.textContent = message;
        this.banner.style.display = "flex";
        // Re-enable Save iff the buffer is still dirty, mirroring the success arm's own rule —
        // `saveInFlight`/`saveBtn.disabled` were both set at entry, so this is what undoes that.
        this.saveBtn.disabled = !this.dirty;
        // Immediate: a save failure is a discrete transition, not a buffer edit.
        this.pushEditorStateNow();
        return;
      }
      if (generation !== this.openGeneration) {
        // A newer open() already moved this pane on to a different file. The write above was still
        // a valid CAS write for the superseded file's own content against its own baseline, so
        // disk is correct either way; there is just no in-memory editor state left for it to update.
        return;
      }
      if ("conflict" in result) {
        this.conflict = true;
        this.saveBtn.disabled = true;
        // Explicit here (not just relying on the constructor's initial class) because a prior save
        // attempt on this same file can have left the banner in "error" styling above.
        this.banner.className = "banner conflict";
        this.banner.textContent = result.fileMissing ? "File deleted on disk — save disabled" : "File changed on disk — save disabled";
        this.banner.style.display = "flex";
        // Immediate: conflict state changing is a discrete transition, not a buffer edit.
        this.pushEditorStateNow();
        return;
      }
      // The pair (submitted, write hash) is self-consistent by construction — adopt the write's own
      // hash as the next CAS baseline directly rather than re-reading the file. A re-read here would
      // instead race whatever else might write the file (e.g. an agent) between this save and the
      // read: a write landing in that window would make the re-read return someone else's hash
      // paired with this buffer's un-saved-again content, and the next save would then pass CAS and
      // silently overwrite it.
      this.baseSHA256 = result.sha256;
      // NOT unconditionally clean: the buffer showing in the editor right now is only guaranteed to
      // match disk if nothing was typed during the await. A keystroke that landed while this save was
      // in flight left `latestContent` ahead of `submitted` — that content was never written, so the
      // buffer must stay dirty against the baseline just adopted above (its own next save CAS-checks
      // against this save's hash, which is correct: it is the disk state that content hasn't seen yet).
      this.dirty = this.latestContent !== submitted;
      this.saveBtn.disabled = !this.dirty;
      // Clears a save-failure banner left by a prior attempt on this same file (the conflict arm
      // above never falls through to here, so this can't accidentally hide a real conflict banner).
      this.banner.style.display = "none";
      // Immediate: a successful save is a discrete transition (new baseline, dirty possibly changed).
      this.pushEditorStateNow();
    } finally {
      this.saveInFlight = false;
    }
  }

  cleanUp(): void {
    clearTimeout(this.searchTimer);
    clearTimeout(this.editorStatePushTimer);
    this.codeView?.cleanUp();
  }
}
