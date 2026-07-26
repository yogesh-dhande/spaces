import Foundation
import XCTest

@testable import spacesterminalcore

final class LineFrameBufferTests: XCTestCase {
    func testLineSplitAcrossTwoAppends() {
        var frames = LineFrameBuffer()
        frames.append(Data("hel".utf8))
        XCTAssertNil(frames.popLine())
        frames.append(Data("lo\n".utf8))
        XCTAssertEqual(frames.popLine(), Data("hello".utf8))
        XCTAssertNil(frames.popLine())
    }

    func testMultipleLinesInOneAppend() {
        var frames = LineFrameBuffer()
        frames.append(Data("one\ntwo\nthree\n".utf8))
        XCTAssertEqual(frames.popLine(), Data("one".utf8))
        XCTAssertEqual(frames.popLine(), Data("two".utf8))
        XCTAssertEqual(frames.popLine(), Data("three".utf8))
        XCTAssertNil(frames.popLine())
        XCTAssertTrue(frames.isEmpty)
    }

    func testBytesAfterLastNewlineStayForNextPop() {
        var frames = LineFrameBuffer()
        frames.append(Data("first\npartial".utf8))
        XCTAssertEqual(frames.popLine(), Data("first".utf8))
        XCTAssertNil(frames.popLine())
        XCTAssertFalse(frames.isEmpty)
        frames.append(Data("-rest\n".utf8))
        XCTAssertEqual(frames.popLine(), Data("partial-rest".utf8))
        XCTAssertNil(frames.popLine())
    }

    func testDrainRemainderReturnsUnterminatedTailAndEmpties() {
        var frames = LineFrameBuffer()
        frames.append(Data("done\ntail".utf8))
        XCTAssertEqual(frames.popLine(), Data("done".utf8))
        XCTAssertEqual(frames.drainRemainder(), Data("tail".utf8))
        XCTAssertTrue(frames.isEmpty)
        XCTAssertEqual(frames.drainRemainder(), Data())
    }

    func testPopLineOnEmptyReturnsNil() {
        var frames = LineFrameBuffer()
        XCTAssertNil(frames.popLine())
        XCTAssertTrue(frames.isEmpty)
    }

    func testEmptyLinePopsAsEmptyData() {
        var frames = LineFrameBuffer()
        frames.append(Data([0x0A]))
        XCTAssertEqual(frames.popLine(), Data())
        XCTAssertNil(frames.popLine())
        XCTAssertTrue(frames.isEmpty)
    }

    func testLargeLineDeliveredInManySmallChunksStaysIntact() {
        var frames = LineFrameBuffer()
        // Avoid 0x0A in the payload itself so it doesn't get mistaken for a line terminator.
        let payload = Data((0..<200_000).map { UInt8(65 + $0 % 26) })
        var offset = payload.startIndex
        while offset < payload.endIndex {
            let chunkEnd = payload.index(offset, offsetBy: 37, limitedBy: payload.endIndex) ?? payload.endIndex
            frames.append(payload[offset..<chunkEnd])
            XCTAssertNil(frames.popLine())
            offset = chunkEnd
        }
        frames.append(Data([0x0A]))
        XCTAssertEqual(frames.popLine(), payload)
        XCTAssertNil(frames.popLine())
        XCTAssertTrue(frames.isEmpty)
    }

    func testInterleavedLinesAndPartialTailsAcrossAppends() {
        var frames = LineFrameBuffer()
        frames.append(Data("alpha\nbe".utf8))
        XCTAssertEqual(frames.popLine(), Data("alpha".utf8))
        XCTAssertNil(frames.popLine())
        frames.append(Data("ta\ngam".utf8))
        XCTAssertEqual(frames.popLine(), Data("beta".utf8))
        XCTAssertNil(frames.popLine())
        frames.append(Data("ma\n\ndelta".utf8))
        XCTAssertEqual(frames.popLine(), Data("gamma".utf8))
        XCTAssertEqual(frames.popLine(), Data())
        XCTAssertNil(frames.popLine())
        XCTAssertFalse(frames.isEmpty)
        frames.append(Data("-rest\n".utf8))
        XCTAssertEqual(frames.popLine(), Data("delta-rest".utf8))
        XCTAssertNil(frames.popLine())
        XCTAssertTrue(frames.isEmpty)
    }

    func testDrainRemainderAfterSeveralPopsReturnsOnlyUnconsumedTail() {
        var frames = LineFrameBuffer()
        frames.append(Data("one\ntwo\nthree\nfour-partial".utf8))
        XCTAssertEqual(frames.popLine(), Data("one".utf8))
        XCTAssertEqual(frames.popLine(), Data("two".utf8))
        XCTAssertEqual(frames.popLine(), Data("three".utf8))
        XCTAssertNil(frames.popLine())
        XCTAssertEqual(frames.drainRemainder(), Data("four-partial".utf8))
        XCTAssertTrue(frames.isEmpty)
        XCTAssertEqual(frames.drainRemainder(), Data())
    }
}
