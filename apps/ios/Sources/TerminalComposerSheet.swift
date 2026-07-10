import SwiftUI
import UIKit

/// Rich message composer for a terminal session: a text field plus removable image attachments
/// (a staged browser/terminal screenshot or a clipboard image) that are sent as one ordered burst
/// followed by Enter. Presented as a sheet from the terminal detail view.
struct TerminalComposerSheet: View {
    @Bindable var model: TerminalViewerModel
    let stagedScreenshots: StagedScreenshotStore
    @Environment(\.dismiss) private var dismiss

    @State private var hasPasteableImage = false
    @State private var didStartSending = false

    private static let thumbnailSize: CGFloat = 56

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !model.composerAttachments.isEmpty {
                attachmentStrip
            }

            TextField("Message", text: $model.composerDraftText, axis: .vertical)
                .lineLimit(3...6)
                .textFieldStyle(.plain)
                .foregroundStyle(Theme.text)
                .tint(Theme.accent)
                .accessibilityIdentifier("composer.message-field")

            Spacer(minLength: 0)

            if let errorMessage = model.composerErrorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(Theme.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("composer.error")
            }

            bottomBar
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Theme.bg)
        .presentationDetents([.height(260), .medium])
        .presentationBackground(Theme.bg)
        .accessibilityIdentifier("composer.sheet")
        .onAppear { refreshPasteState() }
        .onReceive(NotificationCenter.default.publisher(for: UIPasteboard.changedNotification)) { _ in
            refreshPasteState()
        }
        .onChange(of: model.isSendingComposedMessage) { isSending in
            if isSending {
                didStartSending = true
            } else if didStartSending {
                didStartSending = false
                // Success clears the draft and leaves no error; a partial failure keeps the draft and
                // sets composerErrorMessage, so stay open for the user to retry.
                if model.composerErrorMessage == nil { dismiss() }
            }
        }
    }

    private var attachmentStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(model.composerAttachments.enumerated()), id: \.element.id) { index, attachment in
                    attachmentThumbnail(attachment, index: index)
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func attachmentThumbnail(_ attachment: TerminalComposerAttachment, index: Int) -> some View {
        Image(uiImage: attachment.thumbnail)
            .resizable()
            .scaledToFill()
            .frame(width: Self.thumbnailSize, height: Self.thumbnailSize)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Theme.border, lineWidth: 1)
            )
            .overlay(alignment: .topTrailing) {
                Button {
                    model.removeComposerAttachment(id: attachment.id)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .black.opacity(0.55))
                }
                .padding(2)
                .accessibilityLabel("Remove \(attachment.sourceLabel.lowercased())")
            }
            .accessibilityIdentifier("composer.attachment.\(index)")
    }

    private var bottomBar: some View {
        HStack(spacing: 12) {
            if let staged = stagedScreenshots.staged {
                Button {
                    guard let taken = stagedScreenshots.take() else { return }
                    model.attachComposerImage(
                        TerminalComposerAttachment(payload: taken.payload, thumbnail: taken.thumbnail, sourceLabel: "Screenshot"))
                } label: {
                    Image(uiImage: staged.thumbnail)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 28, height: 28)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(Theme.border, lineWidth: 1))
                }
                .accessibilityLabel("Attach screenshot")
                .accessibilityIdentifier("composer.attach-staged")
            }

            Button {
                pasteClipboardImage()
            } label: {
                Image(systemName: "doc.on.clipboard")
                    .font(.system(size: 18))
                    .foregroundStyle(hasPasteableImage ? Theme.accent : Theme.muted)
            }
            .disabled(!hasPasteableImage)
            .accessibilityLabel("Paste image")
            .accessibilityIdentifier("composer.paste")

            Spacer(minLength: 0)

            Button {
                Task { await model.sendComposedMessage() }
            } label: {
                if model.isSendingComposedMessage {
                    ProgressView()
                        .tint(Theme.accent)
                        .frame(width: 30, height: 30)
                } else {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 30))
                        .foregroundStyle(model.canSendComposedMessage ? Theme.accent : Theme.muted)
                }
            }
            .disabled(!model.canSendComposedMessage)
            .accessibilityLabel("Send message")
            .accessibilityIdentifier("composer.send")
        }
    }

    private func refreshPasteState() {
        hasPasteableImage = TerminalUIPasteboardImageReader.hasImage()
    }

    private func pasteClipboardImage() {
        switch TerminalUIPasteboardImageReader.readImage() {
        case .image(let attachment):
            model.attachComposerImage(attachment)
        case .rejected(let message):
            model.composerErrorMessage = message
        case .noImage:
            model.composerErrorMessage = "No image was found on the clipboard."
        }
    }
}
