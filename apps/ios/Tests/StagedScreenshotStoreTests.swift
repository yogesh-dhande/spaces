#if canImport(UIKit)
    import UIKit
    import XCTest
    import spacesterminalcore
    @testable import SpacesMobile

    @MainActor
    final class StagedScreenshotStoreTests: XCTestCase {
        private func makeThumbnail() -> UIImage {
            UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1)).image { context in
                UIColor.black.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
            }
        }

        private func makeScreenshot(sourceTitle: String = "shell") -> StagedScreenshot {
            StagedScreenshot(
                payload: TerminalImageAttachmentPayload(fileExtension: "png", imageData: Data([0x01, 0x02])),
                thumbnail: makeThumbnail(),
                capturedAt: Date(),
                sourceTitle: sourceTitle
            )
        }

        func testStagedIsNilInitially() {
            let store = StagedScreenshotStore()

            XCTAssertNil(store.staged)
        }

        func testStageReplacesExistingStagedScreenshot() {
            let store = StagedScreenshotStore()
            store.stage(makeScreenshot(sourceTitle: "first"))

            store.stage(makeScreenshot(sourceTitle: "second"))

            XCTAssertEqual(store.staged?.sourceTitle, "second")
        }

        func testTakeReturnsAndClearsStagedScreenshot() {
            let store = StagedScreenshotStore()
            store.stage(makeScreenshot())

            let taken = store.take()

            XCTAssertEqual(taken?.sourceTitle, "shell")
            XCTAssertNil(store.staged)
            XCTAssertNil(store.take())
        }

        func testClearEmptiesStagedScreenshot() {
            let store = StagedScreenshotStore()
            store.stage(makeScreenshot())

            store.clear()

            XCTAssertNil(store.staged)
        }
    }
#endif
