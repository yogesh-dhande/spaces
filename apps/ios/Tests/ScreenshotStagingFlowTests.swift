#if canImport(UIKit)
    import UIKit
    import XCTest
    import spacesterminalcore
    @testable import SpacesMobile

    final class ScreenshotStagingFlowTests: XCTestCase {
        private func makePNGData() -> Data {
            let renderer = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4))
            let image = renderer.image { context in
                UIColor.systemTeal.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
            }
            guard let data = image.pngData() else {
                XCTFail("Expected renderer to produce PNG data.")
                return Data()
            }
            return data
        }

        func testMakeStagedScreenshotStagesValidatedPNG() throws {
            let capturedAt = Date(timeIntervalSince1970: 1_700_000_000)

            let screenshot = try ScreenshotStager.makeStagedScreenshot(
                pngData: makePNGData(), sourceTitle: "Preview server", capturedAt: capturedAt)

            XCTAssertEqual(screenshot.payload.fileExtension, "png")
            XCTAssertFalse(screenshot.payload.imageData.isEmpty)
            XCTAssertEqual(screenshot.sourceTitle, "Preview server")
            XCTAssertEqual(screenshot.capturedAt, capturedAt)
            XCTAssertGreaterThan(screenshot.thumbnail.size.width, 0)
            XCTAssertGreaterThan(screenshot.thumbnail.size.height, 0)
        }

        func testMakeStagedScreenshotRejectsOversizedData() {
            let oversized = Data(count: TerminalImageAttachmentPayload.maxByteCount + 1)

            XCTAssertThrowsError(
                try ScreenshotStager.makeStagedScreenshot(pngData: oversized, sourceTitle: "shell", capturedAt: .now)
            ) { error in
                XCTAssertEqual(error as? TerminalImageAttachmentValidationError, .imageTooLarge)
            }
        }

        func testMakeStagedScreenshotRejectsUndecodableBytes() {
            // Passes size/extension validation but is not a real image, so the thumbnail decode fails.
            let bogus = Data([0x01, 0x02, 0x03, 0x04])

            XCTAssertThrowsError(
                try ScreenshotStager.makeStagedScreenshot(pngData: bogus, sourceTitle: "shell", capturedAt: .now)
            ) { error in
                XCTAssertEqual(error as? ScreenshotStagerError, .undecodableImage)
            }
        }
    }
#endif
