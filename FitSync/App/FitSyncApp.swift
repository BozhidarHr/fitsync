import SwiftUI

@main
struct FitSyncApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var model = AppModel.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                Task { await model.syncIfStale() }
            case .background:
                BackgroundSync.schedule()
            default:
                break
            }
        }
        // iOS decides when this runs (usually a few times a day). It goes through the
        // same SyncEngine as the button, so it can never create duplicates.
        .backgroundTask(.appRefresh(BackgroundSync.identifier)) {
            BackgroundSync.schedule() // always queue the next one first
            await AppModel.shared.runBackgroundSync()
        }
    }
}
