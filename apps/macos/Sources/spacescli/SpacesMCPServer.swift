import Foundation
import spacesterminalcore
import workspacecore

final class SpacesMCPStdioServer {
    private struct MCPToolDescriptor {
        let name: String
        let description: String
        let properties: [String: Any]
        let required: [String]
        let oneOf: [[String: Any]]
        let handler: (SpacesMCPStdioServer, [String: Any]) throws -> TerminalServiceProfileCommandResponse

        init(
            name: String, description: String, properties: [String: Any], required: [String], oneOf: [[String: Any]] = [],
            handler: @escaping (SpacesMCPStdioServer, [String: Any]) throws -> TerminalServiceProfileCommandResponse
        ) {
            self.name = name
            self.description = description
            self.properties = properties
            self.required = required
            self.oneOf = oneOf
            self.handler = handler
        }

        var definition: [String: Any] {
            SpacesMCPStdioServer.tool(name: name, description: description, properties: properties, required: required, oneOf: oneOf)
        }
    }

    private let input: FileHandle
    private let output: FileHandle
    private let encoder: JSONEncoder

    init(input: FileHandle = .standardInput, output: FileHandle = .standardOutput) {
        self.input = input
        self.output = output
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = encoder
    }

    func run() throws { while let data = try readMessage() { try handleMessage(data) } }

    private static func toolDescriptors() -> [MCPToolDescriptor] {
        [
            MCPToolDescriptor(name: "spaces_project_list", description: "List Spaces projects.", properties: [:], required: []) { _, _ in
                try TerminalService.sendProfileCommand(.init(operation: .projectList))
            },
            MCPToolDescriptor(
                name: "spaces_workspace_list", description: "List Spaces workspaces.",
                properties: ["project": stringSchema("Project ID filter."), "includeArchived": boolSchema("Include archived workspaces.")],
                required: []
            ) { server, arguments in
                try TerminalService.sendProfileCommand(
                    .init(
                        operation: .workspaceList, projectID: server.optionalString(arguments["project"]),
                        includeArchived: server.optionalBool(arguments["includeArchived"]) ?? false))
            },
            MCPToolDescriptor(
                name: "spaces_workspace_create", description: "Create a workspace on this device.",
                properties: [
                    "project": stringSchema("Project ID."), "branch": stringSchema("Workspace branch."),
                    "baseBranch": stringSchema("Base branch for new branch creation."),
                    "existingBranch": boolSchema("Use an existing branch instead of creating a new branch."),
                ], required: ["project", "branch"]
            ) { server, arguments in
                try TerminalService.sendProfileCommand(
                    .init(
                        operation: .workspaceCreate, projectID: try server.requiredString(arguments["project"], field: "project"),
                        branch: try server.requiredString(arguments["branch"], field: "branch"),
                        baseBranch: server.optionalString(arguments["baseBranch"]),
                        existingBranch: server.optionalBool(arguments["existingBranch"]) ?? false))
            },
            MCPToolDescriptor(
                name: "spaces_workspace_start", description: "Ensure a workspace is running.",
                properties: ["workspace": stringSchema("Workspace ID.")], required: ["workspace"]
            ) { server, arguments in
                try TerminalService.sendProfileCommand(
                    .init(operation: .workspaceStart, workspaceID: try server.requiredString(arguments["workspace"], field: "workspace")))
            },
            MCPToolDescriptor(
                name: "spaces_workspace_restart", description: "Force a full stop and relaunch for a workspace.",
                properties: ["workspace": stringSchema("Workspace ID.")], required: ["workspace"]
            ) { server, arguments in
                try TerminalService.sendProfileCommand(
                    .init(operation: .workspaceRestart, workspaceID: try server.requiredString(arguments["workspace"], field: "workspace")))
            },
            MCPToolDescriptor(name: "spaces_terminal_list", description: "List available Spaces terminal sessions.", properties: [:], required: []) {
                _, _ in try TerminalService.sendProfileCommand(.init(operation: .terminalList), timeout: 5)
            },
            MCPToolDescriptor(
                name: "spaces_terminal_tail", description: "Read recent output from an explicit Spaces terminal session.",
                properties: [
                    "session": stringSchema("Spaces terminal session ID."), "lines": intSchema("Number of output lines to read. Defaults to 20."),
                ], required: ["session"]
            ) { server, arguments in
                try TerminalService.sendProfileCommand(
                    .init(
                        operation: .terminalTail, terminalSessionID: try server.requiredString(arguments["session"], field: "session"),
                        lineCount: server.optionalInt(arguments["lines"])), timeout: 5)
            },
            MCPToolDescriptor(
                name: "spaces_terminal_send", description: "Send text or raw bytes to an explicit Spaces terminal session.",
                properties: [
                    "session": stringSchema("Spaces terminal session ID."),
                    "text": stringSchema("Text to send. Use an empty string with appendNewline to press Enter."),
                    "bytes": byteArraySchema("Raw byte values to send. Each value must be an integer from 0 through 255."),
                    "appendNewline": boolSchema("Append a newline after the payload."),
                ], required: ["session"], oneOf: [["required": ["text"]], ["required": ["bytes"]]]
            ) { server, arguments in
                let payload = try server.terminalInputPayload(from: arguments)
                return try TerminalService.sendProfileCommand(
                    .init(
                        operation: .terminalSend, terminalSessionID: try server.requiredString(arguments["session"], field: "session"),
                        terminalText: payload.text, terminalBytes: payload.bytes,
                        appendNewline: server.optionalBool(arguments["appendNewline"]) ?? false), timeout: 5)
            },
        ]
    }

    static func toolDefinitions() -> [[String: Any]] { toolDescriptors().map(\.definition) }

    private static func tool(name: String, description: String, properties: [String: Any], required: [String], oneOf: [[String: Any]] = [])
        -> [String: Any]
    {
        var inputSchema: [String: Any] = ["type": "object", "properties": properties, "required": required, "additionalProperties": false]
        if !oneOf.isEmpty { inputSchema["oneOf"] = oneOf }
        return ["name": name, "description": description, "inputSchema": inputSchema]
    }

    private static func stringSchema(_ description: String) -> [String: Any] { ["type": "string", "description": description] }

    private static func boolSchema(_ description: String) -> [String: Any] { ["type": "boolean", "description": description] }

    private static func intSchema(_ description: String) -> [String: Any] { ["type": "integer", "minimum": 1, "description": description] }

    private static func byteArraySchema(_ description: String) -> [String: Any] {
        ["type": "array", "items": ["type": "integer", "minimum": 0, "maximum": 255], "description": description]
    }

    private func handleMessage(_ data: Data) throws {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            try sendError(id: nil, code: -32700, message: "Invalid JSON-RPC message.")
            return
        }
        let id = object["id"]
        guard let method = object["method"] as? String else {
            try sendError(id: id, code: -32600, message: "Missing JSON-RPC method.")
            return
        }

        switch method {
        case "initialize":
            try sendResponse(
                id: id,
                result: [
                    "protocolVersion": "2024-11-05", "capabilities": ["tools": [:]], "serverInfo": ["name": "spaces", "version": AppVersion.current],
                ])
        case "notifications/initialized": return
        case "ping": try sendResponse(id: id, result: [:])
        case "tools/list": try sendResponse(id: id, result: ["tools": Self.toolDefinitions()])
        case "tools/call": try handleToolCall(id: id, params: object["params"] as? [String: Any])
        default: try sendError(id: id, code: -32601, message: "Unsupported MCP method '\(method)'.")
        }
    }

    private func handleToolCall(id: Any?, params: [String: Any]?) throws {
        do {
            guard let params else { throw MCPError.invalidArguments("Missing tool call parameters.") }
            let name = try requiredString(params["name"], field: "name")
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            let profileResponse = try callTool(name: name, arguments: arguments)
            try sendToolResult(id: id, text: try encodedText(profileResponse), isError: false)
        } catch { try sendToolResult(id: id, text: error.localizedDescription, isError: true) }
    }

    private func callTool(name: String, arguments: [String: Any]) throws -> TerminalServiceProfileCommandResponse {
        guard let descriptor = Self.toolDescriptors().first(where: { $0.name == name }) else {
            throw MCPError.invalidArguments("Unknown Spaces tool '\(name)'.")
        }
        return try descriptor.handler(self, arguments)
    }

    private func encodedText(_ response: TerminalServiceProfileCommandResponse) throws -> String {
        let data = try encoder.encode(response)
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private func requiredString(_ value: Any?, field: String) throws -> String {
        guard let string = optionalString(value) else { throw MCPError.invalidArguments("\(field) is required.") }
        return string
    }

    private func requiredRawString(_ value: Any?, field: String) throws -> String {
        guard let string = value as? String else { throw MCPError.invalidArguments("\(field) is required.") }
        return string
    }

    private func optionalString(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func optionalBool(_ value: Any?) -> Bool? {
        if let bool = value as? Bool { return bool }
        if let number = value as? NSNumber { return number.boolValue }
        return nil
    }

    private func optionalInt(_ value: Any?) -> Int? {
        if value is Bool { return nil }
        if let int = value as? Int { return int }
        if let number = value as? NSNumber {
            let double = number.doubleValue
            guard double.isFinite, double.rounded(.towardZero) == double else { return nil }
            return number.intValue
        }
        return nil
    }

    private func terminalInputPayload(from arguments: [String: Any]) throws -> (text: String?, bytes: Data?) {
        let textValue = arguments["text"]
        let bytesValue = arguments["bytes"]
        let hasText = textValue != nil
        let hasBytes = bytesValue != nil
        guard hasText || hasBytes else { throw MCPError.invalidArguments("text or bytes is required.") }
        guard !(hasText && hasBytes) else { throw MCPError.invalidArguments("Provide text or bytes, not both.") }
        if hasText { return (try requiredRawString(textValue, field: "text"), nil) }
        return (nil, try requiredBytes(bytesValue, field: "bytes"))
    }

    private func requiredBytes(_ value: Any?, field: String) throws -> Data {
        guard let values = value as? [Any] else { throw MCPError.invalidArguments("\(field) must be an array of byte values.") }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(values.count)
        for (index, value) in values.enumerated() {
            if value is Bool { throw MCPError.invalidArguments("\(field)[\(index)] must be an integer from 0 through 255.") }
            guard let byte = byteValue(value) else { throw MCPError.invalidArguments("\(field)[\(index)] must be an integer from 0 through 255.") }
            bytes.append(byte)
        }
        return Data(bytes)
    }

    private func byteValue(_ value: Any) -> UInt8? {
        if let int = value as? Int { return (0...255).contains(int) ? UInt8(int) : nil }
        guard let number = value as? NSNumber else { return nil }
        let double = number.doubleValue
        guard double.isFinite, double.rounded(.towardZero) == double else { return nil }
        let int = number.intValue
        return (0...255).contains(int) ? UInt8(int) : nil
    }

    private func sendToolResult(id: Any?, text: String, isError: Bool) throws {
        try sendResponse(id: id, result: ["content": [["type": "text", "text": text]], "isError": isError])
    }

    private func sendResponse(id: Any?, result: [String: Any]) throws {
        var response: [String: Any] = ["jsonrpc": "2.0", "result": result]
        response["id"] = id ?? NSNull()
        try writeJSONObject(response)
    }

    private func sendError(id: Any?, code: Int, message: String) throws {
        var response: [String: Any] = ["jsonrpc": "2.0", "error": ["code": code, "message": message]]
        response["id"] = id ?? NSNull()
        try writeJSONObject(response)
    }

    private func writeJSONObject(_ object: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: object)
        let header = "Content-Length: \(data.count)\r\n\r\n"
        output.write(Data(header.utf8))
        output.write(data)
    }

    private func readMessage() throws -> Data? {
        var header = Data()
        let crlfTerminator = Data("\r\n\r\n".utf8)
        let lfTerminator = Data("\n\n".utf8)
        while !data(header, hasSuffix: crlfTerminator), !data(header, hasSuffix: lfTerminator) {
            let byte = input.readData(ofLength: 1)
            if byte.isEmpty {
                if header.isEmpty { return nil }
                throw MCPError.invalidMessage("Unexpected EOF while reading MCP headers.")
            }
            header.append(byte)
        }
        guard let headerText = String(data: header, encoding: .utf8) else { throw MCPError.invalidMessage("MCP headers were not UTF-8.") }
        let length = try contentLength(from: headerText)
        let body = input.readData(ofLength: length)
        guard body.count == length else { throw MCPError.invalidMessage("Unexpected EOF while reading MCP body.") }
        return body
    }

    private func data(_ data: Data, hasSuffix suffix: Data) -> Bool {
        guard data.count >= suffix.count else { return false }
        return data.suffix(suffix.count).elementsEqual(suffix)
    }

    private func contentLength(from headerText: String) throws -> Int {
        for line in headerText.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            guard parts.count == 2, parts[0].lowercased() == "content-length" else { continue }
            if let length = Int(parts[1]), length >= 0 { return length }
        }
        throw MCPError.invalidMessage("Missing MCP Content-Length header.")
    }
}

private enum MCPError: LocalizedError {
    case invalidMessage(String)
    case invalidArguments(String)

    var errorDescription: String? {
        switch self {
        case .invalidMessage(let message), .invalidArguments(let message): message
        }
    }
}
