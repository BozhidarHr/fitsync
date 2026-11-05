import Foundation
import SwiftData

/// One row per object FitSync has written to Apple Health.
/// The ledger is an optimisation (skip unchanged data); correctness does not depend on it,
/// because HealthKit sync identifiers prevent duplicates even if the ledger is wiped.
@Model
final class LedgerEntry {
    @Attribute(.unique) var syncId: String
    var contentHash: String
    var version: Int64
    var startDate: Date
    var updatedAt: Date

    init(syncId: String, contentHash: String, version: Int64, startDate: Date, updatedAt: Date) {
        self.syncId = syncId
        self.contentHash = contentHash
        self.version = version
        self.startDate = startDate
        self.updatedAt = updatedAt
    }
}

@ModelActor
actor LedgerStore {
    /// Ledger rows for records starting at or after `since`.
    func state(since: Date) throws -> [String: LedgerState] {
        let descriptor = FetchDescriptor<LedgerEntry>(predicate: #Predicate<LedgerEntry> { $0.startDate >= since })
        let rows = try modelContext.fetch(descriptor)
        return Dictionary(rows.map { ($0.syncId, LedgerState(contentHash: $0.contentHash, version: $0.version)) },
                          uniquingKeysWith: { a, _ in a })
    }

    /// Records what was just confirmed saved by HealthKit.
    func upsert(_ items: [(record: Record, version: Int64)]) throws {
        guard !items.isEmpty else { return }
        // Fetch only this chunk's rows; a date-range fetch reloads the whole window on every
        // chunk, which is quadratic on a 30-day backfill with heart rate.
        let ids = items.map(\.record.syncId)
        let descriptor = FetchDescriptor<LedgerEntry>(predicate: #Predicate<LedgerEntry> { ids.contains($0.syncId) })
        var existing = Dictionary(try modelContext.fetch(descriptor).map { ($0.syncId, $0) },
                                  uniquingKeysWith: { a, _ in a })
        let now = Date()
        for (record, version) in items {
            if let row = existing[record.syncId] {
                row.contentHash = record.contentHash
                row.version = version
                row.startDate = record.start
                row.updatedAt = now
            } else {
                let row = LedgerEntry(syncId: record.syncId, contentHash: record.contentHash,
                                      version: version, startDate: record.start, updatedAt: now)
                modelContext.insert(row)
                existing[record.syncId] = row
            }
        }
        try modelContext.save()
    }

    func remove(_ syncIds: Set<String>) throws {
        guard !syncIds.isEmpty else { return }
        let ids = Array(syncIds)
        try modelContext.delete(model: LedgerEntry.self, where: #Predicate<LedgerEntry> { ids.contains($0.syncId) })
        try modelContext.save()
    }

    /// Keeps the ledger small. Old data is outside every sync window anyway.
    func prune(olderThan date: Date) throws {
        try modelContext.delete(model: LedgerEntry.self, where: #Predicate<LedgerEntry> { $0.startDate < date })
        try modelContext.save()
    }
}
