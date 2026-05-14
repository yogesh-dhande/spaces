import Foundation

public enum TerminalOutputTail {
    private struct PlainTailResult {
        let result: String
        let scannedBytes: UInt64
        let returnedBytes: Int
    }

    private struct RenderedTailResult {
        let result: String
        let renderedCharacterCount: Int
        let renderedByteCount: Int
        let scannedBytes: UInt64
        let boundaryOffset: Int
    }

    private static let plainTextReadBlockSize = 16 * 1024
    private static let renderedSuffixScanLimit: UInt64 = 512 * 1024
    private static let clearScreenBoundaryPatterns: [Data] = [
        Data([0x1B, 0x5B, 0x48, 0x1B, 0x5B, 0x32, 0x4A]), Data([0x1B, 0x5B, 0x32, 0x4A]), Data([0x1B, 0x5B, 0x33, 0x4A]),
    ]
    private static let cursorHomeBoundaryPattern = Data([0x1B, 0x5B, 0x48])

    public static func tail(path: String, lineCount: Int) throws -> String {
        let startedAt = Date()
        guard lineCount > 0 else { return "" }
        let fileURL = URL(fileURLWithPath: path)
        let fileHandle = try FileHandle(forReadingFrom: fileURL)
        defer { try? fileHandle.close() }
        let fileSize = try fileHandle.seekToEnd()
        guard fileSize > 0 else { return "" }

        let plainTextResult = try tailPlainTextIfPossible(fileHandle: fileHandle, fileSize: fileSize, lineCount: lineCount)
        let result: String
        let detail: String
        if let plainTextResult {
            result = plainTextResult.result
            detail =
                "bytes=\(fileSize) lines=\(lineCount) mode=plain scanned_bytes=\(plainTextResult.scannedBytes) "
                + "returned_bytes=\(plainTextResult.returnedBytes)"
        } else if let partialRenderedResult = try tailRenderedSuffixIfPossible(fileHandle: fileHandle, fileSize: fileSize, lineCount: lineCount) {
            result = partialRenderedResult.result
            detail =
                "bytes=\(fileSize) lines=\(lineCount) rendered_chars=\(partialRenderedResult.renderedCharacterCount) "
                + "rendered_bytes=\(partialRenderedResult.renderedByteCount) mode=rendered_partial "
                + "scanned_bytes=\(partialRenderedResult.scannedBytes) boundary_offset=\(partialRenderedResult.boundaryOffset)"
        } else {
            try fileHandle.seek(toOffset: 0)
            let data = try fileHandle.readToEnd() ?? Data()
            guard !data.isEmpty else { return "" }
            guard let text = String(data: data, encoding: .utf8) else { return "" }
            let rendered = TerminalTranscriptRenderer.render(text)
            let hadTrailingNewline = rendered.last == "\n"
            var lines = rendered.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            if hadTrailingNewline, !lines.isEmpty { lines.removeLast() }
            result = lines.suffix(lineCount).joined(separator: "\n")
            detail = "bytes=\(data.count) lines=\(lineCount) rendered_chars=\(rendered.count) mode=rendered_full " + "scanned_bytes=\(data.count)"
        }
        TerminalPerformance.logMetric(
            "terminal_tail_read", target: "file=\(fileURL.lastPathComponent)", elapsedMS: TerminalPerformance.elapsedMS(since: startedAt),
            success: true, detail: detail)
        return result
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

    private static func tailRenderedSuffixIfPossible(fileHandle: FileHandle, fileSize: UInt64, lineCount: Int) throws -> RenderedTailResult? {
        let startOffset = fileSize > renderedSuffixScanLimit ? fileSize - renderedSuffixScanLimit : 0
        try fileHandle.seek(toOffset: startOffset)
        let data = try fileHandle.readToEnd() ?? Data()
        guard !data.isEmpty else { return nil }
        guard let boundaryOffset = latestRenderedTranscriptBoundaryOffset(in: data) else { return nil }

        let suffix = data.suffix(from: boundaryOffset)
        guard let text = String(data: suffix, encoding: .utf8) else { return nil }
        let rendered = TerminalTranscriptRenderer.render(text)
        let hadTrailingNewline = rendered.last == "\n"
        var lines = rendered.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if hadTrailingNewline, !lines.isEmpty { lines.removeLast() }
        let result = lines.suffix(lineCount).joined(separator: "\n")
        return RenderedTailResult(
            result: result, renderedCharacterCount: rendered.count, renderedByteCount: suffix.count, scannedBytes: UInt64(data.count),
            boundaryOffset: boundaryOffset)
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

    private static func latestRenderedTranscriptBoundaryOffset(in data: Data) -> Int? {
        var bestOffset: Int?
        for pattern in clearScreenBoundaryPatterns {
            var searchRange = data.startIndex..<data.endIndex
            while let range = data.range(of: pattern, options: [], in: searchRange) {
                bestOffset = max(bestOffset ?? range.lowerBound, range.lowerBound)
                searchRange = range.lowerBound + 1..<data.endIndex
            }
        }
        var searchRange = data.startIndex..<data.endIndex
        while let range = data.range(of: cursorHomeBoundaryPattern, options: [], in: searchRange) {
            bestOffset = max(bestOffset ?? range.lowerBound, range.lowerBound)
            searchRange = range.lowerBound + 1..<data.endIndex
        }
        return bestOffset
    }
}
