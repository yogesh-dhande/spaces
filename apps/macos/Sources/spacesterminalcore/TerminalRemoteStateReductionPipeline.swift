import Foundation

/// One reduced payload, handed to the main actor for application.
public struct TerminalRemoteStateReductionOutput: Sendable {
    /// The payload exactly as it arrived. The clipboard one-shot reads its write from here, so the
    /// reduction's merge, which deliberately drops the field, cannot swallow it.
    public let incomingPayload: GhosttyRemoteSessionStatePayload
    /// Nil for a payload the pipeline deliberately does not reduce (`clipboard_write`, which carries an
    /// event and no state).
    public let reduction: TerminalRemoteStateReductionResult?
    /// How long the reduction took, reported as the receive metric's decode cost.
    public let reduceMS: Int

    public init(incomingPayload: GhosttyRemoteSessionStatePayload, reduction: TerminalRemoteStateReductionResult?, reduceMS: Int) {
        self.incomingPayload = incomingPayload
        self.reduction = reduction
        self.reduceMS = reduceMS
    }
}

/// One session's remote-state payloads, reduced off the main actor in arrival order.
///
/// Reducing a payload (decoding the incoming render-update blob, applying it to the render-update
/// baseline, and re-encoding the materialized full frame) is pure compute, it dominates the cost of a
/// session under steady output, and none of it touches UI state. So the pipeline, not the main actor,
/// owns the reducer: the render-update baseline and the previous stored payload the next reduce chains
/// from live here. The main actor is left with only the work that needs it (the terminal-view frame
/// application, the metrics, the notifications, and the clipboard one-shot), which it does from
/// `TerminalRemoteStateReductionOutput`.
///
/// Every entry point submits here, the state subscription and the direct `.state` fetch alike,
/// because a render update is a chain. A fetched full frame that overtook a queued delta, or a delta
/// reduced against a baseline a queued full frame had not yet replaced, breaks that chain and costs a
/// resync round trip. FIFO therefore has to span both routes, not just hold within one.
///
/// `submit` is callable from any thread and preserves call order. The single consumer reduces one
/// payload at a time and awaits its main-actor application before taking the next, so payload N is
/// always applied before payload N+1 is reduced: 1:1 payload in, application out, never coalesced,
/// dropped, or reordered.
public final class TerminalRemoteStateReductionPipeline: Sendable {
    private let continuation: AsyncStream<GhosttyRemoteSessionStatePayload>.Continuation
    private let consumer: Task<Void, Never>

    /// - Parameters:
    ///   - shouldUseFrame: Decides whether a materialized frame may be rendered. Pure, so it runs in
    ///     the pipeline alongside the reduction it gates.
    ///   - apply: Applies one reduction result on the main actor. Hold the host weakly here: the
    ///     consumer task outlives nothing, but a payload already being reduced when the host is
    ///     released must apply to nothing rather than to a torn-down host.
    public init(
        shouldUseFrame: @escaping @Sendable (GhosttyRenderFrame, GhosttyRemoteSessionStatePayload) -> Bool,
        apply: @escaping @MainActor @Sendable (TerminalRemoteStateReductionOutput) -> Void
    ) {
        let (stream, continuation) = AsyncStream<GhosttyRemoteSessionStatePayload>.makeStream(bufferingPolicy: .unbounded)
        self.continuation = continuation
        consumer = Task.detached(priority: .userInitiated) {
            var reducer = TerminalRemoteStateReducer()
            var previousPayload: GhosttyRemoteSessionStatePayload?
            for await incomingPayload in stream {
                let output: TerminalRemoteStateReductionOutput
                // A `clipboard_write` payload exports no screen state, and its runtime/attachment
                // snapshot is a repeat of the output turn that carried the escape sequence, so it is
                // carried through the queue (its position relative to the state around it is preserved)
                // but never reduced, which would risk an out-of-order payload regressing the cached
                // title, runtime state, or ownership.
                if incomingPayload.reason == TerminalRemoteSessionStateReason.clipboardWrite {
                    output = TerminalRemoteStateReductionOutput(incomingPayload: incomingPayload, reduction: nil, reduceMS: 0)
                } else {
                    let reduceStartedAt = Date()
                    let reduction = reducer.reduce(
                        incomingPayload: incomingPayload, previousPayload: previousPayload, shouldUseFrame: shouldUseFrame,
                        requestResyncOnApplyFailure: true)
                    previousPayload = reduction.storedPayload
                    output = TerminalRemoteStateReductionOutput(
                        incomingPayload: incomingPayload, reduction: reduction, reduceMS: TerminalPerformance.elapsedMS(since: reduceStartedAt))
                }
                await apply(output)
            }
        }
    }

    deinit {
        // Ending the stream ends the consumer loop; cancelling stops it from reducing whatever is still
        // queued for an owner that no longer exists.
        continuation.finish()
        consumer.cancel()
    }

    /// Enqueues one payload. Callable from any thread; payloads are reduced and applied in call order.
    public func submit(_ payload: GhosttyRemoteSessionStatePayload) { continuation.yield(payload) }
}
