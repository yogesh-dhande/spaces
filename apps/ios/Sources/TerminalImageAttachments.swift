import UIKit
import UniformTypeIdentifiers
import spacesterminalcore

/// An image staged in the terminal message composer, ready to be pasted into a session. The
/// `thumbnail` drives the composer's attachment strip and `sourceLabel` records where the image came
/// from ("Screenshot" from a staged capture, "Clipboard" from a pasteboard read).
struct TerminalComposerAttachment: Identifiable, Equatable {
    let id: UUID
    let payload: TerminalImageAttachmentPayload
    let thumbnail: UIImage
    let sourceLabel: String

    init(id: UUID = UUID(), payload: TerminalImageAttachmentPayload, thumbnail: UIImage, sourceLabel: String) {
        self.id = id
        self.payload = payload
        self.thumbnail = thumbnail
        self.sourceLabel = sourceLabel
    }

    // Identity plus payload/label define equality; the `UIImage` thumbnail is display-only and is not
    // itself `Equatable`, so it is intentionally excluded.
    static func == (lhs: TerminalComposerAttachment, rhs: TerminalComposerAttachment) -> Bool {
        lhs.id == rhs.id && lhs.payload == rhs.payload && lhs.sourceLabel == rhs.sourceLabel
    }
}

/// Result of reading an image off the iOS pasteboard for the composer. Mirrors the macOS
/// `TerminalPasteboardImageReadResult` shape: a validated attachment, no image present, or a rejection
/// message to surface inline (e.g. an oversized image).
enum TerminalUIPasteboardImageReadResult: Equatable {
    case image(TerminalComposerAttachment)
    case noImage
    case rejected(String)

    var image: TerminalComposerAttachment? {
        if case .image(let attachment) = self { return attachment }
        return nil
    }
}

enum TerminalUIPasteboardImageReader {
    private static let oversizedImageMessage = "Image paste is limited to 10 MiB."
    private static let unreadableImageMessage = "That clipboard image couldn't be read."

    /// Reads a clipboard image without triggering the iOS paste-permission prompt for the type probe.
    /// `UIPasteboard.hasImages` inspects the declared types only, so callers can enable a paste control
    /// before the user commits to reading the image data.
    static func hasImage(_ pasteboard: UIPasteboard = .general) -> Bool { pasteboard.hasImages }

    /// Reads and validates the first supported clipboard image. Prefers the encoded representations
    /// (PNG, JPEG, HEIC) so their bytes pass through untouched; falls back to re-encoding a raw
    /// `UIImage` as PNG when the pasteboard only exposes an image object. Reading the data here does
    /// trigger the iOS paste prompt, so call it only in response to an explicit paste action.
    static func readImage(from pasteboard: UIPasteboard = .general) -> TerminalUIPasteboardImageReadResult {
        if let pngData = pasteboard.data(forPasteboardType: UTType.png.identifier) {
            return validatedImage(data: pngData, fileExtension: "png")
        }
        if let jpegData = pasteboard.data(forPasteboardType: UTType.jpeg.identifier) {
            return validatedImage(data: jpegData, fileExtension: "jpg")
        }
        if let heicData = pasteboard.data(forPasteboardType: UTType.heic.identifier) {
            return validatedImage(data: heicData, fileExtension: "heic")
        }
        guard let image = pasteboard.image else { return .noImage }
        guard let pngData = image.pngData() else { return .rejected(unreadableImageMessage) }
        return validatedImage(data: pngData, fileExtension: "png")
    }

    private static func validatedImage(data: Data, fileExtension: String) -> TerminalUIPasteboardImageReadResult {
        do {
            let payload = try TerminalImageAttachmentPayload.validated(fileExtension: fileExtension, imageData: data)
            guard let image = UIImage(data: payload.imageData) else { return .rejected(unreadableImageMessage) }
            return .image(TerminalComposerAttachment(payload: payload, thumbnail: image, sourceLabel: "Clipboard"))
        } catch TerminalImageAttachmentValidationError.imageTooLarge {
            return .rejected(oversizedImageMessage)
        } catch {
            return .rejected(unreadableImageMessage)
        }
    }
}
