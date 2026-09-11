#if canImport(Network)
    import Foundation
    import spacesterminalcore

    /// One `DeviceTerminalSessionStateModel` connect attempt: its dial task, the stream client it opened,
    /// and the facts that attempt's own callbacks and performance events report.
    ///
    /// Ordinarily a pane runs one attempt at a time. Stage 2 ("Device unreachable") is the exception: the
    /// backoff ladder's tick starts a fresh dial alongside a stale one rather than waiting out its dial
    /// budget, so up to `DeviceTerminalSessionStateModel.maximumConcurrentUnreachableAttempts` race at once
    /// and the first to deliver a payload wins. Everything an attempt's callbacks read about "the stream"
    /// therefore belongs to the attempt rather than to the model: a losing attempt must be stoppable on its
    /// own, and its dial's belated result must be recognizable as the loser's.
    ///
    /// A reference type, not a value: the model hands generations (not records) to the closures a dial
    /// installs, and those closures look the record back up when they fire, so an attempt retired in the
    /// meantime is simply gone from the live set.
    @MainActor final class DeviceTerminalConnectAttempt {
        /// This attempt's `connectAttemptGeneration`. Membership of the model's live set under this key is
        /// what makes every callback the attempt installed current or stale.
        let generation: UInt64
        /// When the dial started, the anchor this attempt's `stream_first_frame` measures from. Per attempt
        /// rather than model-wide, so a stage 2 winner reports its own dial-to-frame interval rather than
        /// whichever racing attempt happened to start last.
        let startedAt: Date
        /// The dial-to-subscribe budget `SpacesDeviceAPIStateStreamClient.start(timeoutSeconds:)` runs
        /// under. Stage 2 redials get a shorter one than the cold open: their job is to notice the device
        /// coming back, and the ladder starts a fresh dial on the next rung regardless.
        let dialTimeoutSeconds: TimeInterval
        /// The dial itself, from `openStateStream` through the local-device bootstrap and its retry.
        var task: Task<Void, Never>?
        /// Whether the dial task is still running. An attempt whose stream ends while this is true keeps
        /// its place in the live set until its own body finishes, since the blocking dial has no
        /// structured-concurrency link to that task and will resume regardless.
        var isDialInFlight = true
        /// The stream client this attempt opened, from before its blocking dial resolves (so a rejection
        /// racing the dial finds it) until the stream ends or the attempt is retired.
        var client: (any TerminalRemoteStateStreamClient)?
        /// `client`'s `streamClientGeneration`, the token its `onEvent`/`onDisconnect` closures carry.
        var streamGeneration: UInt64?
        /// The address `client`'s stream connected on. Nil until the dial returns, and for a test double
        /// with no host of its own.
        var connectedHost: String?
        /// Whether this attempt's stream has ever had a payload accepted: the proof it reached the device.
        /// The first attempt to set this wins the stage 2 race and retires the others.
        var deliveredPayload = false

        init(generation: UInt64, startedAt: Date, dialTimeoutSeconds: TimeInterval) {
            self.generation = generation
            self.startedAt = startedAt
            self.dialTimeoutSeconds = dialTimeoutSeconds
        }
    }
#endif
