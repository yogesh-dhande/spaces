// GhosttyKit is the macOS embedded terminal binary; the bridge under test only exists there.
#if os(macOS)
    import AppKit
    import Foundation
    import GhosttyKit
    import XCTest
    import spacesterminalcore

    @testable import spacesterminalghostty

    /// Records whether `NSPasteboard` ever realized this item's data, so a test can prove a listing
    /// request inspected only declared types and never touched the payload.
    private final class RecordingClipboardDataProvider: NSObject, NSPasteboardItemDataProvider {
        private(set) var wasCalled = false

        func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
            wasCalled = true
            item.setData(Data("hello from provider".utf8), forType: type)
        }
    }

    final class GhosttyClipboardBridgeTests: XCTestCase {
        /// Builds a `GhosttyEmbeddedSurfaceUserData` with no backing surface (the completion hop is a
        /// no-op) and hands back the opaque pointer `readClipboard` expects as `userdata`.
        private func makeUserDataPointer() async -> (GhosttyEmbeddedSurfaceUserData, UnsafeMutableRawPointer) {
            let userData = await TerminalEngineActor.run {
                GhosttyEmbeddedSurfaceUserData(closeHandler: {}, surfaceProvider: { nil }, clipboardWriteHandler: { _ in })
            }
            return (userData, Unmanaged.passUnretained(userData).toOpaque())
        }

        private func makePrivatePasteboard() -> NSPasteboard {
            NSPasteboard(name: NSPasteboard.Name("spaces-test-\(UUID().uuidString)"))
        }

        func testPreferredPlainTextSelectsTextPlainPayload() {
            let plainMime = strdup("text/plain;charset=utf-8")
            let plainData = strdup("hello from clipboard")
            let imageMime = strdup("image/png")
            let imageData = strdup("binary")
            defer {
                free(plainMime)
                free(plainData)
                free(imageMime)
                free(imageData)
            }

            let payloads = [
                ghostty_clipboard_content_s(mime: imageMime, data: imageData, len: strlen("binary")),
                ghostty_clipboard_content_s(mime: plainMime, data: plainData, len: strlen("hello from clipboard")),
            ]

            let text = payloads.withUnsafeBufferPointer { GhosttyClipboardBridge.preferredPlainText(from: $0) }
            XCTAssertEqual(text, "hello from clipboard")
        }

        func testPreferredPlainTextReturnsNilWithoutPlainTextEntry() {
            let imageMime = strdup("image/png")
            let imageData = strdup("binary")
            defer {
                free(imageMime)
                free(imageData)
            }

            let payloads = [ghostty_clipboard_content_s(mime: imageMime, data: imageData, len: strlen("binary"))]

            let text = payloads.withUnsafeBufferPointer { GhosttyClipboardBridge.preferredPlainText(from: $0) }
            XCTAssertNil(text)
        }

        /// `data` is binary-safe and length-delimited, not necessarily NUL-terminated: a payload whose
        /// `len` is shorter than its underlying NUL-terminated string must yield only the first `len`
        /// bytes, not the full string.
        func testPreferredPlainTextHonorsExplicitLength() {
            let plainMime = strdup("text/plain")
            let plainData = strdup("hello from clipboard")
            defer {
                free(plainMime)
                free(plainData)
            }

            let payloads = [ghostty_clipboard_content_s(mime: plainMime, data: plainData, len: 5)]

            let text = payloads.withUnsafeBufferPointer { GhosttyClipboardBridge.preferredPlainText(from: $0) }
            XCTAssertEqual(text, "hello")
        }

        /// Spaces has one system clipboard, so a Kitty OSC 5522 read with loc=primary (or a
        /// selection-clipboard read) must be reported unsupported before anything touches the pasteboard,
        /// not served from `NSPasteboard.general` as though it were the standard clipboard. `list: true`
        /// is deliberate: with the standard location that combination returns STARTED even against an
        /// empty clipboard (see `testPreferredPlainTextReturnsNilWithoutPlainTextEntry`'s sibling
        /// behavior in `readClipboard`), so getting UNSUPPORTED here proves the location check runs
        /// before the list/mimes handling, not that the clipboard happened to be empty.
        func testReadClipboardRejectsNonStandardLocations() async throws {
            let userData = await TerminalEngineActor.run {
                GhosttyEmbeddedSurfaceUserData(closeHandler: {}, surfaceProvider: { nil }, clipboardWriteHandler: { _ in })
            }
            let pointer = Unmanaged.passUnretained(userData).toOpaque()

            for location in [GHOSTTY_CLIPBOARD_PRIMARY, GHOSTTY_CLIPBOARD_SELECTION] {
                let result = GhosttyClipboardBridge.readClipboard(
                    userdata: pointer, location: location, state: nil, mimes: nil, mimesCount: 0, list: true)
                XCTAssertEqual(result, GHOSTTY_CLIPBOARD_READ_UNSUPPORTED)
            }

            // Keep userData alive through the assertions above.
            withExtendedLifetime(userData) {}
        }

        /// A list-only request (mimesCount == 0, list == true, Kitty paste-event mode probing for MIME
        /// types) must inspect the pasteboard's declared types only, never realize an item's data
        /// provider. Confirmed empirically: `NSPasteboard.types` reads declared UTIs without invoking a
        /// data provider, so the bridge under test uses it for this check.
        func testListOnlyReadDoesNotLoadClipboardData() async {
            let pasteboard = makePrivatePasteboard()
            defer { pasteboard.releaseGlobally() }
            pasteboard.clearContents()

            let provider = RecordingClipboardDataProvider()
            let item = NSPasteboardItem()
            item.setDataProvider(provider, forTypes: [.string])
            pasteboard.writeObjects([item])

            let (userData, pointer) = await makeUserDataPointer()

            let result = GhosttyClipboardBridge.readClipboard(
                userdata: pointer, location: GHOSTTY_CLIPBOARD_STANDARD, state: nil, mimes: nil, mimesCount: 0,
                list: true, pasteboard: pasteboard)

            XCTAssertEqual(result, GHOSTTY_CLIPBOARD_READ_STARTED)
            XCTAssertFalse(provider.wasCalled, "a list-only request must not realize the pasteboard's data provider")

            withExtendedLifetime(userData) {}
        }

        /// Under the length-delimited ABI a zero-byte text/plain payload is a valid representation: an
        /// empty (but present) string on the pasteboard must be served, not reported UNAVAILABLE.
        func testEmptyPlainTextIsServedNotReportedUnavailable() async {
            let pasteboard = makePrivatePasteboard()
            defer { pasteboard.releaseGlobally() }
            pasteboard.clearContents()
            pasteboard.setString("", forType: .string)

            let (userData, pointer) = await makeUserDataPointer()

            let mime = strdup("text/plain")
            defer { free(mime) }
            let mimes: [UnsafePointer<CChar>?] = [UnsafePointer(mime)]

            let result = mimes.withUnsafeBufferPointer { buffer in
                GhosttyClipboardBridge.readClipboard(
                    userdata: pointer, location: GHOSTTY_CLIPBOARD_STANDARD, state: nil, mimes: buffer.baseAddress,
                    mimesCount: 1, list: false, pasteboard: pasteboard)
            }

            XCTAssertEqual(result, GHOSTTY_CLIPBOARD_READ_STARTED)

            withExtendedLifetime(userData) {}
        }

        /// A pasteboard with no string type at all has no plain text to serve, so a non-listing read
        /// reports UNAVAILABLE rather than starting a completion with empty contents.
        func testReadWithNoPlainTextIsUnavailable() async {
            let pasteboard = makePrivatePasteboard()
            defer { pasteboard.releaseGlobally() }
            pasteboard.clearContents()

            let (userData, pointer) = await makeUserDataPointer()

            let mime = strdup("text/plain")
            defer { free(mime) }
            let mimes: [UnsafePointer<CChar>?] = [UnsafePointer(mime)]

            let result = mimes.withUnsafeBufferPointer { buffer in
                GhosttyClipboardBridge.readClipboard(
                    userdata: pointer, location: GHOSTTY_CLIPBOARD_STANDARD, state: nil, mimes: buffer.baseAddress,
                    mimesCount: 1, list: false, pasteboard: pasteboard)
            }

            XCTAssertEqual(result, GHOSTTY_CLIPBOARD_READ_UNAVAILABLE)

            withExtendedLifetime(userData) {}
        }

        /// A listing request always completes, even against an empty clipboard: the caller learns there
        /// is nothing available rather than the request failing outright.
        func testListOnlyReadWithNoTextStartsWithEmptyAvailability() async {
            let pasteboard = makePrivatePasteboard()
            defer { pasteboard.releaseGlobally() }
            pasteboard.clearContents()

            let (userData, pointer) = await makeUserDataPointer()

            let result = GhosttyClipboardBridge.readClipboard(
                userdata: pointer, location: GHOSTTY_CLIPBOARD_STANDARD, state: nil, mimes: nil, mimesCount: 0,
                list: true, pasteboard: pasteboard)

            XCTAssertEqual(result, GHOSTTY_CLIPBOARD_READ_STARTED)

            withExtendedLifetime(userData) {}
        }
    }
#endif
