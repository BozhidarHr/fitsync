import SwiftUI

@main
struct FitSyncApp: App {
    @State private var model = AppModel.shared
    @State private var showSplash = true

    // Syncing only ever starts from the Sync button: no launch or background syncs.
    var body: some Scene {
        WindowGroup {
            ZStack {
                ContentView()
                    .environment(model)
                if showSplash {
                    SplashView()
                        .transition(.opacity)
                        .zIndex(1)
                }
            }
            .task {
                try? await Task.sleep(for: .seconds(1))
                withAnimation(.easeOut(duration: 0.3)) { showSplash = false }
            }
        }
    }
}
