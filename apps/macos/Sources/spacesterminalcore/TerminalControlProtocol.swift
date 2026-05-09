import Foundation

public struct TerminalControlRequest: Codable, Sendable, Equatable {
    public let command: String
    public let text: String?
    public let key: String?
    public let clientID: String?
    public let appendNewline: Bool

    public init(command: String, text: String? = nil, key: String? = nil, clientID: String? = nil, appendNewline: Bool = false) {
        self.command = command
        self.text = text
        self.key = key
        self.clientID = clientID
        self.appendNewline = appendNewline
    }
}

public struct TerminalControlResponse: Codable, Sendable, Equatable {
    public let ok: Bool
    public let message: String

    public init(ok: Bool, message: String) {
        self.ok = ok
        self.message = message
    }
}

enum TerminalControlCodec {
    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()

    static func encodeRequest(_ request: TerminalControlRequest) throws -> Data { try encoder.encode(request) }

    static func decodeRequest(_ data: Data) throws -> TerminalControlRequest { try decoder.decode(TerminalControlRequest.self, from: data) }

    static func encodeResponse(_ response: TerminalControlResponse) throws -> Data { try encoder.encode(response) }

    static func decodeResponse(_ data: Data) throws -> TerminalControlResponse { try decoder.decode(TerminalControlResponse.self, from: data) }
}
