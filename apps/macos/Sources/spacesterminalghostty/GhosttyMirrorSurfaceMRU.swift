#if canImport(AppKit) && canImport(GhosttyKit)
    import AppKit

    /// Bounds how many terminal panes hold a live Ghostty mirror surface at once.
    ///
    /// A mirror surface costs tens of megabytes — its IOSurface buffers are sized from the pane's
    /// pixel dimensions and it holds several of them — and a pane keeps its surface for as long as
    /// the pane exists. Without a cap the app's memory grows with every tab that has ever been
    /// displayed. This registry orders panes by when they were last displayed and frees the
    /// surfaces of hidden panes beyond the cap; a freed pane repaints from its retained frame the
    /// next time it is shown.
    ///
    /// The cap is process-wide rather than per window or per panel because the memory it bounds is
    /// process-wide: several windows each keeping their own quota of warm surfaces would defeat it.
    @MainActor final class GhosttyMirrorSurfaceMRU {
        static let shared = GhosttyMirrorSurfaceMRU()

        /// The live-surface total the sweep aims for. Displayed panes always stay live even beyond
        /// it, so the effective total is `max(warmSurfaceLimit, displayed panes)` and a hidden pane
        /// keeps its surface only while fewer panes than this are on screen.
        ///
        /// Each warm surface holds roughly 98 MB of IOSurface buffers, while a cold revisit rebuilds
        /// in 5–8 ms with zero blank frames and no network round trip, so switching tabs deliberately
        /// evicts the pane that just left the screen instead of keeping it warm. The slot earns its
        /// keep when no pane is displayed at all: hiding the window leaves the most recent pane's
        /// surface alive, so summoning the window back skips even the rebuild. Eviction resets
        /// mirror-local state — an open find overlay and any selection — which is accepted; scroll
        /// position and content are host-authoritative and survive.
        static let warmSurfaceLimit = 1

        private struct Entry { weak var view: GhosttyMirrorTerminalView? }

        /// Panes that may hold a live mirror surface, most recently displayed first.
        private var entries: [Entry] = []
        private var isSweepScheduled = false

        private init() {}

        /// Records `view` as the most recently displayed pane. Called whenever the view becomes
        /// displayed, whether or not it holds a mirror at that moment: any mirror it builds while
        /// displayed belongs to this position in the order.
        func noteDisplayed(_ view: GhosttyMirrorTerminalView) {
            entries.removeAll { $0.view == nil || $0.view === view }
            entries.insert(Entry(view: view), at: 0)
            scheduleSweep()
        }

        /// Records that a pane stopped being displayed, which is the only moment a pane becomes
        /// evictable.
        func noteHidden() { scheduleSweep() }

        /// Drops a pane that has torn its surface down for good, so it stops occupying a warm slot.
        func forget(_ view: GhosttyMirrorTerminalView) { entries.removeAll { $0.view == nil || $0.view === view } }

        /// Sweeps once the current pass over the view hierarchy has settled rather than against the
        /// state it would observe mid-pass. Re-rendering a tab's pane tree (`PaneTreeView.render`)
        /// detaches the whole split root and reattaches every cached pane view within one synchronous
        /// pass, so every pane in that tab reports itself hidden partway through even though all of
        /// them end the pass on screen. Sweeping then would free surfaces the user is looking at on
        /// every routine rerender. At most one sweep is ever pending, so a burst of transitions
        /// collapses into a single sweep of the settled state instead of a backlog.
        private func scheduleSweep() {
            guard !isSweepScheduled else { return }
            isSweepScheduled = true
            Task { @MainActor in
                isSweepScheduled = false
                releaseSurfacesBeyondLimit()
            }
        }

        private func releaseSurfacesBeyondLimit() {
            // A pane on screen is never freed however far down the order it has fallen: freeing its
            // surface would blank it with nothing left to trigger a rebuild. Displayed panes therefore
            // claim warm slots first and hidden panes are offered only what is left, which holds the
            // live total to `max(warmSurfaceLimit, displayed panes)`.
            let displayedCount = entries.reduce(into: 0) { count, entry in if entry.view?.isDisplayed == true { count += 1 } }
            var hiddenQuota = max(Self.warmSurfaceLimit - displayedCount, 0)
            var retained: [Entry] = []
            retained.reserveCapacity(entries.count)
            for entry in entries {
                guard let view = entry.view else { continue }
                if view.isDisplayed {
                    retained.append(entry)
                } else if hiddenQuota > 0 {
                    hiddenQuota -= 1
                    retained.append(entry)
                } else {
                    // A freed pane leaves the order; it re-registers the next time it is displayed.
                    view.evictMirrorSurface()
                }
            }
            entries = retained
        }

        /// Clears the recorded order without freeing anything, so one test's panes cannot occupy warm
        /// slots in the next test's ordering. Never called by the app.
        func resetForTesting() { entries.removeAll() }
    }
#endif
