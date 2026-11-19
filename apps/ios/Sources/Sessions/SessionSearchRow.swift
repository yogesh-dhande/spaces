import SwiftUI
import spacesdevicecore

/// One conversation in the results: agent badge, title (the pin's name with a pin mark when pinned), the
/// matching excerpt with the query's words emphasized, and where and when it ran. A conversation that
/// cannot be resumed says why and shows its id instead of acting on tap.
struct SessionSearchRow: View {
    let hit: SpacesDeviceAgentSessionHit
    let query: String
    let now: Date
    /// The message of a failed resume of this row.
    let failure: String?
    let onTap: () -> Void
    @ScaledMetric private var badgeSize: CGFloat = 34

    private var isResumable: Bool { hit.resumability == .resumable }

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .top, spacing: 12) {
                Text(hit.agent.tileText).font(.caption2.weight(.bold)).foregroundStyle(Theme.mutedSecondary).frame(
                    width: badgeSize, height: badgeSize
                ).background(Theme.surface2, in: RoundedRectangle(cornerRadius: 8, style: .continuous)).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    title
                    if let excerpt = hit.excerpt, !excerpt.isEmpty {
                        Text(highlighted(excerpt)).font(.footnote).foregroundStyle(Theme.muted).lineLimit(2)
                    }
                    Text(SessionSearchRowText.meta(of: hit, relativeTo: now)).font(.caption).foregroundStyle(Theme.mutedSecondary).lineLimit(2)
                    if !isResumable {
                        Text(SessionSearchRowText.folderMissing(sessionKey: hit.sessionKey)).font(.caption).foregroundStyle(Theme.mutedSecondary)
                    }
                    if let failure { Text(failure).font(.caption).foregroundStyle(Theme.red) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.padding(.vertical, 11).frame(minHeight: 44).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityElement(children: .ignore).accessibilityLabel(accessibilityLabel).accessibilityAddTraits(.isButton)
            .accessibilityIdentifier("sessions.row.\(hit.listID)").contextMenu {
                Button {
                    UIPasteboard.general.string = hit.sessionKey
                } label: {
                    Label("Copy Session ID", systemImage: "doc.on.doc")
                }
            }
    }

    @ViewBuilder private var title: some View {
        if let pinned = hit.pinnedName {
            HStack(spacing: 5) {
                Image(systemName: "pin.fill").font(.caption).foregroundStyle(Theme.mutedSecondary).accessibilityHidden(true)
                Text(pinned).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.text).lineLimit(1)
            }
        } else {
            Text(hit.title).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.text).lineLimit(1)
        }
    }

    private func highlighted(_ excerpt: String) -> AttributedString {
        var text = AttributedString(excerpt)
        for range in SessionSearchHighlight.ranges(in: excerpt, query: query) {
            guard let attributed = Range(range, in: text) else { continue }
            text[attributed].foregroundColor = Theme.text
            text[attributed].font = .footnote.weight(.semibold)
        }
        return text
    }

    private var accessibilityLabel: String {
        var parts = [hit.agent.displayName, hit.pinnedName.map { "Pinned, \($0)" } ?? hit.title]
        if let excerpt = hit.excerpt, !excerpt.isEmpty { parts.append(excerpt) }
        parts.append(SessionSearchRowText.meta(of: hit, relativeTo: now))
        if !isResumable { parts.append(SessionSearchRowText.folderMissing(sessionKey: hit.sessionKey)) }
        if let failure { parts.append(failure) }
        return parts.joined(separator: ". ")
    }
}
