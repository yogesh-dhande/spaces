import Foundation

public enum TerminalSessionHostProtocolSupport {
    public static func hostSnapshot(paths: TerminalSessionPaths, recentOutputLineCount: Int) -> TerminalSessionHostSnapshot {
        TerminalSessionHostSnapshot(
            launchConfiguration: try? TerminalSessionPersistence.readLaunchConfiguration(paths: paths),
            runtimeState: try? TerminalSessionPersistence.readRuntimeState(paths: paths),
            attachmentSnapshot: try? TerminalSessionPersistence.readAttachmentSnapshot(paths: paths),
            recentOutput: (try? TerminalOutputTail.tail(path: paths.outputPath, lineCount: recentOutputLineCount)) ?? "",
            outputByteCount: (try? TerminalOutputChunkReader.currentSize(path: paths.outputPath)) ?? 0)
    }

    public static func attach(
        request: TerminalControlRequest, sessionID: String, paths: TerminalSessionPaths, attachedAt: @escaping @Sendable () -> String
    ) throws -> TerminalControlResponse {
        guard let client = request.client else { return TerminalControlResponse(ok: false, message: "Missing client payload.") }
        let mode = request.attachmentMode ?? .viewer
        try TerminalSessionPersistence.attachClient(sessionID: sessionID, client: client, mode: mode, paths: paths, attachedAt: attachedAt())
        return TerminalControlResponse(ok: true, message: "Attached client.", snapshot: hostSnapshot(paths: paths, recentOutputLineCount: 200))
    }

    public static func detach(request: TerminalControlRequest, paths: TerminalSessionPaths) throws -> TerminalControlResponse {
        guard let clientID = request.clientID, !clientID.isEmpty else { return TerminalControlResponse(ok: false, message: "Missing client ID.") }
        try TerminalSessionPersistence.detachClient(id: clientID, paths: paths, detachedAt: ISO8601DateFormatter().string(from: Date()))
        return TerminalControlResponse(ok: true, message: "Detached client.", snapshot: hostSnapshot(paths: paths, recentOutputLineCount: 200))
    }

    public static func snapshot(request: TerminalControlRequest, paths: TerminalSessionPaths) -> TerminalControlResponse {
        let lineCount = max(0, request.recentOutputLineCount ?? 200)
        return TerminalControlResponse(ok: true, message: "Loaded snapshot.", snapshot: hostSnapshot(paths: paths, recentOutputLineCount: lineCount))
    }

    public static func outputSize(paths: TerminalSessionPaths) -> TerminalControlResponse {
        TerminalControlResponse(
            ok: true, message: "Loaded output size.", outputByteCount: (try? TerminalOutputChunkReader.currentSize(path: paths.outputPath)) ?? 0)
    }

    public static func readOutputChunk(request: TerminalControlRequest, sessionID: String, paths: TerminalSessionPaths) -> TerminalControlResponse {
        guard let offset = request.offset else { return TerminalControlResponse(ok: false, message: "Missing output offset.") }
        let maximumBytes = max(1, request.maximumBytes ?? 4096)
        do {
            let chunk = try TerminalOutputChunkReader.readChunk(
                sessionID: sessionID, path: paths.outputPath, offset: offset, maximumBytes: maximumBytes)
            let size = try TerminalOutputChunkReader.currentSize(path: paths.outputPath)
            return TerminalControlResponse(ok: true, message: "Loaded output chunk.", outputChunk: chunk, outputByteCount: size)
        } catch { return TerminalControlResponse(ok: false, message: String(describing: error)) }
    }
}
