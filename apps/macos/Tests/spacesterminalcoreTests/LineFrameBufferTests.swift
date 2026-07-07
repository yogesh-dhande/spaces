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
}
