import SwiftUI
import spacesterminalcore

@main struct SpacesMobileApp: App {
    @State private var model = SpacesMobileAppModel()
    @AppStorage(AppAppearanceStorage.key) private var appearanceMode: AppAppearanceMode = .default

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .preferredColorScheme(appearanceMode.colorScheme)
        }
    }
}
