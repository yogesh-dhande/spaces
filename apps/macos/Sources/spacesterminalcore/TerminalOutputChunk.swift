import Foundation

public struct TerminalOutputChunk: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let sessionID: String
    public let offset: Int64
    public let lineIndex: Int64
    public let bytes: Data
    public let createdAt: String

    public init(id: String = UUID().uuidString, sessionID: String, offset: Int64, lineIndex: Int64, bytes: Data, createdAt: String) {
        self.id = id
        self.sessionID = sessionID
        self.offset = offset
        self.lineIndex = lineIndex
        self.bytes = bytes
        self.createdAt = createdAt
    }
}
