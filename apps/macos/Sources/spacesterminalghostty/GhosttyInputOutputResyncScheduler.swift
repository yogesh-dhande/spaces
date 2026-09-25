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
        private static let localEchoResyncDelay: TimeInterval = 0.02

        private let onResync: @TerminalEngineActor () -> Void
        private var pendingResync = false
        private var commandResyncPending = false
        private var resyncWorkItem: DispatchWorkItem?

        /// - Parameter onResync: The host body run after the delay; it performs the
        ///   surface refresh, app-service tick, and `input_output` state broadcast.
        init(onResync: @escaping @TerminalEngineActor () -> Void) { self.onResync = onResync }

        var hasScheduledResync: Bool { resyncWorkItem != nil }

        /// The local-window owner produced interactive input; a later bulk output
        /// should trigger a resync to reconcile local echo.
        func noteLocalOwnerInput() { pendingResync = true }

        /// The local-window owner submitted a command (send / key-enter / clear);
        /// even interactive output should keep the delayed resync alive.
        func noteLocalOwnerCommand() { commandResyncPending = true }

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

    /// Coalesces repeated requests into a single body invocation on the next terminal-engine-actor turn.
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
