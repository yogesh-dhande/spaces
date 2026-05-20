import Foundation

public struct GhosttyRemoteSessionStatePayload: Codable, Sendable, Equatable {
    public let sessionID: String
    public let reason: String
    public let emittedAt: String
    public let runtimeState: TerminalSessionRuntimeState?
    public let attachmentSnapshot: TerminalSessionAttachmentSnapshot?
    public let title: String
    public let workingDirectory: String
    public let snapshot: GhosttyTerminalSnapshot?
    public let snapshotText: String?
    public let transcriptTail: String?
    public let outputByteCount: Int?

    public init(
        sessionID: String, reason: String, emittedAt: String, runtimeState: TerminalSessionRuntimeState?,
        attachmentSnapshot: TerminalSessionAttachmentSnapshot?, title: String, workingDirectory: String, snapshot: GhosttyTerminalSnapshot?,
        snapshotText: String?, transcriptTail: String?, outputByteCount: Int?
    ) {
        self.sessionID = sessionID
        self.reason = reason
        self.emittedAt = emittedAt
        self.runtimeState = runtimeState
        self.attachmentSnapshot = attachmentSnapshot
        self.title = title
        self.workingDirectory = workingDirectory
        self.snapshot = snapshot
        self.snapshotText = snapshotText
        self.transcriptTail = transcriptTail
        self.outputByteCount = outputByteCount
    }

    public func merged(with update: Self) -> Self {
        precondition(sessionID == update.sessionID, "Cannot merge terminal state from a different session.")
        return .init(
            sessionID: update.sessionID, reason: update.reason, emittedAt: update.emittedAt, runtimeState: update.runtimeState ?? runtimeState,
            attachmentSnapshot: update.attachmentSnapshot ?? attachmentSnapshot, title: update.title, workingDirectory: update.workingDirectory,
            snapshot: update.snapshot ?? snapshot, snapshotText: update.snapshotText ?? (update.snapshot != nil ? nil : snapshotText),
            transcriptTail: update.transcriptTail ?? transcriptTail, outputByteCount: update.outputByteCount)
    }
}

public enum GhosttyRemoteSessionStateCodec {
    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()

    public static func encodeLine(_ payload: GhosttyRemoteSessionStatePayload) throws -> Data {
        var data = try encoder.encode(payload)
        data.append(0x0A)
        return data
    }

    public static func decodeLine(_ data: Data) throws -> GhosttyRemoteSessionStatePayload {
        try decoder.decode(GhosttyRemoteSessionStatePayload.self, from: data)
    }
}

public enum GhosttyRemoteSessionStateTimestamp {
    public static func string(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    public static func date(from string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let parsed = formatter.date(from: string) { return parsed }
        return ISO8601DateFormatter().date(from: string)
    }
}
