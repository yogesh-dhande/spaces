import Foundation

public struct TerminalControlRequest: Codable, Sendable, Equatable {
    public let command: String
    public let authToken: String?
    public let text: String?
    public let key: String?
    public let clientID: String?
    public let client: TerminalClient?
    public let attachmentMode: TerminalAttachmentMode?
    public let lineCount: Int?
    public let columns: Int?
    public let rows: Int?
    public let appendNewline: Bool

    public init(
        command: String, authToken: String? = nil, text: String? = nil, key: String? = nil, clientID: String? = nil, client: TerminalClient? = nil,
        attachmentMode: TerminalAttachmentMode? = nil, lineCount: Int? = nil, columns: Int? = nil, rows: Int? = nil, appendNewline: Bool = false
    ) {
        self.command = command
        self.authToken = authToken
        self.text = text
        self.key = key
        self.clientID = clientID
        self.client = client
        self.attachmentMode = attachmentMode
        self.lineCount = lineCount
        self.columns = columns
        self.rows = rows
        self.appendNewline = appendNewline
    }

    private enum CodingKeys: String, CodingKey {
        case command
        case authToken
        case text
        case key
        case clientID
        case client
        case attachmentMode
        case lineCount
        case columns
        case rows
        case appendNewline
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        command = try container.decode(String.self, forKey: .command)
        authToken = try container.decodeIfPresent(String.self, forKey: .authToken)
        text = try container.decodeIfPresent(String.self, forKey: .text)
        key = try container.decodeIfPresent(String.self, forKey: .key)
        clientID = try container.decodeIfPresent(String.self, forKey: .clientID)
        client = try container.decodeIfPresent(TerminalClient.self, forKey: .client)
        attachmentMode = try container.decodeIfPresent(TerminalAttachmentMode.self, forKey: .attachmentMode)
        lineCount = try container.decodeIfPresent(Int.self, forKey: .lineCount)
        columns = try container.decodeIfPresent(Int.self, forKey: .columns)
        rows = try container.decodeIfPresent(Int.self, forKey: .rows)
        appendNewline = try container.decodeIfPresent(Bool.self, forKey: .appendNewline) ?? false
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(command, forKey: .command)
        try container.encodeIfPresent(authToken, forKey: .authToken)
        try container.encodeIfPresent(text, forKey: .text)
        try container.encodeIfPresent(key, forKey: .key)
        try container.encodeIfPresent(clientID, forKey: .clientID)
        try container.encodeIfPresent(client, forKey: .client)
        try container.encodeIfPresent(attachmentMode, forKey: .attachmentMode)
        try container.encodeIfPresent(lineCount, forKey: .lineCount)
        try container.encodeIfPresent(columns, forKey: .columns)
        try container.encodeIfPresent(rows, forKey: .rows)
        try container.encode(appendNewline, forKey: .appendNewline)
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
