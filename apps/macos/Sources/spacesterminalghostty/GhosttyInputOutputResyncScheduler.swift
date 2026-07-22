#if canImport(AppKit) && canImport(GhosttyKit)
    import Foundation
    import spacesterminalcore

    /// Serializes the delayed input/output resync that keeps a local-window owner's
    /// locally echoed screen in sync with the render frame broadcast to subscribers.
    ///
    /// This runs on the terminal output hot path on the terminal engine actor. The transition table in
    /// `handleOutputDidChange(interactive:)`, the local-echo resync delay, and the `DispatchWorkItem` +
    /// engine-queue `asyncAfter` structure are load-bearing and must not change.
    @TerminalEngineActor final class GhosttyInputOutputResyncScheduler {
        /// Delay before re-broadcasting a full render frame so local echo settles.
        /// This is the local-echo resync delay.
        private static let localEchoResyncDelay: TimeInterval = 0.02

        private let onResync: @TerminalEngineActor () -> Void
        private var pendingResync = false
        private var commandResyncPending = false
        private var resyncWorkItem: DispatchWorkItem?

        /// - Parameter onResync: The host body run after the delay; it performs the
        ///   surface refresh, app-service tick, and `input_output` state broadcast.
        init(onResync: @escaping @TerminalEngineActor () -> Void) { self.onResync = onResync }

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
                // Dispatched on the engine queue below, so we are already dynamically isolated to the
                // terminal engine actor; run the isolated body inline (the DispatchWorkItem keeps the
                // cancel-before-fire semantics the transition table depends on).
                TerminalEngineActor.assumeIsolated {
                    guard let self else { return }
                    self.resyncWorkItem = nil
                    self.onResync()
                }
            }
            resyncWorkItem = workItem
            TerminalEngineActor.shared.queue.asyncAfter(deadline: .now() + Self.localEchoResyncDelay, execute: workItem)
        }
    }

    /// Coalesces repeated requests into a single body invocation on the next terminal-engine-actor turn:
    /// the first call schedules a `Task { @TerminalEngineActor }`, further calls before it runs are
    /// dropped, and the flag is cleared before the body runs.
    @TerminalEngineActor final class TerminalEngineNextTurnCoalescer {
        private var scheduled = false

        func schedule(_ body: @escaping @TerminalEngineActor () -> Void) {
            guard !scheduled else { return }
            scheduled = true
            Task { @TerminalEngineActor in
                self.scheduled = false
                body()
            }
        }
    }
#endif
