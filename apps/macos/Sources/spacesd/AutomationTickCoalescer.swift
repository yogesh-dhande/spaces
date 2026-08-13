import Foundation

/// Coalesces periodic scheduler callbacks so a slow service operation has at most one tick queued behind it.
final class AutomationTickCoalescer: @unchecked Sendable {
    private let tick: @Sendable () -> Void
    private let stateQueue = DispatchQueue(label: "spaces.automation-tick-coalescer")
    private var tickInFlight = false
    private var tickPending = false

    init(tick: @escaping @Sendable () -> Void) { self.tick = tick }

    func submit() {
        let shouldStart = stateQueue.sync { () -> Bool in
            if tickInFlight { tickPending = true; return false }
            tickInFlight = true
            return true
        }
        guard shouldStart else { return }
        run()
    }

    private func run() {
        Task.detached(priority: .utility) { [weak self] in
            self?.tick()
            guard let self else { return }
            let shouldRunAgain = self.stateQueue.sync { () -> Bool in
                if self.tickPending { self.tickPending = false; return true }
                self.tickInFlight = false
                return false
            }
            if shouldRunAgain { self.run() }
        }
    }
}
