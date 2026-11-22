import Foundation

/// What a pane's empty state says. One value per situation keeps the wording, and whether the state
/// offers an action, decided in one place and independent of the views that draw it.
struct PaneEmptyStateContent: Equatable {
    /// SF Symbol name.
    let symbol: String
    let title: String
    let detail: String?
    /// Label of the text action under the detail, or nil when the state offers none.
    let actionTitle: String?

    static let alertsAllClear = PaneEmptyStateContent(
        symbol: "checkmark.circle", title: "No attention required", detail: "All running workspaces are healthy.", actionTitle: nil)

    static let noAutomations = PaneEmptyStateContent(
        symbol: "clock.arrow.circlepath", title: "No automations", detail: "Run a command on a schedule, on any of your devices.",
        actionTitle: "Create an automation")

    static let noRuns = PaneEmptyStateContent(
        symbol: "list.bullet.rectangle", title: "No runs yet", detail: "Runs appear here once an automation fires.", actionTitle: nil)

    /// The Prompts pane with no rows. A search with no match offers no action: the empty result is
    /// about the query, not the library. With no query the action creates a prompt, and exists only
    /// while a prompt can be created (`canCreate`, which is false when no device is reachable).
    static func savedPrompts(query: String, canCreate: Bool) -> PaneEmptyStateContent {
        guard query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return PaneEmptyStateContent(symbol: "magnifyingglass", title: "No matching prompts", detail: nil, actionTitle: nil)
        }
        return PaneEmptyStateContent(
            symbol: "text.quote", title: "No saved prompts", detail: "Save a prompt once and copy it into any terminal.",
            actionTitle: canCreate ? "Create a prompt" : nil)
    }

    /// The Sessions pane when its device cannot answer: the results are replaced by naming the device.
    static func sessionsOffline(deviceName: String) -> PaneEmptyStateContent {
        PaneEmptyStateContent(symbol: "wifi.slash", title: "\(deviceName) is offline", detail: nil, actionTitle: nil)
    }

    /// The Sessions pane before the device has answered its first search.
    static let sessionsSearching = PaneEmptyStateContent(symbol: "hourglass", title: "Searching", detail: nil, actionTitle: nil)

    /// The Sessions pane with an answered, finished index and no rows: a query with no hit is about the
    /// query, and an empty index is about the device.
    static func sessionsEmpty(hasQuery: Bool, deviceName: String) -> PaneEmptyStateContent {
        hasQuery
            ? PaneEmptyStateContent(symbol: "magnifyingglass", title: "No sessions match", detail: nil, actionTitle: nil)
            : PaneEmptyStateContent(symbol: "bubble.left.and.bubble.right", title: "No sessions on \(deviceName)", detail: nil, actionTitle: nil)
    }

    /// The Resources table with no rows: the first sample has not landed yet, or nothing is running.
    static func resources(hasMeasurement: Bool) -> PaneEmptyStateContent {
        hasMeasurement
            ? PaneEmptyStateContent(symbol: "terminal", title: "No terminals are running", detail: nil, actionTitle: nil)
            : PaneEmptyStateContent(symbol: "hourglass", title: "Measuring…", detail: nil, actionTitle: nil)
    }
}
