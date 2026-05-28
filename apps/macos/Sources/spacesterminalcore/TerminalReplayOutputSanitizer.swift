import Foundation

public enum TerminalReplayOutputSanitizer {
    private static let promptEOLMarkStartSequence = Data("\u{001B}[1m\u{001B}[7m%".utf8)
    private static let promptEOLMarkEndSequence = Data("\r \r".utf8)

    public static func renderableOutputData(from outputData: Data) -> Data {
        normalizeBareLineFeeds(strippingPromptEOLMarkArtifacts(from: outputData))
    }

    public static func strippingPromptEOLMarkArtifacts(from outputData: Data) -> Data {
        var sanitized = Data()
        var searchStart = outputData.startIndex
        while searchStart < outputData.endIndex, let startRange = outputData[searchStart...].range(of: promptEOLMarkStartSequence) {
            sanitized.append(outputData[searchStart..<startRange.lowerBound])
            guard let endRange = outputData[startRange.lowerBound...].range(of: promptEOLMarkEndSequence) else {
                sanitized.append(outputData[startRange.lowerBound...])
                return sanitized
            }
            searchStart = endRange.upperBound
            if searchStart < outputData.endIndex, outputData[searchStart] == 0x0D { searchStart = outputData.index(after: searchStart) }
        }
        if searchStart < outputData.endIndex { sanitized.append(outputData[searchStart...]) }
        return sanitized
    }

    public static func normalizeBareLineFeeds(_ data: Data) -> Data {
        guard data.contains(0x0A) else { return data }
        var normalized = Data()
        normalized.reserveCapacity(data.count)
        var previousByte: UInt8?
        for byte in data {
            if byte == 0x0A, previousByte != 0x0D { normalized.append(0x0D) }
            normalized.append(byte)
            previousByte = byte
        }
        return normalized
    }
}
