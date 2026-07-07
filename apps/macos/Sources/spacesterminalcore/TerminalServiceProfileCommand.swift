import Foundation

/// Trims surrounding whitespace and newlines and returns `nil` when nothing is left. This is the one
/// place the "empty-after-trim means missing" rule lives: the profile-command wire decode enforces
/// required fields with it, and the daemon, CLI, and E2E optional-argument helpers delegate to it so
/// argument normalization can't drift between layers.
public func normalizedNonEmpty(_ value: String?) -> String? {
    guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
    return trimmed
}

extension KeyedDecodingContainer {
    /// Decodes a required profile-command string and normalizes it (trim + reject empty). Enforcing
    /// requiredness at the wire boundary is what lets the daemon's `runProfileCommand` destructure
    /// non-optional payload fields instead of re-validating each argument.
    func decodeRequiredNonEmpty(forKey key: Key) throws -> String {
        let raw = try decode(String.self, forKey: key)
        guard let normalized = normalizedNonEmpty(raw) else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: codingPath + [key], debugDescription: "\(key.stringValue) must not be empty."))
        }
        return normalized
    }
}

/// Terminal input carried by `terminalSend`: exactly one of UTF-8 text or raw bytes. Making this a
/// one-key-tagged union means the text-xor-bytes rule is structural on the wire — a payload can carry
/// neither zero nor both — so no layer re-checks it after decode. `text` intentionally preserves the
/// empty string (an empty text with a trailing newline is how a caller "presses Enter").
public enum TerminalProfileInput: Codable, Sendable, Equatable {
    case text(String)
    case bytes(Data)

    private enum CodingKeys: String, CodingKey {
        case text
        case bytes
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard container.allKeys.count == 1, let key = container.allKeys.first else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Terminal input must contain exactly one of text or bytes."))
        }
        switch key {
        case .text: self = .text(try container.decode(String.self, forKey: .text))
        case .bytes: self = .bytes(try container.decode(Data.self, forKey: .bytes))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let text): try container.encode(text, forKey: .text)
        case .bytes(let bytes): try container.encode(bytes, forKey: .bytes)
        }
    }
}

public struct TerminalServiceWorkspaceListPayload: Codable, Sendable, Equatable {
    /// Optional project filter. `nil` (or an empty value the daemon normalizes away) lists every
    /// project's workspaces.
    public let projectID: String?
    public let includeArchived: Bool

    public init(projectID: String? = nil, includeArchived: Bool = false) {
        self.projectID = projectID
        self.includeArchived = includeArchived
    }
}

public struct TerminalServiceWorkspaceCreatePayload: Codable, Sendable, Equatable {
    public let projectID: String
    public let branch: String
    public let baseBranch: String?
    public let existingBranch: Bool

    public init(projectID: String, branch: String, baseBranch: String? = nil, existingBranch: Bool = false) {
        self.projectID = projectID
        self.branch = branch
        self.baseBranch = baseBranch
        self.existingBranch = existingBranch
    }

    private enum CodingKeys: String, CodingKey {
        case projectID
        case branch
        case baseBranch
        case existingBranch
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        projectID = try container.decodeRequiredNonEmpty(forKey: .projectID)
        branch = try container.decodeRequiredNonEmpty(forKey: .branch)
        baseBranch = try container.decodeIfPresent(String.self, forKey: .baseBranch)
        existingBranch = try container.decodeIfPresent(Bool.self, forKey: .existingBranch) ?? false
    }
}

public struct TerminalServiceProfileAgentSignalPayload: Codable, Sendable, Equatable {
    public let workspaceID: String
    public let terminalSessionID: String
    public let event: String

    public init(workspaceID: String, terminalSessionID: String, event: String) {
        self.workspaceID = workspaceID
        self.terminalSessionID = terminalSessionID
        self.event = event
    }

    private enum CodingKeys: String, CodingKey {
        case workspaceID
        case terminalSessionID
        case event
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        workspaceID = try container.decodeRequiredNonEmpty(forKey: .workspaceID)
        terminalSessionID = try container.decodeRequiredNonEmpty(forKey: .terminalSessionID)
        event = try container.decodeRequiredNonEmpty(forKey: .event)
    }
}

public struct TerminalServiceTerminalSendPayload: Codable, Sendable, Equatable {
    public let sessionID: String
    public let input: TerminalProfileInput
    public let appendNewline: Bool

    public init(sessionID: String, input: TerminalProfileInput, appendNewline: Bool = false) {
        self.sessionID = sessionID
        self.input = input
        self.appendNewline = appendNewline
    }

    private enum CodingKeys: String, CodingKey {
        case sessionID
        case input
        case appendNewline
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionID = try container.decodeRequiredNonEmpty(forKey: .sessionID)
        input = try container.decode(TerminalProfileInput.self, forKey: .input)
        appendNewline = try container.decodeIfPresent(Bool.self, forKey: .appendNewline) ?? false
    }
}

public struct TerminalServiceTerminalTailPayload: Codable, Sendable, Equatable {
    public let sessionID: String
    /// Number of trailing lines to read. `nil` lets the daemon apply its default (20).
    public let lineCount: Int?

    public init(sessionID: String, lineCount: Int? = nil) {
        self.sessionID = sessionID
        self.lineCount = lineCount
    }

    private enum CodingKeys: String, CodingKey {
        case sessionID
        case lineCount
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionID = try container.decodeRequiredNonEmpty(forKey: .sessionID)
        lineCount = try container.decodeIfPresent(Int.self, forKey: .lineCount)
    }
}

public struct TerminalServiceTerminalCommandPayload: Codable, Sendable, Equatable {
    /// Working directory used to derive the owning workspace when `workspaceID` is omitted (the
    /// deepest workspace whose directory contains it).
    public let cwd: String
    public let workspaceID: String?
    public let command: String?
    public let title: String?

    public init(cwd: String, workspaceID: String? = nil, command: String? = nil, title: String? = nil) {
        self.cwd = cwd
        self.workspaceID = workspaceID
        self.command = command
        self.title = title
    }

    private enum CodingKeys: String, CodingKey {
        case cwd
        case workspaceID
        case command
        case title
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        cwd = try container.decodeRequiredNonEmpty(forKey: .cwd)
        workspaceID = try container.decodeIfPresent(String.self, forKey: .workspaceID)
        command = try container.decodeIfPresent(String.self, forKey: .command)
        title = try container.decodeIfPresent(String.self, forKey: .title)
    }
}

/// Typed profile-command contract sent by grouped CLI commands and `spaces mcp` to the adjacent
/// `spacesd` over the profile service socket. One case per operation carries only that operation's
/// fields; required strings are enforced (trim + reject empty) at decode, so the daemon's
/// `runProfileCommand` destructures payloads directly rather than re-validating each field.
public enum TerminalServiceProfileCommand: Sendable, Equatable {
    case projectList
    case terminalList
    case workspaceList(TerminalServiceWorkspaceListPayload)
    case workspaceCreate(TerminalServiceWorkspaceCreatePayload)
    case workspaceStart(workspaceID: String)
    case workspaceRestart(workspaceID: String)
    case agentSignal(TerminalServiceProfileAgentSignalPayload)
    case terminalSend(TerminalServiceTerminalSendPayload)
    case terminalTail(TerminalServiceTerminalTailPayload)
    case terminalCommand(TerminalServiceTerminalCommandPayload)
}

extension TerminalServiceProfileCommand: Codable {
    private enum CodingKeys: String, CodingKey {
        case projectList
        case terminalList
        case workspaceList
        case workspaceCreate
        case workspaceStart
        case workspaceRestart
        case agentSignal
        case terminalSend
        case terminalTail
        case terminalCommand
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard container.allKeys.count == 1, let key = container.allKeys.first else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Profile command must contain exactly one payload."))
        }
        switch key {
        case .projectList:
            _ = try container.decode(TerminalServiceEmptyPayload.self, forKey: key)
            self = .projectList
        case .terminalList:
            _ = try container.decode(TerminalServiceEmptyPayload.self, forKey: key)
            self = .terminalList
        case .workspaceList: self = .workspaceList(try container.decode(TerminalServiceWorkspaceListPayload.self, forKey: key))
        case .workspaceCreate: self = .workspaceCreate(try container.decode(TerminalServiceWorkspaceCreatePayload.self, forKey: key))
        case .workspaceStart: self = .workspaceStart(workspaceID: try container.decodeRequiredNonEmpty(forKey: key))
        case .workspaceRestart: self = .workspaceRestart(workspaceID: try container.decodeRequiredNonEmpty(forKey: key))
        case .agentSignal: self = .agentSignal(try container.decode(TerminalServiceProfileAgentSignalPayload.self, forKey: key))
        case .terminalSend: self = .terminalSend(try container.decode(TerminalServiceTerminalSendPayload.self, forKey: key))
        case .terminalTail: self = .terminalTail(try container.decode(TerminalServiceTerminalTailPayload.self, forKey: key))
        case .terminalCommand: self = .terminalCommand(try container.decode(TerminalServiceTerminalCommandPayload.self, forKey: key))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .projectList: try container.encode(TerminalServiceEmptyPayload(), forKey: .projectList)
        case .terminalList: try container.encode(TerminalServiceEmptyPayload(), forKey: .terminalList)
        case .workspaceList(let payload): try container.encode(payload, forKey: .workspaceList)
        case .workspaceCreate(let payload): try container.encode(payload, forKey: .workspaceCreate)
        case .workspaceStart(let workspaceID): try container.encode(workspaceID, forKey: .workspaceStart)
        case .workspaceRestart(let workspaceID): try container.encode(workspaceID, forKey: .workspaceRestart)
        case .agentSignal(let payload): try container.encode(payload, forKey: .agentSignal)
        case .terminalSend(let payload): try container.encode(payload, forKey: .terminalSend)
        case .terminalTail(let payload): try container.encode(payload, forKey: .terminalTail)
        case .terminalCommand(let payload): try container.encode(payload, forKey: .terminalCommand)
        }
    }
}
