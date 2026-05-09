import Foundation

public protocol TerminalSessionBackendRuntime: Sendable {
    var backendKind: TerminalSessionBackendKind { get }
    var launchConfiguration: TerminalSessionLaunchConfiguration { get }
    var paths: TerminalSessionPaths { get }

    func run() throws -> Never
}
