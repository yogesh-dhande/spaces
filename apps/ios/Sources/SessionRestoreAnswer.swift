import Foundation
import spacesdevicecore
import spacesterminalcore

/// What the user can answer a restore offer with. All or nothing by design: the record is one capture
/// of one moment's work, and picking through it row by row is a decision the user would have to make
/// before seeing any of the sessions again.
enum SessionRestoreAnswer: Equatable {
    case restore
    case skip
}

/// What answering one device's record produced, and what that means for this client. Pure and written
/// against the two Device API calls rather than against the client, so the contract (Restore relaunches
/// and maps, Skip discards, a failure remembers nothing) is testable on its own.
///
/// The iOS half of the Mac's `SessionRestoreController` answer path; the outcomes and their dispositions
/// are the Mac's, because the device makes the same three answers to either client.
enum SessionRestoreAnswerOutcome: Equatable {
    /// The device accepted the answer. Carries each captured session id mapped to the session now
    /// running in its place and the rows the device could not relaunch; both empty for Skip.
    case answered(SpacesDeviceRestoredSessionsResult)
    /// The device refused the answer because the record it names is not the one it holds any more: it
    /// captured again, or another client answered first. Not a failure to report, and not an answer
    /// either: whatever the device holds now is offered afresh.
    case superseded
    /// The device would not authenticate the answer: the pairing this client holds is not one it
    /// recognizes any more (its auth token or its pinned identity changed since the offer appeared).
    /// Kept apart from a plain failure because retrying it from the sheet fails the same way until the
    /// user pairs again. Carries the recovery message the rest of the app shows for the same failure.
    case unauthenticated(recoveryMessage: String)
    /// The answer never landed (the device is unreachable, the daemon refused it). Carries what to tell
    /// the user, because the agents they asked for are still waiting on the device.
    case failed(message: String)
}

/// What one outcome means for the client: whether to remember the generation as answered, and what (if
/// anything) the sheet has to say before it can close.
struct SessionRestoreAnswerDisposition: Equatable {
    /// Only a device that accepted the answer has cleared its record, and only a cleared record must not
    /// be offered again. Remembering a generation the device still holds would hide the offer for good;
    /// forgetting one it cleared would ask about agents that no longer exist.
    let recordsGeneration: Bool
    /// Non-nil keeps the sheet open carrying this message: the user asked for their agents back and did
    /// not get them, so the answer is theirs to retry or abandon.
    let failureMessage: String?
}

enum SessionRestoreAnswering {
    /// Sends one answer and reports what came back.
    static func perform(
        _ answer: SessionRestoreAnswer, generation: String, restore: @Sendable (String) async throws -> SpacesDeviceRestoredSessionsResult,
        discard: @Sendable (String) async throws -> Void
    ) async -> SessionRestoreAnswerOutcome {
        do {
            switch answer {
            case .restore: return .answered(try await restore(generation))
            case .skip:
                try await discard(generation)
                return .answered(.init(newSessionIDsByCapturedSessionID: [:]))
            }
        } catch {
            // A refusal on the record's identity is the daemon saying this offer is stale, which is a
            // different thing from an answer that did not land: nothing is wrong, the user is simply
            // looking at a record the device has replaced.
            if (error as? any SpacesDeviceErrorCodeProviding)?.spacesDeviceErrorCode == .conflict { return .superseded }
            // Classified here rather than flattened into a message, because the way out of it is a
            // surface this sheet is covering: the client routes it into the same re-pair recovery every
            // other failed request uses, and takes the sheet down so the user can reach it.
            if let recoveryMessage = SpacesDeviceAPIAuthentication.recoveryMessage(for: error) {
                return .unauthenticated(recoveryMessage: recoveryMessage)
            }
            return .failed(message: error.localizedDescription)
        }
    }

    static func disposition(for outcome: SessionRestoreAnswerOutcome) -> SessionRestoreAnswerDisposition {
        switch outcome {
        case .answered: SessionRestoreAnswerDisposition(recordsGeneration: true, failureMessage: nil)
        // Nothing to retry and nothing to report: the record the user was looking at is gone, and the one
        // that replaced it is presented by the decision that re-runs when the sheet closes.
        case .superseded: SessionRestoreAnswerDisposition(recordsGeneration: false, failureMessage: nil)
        // The device never read the answer, so its record stands and nothing is remembered. Nothing to
        // say in the sheet either: the sheet comes down, and the recovery surface it uncovers is what
        // tells the user to pair again.
        case .unauthenticated: SessionRestoreAnswerDisposition(recordsGeneration: false, failureMessage: nil)
        case .failed(let message): SessionRestoreAnswerDisposition(recordsGeneration: false, failureMessage: message)
        }
    }

    /// What to tell the user about the rows the device could not relaunch, or nil when everything came
    /// back.
    ///
    /// The device clears its record whatever the relaunches did, so this report is the only word the user
    /// gets: a row that failed because its workspace is gone would fail the same way on every attempt,
    /// and keeping it in the record would offer it again forever.
    ///
    /// Each line is the offer's own row, found by session id, followed by the workspace the list grouped
    /// it under and the device's reason. Worded from the row rather than from anything the device sends,
    /// so the line reads like the entry the user just answered and two sessions of the same agent kind in
    /// one workspace are still told apart.
    static func failureReport(_ failures: [SpacesDeviceRestoredSessionFailure], offer: SessionRestoreOffer) -> String? {
        guard !failures.isEmpty else { return nil }
        let linesBySessionID = Dictionary(
            offer.groups.flatMap { group in group.rows.map { ($0.sessionID, "\($0.displayLabel) in \(group.heading)") } },
            uniquingKeysWith: { first, _ in first })
        return failures.map { failure in
            // A failure for a row this offer does not list can only come from a record captured after the
            // sheet was built, which the device's own title is the one description of.
            "\(linesBySessionID[failure.sessionID] ?? failure.title): \(failure.message)"
        }.joined(separator: "\n")
    }
}
