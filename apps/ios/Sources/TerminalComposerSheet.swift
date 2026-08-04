import SwiftUI
import UIKit

/// Rich message composer for a terminal session: a text field plus removable image attachments
/// (a staged browser/terminal screenshot or a clipboard image) that are sent as one ordered burst
/// followed by Enter. Presented as a sheet from the terminal detail view.
struct TerminalComposerSheet: View {
    @Bindable var model: TerminalViewerModel
    let stagedScreenshots: StagedScreenshotStore
    @Environment(\.dismiss) private var dismiss

    @State private var hasPasteableContent = false
    @State private var didStartSending = false
    @FocusState private var isMessageFieldFocused: Bool

    private static let thumbnailSize: CGFloat = 56

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // The actions sit above the text field so the software keyboard, which claims the bottom of
            // the sheet as soon as the field takes focus, can never cover them.
            actionBar

            if !model.composerAttachments.isEmpty { attachmentStrip }

            TextField("Message", text: composerDraftText, axis: .vertical).lineLimit(3...6).textFieldStyle(.plain).disabled(
                model.isSendingComposedMessage
            ).allowsHitTesting(!model.isSendingComposedMessage).textInputAutocapitalization(.never).autocorrectionDisabled().foregroundStyle(
                Theme.text
            ).tint(Theme.accent).focused($isMessageFieldFocused).accessibilityIdentifier("composer.message-field")

            if let errorMessage = model.composerErrorMessage {
                Text(errorMessage).font(.footnote).foregroundStyle(Theme.red).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier(
                    "composer.error")
            }
        }.padding(16).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top).background(Theme.bg).presentationDetents([.medium, .large])
            .presentationBackground(Theme.bg).accessibilityIdentifier("composer.sheet").onAppear {
                refreshPasteState()
                focusMessageField()
            }.onReceive(NotificationCenter.default.publisher(for: UIPasteboard.changedNotification)) { _ in refreshPasteState() }.onChange(
                of: model.isSendingComposedMessage
            ) { _, isSending in
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

    /// Focuses the message field just after the sheet settles so the keyboard rises on open. Deferring a
    /// hair avoids the first-present case where claiming first responder mid-transition drops the keyboard.
    private func focusMessageField() { DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { isMessageFieldFocused = true } }

    private var attachmentStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(model.composerAttachments.enumerated()), id: \.element.id) { index, attachment in
                    attachmentThumbnail(attachment, index: index)
                }
            }.padding(.vertical, 2)
        }
    }

    private func attachmentThumbnail(_ attachment: TerminalComposerAttachment, index: Int) -> some View {
        Image(uiImage: attachment.thumbnail).resizable().scaledToFill().frame(width: Self.thumbnailSize, height: Self.thumbnailSize).clipShape(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
        ).overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.border, lineWidth: 1)).overlay(alignment: .topTrailing) {
            Button {
                model.removeComposerAttachment(id: attachment.id)
            } label: {
                Image(systemName: "xmark.circle.fill").font(.system(size: 18)).symbolRenderingMode(.palette).foregroundStyle(
                    .white, .black.opacity(0.55))
            }.padding(2).disabled(model.isSendingComposedMessage).accessibilityLabel("Remove \(attachment.sourceLabel.lowercased())")
        }.accessibilityIdentifier("composer.attachment.\(index)")
    }

    private var actionBar: some View {
        HStack(spacing: 12) {
            if let staged = stagedScreenshots.staged {
                Button {
                    guard let taken = stagedScreenshots.take() else { return }
                    model.attachComposerImage(
                        TerminalComposerAttachment(payload: taken.payload, thumbnail: taken.thumbnail, sourceLabel: "Screenshot"))
                } label: {
                    Image(uiImage: staged.thumbnail).resizable().scaledToFill().frame(width: 28, height: 28).clipShape(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                    ).overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Theme.border, lineWidth: 1))
                }.accessibilityLabel("Attach screenshot").disabled(model.isSendingComposedMessage).accessibilityIdentifier("composer.attach-staged")
            }

            Button {
                pasteClipboard()
            } label: {
                Image(systemName: "doc.on.clipboard").font(.system(size: 18)).foregroundStyle(
                    hasPasteableContent && !model.isSendingComposedMessage ? Theme.accent : Theme.muted)
            }.disabled(model.isSendingComposedMessage || !hasPasteableContent).accessibilityLabel("Paste").accessibilityIdentifier("composer.paste")

            Spacer(minLength: 0)

            Button {
                Task { await model.sendComposedMessage() }
            } label: {
                if model.isSendingComposedMessage {
                    ProgressView().tint(Theme.accent).frame(width: 30, height: 30)
                } else {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 30)).foregroundStyle(
                        model.canSendComposedMessage ? Theme.accent : Theme.muted)
                }
            }.disabled(model.isSendingComposedMessage || !model.canSendComposedMessage).accessibilityLabel("Send message").accessibilityIdentifier(
                "composer.send")
        }
    }

    private var composerDraftText: Binding<String> {
        Binding {
            model.composerDraftText
        } set: { newValue in
            guard !model.isSendingComposedMessage else { return }
            model.composerDraftText = newValue
        }
    }

    /// Both probes read declared pasteboard types only, so the button's enabled state costs no paste
    /// prompt; the data is read in `pasteClipboard()` once the user commits.
    private func refreshPasteState() { hasPasteableContent = TerminalUIPasteboardImageReader.hasImage() || UIPasteboard.general.hasStrings }

    /// Pastes whatever the clipboard holds: an image becomes an attachment, otherwise text is appended to
    /// the draft.
    private func pasteClipboard() {
        guard !model.isSendingComposedMessage else { return }
        guard !model.pasteClipboardImageIntoComposer() else { return }
        pasteClipboardText()
    }

    private func pasteClipboardText() {
        guard let text = UIPasteboard.general.string, !text.isEmpty else {
            model.composerErrorMessage = "There was nothing on the clipboard to paste."
            return
        }
        model.composerDraftText += text
        // A successful paste supersedes whatever a prior attempt reported, same as image attach.
        model.composerErrorMessage = nil
    }
}
