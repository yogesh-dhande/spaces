import Foundation
import Observation
import UIKit
import spacesterminalcore

/// An image staged for paste into a terminal session, along with the thumbnail and provenance
/// shown in the staging UI before the user confirms the paste.
struct StagedScreenshot {
    let payload: TerminalImageAttachmentPayload
    let thumbnail: UIImage
    let capturedAt: Date
    let sourceTitle: String
}

/// Holds at most one staged screenshot in memory, ready to paste into a terminal session's Device
/// API request. Staging a new screenshot replaces any previous one; there is no persistence across
/// app launches since a staged screenshot is only meaningful for the in-flight paste flow.
@MainActor @Observable final class StagedScreenshotStore {
    private(set) var staged: StagedScreenshot?

    func stage(_ screenshot: StagedScreenshot) {
        staged = screenshot
    }

    func take() -> StagedScreenshot? {
        defer { staged = nil }
        return staged
    }

    func clear() {
        staged = nil
    }
}
