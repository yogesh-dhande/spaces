import AppKit
import Testing

@testable import spacesui

/// The one thing about the compatibility block that only AppKit can answer: that every state builds and
/// lays out as a hero rather than collapsing. A wrapping label's intrinsic width is its narrowest, so
/// without a stated measure the block folds into a tall column of two-word lines that still satisfies
/// every constraint — a defect no content test can see.
@Suite @MainActor struct CompatibilityBlockLayoutTests {
    @Test func everyStateLaysOutAsAWideBlockRatherThanACollapsedColumn() {
        let states:
            [(
                label: String, remedy: CompatibilityBlockView.BlockRemedy, isLocalDevice: Bool, isLinuxDaemon: Bool, canUpdateOverSSH: Bool,
                isUpdatingOverSSH: Bool
            )] = [
                ("Linux over SSH", .installUpdateOnDevice(daemonVersion: "0.1.0"), false, true, true, false),
                ("Linux updating over SSH", .installUpdateOnDevice(daemonVersion: "0.1.0"), false, true, true, true),
                ("Linux command only", .installUpdateOnDevice(daemonVersion: "0.1.0"), false, true, false, false),
                ("local Mac, no daemon version", .installUpdateOnDevice(daemonVersion: nil), true, false, false, false),
                ("remote Mac", .installUpdateOnDevice(daemonVersion: "0.1.0"), false, false, false, false),
                ("staged update on Linux", .applyStagedUpdate(daemonVersion: "0.8.7", installedVersion: "0.9.2"), false, true, false, false),
                ("staged update on a Mac", .applyStagedUpdate(daemonVersion: "0.8.7", installedVersion: "0.9.2"), false, false, false, false),
                ("this app too old", .updateClient(daemonVersion: "0.3.0"), false, false, false, false),
            ]
        for state in states {
            let block = CompatibilityBlockView(
                remedy: state.remedy, deviceName: "lantern", isLocalDevice: state.isLocalDevice, isLinuxDaemon: state.isLinuxDaemon,
                canUpdateOverSSH: state.canUpdateOverSSH, isUpdatingOverSSH: state.isUpdatingOverSSH, onRetryStagedApply: {}, onCheckForUpdates: {},
                onUpdateOverSSH: {})
            // The same placement the detail pane gives it: centered, free to size itself under a cap.
            let pane = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 700))
            block.translatesAutoresizingMaskIntoConstraints = false
            pane.addSubview(block)
            NSLayoutConstraint.activate([
                block.centerXAnchor.constraint(equalTo: pane.centerXAnchor), block.centerYAnchor.constraint(equalTo: pane.centerYAnchor),
                block.widthAnchor.constraint(lessThanOrEqualToConstant: 460),
            ])
            pane.layoutSubtreeIfNeeded()
            #expect(block.frame.width >= 300, "\(state.label) laid out \(block.frame.width) pt wide")
            #expect(block.frame.height > 0 && block.frame.height <= 320, "\(state.label) laid out \(block.frame.height) pt tall")
        }
    }
}
