import Dispatch
import Foundation

/// What a session core made of one control request: the response, plus — for a send, whose bytes are
/// written after the request is handled — the acknowledgement that resolves when those writes have run.
///
/// The cores handle requests on the terminal engine actor, while the writes they enqueue run on that
/// same actor afterwards, so a core can never wait for its own writes: it hands the wait back to its
/// caller, which is always off the engine (a session's control-socket queue, or the daemon's off-main
/// send path). `resolvedResponse()` is that wait, and it is what turns "the request was accepted" into
/// "the bytes reached the PTY".
public struct TerminalControlHandling: Sendable {
    public let response: TerminalControlResponse
    public let writeAcknowledgement: TerminalInputWriteAcknowledgement?

    public init(response: TerminalControlResponse, writeAcknowledgement: TerminalInputWriteAcknowledgement? = nil) {
        self.response = response
        self.writeAcknowledgement = writeAcknowledgement
    }

    /// Bounded below `TerminalControlClient`'s 5s round trip so a send whose write never runs is reported
    /// as a failed send by the daemon rather than as a dead control socket by the client. A submit whose
    /// text goes out unframed spends `TerminalControlInputSequencer.separation` inside this window by
    /// design, which is why it is seconds rather than milliseconds. Enough unframed submits queued ahead
    /// of one on the same session could still exhaust it, which reports a failed send for a write that
    /// lands afterwards; that needs several seconds of back-to-back submits into a session whose program
    /// has bracketed paste off, and the callers that queue submits in bulk (agent notification delivery)
    /// deliver them one at a time, each waiting for its own write.
    public static let writeAcknowledgementTimeout: DispatchTimeInterval = .seconds(4)

    /// The response to answer with, after waiting for any enqueued writes to reach the PTY.
    ///
    /// MUST be called off the terminal engine actor: the writes being waited for run there.
    public func resolvedResponse() -> TerminalControlResponse {
        guard let writeAcknowledgement else { return response }
        precondition(
            !TerminalEngineActor.isRunningOnEngineQueue,
            "a send's write acknowledgement must be awaited off the terminal engine actor — the write it waits for runs there")
        switch writeAcknowledgement.wait(timeout: Self.writeAcknowledgementTimeout) {
        case .delivered: return response
        case .notDelivered:
            return TerminalControlResponse(
                ok: false, message: "Terminal session stopped accepting input before the send reached it.", errorCode: .sessionNotRunning)
        case nil:
            return TerminalControlResponse(ok: false, message: "Timed out waiting for the terminal to accept the send.", errorCode: .internalError)
        }
    }
}
