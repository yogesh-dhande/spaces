import SwiftUI

/// Puts the device's outstanding restorable record to the user: the coding agents whose work was cut
/// short, grouped by the workspace they were working in, with the two answers the record takes.
///
/// All or nothing, like the Mac's offer: the record is one capture of one moment's work, and picking
/// through it row by row is a decision the user would have to make before seeing any of the sessions
/// again. That is also why the sheet has no dismiss affordance and cannot be swiped away: leaving
/// without answering would leave the record standing and raise the same question on the next refresh.
struct SessionRestoreOfferSheet: View {
    @Bindable var model: SpacesMobileAppModel
    let offer: SessionRestoreOffer

    /// What the answer in flight is doing, so the buttons report progress instead of going silently
    /// inert for the length of a relaunch.
    @State private var answerInProgress: String?
    /// Why the last answer did not land. The sheet stays open carrying it so the same answer can be
    /// tried again, or skipped instead.
    @State private var failureMessage: String?

    var body: some View {
        NavigationStack {
            List {
                Section { intro.bandListRow() }
                ForEach(offer.groups) { group in
                    Section {
                        HeaderBand {
                            Text(group.heading).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1).truncationMode(
                                .middle)
                        }.bandListHeaderRow()
                    }
                    // One section per row, as on the Spaces tab: a row leaving a surviving section is the
                    // update the collection view miscounts.
                    ForEach(group.rows) { row in Section { sessionRow(row, groupHeading: group.heading) } }
                }
            }.listStyle(.plain).listSectionSpacing(0).background(Theme.bg).scrollContentBackground(.hidden).navigationTitle("Unfinished sessions")
                .navigationBarTitleDisplayMode(.inline).safeAreaInset(edge: .bottom) { actions }
        }.tint(Theme.accent).interactiveDismissDisabled().accessibilityIdentifier("restore-sessions.sheet")
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("These coding agents were running when Spaces on \(offer.deviceName) last stopped.").font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.text)
            Text(
                "Restoring brings every one of them back in the workspace it was working in, resuming its conversation where it reported one. Skip lets them go, and Spaces does not offer them again."
            ).font(.system(size: 13)).foregroundStyle(Theme.mutedSecondary)
        }.fixedSize(horizontal: false, vertical: true).padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 4)
    }

    private func sessionRow(_ row: SessionRestoreOffer.Row, groupHeading: String) -> some View {
        // No status dot: these sessions ended, so there is no run state for one to carry, and the row
        // holds the dot's slot empty to stay aligned with the rows above and below it.
        //
        // The directory is dropped when the group is already headed by it, which is every group on a
        // device whose workspace names this client has not loaded yet: the row would otherwise repeat the
        // heading verbatim one line below it.
        BandRow(
            dotKind: nil, tile: TypeIconTile.tile(for: .codingAgents), title: row.displayLabel,
            detail: row.workingDirectory == groupHeading ? "" : row.workingDirectory
        ) {
            if row.startsNewConversation {
                // The agent never reported a conversation id, so its relaunch cannot resume anything. Said
                // here rather than hidden behind the Restore button, because it changes what the user gets
                // back: the same command in the same place, with none of the conversation.
                Text("New conversation").font(.system(size: 11)).foregroundStyle(Theme.mutedSecondary)
            }
        }.bandListRow().accessibilityIdentifier("restore-sessions-row-\(row.sessionID)")
    }

    private var actions: some View {
        VStack(spacing: 10) {
            status
            HStack(spacing: 12) {
                Button {
                    answer(.skip, progress: "Discarding…")
                } label: {
                    Text("Skip").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.muted).frame(maxWidth: .infinity).padding(
                        .vertical, 12
                    ).background(Theme.surface2, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }.buttonStyle(.plain).disabled(answerInProgress != nil).accessibilityIdentifier("restore-sessions-skip")
                Button {
                    answer(.restore, progress: "Restoring…")
                } label: {
                    Text("Restore all")
                }.buttonStyle(BrandPrimaryButtonStyle()).disabled(answerInProgress != nil).accessibilityIdentifier("restore-sessions-restore")
            }
        }.padding(.horizontal, 20).padding(.vertical, 14).background(Theme.bg)
    }

    /// One line above the buttons: what the answer in flight is doing, or why the last one did not land.
    /// Never both, because an answer in flight has not failed yet and a failure has nothing in flight.
    @ViewBuilder private var status: some View {
        if let answerInProgress {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(answerInProgress).font(.system(size: 12)).foregroundStyle(Theme.mutedSecondary)
            }.frame(maxWidth: .infinity, alignment: .leading)
        } else if let failureMessage {
            Text(failureMessage).font(.system(size: 12)).foregroundStyle(Theme.red).multilineTextAlignment(.leading).fixedSize(
                horizontal: false, vertical: true
            ).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Sends one answer. The sheet closes on its own when the model retires the offer, which is what an
    /// answer the device accepted (or refused as stale) does; a message means the answer never landed,
    /// so the question stays on screen.
    private func answer(_ answer: SessionRestoreAnswer, progress: String) {
        answerInProgress = progress
        failureMessage = nil
        Task {
            failureMessage = await model.answerSessionRestoreOffer(answer, offer: offer)
            answerInProgress = nil
        }
    }
}
