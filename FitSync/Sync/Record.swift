import CryptoKit
import Foundation

/// A HealthKit-independent description of one object FitSync wants in Apple Health.
/// Pure value type so the planning and dedup logic is unit-testable.
struct Record: Sendable, Equatable {
    enum Quantity: String, Sendable {
        case activeEnergy      // kcal
        case steps             // count
        case distanceWalkingRunning // m
        case distanceCycling   // m
    }

    enum SleepStage: String, Sendable {
        case awake, core, deep, rem, unspecified
    }

    enum Payload: Sendable, Equatable {
        case quantity(Quantity, Double)
        case sleep(SleepStage)
        case workout(activity: String, title: String?)
    }

    /// `gh:<kind>:<google data point id>[:suffix]` — HKMetadataKeySyncIdentifier.
    let syncId: String
    let start: Date
    let end: Date
    let payload: Payload
    /// Set for samples that belong inside a workout (written with it, never on their own).
    var parentSyncId: String?
    /// For workouts: hash of the children, so a changed child rebuilds the workout.
    var childrenHash: String = ""

    /// Deterministic fingerprint of everything that ends up in HealthKit.
    var contentHash: String {
        let canonical = [
            syncId,
            String(Int64(start.timeIntervalSince1970 * 1000)),
            String(Int64(end.timeIntervalSince1970 * 1000)),
            payload.canonical,
            parentSyncId ?? "-",
            childrenHash,
        ].joined(separator: "|")
        return SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    var isWorkout: Bool {
        if case .workout = payload { return true }
        return false
    }
}

extension Record.Payload {
    var canonical: String {
        switch self {
        case let .quantity(q, v): return "q:\(q.rawValue):\(String(format: "%.4f", v))"
        case let .sleep(s): return "s:\(s.rawValue)"
        case let .workout(a, t): return "w:\(a):\(t ?? "")"
        }
    }
}

enum SyncID {
    static func make(_ kind: String, _ pointId: String, _ suffix: String? = nil) -> String {
        ["gh", kind, pointId, suffix].compactMap { $0 }.joined(separator: ":")
    }

    static let prefix = "gh:"
}
