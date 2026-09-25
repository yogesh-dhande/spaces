import Foundation
import SwiftUI
import spacesdevicecore

/// A coding agent's brief, read-only, in a sheet over its terminal: the agent's own Markdown rendered
/// by the same markdown-it document the Markdown artifact viewer uses.
///
/// Reads the brief from the app model on every render rather than taking it as a value, so an overview
/// that carries a rewritten brief re-renders the sheet in place.
struct TerminalBriefSheet: View {
    let appModel: SpacesMobileAppModel
    let sessionID: String

    var body: some View {
        let row = appModel.runtimeRow(forSessionID: sessionID)
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Brief").font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.text)
                Spacer(minLength: 0)
                if let updated = Self.updatedDescription(briefUpdatedAt: row?.briefUpdatedAt, relativeTo: appModel.relativeTimeReference) {
                    Text(updated).font(.system(size: 11)).foregroundStyle(Theme.mutedSecondary).lineLimit(1)
                }
            }.padding(.horizontal, 18).padding(.top, 22).padding(.bottom, 4)

            if let brief = row?.brief { TerminalWebArtifactView(load: .htmlString(TerminalMarkdownDocument.makeHTML(markdownSource: brief))) }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top).background(Theme.bg).presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible).presentationBackground(Theme.bg).accessibilityElement(children: .contain).accessibilityIdentifier(
                "brief.sheet")
    }

    /// "Updated 2 min ago" for the header, or nil when the device reported no time for the brief.
    /// `now` is `SpacesMobileAppModel.relativeTimeReference`, which advances in 30-second jumps and can
    /// trail a brief written moments ago; that boundary reads as "just now" rather than in the future
    /// tense the formatter would give it.
    static func updatedDescription(briefUpdatedAt: String?, relativeTo now: Date) -> String? {
        guard let updated = SpacesMobileAttention.date(fromISO8601: briefUpdatedAt) else { return nil }
        guard now > updated else { return "Updated just now" }
        return "Updated \(AutomationRunFormatting.relativePhrase(for: updated, relativeTo: now))"
    }
}
