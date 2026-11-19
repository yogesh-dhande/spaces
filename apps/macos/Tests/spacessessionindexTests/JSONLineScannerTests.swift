import Foundation
import Testing

@testable import spacessessionindex

@Suite struct JSONLineScannerTests {
    /// Chunks of fixed bytes, so line boundaries can be placed anywhere relative to chunk boundaries.
    private struct Chunks: ByteChunkSource {
        var pending: [Data]
        mutating func nextChunk() throws -> Data? { pending.isEmpty ? nil : pending.removeFirst() }
    }

    private func scan(_ chunks: [String], startOffset: Int64 = 0, acceptsUnterminatedFinalLine: Bool = false) throws -> (lines: [String], end: Int64)
    {
        var source = Chunks(pending: chunks.map { Data($0.utf8) })
        var lines: [String] = []
        let end = try JSONLineScanner(startOffset: startOffset, acceptsUnterminatedFinalLine: acceptsUnterminatedFinalLine).scan(&source) {
            lines.append(String(decoding: $0, as: UTF8.self))
        }
        return (lines, end)
    }

    @Test func partialTrailingLineIsNeitherDeliveredNorCounted() throws {
        let result = try scan(["{\"a\":1}\n{\"b\":2}\n{\"c\":"])
        #expect(result.lines == ["{\"a\":1}", "{\"b\":2}"])
        #expect(result.end == 16)
    }

    @Test func linesSplitAcrossChunksAreReassembled() throws {
        let result = try scan(["{\"a\"", ":1}\n{\"b\":2", "}\n"])
        #expect(result.lines == ["{\"a\":1}", "{\"b\":2}"])
        #expect(result.end == 16)
    }

    @Test func offsetStartsFromTheResumePoint() throws {
        let result = try scan(["{\"a\":1}\n"], startOffset: 100)
        #expect(result.end == 108)
    }

    @Test func blankLinesAreSkippedButCounted() throws {
        let result = try scan(["{\"a\":1}\n\n{\"b\":2}\n"])
        #expect(result.lines == ["{\"a\":1}", "{\"b\":2}"])
        #expect(result.end == 17)
    }

    @Test func anImmutableFileDeliversItsUnterminatedFinalLine() throws {
        let result = try scan(["{\"a\":1}\n{\"b\":2}"], acceptsUnterminatedFinalLine: true)
        #expect(result.lines == ["{\"a\":1}", "{\"b\":2}"])
        #expect(result.end == 15)
    }
}
