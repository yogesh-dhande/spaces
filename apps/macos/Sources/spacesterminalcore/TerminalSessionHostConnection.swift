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

    public static func tcp(host: String, port: Int, authToken: String? = nil) -> Self {
        Self(
            isAvailable: { true },
            send: { request in
                try TerminalControlClient.send(
                    request: TerminalControlRequest(
                        command: request.command, protocolVersion: request.protocolVersion,
                        minimumSupportedProtocolVersion: request.minimumSupportedProtocolVersion, authToken: authToken, text: request.text,
                        key: request.key, clientID: request.clientID, client: request.client, attachmentMode: request.attachmentMode,
                        appendNewline: request.appendNewline, columns: request.columns, rows: request.rows, offset: request.offset,
                        maximumBytes: request.maximumBytes, recentOutputLineCount: request.recentOutputLineCount), host: host, port: port)
            })
    }
}
