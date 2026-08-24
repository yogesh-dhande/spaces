import {
  CodePaneAgentSummary,
  DiffFileEntry,
  PendingReviewCommentEntry,
  ReviewCommentSide,
  SpacesBridge,
  SpacesBridgeError,
  SpacesReviewComment,
} from "../bridge/types";
import { DiffCommentHooks, DiffView } from "./diffView";
import {
  AnchoredComment,
  anchoredLineNumber,
  formatReviewCommentsText,
  reanchorComments,
  selectDefaultAgentId,
} from "./reviewComments";

/** A gutter click's anchor, as reported by `DiffView`'s `onRequestNewComment` hook. */
interface NewCommentAnchor {
  filePath: string;
  side: ReviewCommentSide;
  lineNumber: number;
  lineText: string;
}

/** What the toolbar's agent picker / "Send batch" button need to know; pushed to `root.ts` on
 *  every change so it can fold this into the toolbar's own `update()` call. */
export interface CommentsToolbarState {
  agents: CodePaneAgentSummary[];
  selectedAgentId: string | undefined;
  /** Count of drafts with a non-empty body — an empty draft (a card opened but never typed into)
   *  is never sendable or batchable, per `reviewComments.ts`'s doc comments. */
  draftCount: number;
}

export interface CommentsControllerCallbacks {
  onToolbarStateChange(state: CommentsToolbarState): void;
}

const BANNER_TIMEOUT_MS = 4000;

/** Bounded-backoff floor/cap for `loadInitial`'s retry-on-transient-failure mechanism — same
 *  floor/doubling/cap shape as root.ts's `scheduleDiffRetry` and `editorView.ts`'s
 *  `scheduleExternalChangeRetry` (mirrored here, not imported/shared, matching those two's own
 *  precedent of a private per-file copy). */
const LOAD_INITIAL_RETRY_FLOOR_MS = 1000;
const LOAD_INITIAL_RETRY_CAP_MS = 30000;

/**
 * Owns the diff-mode comment surface end to end: the in-memory draft mirror (rehydrated once from
 * `reviewCommentList`, then kept in sync by local mutations only — see `loadInitial`'s doc
 * comment), the inline comment-card DOM (`DiffView`'s `renderAnnotation`/`onGutterUtilityClick`
 * hooks), the batch tray, and the assigned-agent selection. `root.ts` is the only caller.
 *
 * Construction is two-phase to break a circular dependency: `DiffView` needs this controller's
 * hooks *at construction time* (to pass into `@pierre/diffs`' `CodeView` options), but this
 * controller needs a live `DiffView` reference (for `setComments`/`scrollToLine`) that can only
 * exist after `DiffView` is built. `root.ts` therefore does:
 *   1. `new CommentsController(...)`
 *   2. `new DiffView(diffAreaEl, layout, controller.hooks)`
 *   3. `controller.attachDiffView(diffView)`
 *   4. `controller.mount(diffAreaEl)` — appended last, so the tray lands below the diff content.
 *
 * A gutter click never round-trips to the daemon by itself: the daemon rejects an empty-body
 * `reviewCommentUpsert` outright (a comment worth persisting has to say something), so a card
 * opened via `onRequestNewComment` is created as a *provisional*, client-local draft — keyed by a
 * local id from `provisionalSequence`, tracked in `provisionalIds`, never sent to the bridge. The
 * first successful `persistBody` call for that id (on blur, or on Send) creates the real row and
 * swaps the local key for the server-assigned one everywhere (`this.drafts`); until then, blurring
 * with an empty body or clicking Delete just drops the local entry, and Send/"Add to batch" treat
 * it the same as any other empty-body card (see `renderCard`).
 *
 * A card action (Send/Delete) is never the only thing racing that blur-time persist: a browser
 * fires a focused textarea's `blur` *before* delivering a button's `click` (mousedown fires blur
 * first), so clicking Send or Delete on a card that still has focus always follows a fire-and-forget
 * `persistBody` call that hasn't resolved yet. `pendingPersistById`/`idAliases` (below) are what let
 * `sendOne`/`deleteDraft`/`persistBody` itself coordinate around that race instead of assuming
 * whatever `provisionalIds`/`this.drafts` say synchronously is still true by the time an awaited
 * call actually runs.
 */
export class CommentsController {
  private readonly bridge: SpacesBridge;
  private readonly onToolbarStateChange: (state: CommentsToolbarState) => void;
  private diffView: DiffView | undefined;

  private drafts: SpacesReviewComment[] = [];
  private files: readonly DiffFileEntry[] = [];
  /** Ids whose inline card is hidden ("added to batch") — UI-only, per the spec's "ALL drafts ARE
   *  the batch" rule: this never affects which comments are sendable, only which ones render
   *  inline. The tray always lists every sendable draft regardless of this set. */
  private readonly collapsedIds = new Set<string>();
  private agents: readonly CodePaneAgentSummary[];
  private selectedAgentId: string | undefined;
  /** Set right after a new draft is created (no selection to restore — a brand-new card has
   *  nothing typed yet) or captured by `captureFocusedCard` just before a wholesale annotation
   *  rebuild, when a comment card's textarea currently has focus (with its caret/selection, to
   *  restore across the rebuild). `@pierre/diffs` rebuilds every annotation's DOM from scratch on
   *  every `setComments` call, and removing a focused element from the DOM fires no `blur` event —
   *  without this, a live diff refresh (an agent touching the working tree while the user is mid-
   *  comment) would silently kick the user out of the textarea they were typing in. Consumed
   *  (cleared) the first time the matching card is rendered again — see `renderCard`. Re-keyed by
   *  `persistBody` alongside `idAliases` when the id it names gets swapped for a server id mid-flight. */
  private pendingFocus: { id: string; selectionStart?: number; selectionEnd?: number } | undefined;
  /** Ids of drafts that exist only in this controller's local mirror and have never round-tripped
   *  to the daemon — see the class doc comment. Checked by `persistBody`/`sendOne` (create vs.
   *  update) and by `deleteDraft` (skip the RPC entirely for an id nothing server-side knows
   *  about). An id is removed from this set the moment its first persist succeeds. */
  private readonly provisionalIds = new Set<string>();
  /** Source for `provisionalIds` members — local to this controller, never sent to the daemon, so
   *  a plain monotonic counter is enough (no need for global uniqueness). */
  private provisionalSequence = 0;
  /** In-flight persist promises, keyed by the id `persistBody` was called with (which may itself
   *  be a still-provisional id). A browser delivers a focused textarea's `blur` before a button's
   *  `click`, so clicking Send or Delete on a focused card always races this fire-and-forget
   *  persist. Without serializing on it, both the blur and the action could independently call
   *  `reviewCommentUpsert` for a still-provisional draft (creating two rows for one comment), or a
   *  Delete could drop the local-only entry while the blur's persist still goes on to create an
   *  orphaned server row that reappears on the next reload. `sendOne`/`deleteDraft` await this
   *  (when present) before touching `this.drafts`/`provisionalIds` for the id they were given.
   *  Each promise resolves to whether that persist actually succeeded (`false` on a caught
   *  failure, never a rejection — see `doPersistBody`) — `sendBatch` is the one caller that reads
   *  this boolean, since a failed persist leaves `this.drafts` holding stale body/revision that its
   *  own revision-CAS retry can't catch (see `sendBatch`'s doc comment). `sendOne`/`deleteDraft`
   *  only need the ordering this map provides, not the result, so they await without inspecting it. */
  private readonly pendingPersistById = new Map<string, Promise<boolean>>();
  /** In-flight delete promises, keyed the same way `pendingPersistById` is — by whatever id
   *  `deleteDraft` was called with, AND (if different) by the id it resolves to via `resolveId`,
   *  since either key might be what a racing caller (`sendBatch`) holds. Exists for the same reason
   *  `pendingPersistById` does: the blur handler's empty-draft auto-discard (`renderCard`) fires
   *  `deleteDraft` fire-and-forget, and without tracking it, `sendBatch` could race that delete and
   *  send a card's stale (already-cleared) body, or the delete could remove a row `sendBatch` is
   *  mid-way through sending. Cleared the same only-if-still-mine way `pendingPersistById` is —
   *  `deleteDraft`'s own try/finally does this on every exit path of `doDeleteDraft` (success,
   *  provisional early-return, or the catch path), so unlike `idAliases`/`liveBodies`/
   *  `pendingPersistById`, `forgetDraftState` does not also need to clear this map: by the time
   *  `forgetDraftState` is called (always from inside `doDeleteDraft`, before it returns), this
   *  entry is still technically present, but `deleteDraft`'s wrapper clears it immediately once
   *  `doDeleteDraft`'s promise settles, which happens right after — so nothing here ever outlives
   *  its call. */
  private readonly pendingDeleteById = new Map<string, Promise<void>>();
  /** Provisional id -> server-assigned id, recorded the moment a provisional draft's first persist
   *  succeeds (alongside the existing `provisionalIds`/`this.drafts` re-keying). A card action
   *  (`sendOne`/`deleteDraft`) can be invoked with the pre-persist id — it was read synchronously
   *  before an awaited `pendingPersistById` entry resolved and re-keyed the draft — so those callers
   *  re-resolve through `resolveId` after their await rather than trusting the id they were called
   *  with; without this, such a call would silently find nothing and no-op. */
  private readonly idAliases = new Map<string, string>();
  /** In-progress textarea text, updated on every `input` (not `blur`) event — keyed the same way
   *  `pendingPersistById`/`idAliases` are. `renderCard` seeds a rebuilt card's textarea from here
   *  (falling back to `comment.body`, the last-*persisted* value) instead of always starting from
   *  `comment.body`, so a wholesale annotation rebuild (see `pendingFocus`'s doc comment) never
   *  silently discards keystrokes typed since the last blur. Cleared once a persist lands with
   *  exactly this text (nothing typed since), and when a draft is sent or deleted — see
   *  `forgetDraftState`. Re-keyed by `persistBody` alongside `idAliases`/`pendingFocus` when a
   *  provisional id is swapped for a server id while an edit is still in flight.
   */
  private readonly liveBodies = new Map<string, string>();
  /** Holds a persisted (non-provisional) `restorePendingState` entry only for the window between
   *  that call and `loadInitial()`'s successful resolution — see `restorePendingState`'s doc
   *  comment for why a persisted entry's draft object doesn't exist in `this.drafts` yet during
   *  that window. This is not a second source of truth for the draft's state: once `loadInitial()`
   *  has merged the real row in, `this.drafts`/`liveBodies` are authoritative again and this map is
   *  cleared wholesale (see `loadInitial`). It exists solely so a second teardown landing inside
   *  that window (`collectStateForFlush`) still has something to recover the typed text from. */
  private readonly restoredPendingById = new Map<string, PendingReviewCommentEntry>();
  /** Fix 4 (round-2) / round-2b: ids removed locally (a send or delete completing) while EITHER
   *  `loadInitial`'s own `reviewCommentList` call OR `reconcileMirrorAfterRejection`'s own relist
   *  call is in flight — see `listCallsInFlight`. Each method's response is a snapshot taken when its
   *  RPC was dispatched, so a send/delete that completes locally before that response actually lands
   *  is otherwise invisible to it: the response still carries the now-archived/deleted row, and
   *  merging it in (both methods' response-wins rule — see each one's own doc comment) would
   *  resurrect it as a ghost card right after the user watched it disappear. Recorded under the
   *  removed draft's RESOLVED id (`resolveId`) — the same id a response row would be keyed by — at
   *  the moment `sendOne`/`sendBatch`/`doDeleteDraft` complete successfully, guarded by
   *  `this.listCallsInFlight > 0` (true whenever either method has a response still outstanding).
   *  Both `loadInitial` and `reconcileMirrorAfterRejection` filter their own response against this
   *  set before merging, on their success path only — a rejected `reviewCommentList` call consumed no
   *  response, so it has nothing here to apply or clear (see `listCallsInFlight`'s doc comment for why
   *  a failed call must leave the set untouched for whichever call actually applies it later).
   *
   *  A tombstone lives for as long as ANY list call that predates the removal is still un-applied: the
   *  completing call's own filter step clears the set only once `listCallsInFlight` has returned to
   *  zero after ITS OWN decrement, never while the other call is still outstanding — that other call's
   *  response is an equally stale snapshot with respect to the same removed id, so clearing early
   *  would let it resurrect the exact ghost this set exists to prevent. The resulting slight
   *  over-retention across an overlapping call (a tombstone staying recorded a little longer than the
   *  one call that actually needed it) is deliberate, not a leak — the set is still bounded by
   *  whichever of the two calls finishes last. */
  private readonly removedWhileListInFlight = new Set<string>();
  /** Count of `reviewCommentList` calls currently in flight, across BOTH `loadInitial`'s own call
   *  (including each retry attempt's — see `scheduleLoadInitialRetry`) and
   *  `reconcileMirrorAfterRejection`'s own relist call. A plain boolean is not enough here: the two
   *  calls can genuinely overlap — a `loadInitial` retry can still be parked on the daemon when a
   *  rejected send/delete fires `reconcileMirrorAfterRejection`'s own relist — and a boolean would be
   *  clobbered to `false` by whichever of the two completes first, prematurely closing the tombstone
   *  window the other call's still-outstanding (and equally stale) response still needs. Incremented
   *  right before each of the two methods' own `reviewCommentList` await, decremented on every outcome
   *  path of each (their success and catch branches alike). Gates whether a successful removal needs
   *  to record a `removedWhileListInFlight` tombstone at all (`this.listCallsInFlight > 0`): at zero
   *  there is no in-flight response left to race, so the row is simply never in a later response — the
   *  ordinary, unraced case that needs no bookkeeping. */
  private listCallsInFlight = 0;
  /** Consecutive-failure counter and pending-timer handle for `loadInitial`'s retry-on-transient-
   *  failure mechanism — same shape as `EditorView`'s `externalChangeRetryFailures`/
   *  `externalChangeRetryTimer` (see that class for the fuller rationale). `root.ts` calls
   *  `loadInitial` exactly once; without a retry, a transient `reviewCommentList` failure (the pane
   *  opened while the device is briefly unavailable — a daemon restart/update, a remote offline at
   *  open) would surface a banner and give up for the rest of the page's lifetime, leaving
   *  persisted drafts invisible even though the restart/hibernation persistence contract promises
   *  them back. Reset to 0 whenever a call reaches a decoded outcome (a successful response), so a
   *  later transient failure starts its own backoff at the floor rather than inheriting whatever
   *  count a prior run left behind. */
  private loadInitialRetryFailures = 0;
  private loadInitialRetryTimer: ReturnType<typeof setTimeout> | undefined;
  /** The send currently being delivered, if any — `sendOne` and `sendBatch` both await it before
   *  starting and publish their own run into it, so overlapping send gestures (double-click on a
   *  card's Send, Send batch while a single send is pending, two batch clicks) serialize instead of
   *  racing. The daemon rejects a whole send request when ANY of its comments is already archived,
   *  so letting the second gesture run concurrently would turn the first one's success into a false
   *  "not a draft" failure — and for a batch, would leave every other draft unsent. After the wait,
   *  the second sender re-validates against post-send state: a sent draft is gone from `this.drafts`,
   *  so a double-click's second `sendOne` no-ops and a trailing `sendBatch` sends only what actually
   *  remains. */
  private sendInFlight: Promise<void> | undefined;

  private readonly banner: HTMLElement;
  private bannerTimer: ReturnType<typeof setTimeout> | undefined;
  private readonly tray: HTMLElement;
  private readonly trayList: HTMLElement;
  private readonly trayCount: HTMLElement;
  private readonly trayCaret: HTMLElement;
  private trayExpanded = true;

  constructor(bridge: SpacesBridge, agents: readonly CodePaneAgentSummary[], callbacks: CommentsControllerCallbacks) {
    this.bridge = bridge;
    this.agents = agents;
    this.selectedAgentId = selectDefaultAgentId(agents, undefined);
    this.onToolbarStateChange = callbacks.onToolbarStateChange;

    this.banner = document.createElement("div");
    this.banner.className = "banner error";
    this.banner.style.display = "none";

    this.tray = document.createElement("div");
    this.tray.className = "comment-tray";

    const header = document.createElement("div");
    header.className = "comment-tray-header";
    const title = document.createElement("span");
    title.className = "comment-tray-title";
    title.textContent = "Comments";
    this.trayCount = document.createElement("span");
    this.trayCount.className = "comment-tray-count";
    this.trayCaret = document.createElement("span");
    this.trayCaret.className = "comment-tray-caret";
    header.appendChild(title);
    header.appendChild(this.trayCount);
    const headerSpacer = document.createElement("span");
    headerSpacer.className = "sp";
    header.appendChild(headerSpacer);
    header.appendChild(this.trayCaret);
    header.addEventListener("click", () => {
      this.trayExpanded = !this.trayExpanded;
      this.updateTrayExpansion();
    });
    this.tray.appendChild(header);

    this.trayList = document.createElement("div");
    this.trayList.className = "comment-tray-list";
    this.tray.appendChild(this.trayList);

    this.tray.style.display = "none"; // hidden until there is at least one sendable draft
    this.updateTrayExpansion();
  }

  /** Appends this controller's DOM (error banner, batch tray) into `container`. Called after
   *  `DiffView` has already appended its own children, so the tray lands visually below the diff
   *  content rather than above it. */
  mount(container: HTMLElement): void {
    container.appendChild(this.banner);
    container.appendChild(this.tray);
  }

  attachDiffView(diffView: DiffView): void {
    this.diffView = diffView;
  }

  /** Hooks passed into `DiffView`'s constructor — see the class doc comment on construction order. */
  get hooks(): DiffCommentHooks {
    return {
      renderCard: (anchored) => this.renderCard(anchored),
      onRequestNewComment: (anchor) => this.createDraft(anchor),
    };
  }

  /**
   * One-time rehydration from the daemon's draft store, called once from `root.ts` after mount
   * (workspace-scoped, independent of `refreshDiff`'s scope-driven pull). Every subsequent change
   * — create/edit/delete/send, and every `spaces:agents` push — updates this in-memory mirror
   * directly; a live diff refresh only re-anchors the existing drafts against the new file set
   * (`setFiles`), it never re-fetches them. Re-fetching on every refresh would let a slow
   * `reviewCommentList` reply race a local mutation and silently revert it.
   *
   * The response is *merged* into `this.drafts`, not assigned wholesale: this RPC can take a
   * moment, and a gutter click (a provisional draft, which never round-trips) or a fast
   * `persistBody` can land locally while it is still in flight. Response rows win (they are the
   * daemon's authoritative state as of just now); any currently-held local draft whose id — after
   * resolving through `idAliases`, in case it was re-keyed mid-flight — is *not* already present in
   * the response is kept too. That covers both a still-open provisional card (it never round-trips,
   * so it can never appear in the response) and a draft whose persist landed server-side after the
   * list snapshot was taken (present locally under its real id, and, if the persist actually beat
   * the list request server-side, possibly *also* in the response under that same id — which is why
   * the id filter matters: plain concatenation would double-list it).
   *
   * `reconcileMirrorAfterRejection` merges its own relist response differently — see its doc
   * comment. The rules diverge because the two callers start from different priors: this method's
   * caller has no proof any currently-held local draft is stale (it is an ordinary rehydration), so
   * it can afford to keep every one of them; `reconcileMirrorAfterRejection`'s caller just received
   * proof from the daemon that this client's mirror was wrong about something, so it must not
   * blindly keep everything absent from the response.
   *
   * A `reviewCommentList` rejection is retried with bounded backoff (`loadInitialRetryFailures`/
   * `scheduleLoadInitialRetry`) rather than given up on after one attempt — see
   * `loadInitialRetryFailures`'s doc comment. A retry landing after the user already started
   * drafting is safe: `stillLocalOnly` above already keeps any id absent from the response (a
   * provisional draft never round-trips, so it can never appear there), the same as it does for the
   * very first call.
   */
  async loadInitial(): Promise<void> {
    // Cancels any pending retry: this call — whether the original one-time invocation or the retry
    // timer's own re-invocation — is itself a fresh attempt that supersedes it.
    clearTimeout(this.loadInitialRetryTimer);
    this.listCallsInFlight += 1;
    let response: SpacesReviewComment[];
    try {
      response = await this.bridge.reviewCommentList();
    } catch (err) {
      // Decrement only — never clear `removedWhileListInFlight` here: this attempt consumed no
      // response, so any tombstone recorded during its window is still owed to whichever call next
      // actually applies a response (this method's own retry, or an overlapping
      // `reconcileMirrorAfterRejection` relist) — see `removedWhileListInFlight`'s doc comment.
      this.listCallsInFlight -= 1;
      // Only the FIRST failure in a retry run shows the banner — re-showing it on every retry
      // attempt would be a distracting flicker for what is, from the user's point of view, a single
      // ongoing "still trying to load" condition.
      if (this.loadInitialRetryFailures === 0) this.surfaceError(err, "Failed to load draft comments.");
      this.scheduleLoadInitialRetry();
      return;
    }
    this.loadInitialRetryFailures = 0;
    // Fix 4 (round-2) / round-2b: drop any response row a send/delete already removed locally while
    // this call — or an overlapping `reconcileMirrorAfterRejection` relist — was in flight (see
    // `removedWhileListInFlight`'s doc comment) before folding the response in. The tombstones this
    // filter consumes are cleared only once `listCallsInFlight` has returned to zero after THIS
    // call's own decrement below: an overlapping reconcile relist still outstanding needs the same
    // tombstones for its own equally-stale response, so clearing them here while it is still in
    // flight would reopen the exact race this filter exists to close.
    const survivingResponse = response.filter((d) => !this.removedWhileListInFlight.has(d.id));
    this.listCallsInFlight -= 1;
    if (this.listCallsInFlight === 0) this.removedWhileListInFlight.clear();
    const responseIds = new Set(survivingResponse.map((d) => d.id));
    const stillLocalOnly = this.drafts.filter((d) => !responseIds.has(this.resolveId(d.id)));
    this.drafts = [...survivingResponse, ...stillLocalOnly];
    // The restore→list-merge race `restoredPendingById` exists to bridge (see its doc comment) is
    // over now that this response has landed: an id present in `response` is a real draft object
    // going forward, covered normally by `this.drafts`/`liveBodies`; an id absent from it was
    // deleted or sent remotely while this pane was torn down — delete/send are the only two actions
    // that legitimately remove a draft, so resurrecting that text is not a promise this mechanism
    // makes. Either way nothing is left for the map to hold past this point.
    this.restoredPendingById.clear();
    this.refresh();
  }

  /** Schedules the next `loadInitial` retry attempt after a `reviewCommentList` rejection — same
   *  floor/doubling/cap backoff shape as root.ts's `scheduleDiffRetry` and `editorView.ts`'s
   *  `scheduleExternalChangeRetry`. No generation/token guard is needed here (unlike those two):
   *  `root.ts` calls `loadInitial` exactly once as its own entry point, so this timer is the only
   *  thing that will ever re-invoke it, and `loadInitial`'s own `clearTimeout` at the top of every
   *  call means a fresh attempt (this timer firing) never overlaps a still-pending one. */
  private scheduleLoadInitialRetry(): void {
    const delay = Math.min(LOAD_INITIAL_RETRY_FLOOR_MS * 2 ** this.loadInitialRetryFailures, LOAD_INITIAL_RETRY_CAP_MS);
    this.loadInitialRetryFailures += 1;
    clearTimeout(this.loadInitialRetryTimer);
    this.loadInitialRetryTimer = setTimeout(() => {
      void this.loadInitial();
    }, delay);
  }

  /**
   * round-16 Fix 1a: the Swift host calls this synchronously at web-view teardown (mirroring
   * `EditorView.collectStateForFlush`/`window.__spacesCollectEditorState` — see that method's doc
   * comment for the hibernation reasoning this mirrors) to snapshot any comment text that has been
   * typed but not yet persisted, so it survives the teardown and is rehydrated via `spaces:init`'s
   * `pendingReviewComments` field on the next page load (see `restorePendingState`).
   *
   * A draft is included only if it has unpersisted live text: a still-provisional card (never
   * round-tripped — see the class doc comment) whose live body is non-empty, or a persisted draft
   * whose `liveBodies` entry differs from its last-persisted `body` (typed since the last blur, or
   * since the last successful `doPersistBody`). A clean persisted draft or an empty provisional
   * card has nothing to lose at teardown, so it is left out — the next page load hydrates persisted
   * drafts through the ordinary `loadInitial` call instead.
   *
   * Returns `null` (not `"[]"`) when nothing is pending, matching `'__none__'`'s meaning on the
   * Swift side — see `decodeCollectedReviewCommentState`'s doc comment there.
   *
   * A second pass over `restoredPendingById` follows the main loop, to cover a persisted entry
   * `restorePendingState` is still holding because `loadInitial()` hasn't merged its real draft
   * object into `this.drafts` yet (see that map's doc comment): without it, a second teardown
   * landing inside that restore→list-merge window would find nothing in `this.drafts` for that id
   * and silently lose the text a first teardown had already recovered.
   *
   * This is also this controller's one teardown seam (the Swift host's synchronous call is the
   * only signal this controller ever gets that the page is going away), so it doubles as the place
   * `loadInitial`'s pending retry timer (see `loadInitialRetryFailures`'s doc comment) is cleared —
   * a retry firing after teardown would call `reviewCommentList` again for a page nobody is looking
   * at any more.
   */
  collectStateForFlush(): string | null {
    clearTimeout(this.loadInitialRetryTimer);
    const entries: PendingReviewCommentEntry[] = [];
    for (const draft of this.drafts) {
      const live = this.liveBodies.get(draft.id);
      if (live === undefined) continue;
      const provisional = this.provisionalIds.has(draft.id);
      if (provisional ? live.trim().length === 0 : live === draft.body) continue;
      entries.push({
        id: draft.id,
        provisional,
        filePath: draft.filePath,
        side: draft.side,
        lineNumber: draft.lineNumber,
        lineText: draft.lineText,
        body: live,
      });
    }
    for (const [id, entry] of this.restoredPendingById) {
      if (this.drafts.some((d) => d.id === id)) {
        // The real draft object has since arrived (via loadInitial's merge) — the main loop above
        // now covers this id (whether or not it actually emitted it, which depends only on whether
        // its live text has diverged), so this held copy no longer needs to survive further.
        this.restoredPendingById.delete(id);
        continue;
      }
      // Still not merged in — keep holding it (don't delete here) in case a further teardown lands
      // before loadInitial() resolves.
      entries.push({
        id,
        provisional: false,
        filePath: entry.filePath,
        side: entry.side,
        lineNumber: entry.lineNumber,
        lineText: entry.lineText,
        body: this.liveBodies.get(id) ?? entry.body,
      });
    }
    return entries.length === 0 ? null : JSON.stringify(entries);
  }

  /**
   * round-16 Fix 1a: seeds drafts/live text from a teardown snapshot the Swift host handed back in
   * `spaces:init`'s `pendingReviewComments` field (see `collectStateForFlush`). Called from
   * `root.ts` *before* `loadInitial()`'s network-awaiting call — the same ordering rule
   * `EditorView.restoreState` follows — so a teardown racing this pane's next hibernation cycle
   * flushes this seeded state right back out rather than losing it.
   *
   * A provisional entry never round-tripped to the daemon, so it is recreated as a brand-new local
   * draft under a *fresh* provisional id (`provisionalSequence` restarts at 0 every page load — reusing
   * the pre-teardown id risks colliding with an id minted this session). A persisted entry's draft
   * object is not recreated here: it arrives through `loadInitial()`'s existing merge-by-id logic
   * once the list response lands, so only its live (unsaved) text is seeded into `liveBodies` ahead of
   * that — the card immediately renders the in-progress text (see `renderCard`'s `liveBodies` lookup),
   * and the next blur persists it through the normal `persistBody` path, unchanged.
   */
  restorePendingState(entries: readonly PendingReviewCommentEntry[]): void {
    if (entries.length === 0) return;
    for (const entry of entries) {
      if (entry.provisional) {
        const id = `provisional-${++this.provisionalSequence}`;
        const now = new Date().toISOString();
        const draft: SpacesReviewComment = {
          id,
          filePath: entry.filePath,
          side: entry.side,
          lineNumber: entry.lineNumber,
          lineText: entry.lineText,
          body: "",
          createdAt: now,
          revision: 0,
        };
        this.provisionalIds.add(id);
        this.drafts = [...this.drafts, draft];
        this.liveBodies.set(id, entry.body);
      } else {
        this.liveBodies.set(entry.id, entry.body);
        // Held until `loadInitial()`'s response merges the real draft object in — see
        // `restoredPendingById`'s doc comment for the race this bridges.
        this.restoredPendingById.set(entry.id, entry);
      }
    }
    this.refresh();
  }

  /** Called from `refreshDiff` right after `diffView.setFiles(...)`, on every scope switch and
   *  live diff refresh — re-anchors the existing draft set against the new files without touching
   *  the drafts themselves. */
  setFiles(files: readonly DiffFileEntry[]): void {
    this.files = files;
    this.refresh();
  }

  /** Re-runs the same auto-default rule used at startup — see `spaces:agents`'s contract in
   *  README.md and `selectDefaultAgentId`'s doc comment. */
  onAgentsChanged(agents: readonly CodePaneAgentSummary[]): void {
    this.agents = agents;
    this.selectedAgentId = selectDefaultAgentId(agents, this.selectedAgentId);
    this.pushToolbarState();
    this.refreshCardsOnly();
  }

  onAgentSelected(id: string): void {
    this.selectedAgentId = id;
    this.pushToolbarState();
    this.refreshCardsOnly();
  }

  /** Public entry point for the toolbar's "Send batch" button — see `sendInFlight`'s doc comment for
   *  why this only waits for/publishes into the shared marker rather than doing any send work itself.
   *  `doSendBatch` (below) is the unchanged original body.
   *
   * Fix 3 (round-2 P1): the agent shown on the "Send batch" button is captured HERE, before the
   * `sendInFlight` wait — see the identical capture (and its full rationale) at the top of `sendOne`
   * below. A selection change (dropdown pick, or an agents-update auto-selecting a different agent)
   * during the queued wait — which can span the full duration of another in-flight send — or during
   * `doSendBatch`'s own drain must not reroute the batch to a different agent's terminal; if this
   * agent's session has ended by send time, `reviewCommentsSend` fails loudly through the existing
   * failure path, which is preferable to silently delivering into whatever agent is selected now. */
  async sendBatch(): Promise<void> {
    const agent = this.agents.find((a) => a.id === this.selectedAgentId);
    if (!agent) return; // toolbar keeps this disabled in this state; defensive no-op if reached anyway
    while (this.sendInFlight) await this.sendInFlight;
    const run = this.doSendBatch(agent);
    const published = run.finally(() => {
      // Only clear our own marker — a queued sender that started after us must not have its marker
      // wiped by our finally.
      if (this.sendInFlight === published) this.sendInFlight = undefined;
    });
    this.sendInFlight = published;
    await run;
  }

  /**
   * Sends every current sendable draft in one call. Unlike `sendOne`, this reads bodies from
   * `this.drafts` (the last-persisted value), not live from any card's textarea: a card mid-edit
   * that has not yet blurred still sends its last-saved body, not the in-progress keystrokes.
   * Accepted as-is — the toolbar's "Send batch" button lives outside any card, so there is no
   * single textarea whose blur this action could naturally trigger first, and forcing a blur on
   * every open card as a side effect of a toolbar click would be a surprising, hard-to-predict
   * side effect of its own.
   *
   * Drains `pendingPersistById`/`pendingDeleteById` in a loop — not a one-shot snapshot-then-await
   * — before reading anything from `this.drafts`, so the bodies/revisions read below are always
   * post-persist for every entry that was in flight at ANY point during the drain, not just the
   * ones in flight the instant "Send batch" was clicked. A one-shot snapshot taken before the first
   * await would miss a persist that *registers during* that await (e.g. another card gets
   * edited-and-blurred while this method is waiting): `this.drafts` would still hold that card's
   * stale pre-edit body/revision when the membership below is computed, and if the send RPC then
   * beat the delayed upsert to the daemon, the daemon would archive the stale body and reject the
   * upsert as already-sent — silently discarding the user's edit. Looping — re-snapshotting both
   * maps fresh after every `Promise.all` and only stopping once both come back empty — closes that
   * window: any persist that registers mid-drain is caught by the next iteration. Once the loop
   * exits, the membership computation below (`reanchorComments`, the sendable filter, `ids`/
   * `comments`) runs synchronously with no intervening await — JS is single-threaded, so nothing can
   * register between the last empty-maps check and the `reviewCommentsSend` call below. This closes
   * both possible race orderings between this call and a just-blurred card's fire-and-forget
   * `persistBody`:
   *   - Upsert-wins-first: if this were reached without waiting, the daemon's own `revision` check
   *     would reject this send as a `conflict` (see `handleSendFailure`), which re-fetches and
   *     re-renders — self-correcting, not a duplicate or an orphan.
   *   - Send-wins-first: without draining, `reviewCommentsSend` could reach the daemon's
   *     `reviewCommentQueue` *before* a racing upsert does, archiving whatever body the daemon
   *     currently has (the stale, pre-edit one) and then rejecting the delayed upsert as
   *     already-sent/gone — silently discarding the user's edit, with no error surfaced, because
   *     the client raced itself rather than something the daemon's revision check can catch.
   * This is not the same as `sendOne`/`deleteDraft`'s `resolveId` re-keying — a persist that isn't a
   * provisional-to-server swap doesn't change an id's identity, only its body/revision — so nothing
   * here needs `resolveId`.
   *
   * The residual window this cannot close: a blur that happens AFTER the drain loop has already
   * exited and `reviewCommentsSend` has already been issued. That is the same still-focused-card
   * acceptance noted above (a card mid-edit with no blur yet sends its last-saved body by design),
   * and the daemon's revision CAS turns a same-card race of that shape into a `conflict`
   * (self-correcting, see `handleSendFailure`) rather than a silent loss, because that upsert is now
   * the one racing an already-issued send rather than the reverse. This is the unavoidable minimum
   * without daemon-side coordination of persist-vs-send ordering.
   *
   * A *failed* persist (drained at any iteration) is a distinct case from the successful-racing-
   * persist ordering above, and cannot be handled the same way: `doPersistBody`'s catch block
   * surfaces the error but never updates `this.drafts`' body or revision, so after the drain,
   * `this.drafts` still holds the pre-edit body at the pre-edit revision — indistinguishable, from
   * this method's point of view, from a card that was never edited at all. The daemon's revision CAS
   * has nothing to catch here (the revision never bumped), so sending would silently
   * archive/deliver the wrong (stale) text. `pendingPersistById`'s promises therefore resolve to a
   * boolean, and this method checks every one of them at every iteration and aborts before computing
   * anything if any failed, leaving every draft untouched so the user can retry. A `deleteDraft` call
   * awaiting a pending persist internally (see `pendingDeleteById`'s doc comment) is already covered
   * correctly by the combined wait — by the time a `pendingDeleteById` promise resolves, any persist
   * it was itself waiting on has already resolved too, so there is no extra sequencing to add for
   * that case.
   *
   * Starvation is not a concern worth guarding against: each extra loop iteration requires another
   * user blur (a real interaction happening in real time), so the loop is naturally bounded by how
   * fast a person can type and click — no cap is added.
   */
  private async doSendBatch(agent: CodePaneAgentSummary): Promise<void> {
    // Fix 2 (round-2 P1): drain until quiescent — see the class doc comment above for the full race
    // this closes. Re-snapshot both maps fresh on every iteration so a persist/delete that registers
    // during the just-awaited `Promise.all` is caught on the next pass instead of being missed.
    for (;;) {
      const persists = [...this.pendingPersistById.values()];
      const deletes = [...this.pendingDeleteById.values()];
      if (persists.length === 0 && deletes.length === 0) break;
      const [persistResults] = await Promise.all([Promise.all(persists), Promise.all(deletes)]);
      if (persistResults.some((ok) => !ok)) {
        // A blur-time persist that was in flight during the drain failed — this.drafts still holds
        // the pre-edit body/revision (doPersistBody's catch never updates either), so sending now
        // would deliver stale text the daemon's revision CAS has no way to catch (the revision only
        // bumps on a successful persist). Abort before anything is computed/sent, leaving every
        // draft untouched so the user can re-blur (or edit again) and retry.
        this.surfaceError(undefined, "A recent edit failed to save — nothing was sent. Try again.");
        return;
      }
    }

    const anchored = reanchorComments(this.drafts, this.files);
    const sendableAnchored = anchored.filter((ac) => {
      // Sendability is judged on LIVE text (falling back to the persisted body when there is no live
      // entry), not just `comment.body`: a card cleared by the blur handler's auto-discard fires
      // `deleteDraft` (drained above), but if that delete RPC itself fails (a transport-shaped
      // rejection, not a typed one — see `reconcileMirrorAfterRejection`), the row survives in
      // `this.drafts` with its old non-empty body even though the user emptied it on screen.
      // Consulting live text here excludes it from the batch either way. The BODY actually sent
      // (below) stays the persisted one, unchanged from before this fix — by the time this filter
      // runs, every surviving sendable card's in-flight persist has already resolved (the drain loop
      // above only exits once both maps are empty), so persisted and live text agree for anything
      // this filter lets through, EXCEPT a still-focused card mid-edit with no blur yet: it passes on
      // its live text while its persisted body (what actually gets sent, per the still-focused-card
      // acceptance in the class doc comment above) lags behind. Fix 1 (P2): that gap's unsent live
      // text is not lost — see the success arm below, which preserves it via `preserveUnsentLiveText`
      // once the send that carried the stale persisted body succeeds.
      const liveText = this.liveBodies.get(ac.comment.id) ?? ac.comment.body;
      return liveText.trim().length > 0;
    });
    if (sendableAnchored.length === 0) return;
    const ids = sendableAnchored.map((ac) => ac.comment.id);
    const comments = sendableAnchored.map((ac) => ({ id: ac.comment.id, revision: ac.comment.revision }));
    try {
      await this.bridge.reviewCommentsSend(agent.sessionId, formatReviewCommentsText(sendableAnchored), comments);
    } catch (err) {
      // A rejection (including a stale-`revision` conflict) leaves every named draft exactly as
      // it was on the daemon, so nothing here is removed from `this.drafts` on failure.
      await this.handleSendFailure(err, "Failed to send the batch.");
      return;
    }
    const sentIds = new Set(ids);
    this.drafts = this.drafts.filter((draft) => !sentIds.has(draft.id));
    for (const ac of sendableAnchored) {
      const id = ac.comment.id;
      // Fix 1 (P2): captured BEFORE `forgetDraftState` below deletes it — see the sendable-filter
      // comment above and `preserveUnsentLiveText`'s doc comment for why a live entry surviving here
      // is the still-focused-card gap's unsent typing, not stale bookkeeping.
      const live = this.liveBodies.get(id);
      this.collapsedIds.delete(id);
      this.forgetDraftState(id);
      // Fix 4 (round-2) / round-2b: see `doDeleteDraft`'s identical guard — a `loadInitial` or
      // `reconcileMirrorAfterRejection` response already dispatched before this batch send completed
      // still carries these rows.
      if (this.listCallsInFlight > 0) this.removedWhileListInFlight.add(id);
      // `ac.comment.body` is the exact (persisted) text this send delivered for this card — a live
      // entry equal to it means nothing was typed beyond what was already saved.
      if (live !== undefined && live !== ac.comment.body && live.trim().length > 0) {
        this.preserveUnsentLiveText(ac.comment, live);
      }
    }
    this.refresh();
  }

  /** Opens a new card with no RPC — see the class doc comment. `anchor` becomes the draft's fixed
   *  identity fields (`filePath`/`side`/`lineNumber`/`lineText`); only `persistBody` ever sends
   *  them to the daemon, and only once the body is non-empty. */
  private createDraft(anchor: NewCommentAnchor): void {
    const id = `provisional-${++this.provisionalSequence}`;
    const now = new Date().toISOString();
    // `revision: 0` is a placeholder never actually sent: a provisional draft always round-trips
    // through `reviewCommentUpsert` (in `persistBody`/`sendOne`) before any send, and that response's
    // real `revision` replaces this one in `this.drafts` at that point.
    const draft: SpacesReviewComment = { id, ...anchor, body: "", createdAt: now, revision: 0 };
    this.provisionalIds.add(id);
    this.drafts = [...this.drafts, draft];
    this.pendingFocus = { id };
    this.refresh();
  }

  /** Resolves a possibly-stale draft id (captured before an await that may have re-keyed it) to
   *  its current key — see `idAliases`'s doc comment. A no-op for an id that was never provisional
   *  or has no recorded alias. */
  private resolveId(id: string): string {
    return this.idAliases.get(id) ?? id;
  }

  /** Drops bookkeeping for a draft that is gone for good (sent or deleted): `idAliases`,
   *  `liveBodies`, and `pendingPersistById` would otherwise accumulate dead entries, keyed by ids
   *  that will never be looked up again, over a long session. Accepts every id this draft has ever
   *  been known by — its original/provisional id, its resolved/current id, and (for `sendOne`) the
   *  server id a just-issued upsert returned — since any of them might still be a map key. */
  private forgetDraftState(...ids: string[]): void {
    for (const id of ids) {
      this.idAliases.delete(id);
      this.liveBodies.delete(id);
      this.pendingPersistById.delete(id);
      this.restoredPendingById.delete(id);
    }
  }

  /** Fix 1 (P2): called from `sendOne`'s and `sendBatch`'s success arms only, after they have
   *  already removed `sent` from `this.drafts` and called `forgetDraftState` for it. A `liveBodies`
   *  entry surviving at that point (passed in as `live`) is text typed since the last successful
   *  `doPersistBody` — see its re-key block above — that the just-completed send did not carry (the
   *  send always delivers a previously-persisted body, per `sendBatch`'s still-focused-card
   *  acceptance and `sendOne`'s live-body-at-click-time capture, either of which can predate a later
   *  keystroke). The sent row is archived server-side the moment the send succeeds, so without this,
   *  `forgetDraftState`'s `liveBodies.delete` would silently destroy that unsent typing — the only
   *  event that is allowed to lose an unsaved edit is quitting the app.
   *
   * Recreates the leftover text as a brand-new local draft at the same anchor, mirroring
   * `restorePendingState`'s provisional branch exactly (same shape: empty `body`, the text seeded
   * into `liveBodies` instead) so nothing downstream sees a novel state — `renderCard` already knows
   * how to render a provisional card whose live text hasn't been persisted yet, and the next blur
   * persists it through the normal `persistBody` path. Deliberately does not set `pendingFocus`:
   * unlike `createDraft` (a direct user action opening a new card), this runs from a send's success
   * arm with no user gesture on this new card, so stealing focus onto it would be a surprising side
   * effect of a completed send. */
  private preserveUnsentLiveText(sent: SpacesReviewComment, live: string): void {
    const id = `provisional-${++this.provisionalSequence}`;
    const now = new Date().toISOString();
    const draft: SpacesReviewComment = {
      id,
      filePath: sent.filePath,
      side: sent.side,
      lineNumber: sent.lineNumber,
      lineText: sent.lineText,
      body: "",
      createdAt: now,
      revision: 0,
    };
    this.provisionalIds.add(id);
    this.drafts = [...this.drafts, draft];
    this.liveBodies.set(id, live);
  }

  /** Serializes against any persist already in flight for this id (a prior blur that hasn't
   *  resolved yet — see `pendingPersistById`'s doc comment), then delegates to `doPersistBody`,
   *  registering *that* call's own promise before awaiting it so a `sendOne`/`deleteDraft` racing
   *  this one waits for it in turn. Resolves to whether THIS call's own persist succeeded — the
   *  `priorPersist` await above is for ordering only, so its own result is irrelevant here.
   *
   * The awaited `priorPersist` may have re-keyed a provisional id to its server-assigned id (see
   * `doPersistBody`'s `idAliases` bookkeeping) while this call was parked waiting for it — `id` is
   * re-resolved right after the await, mirroring `deleteDraft`'s own post-await re-resolve, so
   * `doPersistBody` is called (and `pendingPersistById` registered) under the CURRENT key rather
   * than the now-stale one. Without this, `doPersistBody` would look up a draft that no longer
   * exists under the original `id` and silently no-op — dropping the second blur's edit. Registers
   * under both `id` and the resolved id (like `deleteDraft`'s `preResolvedId` pair) so a
   * `sendOne`/`deleteDraft` call still holding the original id can find this run too. */
  private async persistBody(id: string, body: string): Promise<boolean> {
    const priorPersist = this.pendingPersistById.get(id);
    if (priorPersist) await priorPersist; // e.g. two blur events for the same id in quick succession
    const resolvedId = this.resolveId(id);

    const thisPersist = this.doPersistBody(resolvedId, body);
    this.pendingPersistById.set(id, thisPersist);
    if (resolvedId !== id) this.pendingPersistById.set(resolvedId, thisPersist);
    try {
      return await thisPersist;
    } finally {
      // Only clear if nothing newer has already overwritten this key's entry — a later persist (or
      // delete) for the same id may have started while this one was in flight.
      if (this.pendingPersistById.get(id) === thisPersist) this.pendingPersistById.delete(id);
      if (resolvedId !== id && this.pendingPersistById.get(resolvedId) === thisPersist) {
        this.pendingPersistById.delete(resolvedId);
      }
    }
  }

  /** First successful call for a provisional id creates the row server-side (`id` omitted) and
   *  adopts the response's server-assigned id as this draft's new key everywhere; every later call
   *  updates the existing row in place. Only ever called with a non-empty `body` (see `renderCard`'s
   *  blur handler and `sendOne`) — the daemon rejects an empty body outright.
   *
   * Returns whether the persist succeeded: `true` once `this.drafts` reflects the new body/revision,
   * `false` from the catch block below. The catch surfaces the failure via `surfaceError` (unchanged
   * — still the only place a persist failure is shown to the user) but deliberately does NOT update
   * `this.drafts`, so a caller cannot tell success from failure by inspecting the draft alone; the
   * boolean is what lets `sendBatch` distinguish the two (see its doc comment) and abort rather than
   * send a body/revision that never actually changed.
   *
   * Re-resolves `id` at entry as a second line of defense — `persistBody` already re-resolves after
   * its own await before calling in here, so this is normally a no-op, but it keeps this method
   * correct on its own for any other caller. A draft still missing after that re-resolve is
   * genuinely gone (sent or deleted while this persist was queued behind a prior one — see
   * `doDeleteDraft`'s await of `pendingPersistById`), not merely looked up under a stale alias, so
   * `true` (nothing to persist, not a failure) is the right answer. */
  private async doPersistBody(id: string, body: string): Promise<boolean> {
    const resolvedId = this.resolveId(id);
    const draft = this.drafts.find((d) => d.id === resolvedId);
    if (!draft) return true;
    const isProvisional = this.provisionalIds.has(resolvedId);
    let persisted: SpacesReviewComment;
    try {
      persisted = await this.bridge.reviewCommentUpsert({
        id: isProvisional ? undefined : resolvedId,
        filePath: draft.filePath,
        side: draft.side,
        lineNumber: draft.lineNumber,
        lineText: draft.lineText,
        body,
      });
    } catch (err) {
      this.surfaceError(err, isProvisional ? "Failed to create the comment." : "Failed to save the comment.");
      return false;
    }
    // Carry any in-progress (unsaved) text forward across this id swap. If nothing was typed since
    // this persist's blur captured `body`, the entry is just stale — drop it, since the next
    // rebuild's textarea will start from `persisted.body`, which now matches it anyway. If the user
    // kept typing during the await, that live text is newer than what was just saved, so it must
    // survive under whatever id the draft is keyed by after this (the server id, for a provisional
    // draft's first persist; the same id otherwise).
    const live = this.liveBodies.get(resolvedId);
    if (live !== undefined) {
      this.liveBodies.delete(resolvedId);
      if (live !== body) this.liveBodies.set(persisted.id, live);
    }
    if (isProvisional) {
      this.provisionalIds.delete(resolvedId);
      this.idAliases.set(resolvedId, persisted.id);
      // A focus-restore capture in flight for this id (see `pendingFocus`'s doc comment) must
      // follow the id to its new key too, or a rebuild racing this persist would fail to find the
      // card it meant to refocus.
      if (this.pendingFocus?.id === resolvedId) this.pendingFocus = { ...this.pendingFocus, id: persisted.id };
      // Batch-tray membership (see `collapsedIds`'s doc comment) must follow the id the same way —
      // otherwise a card added to the batch while still provisional would silently fall out of
      // `collapsedIds` the moment its first persist re-keys it to the server id, reappearing inline.
      if (this.collapsedIds.has(resolvedId)) {
        this.collapsedIds.delete(resolvedId);
        this.collapsedIds.add(persisted.id);
      }
    }
    this.drafts = this.drafts.map((d) => (d.id === resolvedId ? persisted : d));
    this.refresh();
    return true;
  }

  /** Deletes a draft. A still-provisional id (see the class doc comment) has never round-tripped
   *  to the daemon, so it is dropped from the local mirror only, with no `reviewCommentDelete`
   *  call. `silent` covers the blur-time auto-discard of an empty draft (see `renderCard`'s doc
   *  comment) — a failure there has no user-visible affordance to explain itself against, so it is
   *  swallowed rather than surfaced as an error banner.
   *
   * Awaits any persist already in flight for `id` first, then re-resolves `id` through
   * `resolveId` before deciding provisional-vs-real: without this, a Delete click racing a
   * still-unresolved blur `persistBody` call (blur fires before click — see the class doc comment)
   * could drop the local-only entry while that persist goes on to create a server row nothing ever
   * deletes — an orphan that reappears on the next reload.
   *
   * Fix 2 note: a failed prior persist (see `pendingPersistById`'s await above) never flips
   * `provisionalIds`/re-keys via `idAliases` (`doPersistBody`'s catch returns before any of that),
   * so the provisional-vs-persisted branch below is exactly the same branch it would have taken had
   * no persist ever been attempted — correct either way, so this stays a plain await with no check
   * of the persist's own success/failure.
   *
   * This whole call is registered in `pendingDeleteById` (see its doc comment) synchronously, at
   * the top of this method, before any `await` — so a `sendBatch` call arriving immediately after
   * this one is invoked can see it and wait for it. Registration uses a *synchronous*, pre-persist
   * `resolveId(id)` lookup (safe: `resolveId` is a plain map read with no await) purely to decide
   * which map key(s) to publish this run under; the real re-resolve used by the delete logic itself
   * happens again inside `doDeleteDraft`, after awaiting the pending persist, since that persist
   * could re-key `id` between now and then.
   *
   * round-16 Fix 3: coalesces concurrent deletes for the same draft instead of unconditionally
   * starting a new run. Emptying a persisted comment's textarea and clicking Delete fires blur's
   * silent auto-discard delete first, then the click's own (non-silent) delete, both for the same
   * row — `pendingDeleteById` already tracks in-flight deletes for `sendBatch` to await, but
   * `doDeleteDraft` itself never checked it, so both calls would independently issue
   * `reviewCommentDelete` for the same id: the first wins, the second gets `notFound` and, being
   * non-silent, surfaces a spurious "Failed to delete the comment." banner plus a pointless
   * reconcile. Returning the already-registered run instead fixes that. Accepted asymmetry: the
   * coalesced click inherits the earlier (blur) run's `silent` flag, so a blur-discard's failure
   * stays bannerless even though the user also clicked Delete — `reconcileMirrorAfterRejection`
   * still converges the mirror either way, and the failure case itself is rare-of-rare. Keyed on the
   * same id only: a second, unrelated card's delete has its own id/preResolvedId pair and starts its
   * own run as usual.
   */
  private async deleteDraft(id: string, silent: boolean): Promise<void> {
    const preResolvedId = this.resolveId(id);
    const existing = this.pendingDeleteById.get(id) ?? this.pendingDeleteById.get(preResolvedId);
    if (existing) return existing;
    const run = this.doDeleteDraft(id, silent);
    this.pendingDeleteById.set(id, run);
    if (preResolvedId !== id) this.pendingDeleteById.set(preResolvedId, run);
    try {
      await run;
    } finally {
      // Only clear if nothing newer has already overwritten this key's entry — a later delete (or
      // persist) for the same id may have started while this one was in flight.
      if (this.pendingDeleteById.get(id) === run) this.pendingDeleteById.delete(id);
      if (preResolvedId !== id && this.pendingDeleteById.get(preResolvedId) === run) {
        this.pendingDeleteById.delete(preResolvedId);
      }
    }
  }

  private async doDeleteDraft(id: string, silent: boolean): Promise<void> {
    const pending = this.pendingPersistById.get(id);
    if (pending) await pending;
    const resolvedId = this.resolveId(id);

    if (this.provisionalIds.has(resolvedId)) {
      this.provisionalIds.delete(resolvedId);
      this.drafts = this.drafts.filter((d) => d.id !== resolvedId);
      this.collapsedIds.delete(resolvedId);
      this.forgetDraftState(id, resolvedId);
      this.refresh();
      return;
    }
    try {
      await this.bridge.reviewCommentDelete(resolvedId);
    } catch (err) {
      // round-16 Fix 2: reconciles through the same typed-rejection rule `handleSendFailure` uses
      // (see its doc comment) rather than routing through `handleSendFailure` itself, since that
      // would unconditionally call `surfaceError` — breaking `silent`'s no-banner contract above.
      if (!silent) this.surfaceError(err, "Failed to delete the comment.");
      await this.reconcileMirrorAfterRejection(err);
      this.refresh();
      return;
    }
    this.drafts = this.drafts.filter((d) => d.id !== resolvedId);
    this.collapsedIds.delete(resolvedId);
    this.forgetDraftState(id, resolvedId);
    // Fix 4 (round-2) / round-2b: a `loadInitial` or `reconcileMirrorAfterRejection` response already
    // dispatched before this delete completed still carries this row — tombstone it so that response
    // doesn't resurrect it as a ghost card.
    if (this.listCallsInFlight > 0) this.removedWhileListInFlight.add(resolvedId);
    this.refresh();
  }

  /** Public entry point for a card's "Send" button — see `sendInFlight`'s doc comment for why this
   *  only waits for/publishes into the shared marker rather than doing any send work itself.
   *  `doSendOne` (below) is the unchanged original body.
   *
   * Fix 3 (round-2 P1): the agent shown on this card's Send button is captured HERE, before the
   * `sendInFlight` wait — see `doSendOne`'s doc comment below for the full rationale. A selection
   * change (dropdown pick, or an agents-update auto-selecting a different agent) during the queued
   * wait — which can span the full duration of another in-flight send — or during `doSendOne`'s own
   * pending-persist await must not reroute this comment to a different agent's terminal. */
  private async sendOne(id: string, body: string): Promise<void> {
    const agent = this.agents.find((a) => a.id === this.selectedAgentId);
    if (!agent) return;
    while (this.sendInFlight) await this.sendInFlight;
    const run = this.doSendOne(id, body, agent);
    const published = run.finally(() => {
      // Only clear our own marker — a queued sender that started after us must not have its marker
      // wiped by our finally.
      if (this.sendInFlight === published) this.sendInFlight = undefined;
    });
    this.sendInFlight = published;
    await run;
  }

  /** `body` is read live from the card's textarea at click time (not the last-persisted value),
   *  so clicking Send immediately after typing — before the textarea has had a chance to blur —
   *  still sends exactly what is on screen, persisting it first (creating it, if the card is still
   *  provisional — see `persistBody`).
   *
   * Awaits any persist already in flight for `id` first, then re-resolves `id` through
   * `resolveId` — a Send click races a still-unresolved blur `persistBody` call the same way
   * `deleteDraft` does (see its doc comment): without the await+re-resolve, this could still see
   * the draft as provisional after the blur has already created it server-side, and issue a second
   * `reviewCommentUpsert` with `id: undefined` — a duplicate row for one comment. If, after
   * resolving, the draft already holds exactly this `body` (the blur we just waited on already
   * saved it), this skips issuing a second upsert entirely rather than doing a redundant round trip.
   *
   * Fix 1 note: the pending-persist await above is a plain await, not a check of its boolean result
   * (unlike `sendBatch`) — that is safe here because a failed prior persist never updates
   * `draft.body` (see `doPersistBody`'s catch), so `draft.body` stays unequal to whatever `body`
   * this call was handed, and the `!isProvisional && draft.body === body` fast path just below can
   * never incorrectly fire. `sendOne` therefore always re-issues its own upsert with the live `body`
   * it was given, self-healing the failed save.
   *
   * Fix 3 (round-2 P1): `agent` is captured by the caller (`sendOne`, above) at the very top of the
   * PUBLIC entry point — before both the `sendInFlight` wait and the pending-persist await below —
   * not re-resolved from `this.selectedAgentId` after either of them, the way it used to be. The
   * click targeted the agent shown on the card's Send button at click time; `selectedAgentId` can
   * change during either await (a dropdown pick, or an agents-update auto-selecting a different
   * agent — see `onAgentsChanged`), and resolving it after either would silently reroute the comment
   * into whatever agent happens to be selected by the time the send actually runs, not the one the
   * user actually clicked "Send to". If the captured agent's session has ended by send time, the
   * `reviewCommentsSend` call below fails loudly through the existing failure path — preferable to
   * silently delivering into a different agent's terminal. Capturing at the public entry point widens
   * the window this covers to the full queued-wait duration (a send parked behind another in-flight
   * send can wait many seconds), which is still accepted behavior, not a new concern — it is the same
   * "session ended by send time" gap, just possibly longer.
   */
  private async doSendOne(id: string, body: string, agent: CodePaneAgentSummary): Promise<void> {
    const pending = this.pendingPersistById.get(id);
    if (pending) await pending;
    const resolvedId = this.resolveId(id);

    const draft = this.drafts.find((d) => d.id === resolvedId);
    if (!draft) return;
    if (body.trim().length === 0) {
      // Mirrors the blur-time rule: an emptied-out (or still-provisional, never-typed-into) draft
      // is discarded, never sent.
      void this.deleteDraft(resolvedId, true);
      return;
    }
    const isProvisional = this.provisionalIds.has(resolvedId);
    let persisted: SpacesReviewComment;
    if (!isProvisional && draft.body === body) {
      persisted = draft;
    } else {
      try {
        persisted = await this.bridge.reviewCommentUpsert({
          id: isProvisional ? undefined : resolvedId,
          filePath: draft.filePath,
          side: draft.side,
          lineNumber: draft.lineNumber,
          lineText: draft.lineText,
          body,
        });
      } catch (err) {
        this.surfaceError(err, isProvisional ? "Failed to create the comment." : "Failed to save the comment.");
        return; // the draft stays exactly as it was — no optimistic removal before this resolves
      }
      // The upsert above already landed server-side, so fold it into the local mirror before
      // attempting the send below — a send failure must not leave this draft pointing at a stale
      // provisional id, which would otherwise create a duplicate row on a retried send.
      if (isProvisional) {
        this.provisionalIds.delete(resolvedId);
        this.idAliases.set(resolvedId, persisted.id);
      }
      this.drafts = this.drafts.map((d) => (d.id === resolvedId ? persisted : d));
      // Fix 2 (P2): mirrors `doPersistBody`'s re-key block above (see its comments there for the
      // drop-if-live-equals-persisted-body rule and the `pendingFocus` migration rationale) — this
      // upsert re-keys the draft the same way a `persistBody` call would, so the card's live text and
      // any pending focus-restore must follow the id the same way, or they silently fall out of sync.
      // Named `liveAtSwap` (not `live`) to avoid colliding with the separate `live` lookup a few lines
      // below, in the send success arm, which runs after this and reads a different, later snapshot.
      const liveAtSwap = this.liveBodies.get(resolvedId);
      if (liveAtSwap !== undefined) {
        this.liveBodies.delete(resolvedId);
        if (liveAtSwap !== body) this.liveBodies.set(persisted.id, liveAtSwap);
      }
      if (this.pendingFocus?.id === resolvedId) this.pendingFocus = { ...this.pendingFocus, id: persisted.id };
      // Unlike `doPersistBody`, `collapsedIds` is deliberately NOT transferred here: this path is
      // reached only via a card's inline Send button, and a collapsed (batch-tray) card has no inline
      // Send button, so `collapsedIds` membership can never be relevant to a draft reaching this code.
      // `this.refresh()` must run BEFORE the `reviewCommentsSend` await below (not after): any
      // keystroke typed during that await lands in `liveBodies` under the id the DOM card is actually
      // keyed by, which only matches `persisted.id` once this rebuild has run. This is what the
      // success arm's 3-key lookup chain (`this.liveBodies.get(persisted.id) ?? ...`, a few lines
      // below) and the failure path's later rebuild both expect to find.
      this.refresh();
    }
    const anchored = reanchorComments([persisted], this.files);
    try {
      await this.bridge.reviewCommentsSend(agent.sessionId, formatReviewCommentsText(anchored), [
        { id: persisted.id, revision: persisted.revision },
      ]);
    } catch (err) {
      // Reflects the persisted id/body above even though the send itself failed; see
      // `handleSendFailure` for the additional re-fetch a stale-`revision` conflict triggers.
      await this.handleSendFailure(err, "Failed to send the comment.");
      return;
    }
    // Fix 1 (P2): captured BEFORE the removal/forget below, under every key this draft's live text
    // could still be sitting under — see `preserveUnsentLiveText`'s doc comment for why a surviving
    // entry here is unsent typing, not stale bookkeeping.
    const live = this.liveBodies.get(persisted.id) ?? this.liveBodies.get(resolvedId) ?? this.liveBodies.get(id);
    this.drafts = this.drafts.filter((d) => d.id !== persisted.id);
    this.collapsedIds.delete(persisted.id);
    this.forgetDraftState(id, resolvedId, persisted.id);
    // Fix 4 (round-2) / round-2b: see `doDeleteDraft`'s identical guard — a `loadInitial` or
    // `reconcileMirrorAfterRejection` response already dispatched before this send completed still
    // carries this row.
    if (this.listCallsInFlight > 0) this.removedWhileListInFlight.add(persisted.id);
    // `body` is the exact text this send delivered — a live entry equal to it means the user retyped
    // the same thing (or typed nothing new since the click), so there is nothing to preserve.
    if (live !== undefined && live !== body && live.trim().length > 0) this.preserveUnsentLiveText(persisted, live);
    this.refresh();
  }

  /**
   * Async click handler for a card's "Add to batch" button — mirrors `sendOne`/`deleteDraft`'s
   * coordination pattern (await any persist already in flight, then re-resolve the id) instead of
   * synchronously collapsing the card: a still-provisional card's first blur persist may still be
   * in flight when this is clicked (blur fires before click — see the class doc comment), and
   * collapsing under the pre-persist provisional id would leave `collapsedIds` holding a key that
   * `doPersistBody`'s re-key block (see its transfer of `collapsedIds` alongside `idAliases`) would
   * otherwise have to guess at.
   *
   * `body` is read live from the card's textarea at click time, mirroring `sendOne`'s empty-body
   * gate: a still-provisional (never-typed-into) card has nothing to batch.
   */
  private async addToBatch(id: string, body: string): Promise<void> {
    if (body.trim().length === 0) return;
    const pending = this.pendingPersistById.get(id);
    if (pending) await pending;
    const resolvedId = this.resolveId(id);

    const draft = this.drafts.find((d) => d.id === resolvedId);
    if (!draft) return; // deleted concurrently while this awaited the persist above

    // `persistBody`/`doPersistBody` swallow their own errors (surfacing a banner) rather than
    // rejecting, so the await above resolves the same way whether the persist succeeded or failed.
    // Detect a failed *create* persist here: a draft that is still provisional with an empty stored
    // body never actually round-tripped (see `createDraft`'s `body: ""` placeholder, only ever
    // overwritten by a successful `doPersistBody`). Collapsing such a card into the tray would hide
    // it behind a tray that only lists sendable (non-empty-body) drafts, with no way to bring it
    // back — leave it rendered inline instead, so the user still sees the error banner
    // `persistBody`'s failure path already surfaced.
    if (this.provisionalIds.has(resolvedId) && draft.body.trim().length === 0) return;

    this.collapsedIds.add(resolvedId);
    this.refresh();
  }

  private anchoredAll(): AnchoredComment[] {
    return reanchorComments(this.drafts, this.files);
  }

  /** Captures the currently focused comment card's id and caret/selection, if any, into
   *  `pendingFocus` right before a wholesale `setComments` rebuild — see `pendingFocus`'s doc
   *  comment for why this exists. Only overwrites `pendingFocus` when a comment card's textarea is
   *  actually focused right now; otherwise leaves it alone (e.g. `createDraft`'s just-set capture
   *  for a brand-new card that has no DOM yet to be "focused" in). */
  private captureFocusedCard(): void {
    const active = document.activeElement;
    if (!(active instanceof HTMLTextAreaElement)) return;
    const id = active.dataset.commentId;
    if (id === undefined) return;
    this.pendingFocus = {
      id,
      selectionStart: active.selectionStart ?? undefined,
      selectionEnd: active.selectionEnd ?? undefined,
    };
  }

  /** Re-anchors, re-renders the tray, and pushes the toolbar state — the full pipeline, run after
   *  any change to `drafts`, `files`, or `collapsedIds`. */
  private refresh(): void {
    this.captureFocusedCard();
    const anchored = this.anchoredAll();
    const visible = anchored.filter((ac) => !this.collapsedIds.has(ac.comment.id));
    this.diffView?.setComments(visible);
    this.renderTray(anchored);
    this.pushToolbarState();
  }

  /** Cheaper path for a change that only affects card rendering (agent selection/list), not the
   *  draft set or anchoring itself — still needs the cards re-rendered (their Send button's label
   *  and disabled state depend on the selected agent), but the tray rows don't. */
  private refreshCardsOnly(): void {
    this.captureFocusedCard();
    const anchored = this.anchoredAll();
    const visible = anchored.filter((ac) => !this.collapsedIds.has(ac.comment.id));
    this.diffView?.setComments(visible);
  }

  private pushToolbarState(): void {
    const draftCount = this.drafts.filter((d) => d.body.trim().length > 0).length;
    this.onToolbarStateChange({ agents: [...this.agents], selectedAgentId: this.selectedAgentId, draftCount });
  }

  private renderCard(anchored: AnchoredComment): HTMLElement {
    const comment = anchored.comment;
    const card = document.createElement("div");
    card.className = "comment-card";
    if (anchored.position?.outdated) {
      card.classList.add("outdated");
    }

    const textarea = document.createElement("textarea");
    textarea.className = "comment-card-body";
    // Used by `captureFocusedCard` to map a focused DOM element back to its draft id across a
    // wholesale rebuild (`@pierre/diffs` creates fresh DOM nodes every `setComments` call).
    textarea.dataset.commentId = comment.id;
    // Prefer any live, not-yet-persisted text over the last-*persisted* value — see `liveBodies`'s
    // doc comment. Without this, a wholesale rebuild (a live diff refresh while the user is mid-
    // comment) would silently revert the textarea to stale content, since DOM removal fires no
    // `blur` to save what was actually typed.
    textarea.value = this.liveBodies.get(comment.id) ?? comment.body;
    textarea.placeholder = "Leave a comment…";
    let lastSavedBody = comment.body;
    textarea.addEventListener("input", () => {
      // Bridges the gap a wholesale rebuild opens up: removing a focused element from the DOM
      // fires no `blur`, so without tracking every keystroke here, anything typed since the last
      // blur would be silently lost the moment `@pierre/diffs` re-renders (see `liveBodies`).
      this.liveBodies.set(comment.id, textarea.value);
    });
    // Blur-only persistence, deliberately with no debounce timer at all (stricter than
    // editorView.ts's ~500ms debounce for editor buffer edits): a comment body is short and the
    // save is not latency-sensitive the way a file buffer is, so there is no reason to accept the
    // added complexity of a partial-typing race window here.
    textarea.addEventListener("blur", () => {
      const body = textarea.value;
      if (body.trim().length === 0) {
        // A draft opened but never typed into (or emptied back out) must never persist or appear
        // as a real batchable item — discard it silently rather than leaving an empty comment.
        void this.deleteDraft(comment.id, true);
        return;
      }
      if (body === lastSavedBody) return;
      lastSavedBody = body;
      void this.persistBody(comment.id, body);
    });
    card.appendChild(textarea);

    const actions = document.createElement("div");
    actions.className = "comment-card-actions";

    const agent = this.agents.find((a) => a.id === this.selectedAgentId);
    const sendBtn = document.createElement("button");
    sendBtn.type = "button";
    sendBtn.className = "btn primary";
    sendBtn.textContent = agent ? `Send to ${agent.label}` : "Send";
    const disabledReason =
      this.agents.length === 0
        ? "No agent is running in this workspace."
        : agent === undefined
          ? "Pick an agent to send to."
          : undefined;
    if (disabledReason !== undefined) {
      sendBtn.disabled = true;
      sendBtn.title = disabledReason;
    }
    sendBtn.addEventListener("click", () => void this.sendOne(comment.id, textarea.value));
    actions.appendChild(sendBtn);

    const batchBtn = document.createElement("button");
    batchBtn.type = "button";
    batchBtn.className = "btn";
    batchBtn.textContent = "Add to batch";
    batchBtn.addEventListener("click", () => void this.addToBatch(comment.id, textarea.value));
    actions.appendChild(batchBtn);

    const deleteBtn = document.createElement("button");
    deleteBtn.type = "button";
    deleteBtn.className = "btn";
    deleteBtn.textContent = "Delete";
    deleteBtn.addEventListener("click", () => void this.deleteDraft(comment.id, false));
    actions.appendChild(deleteBtn);

    card.appendChild(actions);

    if (comment.id === this.pendingFocus?.id) {
      const focus = this.pendingFocus;
      this.pendingFocus = undefined;
      // Deferred a tick: `@pierre/diffs` inserts this returned element into the DOM as part of the
      // same render pass that invoked renderAnnotation, so focusing synchronously here can race
      // that insertion.
      setTimeout(() => {
        textarea.focus();
        if (focus.selectionStart !== undefined && focus.selectionEnd !== undefined) {
          textarea.setSelectionRange(focus.selectionStart, focus.selectionEnd);
        }
      }, 0);
    }

    return card;
  }

  private renderTray(anchored: readonly AnchoredComment[]): void {
    const sendable = anchored.filter((ac) => ac.comment.body.trim().length > 0);
    this.tray.style.display = sendable.length === 0 ? "none" : "flex";
    this.trayCount.textContent = String(sendable.length);

    this.trayList.replaceChildren();
    for (const ac of sendable) {
      const row = document.createElement("div");
      row.className = "comment-tray-row";
      row.addEventListener("click", () => {
        this.collapsedIds.delete(ac.comment.id);
        this.refresh();
        const position = ac.position;
        if (this.diffView) {
          if (position && !position.outdated) {
            this.diffView.scrollToLine(ac.comment.filePath, ac.comment.side, position.lineNumber);
          } else {
            this.diffView.scrollToFile(ac.comment.filePath);
          }
        }
      });

      const loc = document.createElement("span");
      loc.className = "comment-tray-loc";
      loc.textContent = `${ac.comment.filePath}:${anchoredLineNumber(ac)}`;
      row.appendChild(loc);

      const excerpt = document.createElement("span");
      excerpt.className = "comment-tray-excerpt";
      excerpt.textContent = ac.comment.body;
      row.appendChild(excerpt);

      const removeBtn = document.createElement("button");
      removeBtn.type = "button";
      removeBtn.className = "comment-tray-remove";
      removeBtn.textContent = "×";
      removeBtn.title = "Remove comment";
      removeBtn.addEventListener("click", (event) => {
        event.stopPropagation(); // don't also trigger the row's own scroll-to-line click
        void this.deleteDraft(ac.comment.id, false);
      });
      row.appendChild(removeBtn);

      this.trayList.appendChild(row);
    }
  }

  private updateTrayExpansion(): void {
    this.trayList.style.display = this.trayExpanded ? "flex" : "none";
    this.trayCaret.textContent = this.trayExpanded ? "▾" : "▸";
  }

  /**
   * round-16 Fix 2: re-fetches every draft from the daemon whenever a mutation was rejected with one
   * of exactly three codes that each *prove* this controller's local mirror of the comment(s)
   * involved is stale: `conflict` means the `revision` this client last saw is behind the daemon's;
   * `invalidArgument`/`notFound` mean the comment was already sent, deleted, or never existed the
   * way this mirror thinks it does.
   *
   * Every other rejection skips the re-fetch, leaving the tray/draft list exactly as it was — this
   * includes a rejection that isn't a `SpacesBridgeError` at all (a transport-shaped failure) *and*
   * a `SpacesBridgeError` whose code is `internalError` or `unavailable`. Those two codes are
   * transient/ambiguous-outcome failures (a daemon hiccup, an agent momentarily unreachable, a
   * client mid-reconnect) rather than proof of anything: `realBridge.ts`'s `post()` wraps every
   * rejection the real bridge can ever produce — including the "handler not installed" transport
   * case — into a `SpacesBridgeError`, so `instanceof SpacesBridgeError` alone does not distinguish
   * a proven-stale mutation from a merely-failed-to-reach-anything one. Re-fetching on those would
   * churn the mirror (and any in-progress edit) for a failure that says nothing about whether some
   * other surface actually touched this comment.
   *
   * The re-fetch itself is best-effort: a failure there is swallowed, since the triggering failure
   * is already surfaced (or, for a silent `deleteDraft`, deliberately not) and the next successful
   * `loadInitial`/mutation will reconcile the mirror anyway.
   *
   * Fix 3: the relist response is *merged* into `this.drafts`, but with a narrower keep-rule than
   * `loadInitial`'s merge (see its doc comment for the cross-reference) — do NOT reuse that rule
   * here. `loadInitial` keeps every currently-held local draft absent from its response, because its
   * caller has no reason to believe any of them is stale. This method's caller just received proof
   * of the opposite: the rejection that triggered this call means the daemon and this client's
   * mirror disagree about at least one comment. Keeping every absent local row here would resurrect
   * the exact stale row this relist exists to remove (e.g. an already-sent-or-deleted-elsewhere row
   * a rejected retry just proved stale), turning every retry into an infinite loop that fails the
   * same way forever (see round-10 Fix 2).
   *
   * An absent local row is kept ONLY if the daemon could not possibly know about it yet: still
   * provisional (never round-tripped — see the class doc comment), or with a persist/create actually
   * in flight right now (`pendingPersistById`, checked under both the row's stored id and its
   * `resolveId`-resolved id, since either might be the key a concurrent `persistBody` registered
   * under). Every other absent row is real staleness and must be dropped.
   *
   * This keep-rule is sufficient because both the rejected mutation and this relist run through the
   * daemon's serial `reviewCommentQueue` (see docs/implementation.md / SpacesDeviceAPIServer.swift),
   * and this relist is only issued *after* the rejection has already arrived. Any create that
   * settled server-side before the relist was issued is therefore already present in the relist's
   * own response; the only real gap left to cover is a create still in flight at the moment of the
   * relist, which the `pendingPersistById` check above catches.
   *
   * Implemented inline rather than sharing a helper with `loadInitial`'s merge: two call sites with
   * different keep-predicates isn't worth a parameterized abstraction, and inlining keeps each
   * site's doc comment next to the rule it actually applies.
   *
   * round-2b: before applying the keep-rule above, the response itself is filtered against
   * `removedWhileListInFlight` the same way `loadInitial`'s response is — see that set's doc comment
   * and `listCallsInFlight`'s for why this relist needs its own tombstone guard: this method's own
   * `reviewCommentList` call is just as much a stale snapshot, racing a concurrent unrelated
   * send/delete, as `loadInitial`'s is.
   */
  private async reconcileMirrorAfterRejection(err: unknown): Promise<void> {
    if (
      !(err instanceof SpacesBridgeError) ||
      (err.code !== "conflict" && err.code !== "invalidArgument" && err.code !== "notFound")
    ) {
      return;
    }
    this.listCallsInFlight += 1;
    let response: SpacesReviewComment[];
    try {
      response = await this.bridge.reviewCommentList();
    } catch {
      // Decrement only — never clear `removedWhileListInFlight` here: this relist consumed no
      // response, so any tombstone recorded during its window is still owed to whichever call next
      // actually applies a response (an overlapping `loadInitial`, or a later reconcile) — see
      // `removedWhileListInFlight`'s doc comment. The failure itself is swallowed — see doc comment
      // above.
      this.listCallsInFlight -= 1;
      return;
    }
    // round-2b: drop any response row a send/delete already removed locally while this relist — or
    // an overlapping `loadInitial` — was in flight (see `removedWhileListInFlight`'s doc comment)
    // before applying this method's own keep-rule below (kept exactly as it was — only the
    // response-side filter is new here). Tombstones are cleared only once `listCallsInFlight` has
    // returned to zero after THIS call's own decrement: an overlapping `loadInitial` still in flight
    // needs the same tombstones for its own equally-stale response.
    const survivingResponse = response.filter((d) => !this.removedWhileListInFlight.has(d.id));
    this.listCallsInFlight -= 1;
    if (this.listCallsInFlight === 0) this.removedWhileListInFlight.clear();
    const responseIds = new Set(survivingResponse.map((d) => d.id));
    const stillRelevantLocalOnly = this.drafts.filter((d) => {
      const resolvedId = this.resolveId(d.id);
      if (responseIds.has(resolvedId)) return false; // response rows win, same as loadInitial
      return (
        this.provisionalIds.has(resolvedId) ||
        this.pendingPersistById.has(resolvedId) ||
        this.pendingPersistById.has(d.id)
      );
    });
    this.drafts = [...survivingResponse, ...stillRelevantLocalOnly];
  }

  /** Common failure path for both `sendOne` and `sendBatch`: surfaces the error, then reconciles
   *  the local mirror via `reconcileMirrorAfterRejection` before re-rendering. */
  private async handleSendFailure(err: unknown, fallback: string): Promise<void> {
    this.surfaceError(err, fallback);
    await this.reconcileMirrorAfterRejection(err);
    this.refresh();
  }

  private surfaceError(err: unknown, fallback: string): void {
    const message = err instanceof SpacesBridgeError ? err.message : fallback;
    this.banner.textContent = message;
    this.banner.style.display = "flex";
    clearTimeout(this.bannerTimer);
    this.bannerTimer = setTimeout(() => {
      this.banner.style.display = "none";
    }, BANNER_TIMEOUT_MS);
  }
}
