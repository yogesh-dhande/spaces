import Foundation
import GhosttyKit
import XCTest

@testable import spacesterminalghostty

final class GhosttyClipboardBridgeTests: XCTestCase {
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

        let payloads = [ghostty_clipboard_content_s(mime: imageMime, data: imageData), ghostty_clipboard_content_s(mime: plainMime, data: plainData)]

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

        let payloads = [ghostty_clipboard_content_s(mime: imageMime, data: imageData)]

        let text = payloads.withUnsafeBufferPointer { GhosttyClipboardBridge.preferredPlainText(from: $0) }
        XCTAssertNil(text)
    }
}
