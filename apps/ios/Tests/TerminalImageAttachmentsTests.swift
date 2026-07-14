#if canImport(UIKit)
    import UIKit
    import UniformTypeIdentifiers
    import XCTest
    import spacesterminalcore
    @testable import SpacesMobile

    final class TerminalImageAttachmentsTests: XCTestCase {
        private func makeImage() -> UIImage {
            UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { context in
                UIColor.red.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
            }
        }

        private func withPasteboard(_ body: (UIPasteboard) -> Void) {
            let pasteboard = UIPasteboard.withUniqueName()
            defer { UIPasteboard.remove(withName: pasteboard.name) }
            body(pasteboard)
        }

        func testReadsPNGDataAsPNGAttachment() {
            let png = try? XCTUnwrap(makeImage().pngData())
            withPasteboard { pasteboard in
                pasteboard.setData(png ?? Data(), forPasteboardType: UTType.png.identifier)
                let result = TerminalUIPasteboardImageReader.readImage(from: pasteboard)
                let attachment = try? XCTUnwrap(result.image)
                XCTAssertEqual(attachment?.payload.fileExtension, "png")
                XCTAssertEqual(attachment?.sourceLabel, "Clipboard")
                XCTAssertFalse(attachment?.payload.imageData.isEmpty ?? true)
            }
        }

        func testReadsJPEGDataAsJPGAttachment() {
            let jpeg = makeImage().jpegData(compressionQuality: 0.8) ?? Data()
            withPasteboard { pasteboard in
                pasteboard.setData(jpeg, forPasteboardType: UTType.jpeg.identifier)
                let result = TerminalUIPasteboardImageReader.readImage(from: pasteboard)
                XCTAssertEqual(result.image?.payload.fileExtension, "jpg")
            }
        }

        func testNormalizesRawPasteboardImageToPNG() {
            withPasteboard { pasteboard in
                pasteboard.image = makeImage()
                let result = TerminalUIPasteboardImageReader.readImage(from: pasteboard)
                let attachment = result.image
                XCTAssertNotNil(attachment, "A raw pasteboard image should be read as an attachment.")
                if let attachment {
                    XCTAssertTrue(TerminalImageAttachmentPayload.supportedFileExtensions.contains(attachment.payload.fileExtension))
                    XCTAssertNotNil(UIImage(data: attachment.payload.imageData), "The normalized attachment data should decode as an image.")
                }
            }
        }

        func testRejectsOversizedImageWithSizeMessage() {
            let oversized = Data(count: TerminalImageAttachmentPayload.maxByteCount + 1)
            withPasteboard { pasteboard in
                pasteboard.setData(oversized, forPasteboardType: UTType.png.identifier)
                let result = TerminalUIPasteboardImageReader.readImage(from: pasteboard)
                guard case .rejected(let message) = result else {
                    XCTFail("Expected an oversized image to be rejected, got \(result).")
                    return
                }
                XCTAssertTrue(message.localizedStandardContains("10 MiB"), message)
            }
        }

        func testEmptyPasteboardReturnsNoImage() {
            withPasteboard { pasteboard in
                XCTAssertEqual(TerminalUIPasteboardImageReader.readImage(from: pasteboard), .noImage)
                XCTAssertFalse(TerminalUIPasteboardImageReader.hasImage(pasteboard))
            }
        }

        func testHasImageReflectsPasteboardContents() {
            let png = makeImage().pngData() ?? Data()
            withPasteboard { pasteboard in
                XCTAssertFalse(TerminalUIPasteboardImageReader.hasImage(pasteboard))
                pasteboard.setData(png, forPasteboardType: UTType.png.identifier)
                XCTAssertTrue(TerminalUIPasteboardImageReader.hasImage(pasteboard))
            }
        }
    }
#endif
