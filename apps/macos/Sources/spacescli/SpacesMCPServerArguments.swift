import Foundation
import spacesterminalcore

/// One JSON-RPC tool call's decoded arguments, typed per `spaces_*` MCP tool. Each `MCPToolDescriptor`
/// handler in `SpacesMCPServer.swift` used to receive the raw `[String: Any]` `arguments` object and pick
/// fields out by string key inline; these structs replace that with a `Decodable` type per tool, decoded
/// once via `decodeMCPArguments(_:from:)` at the top of each handler.
///
/// The prior `[String: Any]` extraction was deliberately lenient in ways that are easy to lose in a
/// straight port to `Decodable`, so each converter below documents the specific leniency it reproduces:
/// a wrong-shaped value for an optional field reads as absent rather than as an error, a string field is
/// trimmed and an empty result reads as absent, a boolean field also accepts a JSON number (nonzero ==
/// true), and an integer field silently drops a non-integral or boolean value instead of erroring.
/// `MCPArgumentValue` exists to make that possible: it mirrors the dynamic shapes `JSONSerialization`
/// would have handed back (string, bool, number, array), so the converters can match on it the same way
/// the old code matched on `Any` with `as?`, while still going through real `Decodable` conformance.
enum MCPArgumentValue: Decodable {
    case string(String)
    case bool(Bool)
    case number(Double)
    case array([MCPArgumentValue])
    /// Any other JSON shape (an object, or one nested inside an array) decodes successfully into this
    /// case instead of throwing, so a field of unexpected shape falls through the converters below to
    /// their nil/error path exactly like `value as? String` returning nil for a non-string `Any` did —
    /// old `[String: Any]` extraction never failed a decode outright over one field's dynamic type.
    case other

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
        } else if let number = try? container.decode(Double.self) {
            self = .number(number)
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else if let array = try? container.decode([MCPArgumentValue].self) {
            self = .array(array)
        } else {
            self = .other
        }
    }
}

/// A trimmed, non-empty string, or nil for a missing/null/empty/wrong-typed value — the `optionalString`
/// leniency the pre-refactor `[String: Any]` extraction applied to every string argument.
private func lenientOptionalString(_ value: MCPArgumentValue?) -> String? {
    guard case .string(let string) = value else { return nil }
    let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}

/// A JSON boolean, or a JSON number read as nonzero == true (the old `NSNumber.boolValue` coercion) —
/// nil for anything else, including a missing/null value.
private func lenientOptionalBool(_ value: MCPArgumentValue?) -> Bool? {
    switch value {
    case .bool(let bool): return bool
    case .number(let number): return number != 0
    default: return nil
    }
}

/// A JSON number with no fractional part as an `Int`, or nil for anything else (a boolean, a fractional
/// number, an out-of-range number, or a missing/null value) — the `optionalInt` leniency of silently
/// dropping a malformed value instead of erroring.
private func lenientOptionalInt(_ value: MCPArgumentValue?) -> Int? {
    guard case .number(let double) = value, double.isFinite, double.rounded(.towardZero) == double else { return nil }
    return Int(exactly: double)
}

/// An array of byte values (0 through 255, no fractional part) as `Data`, or an `MCPError` naming the
/// field and offending index — the `requiredBytes`/`byteValue` leniency. A JSON boolean array element
/// falls to `.bool` above, never `.number`, so it is rejected by the same guard as any other wrong type.
private func lenientBytes(_ value: MCPArgumentValue?, field: String) throws -> Data {
    guard case .array(let values) = value else { throw MCPError.invalidArguments("\(field) must be an array of byte values.") }
    var bytes: [UInt8] = []
    bytes.reserveCapacity(values.count)
    for (index, item) in values.enumerated() {
        guard case .number(let double) = item, double.isFinite, double.rounded(.towardZero) == double, (0...255).contains(double) else {
            throw MCPError.invalidArguments("\(field)[\(index)] must be an integer from 0 through 255.")
        }
        bytes.append(UInt8(double))
    }
    return Data(bytes)
}

/// Applies the `requiredString` "missing" contract to an already-decoded, already-leniency-processed
/// optional field. Used instead of a decode-time required check on `spaces_terminal_send`'s `session`,
/// because the pre-refactor handler resolved `text`/`bytes` before checking `session`, and a struct's
/// `init(from:)` decodes its fields in one atomic pass — deferring the check to the handler, after
/// `TerminalInputArguments.resolvedInput()` runs, preserves which error wins when both are missing.
func mcpRequired(_ value: String?, field: String) throws -> String {
    guard let value else { throw MCPError.invalidArguments("\(field) is required.") }
    return value
}

extension KeyedDecodingContainer {
    fileprivate func mcpOptionalString(forKey key: Key) throws -> String? {
        lenientOptionalString(try decodeIfPresent(MCPArgumentValue.self, forKey: key))
    }

    /// `mcpOptionalString`, throwing `MCPError.invalidArguments("<field> is required.")` when absent —
    /// the `requiredString` leniency, where a wrong-typed or empty value reads as "missing" rather than
    /// as a type error.
    fileprivate func mcpRequiredString(forKey key: Key, field: String) throws -> String {
        guard let string = try mcpOptionalString(forKey: key) else { throw MCPError.invalidArguments("\(field) is required.") }
        return string
    }

    /// The exact string value with no trimming or empty-to-nil collapsing — the `requiredRawString`
    /// leniency used where an empty string is itself a meaningful, valid value (an agent note cleared to
    /// empty) rather than "absent".
    fileprivate func mcpRequiredRawString(forKey key: Key, field: String) throws -> String {
        guard case .string(let string) = try decodeIfPresent(MCPArgumentValue.self, forKey: key) else {
            throw MCPError.invalidArguments("\(field) is required.")
        }
        return string
    }

    fileprivate func mcpOptionalBool(forKey key: Key) throws -> Bool? {
        lenientOptionalBool(try decodeIfPresent(MCPArgumentValue.self, forKey: key))
    }

    fileprivate func mcpOptionalInt(forKey key: Key) throws -> Int? {
        lenientOptionalInt(try decodeIfPresent(MCPArgumentValue.self, forKey: key))
    }
}

/// Decodes one tool's typed arguments from the raw JSON-RPC `arguments` object. Re-serializes the
/// already-parsed `[String: Any]` (parsed once, in `SpacesMCPStdioServer.handleMessage`) back to `Data`
/// and decodes that through `JSONDecoder`, rather than hand-walking the dictionary — a free function
/// (not a method) so it is callable the same way from every tool handler and directly from tests.
func decodeMCPArguments<T: Decodable>(_ type: T.Type, from arguments: [String: Any]) throws -> T {
    let data = try JSONSerialization.data(withJSONObject: arguments)
    return try JSONDecoder().decode(T.self, from: data)
}

// MARK: - spaces_project_list / spaces_workspace_list

struct ProjectListArguments: Decodable {
    let device: String?

    private enum CodingKeys: String, CodingKey { case device }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        device = try container.mcpOptionalString(forKey: .device)
    }
}

struct WorkspaceListArguments: Decodable {
    let project: String?
    let device: String?

    private enum CodingKeys: String, CodingKey { case project, device }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        project = try container.mcpOptionalString(forKey: .project)
        device = try container.mcpOptionalString(forKey: .device)
    }
}

// MARK: - spaces_workspace_create / spaces_workspace_start / spaces_workspace_restart

struct WorkspaceCreateArguments: Decodable {
    let project: String
    let branch: String
    let baseBranch: String?
    let existingBranch: Bool?
    let device: String?

    private enum CodingKeys: String, CodingKey { case project, branch, baseBranch, existingBranch, device }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        project = try container.mcpRequiredString(forKey: .project, field: "project")
        branch = try container.mcpRequiredString(forKey: .branch, field: "branch")
        baseBranch = try container.mcpOptionalString(forKey: .baseBranch)
        existingBranch = try container.mcpOptionalBool(forKey: .existingBranch)
        device = try container.mcpOptionalString(forKey: .device)
    }
}

struct WorkspaceStartArguments: Decodable {
    let workspace: String
    let device: String?

    private enum CodingKeys: String, CodingKey { case workspace, device }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        workspace = try container.mcpRequiredString(forKey: .workspace, field: "workspace")
        device = try container.mcpOptionalString(forKey: .device)
    }
}

struct WorkspaceRestartArguments: Decodable {
    let workspace: String
    let device: String?

    private enum CodingKeys: String, CodingKey { case workspace, device }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        workspace = try container.mcpRequiredString(forKey: .workspace, field: "workspace")
        device = try container.mcpOptionalString(forKey: .device)
    }
}

// MARK: - spaces_terminal_list / spaces_terminal_tail / spaces_terminal_send

struct TerminalListArguments: Decodable {
    let device: String?

    private enum CodingKeys: String, CodingKey { case device }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        device = try container.mcpOptionalString(forKey: .device)
    }
}

struct TerminalTailArguments: Decodable {
    let session: String
    let lines: Int?
    let device: String?

    private enum CodingKeys: String, CodingKey { case session, lines, device }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        session = try container.mcpRequiredString(forKey: .session, field: "session")
        lines = try container.mcpOptionalInt(forKey: .lines)
        device = try container.mcpOptionalString(forKey: .device)
    }
}

/// The `text`/`bytes` half of `spaces_terminal_send`'s arguments, decoded standalone (independent of
/// `session`/`submit`/`device`) so the oneOf resolution is unit-testable on its own — the typed
/// replacement for the pre-refactor `terminalInputPayload(from:)` helper.
struct TerminalInputArguments: Decodable {
    private let hasText: Bool
    private let hasBytes: Bool
    private let textValue: MCPArgumentValue?
    private let bytesValue: MCPArgumentValue?

    private enum CodingKeys: String, CodingKey { case text, bytes }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // `contains` is true whenever the JSON key is present at all, including an explicit `null` value
        // — matching the pre-refactor dictionary check `arguments["text"] != nil`, which was also true
        // for an explicit null (`JSONSerialization` represents JSON `null` as `NSNull()`, not a missing
        // key). `decodeIfPresent` below collapses "absent" and "present but null" to the same nil, which
        // is right for the *value*, but presence for the oneOf check below must not conflate the two.
        hasText = container.contains(.text)
        hasBytes = container.contains(.bytes)
        textValue = try container.decodeIfPresent(MCPArgumentValue.self, forKey: .text)
        bytesValue = try container.decodeIfPresent(MCPArgumentValue.self, forKey: .bytes)
    }

    /// Resolves the typed xor input the wire's untyped `text`/`bytes` arguments must encode: exactly one
    /// of the two keys must be present.
    func resolvedInput() throws -> TerminalProfileInput {
        guard hasText || hasBytes else { throw MCPError.invalidArguments("text or bytes is required.") }
        guard !(hasText && hasBytes) else { throw MCPError.invalidArguments("Provide text or bytes, not both.") }
        if hasText {
            guard case .string(let string) = textValue else { throw MCPError.invalidArguments("text is required.") }
            return .text(string)
        }
        return .bytes(try lenientBytes(bytesValue, field: "bytes"))
    }
}

struct TerminalSendArguments: Decodable {
    /// Optional here (unlike every other required "session" field) so decoding never fails before the
    /// handler can resolve `input` first — see `mcpRequired`'s doc comment for why the order matters.
    let session: String?
    let submit: Bool?
    let device: String?
    let input: TerminalInputArguments

    private enum CodingKeys: String, CodingKey { case session, submit, device }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        session = try container.mcpOptionalString(forKey: .session)
        submit = try container.mcpOptionalBool(forKey: .submit)
        device = try container.mcpOptionalString(forKey: .device)
        input = try TerminalInputArguments(from: decoder)
    }
}

// MARK: - spaces_agent_list / spaces_agent_status / spaces_agent_annotate

struct AgentListArguments: Decodable {
    let workspace: String?
    let device: String?

    private enum CodingKeys: String, CodingKey { case workspace, device }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        workspace = try container.mcpOptionalString(forKey: .workspace)
        device = try container.mcpOptionalString(forKey: .device)
    }
}

struct AgentStatusArguments: Decodable {
    let session: String?
    let device: String?

    private enum CodingKeys: String, CodingKey { case session, device }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        session = try container.mcpOptionalString(forKey: .session)
        device = try container.mcpOptionalString(forKey: .device)
    }
}

struct AgentAnnotateArguments: Decodable {
    let note: String
    let session: String?
    let device: String?

    private enum CodingKeys: String, CodingKey { case note, session, device }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Decoded before `session`/`device` so a missing `note` throws first, matching the pre-refactor
        // handler's order (`requiredRawString` before `resolvedAgentSessionID`).
        note = try container.mcpRequiredRawString(forKey: .note, field: "note")
        session = try container.mcpOptionalString(forKey: .session)
        device = try container.mcpOptionalString(forKey: .device)
    }
}

// MARK: - spaces_agent_spawn / spaces_agent_kill

struct AgentSpawnArguments: Decodable {
    let command: String
    let workspace: String?
    let title: String?
    let timeout: Int?
    let device: String?

    private enum CodingKeys: String, CodingKey { case command, workspace, title, timeout, device }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        command = try container.mcpRequiredString(forKey: .command, field: "command")
        workspace = try container.mcpOptionalString(forKey: .workspace)
        title = try container.mcpOptionalString(forKey: .title)
        timeout = try container.mcpOptionalInt(forKey: .timeout)
        device = try container.mcpOptionalString(forKey: .device)
    }
}

struct AgentKillArguments: Decodable {
    let session: String
    let device: String?

    private enum CodingKeys: String, CodingKey { case session, device }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        session = try container.mcpRequiredString(forKey: .session, field: "session")
        device = try container.mcpOptionalString(forKey: .device)
    }
}

// MARK: - spaces_agent_subscribe / spaces_agent_unsubscribe

struct AgentSubscribeArguments: Decodable {
    let session: String
    let subscriber: String?
    let device: String?

    private enum CodingKeys: String, CodingKey { case session, subscriber, device }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        session = try container.mcpRequiredString(forKey: .session, field: "session")
        subscriber = try container.mcpOptionalString(forKey: .subscriber)
        device = try container.mcpOptionalString(forKey: .device)
    }
}

struct AgentUnsubscribeArguments: Decodable {
    let session: String
    let subscriber: String?
    let device: String?

    private enum CodingKeys: String, CodingKey { case session, subscriber, device }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        session = try container.mcpRequiredString(forKey: .session, field: "session")
        subscriber = try container.mcpOptionalString(forKey: .subscriber)
        device = try container.mcpOptionalString(forKey: .device)
    }
}
