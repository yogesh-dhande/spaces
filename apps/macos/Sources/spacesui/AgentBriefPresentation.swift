/// What a terminal pane's brief column shows: the brief of the coding agent whose session the pane
/// hosts, while that brief is shown. A pane handed nil has no column.
struct AgentBriefPresentation: Equatable {
    /// The agent the brief belongs to (`row.agentID ?? row.id`), which is what visibility is keyed by.
    let agentKey: String
    let markdown: String
    /// ISO-8601 time the brief was last written, as the device reports it.
    let updatedAt: String?
}
