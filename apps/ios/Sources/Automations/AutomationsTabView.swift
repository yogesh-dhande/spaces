import SwiftUI

/// Automations tab shell: hosts `AutomationsListView` as the tab's root. A thin wrapper (rather than
/// folding the `NavigationStack` into `AutomationsListView` itself) keeps the list view reusable as
/// plain content that unit tests can construct directly without a navigation container.
struct AutomationsTabView: View {
    @Bindable var model: SpacesMobileAppModel

    var body: some View { NavigationStack { AutomationsListView(model: model) }.accessibilityIdentifier("tab.automations") }
}
