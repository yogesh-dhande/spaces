import Foundation
import spacesterminalcore

/// One row of a restore answer that belongs to an agent automation: the captured record, and the command
/// its relaunch runs, which resumes the agent's conversation when it reported one.
public typealias AttributedAgentRestoreRequest = (record: RestorableSessionRecord, command: String)

/// What a restore answer's attributed rows came back as, keyed by captured session id: one outcome per
/// request, because a row refused on its own merits travels beside the rows that did relaunch.
public typealias AttributedAgentRestoreOutcomes = [String: Result<TerminalServiceSessionSummary, any Error>]
