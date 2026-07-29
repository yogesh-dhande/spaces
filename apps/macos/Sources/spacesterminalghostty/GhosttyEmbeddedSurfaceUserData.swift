#if canImport(GhosttyKit)
    import Foundation
    import GhosttyKit
    import spacesterminalcore

    @TerminalEngineActor final class GhosttyEmbeddedSurfaceUserData {
        private let closeHandler: @TerminalEngineActor () -> Void
        private let surfaceProvider: @TerminalEngineActor () -> ghostty_surface_t?
        private let clipboardWriteHandler: @TerminalEngineActor (String) -> Void

        /// Guards `replayingHistoricalOutput`, which the ghostty runtime's write-clipboard callback
        /// reads from outside the engine actor.
        private nonisolated let replayLock = NSLock()
        private nonisolated(unsafe) var replayingHistoricalOutput = false

        init(
            closeHandler: @escaping @TerminalEngineActor () -> Void, surfaceProvider: @escaping @TerminalEngineActor () -> ghostty_surface_t?,
            clipboardWriteHandler: @escaping @TerminalEngineActor (String) -> Void
        ) {
            self.closeHandler = closeHandler
            self.surfaceProvider = surfaceProvider
            self.clipboardWriteHandler = clipboardWriteHandler
        }

        func handleClose() { closeHandler() }

        func surface() -> ghostty_surface_t? { surfaceProvider() }

        func handleClipboardWrite(_ text: String) { clipboardWriteHandler(text) }

        /// True while this surface's driver is replaying historical transcript bytes into it.
        ///
        /// A daemon handoff replays a whole transcript through the live surface, so every OSC 52 the
        /// scrollback ever carried reaches the runtime's write-clipboard callback a second time.
        /// Forwarding those would silently overwrite the owner's current clipboard with stale text —
        /// worse than the spurious alert the same replay costs the bell, because it destroys something
        /// the user has.
        ///
        /// The callback fires nonisolated (inside ghostty's mailbox drain) and hands the write to the
        /// engine actor on a LATER turn, by which time the replay bracket has closed, so the decision
        /// has to be read where the callback fires rather than where it is delivered. The driver's
        /// bracket ends with the `ghostty_app_tick` that drains the messages the replay queued, so
        /// every replayed write has already been refused by the time this clears.
        nonisolated var isReplayingHistoricalOutput: Bool {
            replayLock.lock()
            defer { replayLock.unlock() }
            return replayingHistoricalOutput
        }

        nonisolated func setReplayingHistoricalOutput(_ value: Bool) {
            replayLock.lock()
            defer { replayLock.unlock() }
            replayingHistoricalOutput = value
        }
    }
#endif
