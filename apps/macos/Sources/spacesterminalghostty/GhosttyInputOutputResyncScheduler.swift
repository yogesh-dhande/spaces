#if canImport(AppKit) && canImport(GhosttyKit)
    import Foundation

    /// Serializes the delayed input/output resync that keeps a local-window owner's
    /// locally echoed screen in sync with the render frame broadcast to subscribers.
    ///
    /// This runs on the terminal output hot path. The transition table in
    /// `handleOutputDidChange(interactive:)`, the local-echo resync delay, and the
    /// `DispatchWorkItem` + `DispatchQueue.main.asyncAfter` + inner `Task { @MainActor }`
    /// structure are load-bearing and must not change.
    @MainActor final class GhosttyInputOutputResyncScheduler {
        /// Delay before re-broadcasting a full render frame so local echo settles.
        /// This is the local-echo resync delay.
        private static let localEchoResyncDelay: TimeInterval = 0.02

        private let onResync: @MainActor () -> Void
        private var pendingResync = false
        private var commandResyncPending = false
        private var resyncWorkItem: DispatchWorkItem?

        /// - Parameter onResync: The host body run after the delay; it performs the
        ///   surface refresh, app-service tick, and `input_output` state broadcast.
        init(onResync: @escaping @MainActor () -> Void) { self.onResync = onResync }

        /// True while a delayed resync is scheduled but has not yet fired.
        var hasScheduledResync: Bool { resyncWorkItem != nil }

        /// The local-window owner produced interactive input; a later bulk output
        /// should trigger a resync to reconcile local echo.
        func noteLocalOwnerInput() { pendingResync = true }

        /// The local-window owner submitted a command (send / key-enter / clear);
        /// even interactive output should keep the delayed resync alive.
        func noteLocalOwnerCommand() { commandResyncPending = true }

        /// Applies the resync transition table for freshly drained output.
        ///
        /// - interactive output with a pending command or an in-flight work item:
        ///   clear both pending flags and (re)schedule the delayed resync.
        /// - plain interactive output: clear the input-pending flag and cancel any
        ///   work item without rescheduling (the work item is already `nil` here).
        /// - bulk output with a pending input flag or an in-flight work item:
        ///   clear both pending flags and (re)schedule.
        /// - bulk output with nothing pending: no-op.
        func handleOutputDidChange(interactive: Bool) {
            if interactive {
                if commandResyncPending || resyncWorkItem != nil {
                    pendingResync = false
                    commandResyncPending = false
                    scheduleResync()
                } else {
                    pendingResync = false
                    resyncWorkItem?.cancel()
                    resyncWorkItem = nil
                }
            } else if pendingResync || resyncWorkItem != nil {
                pendingResync = false
                commandResyncPending = false
                scheduleResync()
            }
        }

        /// Cancels a pending resync while the session terminates.
        ///
        /// Deliberately clears only the command flag, matching the host's original
        /// `terminate()`, which left the input-pending flag untouched. Preserving
        /// that keeps the existing behavior exactly.
        func cancelForTermination() {
            resyncWorkItem?.cancel()
            resyncWorkItem = nil
            commandResyncPending = false
        }

        private func scheduleResync() {
            resyncWorkItem?.cancel()
            let workItem = DispatchWorkItem { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.resyncWorkItem = nil
                    self.onResync()
                }
            }
            resyncWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.localEchoResyncDelay, execute: workItem)
        }
    }

    /// Coalesces repeated requests into a single body invocation on the next
    /// main-actor turn: the first call schedules a `Task { @MainActor }`, further
    /// calls before it runs are dropped, and the flag is cleared before the body runs.
    @MainActor final class MainActorNextTurnCoalescer {
        private var scheduled = false

        func schedule(_ body: @escaping @MainActor () -> Void) {
            guard !scheduled else { return }
            scheduled = true
            Task { @MainActor in
                self.scheduled = false
                body()
            }
        }
    }
#endif
