import AppKit

/// Ships the final release of AppKit objects to the main queue when invoked off it. A @MainActor
/// class whose last reference is dropped by a background task runs its deinit — and its stored
/// property destruction — on that thread. A deinit that passes its AppKit members here first gives
/// them one extra retain that is dropped on the main queue instead, so AppKit deallocation stays
/// main-thread-only regardless of which thread performs the object's own last release.
enum MainThreadRelease {
    static func release(_ objects: [AnyObject]) {
        guard !Thread.isMainThread, !objects.isEmpty else { return }
        // `DispatchQueue.main.async`'s closure must be `@Sendable`, and `[AnyObject]` is not; the
        // box carries the array across without the compiler enforcing per-element Sendability,
        // which is fine here since the array is only ever read (dropped) once, on the main queue.
        let box = UncheckedObjectsBox(objects)
        DispatchQueue.main.async { _ = box }
    }

    private final class UncheckedObjectsBox: @unchecked Sendable {
        let objects: [AnyObject]
        init(_ objects: [AnyObject]) { self.objects = objects }
    }
}
