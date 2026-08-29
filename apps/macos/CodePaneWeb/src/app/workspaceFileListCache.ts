import { SpacesBridge, WorkspaceFileListResult } from "../bridge/types";

/**
 * Shared in-memory cache for `workspaceFileList`, the source of both Editor mode's Files tree
 * (`editorSidebar.ts`) and the ⌘P quick-open overlay (`quickOpen.ts`) — both need the same full
 * workspace listing, and neither owns it exclusively (the overlay works in Diff mode too, where
 * there is no Files tree instance around to hold it). Fetches lazily on first `get()`/`getFresh()`,
 * not at construction: a pane that never opens the overlay or switches to the Files tab never pays
 * for the listing at all.
 *
 * `root.ts` owns the one instance for a pane and calls `invalidate()` from the dedicated
 * workspace-level `spaces:fileListSignature` push, so files added or removed by an agent (or any
 * other outside change) reappear without a manual refresh even when the active diff scope would not
 * change. `getFresh()` exists for the first show of Files/⌘P before that stream has ever fired — see
 * its own doc comment.
 *
 * Invariant: at most one `workspaceFileList` bridge call is outstanding at a time, across `get()`
 * and `getFresh()` combined (`inFlight`). `workspaceFileList` runs on the daemon's per-workspace
 * SERIAL git queue — the same queue file reads, saves, and diffs share — so a second request issued
 * while one is already in flight can never come back with fresher data sooner than chaining it
 * after the first one settles; it only stacks extra load (up to a 50,000-path scan) onto a queue
 * every other request is also waiting behind. `invalidate()` therefore never itself starts a
 * request: while one is in flight it only records that its result is stale and a fresh one is owed
 * (`trailing`). Any number of `invalidate()`, `get()`, and `getFresh()` calls arriving during that
 * one flight share the same `trailing` promise and collapse into exactly one bridge call, fired the
 * instant the in-flight request settles (success or failure) — never one per caller or per
 * invalidation.
 *
 * Cross-consumer stale paint: each consumer keeps its own local copy of the last listing it
 * rendered (quickOpen's `cachedPaths`, editorSidebar's `this.paths`) and paints it synchronously at
 * show time, before `getFresh()`'s revalidation resolves. That works fine for a consumer reopening
 * itself, but leaves a consumer that has never rendered before blank even when the OTHER consumer
 * already populated this cache — e.g. ⌘P in Diff mode fetches a listing, then the Files tab's first
 * show has nothing of its own to paint and sits empty until its own revalidation completes. `
 * snapshot()` exists so a consumer can seed its local copy from whatever the cache last fetched,
 * regardless of which consumer triggered that fetch, before painting.
 */
export class WorkspaceFileListCache {
  /** The last successfully fetched (and not since invalidated) listing. Doubles as "has a value ever
   *  been obtained": both this and a successful fetch's write-back happen in the same step, and
   *  `invalidate()` always clears it, so `get()`/`getFresh()` branch on its presence directly instead
   *  of tracking that fact separately. */
  private cached: Promise<WorkspaceFileListResult> | undefined;
  /** The single outstanding bridge call, if any — shared by `get()` and `getFresh()` so the
   *  "at most one request in flight" invariant holds regardless of which entry point started it. */
  private inFlight: Promise<WorkspaceFileListResult> | undefined;
  /** Set while a request is in flight AND at least one `invalidate()`/`get()`/`getFresh()` call has
   *  arrived that request's result cannot satisfy. Consumed the instant `inFlight` settles: exactly
   *  one trailing request starts then, however many calls set this flag while waiting.
   *  `undefined` means no trailing request is owed. */
  private trailing: Promise<WorkspaceFileListResult> | undefined;
  /** Bumped by `invalidate()`. A request started before the bump checks this on completion and skips
   *  writing `cached` if it no longer matches — otherwise a listing requested before the invalidation
   *  event could land in the cache after it, masking whatever change the invalidation was meant to
   *  surface. The `trailing` mechanism above guarantees a fresh request eventually runs regardless;
   *  this guard only stops the STALE one's own result from being served as current in the window
   *  before that fresh request lands. */
  private generation = 0;
  /** The most recently successfully fetched listing, regardless of invalidation — unlike `cached`,
   *  never cleared by `invalidate()` and never generation-guarded: a generation-stale result is
   *  still newer than whatever this held before, and the trailing fetch `invalidate()` schedules
   *  refreshes it again moments later. Backs `snapshot()`. */
  private lastResult: WorkspaceFileListResult | undefined;

  constructor(private readonly bridge: Pick<SpacesBridge, "workspaceFileList">) {}

  /** The most recent successfully fetched listing, regardless of invalidation — for a consumer to
   *  paint stale data instantly (before its own `getFresh()` call resolves) even when it has never
   *  fetched a listing itself, as long as some other consumer of this shared cache has. Stale-while-
   *  revalidate means the pre-invalidation listing is still worth showing until the refetch lands, so
   *  this is never cleared by `invalidate()` the way `cached` is. `undefined` only before the very
   *  first successful fetch this cache instance has ever made. */
  snapshot(): WorkspaceFileListResult | undefined {
    return this.lastResult;
  }

  /** Returns the cached listing, fetching lazily on first call. Concurrent callers before the
   *  first fetch resolves share the same in-flight request. A failed fetch is not cached — the
   *  next `get()` call retries rather than latching a permanent failure. */
  get(): Promise<WorkspaceFileListResult> {
    if (this.cached) return this.cached;
    // No value cached: a request already in flight can be handed straight back UNLESS it's already
    // known stale (`trailing` set) — in that case its result is not this caller's answer, so join
    // the trailing request below instead of the doomed one.
    if (this.inFlight && !this.trailing) return this.inFlight;
    return this.queueFetch();
  }

  /** Stale-while-revalidate entry point for the two "show" points where the listing must be correct
   *  even though nothing pushed an invalidation: the ⌘P overlay opening, and the Files tab becoming
   *  visible (tab switch or `reattach()`). Both moments matter because the workspace-level
   *  `spaces:fileListSignature` stream only starts after the first successful `workspaceFileList`
   *  pull, so a pane's first visible consumer still has to revalidate on demand.
   *
   *  With nothing cached yet, this is just `get()` — there's no stale value to keep serving while a
   *  fetch is outstanding. With a cached value already in hand, it returns (and dedupes) a background
   *  refetch's promise while leaving `get()`'s own cached value — and so every other current reader —
   *  untouched until that refetch actually resolves; callers keep rendering whatever they last had
   *  and re-render when this promise settles. A failed revalidation leaves the previous cached value
   *  in place rather than clobbering good data with a transient failure. */
  getFresh(): Promise<WorkspaceFileListResult> {
    if (!this.cached) return this.get();
    if (this.inFlight && !this.trailing) return this.inFlight;
    return this.queueFetch();
  }

  /** Marks the cached listing stale so the next `get()`/`getFresh()` sees fresh data. Does NOT itself
   *  start a bridge call: per this class's doc comment, a request fired while another is already in
   *  flight can't finish any sooner than one chained after it, so an invalidation during a flight
   *  only records that a trailing refetch is owed (via `queueFetch`) once that flight settles,
   *  instead of adding a second request to the serial queue. With nothing in flight, this is just the
   *  drop-and-bump: the next call starts a genuinely new request on its own.
   *
   *  The trailing refetch this schedules may end up with no consumer — e.g. the ⌘P overlay closes
   *  and the pane is in Diff mode, so nothing ever calls `get()`/`getFresh()` again to join it — so
   *  its rejection is absorbed right here with a no-op handler. This does not swallow rejections for
   *  actual callers: a `get()`/`getFresh()` call that joins the same `trailing` promise gets back
   *  that identical promise and attaches its own handler to it; `.catch()` below creates a separate
   *  derived promise and leaves the original (and every other holder's) rejection intact. */
  invalidate(): void {
    this.cached = undefined;
    this.generation++;
    if (this.inFlight) this.queueFetch().catch(() => {});
  }

  /** The one place either a fresh request starts or an already-owed one is joined — used by `get()`
   *  and `getFresh()` once they've determined the cache can't answer directly, and by `invalidate()`
   *  to register that a trailing request is owed without needing its return value. Idempotent within
   *  one flight: repeated calls (multiple `invalidate()`s, plus any `get()`/`getFresh()` calls in
   *  between) all get back the same `trailing` promise, which is what makes "N calls during one
   *  flight = exactly one trailing bridge call" hold. */
  private queueFetch(): Promise<WorkspaceFileListResult> {
    if (!this.inFlight) return this.startRequest();
    if (!this.trailing) {
      // Chained on the CURRENT flight, whatever it is — settling either way is what unblocks the
      // one trailing request the serial queue allows next; a request result is never discarded, so
      // both arms proceed identically.
      this.trailing = this.inFlight.then(
        () => this.startRequest(),
        () => this.startRequest(),
      );
    }
    return this.trailing;
  }

  /** Fires the single outstanding bridge call and installs its completion handling: on success (and
   *  only if no `invalidate()` has bumped `generation` since this request started), publish the
   *  result as `cached`; either way, clear `inFlight` and, if a trailing request is owed, start it —
   *  see `queueFetch`'s doc comment for why this is the only place that happens. `lastResult` is
   *  updated on every success UNCONDITIONALLY, unlike `cached` — see its own doc comment for why the
   *  generation guard doesn't apply to it. */
  private startRequest(): Promise<WorkspaceFileListResult> {
    const generation = this.generation;
    const request: Promise<WorkspaceFileListResult> = this.bridge.workspaceFileList().then(
      (result) => {
        if (this.generation === generation) this.cached = request;
        this.lastResult = result;
        this.onSettled();
        return result;
      },
      (error: unknown) => {
        this.onSettled();
        throw error;
      },
    );
    this.inFlight = request;
    return request;
  }

  /** `this.inFlight` is always exactly the request currently settling when this runs — nothing else
   *  can reassign it first, since a new request only ever starts either from `get()`/`getFresh()`
   *  finding NOTHING in flight, or from `queueFetch`'s trailing continuation, which by construction
   *  only runs after this very handler has already completed (chained on the same promise). Clearing
   *  `trailing` here (rather than inside that continuation) is what lets a later `invalidate()` — one
   *  arriving during the TRAILING request's own flight — schedule a genuinely new one instead of
   *  reusing this now-consumed slot. */
  private onSettled(): void {
    this.inFlight = undefined;
    this.trailing = undefined;
  }
}
