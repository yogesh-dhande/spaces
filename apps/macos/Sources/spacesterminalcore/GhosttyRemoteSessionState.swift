import Foundation

public struct GhosttyRemoteSessionStatePayload: Codable, Sendable, Equatable {
    public let sessionID: String
    public let reason: String
    public let emittedAt: String
    public let sessionStateRevision: UInt64?
    public let sessionStateFlags: UInt32?
    public let screenStateRevision: UInt64?
    public let runtimeState: TerminalSessionRuntimeState?
    public let attachmentSnapshot: TerminalSessionAttachmentSnapshot?
    public let title: String
    public let workingDirectory: String
    public let renderFrame: Data?
    public let outputByteCount: Int?
    public let outputEndByteOffset: Int?

    public init(
        sessionID: String, reason: String, emittedAt: String, sessionStateRevision: UInt64?, sessionStateFlags: UInt32?, screenStateRevision: UInt64?,
        runtimeState: TerminalSessionRuntimeState?, attachmentSnapshot: TerminalSessionAttachmentSnapshot?, title: String, workingDirectory: String,
        renderFrame: Data?, outputByteCount: Int?, outputEndByteOffset: Int? = nil
    ) {
        self.sessionID = sessionID
        self.reason = reason
        self.emittedAt = emittedAt
        self.sessionStateRevision = sessionStateRevision
        self.sessionStateFlags = sessionStateFlags
        self.screenStateRevision = screenStateRevision
        self.runtimeState = runtimeState
        self.attachmentSnapshot = attachmentSnapshot
        self.title = title
        self.workingDirectory = workingDirectory
        self.renderFrame = renderFrame
        self.outputByteCount = outputByteCount
        self.outputEndByteOffset = outputEndByteOffset
    }

    public func merged(with update: Self) -> Self {
        precondition(sessionID == update.sessionID, "Cannot merge terminal state from a different session.")
        let previousOwnerClientID = Self.activeOwnerClientID(in: attachmentSnapshot)
        let nextOwnerClientID = Self.activeOwnerClientID(in: update.attachmentSnapshot ?? attachmentSnapshot)
        let ownerChanged = update.attachmentSnapshot != nil && previousOwnerClientID != nextOwnerClientID
        let mergedRenderFrame = update.renderFrame ?? (ownerChanged ? nil : renderFrame)
        return .init(
            sessionID: update.sessionID, reason: update.reason, emittedAt: update.emittedAt,
            sessionStateRevision: update.sessionStateRevision ?? sessionStateRevision,
            sessionStateFlags: update.sessionStateFlags ?? sessionStateFlags, screenStateRevision: update.screenStateRevision ?? screenStateRevision,
            runtimeState: update.runtimeState ?? runtimeState, attachmentSnapshot: update.attachmentSnapshot ?? attachmentSnapshot,
            title: update.title, workingDirectory: update.workingDirectory, renderFrame: mergedRenderFrame, outputByteCount: update.outputByteCount,
            outputEndByteOffset: update.outputEndByteOffset)
    }

    private static func activeOwnerClientID(in snapshot: TerminalSessionAttachmentSnapshot?) -> String? {
        snapshot?.attachments.first { $0.mode == .owner && $0.detachedAt == nil }?.clientID
    }
}

extension GhosttyRemoteSessionStatePayload {
    public var decodedRenderFrame: GhosttyRenderFrame? {
        guard let renderFrame else { return nil }
        return try? GhosttyRenderFrame.decode(renderFrame)
    }

    public var renderFrameSnapshot: GhosttyTerminalSnapshot? { decodedRenderFrame?.snapshot }

    public var renderFrameText: String? {
        guard let snapshot = renderFrameSnapshot else { return nil }
        return GhosttyTerminalSnapshotLayout.plainText(for: snapshot)
    }

    public var renderFrameOwnerEpoch: UInt64? { decodedRenderFrame?.ownerEpoch }
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
