import Foundation
import Testing

@testable import spacessessionindex

@Suite struct JSONLineFilterTests {
    private let filter = JSONLineFilter(needles: ["\"type\":\"user\"", "\"item\":{\"type\":\"UserMessage\"", "\"type\":\"session_meta\""])

    private func matches(_ line: String) -> Bool { Array(line.utf8).withUnsafeBytes { filter.matches($0) } }

    @Test func findsAnyNeedleAnywhereInTheLine() {
        #expect(matches("{\"type\":\"user\",\"x\":1}"))
        #expect(matches("{\"a\":\"yyy type\",\"payload\":{\"item\":{\"type\":\"UserMessage\",\"text\":\"y\"}}}"))
        #expect(matches("{\"output\":\"" + String(repeating: "type yes ", count: 50) + "\",\"type\":\"session_meta\"}"))
    }

    @Test func rejectsLinesWithoutAnyNeedle() {
        #expect(!matches("{\"type\":\"tool_result\",\"content\":\"user\"}"))
        // The lead of a needle must precede the anchor, not merely appear later.
        #expect(!matches("{\"type\":\"UserMessage\",\"item\":{}}"))
        #expect(!matches("{\"type\":\"us"))
        #expect(!matches(""))
    }
}
