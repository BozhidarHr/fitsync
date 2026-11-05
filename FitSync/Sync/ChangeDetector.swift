import Foundation

struct LedgerState: Sendable, Equatable {
    let contentHash: String
    let version: Int64
}

/// Decides what actually needs writing. Pure logic, covered by unit tests.
enum ChangeDetector {
    struct Plan {
        /// Samples written on their own (not part of a workout).
        var standalone: [Record] = []
        /// Workouts to (re)build, each with ALL of its children.
        var workouts: [(workout: Record, children: [Record])] = []
        /// Records whose content is identical to what was last written.
        var unchangedCount = 0
    }

    static func plan(_ records: [Record], ledger: [String: LedgerState]) -> Plan {
        var plan = Plan()
        let changed = records.filter { ledger[$0.syncId]?.contentHash != $0.contentHash }
        plan.unchangedCount = records.count - changed.count

        plan.standalone = changed.filter { $0.parentSyncId == nil && !$0.isWorkout }

        // A workout is rebuilt if it changed or any child changed. Its children are always
        // re-sent with it (new version), so HealthKit replaces old copies by sync id.
        var rebuild = Set(changed.filter(\.isWorkout).map(\.syncId))
        rebuild.formUnion(changed.compactMap(\.parentSyncId))
        for w in records where w.isWorkout && rebuild.contains(w.syncId) {
            plan.workouts.append((w, records.filter { $0.parentSyncId == w.syncId }))
        }
        return plan
    }

    /// HKMetadataKeySyncVersion: HealthKit only replaces an object when the new version is
    /// GREATER. Using epoch milliseconds keeps versions rising even if the ledger is lost
    /// (reinstall), so a re-write replaces instead of duplicating.
    static func nextVersion(previous: Int64?, now: Date) -> Int64 {
        max(Int64(now.timeIntervalSince1970 * 1000), (previous ?? 0) + 1)
    }
}
