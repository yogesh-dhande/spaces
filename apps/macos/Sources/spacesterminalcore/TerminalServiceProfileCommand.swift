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

    public init(projectID: String? = nil) { self.projectID = projectID }
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

public struct TerminalServiceWorkspaceLifecyclePayload: Codable, Sendable, Equatable {
    public let cwd: String
    public let workspaceID: String?

    public init(cwd: String, workspaceID: String? = nil) {
        self.cwd = cwd
        self.workspaceID = workspaceID
    }

    private enum CodingKeys: String, CodingKey { case cwd, workspaceID }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        cwd = try container.decodeRequiredNonEmpty(forKey: .cwd)
        workspaceID = normalizedNonEmpty(try container.decodeIfPresent(String.self, forKey: .workspaceID))
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

public struct TerminalServiceAgentListPayload: Codable, Sendable, Equatable {
    /// Optional workspace filter. `nil` (or an empty value the daemon normalizes away) lists agents
    /// across every workspace.
    public let workspaceID: String?
    /// Optional terminal-session filter, matched against each agent's terminal tracking id. Used for a
    /// single-agent `status` view and for readiness polling.
    public let sessionID: String?

    public init(workspaceID: String? = nil, sessionID: String? = nil) {
        self.workspaceID = workspaceID
        self.sessionID = sessionID
    }

    private enum CodingKeys: String, CodingKey {
        case workspaceID
        case sessionID
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        workspaceID = try container.decodeIfPresent(String.self, forKey: .workspaceID)
        sessionID = try container.decodeIfPresent(String.self, forKey: .sessionID)
    }
}

public struct TerminalServiceAgentAnnotatePayload: Codable, Sendable, Equatable {
    /// Terminal session / tracking id of the agent to annotate.
    public let sessionID: String
    /// The annotation to store. An empty string clears the note, so this field is required but not
    /// normalized-non-empty at the wire boundary.
    public let note: String

    public init(sessionID: String, note: String) {
        self.sessionID = sessionID
        self.note = note
    }

    private enum CodingKeys: String, CodingKey {
        case sessionID
        case note
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionID = try container.decodeRequiredNonEmpty(forKey: .sessionID)
        note = try container.decode(String.self, forKey: .note)
    }
}

public struct TerminalServiceAgentSpawnPayload: Codable, Sendable, Equatable {
    /// Working directory used to derive the owning workspace when `workspaceID` is omitted (the
    /// deepest workspace whose directory contains it), same rule as `terminalCommand`.
    public let cwd: String
    public let workspaceID: String?
    /// Shell command that launches the coding agent. Required and validated non-empty at decode; the
    /// daemon gates it against the supported-agent hook set (and their install state) before spawning.
    public let command: String
    public let title: String?

    public init(cwd: String, workspaceID: String? = nil, command: String, title: String? = nil) {
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
        command = try container.decodeRequiredNonEmpty(forKey: .command)
        title = try container.decodeIfPresent(String.self, forKey: .title)
    }
}

public struct TerminalServiceAgentKillPayload: Codable, Sendable, Equatable {
    /// Terminal session / tracking id of the agent to terminate.
    public let sessionID: String

    public init(sessionID: String) { self.sessionID = sessionID }

    private enum CodingKeys: String, CodingKey { case sessionID }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionID = try container.decodeRequiredNonEmpty(forKey: .sessionID)
    }
}

/// Persist-only subscription edge carried by `.agentSubscribe`/`.agentUnsubscribe`. `subscriberTerminalSessionID`
/// is the watching terminal. When `deviceID` is nil this is a same-device edge and `agentSessionID` is the
/// watched agent session **row** id (the CLI resolves the child's terminal session to its agent row before
/// sending). When `deviceID` is set this is a cross-device edge and `agentSessionID` is the child's
/// terminal session id on that device, which the daemon resolves to the remote agent row id (and validates
/// exists) via one `listAgentSessions` call before persisting the watch.
public struct TerminalServiceAgentSubscriptionPayload: Codable, Sendable, Equatable {
    public let subscriberTerminalSessionID: String
    public let agentSessionID: String
    public let deviceID: String?

    public init(subscriberTerminalSessionID: String, agentSessionID: String, deviceID: String? = nil) {
        self.subscriberTerminalSessionID = subscriberTerminalSessionID
        self.agentSessionID = agentSessionID
        self.deviceID = deviceID
    }

    private enum CodingKeys: String, CodingKey {
        case subscriberTerminalSessionID
        case agentSessionID
        case deviceID
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        subscriberTerminalSessionID = try container.decodeRequiredNonEmpty(forKey: .subscriberTerminalSessionID)
        agentSessionID = try container.decodeRequiredNonEmpty(forKey: .agentSessionID)
        deviceID = try container.decodeIfPresent(String.self, forKey: .deviceID).flatMap { value in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
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
    case workspaceStart(TerminalServiceWorkspaceLifecyclePayload)
    case workspaceRestart(TerminalServiceWorkspaceLifecyclePayload)
    case agentSignal(TerminalServiceProfileAgentSignalPayload)
    case agentList(TerminalServiceAgentListPayload)
    case agentAnnotate(TerminalServiceAgentAnnotatePayload)
    case agentSpawn(TerminalServiceAgentSpawnPayload)
    case agentKill(TerminalServiceAgentKillPayload)
    case agentSubscribe(TerminalServiceAgentSubscriptionPayload)
    case agentUnsubscribe(TerminalServiceAgentSubscriptionPayload)
    /// Atomically reads and deletes the pending child-agent notifications held for a subscriber terminal,
    /// returning the rendered blocks on the response's `pendingAgentEvents`. The MCP server issues this at
    /// its tools/call chokepoint so a busy orchestrator receives its watched children's held events; the
    /// idle-time injection path is unchanged.
    case agentConsumePendingEvents(subscriberTerminalSessionID: String)
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
        case agentList
        case agentAnnotate
        case agentSpawn
        case agentKill
        case agentSubscribe
        case agentUnsubscribe
        case agentConsumePendingEvents
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
        case .workspaceStart: self = .workspaceStart(try container.decode(TerminalServiceWorkspaceLifecyclePayload.self, forKey: key))
        case .workspaceRestart: self = .workspaceRestart(try container.decode(TerminalServiceWorkspaceLifecyclePayload.self, forKey: key))
        case .agentSignal: self = .agentSignal(try container.decode(TerminalServiceProfileAgentSignalPayload.self, forKey: key))
        case .agentList: self = .agentList(try container.decode(TerminalServiceAgentListPayload.self, forKey: key))
        case .agentAnnotate: self = .agentAnnotate(try container.decode(TerminalServiceAgentAnnotatePayload.self, forKey: key))
        case .agentSpawn: self = .agentSpawn(try container.decode(TerminalServiceAgentSpawnPayload.self, forKey: key))
        case .agentKill: self = .agentKill(try container.decode(TerminalServiceAgentKillPayload.self, forKey: key))
        case .agentSubscribe: self = .agentSubscribe(try container.decode(TerminalServiceAgentSubscriptionPayload.self, forKey: key))
        case .agentUnsubscribe: self = .agentUnsubscribe(try container.decode(TerminalServiceAgentSubscriptionPayload.self, forKey: key))
        case .agentConsumePendingEvents:
            self = .agentConsumePendingEvents(subscriberTerminalSessionID: try container.decodeRequiredNonEmpty(forKey: key))
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
        case .workspaceStart(let payload): try container.encode(payload, forKey: .workspaceStart)
        case .workspaceRestart(let payload): try container.encode(payload, forKey: .workspaceRestart)
        case .agentSignal(let payload): try container.encode(payload, forKey: .agentSignal)
        case .agentList(let payload): try container.encode(payload, forKey: .agentList)
        case .agentAnnotate(let payload): try container.encode(payload, forKey: .agentAnnotate)
        case .agentSpawn(let payload): try container.encode(payload, forKey: .agentSpawn)
        case .agentKill(let payload): try container.encode(payload, forKey: .agentKill)
        case .agentSubscribe(let payload): try container.encode(payload, forKey: .agentSubscribe)
        case .agentUnsubscribe(let payload): try container.encode(payload, forKey: .agentUnsubscribe)
        case .agentConsumePendingEvents(let subscriberTerminalSessionID):
            try container.encode(subscriberTerminalSessionID, forKey: .agentConsumePendingEvents)
        case .terminalSend(let payload): try container.encode(payload, forKey: .terminalSend)
        case .terminalTail(let payload): try container.encode(payload, forKey: .terminalTail)
        case .terminalCommand(let payload): try container.encode(payload, forKey: .terminalCommand)
        }
    }
}
