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
    /// The render update, in whichever form its producer holds it: wire bytes for a payload that arrived
    /// over a wire or came off disk, the decoded update for one a client materialized (see
    /// `GhosttyRenderUpdateBody`). `renderUpdate` and `decodedRenderUpdate` read whichever side the
    /// caller needs; only `renderUpdate` can cost an encode.
    private let renderUpdateBody: GhosttyRenderUpdateBody?
    /// A one-shot OSC 52 clipboard write for the session's owner, present only on a
    /// `clipboard_write` payload. Every carry-forward below drops it on purpose (see `merged(with:)`),
    /// so a client applies it exactly once, on the payload that announced it.
    public let clipboardWrite: TerminalClipboardWritePayload?

    public init(
        sessionID: String, reason: String, emittedAt: String, sessionStateRevision: UInt64?, sessionStateFlags: UInt32?, screenStateRevision: UInt64?,
        runtimeState: TerminalSessionRuntimeState?, attachmentSnapshot: TerminalSessionAttachmentSnapshot?, title: String, workingDirectory: String,
        outputByteCount: Int?, outputEndByteOffset: Int? = nil, renderUpdate: Data? = nil, clipboardWrite: TerminalClipboardWritePayload? = nil
    ) {
        self.init(
            sessionID: sessionID, reason: reason, emittedAt: emittedAt, sessionStateRevision: sessionStateRevision,
            sessionStateFlags: sessionStateFlags, screenStateRevision: screenStateRevision, runtimeState: runtimeState,
            attachmentSnapshot: attachmentSnapshot, title: title, workingDirectory: workingDirectory, outputByteCount: outputByteCount,
            outputEndByteOffset: outputEndByteOffset, renderUpdateBody: renderUpdate.map(GhosttyRenderUpdateBody.init(encoded:)),
            clipboardWrite: clipboardWrite)
    }

    private init(
        sessionID: String, reason: String, emittedAt: String, sessionStateRevision: UInt64?, sessionStateFlags: UInt32?, screenStateRevision: UInt64?,
        runtimeState: TerminalSessionRuntimeState?, attachmentSnapshot: TerminalSessionAttachmentSnapshot?, title: String, workingDirectory: String,
        outputByteCount: Int?, outputEndByteOffset: Int?, renderUpdateBody: GhosttyRenderUpdateBody?, clipboardWrite: TerminalClipboardWritePayload?
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
        self.renderUpdateBody = renderUpdateBody
        self.clipboardWrite = clipboardWrite
    }

    /// The render update's wire bytes. A payload carrying a materialized update encodes here, so read
    /// `hasRenderUpdate` when only presence matters and `decodedRenderUpdate` when the value does.
    public var renderUpdate: Data? { renderUpdateBody?.encodedData }

    /// Whether the payload carries a render update, without decoding or encoding one.
    public var hasRenderUpdate: Bool { renderUpdateBody != nil }

    /// Folds an incoming payload onto the client's stored state. Every field here is carried forward
    /// when the update omits it — EXCEPT `clipboardWrite`, which is deliberately absent from the
    /// result: it is a one-shot event, not state. Inheriting it would make every later payload look
    /// like a fresh clipboard write and re-paste over the user's clipboard on each output turn.
    public func merged(with update: Self) -> Self {
        precondition(sessionID == update.sessionID, "Cannot merge terminal state from a different session.")
        let previousOwnerClientID = TerminalRemoteSessionStatePolicy.activeOwnerClientID(in: attachmentSnapshot)
        let nextOwnerClientID = TerminalRemoteSessionStatePolicy.activeOwnerClientID(in: update.attachmentSnapshot ?? attachmentSnapshot)
        let ownerChanged = update.attachmentSnapshot != nil && previousOwnerClientID != nextOwnerClientID
        // The body is carried by reference, so a metadata-only update inherits the stored screen state
        // without re-encoding or re-decoding it.
        let mergedRenderUpdateBody = update.renderUpdateBody ?? (ownerChanged ? nil : renderUpdateBody)
        return .init(
            sessionID: update.sessionID, reason: update.reason, emittedAt: update.emittedAt,
            sessionStateRevision: update.sessionStateRevision ?? sessionStateRevision,
            sessionStateFlags: update.sessionStateFlags ?? sessionStateFlags, screenStateRevision: update.screenStateRevision ?? screenStateRevision,
            runtimeState: update.runtimeState ?? runtimeState, attachmentSnapshot: update.attachmentSnapshot ?? attachmentSnapshot,
            title: update.title, workingDirectory: update.workingDirectory, outputByteCount: update.outputByteCount,
            outputEndByteOffset: update.outputEndByteOffset, renderUpdateBody: mergedRenderUpdateBody, clipboardWrite: nil)
    }
}

extension GhosttyRemoteSessionStatePayload {
    private enum CodingKeys: String, CodingKey {
        case sessionID
        case reason
        case emittedAt
        case sessionStateRevision
        case sessionStateFlags
        case screenStateRevision
        case runtimeState
        case attachmentSnapshot
        case title
        case workingDirectory
        case outputByteCount
        case outputEndByteOffset
        case renderUpdate
        case clipboardWrite
    }

    /// Written by hand only because the render update is stored as a body rather than as `Data`. The
    /// wire shape is unchanged: the same keys, optionals omitted when nil, the render update as the
    /// base64 blob under `renderUpdate` (which a schema migration matches on by name).
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            sessionID: try container.decode(String.self, forKey: .sessionID), reason: try container.decode(String.self, forKey: .reason),
            emittedAt: try container.decode(String.self, forKey: .emittedAt),
            sessionStateRevision: try container.decodeIfPresent(UInt64.self, forKey: .sessionStateRevision),
            sessionStateFlags: try container.decodeIfPresent(UInt32.self, forKey: .sessionStateFlags),
            screenStateRevision: try container.decodeIfPresent(UInt64.self, forKey: .screenStateRevision),
            runtimeState: try container.decodeIfPresent(TerminalSessionRuntimeState.self, forKey: .runtimeState),
            attachmentSnapshot: try container.decodeIfPresent(TerminalSessionAttachmentSnapshot.self, forKey: .attachmentSnapshot),
            title: try container.decode(String.self, forKey: .title), workingDirectory: try container.decode(String.self, forKey: .workingDirectory),
            outputByteCount: try container.decodeIfPresent(Int.self, forKey: .outputByteCount),
            outputEndByteOffset: try container.decodeIfPresent(Int.self, forKey: .outputEndByteOffset),
            renderUpdate: try container.decodeIfPresent(Data.self, forKey: .renderUpdate),
            clipboardWrite: try container.decodeIfPresent(TerminalClipboardWritePayload.self, forKey: .clipboardWrite))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sessionID, forKey: .sessionID)
        try container.encode(reason, forKey: .reason)
        try container.encode(emittedAt, forKey: .emittedAt)
        try container.encodeIfPresent(sessionStateRevision, forKey: .sessionStateRevision)
        try container.encodeIfPresent(sessionStateFlags, forKey: .sessionStateFlags)
        try container.encodeIfPresent(screenStateRevision, forKey: .screenStateRevision)
        try container.encodeIfPresent(runtimeState, forKey: .runtimeState)
        try container.encodeIfPresent(attachmentSnapshot, forKey: .attachmentSnapshot)
        try container.encode(title, forKey: .title)
        try container.encode(workingDirectory, forKey: .workingDirectory)
        try container.encodeIfPresent(outputByteCount, forKey: .outputByteCount)
        try container.encodeIfPresent(outputEndByteOffset, forKey: .outputEndByteOffset)
        try container.encodeIfPresent(renderUpdate, forKey: .renderUpdate)
        try container.encodeIfPresent(clipboardWrite, forKey: .clipboardWrite)
    }
}

extension GhosttyRemoteSessionStatePayload {
    public var decodedRenderUpdate: GhosttyRenderUpdate? { renderUpdateBody?.decodedUpdate }

    /// What kind of render update the payload carries, answered from the update's header rather than by
    /// decoding its cells. Read this wherever the question is only "does this hand the reader a complete
    /// screen?" — a grid decode there costs a full columns×rows pass on paths (listener registration, the
    /// submit into the reduction pipeline) that must not do grid work. Nil when there is no render update,
    /// or when the one there is cannot be classified, which callers treat the same as "not a full frame".
    public var renderUpdateKind: GhosttyRenderUpdateKind? { renderUpdateBody?.kind }

    public var renderSnapshot: GhosttyTerminalSnapshot? { decodedRenderUpdate?.fullFrame?.snapshot }

    public var renderText: String? {
        guard let snapshot = renderSnapshot else { return nil }
        return GhosttyTerminalSnapshotLayout.plainText(for: snapshot)
    }

    public var renderOwnerEpoch: UInt64? { decodedRenderUpdate?.ownerEpoch }

    /// Rebuilds the payload around a different render update. `clipboardWrite` is dropped rather than
    /// copied for the same reason `merged(with:)` drops it: the derived payload is a re-export of
    /// screen state, and a clipboard write must be applied only from the payload that announced it. A
    /// `clipboard_write` payload never carries a render update (the reason exports no screen state),
    /// so nothing reaches a client through this path with the field to lose.
    public func replacingRenderUpdate(_ renderUpdate: Data?, screenStateRevision: UInt64? = nil) -> Self {
        replacingRenderUpdateBody(renderUpdate.map(GhosttyRenderUpdateBody.init(encoded:)), screenStateRevision: screenStateRevision)
    }

    /// Rebuilds the payload around a render update the caller already holds decoded, which is what a
    /// client's reducer produces for every applied update. The update is encoded only if the payload is
    /// later serialized; see `GhosttyRenderUpdateBody`.
    public func replacingRenderUpdate(materialized update: GhosttyRenderUpdate) -> Self {
        replacingRenderUpdateBody(GhosttyRenderUpdateBody(materialized: update), screenStateRevision: nil)
    }

    private func replacingRenderUpdateBody(_ body: GhosttyRenderUpdateBody?, screenStateRevision: UInt64?) -> Self {
        .init(
            sessionID: sessionID, reason: reason, emittedAt: emittedAt, sessionStateRevision: sessionStateRevision,
            sessionStateFlags: sessionStateFlags, screenStateRevision: screenStateRevision ?? self.screenStateRevision, runtimeState: runtimeState,
            attachmentSnapshot: attachmentSnapshot, title: title, workingDirectory: workingDirectory, outputByteCount: outputByteCount,
            outputEndByteOffset: outputEndByteOffset, renderUpdateBody: body, clipboardWrite: nil)
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

    // `date(from:)` runs once per terminal state-stream frame on the GUI main thread (see
    // DeviceTerminalSessionStateModel.apply), where its result only feeds a monotonic ordering
    // guard. `fastParse` hand-scans the two canonical wire shapes below without touching
    // ISO8601DateFormatter's ICU machinery; anything that isn't exactly one of those shapes
    // (wrong length, a non-digit, an offset like +05:00, a fractional part that isn't exactly 3
    // digits, an out-of-range field, ...) returns nil and falls through to the formatters
    // unchanged. This preserves the function's existing tolerance contract exactly, it is not a
    // new, looser fallback, just a short-circuit for the shapes the formatters already accept.
    public static func date(from string: String) -> Date? {
        if let fast = fastParse(string) { return fast }
        if let parsed = fractionalSecondsFormatter.date(from: string) { return parsed }
        return defaultFormatter.date(from: string)
    }

    /// Hand-rolled parser for `yyyy-MM-ddTHH:mm:ss.SSSZ` (what `string(from:)` emits) and
    /// `yyyy-MM-ddTHH:mm:ssZ` (legacy/foreign whole-second timestamps).
    private static func fastParse(_ string: String) -> Date? {
        guard let result = string.utf8.withContiguousStorageIfAvailable({ fastParse(bytes: $0) }) else { return nil }
        return result
    }

    private static func fastParse(bytes: UnsafeBufferPointer<UInt8>) -> Date? {
        let count = bytes.count
        guard count == 20 || count == 24 else { return nil }

        func digit(_ index: Int) -> Int? {
            let byte = bytes[index]
            guard byte >= 0x30, byte <= 0x39 else { return nil }
            return Int(byte - 0x30)
        }
        func twoDigits(_ index: Int) -> Int? {
            guard let tens = digit(index), let ones = digit(index + 1) else { return nil }
            return tens * 10 + ones
        }

        guard bytes[4] == UInt8(ascii: "-"), bytes[7] == UInt8(ascii: "-"), bytes[10] == UInt8(ascii: "T"), bytes[13] == UInt8(ascii: ":"),
            bytes[16] == UInt8(ascii: ":")
        else { return nil }
        guard let y0 = digit(0), let y1 = digit(1), let y2 = digit(2), let y3 = digit(3) else { return nil }
        let year = y0 * 1000 + y1 * 100 + y2 * 10 + y3
        guard let month = twoDigits(5), let day = twoDigits(8), let hour = twoDigits(11), let minute = twoDigits(14), let second = twoDigits(17)
        else { return nil }

        var nanoseconds = 0
        if count == 24 {
            guard bytes[19] == UInt8(ascii: "."), bytes[23] == UInt8(ascii: "Z") else { return nil }
            guard let f0 = digit(20), let f1 = digit(21), let f2 = digit(22) else { return nil }
            nanoseconds = (f0 * 100 + f1 * 10 + f2) * 1_000_000
        } else {
            guard bytes[19] == UInt8(ascii: "Z") else { return nil }
        }

        // Reject anything the formatters would also reject (invalid month/day/hour/minute/second)
        // rather than guessing at their behavior for those inputs; falling through here keeps the
        // fast and slow paths identical by construction for every string that reaches this point.
        // The year floor keeps the same guarantee for pre-Gregorian-reform years: `ISO8601DateFormatter`
        // resolves years before 1583 against the historical Julian calendar rather than proleptic
        // Gregorian, so this civil-days arithmetic would disagree with it there. Every real `emittedAt`
        // reflects a wall-clock time near now, so the floor never affects a genuine wire timestamp.
        guard year >= 1583, month >= 1, month <= 12, day >= 1, day <= daysInMonth(year: year, month: month), hour <= 23, minute <= 59, second <= 59
        else { return nil }

        // Days-since-epoch via the proleptic-Gregorian civil-days algorithm
        // (http://howardhinnant.github.io/date_algorithms.html#days_from_civil).
        let days = daysFromCivil(year: year, month: month, day: day)
        let secondsSinceEpoch = Double(days) * 86_400 + Double(hour) * 3_600 + Double(minute) * 60 + Double(second)
        return Date(timeIntervalSince1970: secondsSinceEpoch + Double(nanoseconds) / 1_000_000_000)
    }

    private static func daysFromCivil(year: Int, month: Int, day: Int) -> Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yearOfEra = y - era * 400
        let monthOfYear = (month + 9) % 12
        let dayOfYear = (153 * monthOfYear + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }

    private static func daysInMonth(year: Int, month: Int) -> Int {
        switch month {
        case 2: return isLeapYear(year) ? 29 : 28
        case 4, 6, 9, 11: return 30
        default: return 31
        }
    }

    private static func isLeapYear(_ year: Int) -> Bool { (year % 4 == 0 && year % 100 != 0) || year % 400 == 0 }
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
