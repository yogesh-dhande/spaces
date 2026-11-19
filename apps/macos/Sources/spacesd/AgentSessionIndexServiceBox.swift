import Foundation

/// The live `AgentSessionIndexService`, held in a lock-guarded box so the Device API's off-main search
/// handler can resolve it without touching the main actor. Set when the device runtime services start and
/// cleared when they stop, so a request that races a handoff finds no service rather than a stopped one.
final class AgentSessionIndexServiceBox: @unchecked Sendable {
    private let lock = NSLock()
    private var service: AgentSessionIndexService?

    func get() -> AgentSessionIndexService? {
        lock.lock()
        defer { lock.unlock() }
        return service
    }

    func set(_ newValue: AgentSessionIndexService?) {
        lock.lock()
        service = newValue
        lock.unlock()
    }
}
