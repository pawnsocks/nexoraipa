import SwiftUI

@main
struct PocketHostApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .task { await model.start() }
                .onChange(of: scenePhase) { phase in
                    model.handleScenePhase(phase)
                }
        }
    }
}
