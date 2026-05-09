import Foundation

public enum TerminalAttachmentMode: String, Codable, Sendable, CaseIterable {
    case owner
    case viewer
}

public struct TerminalAttachment: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let sessionID: String
    public let clientID: String
    public let mode: TerminalAttachmentMode
    public let attachedAt: String
    public let detachedAt: String?

    public init(
        id: String = UUID().uuidString, sessionID: String, clientID: String, mode: TerminalAttachmentMode, attachedAt: String,
        detachedAt: String? = nil
    ) {
        self.id = id
        self.sessionID = sessionID
        self.clientID = clientID
        self.mode = mode
        self.attachedAt = attachedAt
        self.detachedAt = detachedAt
    }
}
