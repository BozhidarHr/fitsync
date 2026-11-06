import Foundation
import HealthKit

/// The only place that touches HealthKit. Every object it writes carries
/// HKMetadataKeySyncIdentifier + HKMetadataKeySyncVersion, so writing the same record
/// again REPLACES the earlier copy instead of adding a second one.
final class HealthKitWriter: @unchecked Sendable { // HKHealthStore is thread-safe
    let store = HKHealthStore()

    private static let quantityTypes: [HKQuantityTypeIdentifier] = [
        .activeEnergyBurned, .stepCount, .distanceWalkingRunning, .distanceCycling,
    ]

    /// Types FitSync used to write and no longer does: Google Health's own Apple Health
    /// sharing writes workouts and heart rate, so FitSync's copies showed twice; resting
    /// energy was dropped because Google serves none.
    private static let retiredTypes: [HKSampleType] = [
        HKObjectType.workoutType(), HKQuantityType(.heartRate), HKQuantityType(.basalEnergyBurned),
    ]

    var writeTypes: Set<HKSampleType> {
        var set: Set<HKSampleType> = Set(Self.quantityTypes.map { HKQuantityType($0) })
        set.insert(HKCategoryType(.sleepAnalysis))
        return set
    }

    /// Read access lets FitSync find its own samples for updates and deletions.
    var readTypes: Set<HKObjectType> { Set(writeTypes.map { $0 as HKObjectType }) }

    enum Access { case full, notAsked, denied }

    /// `.notAsked` only when iOS will really show the permission sheet for a request;
    /// otherwise `.denied` if any write access is off (fixable only in Settings).
    /// Read access can't be checked (HealthKit hides it), so this covers writing only.
    func access() async -> Access {
        guard HKHealthStore.isHealthDataAvailable() else { return .full }
        if (try? await store.statusForAuthorizationRequest(toShare: writeTypes, read: readTypes)) == .shouldRequest {
            return .notAsked
        }
        let statuses = writeTypes.map { store.authorizationStatus(for: $0) }
        return statuses.allSatisfy { $0 == .sharingAuthorized } ? .full : .denied
    }

    // MARK: Writing

    func saveStandalone(_ items: [(record: Record, version: Int64)]) async throws {
        for chunk in items.chunked(into: 500) {
            let objects: [HKObject] = chunk.compactMap { makeSample($0.record, version: $0.version) }
            if !objects.isEmpty { try await store.save(objects) }
        }
    }

    /// Builds (or rebuilds) a workout with its energy/distance samples attached, so the
    /// calories count toward Active Energy and the Move ring.
    func saveWorkout(_ workout: Record, version: Int64, children: [(record: Record, version: Int64)]) async throws {
        guard case let .workout(activity, title) = workout.payload else { return }
        let config = HKWorkoutConfiguration()
        config.activityType = Self.activityType(activity)
        config.locationType = .unknown

        let builder = HKWorkoutBuilder(healthStore: store, configuration: config, device: nil)
        try await builder.beginCollection(at: workout.start)

        let samples: [HKSample] = children.compactMap { makeSample($0.record, version: $0.version) }
        if !samples.isEmpty { try await builder.addSamples(samples) }

        var metadata = Self.metadata(syncId: workout.syncId, version: version)
        if let title, !title.isEmpty { metadata["FitSyncTitle"] = title } // custom key, shown in Health's details
        try await builder.addMetadata(metadata)

        try await builder.endCollection(at: workout.end)
        let saved = try await builder.finishWorkout()
        let kcal = saved?.statistics(for: HKQuantityType(.activeEnergyBurned))?.sumQuantity()?.doubleValue(for: .kilocalorie())
        syncLog.notice("saved workout \(workout.syncId, privacy: .public): \(samples.count) samples added, HealthKit reports kcal=\(kcal.map { "\($0)" } ?? "nil", privacy: .public)")
    }

    // MARK: Deleting

    /// Deletes FitSync-written objects inside the window whose sync id is no longer produced
    /// (deleted or changed in Google Health). Never touches data from other apps.
    /// Returns the sync ids that were deleted.
    func deleteOrphans(since: Date, keep: Set<String>) async throws -> Set<String> {
        var types: [HKSampleType] = Self.quantityTypes.map { HKQuantityType($0) }
        types.append(HKCategoryType(.sleepAnalysis))

        var deleted = Set<String>()
        for type in types {
            let isSleep = type.identifier == HKCategoryTypeIdentifier.sleepAnalysis.rawValue
            // Sleep is fetched by END time, everything else by START time; match that here.
            let window = HKQuery.predicateForSamples(withStart: since, end: nil,
                                                     options: isSleep ? .strictEndDate : .strictStartDate)
            let mine = HKQuery.predicateForObjects(from: HKSource.default())
            let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [window, mine])
            let query = HKSampleQueryDescriptor(predicates: [.sample(type: type, predicate: predicate)],
                                                sortDescriptors: [])
            let samples = try await query.result(for: store)

            let orphans = samples.filter { s in
                guard let id = s.metadata?[HKMetadataKeySyncIdentifier] as? String,
                      id.hasPrefix(SyncID.prefix) else { return false }
                return !keep.contains(id)
            }
            for chunk in orphans.chunked(into: 500) {
                try await store.delete(chunk)
                chunk.compactMap { $0.metadata?[HKMetadataKeySyncIdentifier] as? String }.forEach { deleted.insert($0) }
            }
        }
        return deleted
    }

    /// Deletes every object of a retired type FitSync ever wrote (any date). Only
    /// FitSync's own objects match, so Google Health's shared copies are kept.
    /// Returns how many objects were deleted.
    func deleteRetiredTypes() async throws -> Int {
        let mine = HKQuery.predicateForObjects(from: HKSource.default())
        var count = 0
        for type in Self.retiredTypes {
            do {
                count += try await store.deleteObjects(of: type, predicate: mine)
            } catch let error as HKError where error.code == .errorAuthorizationDenied
                                                || error.code == .errorAuthorizationNotDetermined {
                continue // never allowed to write this type, so nothing of ours to remove
            }
        }
        return count
    }

    // MARK: Mapping

    private func makeSample(_ r: Record, version: Int64) -> HKSample? {
        let meta = Self.metadata(syncId: r.syncId, version: version)
        switch r.payload {
        case let .quantity(kind, value):
            let (id, unit) = Self.quantityType(kind)
            return HKQuantitySample(type: HKQuantityType(id), quantity: HKQuantity(unit: unit, doubleValue: value),
                                    start: r.start, end: r.end, metadata: meta)
        case let .sleep(stage):
            return HKCategorySample(type: HKCategoryType(.sleepAnalysis), value: Self.sleepValue(stage).rawValue,
                                    start: r.start, end: r.end, metadata: meta)
        case .workout:
            return nil // built by saveWorkout
        }
    }

    private static func metadata(syncId: String, version: Int64) -> [String: Any] {
        [
            HKMetadataKeySyncIdentifier: syncId,
            HKMetadataKeySyncVersion: NSNumber(value: version),
            HKMetadataKeyExternalUUID: syncId,
            HKMetadataKeyWasUserEntered: false,
        ]
    }

    private static func quantityType(_ q: Record.Quantity) -> (HKQuantityTypeIdentifier, HKUnit) {
        switch q {
        case .activeEnergy: return (.activeEnergyBurned, .kilocalorie())
        case .steps: return (.stepCount, .count())
        case .distanceWalkingRunning: return (.distanceWalkingRunning, .meter())
        case .distanceCycling: return (.distanceCycling, .meter())
        }
    }

    private static func sleepValue(_ s: Record.SleepStage) -> HKCategoryValueSleepAnalysis {
        switch s {
        case .awake: return .awake
        case .core: return .asleepCore
        case .deep: return .asleepDeep
        case .rem: return .asleepREM
        case .unspecified: return .asleepUnspecified
        }
    }

    static func activityType(_ googleType: String) -> HKWorkoutActivityType {
        let t = googleType.uppercased()
        switch true {
        case t.contains("RUN"), t.contains("TREADMILL"): return .running
        case t.contains("WALK"): return .walking
        case t.contains("HIK"): return .hiking
        case t.contains("BIK"), t.contains("CYCL"), t.contains("SPIN"): return .cycling
        case t.contains("SWIM"): return .swimming
        case t.contains("YOGA"): return .yoga
        case t.contains("PILATES"): return .pilates
        case t.contains("ELLIPTICAL"): return .elliptical
        case t.contains("ROW"): return .rowing
        case t.contains("WEIGHT"), t.contains("STRENGTH"): return .traditionalStrengthTraining
        case t.contains("HIIT"), t.contains("INTERVAL"): return .highIntensityIntervalTraining
        case t.contains("TENNIS"): return .tennis
        case t.contains("SOCCER"), t.contains("FOOTBALL"): return .soccer
        case t.contains("AEROBIC"), t.contains("CARDIO"): return .mixedCardio
        default: return .other
        }
    }
}

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}
