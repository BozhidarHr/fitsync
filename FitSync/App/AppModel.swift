import Foundation
import Observation
import SwiftData

/// UI-facing state. All syncing is delegated to `SyncEngine`, which guarantees that
/// only one sync runs at a time no matter how many triggers fire.
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

    /// The launch trigger only syncs when the last sync is older than this.
    private let staleAfter: TimeInterval = 15 * 60

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
            try await writer.requestAuthorization()
            await syncNow()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func signOut() async {
        await auth.signOut()
        isSignedIn = false
    }

    func requestHealthAccess() async {
        do { try await writer.requestAuthorization() } catch { lastError = error.localizedDescription }
    }

    // MARK: Triggers (all go through the same engine)

    func syncNow() async {
        await run(.manual)
    }

    func syncIfStale() async {
        guard isSignedIn else { return }
        if let last = lastSyncDate, Date().timeIntervalSince(last) < staleAfter { return }
        await run(.launch)
    }

    func runBackgroundSync() async {
        guard isSignedIn else { return }
        await run(.background)
    }

    private func run(_ reason: SyncReason) async {
        guard isSignedIn else { return }
        isSyncing = true
        lastError = nil
        defer { isSyncing = false; syncProgress = nil }

        let firstRun = lastSyncDate == nil
        do {
            let report = try await engine.sync(
                reason: reason,
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
