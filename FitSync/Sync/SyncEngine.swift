import Foundation

enum SyncReason: String, Sendable {
    case manual, launch, background
}

struct SyncReport: Sendable {
    let reason: SyncReason
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
/// instead of starting a second one, means the button, app launch and background refresh
/// can never run two syncs at the same time (a classic cause of double writes).
actor SyncEngine {
    static let initialBackfillDays = 30
    private static let ledgerRetentionDays = 120

    private let client: GoogleHealthClient
    private let writer: HealthKitWriter
    private let ledger: LedgerStore
    private var inFlight: Task<SyncReport, Error>?

    init(client: GoogleHealthClient, writer: HealthKitWriter, ledger: LedgerStore) {
        self.client = client
        self.writer = writer
        self.ledger = ledger
    }

    /// `progress` receives short status lines ("Fetching heart-rate…") for the UI.
    func sync(reason: SyncReason, lookbackDays: Int,
              progress: @escaping @Sendable (String) -> Void = { _ in }) async throws -> SyncReport {
        if let inFlight { return try await inFlight.value }
        let task = Task { try await self.perform(reason: reason, lookbackDays: lookbackDays, progress: progress) }
        inFlight = task
        defer { inFlight = nil }
        return try await task.value
    }

    private func perform(reason: SyncReason, lookbackDays: Int,
                         progress: @Sendable (String) -> Void) async throws -> SyncReport {
        let now = Date()
        var report = SyncReport(reason: reason, startedAt: now)

        // Background tasks get ~30 s, so they only cover the last day.
        let days = reason == .background ? 1 : max(1, lookbackDays)
        let since = Calendar.current.startOfDay(for: now.addingTimeInterval(-Double(days) * 86_400))

        // 1. Fetch. Each type is independent; a failure skips deletions for this run.
        var data = FetchedData()
        var firstError: Error?
        for type in GHDataType.allCases {
            progress("Fetching \(type.rawValue)…")
            do {
                let points = try await client.list(type, since: since)
                data.set(type, points)
                report.fetched[type.rawValue] = points.count
            } catch {
                firstError = firstError ?? error
                report.failures.append("\(type.rawValue): \(error.localizedDescription)")
            }
        }
        if report.fetched.isEmpty, let firstError { throw firstError }

        // 2. Plan the exact target state and compare with what was written before.
        progress("Comparing with previous syncs…")
        let records = Planner.plan(data)
        let earliest = records.map(\.start).min() ?? since
        let previous = try await ledger.state(since: min(earliest, since))
        let plan = ChangeDetector.plan(records, ledger: previous)
        report.unchanged = plan.unchangedCount

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
