import AppKit
import Foundation
import spacesterminalcore
import spacesterminalghostty

extension TerminalSessionPaneViewController {
    @objc public func find(_ sender: Any?) {
        if visibleRenderer == .ghosttyOwner {
            _ = performLiveTerminalBindingAction("start_search")
            return
        }
        performOutputTextFinderAction(.showFindInterface)
    }

    @objc public func findNext(_ sender: Any?) {
        if visibleRenderer == .ghosttyOwner {
            _ = performLiveTerminalBindingAction("navigate_search:next")
            return
        }
        performOutputTextFinderAction(.nextMatch)
    }

    @objc public func findPrevious(_ sender: Any?) {
        if visibleRenderer == .ghosttyOwner {
            _ = performLiveTerminalBindingAction("navigate_search:previous")
            return
        }
        performOutputTextFinderAction(.previousMatch)
    }

    @objc public func useSelectionForFind(_ sender: Any?) {
        if visibleRenderer == .ghosttyOwner {
            _ = performLiveTerminalBindingAction("search_selection")
            return
        }
        performOutputTextFinderAction(.setSearchString)
    }

    @objc public func hideFind(_ sender: Any?) {
        if visibleRenderer == .ghosttyOwner || visibleRenderer == .ghosttyEndedFinalRender {
            _ = performLiveTerminalEndSearchAction()
            return
        }
        performOutputTextFinderAction(.hideFindInterface)
    }

    func performOutputTextFinderAction(_ action: NSTextFinder.Action) {
        let sender = NSMenuItem()
        sender.tag = action.rawValue
        window?.makeFirstResponder(outputView)
        outputView.performTextFinderAction(sender)
    }

    @discardableResult private func performLiveTerminalEndSearchAction() -> Bool {
        guard canPerformLiveTerminalReadOnlyAction, ghosttyRendererHost?.debugSearchState.isVisible == true else {
            NSSound.beep()
            return false
        }
        guard ghosttyRendererHost?.performBindingAction("end_search") == true else {
            NSSound.beep()
            return false
        }
        return true
    }
}
