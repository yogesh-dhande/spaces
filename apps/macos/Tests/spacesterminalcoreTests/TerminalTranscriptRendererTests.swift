import Foundation
import XCTest

@testable import spacesterminalcore

final class TerminalTranscriptRendererTests: XCTestCase {
    func testRenderKeepsFinalVisibleFrameFromRepeatedRepaintTranscript() {
        let frames = (1...25).map { frame -> String in
            let row1 = "\u{001B}[H\u{001B}[2JFRAME \(frame)"
            let row2 = "\u{001B}[2;1HSEQ \(frame)"
            let row3 = "\u{001B}[3;1HSTATUS repaint"
            return [row1, row2, row3].joined()
        }.joined()

        let rendered = TerminalTranscriptRenderer.render(frames)

        XCTAssertTrue(rendered.contains("FRAME 25"))
        XCTAssertTrue(rendered.contains("SEQ 25"))
        XCTAssertFalse(rendered.contains("FRAME 1"))
    }

    func testRenderPreservesLongOrderedSequenceSuffix() {
        let transcript = (1...5000).map { "SEQ \($0)" }.joined(separator: "\n") + "\n"

        let rendered = TerminalTranscriptRenderer.render(transcript)
        let lines = rendered.split(separator: "\n")

        XCTAssertEqual(lines.count, 5000)
        XCTAssertEqual(lines.suffix(3).map(String.init), ["SEQ 4998", "SEQ 4999", "SEQ 5000"])
    }
}
