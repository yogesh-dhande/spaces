import AppKit
import Foundation

public struct TerminalPasteboardImage: Sendable, Equatable {
    public static let maxByteCount = 10 * 1024 * 1024

    public let fileExtension: String
    public let imageData: Data

    public init(fileExtension: String, imageData: Data) {
        self.fileExtension = fileExtension
        self.imageData = imageData
    }
}

public enum TerminalPasteboardImageReadResult: Equatable {
    case image(TerminalPasteboardImage)
    case noImage
    case rejected(String)

    public var image: TerminalPasteboardImage? {
        if case .image(let image) = self { return image }
        return nil
    }
}

public enum TerminalPasteboardImageReader {
    private static let oversizedImageMessage = "Image paste is limited to 10 MiB."
    private static let jpegType = NSPasteboard.PasteboardType("public.jpeg")
    private static let supportedFileExtensions: Set<String> = [
        "avif", "bmp", "gif", "heic", "heif", "jpg", "jpeg", "png", "tif", "tiff", "webp",
    ]

    public static func readImage(from pasteboard: NSPasteboard = .general) -> TerminalPasteboardImageReadResult {
        if let pngData = pasteboard.data(forType: .png) { return validatedImage(data: pngData, fileExtension: "png") }
        if let jpegData = pasteboard.data(forType: jpegType) { return validatedImage(data: jpegData, fileExtension: "jpg") }
        if let tiffData = pasteboard.data(forType: .tiff) { return normalizedTIFFImage(data: tiffData) }
        return readImageFileURL(from: pasteboard)
    }

    private static func readImageFileURL(from pasteboard: NSPasteboard) -> TerminalPasteboardImageReadResult {
        guard
            let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
            let url = urls.first
        else { return .noImage }
        let fileExtension = url.pathExtension.trimmingCharacters(in: CharacterSet(charactersIn: ".").union(.whitespacesAndNewlines)).lowercased()
        guard supportedFileExtensions.contains(fileExtension) else { return .noImage }
        guard let fileSize = imageFileSize(at: url) else { return .noImage }
        guard fileSize <= TerminalPasteboardImage.maxByteCount else { return .rejected(oversizedImageMessage) }
        guard let data = try? Data(contentsOf: url) else { return .noImage }
        if fileExtension == "tif" || fileExtension == "tiff" { return normalizedTIFFImage(data: data) }
        return validatedImage(data: data, fileExtension: fileExtension)
    }

    private static func normalizedTIFFImage(data: Data) -> TerminalPasteboardImageReadResult {
        guard !data.isEmpty else { return .noImage }
        guard data.count <= TerminalPasteboardImage.maxByteCount else { return .rejected(oversizedImageMessage) }
        guard let pngData = pngData(fromTIFFData: data) else { return .noImage }
        return validatedImage(data: pngData, fileExtension: "png")
    }

    private static func validatedImage(data: Data, fileExtension: String) -> TerminalPasteboardImageReadResult {
        guard !data.isEmpty else { return .noImage }
        guard data.count <= TerminalPasteboardImage.maxByteCount else { return .rejected(oversizedImageMessage) }
        guard NSImage(data: data) != nil else { return .noImage }
        return .image(TerminalPasteboardImage(fileExtension: fileExtension, imageData: data))
    }

    private static func imageFileSize(at url: URL) -> Int? {
        (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
    }

    private static func pngData(fromTIFFData data: Data) -> Data? {
        guard let image = NSImage(data: data), let tiffRepresentation = image.tiffRepresentation,
            let bitmap = NSBitmapImageRep(data: tiffRepresentation)
        else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }
}
