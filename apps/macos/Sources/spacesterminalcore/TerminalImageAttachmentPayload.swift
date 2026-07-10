import Foundation

/// Shared image-attachment payload for terminal paste-image flows. Owned by `spacesterminalcore`
/// (which cross-compiles for Linux) so both the macOS pasteboard reader and the iOS Device API
/// client can validate against the same size cap and supported file extensions without either
/// platform depending on AppKit/UIKit here.
public struct TerminalImageAttachmentPayload: Sendable, Equatable {
    public static let maxByteCount = 10 * 1024 * 1024
    public static let supportedFileExtensions: Set<String> = [
        "avif", "bmp", "gif", "heic", "heif", "jpg", "jpeg", "png", "tif", "tiff", "webp",
    ]

    public let fileExtension: String
    public let imageData: Data

    public init(fileExtension: String, imageData: Data) {
        self.fileExtension = fileExtension
        self.imageData = imageData
    }
}

public enum TerminalImageAttachmentValidationError: Error, Equatable {
    case emptyImageData
    case imageTooLarge
    case unsupportedFileExtension
}

extension TerminalImageAttachmentPayload {
    /// Normalizes `fileExtension` (trimmed, lowercased) and validates `imageData` against the
    /// shared size cap and supported-extension set before constructing a payload.
    public static func validated(fileExtension: String, imageData: Data) throws -> TerminalImageAttachmentPayload {
        guard !imageData.isEmpty else { throw TerminalImageAttachmentValidationError.emptyImageData }
        guard imageData.count <= maxByteCount else { throw TerminalImageAttachmentValidationError.imageTooLarge }
        let normalizedExtension = fileExtension.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard supportedFileExtensions.contains(normalizedExtension) else {
            throw TerminalImageAttachmentValidationError.unsupportedFileExtension
        }
        return TerminalImageAttachmentPayload(fileExtension: normalizedExtension, imageData: imageData)
    }
}
