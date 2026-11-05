import BackgroundTasks
import Foundation

enum BackgroundSync {
    /// Must match BGTaskSchedulerPermittedIdentifiers in Info.plist ($(APP_BUNDLE_ID).refresh).
    static var identifier: String {
        (Bundle.main.bundleIdentifier ?? "com.fitsyncapp.ios") + ".refresh"
    }

    /// Asks iOS to wake the app in roughly an hour. iOS may run it later, or skip it
    /// if the app is rarely used; launching the app always syncs anyway.
    static func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 60 * 60)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            // Fails on the simulator and when Background App Refresh is off. Not fatal.
            print("BGTaskScheduler submit failed: \(error)")
        }
    }
}
