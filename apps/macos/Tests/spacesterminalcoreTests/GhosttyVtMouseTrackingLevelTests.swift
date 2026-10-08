import Foundation
import Testing
import ghosttyvtshim

@testable import spacesterminalcore

/// The tracking level the libghostty-vt shim reports is Ghostty's effective tracking flag, the one its
/// mouse encoder reports against, not the tracking mode bits: the latest tracking-mode request wins and
/// any tracking-mode reset clears it.
@Suite struct GhosttyVtMouseTrackingLevelTests {
    private func level(afterWriting sequences: [String]) throws -> UInt8 {
        let session = try #require(spaces_ghostty_vt_session_new(20, 3, 0, nil))
        defer { spaces_ghostty_vt_session_free(session) }
        for sequence in sequences {
            let data = Data(sequence.utf8)
            #expect(data.withUnsafeBytes { spaces_ghostty_vt_session_write(session, $0.bindMemory(to: UInt8.self).baseAddress, $0.count) })
        }
        var level: UInt8 = 255
        #expect(spaces_ghostty_vt_session_mouse_tracking_level(session, &level))
        return level
    }

    @Test func eachTrackingModeReportsItsLevel() throws {
        #expect(try level(afterWriting: []) == UInt8(SPACES_GHOSTTY_VT_MOUSE_TRACKING_NONE.rawValue))
        #expect(try level(afterWriting: ["\u{1B}[?9h"]) == UInt8(SPACES_GHOSTTY_VT_MOUSE_TRACKING_CLICKS.rawValue))
        #expect(try level(afterWriting: ["\u{1B}[?1000h"]) == UInt8(SPACES_GHOSTTY_VT_MOUSE_TRACKING_CLICKS.rawValue))
        #expect(try level(afterWriting: ["\u{1B}[?1002h"]) == UInt8(SPACES_GHOSTTY_VT_MOUSE_TRACKING_BUTTON_MOTION.rawValue))
        #expect(try level(afterWriting: ["\u{1B}[?1003h"]) == UInt8(SPACES_GHOSTTY_VT_MOUSE_TRACKING_ANY_MOTION.rawValue))
    }

    /// `1003h` then `1000h` leaves both mode bits set, but Ghostty tracks clicks only.
    @Test func theLatestTrackingRequestWinsOverAWiderEarlierOne() throws {
        #expect(try level(afterWriting: ["\u{1B}[?1003h", "\u{1B}[?1000h"]) == UInt8(SPACES_GHOSTTY_VT_MOUSE_TRACKING_CLICKS.rawValue))
    }

    /// `1000h`, `1003h`, `1003l` leaves the 1000 bit set, but resetting any tracking mode clears Ghostty's flag.
    @Test func resettingAnyTrackingModeClearsTracking() throws {
        #expect(
            try level(afterWriting: ["\u{1B}[?1000h", "\u{1B}[?1003h", "\u{1B}[?1003l"]) == UInt8(SPACES_GHOSTTY_VT_MOUSE_TRACKING_NONE.rawValue))
    }
}
