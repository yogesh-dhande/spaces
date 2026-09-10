import Foundation

/// One `TerminalViewerModel` connect attempt: its dial task, the stream it opened, and the timing
/// facts its own perf events report.
///
/// Stage 2 ("Device unreachable") runs up to two dials at once, so that a fresh dial can start on the
/// backoff ladder's tick instead of waiting out a stale attempt's transport budget (see
/// `TerminalViewerModel.armUnreachableRedialTick`). Everything an attempt's callbacks read about "the
/// stream" therefore belongs to the attempt rather than to the model: a losing attempt's disconnect
/// must report its own numbers rather than the winner's, and its stream handle must be cancellable on
/// its own, since `SpacesDeviceAPIStreamHandle` has no deinit cancellation.
///
/// A reference type, not a value: `TerminalViewerModel` hands the generation (not the record) to the
/// closures a dial installs, and those closures look the record back up when they fire, so an attempt
/// that has been retired in the meantime is simply gone from the live set.
@MainActor final class TerminalConnectAttempt {
    /// This attempt's `reconnectAttemptGeneration`, the identity every callback is gated on
    /// (`TerminalViewerModel.isCurrentConnect`).
    let generation: UInt64
    /// The dial itself, from the backoff sleep through the subscribe and the bootstrap read. Cleared
    /// once the attempt is settled and there is nothing left to cancel.
    var task: Task<Void, Never>?
    /// The live stream, once `subscribe` has returned one.
    var handle: SpacesDeviceAPIStreamHandle?
    /// The address `handle`'s stream actually connected to (see `SpacesDeviceAPIStreamHandle.host`).
    /// `nil` for a backend with no host concept (Demo Mode) and before the handle lands.
    var connectedHost: String?
    /// Whether this attempt's stream has ever delivered a frame, the proof that it connected. The
    /// first attempt to set this wins the stage 2 race and retires the others.
    var deliveredFrame = false
    /// `stream_first_frame`'s elapsed time when the frame beat the handle install; the event waits for
    /// the handle, which names the host that was dialed.
    var firstFrameElapsedMSAwaitingHost: Int?
    /// Uptime anchor for this attempt's `stream_first_frame` and `stream_connect_end`. Set when
    /// `connect()` starts running, not when the attempt was scheduled, so the backoff sleep is not
    /// counted as connect time.
    var beginUptimeNanoseconds: UInt64?
    /// Whether this attempt reconnects silently (an owner keeping its screen up), captured at the same
    /// moment as `beginUptimeNanoseconds` for the same reason.
    var isSilent = false

    init(generation: UInt64) { self.generation = generation }
}
