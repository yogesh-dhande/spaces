import Foundation

/// How much a session's program has painted, as a cheap fingerprint: the byte length and last-write time
/// of the session's output log, which only advances when the program writes to the terminal. Input never
/// appears in it, so a mark that moves after a write to the session is the program reacting to that write.
public struct AutomationSessionOutputMark: Equatable, Sendable {
    public let byteCount: Int
    public let modifiedAt: Date?

    public init(byteCount: Int, modifiedAt: Date?) {
        self.byteCount = byteCount
        self.modifiedAt = modifiedAt
    }

    /// A session whose output log does not exist yet, which is a real state (the log appears with the
    /// program's first output) and compares equal to itself, so "nothing has been painted" reads as no
    /// reaction rather than as a change.
    public static let silent = AutomationSessionOutputMark(byteCount: 0, modifiedAt: nil)
}

/// The seed-prompt delivery ladder for one agent-kind automation run: what to write next, decided from
/// whether the agent's terminal reacted to what was written last.
///
/// A coding agent's TUI enables bracketed paste (DECSET 2004) while it is still mounting, so the
/// readiness gate can only narrow the window in which a prompt is written into a terminal that is not
/// ready for it, never close it. Driving the real Claude Code TUI under a PTY put numbers on that window
/// and on the two failures it produces (issue #556): the TUI enabled DECSET 2004 0.4–2.2s before its
/// composer accepted anything; a submit written inside that window was discarded outright, with nothing
/// appearing in the composer; and a submit written just as the composer mounted left the text in the
/// composer with its Enter swallowed. The write acknowledgement sees neither — the bytes did reach the
/// PTY — so delivery cannot be a single write.
///
/// What the terminal does report is whether the program painted, and the same PTY runs measured what each
/// outcome looks like in the second after a write: an accepted paste paints once (~800 bytes) and falls
/// silent; a submitted prompt paints every second for the length of the turn (~0.5–4 KB per second, an
/// agent's spinner and streaming answer); an idle composer is silent apart from a rare small status
/// repaint. Every step here follows from that:
///
/// - **Write into a settled terminal.** A prompt goes out only after the session has painted nothing for
///   `settleTicks` consecutive ticks, which a TUI still mounting never satisfies (its longest silence
///   before the composer appeared was 1.6s). Writing into a quiet terminal is also what makes the next
///   paint attributable to the write rather than to the program finishing its own startup.
/// - **No paint at all → nothing consumed the write**; send the whole prompt again.
/// - **A paint, then silence → the text is sitting in the composer unsubmitted**; press Enter. An Enter
///   is only ever sent into a terminal that has painted nothing since the last write, which is what keeps
///   it safe: a TUI that raised a dialog painted it, so this never answers one.
/// - **Painting in `workTicks` consecutive ticks → the agent is working on the prompt**; that is
///   delivery. One paint is not enough: an Enter into an empty composer also produces a small repaint.
///
/// The ladder repeats until it confirms delivery or the run's readiness deadline fails the run loudly.
/// One step runs per service tick (1s), which is what spaces the observations. Ticks are coalesced rather
/// than guaranteed, so a tick that overran its second is followed immediately by the one queued behind it
/// and a single window can close in about a second instead of two. That degrades to writing into a
/// terminal that was quiet for a second or re-sending a second early — both of which the ladder's own
/// steps then correct — so the counters stay in ticks rather than carrying a clock through every step and
/// every test that drives one.
struct AutomationAgentPromptDelivery: Equatable {
    enum Action: Equatable {
        /// Write the prompt as one submit-send (text plus its Enter).
        case sendPrompt
        /// Write a bare Enter, submitting text the composer is already holding.
        case sendEnter
        /// Nothing to write this tick; keep watching.
        case wait
        /// The agent took the prompt and is working on it: record it as delivered.
        case recordDelivered
    }

    /// Consecutive silent ticks that mark the agent's TUI as settled and ready to be written into.
    static let settleTicks = 2
    /// Ticks a write is given to produce its first paint before it counts as unconsumed.
    static let reactionTicks = 2
    /// Consecutive painting ticks that distinguish an agent working on the prompt from a one-off repaint.
    static let workTicks = 2
    /// Enters pressed into a quiet terminal before the ladder concludes the text is not there after all
    /// and starts over with the whole prompt.
    static let maxEnterAttempts = 2

    private enum Phase: Equatable {
        /// Waiting for the TUI to stop painting before writing anything into it.
        case settling(mark: AutomationSessionOutputMark, quietTicks: Int)
        /// A write is out; waiting to see whether the program paints in response. `enter` records that the
        /// write was a bare Enter, so silence retries the Enter rather than pasting the prompt on top of a
        /// copy the composer may already be holding.
        case awaitingReaction(mark: AutomationSessionOutputMark, quietTicks: Int, enter: Bool)
        /// The program painted; counting how long it keeps painting.
        case awaitingWork(mark: AutomationSessionOutputMark, paintedTicks: Int)
    }

    private var phase: Phase
    /// Enters pressed since the last time the whole prompt went out.
    private var enterAttempts = 0

    /// Starts the ladder watching a session that is ready for input but has not been written to yet.
    init(observedMark mark: AutomationSessionOutputMark) { phase = .settling(mark: mark, quietTicks: 0) }

    /// Advances one tick and reports what to write, assuming the caller performs it. `mark` is the
    /// session's output mark as of this tick; when the returned action writes, that same mark is what the
    /// next tick compares against.
    mutating func next(mark: AutomationSessionOutputMark) -> Action {
        switch phase {
        case .settling(let observedMark, let quietTicks):
            guard mark == observedMark else {
                phase = .settling(mark: mark, quietTicks: 0)
                return .wait
            }
            guard quietTicks + 1 >= Self.settleTicks else {
                phase = .settling(mark: mark, quietTicks: quietTicks + 1)
                return .wait
            }
            return startPrompt(mark: mark)
        case .awaitingReaction(let writtenMark, let quietTicks, let enter):
            if mark != writtenMark {
                phase = .awaitingWork(mark: mark, paintedTicks: 1)
                return Self.workTicks <= 1 ? .recordDelivered : .wait
            }
            guard quietTicks + 1 >= Self.reactionTicks else {
                phase = .awaitingReaction(mark: writtenMark, quietTicks: quietTicks + 1, enter: enter)
                return .wait
            }
            // An Enter that painted nothing tells us nothing new about the composer, so escalate the same
            // way a reacting-then-quiet terminal does: try the Enter again, and only once those are spent
            // conclude the text is not there and start over. Pasting the prompt on top of a copy the
            // composer is still holding would submit it twice over.
            if enter, enterAttempts < Self.maxEnterAttempts { return sendEnter(mark: mark) }
            // Nothing consumed the write at all, so nothing is holding the text: start over with the
            // whole prompt rather than pressing Enter into a composer that never received it.
            return startPrompt(mark: mark)
        case .awaitingWork(let observedMark, let paintedTicks):
            if mark != observedMark {
                guard paintedTicks + 1 >= Self.workTicks else {
                    phase = .awaitingWork(mark: mark, paintedTicks: paintedTicks + 1)
                    return .wait
                }
                return .recordDelivered
            }
            // It reacted and stopped: the text is in the composer with nothing running.
            //
            // Accepted risk: a dialog the agent raised in the second after the prompt also looks like this,
            // and the Enter answers it with its default. The prompt's own submit-send carries an Enter into
            // whatever is on screen already, so seeding an agent that is sitting at a dialog is a
            // pre-existing property of automations (spec.md), not something this step introduces; what it
            // adds is one more Enter a second later. A submitted turn is what normally follows a prompt,
            // and every supported agent animates a spinner while it thinks, so a full silent tick right
            // after a submit means nothing is running. No terminal fact separates a modal from a composer,
            // so the alternative is not a safer Enter but no Enter at all — which is the swallowed-submit
            // failure this ladder exists to fix.
            //
            // Accepted risk: an agent whose whole turn starts and finishes between two observations also
            // looks like this, and is sent an Enter (a no-op into an idle composer) and then the prompt
            // again, so that task runs twice. Every supported agent streams its turn — a spinner and answer
            // painting every second for as long as the turn lasts — so this needs either a turn that
            // completes inside a second or a service tick that stalled long enough to swallow a whole turn,
            // which is a degraded daemon rather than normal operation. The duplicate is bounded: the second
            // turn's own painting confirms delivery and the ladder stops. Deciding by how much was painted
            // instead would hold across a stalled poll but trade this for a worse failure: a composer that
            // echoes a long paste can out-paint a short turn, and a prompt wrongly recorded as delivered
            // leaves the run waiting on work no agent ever started.
            guard enterAttempts < Self.maxEnterAttempts else { return startPrompt(mark: mark) }
            return sendEnter(mark: mark)
        }
    }

    private mutating func startPrompt(mark: AutomationSessionOutputMark) -> Action {
        enterAttempts = 0
        phase = .awaitingReaction(mark: mark, quietTicks: 0, enter: false)
        return .sendPrompt
    }

    private mutating func sendEnter(mark: AutomationSessionOutputMark) -> Action {
        enterAttempts += 1
        phase = .awaitingReaction(mark: mark, quietTicks: 0, enter: true)
        return .sendEnter
    }
}
