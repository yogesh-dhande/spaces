import Foundation
import ghosttyvtshim

public enum TerminalOutputTail {
    private struct PlainTailResult {
        let result: String
        let scannedBytes: UInt64
        let returnedBytes: Int
    }

    private static let plainTextReadBlockSize = 16 * 1024
    private static let defaultColumns = 120
    private static let defaultRows = 40
    fileprivate static let maxScrollbackBytes = TerminalScrollbackBudget.defaultMaxBytes

    /// Renders the last `lineCount` lines of a session's screen and scrollback from its persisted
    /// `output.log`.
    ///
    /// A transcript that holds no escape sequences is answered by scanning back for `lineCount` newlines
    /// — plain text carries no terminal state, so there is nothing to reconstruct and nothing to gain
    /// from a render. Everything else is REPLAYED FROM BYTE 0 through a `libghostty-vt` session: a
    /// terminal's screen is the accumulation of every byte before it, so any starting point other than
    /// the file's beginning has to reconstruct the state it skipped, and a transcript carries no marker
    /// that is reliably both a valid state root and a truthful history boundary. Starting anywhere else
    /// is how a full-screen TUI — one that paints its frame once and afterwards only addresses the cursor
    /// — comes back blank: its last real repaint is arbitrarily far behind the end of the file.
    ///
    /// The cost is O(transcript), bounded by the trim trigger
    /// (`TerminalScrollbackBudget.liveTranscriptTrimTriggerBytes`, 30&nbsp;MB) — measured at ~155&nbsp;ms
    /// for a 30&nbsp;MB agent-TUI transcript and ~45&nbsp;ms for a 30&nbsp;MB shell one. That is
    /// affordable because this function has exactly three callers and all three are `spaces terminal
    /// tail` (CLI, daemon profile command, Device API): an orchestration surface, not a render path.
    /// Nothing interactive depends on it — the live mirror is fed by the session core, and the ended-pane
    /// and Device API scrollback replays read `output.log` directly, without coming through here.
    public static func tail(path: String, lineCount: Int) throws -> String {
        let startedAt = Date()
        guard lineCount > 0 else { return "" }
        let fileURL = URL(fileURLWithPath: path)
        let fileHandle = try FileHandle(forReadingFrom: fileURL)
        defer { try? fileHandle.close() }
        let fileSize = try fileHandle.seekToEnd()
        guard fileSize > 0 else { return "" }

        let result: String
        let detail: String
        if let plainTextResult = try tailPlainTextIfPossible(fileHandle: fileHandle, fileSize: fileSize, lineCount: lineCount) {
            result = plainTextResult.result
            detail =
                "bytes=\(fileSize) lines=\(lineCount) mode=plain scanned_bytes=\(plainTextResult.scannedBytes) "
                + "returned_bytes=\(plainTextResult.returnedBytes)"
        } else {
            try fileHandle.seek(toOffset: 0)
            let data = try fileHandle.readToEnd() ?? Data()
            guard !data.isEmpty else { return "" }
            let terminalSize = resolvedTerminalSize(forOutputPath: path)
            let rendered = try TerminalOutputVTRenderer.renderTailPlain(
                data, columns: terminalSize.columns, rows: terminalSize.rows,
                suppressInlineAgentSuggestion: isIdentifiedAgentSession(forOutputPath: path))
            result = tailRenderedText(rendered, lineCount: lineCount)
            detail =
                "bytes=\(data.count) lines=\(lineCount) mode=ghostty_vt scanned_bytes=\(data.count) "
                + "columns=\(terminalSize.columns) rows=\(terminalSize.rows) rendered_chars=\(rendered.count)"
        }

        TerminalPerformance.logMetric(
            "terminal_tail_read", target: "file=\(fileURL.lastPathComponent)", elapsedMS: TerminalPerformance.elapsedMS(since: startedAt),
            success: true, detail: detail)
        return result
    }

    public static func stableTranscript(from data: Data, columns: Int, rows: Int) throws -> String {
        guard !data.isEmpty else { return "" }
        if !containsUnsafeTranscriptControls(data) {
            if let text = String(data: data, encoding: .utf8) { return collapsedPromptEOLMarkLines(in: normalizedPlainTranscript(text)) }
        }
        let rendered = try TerminalOutputVTRenderer.renderPlain(data, columns: max(columns, 1), rows: max(rows, 1))
        return collapsedPromptEOLMarkLines(in: rendered)
    }

    private static func tailPlainTextIfPossible(fileHandle: FileHandle, fileSize: UInt64, lineCount: Int) throws -> PlainTailResult? {
        var offset = fileSize
        var startOffset: UInt64 = 0
        var newlineCount = 0
        var scannedBytes: UInt64 = 0
        let fileEndsWithNewline = try byteAt(fileSize - 1, in: fileHandle) == 0x0A
        var skippedTrailingNewline = !fileEndsWithNewline

        while offset > 0 {
            let readLength = min(UInt64(plainTextReadBlockSize), offset)
            offset -= readLength
            try fileHandle.seek(toOffset: offset)
            let chunk = try fileHandle.read(upToCount: Int(readLength)) ?? Data()
            guard !chunk.isEmpty else { break }
            scannedBytes += UInt64(chunk.count)
            if try containsUnsafeTranscriptControls(chunk, chunkOffset: offset, fileHandle: fileHandle, fileSize: fileSize) { return nil }
            var locatedStartInChunk = false
            for index in stride(from: chunk.count - 1, through: 0, by: -1) {
                guard chunk[index] == 0x0A else { continue }
                if !skippedTrailingNewline {
                    skippedTrailingNewline = true
                    continue
                }
                newlineCount += 1
                if newlineCount == lineCount {
                    startOffset = offset + UInt64(index + 1)
                    locatedStartInChunk = true
                    break
                }
            }
            if locatedStartInChunk { break }
            startOffset = offset
        }

        try fileHandle.seek(toOffset: startOffset)
        let readLength = Int(fileSize - startOffset)
        let data = try fileHandle.read(upToCount: readLength) ?? Data()
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        let result = plainTextTail(from: text, lineCount: lineCount)
        return PlainTailResult(result: result, scannedBytes: scannedBytes, returnedBytes: data.count)
    }

    private static func plainTextTail(from text: String, lineCount: Int) -> String {
        guard !text.isEmpty else { return "" }
        let hadTrailingNewline = text.last == "\n"
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            let string = String(line)
            if string.last == "\r" { return String(string.dropLast()) }
            return string
        }
        if hadTrailingNewline, !lines.isEmpty { lines.removeLast() }
        return lines.suffix(lineCount).joined(separator: "\n")
    }

    private static func tailRenderedText(_ text: String, lineCount: Int) -> String {
        guard !text.isEmpty else { return "" }
        let hadTrailingNewline = text.last == "\n"
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if hadTrailingNewline, !lines.isEmpty { lines.removeLast() }
        return lines.suffix(lineCount).joined(separator: "\n")
    }

    private static func resolvedTerminalSize(forOutputPath path: String) -> (columns: Int, rows: Int) {
        let sessionRoot = URL(fileURLWithPath: path).deletingLastPathComponent().path
        let paths = TerminalSessionPaths(rootDirectory: sessionRoot)
        guard let runtimeState = try? TerminalSessionPersistence.readRuntimeState(paths: paths) else { return (defaultColumns, defaultRows) }
        let columns = max(runtimeState.columns ?? defaultColumns, 1)
        let rows = max(runtimeState.rows ?? defaultRows, 1)
        return (columns, rows)
    }

    private static func isIdentifiedAgentSession(forOutputPath path: String) -> Bool {
        let sessionRoot = URL(fileURLWithPath: path).deletingLastPathComponent().path
        let paths = TerminalSessionPaths(rootDirectory: sessionRoot)
        if let launchConfiguration = try? TerminalSessionPersistence.readLaunchConfiguration(paths: paths), launchConfiguration.kind == .agent {
            return true
        }
        return (try? TerminalSessionPersistence.readRuntimeState(paths: paths).foregroundDetectedAgentKind) != nil
    }

    private static func containsUnsafeTranscriptControls(_ data: Data, chunkOffset: UInt64, fileHandle: FileHandle, fileSize: UInt64) throws -> Bool {
        for index in data.indices {
            switch data[index] {
            case 0x1B, 0x08: return true
            case 0x0D: if try !isCRLF(in: data, index: index, chunkOffset: chunkOffset, fileHandle: fileHandle, fileSize: fileSize) { return true }
            default: break
            }
        }
        return false
    }

    private static func containsUnsafeTranscriptControls(_ data: Data) -> Bool {
        for index in data.indices {
            switch data[index] {
            case 0x1B, 0x08: return true
            case 0x0D:
                let nextIndex = index + 1
                if nextIndex >= data.endIndex || data[nextIndex] != 0x0A { return true }
            default: break
            }
        }
        return false
    }

    private static func normalizedPlainTranscript(_ text: String) -> String { text.replacingOccurrences(of: "\r\n", with: "\n") }

    private static func collapsedPromptEOLMarkLines(in text: String) -> String {
        guard !text.isEmpty else { return text }
        let hadTrailingNewline = text.last == "\n"
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var collapsed: [String] = []
        collapsed.reserveCapacity(lines.count)

        for (index, line) in lines.enumerated() {
            let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedLine == "%", let nextLine = lines[safe: index + 1]?.trimmingCharacters(in: .whitespacesAndNewlines),
                isPromptLikeTranscriptLine(nextLine)
            {
                continue
            }
            collapsed.append(line)
        }

        var result = collapsed.joined(separator: "\n")
        if hadTrailingNewline { result.append("\n") }
        return result
    }

    private static func isPromptLikeTranscriptLine(_ line: String) -> Bool {
        guard !line.isEmpty else { return false }
        return line.contains(" % ") || line.hasSuffix(" %")
    }

    private static func isCRLF(in data: Data, index: Int, chunkOffset: UInt64, fileHandle: FileHandle, fileSize: UInt64) throws -> Bool {
        let nextIndex = index + 1
        if nextIndex < data.endIndex { return data[nextIndex] == 0x0A }
        let globalNextOffset = chunkOffset + UInt64(nextIndex)
        guard globalNextOffset < fileSize else { return false }
        return try byteAt(globalNextOffset, in: fileHandle) == 0x0A
    }

    private static func byteAt(_ offset: UInt64, in fileHandle: FileHandle) throws -> UInt8 {
        try fileHandle.seek(toOffset: offset)
        let data = try fileHandle.read(upToCount: 1) ?? Data()
        return data.first ?? 0
    }
}

extension Array { fileprivate subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil } }

private enum TerminalOutputVTRenderer {
    static func renderTailPlain(_ data: Data, columns: Int, rows: Int, suppressInlineAgentSuggestion: Bool) throws -> String {
        guard
            let session = spaces_ghostty_vt_session_new(UInt16(clamping: columns), UInt16(clamping: rows), TerminalOutputTail.maxScrollbackBytes, nil)
        else { throw TerminalOutputTailError.ghosttyVTRenderFailed }
        defer { spaces_ghostty_vt_session_free(session) }

        let replayed = data.withUnsafeBytes { rawBuffer in
            spaces_ghostty_vt_session_write(session, rawBuffer.bindMemory(to: UInt8.self).baseAddress, rawBuffer.count)
        }
        guard replayed else { throw TerminalOutputTailError.ghosttyVTRenderFailed }
        if suppressInlineAgentSuggestion, !spaces_ghostty_vt_session_erase_faint_run_at_cursor(session) {
            throw TerminalOutputTailError.ghosttyVTRenderFailed
        }

        var outputPointer: UnsafeMutablePointer<CChar>?
        var outputLength = 0
        guard spaces_ghostty_vt_session_format_plain(session, &outputPointer, &outputLength), let outputPointer else {
            throw TerminalOutputTailError.ghosttyVTRenderFailed
        }
        defer { spaces_ghostty_vt_free_buffer(outputPointer) }
        let buffer = UnsafeBufferPointer(start: outputPointer, count: outputLength)
        return String(decoding: UnsafeRawBufferPointer(buffer), as: UTF8.self)
    }

    static func renderPlain(_ data: Data, columns: Int, rows: Int) throws -> String {
        var outputPointer: UnsafeMutablePointer<CChar>?
        var outputLength = 0
        let succeeded = data.withUnsafeBytes { rawBuffer in
            let baseAddress = rawBuffer.bindMemory(to: UInt8.self).baseAddress
            return spaces_ghostty_vt_render_plain(
                baseAddress, rawBuffer.count, UInt16(clamping: columns), UInt16(clamping: rows), TerminalOutputTail.maxScrollbackBytes,
                &outputPointer, &outputLength)
        }
        guard succeeded, let outputPointer else { throw TerminalOutputTailError.ghosttyVTRenderFailed }
        defer { spaces_ghostty_vt_free_buffer(outputPointer) }
        let buffer = UnsafeBufferPointer(start: outputPointer, count: outputLength)
        return String(decoding: UnsafeRawBufferPointer(buffer), as: UTF8.self)
    }
}

private enum TerminalOutputTailError: Error { case ghosttyVTRenderFailed }
