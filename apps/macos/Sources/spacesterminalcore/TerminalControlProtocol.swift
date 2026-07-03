import Foundation

public struct TerminalControlRequest: Codable, Sendable, Equatable {
    public let command: String
    public let authToken: String?
    public let text: String?
    public let bytes: Data?
    public let key: String?
    public let clientID: String?
    public let client: TerminalClient?
    public let attachmentMode: TerminalAttachmentMode?
    public let lineCount: Int?
    public let columns: Int?
    public let rows: Int?
    public let ownerEpoch: UInt64?
    public let resizeSerial: UInt64?
    public let scrollHorizontal: Double?
    public let scrollVertical: Double?
    public let scrollMods: Int32?
    public let appendNewline: Bool
    /// The attaching client's OS appearance (light/dark). Carried on `attach` so a remote daemon can
    /// render its headless terminal session with the matching Spaces theme variant.
    public let appearance: ThemeAppearance?

    public init(
        command: String, authToken: String? = nil, text: String? = nil, bytes: Data? = nil, key: String? = nil, clientID: String? = nil,
        client: TerminalClient? = nil, attachmentMode: TerminalAttachmentMode? = nil, lineCount: Int? = nil, columns: Int? = nil, rows: Int? = nil,
        ownerEpoch: UInt64? = nil, resizeSerial: UInt64? = nil, scrollHorizontal: Double? = nil, scrollVertical: Double? = nil,
        scrollMods: Int32? = nil, appendNewline: Bool = false, appearance: ThemeAppearance? = nil
    ) {
        self.command = command
        self.authToken = authToken
        self.text = text
        self.bytes = bytes
        self.key = key
        self.clientID = clientID
        self.client = client
        self.attachmentMode = attachmentMode
        self.lineCount = lineCount
        self.columns = columns
        self.rows = rows
        self.ownerEpoch = ownerEpoch
        self.resizeSerial = resizeSerial
        self.scrollHorizontal = scrollHorizontal
        self.scrollVertical = scrollVertical
        self.scrollMods = scrollMods
        self.appendNewline = appendNewline
        self.appearance = appearance
    }

    private enum CodingKeys: String, CodingKey {
        case command
        case authToken
        case text
        case bytes
        case key
        case clientID
        case client
        case attachmentMode
        case lineCount
        case columns
        case rows
        case ownerEpoch
        case resizeSerial
        case scrollHorizontal
        case scrollVertical
        case scrollMods
        case appendNewline
        case appearance
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        command = try container.decode(String.self, forKey: .command)
        authToken = try container.decodeIfPresent(String.self, forKey: .authToken)
        text = try container.decodeIfPresent(String.self, forKey: .text)
        bytes = try container.decodeIfPresent(Data.self, forKey: .bytes)
        key = try container.decodeIfPresent(String.self, forKey: .key)
        clientID = try container.decodeIfPresent(String.self, forKey: .clientID)
        client = try container.decodeIfPresent(TerminalClient.self, forKey: .client)
        attachmentMode = try container.decodeIfPresent(TerminalAttachmentMode.self, forKey: .attachmentMode)
        lineCount = try container.decodeIfPresent(Int.self, forKey: .lineCount)
        columns = try container.decodeIfPresent(Int.self, forKey: .columns)
        rows = try container.decodeIfPresent(Int.self, forKey: .rows)
        ownerEpoch = try container.decodeIfPresent(UInt64.self, forKey: .ownerEpoch)
        resizeSerial = try container.decodeIfPresent(UInt64.self, forKey: .resizeSerial)
        scrollHorizontal = try container.decodeIfPresent(Double.self, forKey: .scrollHorizontal)
        scrollVertical = try container.decodeIfPresent(Double.self, forKey: .scrollVertical)
        scrollMods = try container.decodeIfPresent(Int32.self, forKey: .scrollMods)
        appendNewline = try container.decodeIfPresent(Bool.self, forKey: .appendNewline) ?? false
        appearance = try container.decodeIfPresent(ThemeAppearance.self, forKey: .appearance)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(command, forKey: .command)
        try container.encodeIfPresent(authToken, forKey: .authToken)
        try container.encodeIfPresent(text, forKey: .text)
        try container.encodeIfPresent(bytes, forKey: .bytes)
        try container.encodeIfPresent(key, forKey: .key)
        try container.encodeIfPresent(clientID, forKey: .clientID)
        try container.encodeIfPresent(client, forKey: .client)
        try container.encodeIfPresent(attachmentMode, forKey: .attachmentMode)
        try container.encodeIfPresent(lineCount, forKey: .lineCount)
        try container.encodeIfPresent(columns, forKey: .columns)
        try container.encodeIfPresent(rows, forKey: .rows)
        try container.encodeIfPresent(ownerEpoch, forKey: .ownerEpoch)
        try container.encodeIfPresent(resizeSerial, forKey: .resizeSerial)
        try container.encodeIfPresent(scrollHorizontal, forKey: .scrollHorizontal)
        try container.encodeIfPresent(scrollVertical, forKey: .scrollVertical)
        try container.encodeIfPresent(scrollMods, forKey: .scrollMods)
        try container.encode(appendNewline, forKey: .appendNewline)
        try container.encodeIfPresent(appearance, forKey: .appearance)
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

extension TerminalControlRequest {
    public var inputPayload: Data? {
        if let bytes { return bytes }
        if let text { return Data(text.utf8) }
        return nil
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
