import Foundation
import UIKit
import spacesterminalcore

/// Pure "PNG bytes → `StagedScreenshot`" step shared by the browser screenshot flow, factored out so the
/// validation and thumbnail-decode logic can be unit tested without a live web view or the Markup UI.
enum ScreenshotStager {
    static func makeStagedScreenshot(pngData: Data, sourceTitle: String, capturedAt: Date) throws -> StagedScreenshot {
        let payload = try TerminalImageAttachmentPayload.validated(fileExtension: "png", imageData: pngData)
        guard let thumbnail = UIImage(data: pngData) else {
            throw ScreenshotStagerError.undecodableImage
        }
        return StagedScreenshot(payload: payload, thumbnail: thumbnail, capturedAt: capturedAt, sourceTitle: sourceTitle)
    }
}

enum ScreenshotStagerError: Error, Equatable {
    /// The bytes passed validation (non-empty, within the size cap, `png` extension) but `UIImage` could
    /// not decode them into a thumbnail.
    case undecodableImage
}
