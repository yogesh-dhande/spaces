import Foundation

public struct TerminalSessionHostConnection: Sendable {
    public let isAvailable: @Sendable () -> Bool
    public let send: @Sendable (TerminalControlRequest) throws -> TerminalControlResponse

    public init(isAvailable: @escaping @Sendable () -> Bool, send: @escaping @Sendable (TerminalControlRequest) throws -> TerminalControlResponse) {
        self.isAvailable = isAvailable
        self.send = send
    }

    public static func localSocket(path: String) -> Self {
        Self(
            isAvailable: { FileManager.default.fileExists(atPath: path) },
            send: { request in try TerminalControlClient.send(request: request, socketPath: path) })
    }
}
