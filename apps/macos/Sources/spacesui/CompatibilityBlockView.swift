import AppKit
import spacesclientcore
import spacesterminalcore
import workspacecore

/// Full-pane block shown when a device's daemon is wire-incompatible with this app. The situation is a
/// version gap, so the block is built as a version hero: an orange eyebrow naming the state, the two
/// versions the gap spans, a quiet line saying whose versions those are, one sentence of pitch, and at
/// most one action.
///
/// Rendering is driven by `DaemonUpdateRemedy` (via `blockRemedy(verdict:status:)`), not the raw
/// `SpacesWireCompatibility` verdict: a too-old daemon with nothing staged on its device
/// (`.installUpdateOnDevice`) cannot be fixed by a restart — that would just re-exec the same binary and
/// leave the block stuck — so every OS in that state shows install guidance instead of a button:
///   - Linux: the version-pinned `install.sh` one-liner. When the device's pairing stored SSH details,
///     an "Update over SSH" button runs that same installer on the device from here and the one-liner
///     demotes to a small line under it; without SSH details the one-liner is the block's main element.
///     Either way it stays on screen, as the fallback for a device Spaces cannot reach over SSH.
///   - A remote Mac: instructions to open Spaces on that device and install the update there.
///   - This Mac (the local daemon): a "Check for Updates…" button wired to Sparkle, when available.
/// `.applyStagedUpdate` — a newer build already installed on the device — is not rendered at all while
/// Spaces is applying that build by itself; the block appears for it only once the apply did not land
/// (see `AppKitController.shouldRenderCompatibilityBlock`), and then offers "Try Again".
final class CompatibilityBlockView: NSView {
    /// What the block renders, carrying exactly the version facts each case is guaranteed to have (so
    /// `content(...)` never needs to invent placeholder text for data it doesn't have). Produced by
    /// `blockRemedy(verdict:status:)`, which is `nil` for a device that needs no block at all.
    enum BlockRemedy: Equatable {
        /// This client's own app build must update. `daemonVersion` is `nil` only in the no-status
        /// conservative fallback (see `blockRemedy`); once a status is known it is always present.
        case updateClient(daemonVersion: String?)
        /// A newer build is installed on the device and a restart applies it — the only case with an
        /// action button. Both versions are guaranteed non-nil: this case is only produced from
        /// a status whose `isUpdatePending` is true, which by definition requires a staged
        /// `installedVersion`, and `version` (the daemon's own running build) is never optional.
        case applyStagedUpdate(daemonVersion: String, installedVersion: String)
        /// The daemon is too old and nothing newer is staged; `daemonVersion` is `nil` only in the
        /// no-status conservative fallback.
        case installUpdateOnDevice(daemonVersion: String?)

        /// The only case whose block carries a Try Again action, because it is the only one Spaces can
        /// resolve by asking the device to apply what is already installed on it.
        var offersStagedApplyRetry: Bool {
            if case .applyStagedUpdate = self { return true }
            return false
        }

        /// The staged build this remedy is waiting on, so the caller can match it against the attempt it
        /// fired; `nil` for every remedy that is not waiting on one.
        var stagedVersion: String? {
            if case .applyStagedUpdate(_, let installedVersion) = self { return installedVersion }
            return nil
        }

        /// The only case an Update-over-SSH run is trying to resolve, so it is also the only one whose
        /// presence justifies keeping that run's in-progress state alive.
        var isInstallUpdateOnDevice: Bool {
            if case .installUpdateOnDevice = self { return true }
            return false
        }
    }

    /// The two versions the hero spans, shared with iOS as `DaemonVersionPair` (see
    /// `spacesterminalcore/DaemonCompatibilityCopy.swift`) so both clients' version heroes state the same
    /// two numbers the same way. `.unknown` stands in for a version this state has no fact for: the
    /// daemon version in the no-status fallback, and the target on a Mac, where what lands is whatever
    /// the user chooses to install.
    typealias VersionPair = DaemonVersionPair

    /// Pure "what should the block show" descriptor, independent of AppKit so it is unit-testable
    /// without instantiating a view. `actionButtonTitle == nil` means no button is rendered.
    struct Content: Equatable {
        /// Orange, letter-spaced, uppercase: the one place severity is stated, so no warning icon is
        /// needed and no other element has to carry alarm.
        let eyebrow: String
        /// The version gap itself, rendered as the block's largest element.
        let versionPair: VersionPair
        /// Quiet line under the pair saying whose versions those are and how the fix travels.
        let whoLine: String
        /// One sentence of pitch: what the action does, in the user's terms.
        let body: String
        /// Quieter line under the body, for the one state with something to say about waiting.
        let footnote: String?
        let installerCommand: String?
        let actionButtonTitle: String?
        /// Whether a spinner accompanies the copy, for the one state that waits on work Spaces itself
        /// started: the Update-over-SSH installer run.
        let showsProgress: Bool
    }

    private let onAction: (() -> Void)?

    init(
        remedy: BlockRemedy, deviceName: String, isLocalDevice: Bool, isLinuxDaemon: Bool, canUpdateOverSSH: Bool, isUpdatingOverSSH: Bool,
        onRetryStagedApply: (() -> Void)?, onCheckForUpdates: (() -> Void)?, onUpdateOverSSH: (() -> Void)?
    ) {
        let content = Self.content(
            remedy: remedy, deviceName: deviceName, isLocalDevice: isLocalDevice, isLinuxDaemon: isLinuxDaemon, clientVersion: AppVersion.short,
            canCheckForUpdates: onCheckForUpdates != nil, canUpdateOverSSH: canUpdateOverSSH, isUpdatingOverSSH: isUpdatingOverSSH)
        // Only one of these is ever the button's target for a given remedy — see `content(...)`, which
        // decides the button's *title*, and this switch, which picks the matching closure. The caller
        // (`AppKitController`) already withholds whichever closure isn't justified for this device, so at
        // most one is non-nil in practice. `.installUpdateOnDevice` splits by device: this Mac checks for
        // an app update, any other device runs the installer over SSH when its pairing allows it.
        switch remedy {
        case .applyStagedUpdate: onAction = onRetryStagedApply
        case .installUpdateOnDevice: onAction = isLocalDevice ? onCheckForUpdates : onUpdateOverSSH
        case .updateClient: onAction = nil
        }
        super.init(frame: .zero)

        // No card: the block already owns the whole detail pane, so a border and a fill around content
        // that has nothing to sit beside would be chrome for its own sake. The eyebrow carries the
        // severity the old orange frame was carrying.
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 0  // every gap is set explicitly below, since the hero's rhythm is not uniform
        stack.translatesAutoresizingMaskIntoConstraints = false

        let eyebrow = NSTextField(labelWithAttributedString: Self.eyebrowText(content.eyebrow))
        stack.addArrangedSubview(eyebrow)
        stack.setCustomSpacing(14, after: eyebrow)

        let pair = Self.versionPairRow(content.versionPair)
        stack.addArrangedSubview(pair)
        stack.setCustomSpacing(8, after: pair)

        let whoLine = NSTextField(labelWithString: content.whoLine)
        whoLine.font = Typography.metadata
        whoLine.textColor = Theme.mutedSecondary
        stack.addArrangedSubview(whoLine)
        stack.setCustomSpacing(18, after: whoLine)

        let body = NSTextField(wrappingLabelWithString: content.body)
        body.font = Typography.body
        body.textColor = Theme.muted
        body.alignment = .center
        // A wrapping label's intrinsic width is its narrowest, so without a stated measure the whole
        // hero collapses to a tall column of two-word lines. This is the sentence's line length, and
        // it sets the block's width; the pane caps it well above this.
        body.preferredMaxLayoutWidth = Self.bodyMeasure
        // The spinner belongs to the sentence that says what is running, so it sits beside it rather
        // than floating as its own row.
        let bodyRow: NSView
        if content.showsProgress {
            let row = NSStackView()
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 8
            let spinner = NSProgressIndicator()
            spinner.style = .spinning
            spinner.controlSize = .small
            spinner.isDisplayedWhenStopped = false
            spinner.startAnimation(nil)
            row.addArrangedSubview(spinner)
            row.addArrangedSubview(body)
            bodyRow = row
        } else {
            bodyRow = body
        }
        stack.addArrangedSubview(bodyRow)
        stack.setCustomSpacing(content.footnote == nil ? 18 : 6, after: bodyRow)

        if let footnote = content.footnote {
            let label = NSTextField(labelWithString: footnote)
            label.font = Typography.metadata
            label.textColor = Theme.mutedSecondary
            stack.addArrangedSubview(label)
            stack.setCustomSpacing(18, after: label)
        }

        if let actionButtonTitle = content.actionButtonTitle, onAction != nil {
            let button = NSButton(title: actionButtonTitle, target: self, action: #selector(actionTapped))
            Theme.applyPrimaryStyle(to: button)
            button.keyEquivalent = "\r"
            stack.addArrangedSubview(button)
            stack.setCustomSpacing(18, after: button)
        }

        if let installerCommand = content.installerCommand {
            // The command is the block's main element only when it is the whole fix (a Linux device
            // Spaces cannot reach over SSH). Everywhere else something else already resolves the block,
            // so the command demotes to a quiet fallback line the user can still copy.
            let isPrimary = content.actionButtonTitle == nil && !content.showsProgress
            stack.addArrangedSubview(Self.commandView(installerCommand, isPrimary: isPrimary))
        }

        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 18), stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -18),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { nil }

    @objc private func actionTapped() { onAction?() }

    // MARK: - Hero elements

    /// Line length for the block's wrapping text, in points. One measure for the body sentence and the
    /// command, so the block reads as one column rather than as elements of differing widths.
    private static let bodyMeasure: CGFloat = 340

    /// Uppercase and letter-spaced so a 11 pt line reads as a label for what follows rather than as
    /// another sentence. Orange is confined to this string.
    private static func eyebrowText(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [.font: Typography.metadataTitle, .foregroundColor: Theme.orange, .kern: 1.2])
    }

    /// `from → to`, at the largest role the chrome scale has. Digit-monospaced so the two versions
    /// align on their dots instead of drifting apart, and colored rather than weighted to say which
    /// side has to move: the scale carries one weight per size, and color separates the two more
    /// legibly at this size anyway.
    private static func versionPairRow(_ pair: VersionPair) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = 12
        let font = Typography.tabularDigits(Typography.pageTitle)
        for (text, color) in [(pair.from, Theme.mutedSecondary), ("\u{2192}", Theme.accent), (pair.to, Theme.text)] {
            let label = NSTextField(labelWithString: text)
            label.font = font
            label.textColor = color
            row.addArrangedSubview(label)
        }
        return row
    }

    /// The copyable command. Selectable in both treatments — the point of showing it is that it can be
    /// carried to the device by hand.
    private static func commandView(_ command: String, isPrimary: Bool) -> NSView {
        let label = NSTextField(labelWithString: command)
        label.isSelectable = true
        label.isEditable = false
        label.lineBreakMode = .byCharWrapping
        label.maximumNumberOfLines = 0
        label.alignment = .center
        label.preferredMaxLayoutWidth = bodyMeasure
        label.translatesAutoresizingMaskIntoConstraints = false
        guard isPrimary else {
            label.font = Typography.monoCaption
            label.textColor = Theme.mutedSecondary
            return label
        }
        label.font = Typography.monoBody
        label.textColor = Theme.text
        let box = NSView()
        box.translatesAutoresizingMaskIntoConstraints = false
        // Binds first: it is what turns the layer on, so anything set on `layer` before it is dropped.
        bindAppearanceReactiveLayer(box) { $0.layer?.backgroundColor = Theme.chipBg.cgColor }
        box.layer?.cornerRadius = 5
        box.addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: box.topAnchor, constant: 8), label.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -8),
            label.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -12),
        ])
        return box
    }

    // MARK: - Content

    /// Maps a device's verdict/status onto what the block should render, or `nil` when the device needs
    /// no block at all (a compatible, up-to-date daemon).
    ///
    /// Without a `status` there is no installed-version fact to justify a staged-update or
    /// "nothing to do" story, so this falls back to a deliberate conservative reading of the verdict
    /// alone: too-old-client still means update this app, too-old-daemon still means *some* update is
    /// needed on that device, but neither carries a version number or offers an action button. This
    /// fallback is reachable in principle (a verdict known before its paired status has landed), unlike
    /// the cases below, which is why it stays a real branch rather than an assertion.
    nonisolated static func blockRemedy(verdict: SpacesWireCompatibility, status: TerminalServiceDaemonStatus?) -> BlockRemedy? {
        guard let status else {
            switch verdict {
            case .clientTooOld: return .updateClient(daemonVersion: nil)
            case .daemonTooOld: return .installUpdateOnDevice(daemonVersion: nil)
            case .compatible: return nil
            }
        }
        switch DaemonUpdateRemedy.remedy(for: status) {
        case .none: return nil
        case .updateClient: return .updateClient(daemonVersion: nonEmpty(status.version))
        case .applyStagedUpdate(let installedVersion): return .applyStagedUpdate(daemonVersion: status.version, installedVersion: installedVersion)
        case .installUpdateOnDevice: return .installUpdateOnDevice(daemonVersion: nonEmpty(status.version))
        }
    }

    /// Builds the block's copy and button choice for `remedy`. `clientVersion` plays no part in picking
    /// the eyebrow, body, or button below; `remedy` already encodes every decision, and a client must
    /// never re-derive one by comparing its own build against a daemon's (unrelated release trains — see
    /// `DaemonUpdateRemedy`). It survives here for two uses that are not comparisons: naming this app's
    /// own build as one side of the version pair, and pinning the Linux installer command — and with it
    /// the version that installer would land — to the version this app ships with.
    nonisolated static func content(
        remedy: BlockRemedy, deviceName: String, isLocalDevice: Bool, isLinuxDaemon: Bool, clientVersion: String, canCheckForUpdates: Bool,
        canUpdateOverSSH: Bool, isUpdatingOverSSH: Bool
    ) -> Content {
        switch remedy {
        case .updateClient(let daemonVersion):
            // The pair reads left to right as "the thing that must move, then where it must get to", so
            // here it is this app's build against the daemon's. That is a statement of the two builds in
            // play, not a comparison: which one is behind came from the wire verdict.
            return Content(
                eyebrow: DaemonCompatibilityCopy.updateClientEyebrow,
                versionPair: VersionPair(from: clientVersion, to: daemonVersion ?? VersionPair.unknown),
                whoLine: DaemonCompatibilityCopy.updateClientWhoLine(deviceName: deviceName),
                body: "\(deviceName) speaks a newer connection protocol than this app, so update this app to reconnect to it.", footnote: nil,
                installerCommand: nil, actionButtonTitle: nil, showsProgress: false)

        case .applyStagedUpdate(let daemonVersion, let installedVersion):
            // Reached only after the requested apply did not land: while Spaces is applying the staged
            // build there is nothing for the user to do, so the caller withholds the block entirely
            // (`AppKitController.shouldRenderCompatibilityBlock`). The dialog Spaces raised once carries
            // the long form, including the by-hand instruction for a Mac; what stays behind it is the
            // same facts short — what is installed, what is running, that nothing was interrupted —
            // plus the retry, and on Linux the command that applies the build on the device by hand.
            //
            // The wording never calls the apply a failure: a daemon that is slow to restart and one that
            // refused look identical from here, so this reports what has not happened.
            return Content(
                eyebrow: DaemonCompatibilityCopy.stagedUpdateNotLandedEyebrow, versionPair: VersionPair(from: daemonVersion, to: installedVersion),
                whoLine: DaemonCompatibilityCopy.stagedUpdateNotLandedWhoLine(installedVersion: installedVersion, deviceName: deviceName),
                body: DaemonCompatibilityCopy.stagedUpdateNotLandedBody(deviceName: deviceName), footnote: nil,
                installerCommand: isLinuxDaemon ? linuxApplyStagedUpdateCommand : nil, actionButtonTitle: "Try Again", showsProgress: false)

        case .installUpdateOnDevice(let daemonVersion):
            let eyebrow = "CAN'T CONNECT — DAEMON NEEDS AN UPDATE"
            let runningVersion = daemonVersion ?? VersionPair.unknown
            if isLinuxDaemon {
                // The installer is pinned to this app's version, so that is exactly what the device ends
                // up running — the one state where the target side of the pair is a fact and not a hope.
                let installerCommand = SpacesLinuxInstaller.installCommand(version: clientVersion)
                let pair = VersionPair(from: runningVersion, to: clientVersion)
                if isUpdatingOverSSH {
                    return Content(
                        eyebrow: eyebrow, versionPair: pair, whoLine: "\(deviceName) · over SSH",
                        body: "Updating \(deviceName) — a few minutes, nothing stops.", footnote: "Safe to leave this screen.",
                        installerCommand: installerCommand, actionButtonTitle: nil, showsProgress: true)
                }
                if canUpdateOverSSH {
                    return Content(
                        eyebrow: eyebrow, versionPair: pair, whoLine: "\(deviceName) · over SSH",
                        body: "Update \(deviceName) over SSH without stopping anything it's running.", footnote: nil,
                        installerCommand: installerCommand, actionButtonTitle: "Update over SSH", showsProgress: false)
                }
                return Content(
                    eyebrow: eyebrow, versionPair: pair, whoLine: "run on \(deviceName)",
                    body: "Run this on \(deviceName) — nothing it's running stops.", footnote: nil, installerCommand: installerCommand,
                    actionButtonTitle: nil, showsProgress: false)
            }
            // A Mac has no headless installer to pin a target to: what lands is whatever the user
            // installs there, so the target side stays an honest hole.
            let pair = VersionPair(from: runningVersion, to: VersionPair.unknown)
            if isLocalDevice {
                return Content(
                    eyebrow: eyebrow, versionPair: pair, whoLine: deviceName,
                    body: "Update Spaces on this Mac; its daemon applies the update on its own, and nothing running stops.", footnote: nil,
                    installerCommand: nil, actionButtonTitle: canCheckForUpdates ? "Check for Updates…" : nil, showsProgress: false)
            }
            return Content(
                eyebrow: eyebrow, versionPair: pair, whoLine: deviceName,
                body: "Open Spaces on \(deviceName) and install the update; its daemon applies it on its own, and nothing running stops.",
                footnote: nil, installerCommand: nil, actionButtonTitle: nil, showsProgress: false)
        }
    }

    /// Copy for a device that still reports a staged build its daemon is not running some time after
    /// Spaces asked it to apply that build in place. One shape for every device: what is installed, what
    /// is still running, that nothing on the device was disturbed, and the one instruction that applies
    /// the build on that kind of device by hand.
    struct StagedApplyDidNotLandCopy: Equatable {
        let title: String
        let body: String
        let instruction: String
        /// The command the user runs on the device, when the instruction is a command — Linux only.
        let command: String?
    }

    /// The command that applies a staged build on a Linux device by hand. Loading the staged daemon in
    /// place is what the RPC asks for too, so running it resolves the same state without disturbing the
    /// device's sessions.
    static let linuxApplyStagedUpdateCommand = "~/.spaces/bin/spaces daemon apply-update"

    /// Builds `StagedApplyDidNotLandCopy` for one device, for the dialog Spaces raises once when an
    /// apply it requested has not landed.
    ///
    /// The wording never calls the apply a failure: a daemon that is slow to restart and one that refused
    /// look identical from here, so this reports what has not happened rather than a verdict.
    nonisolated static func stagedApplyDidNotLandCopy(
        deviceName: String, stagedVersion: String, runningVersion: String, isLocalDevice: Bool, isLinuxDaemon: Bool
    ) -> StagedApplyDidNotLandCopy {
        let body =
            "Spaces \(stagedVersion) is installed on \(deviceName), but its daemon is still running \(runningVersion) after the update was "
            + "requested. Nothing running on \(deviceName) was interrupted."
        // The instruction stops at the colon for Linux: the dialog renders `command` itself, under the
        // informative text next to Copy Command.
        if isLinuxDaemon {
            return StagedApplyDidNotLandCopy(
                title: "\(deviceName)'s daemon didn't pick up the update", body: body, instruction: "Run this on \(deviceName) to apply it:",
                command: linuxApplyStagedUpdateCommand)
        }
        let instruction =
            isLocalDevice
            ? "Use Restart Local Daemon in Spaces settings to apply it here."
            : "Open Spaces on \(deviceName); its daemon applies the update when it restarts."
        return StagedApplyDidNotLandCopy(
            title: "\(deviceName)'s daemon didn't pick up the update", body: body, instruction: instruction, command: nil)
    }

    private nonisolated static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}
