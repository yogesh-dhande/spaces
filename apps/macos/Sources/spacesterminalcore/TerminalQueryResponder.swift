import Foundation

struct TerminalQueryResponder {
    private struct QueryPattern {
        let request: [UInt8]
        let response: [UInt8]
    }

    private static let queryPatterns: [QueryPattern] = [
        .init(request: Array("\u{001B}[5n".utf8), response: Array("\u{001B}[0n".utf8)),
        .init(request: Array("\u{001B}[6n".utf8), response: Array("\u{001B}[1;1R".utf8)),
        .init(request: Array("\u{001B}[c".utf8), response: Array("\u{001B}[?62;4;22c".utf8)),
        .init(request: Array("\u{001B}[>c".utf8), response: Array("\u{001B}[>0;10;1c".utf8)),
        .init(request: Array("\u{001B}]10;?\u{001B}\\".utf8), response: Array("\u{001B}]10;rgb:dddd/dddd/dddd\u{001B}\\".utf8)),
        .init(request: Array("\u{001B}]10;?\u{0007}".utf8), response: Array("\u{001B}]10;rgb:dddd/dddd/dddd\u{0007}".utf8)),
        .init(request: Array("\u{001B}]11;?\u{001B}\\".utf8), response: Array("\u{001B}]11;rgb:1111/1111/1111\u{001B}\\".utf8)),
        .init(request: Array("\u{001B}]11;?\u{0007}".utf8), response: Array("\u{001B}]11;rgb:1111/1111/1111\u{0007}".utf8)),
    ]

    private static let maxPatternLength = queryPatterns.map { $0.request.count }.max() ?? 0

    private var trailingBytes = [UInt8]()

    mutating func responses(for output: Data) -> [Data] {
        guard !output.isEmpty else { return [] }
        let outputBytes = [UInt8](output)
        let prefixCount = trailingBytes.count
        let combined = trailingBytes + outputBytes
        var responses = [Data]()

        for pattern in Self.queryPatterns {
            guard combined.count >= pattern.request.count else { continue }
            let lastStartIndex = combined.count - pattern.request.count
            for startIndex in 0...lastStartIndex {
                guard combined[startIndex..<(startIndex + pattern.request.count)].elementsEqual(pattern.request) else { continue }
                if startIndex + pattern.request.count > prefixCount { responses.append(Data(pattern.response)) }
            }
        }

        let tailCount = min(Self.maxPatternLength - 1, combined.count)
        trailingBytes = Array(combined.suffix(tailCount))
        return responses
    }
}
