import Foundation

/// Runs window-cycle steps strictly one after another, in the order they were enqueued.
///
/// A burst of Next/Previous presses is a sequence, not a set of independent requests: each step has
/// to start from where the previous one landed. A single step can await real work (Chrome tab
/// discovery over Apple Events, opening a remote pane), so two presses that overlap would otherwise
/// both read the pre-landing cursor and the pre-landing focused session, and could land on the same
/// target instead of advancing the rotation.
///
/// Enqueuing never blocks the caller and never drops or coalesces a step: every press the user made
/// is a step of the rotation, so the queue is unbounded and runs them all in order.
@MainActor final class WindowCycleStepQueue {
    /// The most recently enqueued step. A new step awaits it before running, which chains the whole
    /// queue: awaiting a finished task returns immediately, so a press outside a burst pays nothing.
    private var tail: Task<Void, Never>?

    func enqueue(_ step: @escaping @MainActor () async -> Void) {
        let previous = tail
        tail = Task { @MainActor in
            await previous?.value
            await step()
        }
    }
}
