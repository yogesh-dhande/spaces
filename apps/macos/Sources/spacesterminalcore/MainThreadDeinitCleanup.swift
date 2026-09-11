#if canImport(Darwin)
    import Foundation

    /// Runs the main-thread half of a `@MainActor` class's `deinit` on the main thread.
    ///
    /// A `@MainActor` class whose last reference is dropped by a background task runs its `deinit` — and
    /// its stored property destruction — on that thread, so `MainActor.assumeIsolated` in a `deinit`
    /// traps there and a `guard Thread.isMainThread else { return }` abandons whatever the `deinit` was
    /// supposed to release. Cleanup that genuinely needs the main actor — freeing a Ghostty mirror,
    /// unregistering from a main-actor service, invalidating a display link — goes through here instead:
    /// it runs inline when the last release landed on the main thread, and is handed to the main queue
    /// when it did not, so the resources are always released and neither path traps.
    ///
    /// Capture the values the cleanup needs into locals first; `self` is already being destroyed and must
    /// never be captured. Teardown that is thread-safe on its own — `Task.cancel()`, a lock-guarded
    /// `stop()`/`cancelAll()`, `NotificationCenter.removeObserver` — needs none of this: declare those
    /// members `nonisolated(unsafe)` and do them directly in `deinit`.
    ///
    /// The sibling helper `MainThreadRelease` covers the other half of the same rule: AppKit/UIKit members
    /// that must not *deallocate* off the main thread.
    ///
    /// Darwin-only: the Linux daemon has no serviced main queue, so a cleanup scheduled there would never
    /// run. The guard makes that a compile error rather than a silent drop.
    public enum MainThreadDeinitCleanup {
        public static func run(_ cleanup: @escaping @MainActor () -> Void) {
            if Thread.isMainThread {
                MainActor.assumeIsolated(cleanup)
                return
            }
            // `DispatchQueue.main.async`'s closure must be `@Sendable`, and a cleanup closure carrying a
            // dying object's non-Sendable resources is not; the box carries it across without the compiler
            // enforcing Sendability, which is sound here because the resources have exactly one owner left
            // (the deinit that handed them over) and are touched once, on the main queue.
            let box = UncheckedCleanupBox(cleanup)
            DispatchQueue.main.async { MainActor.assumeIsolated(box.cleanup) }
        }

        private final class UncheckedCleanupBox: @unchecked Sendable {
            let cleanup: @MainActor () -> Void
            init(_ cleanup: @escaping @MainActor () -> Void) { self.cleanup = cleanup }
        }
    }
#endif
