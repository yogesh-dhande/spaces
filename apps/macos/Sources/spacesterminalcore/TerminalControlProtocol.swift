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
    public let scrollPointerX: Double?
    public let scrollPointerY: Double?
    public let scrollPointerMods: UInt32?
    public let appendNewline: Bool
    public let asPaste: Bool
    /// The attaching client's OS appearance (light/dark). Carried on `attach` so a remote daemon can
    /// render its headless terminal session with the matching Spaces theme variant.
    public let appearance: ThemeAppearance?

    public init(
        command: String, authToken: String? = nil, text: String? = nil, bytes: Data? = nil, key: String? = nil, clientID: String? = nil,
        client: TerminalClient? = nil, attachmentMode: TerminalAttachmentMode? = nil, lineCount: Int? = nil, columns: Int? = nil, rows: Int? = nil,
        ownerEpoch: UInt64? = nil, resizeSerial: UInt64? = nil, scrollHorizontal: Double? = nil, scrollVertical: Double? = nil,
        scrollMods: Int32? = nil, scrollPointerX: Double? = nil, scrollPointerY: Double? = nil, scrollPointerMods: UInt32? = nil,
        appendNewline: Bool = false, asPaste: Bool = false, appearance: ThemeAppearance? = nil
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
        self.scrollPointerX = scrollPointerX
        self.scrollPointerY = scrollPointerY
        self.scrollPointerMods = scrollPointerMods
        self.appendNewline = appendNewline
        self.asPaste = asPaste
        self.appearance = appearance
    }

    public init(command: TerminalControlCommand, authToken: String? = nil) {
        switch command {
        case .attach(let payload):
            self.init(
                command: command.name, authToken: authToken, client: payload.client, attachmentMode: payload.attachmentMode,
                appearance: payload.appearance)
        case .detach(let payload), .heartbeat(let payload), .takeover(let payload):
            self.init(command: command.name, authToken: authToken, clientID: payload.clientID)
        case .send(let payload):
            self.init(
                command: command.name, authToken: authToken, text: payload.text, bytes: payload.bytes, clientID: payload.clientID,
                ownerEpoch: payload.ownerEpoch, appendNewline: payload.appendNewline, asPaste: payload.asPaste)
        case .key(let payload):
            self.init(command: command.name, authToken: authToken, key: payload.key, clientID: payload.clientID, ownerEpoch: payload.ownerEpoch)
        case .clearScreen(let payload):
            self.init(command: command.name, authToken: authToken, clientID: payload.clientID, ownerEpoch: payload.ownerEpoch)
        case .resize(let payload):
            self.init(
                command: command.name, authToken: authToken, clientID: payload.clientID, columns: payload.columns, rows: payload.rows,
                ownerEpoch: payload.ownerEpoch, resizeSerial: payload.resizeSerial)
        case .scroll(let payload):
            self.init(
                command: command.name, authToken: authToken, clientID: payload.clientID, ownerEpoch: payload.ownerEpoch,
                scrollHorizontal: payload.scrollHorizontal, scrollVertical: payload.scrollVertical, scrollMods: payload.scrollMods,
                scrollPointerX: payload.scrollPointerX, scrollPointerY: payload.scrollPointerY, scrollPointerMods: payload.scrollPointerMods)
        case .setAppearance(let payload):
            self.init(command: command.name, authToken: authToken, clientID: payload.clientID, appearance: payload.appearance)
        case .unsupported(let name): self.init(command: name, authToken: authToken)
        }
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
        case scrollPointerX
        case scrollPointerY
        case scrollPointerMods
        case appendNewline
        case asPaste
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
        scrollPointerX = try container.decodeIfPresent(Double.self, forKey: .scrollPointerX)
        scrollPointerY = try container.decodeIfPresent(Double.self, forKey: .scrollPointerY)
        scrollPointerMods = try container.decodeIfPresent(UInt32.self, forKey: .scrollPointerMods)
        appendNewline = try container.decodeIfPresent(Bool.self, forKey: .appendNewline) ?? false
        asPaste = try container.decodeIfPresent(Bool.self, forKey: .asPaste) ?? false
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
        try container.encodeIfPresent(scrollPointerX, forKey: .scrollPointerX)
        try container.encodeIfPresent(scrollPointerY, forKey: .scrollPointerY)
        try container.encodeIfPresent(scrollPointerMods, forKey: .scrollPointerMods)
        try container.encode(appendNewline, forKey: .appendNewline)
        try container.encode(asPaste, forKey: .asPaste)
        try container.encodeIfPresent(appearance, forKey: .appearance)
    }
}

public struct TerminalControlAttachPayload: Sendable, Equatable {
    public let client: TerminalClient?
    public let attachmentMode: TerminalAttachmentMode?
    public let appearance: ThemeAppearance?

    public init(client: TerminalClient?, attachmentMode: TerminalAttachmentMode?, appearance: ThemeAppearance?) {
        self.client = client
        self.attachmentMode = attachmentMode
        self.appearance = appearance
    }
}

public struct TerminalControlClientPayload: Sendable, Equatable {
    public let clientID: String?

    public init(clientID: String?) { self.clientID = clientID }
}

public struct TerminalControlSendPayload: Sendable, Equatable {
    public let text: String?
    public let bytes: Data?
    public let clientID: String?
    public let ownerEpoch: UInt64?
    public let appendNewline: Bool
    public let asPaste: Bool

    public init(text: String?, bytes: Data?, clientID: String?, ownerEpoch: UInt64?, appendNewline: Bool, asPaste: Bool = false) {
        self.text = text
        self.bytes = bytes
        self.clientID = clientID
        self.ownerEpoch = ownerEpoch
        self.appendNewline = appendNewline
        self.asPaste = asPaste
    }

    public var inputPayload: Data? {
        if let bytes { return bytes }
        if let text { return Data(text.utf8) }
        return nil
    }
}

public struct TerminalControlKeyPayload: Sendable, Equatable {
    public let key: String?
    public let clientID: String?
    public let ownerEpoch: UInt64?

    public init(key: String?, clientID: String?, ownerEpoch: UInt64?) {
        self.key = key
        self.clientID = clientID
        self.ownerEpoch = ownerEpoch
    }
}

public struct TerminalControlOwnerPayload: Sendable, Equatable {
    public let clientID: String?
    public let ownerEpoch: UInt64?

    public init(clientID: String?, ownerEpoch: UInt64?) {
        self.clientID = clientID
        self.ownerEpoch = ownerEpoch
    }
}

public struct TerminalControlResizePayload: Sendable, Equatable {
    public let clientID: String?
    public let columns: Int?
    public let rows: Int?
    public let ownerEpoch: UInt64?
    public let resizeSerial: UInt64?

    public init(clientID: String?, columns: Int?, rows: Int?, ownerEpoch: UInt64?, resizeSerial: UInt64?) {
        self.clientID = clientID
        self.columns = columns
        self.rows = rows
        self.ownerEpoch = ownerEpoch
        self.resizeSerial = resizeSerial
    }
}

public struct TerminalControlSetAppearancePayload: Sendable, Equatable {
    /// The client requesting the appearance change. Carried for lease-touch/tracing only; appearance
    /// is deliberately not owner-gated (see the session core's handler).
    public let clientID: String?
    public let appearance: ThemeAppearance?

    public init(clientID: String?, appearance: ThemeAppearance?) {
        self.clientID = clientID
        self.appearance = appearance
    }
}

public struct TerminalControlScrollPayload: Sendable, Equatable {
    public let clientID: String?
    public let ownerEpoch: UInt64?
    public let scrollHorizontal: Double?
    public let scrollVertical: Double?
    public let scrollMods: Int32?
    public let scrollPointerX: Double?
    public let scrollPointerY: Double?
    public let scrollPointerMods: UInt32?

    public init(
        clientID: String?, ownerEpoch: UInt64?, scrollHorizontal: Double?, scrollVertical: Double?, scrollMods: Int32?, scrollPointerX: Double? = nil,
        scrollPointerY: Double? = nil, scrollPointerMods: UInt32? = nil
    ) {
        self.clientID = clientID
        self.ownerEpoch = ownerEpoch
        self.scrollHorizontal = scrollHorizontal
        self.scrollVertical = scrollVertical
        self.scrollMods = scrollMods
        self.scrollPointerX = scrollPointerX
        self.scrollPointerY = scrollPointerY
        self.scrollPointerMods = scrollPointerMods
    }
}

public enum TerminalControlCommand: Sendable, Equatable {
    case attach(TerminalControlAttachPayload)
    case detach(TerminalControlClientPayload)
    case heartbeat(TerminalControlClientPayload)
    case takeover(TerminalControlClientPayload)
    case send(TerminalControlSendPayload)
    case key(TerminalControlKeyPayload)
    case clearScreen(TerminalControlOwnerPayload)
    case resize(TerminalControlResizePayload)
    case scroll(TerminalControlScrollPayload)
    case setAppearance(TerminalControlSetAppearancePayload)
    case unsupported(String)

    public init(request: TerminalControlRequest) {
        switch request.command {
        case "attach":
            self = .attach(
                TerminalControlAttachPayload(client: request.client, attachmentMode: request.attachmentMode, appearance: request.appearance))
        case "detach": self = .detach(TerminalControlClientPayload(clientID: request.clientID))
        case "heartbeat": self = .heartbeat(TerminalControlClientPayload(clientID: request.clientID))
        case "takeover": self = .takeover(TerminalControlClientPayload(clientID: request.clientID))
        case "send":
            self = .send(
                TerminalControlSendPayload(
                    text: request.text, bytes: request.bytes, clientID: request.clientID, ownerEpoch: request.ownerEpoch,
                    appendNewline: request.appendNewline, asPaste: request.asPaste))
        case "key": self = .key(TerminalControlKeyPayload(key: request.key, clientID: request.clientID, ownerEpoch: request.ownerEpoch))
        case "clearScreen": self = .clearScreen(TerminalControlOwnerPayload(clientID: request.clientID, ownerEpoch: request.ownerEpoch))
        case "resize":
            self = .resize(
                TerminalControlResizePayload(
                    clientID: request.clientID, columns: request.columns, rows: request.rows, ownerEpoch: request.ownerEpoch,
                    resizeSerial: request.resizeSerial))
        case "scroll":
            self = .scroll(
                TerminalControlScrollPayload(
                    clientID: request.clientID, ownerEpoch: request.ownerEpoch, scrollHorizontal: request.scrollHorizontal,
                    scrollVertical: request.scrollVertical, scrollMods: request.scrollMods, scrollPointerX: request.scrollPointerX,
                    scrollPointerY: request.scrollPointerY, scrollPointerMods: request.scrollPointerMods))
        case "setAppearance": self = .setAppearance(TerminalControlSetAppearancePayload(clientID: request.clientID, appearance: request.appearance))
        default: self = .unsupported(request.command)
        }
    }

    public var name: String {
        switch self {
        case .attach: "attach"
        case .detach: "detach"
        case .heartbeat: "heartbeat"
        case .takeover: "takeover"
        case .send: "send"
        case .key: "key"
        case .clearScreen: "clearScreen"
        case .resize: "resize"
        case .scroll: "scroll"
        case .setAppearance: "setAppearance"
        case .unsupported(let name): name
        }
    }

    public var requiresOwnerClientID: Bool {
        switch self {
        case .send, .key, .clearScreen, .resize, .scroll: true
        // setAppearance is a per-client view preference, not an ownership-gated mutation.
        case .attach, .detach, .heartbeat, .takeover, .setAppearance, .unsupported: false
        }
    }

    /// The controls that change who is attached echo the resulting session state on the response. A client
    /// applies that state directly instead of following the control with a separate `.state` request, which
    /// costs a second round trip and a second full-frame export for a fact the daemon just computed. The
    /// input and view controls do not echo state: their effect reaches clients on the subscription's next
    /// broadcast.
    public var includesSessionStateOnSuccess: Bool {
        switch self {
        case .attach, .detach, .takeover: true
        case .heartbeat, .send, .key, .clearScreen, .resize, .scroll, .setAppearance, .unsupported: false
        }
    }

    public var requiredPayloadFailureMessage: String? {
        switch self {
        case .attach(let payload): payload.client == nil ? "Missing client payload." : nil
        case .detach(let payload), .heartbeat(let payload), .takeover(let payload): payload.clientID == nil ? "Missing client ID." : nil
        case .send(let payload): payload.inputPayload == nil ? "Missing input payload." : nil
        case .key(let payload): payload.key == nil ? "Unsupported terminal key." : nil
        case .resize(let payload):
            if let columns = payload.columns, let rows = payload.rows, columns > 0, rows > 0 { nil } else { "Missing terminal size." }
        case .setAppearance(let payload): payload.appearance == nil ? "Missing appearance." : nil
        case .clearScreen, .scroll, .unsupported: nil
        }
    }

    public static func isMobileTerminalControlName(_ name: String) -> Bool {
        switch name {
        case "attach", "detach", "heartbeat", "takeover", "send", "key", "clearScreen", "resize", "scroll", "setAppearance": true
        default: false
        }
    }
}

public struct TerminalControlResponse: Codable, Sendable, Equatable {
    public let ok: Bool
    public let message: String
    /// Machine-readable failure category. Nil on success and omitted from the wire when nil.
    public let errorCode: SpacesDeviceErrorCode?

    public init(ok: Bool, message: String, errorCode: SpacesDeviceErrorCode? = nil) {
        self.ok = ok
        self.message = message
        self.errorCode = errorCode
    }
}

extension TerminalControlRequest {
    public var commandValue: TerminalControlCommand { TerminalControlCommand(request: self) }

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
