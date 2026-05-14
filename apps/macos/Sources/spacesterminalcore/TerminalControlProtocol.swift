import Foundation

public struct TerminalSessionHostSnapshot: Codable, Sendable, Equatable {
    public let launchConfiguration: TerminalSessionLaunchConfiguration?
    public let runtimeState: TerminalSessionRuntimeState?
    public let attachmentSnapshot: TerminalSessionAttachmentSnapshot?
    public let recentOutput: String
    public let outputByteCount: Int64

    public init(
        launchConfiguration: TerminalSessionLaunchConfiguration?, runtimeState: TerminalSessionRuntimeState?,
        attachmentSnapshot: TerminalSessionAttachmentSnapshot?, recentOutput: String, outputByteCount: Int64
    ) {
        self.launchConfiguration = launchConfiguration
        self.runtimeState = runtimeState
        self.attachmentSnapshot = attachmentSnapshot
        self.recentOutput = recentOutput
        self.outputByteCount = outputByteCount
    }
}

public struct TerminalControlRequest: Codable, Sendable, Equatable {
    public let command: String
    public let authToken: String?
    public let text: String?
    public let key: String?
    public let clientID: String?
    public let client: TerminalClient?
    public let attachmentMode: TerminalAttachmentMode?
    public let appendNewline: Bool
    public let columns: Int?
    public let rows: Int?
    public let offset: Int64?
    public let maximumBytes: Int?
    public let recentOutputLineCount: Int?

    public init(
        command: String, authToken: String? = nil, text: String? = nil, key: String? = nil, clientID: String? = nil, client: TerminalClient? = nil,
        attachmentMode: TerminalAttachmentMode? = nil, appendNewline: Bool = false, columns: Int? = nil, rows: Int? = nil, offset: Int64? = nil,
        maximumBytes: Int? = nil, recentOutputLineCount: Int? = nil
    ) {
        self.command = command
        self.authToken = authToken
        self.text = text
        self.key = key
        self.clientID = clientID
        self.client = client
        self.attachmentMode = attachmentMode
        self.appendNewline = appendNewline
        self.columns = columns
        self.rows = rows
        self.offset = offset
        self.maximumBytes = maximumBytes
        self.recentOutputLineCount = recentOutputLineCount
    }

    enum CodingKeys: String, CodingKey {
        case command
        case authToken
        case text
        case key
        case clientID
        case client
        case attachmentMode
        case appendNewline
        case columns
        case rows
        case offset
        case maximumBytes
        case recentOutputLineCount
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
        appendNewline = try container.decodeIfPresent(Bool.self, forKey: .appendNewline) ?? false
        columns = try container.decodeIfPresent(Int.self, forKey: .columns)
        rows = try container.decodeIfPresent(Int.self, forKey: .rows)
        offset = try container.decodeIfPresent(Int64.self, forKey: .offset)
        maximumBytes = try container.decodeIfPresent(Int.self, forKey: .maximumBytes)
        recentOutputLineCount = try container.decodeIfPresent(Int.self, forKey: .recentOutputLineCount)
    }
}

public struct TerminalControlResponse: Codable, Sendable, Equatable {
    public let ok: Bool
    public let message: String
    public let snapshot: TerminalSessionHostSnapshot?
    public let outputChunk: TerminalOutputChunk?
    public let outputByteCount: Int64?

    public init(
        ok: Bool, message: String, snapshot: TerminalSessionHostSnapshot? = nil, outputChunk: TerminalOutputChunk? = nil,
        outputByteCount: Int64? = nil
    ) {
        self.ok = ok
        self.message = message
        self.snapshot = snapshot
        self.outputChunk = outputChunk
        self.outputByteCount = outputByteCount
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
