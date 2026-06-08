import Foundation
import GhosttyKit

public enum GhosttyActionEvent: Sendable, Equatable {
    case setTitle(String)
    case setWorkingDirectory(String)
    case startSearch(String?)
    case endSearch
    case searchTotal(Int?)
    case searchSelected(Int?)
}

enum GhosttyActionEventParser {
    static func parse(_ action: ghostty_action_s) -> GhosttyActionEvent? {
        switch action.tag {
        case GHOSTTY_ACTION_SET_TITLE, GHOSTTY_ACTION_SET_TAB_TITLE:
            guard let title = action.action.set_title.title else { return nil }
            return .setTitle(String(cString: title))
        case GHOSTTY_ACTION_PWD:
            guard let pwd = action.action.pwd.pwd else { return nil }
            return .setWorkingDirectory(String(cString: pwd))
        case GHOSTTY_ACTION_START_SEARCH:
            guard let needle = action.action.start_search.needle else { return .startSearch(nil) }
            let value = String(cString: needle)
            return .startSearch(value.isEmpty ? nil : value)
        case GHOSTTY_ACTION_END_SEARCH: return .endSearch
        case GHOSTTY_ACTION_SEARCH_TOTAL:
            let total = action.action.search_total.total
            return .searchTotal(total >= 0 ? Int(total) : nil)
        case GHOSTTY_ACTION_SEARCH_SELECTED:
            let selected = action.action.search_selected.selected
            return .searchSelected(selected >= 0 ? Int(selected) : nil)
        default: return nil
        }
    }
}
