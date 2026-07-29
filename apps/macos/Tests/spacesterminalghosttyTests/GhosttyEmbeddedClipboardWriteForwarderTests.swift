#if canImport(AppKit) && canImport(GhosttyKit)
    import AppKit
    import Foundation
    import GhosttyKit
    import XCTest
    import spacesterminalcore

    @testable import spacesterminalghostty

    /// The daemon's half of OSC 52: a program's copy is handed to the session that produced it, never
    /// written to the daemon host's own pasteboard. Writing it there would put a session's clipboard on
    /// whatever machine happens to run the daemon — for a Linux daemon or a Mac serving a phone, a
    /// machine nobody is typing on — so these pin that the runtime callback resolves a session instead.
    final class GhosttyEmbeddedClipboardWriteForwarderTests: XCTestCase {
        /// Collects what the surface's session host was handed, from the engine actor.
        private final class ClipboardWriteRecorder: @unchecked Sendable {
            private let lock = NSLock()
            private var values: [String] = []
            let received = XCTestExpectation(description: "clipboard write delivered to the session")

            func record(_ text: String) {
                lock.lock()
                values.append(text)
                lock.unlock()
                received.fulfill()
            }

            func texts() -> [String] {
                lock.lock()
                defer { lock.unlock() }
                return values
            }
        }

        /// Runs `body` with a C clipboard-content array holding one representation.
        private func withContent(mime: String, data: String, _ body: (UnsafePointer<ghostty_clipboard_content_s>, Int) -> Void) {
            let mimePointer = strdup(mime)
            let dataPointer = strdup(data)
            defer {
                free(mimePointer)
                free(dataPointer)
            }
            var content = ghostty_clipboard_content_s(mime: UnsafePointer(mimePointer), data: UnsafePointer(dataPointer))
            withUnsafePointer(to: &content) { body($0, 1) }
        }

        /// A surface userdata whose session hands every clipboard write to `recorder` — standing in for
        /// the driver's route to the session host.
        private func makeSurfaceUserData(_ recorder: ClipboardWriteRecorder) async -> GhosttyEmbeddedSurfaceUserData {
            await TerminalEngineActor.run {
                GhosttyEmbeddedSurfaceUserData(closeHandler: {}, surfaceProvider: { nil }, clipboardWriteHandler: { text in recorder.record(text) })
            }
        }

        /// The product behavior: the decoded text reaches the session, which is what forwards it to the
        /// attached owner. Nothing here consults a pasteboard.
        func testStandardClipboardWriteReachesTheSession() async throws {
            let recorder = ClipboardWriteRecorder()
            let userData = await makeSurfaceUserData(recorder)
            let pointer = Unmanaged.passUnretained(userData).toOpaque()

            withContent(mime: "text/plain", data: "copied text") { content, count in
                GhosttyEmbeddedClipboardWriteForwarder.forward(
                    userdata: pointer, location: GHOSTTY_CLIPBOARD_STANDARD, content: content, count: count)
            }

            await fulfillment(of: [recorder.received], timeout: 5)
            XCTAssertEqual(recorder.texts(), ["copied text"])
        }

        /// A write carrying no representation is an OSC 52 clear, which travels as empty text so the
        /// owner empties its clipboard rather than keeping content the program asked to remove.
        func testClearWriteReachesTheSessionAsEmptyText() async throws {
            let recorder = ClipboardWriteRecorder()
            let userData = await makeSurfaceUserData(recorder)
            let pointer = Unmanaged.passUnretained(userData).toOpaque()

            GhosttyEmbeddedClipboardWriteForwarder.forward(userdata: pointer, location: GHOSTTY_CLIPBOARD_STANDARD, content: nil, count: 0)

            await fulfillment(of: [recorder.received], timeout: 5)
            XCTAssertEqual(recorder.texts(), [""])
        }

        /// Refused writes leave the owner's clipboard alone: the selection clipboard has no counterpart
        /// on a client device, a payload over the cap is a runaway, and a write with no `text/plain`
        /// representation carries nothing to paste. The cap matches the Linux vt shim's, so a session
        /// behaves the same on either daemon.
        func testRefusedWritesDeliverNothing() async throws {
            let recorder = ClipboardWriteRecorder()
            recorder.received.isInverted = true
            let userData = await makeSurfaceUserData(recorder)
            let pointer = Unmanaged.passUnretained(userData).toOpaque()

            withContent(mime: "text/plain", data: "selection copy") { content, count in
                GhosttyEmbeddedClipboardWriteForwarder.forward(
                    userdata: pointer, location: GHOSTTY_CLIPBOARD_SELECTION, content: content, count: count)
            }
            withContent(mime: "image/png", data: "not text") { content, count in
                GhosttyEmbeddedClipboardWriteForwarder.forward(
                    userdata: pointer, location: GHOSTTY_CLIPBOARD_STANDARD, content: content, count: count)
            }
            let overCap = String(repeating: "a", count: GhosttyEmbeddedClipboardWriteForwarder.maximumClipboardWriteBytes + 1)
            withContent(mime: "text/plain", data: overCap) { content, count in
                GhosttyEmbeddedClipboardWriteForwarder.forward(
                    userdata: pointer, location: GHOSTTY_CLIPBOARD_STANDARD, content: content, count: count)
            }

            await fulfillment(of: [recorder.received], timeout: 1)
            XCTAssertEqual(recorder.texts(), [])
        }

        /// A daemon handoff replays the whole transcript through the live surface, so every OSC 52 the
        /// scrollback carried fires this callback again. Those must not reach the owner — re-pasting a
        /// copy from before a daemon update would destroy whatever the user has on their clipboard now.
        /// The decision is read here, at the callback, because the delivery hop lands after the replay
        /// bracket has already closed.
        func testWritesDuringTranscriptReplayAreRefused() async throws {
            let recorder = ClipboardWriteRecorder()
            recorder.received.isInverted = true
            let userData = await makeSurfaceUserData(recorder)
            userData.setReplayingHistoricalOutput(true)
            let pointer = Unmanaged.passUnretained(userData).toOpaque()

            withContent(mime: "text/plain", data: "copied before the update") { content, count in
                GhosttyEmbeddedClipboardWriteForwarder.forward(
                    userdata: pointer, location: GHOSTTY_CLIPBOARD_STANDARD, content: content, count: count)
            }

            await fulfillment(of: [recorder.received], timeout: 1)
            XCTAssertEqual(recorder.texts(), [])
        }

        /// Once the replay bracket closes, live copies forward again — the suppression is a window, not
        /// a permanent state a resumed session gets stuck in.
        func testWritesResumeAfterTranscriptReplay() async throws {
            let recorder = ClipboardWriteRecorder()
            let userData = await makeSurfaceUserData(recorder)
            userData.setReplayingHistoricalOutput(true)
            userData.setReplayingHistoricalOutput(false)
            let pointer = Unmanaged.passUnretained(userData).toOpaque()

            withContent(mime: "text/plain", data: "copied after the update") { content, count in
                GhosttyEmbeddedClipboardWriteForwarder.forward(
                    userdata: pointer, location: GHOSTTY_CLIPBOARD_STANDARD, content: content, count: count)
            }

            await fulfillment(of: [recorder.received], timeout: 5)
            XCTAssertEqual(recorder.texts(), ["copied after the update"])
        }
    }
#endif
