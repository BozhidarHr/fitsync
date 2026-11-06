import Foundation
import os

let syncLog = Logger(subsystem: "FitSync", category: "sync")

struct SyncReport: Sendable {
    let startedAt: Date
    var finishedAt = Date()
    var fetched: [String: Int] = [:]
    var written = 0
    var workouts = 0
    var unchanged = 0
    var deleted = 0
    var failures: [String] = []
    var isComplete: Bool { failures.isEmpty }
}

/// The single entry point for every sync. Being an actor, and joining an in-flight sync
/// instead of starting a second one, means repeated taps on the Sync button can never
/// run two syncs at the same time (a classic cause of double writes).
actor SyncEngine {
    static let initialBackfillDays = 30
    private static let ledgerRetentionDays = 120
    private static let retiredCleanupKey = "retiredTypesCleanupDone.v2" // bump when retiredTypes grows

    private let client: GoogleHealthClient
    private let writer: HealthKitWriter
    private let ledger: LedgerStore
    private var inFlight: Task<SyncReport, Error>?

    init(client: GoogleHealthClient, writer: HealthKitWriter, ledger: LedgerStore) {
        self.client = client
        self.writer = writer
        self.ledger = ledger
    }

    /// `progress` receives short status lines ("Fetching from Google Health…") for the UI.
    func sync(lookbackDays: Int,
              progress: @escaping @Sendable (String) -> Void = { _ in }) async throws -> SyncReport {
        if let inFlight { return try await inFlight.value }
        let task = Task { try await self.perform(lookbackDays: lookbackDays, progress: progress) }
        inFlight = task
        defer { inFlight = nil }
        return try await task.value
    }

    private func perform(lookbackDays: Int,
                         progress: @Sendable (String) -> Void) async throws -> SyncReport {
        let now = Date()
        var report = SyncReport(startedAt: now)

        let days = max(1, lookbackDays)
        let since = Calendar.current.startOfDay(for: now.addingTimeInterval(-Double(days) * 86_400))

        // 1. Fetch all types at once. Each is independent; a failure skips deletions for this run.
        progress("Fetching from Google Health…")
        var data = FetchedData()
        var firstError: Error?
        let client = self.client
        await withTaskGroup(of: (GHDataType, Result<[DataPoint], Error>).self) { group in
            for type in GHDataType.allCases {
                group.addTask {
                    do { return (type, .success(try await client.list(type, since: since))) }
                    catch { return (type, .failure(error)) }
                }
            }
            for await (type, result) in group {
                switch result {
                case let .success(points):
                    data.set(type, points)
                    report.fetched[type.rawValue] = points.count
                case let .failure(error):
                    firstError = firstError ?? error
                    report.failures.append("\(type.rawValue): \(error.localizedDescription)")
                }
            }
        }
        report.failures.sort()
        if report.fetched.isEmpty, let firstError { throw firstError }

        // One-time: remove what FitSync wrote of types it no longer syncs (HealthKitWriter.retiredTypes).
        if !UserDefaults.standard.bool(forKey: Self.retiredCleanupKey) {
            progress("Removing data FitSync no longer syncs…")
            do {
                let removed = try await writer.deleteRetiredTypes()
                syncLog.notice("deleted \(removed) objects of retired types")
                UserDefaults.standard.set(true, forKey: Self.retiredCleanupKey)
            } catch {
                syncLog.error("retired cleanup failed, retrying next sync: \(error.localizedDescription, privacy: .public)")
            }
        }

        // 2. Plan the exact target state and compare with what was written before.
        progress("Comparing with previous syncs…")
        let records = Planner.plan(data)
        let earliest = records.map(\.start).min() ?? since
        let previous = try await ledger.state(since: min(earliest, since))
        let plan = ChangeDetector.plan(records, ledger: previous)
        report.unchanged = plan.unchangedCount

        syncLog.notice("fetched \(report.fetched.description, privacy: .public), failures \(report.failures.description, privacy: .public)")
        for p in data.exercises {
            let kcal = p.exercise?.metricsSummary?.caloriesKcal?.value
            syncLog.notice("exercise \(p.id, privacy: .public) platform=\(p.dataSource?.platform ?? "nil", privacy: .public) summaryKcal=\(kcal.map { "\($0)" } ?? "nil", privacy: .public)")
        }
        syncLog.notice("planned \(records.count) records, \(plan.standalone.count) standalone + \(plan.workouts.count) workouts to write, \(plan.unchangedCount) unchanged")
        for (w, kids) in plan.workouts {
            syncLog.notice("workout \(w.syncId, privacy: .public) children: \(kids.map { "\($0.syncId)=\($0.payload.canonical)" }.description, privacy: .public)")
        }

        func stamp(_ r: Record) -> (record: Record, version: Int64) {
            (r, ChangeDetector.nextVersion(previous: previous[r.syncId]?.version, now: now))
        }

        // 3. Write standalone samples. The ledger is updated only after HealthKit confirms.
        for chunk in plan.standalone.chunked(into: 500) {
            progress("Writing \(report.written + chunk.count) of \(plan.standalone.count)…")
            let stamped = chunk.map(stamp)
            try await writer.saveStandalone(stamped)
            try await ledger.upsert(stamped)
            report.written += stamped.count
        }

        // 4. (Re)build workouts with their attached energy/distance samples.
        for (workout, children) in plan.workouts {
            progress("Building workout \(report.workouts + 1) of \(plan.workouts.count)…")
            let w = stamp(workout)
            let kids = children.map(stamp)
            try await writer.saveWorkout(w.record, version: w.version, children: kids)
            try await ledger.upsert([w] + kids)
            report.workouts += 1
            report.written += 1 + kids.count
        }

        // 5. Remove what disappeared from Google — only when every fetch succeeded,
        //    otherwise a failed fetch would look like "everything was deleted".
        if report.failures.isEmpty {
            progress("Cleaning up…")
            let removed = try await writer.deleteOrphans(since: since, keep: Set(records.map(\.syncId)))
            try await ledger.remove(removed)
            report.deleted = removed.count
            try await ledger.prune(olderThan: now.addingTimeInterval(-Double(Self.ledgerRetentionDays) * 86_400))
        }

        report.finishedAt = Date()
        return report
    }
}
