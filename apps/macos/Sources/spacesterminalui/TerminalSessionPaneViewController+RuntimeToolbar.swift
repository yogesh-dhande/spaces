import AppKit
import Foundation
import spacesterminalcore
import spacesterminalghostty

extension TerminalSessionPaneViewController {
    public func setRuntimeControls(_ controls: TerminalSessionRuntimeControls?) {
        runtimeControls = controls
        runtimeControlsDirty = false
        updateRuntimeToolbar()
    }

    public func markRuntimeControlsDirty() { runtimeControlsDirty = true }

    func configureRuntimeToolbarButton(_ button: NSButton, symbol: String, tooltip: String, action: Selector) {
        button.translatesAutoresizingMaskIntoConstraints = false
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)
        button.imagePosition = .imageOnly
        button.bezelStyle = .texturedRounded
        button.isBordered = false
        button.contentTintColor = .secondaryLabelColor
        button.toolTip = tooltip
        button.target = self
        button.action = action
    }

    @objc func runRuntimeFromToolbar() { runtimeControls?.onRun?() }

    @objc func stopRuntimeFromToolbar() { runtimeControls?.onStop?() }

    @objc func restartRuntimeFromToolbar() { runtimeControls?.onRestart?() }

    func refreshRuntimeControlsIfNeeded(force: Bool = false) {
        guard force || runtimeControlsDirty else { return }
        runtimeControlsDirty = false
        guard let runtimeControlsProvider else {
            updateRuntimeToolbar()
            return
        }
        runtimeControls = runtimeControlsProvider(sessionID)
        updateRuntimeToolbar()
    }

    private func updateRuntimeToolbar() {
        guard let runtimeControls, runtimeControls.hasActions else {
            runtimeToolbarStackView.isHidden = true
            runtimeToolbarRunButton.isHidden = true
            runtimeToolbarStopButton.isHidden = true
            runtimeToolbarRestartButton.isHidden = true
            updateHeaderLayoutVisibility()
            return
        }
        runtimeToolbarTitleLabel.stringValue = runtimeControls.title
        runtimeToolbarTitleLabel.isHidden = true
        runtimeToolbarStackView.isHidden = false
        runtimeToolbarRunButton.isHidden = !runtimeControls.canRun
        runtimeToolbarStopButton.isHidden = !runtimeControls.canStop
        runtimeToolbarRestartButton.isHidden = !runtimeControls.canRestart
        runtimeToolbarRunButton.isEnabled = runtimeControls.onRun != nil
        runtimeToolbarStopButton.isEnabled = runtimeControls.onStop != nil
        runtimeToolbarRestartButton.isEnabled = runtimeControls.onRestart != nil
        updateHeaderLayoutVisibility()
    }
}
