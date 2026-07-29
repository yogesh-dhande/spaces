import Foundation

#if canImport(GhosttyKit)
    import GhosttyKit
#endif

public enum GhosttyActionEvent: Sendable, Equatable {
    public enum OpenURLKind: Sendable, Equatable {
        case unknown
        case text
        case html

        #if canImport(GhosttyKit)
            init(_ kind: ghostty_action_open_url_kind_e) {
                switch kind {
                case GHOSTTY_ACTION_OPEN_URL_KIND_TEXT: self = .text
                case GHOSTTY_ACTION_OPEN_URL_KIND_HTML: self = .html
                default: self = .unknown
                }
            }
        #endif
    }

    case setTitle(String)
    case setWorkingDirectory(String)
    /// The program rang the terminal bell (BEL, or an OSC that ends in one). Tag-only: Ghostty carries no
    /// payload with it, and the count is not meaningful either — its terminal layer already debounces
    /// repeats at 100 ms, so the event says the session rang, not how often.
    case ringBell
    case openURL(kind: OpenURLKind, value: String)
    case mouseOverLink(String?)
    case startSearch(String?)
    case endSearch
    case searchTotal(Int?)
    case searchSelected(Int?)
}

#if canImport(GhosttyKit)
    enum GhosttyActionEventParser {
        static func parse(_ action: ghostty_action_s) -> GhosttyActionEvent? {
            switch action.tag {
            case GHOSTTY_ACTION_SET_TITLE, GHOSTTY_ACTION_SET_TAB_TITLE:
                guard let title = action.action.set_title.title else { return nil }
                return .setTitle(String(cString: title))
            case GHOSTTY_ACTION_PWD:
                guard let pwd = action.action.pwd.pwd else { return nil }
                return .setWorkingDirectory(String(cString: pwd))
            case GHOSTTY_ACTION_OPEN_URL:
                let openURL = action.action.open_url
                guard let value = string(pointer: openURL.url, count: Int(openURL.len)), !value.isEmpty else { return nil }
                return .openURL(kind: GhosttyActionEvent.OpenURLKind(openURL.kind), value: value)
            case GHOSTTY_ACTION_MOUSE_OVER_LINK:
                let link = action.action.mouse_over_link
                guard link.len > 0 else { return .mouseOverLink(nil) }
                return .mouseOverLink(string(pointer: link.url, count: link.len))
            case GHOSTTY_ACTION_START_SEARCH:
                guard let needle = action.action.start_search.needle else { return .startSearch(nil) }
                let value = String(cString: needle)
                return .startSearch(value.isEmpty ? nil : value)
            case GHOSTTY_ACTION_RING_BELL: return .ringBell
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

        private static func string(pointer: UnsafePointer<CChar>?, count: Int) -> String? {
            guard let pointer, count > 0 else { return nil }
            let data = Data(bytes: pointer, count: count)
            return String(data: data, encoding: .utf8)
        }
    }
#endif
