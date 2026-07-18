import Foundation

/// The daemon-side automation operations, injected as `@Sendable` closures that hop to the daemon main
/// actor and call the one live `AutomationService`. This is the seam for the "one implementation, two
/// transports" contract: the profile-socket handlers call the service directly, and the Device API server
/// is handed this bundle so its handlers drive the same scheduler instance. Working in domain types keeps
/// the bundle transport-neutral; each transport maps the results to its own wire summaries. Lives in
/// `workspacecore` so it is available unconditionally (the Device API module is compiled conditionally).
public struct AutomationOperations: Sendable {
    public let create: @Sendable (AutomationDraft) throws -> Automation
    public let update: @Sendable (_ id: String, _ draft: AutomationDraft) throws -> Automation
    public let delete: @Sendable (_ id: String) throws -> Void
    public let list: @Sendable () throws -> [Automation]
    public let runs: @Sendable (_ automationID: String?) throws -> [AutomationRun]
    public let trigger: @Sendable (_ id: String) throws -> AutomationRun
    public let cancelRun: @Sendable (_ runID: String) throws -> AutomationRun

    public init(
        create: @escaping @Sendable (AutomationDraft) throws -> Automation,
        update: @escaping @Sendable (String, AutomationDraft) throws -> Automation, delete: @escaping @Sendable (String) throws -> Void,
        list: @escaping @Sendable () throws -> [Automation], runs: @escaping @Sendable (String?) throws -> [AutomationRun],
        trigger: @escaping @Sendable (String) throws -> AutomationRun, cancelRun: @escaping @Sendable (String) throws -> AutomationRun
    ) {
        self.create = create
        self.update = update
        self.delete = delete
        self.list = list
        self.runs = runs
        self.trigger = trigger
        self.cancelRun = cancelRun
    }
}
