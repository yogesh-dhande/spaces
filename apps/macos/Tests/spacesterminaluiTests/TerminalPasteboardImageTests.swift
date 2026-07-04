import AppKit
import XCTest

@testable import spacesterminalui

final class TerminalPasteboardImageTests: XCTestCase {
    private func pasteboard() -> NSPasteboard {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("terminal-pasteboard-image-\(UUID().uuidString)"))
        pasteboard.clearContents()
        return pasteboard
    }

    private func imageData(type: NSBitmapImageRep.FileType, width: Int = 4, height: Int = 4) throws -> Data {
        let bitmap = try XCTUnwrap(
            NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: width * 4, bitsPerPixel: 32))
        for x in 0..<width {
            for y in 0..<height {
                bitmap.setColor(
                    NSColor(calibratedRed: CGFloat(x) / CGFloat(width), green: CGFloat(y) / CGFloat(height), blue: 0.5, alpha: 1), atX: x, y: y)
            }
        }
        return try XCTUnwrap(bitmap.representation(using: type, properties: [:]))
    }

    func testReadsPNGImageData() throws {
        let pasteboard = pasteboard()
        pasteboard.setData(try imageData(type: .png), forType: .png)

        let image = try XCTUnwrap(TerminalPasteboardImageReader.readImage(from: pasteboard).image)

        XCTAssertEqual(image.fileExtension, "png")
        XCTAssertFalse(image.imageData.isEmpty)
    }

    func testReadsJPEGImageData() throws {
        let pasteboard = pasteboard()
        pasteboard.setData(try imageData(type: .jpeg), forType: NSPasteboard.PasteboardType("public.jpeg"))

        let image = try XCTUnwrap(TerminalPasteboardImageReader.readImage(from: pasteboard).image)

        XCTAssertEqual(image.fileExtension, "jpg")
        XCTAssertFalse(image.imageData.isEmpty)
    }

    func testNormalizesTIFFImageDataToPNG() throws {
        let pasteboard = pasteboard()
        pasteboard.setData(try imageData(type: .tiff), forType: .tiff)

        let image = try XCTUnwrap(TerminalPasteboardImageReader.readImage(from: pasteboard).image)

        XCTAssertEqual(image.fileExtension, "png")
        XCTAssertNotNil(NSBitmapImageRep(data: image.imageData))
    }

    func testReadsImageFileURL() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let imageURL = root.appendingPathComponent("paste-source.png")
        try imageData(type: .png).write(to: imageURL)
        let pasteboard = pasteboard()
        pasteboard.writeObjects([imageURL as NSURL])

        let image = try XCTUnwrap(TerminalPasteboardImageReader.readImage(from: pasteboard).image)

        XCTAssertEqual(image.fileExtension, "png")
        XCTAssertEqual(image.imageData, try Data(contentsOf: imageURL))
    }

    func testRejectsOversizedImageFileURL() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let imageURL = root.appendingPathComponent("oversized.png")
        XCTAssertTrue(FileManager.default.createFile(atPath: imageURL.path, contents: nil))
        let handle = try FileHandle(forWritingTo: imageURL)
        try handle.truncate(atOffset: UInt64(TerminalPasteboardImage.maxByteCount + 1))
        try handle.close()
        let pasteboard = pasteboard()
        pasteboard.writeObjects([imageURL as NSURL])

        let result = TerminalPasteboardImageReader.readImage(from: pasteboard)

        XCTAssertEqual(result, .rejected("Image paste is limited to 10 MiB."))
    }

    func testRejectsOversizedPasteboardImageDataBeforeDecoding() throws {
        let pasteboard = pasteboard()
        pasteboard.setData(Data(repeating: 0, count: TerminalPasteboardImage.maxByteCount + 1), forType: .png)

        let result = TerminalPasteboardImageReader.readImage(from: pasteboard)

        XCTAssertEqual(result, .rejected("Image paste is limited to 10 MiB."))
    }

    func testTextPasteboardReportsNoImage() {
        let pasteboard = pasteboard()
        pasteboard.setString("not an image", forType: .string)

        XCTAssertEqual(TerminalPasteboardImageReader.readImage(from: pasteboard), .noImage)
    }
}
