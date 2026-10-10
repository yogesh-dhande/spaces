import Foundation

/// What a client needs from its transcript replay to act on its selection.
public enum TerminalSelectionReplayNeed: Equatable, Sendable {
    /// The text of this selection, which can reach rows the client's live frames no longer show.
    case copy(TerminalAbsoluteSelection)
    /// The span of everything the replay can hold, which is the whole transcript budget.
    case selectAll
}

/// The next thing a client must do before it can read its selection out of the replay.
public enum TerminalSelectionReplayStep: Equatable, Sendable {
    /// There is no replay yet: read the newest page of transcript and build one.
    case readFirstPage
    /// The replay ends before the live frame the request started at: append the bytes written since.
    case readContinuation
    /// The replay does not reach back far enough: read the whole transcript budget and rebuild from it.
    case readWholeBudget
    /// The replay holds what the request needs.
    case format
    /// The request cannot be answered at all: there is no replay and none can be built.
    case abandon
}

/// Decides, from the replay's state, which read a copy or select-all needs next, so every client (the
/// Mac pane, and the iPhone's own replay paths) runs the same flow: ask for a step, perform it, record
/// it, ask again, until the answer is `format` or `abandon`.
///
/// Pure on purpose, and it never returns a step the request has already performed. A read that makes no
/// progress (a failed page, a continuation the file could not serve) therefore ends the loop instead of
/// repeating, and the client stays a thin loop with no repetition bookkeeping of its own.
public enum TerminalSelectionReplayPlanner {
    /// - Parameters:
    ///   - targetStamp: the newest live frame stamp when the request started. Catching up means reaching
    ///     that stamp's offset, not whatever frames arrive while the reads run: under streaming output the
    ///     newest stamp is always ahead of any replay.
    ///   - performed: the steps this request has already run.
    ///   - replayIsUnavailable: the client has latched that it cannot build a replay for this run.
    public static func nextStep(
        model: TerminalLocalScrollbackModel?, need: TerminalSelectionReplayNeed, targetStamp: TerminalLiveFrameStamp?,
        performed: [TerminalSelectionReplayStep], replayIsUnavailable: Bool = false
    ) -> TerminalSelectionReplayStep {
        guard let model else {
            // Select-all reads the whole budget however the replay starts, since its span is only the
            // whole screen once every row the client can replay is in. A read that already ran and left
            // no replay behind has failed, and there is nothing else to try.
            let read: TerminalSelectionReplayStep = need == .selectAll ? .readWholeBudget : .readFirstPage
            let hasTried = performed.contains(.readFirstPage) || performed.contains(.readWholeBudget)
            return replayIsUnavailable || hasTried ? .abandon : read
        }
        // A continuation leaves the replay as caught up as the file allows, which can still be short of
        // the stamp (the host stamps a buffered chunk the file has not received). A whole-budget read
        // rebuilds from the file's current end, so it is caught up too.
        let isCaughtUp = performed.contains(.readContinuation) || performed.contains(.readWholeBudget)
        if !isCaughtUp, let targetStamp, isBehind(model, targetStamp: targetStamp) { return .readContinuation }
        let canReadDeeper = model.hasDeeperHistory && !performed.contains(.readWholeBudget)
        switch need {
        case .selectAll: return canReadDeeper ? .readWholeBudget : .format
        case .copy(let selection):
            // A selection of another epoch has no rows in this replay at all; paging deeper cannot
            // help, and formatting reports that it has no text.
            let reachesAboveReplay = selection.historyEpoch == model.historyEpoch && selection.start.row < model.oldestAbsoluteRow
            return reachesAboveReplay && canReadDeeper ? .readWholeBudget : .format
        }
    }

    /// Whether the stamped live frame was produced from transcript bytes the replay does not hold. A
    /// stamp naming another file means the transcript was rewritten under the replay (a head-trim), which
    /// the continuation read answers with a rebuilt suffix.
    private static func isBehind(_ model: TerminalLocalScrollbackModel, targetStamp: TerminalLiveFrameStamp) -> Bool {
        targetStamp.transcriptFileIdentity != model.transcriptFileIdentity || targetStamp.transcriptByteOffset > model.transcriptEndByteOffset
    }

    /// The text to copy for `selection`, read from a replay that is ready (`nextStep` said `format`).
    /// The caller lines the replay up with its newest live stamps (`align(with:)`) before every
    /// `nextStep` and keeps it aligned as frames arrive, so the epoch comparison above and this read see
    /// the same rows. Nil when the replay holds no such text, which includes a selection from another
    /// coordinate system.
    ///
    /// Accepted behavior: a selection made on a replay that was not yet aligned lives in the replay's own
    /// numbering, and drops once the replay lines up with the host (its epoch changes). That needs the
    /// replay to be unaligned while the user selects, which is rare, and the user selects again.
    public static func copyText(for selection: TerminalAbsoluteSelection, in model: TerminalLocalScrollbackModel) -> String? {
        guard let text = model.text(for: selection), !text.isEmpty else { return nil }
        return text
    }

    /// The select-all selection of a replay that is ready, in the replay's current rows.
    public static func selectAllSelection(in model: TerminalLocalScrollbackModel) -> TerminalAbsoluteSelection? { model.selectAllSelection() }
}
