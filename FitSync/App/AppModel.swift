import Foundation
import Observation
import SwiftData

/// UI-facing state. All syncing is delegated to `SyncEngine`, which guarantees that
/// only one sync runs at a time. Syncs only start from the Sync button.
@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    let auth: GoogleAuth
    let engine: SyncEngine
    let writer: HealthKitWriter

    var isSignedIn: Bool
    var isSyncing = false
    var syncProgress: String?
    var lastReport: SyncReport?
    var lastError: String?
    var healthAccess: HealthKitWriter.Access = .full
    /// Toggling it shows the Apple Health permission sheet (`healthDataAccessRequest` in ContentView).
    var healthAccessRequest = false
    var lastSyncDate: Date? = UserDefaults.standard.object(forKey: Keys.lastSync) as? Date

    var lookbackDays: Int = {
        let v = UserDefaults.standard.integer(forKey: Keys.lookback)
        return v == 0 ? 3 : v
    }()

    /// Called by the UI when the lookback stepper changes.
    func saveLookback() {
        UserDefaults.standard.set(lookbackDays, forKey: Keys.lookback)
    }

    private enum Keys {
        static let lastSync = "lastSuccessfulSync"
        static let lookback = "lookbackDays"
    }

    private init() {
        let container: ModelContainer
        do {
            container = try ModelContainer(for: LedgerEntry.self)
        } catch {
            fatalError("Could not open the sync ledger: \(error)")
        }
        auth = GoogleAuth(config: .fromInfoPlist())
        writer = HealthKitWriter()
        engine = SyncEngine(
            client: GoogleHealthClient(auth: auth),
            writer: writer,
            ledger: LedgerStore(modelContainer: container)
        )
        isSignedIn = GoogleAuth.hasStoredTokens
    }

    // MARK: Account

    func signIn() async {
        lastError = nil
        do {
            try await auth.signIn()
            isSignedIn = true
            requestHealthAccess()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func signOut() async {
        await auth.signOut()
        isSignedIn = false
    }

    func requestHealthAccess() {
        healthAccessRequest.toggle()
    }

    func healthAccessRequestFinished(_ result: Result<Bool, Error>) async {
        if case let .failure(error) = result { lastError = error.localizedDescription }
        await refreshHealthAccess()
    }

    /// Called on launch, after the permission sheet, and when the app comes back to the
    /// foreground, since access can change in Settings.
    func refreshHealthAccess() async {
        healthAccess = await writer.access()
    }

    // MARK: Syncing (manual only)

    func syncNow() async {
        guard isSignedIn else { return }
        isSyncing = true
        lastError = nil
        defer { isSyncing = false; syncProgress = nil }

        let firstRun = lastSyncDate == nil
        do {
            let report = try await engine.sync(
                lookbackDays: firstRun ? SyncEngine.initialBackfillDays : lookbackDays,
                progress: { [weak self] text in Task { @MainActor in self?.syncProgress = text } }
            )
            lastReport = report
            if report.isComplete {
                lastSyncDate = report.finishedAt
                UserDefaults.standard.set(report.finishedAt, forKey: Keys.lastSync)
            } else if let failure = report.failures.first {
                lastError = failure
            }
        } catch {
            lastError = error.localizedDescription
        }
    }
}
