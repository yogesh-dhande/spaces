import SwiftUI

@main struct SpacesMobileApp: App {
    @State private var model = SpacesMobileAppModel()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
        }
    }
}
