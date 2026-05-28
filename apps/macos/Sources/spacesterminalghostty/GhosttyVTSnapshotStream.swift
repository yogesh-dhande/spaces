import Foundation
import ghosttyvtshim
import spacesterminalcore

@MainActor final class GhosttyVTSnapshotStream {
    private static let defaultColumns = 120
    private static let defaultRows = 40
    private static let maxScrollback = 20_000
    private static let replayChunkSize = 64 * 1024

    private let sessionID: String
    private let outputPath: String
    nonisolated(unsafe) private var session: OpaquePointer?
    private var processedBytes: UInt64 = 0
    private var configuredTerminalSize: (columns: Int, rows: Int)?
    private var lastRenderedFileSize: UInt64?
    private var cachedSnapshot: GhosttyTerminalSnapshot?
    private var cachedPlainText: String?

    init(sessionID: String, outputPath: String) {
        self.sessionID = sessionID
        self.outputPath = outputPath
    }

    deinit { if let session { spaces_ghostty_vt_session_free(session) } }

    func snapshot(columns: Int?, rows: Int?) -> GhosttyTerminalSnapshot? {
        refreshIfNeeded(columns: columns, rows: rows, renderer: "snapshot")
        return cachedSnapshot
    }

    func snapshotText(columns: Int?, rows: Int?) -> String? {
        refreshIfNeeded(columns: columns, rows: rows, renderer: "snapshot_text")
        return cachedPlainText
    }

    private func refreshIfNeeded(columns: Int?, rows: Int?, renderer: String) {
        let resolvedColumns = max(columns ?? Self.defaultColumns, 1)
        let resolvedRows = max(rows ?? Self.defaultRows, 1)
        let fileSize = currentOutputFileSize()
        let requestedSize = (columns: resolvedColumns, rows: resolvedRows)
        let shouldRebuildSession =
            session == nil || configuredTerminalSize?.columns != requestedSize.columns || configuredTerminalSize?.rows != requestedSize.rows
            || fileSize < processedBytes
        let startedAt = Date()
        let processedBytesBeforeRefresh = processedBytes
        var rebuiltSession = false
        var rebuildElapsedMS = 0
        var replayElapsedMS = 0
        var recaptureElapsedMS = 0

        if shouldRebuildSession {
            let rebuildStartedAt = Date()
            rebuildSession(columns: resolvedColumns, rows: resolvedRows)
            rebuildElapsedMS = TerminalPerformance.elapsedMS(since: rebuildStartedAt)
            rebuiltSession = true
            processedBytes = 0
            lastRenderedFileSize = nil
        }

        guard let session else {
            cachedSnapshot = nil
            cachedPlainText = nil
            TerminalPerformance.logMetric(
                "terminal_snapshot_stream_refresh", target: "session=\(sessionID)", elapsedMS: TerminalPerformance.elapsedMS(since: startedAt),
                success: false,
                detail:
                    "renderer=\(renderer) rebuilt=\(rebuiltSession ? 1 : 0) replayed_bytes=0 recaptured=0 columns=\(resolvedColumns) rows=\(resolvedRows)"
            )
            return
        }

        let replayedBytes = max(Int64(fileSize) - Int64(processedBytes), 0)
        if fileSize > processedBytes {
            let replayStartedAt = Date()
            guard replayOutput(into: session, fromOffset: processedBytes, fileSize: fileSize) else {
                cachedSnapshot = nil
                cachedPlainText = nil
                TerminalPerformance.logMetric(
                    "terminal_snapshot_stream_refresh", target: "session=\(sessionID)", elapsedMS: TerminalPerformance.elapsedMS(since: startedAt),
                    success: false,
                    detail:
                        "renderer=\(renderer) rebuilt=\(rebuiltSession ? 1 : 0) replayed_bytes=\(replayedBytes) recaptured=0 rebuild_ms=\(rebuildElapsedMS) replay_ms=\(TerminalPerformance.elapsedMS(since: replayStartedAt)) recapture_ms=0 columns=\(resolvedColumns) rows=\(resolvedRows)"
                )
                return
            }
            replayElapsedMS = TerminalPerformance.elapsedMS(since: replayStartedAt)
            processedBytes = fileSize
        }

        let needsRecapture = lastRenderedFileSize != fileSize || cachedSnapshot == nil || cachedPlainText == nil
        guard needsRecapture else {
            if rebuiltSession || processedBytesBeforeRefresh != processedBytes {
                TerminalPerformance.logMetric(
                    "terminal_snapshot_stream_refresh", target: "session=\(sessionID)", elapsedMS: TerminalPerformance.elapsedMS(since: startedAt),
                    success: true,
                    detail:
                        "renderer=\(renderer) rebuilt=\(rebuiltSession ? 1 : 0) replayed_bytes=\(replayedBytes) recaptured=0 rebuild_ms=\(rebuildElapsedMS) replay_ms=\(replayElapsedMS) recapture_ms=0 columns=\(resolvedColumns) rows=\(resolvedRows)"
                )
            }
            return
        }
        let recaptureStartedAt = Date()
        recaptureState(from: session, fileSize: fileSize)
        recaptureElapsedMS = TerminalPerformance.elapsedMS(since: recaptureStartedAt)
        TerminalPerformance.logMetric(
            "terminal_snapshot_stream_refresh", target: "session=\(sessionID)", elapsedMS: TerminalPerformance.elapsedMS(since: startedAt),
            success: true,
            detail:
                "renderer=\(renderer) rebuilt=\(rebuiltSession ? 1 : 0) replayed_bytes=\(replayedBytes) recaptured=1 rebuild_ms=\(rebuildElapsedMS) replay_ms=\(replayElapsedMS) recapture_ms=\(recaptureElapsedMS) columns=\(resolvedColumns) rows=\(resolvedRows)"
        )
    }

    private func rebuildSession(columns: Int, rows: Int) {
        if let session { spaces_ghostty_vt_session_free(session) }
        session = spaces_ghostty_vt_session_new(UInt16(clamping: columns), UInt16(clamping: rows), Self.maxScrollback)
        configuredTerminalSize = session == nil ? nil : (columns: columns, rows: rows)
        cachedSnapshot = nil
        cachedPlainText = nil
    }

    private func replayOutput(into session: OpaquePointer, fromOffset offset: UInt64, fileSize: UInt64) -> Bool {
        guard fileSize > 0 else { return true }
        let outputURL = URL(fileURLWithPath: outputPath)
        guard let fileHandle = try? FileHandle(forReadingFrom: outputURL) else { return false }
        defer { try? fileHandle.close() }

        do {
            try fileHandle.seek(toOffset: offset)
            var remainingBytes = fileSize - offset
            while remainingBytes > 0 {
                let readLength = Int(min(UInt64(Self.replayChunkSize), remainingBytes))
                let chunk = try fileHandle.read(upToCount: readLength) ?? Data()
                guard !chunk.isEmpty else { return false }
                let renderChunk = TerminalReplayOutputSanitizer.renderableOutputData(from: chunk)
                let wroteChunk = renderChunk.withUnsafeBytes { rawBuffer -> Bool in
                    guard let baseAddress = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return renderChunk.isEmpty }
                    return spaces_ghostty_vt_session_write(session, baseAddress, rawBuffer.count)
                }
                if !wroteChunk { return false }
                remainingBytes -= UInt64(chunk.count)
            }
            return true
        } catch { return false }
    }

    private func recaptureState(from session: OpaquePointer, fileSize: UInt64) {
        var rawSnapshot = SpacesGhosttyVtSnapshot()
        guard spaces_ghostty_vt_session_copy_snapshot(session, &rawSnapshot) else {
            cachedSnapshot = nil
            cachedPlainText = nil
            return
        }
        defer { spaces_ghostty_vt_snapshot_free(&rawSnapshot) }

        cachedSnapshot = mapSnapshot(rawSnapshot)
        cachedPlainText = capturePlainText(from: session)
        lastRenderedFileSize = fileSize
    }

    private func capturePlainText(from session: OpaquePointer) -> String? {
        var outputPointer: UnsafeMutablePointer<CChar>?
        var outputLength = 0
        guard spaces_ghostty_vt_session_format_plain(session, &outputPointer, &outputLength), let outputPointer else { return nil }
        defer { spaces_ghostty_vt_free_buffer(outputPointer) }

        guard outputLength > 0 else { return "" }
        let utf8Pointer = UnsafeRawPointer(outputPointer).assumingMemoryBound(to: UInt8.self)
        let bytes = UnsafeBufferPointer(start: utf8Pointer, count: outputLength)
        return String(decoding: bytes, as: UTF8.self)
    }

    private func mapSnapshot(_ rawSnapshot: SpacesGhosttyVtSnapshot) -> GhosttyTerminalSnapshot {
        let cellCount = Int(rawSnapshot.cell_count)
        let cells: [GhosttyTerminalSnapshot.Cell]
        if let rawCells = rawSnapshot.cells, cellCount > 0 {
            let buffer = UnsafeBufferPointer(start: rawCells, count: cellCount)
            cells = buffer.map { cell in
                GhosttyTerminalSnapshot.Cell(
                    codepoint: cell.codepoint, foregroundRGB: cell.foreground_rgb, backgroundRGB: cell.background_rgb, flags: cell.flags)
            }
        } else {
            cells = []
        }

        return GhosttyTerminalSnapshot(
            columns: Int(rawSnapshot.columns), rows: Int(rawSnapshot.rows), cursorColumn: Int(rawSnapshot.cursor_column),
            cursorRow: Int(rawSnapshot.cursor_row), cursorVisible: rawSnapshot.cursor_visible,
            defaultForegroundRGB: rawSnapshot.default_foreground_rgb, defaultBackgroundRGB: rawSnapshot.default_background_rgb, cells: cells)
    }

    private func currentOutputFileSize() -> UInt64 {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: outputPath), let size = attributes[.size] as? NSNumber else {
            return 0
        }
        return size.uint64Value
    }
}
