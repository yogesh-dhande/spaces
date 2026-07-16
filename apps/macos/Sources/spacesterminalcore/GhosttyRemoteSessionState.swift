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
    public let outputByteCount: Int?
    public let outputEndByteOffset: Int?
    public let renderUpdate: Data?

    public init(
        sessionID: String, reason: String, emittedAt: String, sessionStateRevision: UInt64?, sessionStateFlags: UInt32?, screenStateRevision: UInt64?,
        runtimeState: TerminalSessionRuntimeState?, attachmentSnapshot: TerminalSessionAttachmentSnapshot?, title: String, workingDirectory: String,
        outputByteCount: Int?, outputEndByteOffset: Int? = nil, renderUpdate: Data? = nil
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
        self.outputByteCount = outputByteCount
        self.outputEndByteOffset = outputEndByteOffset
        self.renderUpdate = renderUpdate
    }

    public func merged(with update: Self) -> Self {
        precondition(sessionID == update.sessionID, "Cannot merge terminal state from a different session.")
        let previousOwnerClientID = TerminalRemoteSessionStatePolicy.activeOwnerClientID(in: attachmentSnapshot)
        let nextOwnerClientID = TerminalRemoteSessionStatePolicy.activeOwnerClientID(in: update.attachmentSnapshot ?? attachmentSnapshot)
        let ownerChanged = update.attachmentSnapshot != nil && previousOwnerClientID != nextOwnerClientID
        let mergedRenderUpdate = update.renderUpdate ?? (ownerChanged ? nil : renderUpdate)
        return .init(
            sessionID: update.sessionID, reason: update.reason, emittedAt: update.emittedAt,
            sessionStateRevision: update.sessionStateRevision ?? sessionStateRevision,
            sessionStateFlags: update.sessionStateFlags ?? sessionStateFlags, screenStateRevision: update.screenStateRevision ?? screenStateRevision,
            runtimeState: update.runtimeState ?? runtimeState, attachmentSnapshot: update.attachmentSnapshot ?? attachmentSnapshot,
            title: update.title, workingDirectory: update.workingDirectory, outputByteCount: update.outputByteCount,
            outputEndByteOffset: update.outputEndByteOffset, renderUpdate: mergedRenderUpdate)
    }
}

extension GhosttyRemoteSessionStatePayload {
    public var decodedRenderUpdate: GhosttyRenderUpdate? {
        guard let renderUpdate else { return nil }
        return try? GhosttyRenderUpdateBinaryCodec.decode(renderUpdate)
    }

    public var renderSnapshot: GhosttyTerminalSnapshot? { decodedRenderUpdate?.fullFrame?.snapshot }

    public var renderText: String? {
        guard let snapshot = renderSnapshot else { return nil }
        return GhosttyTerminalSnapshotLayout.plainText(for: snapshot)
    }

    public var renderOwnerEpoch: UInt64? { decodedRenderUpdate?.ownerEpoch }

    public func replacingRenderUpdate(_ renderUpdate: Data?, screenStateRevision: UInt64? = nil) -> Self {
        .init(
            sessionID: sessionID, reason: reason, emittedAt: emittedAt, sessionStateRevision: sessionStateRevision,
            sessionStateFlags: sessionStateFlags, screenStateRevision: screenStateRevision ?? self.screenStateRevision, runtimeState: runtimeState,
            attachmentSnapshot: attachmentSnapshot, title: title, workingDirectory: workingDirectory, outputByteCount: outputByteCount,
            outputEndByteOffset: outputEndByteOffset, renderUpdate: renderUpdate)
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
    // ISO8601DateFormatter construction is expensive, and `string(from:)`/`date(from:)` run on
    // hot terminal state broadcast/parse paths across every module that emits or reads
    // `emittedAt` (spacesterminalghostty, spacesd, spacesui, ...). ISO8601DateFormatter is
    // documented thread-safe, so one shared instance per format is safe to reuse across
    // threads/tasks instead of allocating a fresh formatter per call.
    nonisolated(unsafe) private static let fractionalSecondsFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    // Fallback for legacy/foreign timestamps that lack fractional seconds.
    nonisolated(unsafe) private static let defaultFormatter = ISO8601DateFormatter()

    public static func string(from date: Date) -> String { fractionalSecondsFormatter.string(from: date) }

    public static func date(from string: String) -> Date? {
        if let parsed = fractionalSecondsFormatter.date(from: string) { return parsed }
        return defaultFormatter.date(from: string)
    }
}

/// Cached ISO8601 formatter for session runtime/attachment timestamps (`updatedAt`,
/// `attachedAt`, `detachedAt`, `transferredAt`, process `startedAt`/`createdAt`, terminal
/// client `connectedAt`) using the framework's default (whole-second) format. Deliberately
/// separate from `GhosttyRemoteSessionStateTimestamp` above, whose fractional-seconds format
/// is part of the remote session state wire format (see
/// `TerminalSessionPersistence.parseISO8601`'s doc comment) — the two must not be merged.
/// Shared by every module that depends on spacesterminalcore (spacesterminalghostty,
/// spacesterminalui, workspacecore) since several call sites sit on hot terminal-event paths.
public enum TerminalSessionTimestamp {
    nonisolated(unsafe) private static let formatter = ISO8601DateFormatter()

    public static func string(from date: Date) -> String { formatter.string(from: date) }
    public static func date(from string: String) -> Date? { formatter.date(from: string) }
}
