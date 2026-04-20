import Foundation

public struct TerminalLaunchResult: Sendable {
    public let terminalID: String?
    public let containerID: String?
    public let fallbackWindowID: Int?
    public let tabIndex: Int?

    public init(terminalID: String?, containerID: String?, fallbackWindowID: Int?, tabIndex: Int? = nil) {
        self.terminalID = terminalID
        self.containerID = containerID
        self.fallbackWindowID = fallbackWindowID
        self.tabIndex = tabIndex
    }
}

public struct TerminalFocusTarget: Sendable {
    public let terminalID: String?
    public let windowID: Int?
    public let tabIndex: Int?

    public init(terminalID: String?, windowID: Int?, tabIndex: Int? = nil) {
        self.terminalID = terminalID
        self.windowID = windowID
        self.tabIndex = tabIndex
    }
}

public protocol TerminalAdapter: Sendable {
    var appName: String { get }
    var bundleIdentifier: String { get }

    func isAvailable() -> Bool
    func openWindowAndRun(command: String, cwd: String, background: Bool) throws -> TerminalLaunchResult
    func focusTrackedTerminal(_ target: TerminalFocusTarget) throws -> Bool
    func listLiveTerminalIDs() throws -> Set<String>
}
