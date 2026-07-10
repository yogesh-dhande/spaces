import XCTest

@testable import spacesterminalcore

final class TerminalImageAttachmentPayloadTests: XCTestCase {
    func testValidatedRejectsEmptyImageData() {
        XCTAssertThrowsError(try TerminalImageAttachmentPayload.validated(fileExtension: "png", imageData: Data())) { error in
            XCTAssertEqual(error as? TerminalImageAttachmentValidationError, .emptyImageData)
        }
    }

    func testValidatedRejectsOversizedImageData() {
        let oversized = Data(repeating: 0, count: TerminalImageAttachmentPayload.maxByteCount + 1)
        XCTAssertThrowsError(try TerminalImageAttachmentPayload.validated(fileExtension: "png", imageData: oversized)) { error in
            XCTAssertEqual(error as? TerminalImageAttachmentValidationError, .imageTooLarge)
        }
    }

    func testValidatedRejectsUnsupportedFileExtension() {
        XCTAssertThrowsError(try TerminalImageAttachmentPayload.validated(fileExtension: "txt", imageData: Data([0x01]))) { error in
            XCTAssertEqual(error as? TerminalImageAttachmentValidationError, .unsupportedFileExtension)
        }
    }

    func testValidatedNormalizesUppercaseFileExtension() throws {
        let payload = try TerminalImageAttachmentPayload.validated(fileExtension: "PNG", imageData: Data([0x01, 0x02]))

        XCTAssertEqual(payload.fileExtension, "png")
    }

    func testValidatedPreservesImageDataOnHappyPath() throws {
        let imageData = Data([0x89, 0x50, 0x4E, 0x47])

        let payload = try TerminalImageAttachmentPayload.validated(fileExtension: " jpg ", imageData: imageData)

        XCTAssertEqual(payload.fileExtension, "jpg")
        XCTAssertEqual(payload.imageData, imageData)
    }
}
