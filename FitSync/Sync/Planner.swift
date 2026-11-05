import CryptoKit
import Foundation

/// Everything fetched from Google for one sync window.
struct FetchedData: Sendable {
    var exercises: [DataPoint] = []
    var activeEnergy: [DataPoint] = []
    var steps: [DataPoint] = []
    var heartRate: [DataPoint] = []
    var sleep: [DataPoint] = []

    mutating func set(_ type: GHDataType, _ points: [DataPoint]) {
        switch type {
        case .exercise: exercises = points
        case .activeEnergyBurned: activeEnergy = points
        case .steps: steps = points
        case .heartRate: heartRate = points
        case .sleep: sleep = points
        }
    }

    func points(_ type: GHDataType) -> [DataPoint] {
        switch type {
        case .exercise: return exercises
        case .activeEnergyBurned: return activeEnergy
        case .steps: return steps
        case .heartRate: return heartRate
        case .sleep: return sleep
        }
    }
}

/// Turns Google data points into the exact set of records that should exist in Apple Health.
/// Same input → same output (same sync ids, same hashes), which is what makes syncing idempotent.
enum Planner {
    static func plan(_ fetched: FetchedData) -> [Record] {
        // Points Google Health imported from Apple Health are already there (often
        // including FitSync's own workouts); copying them back would duplicate them.
        var data = fetched
        for type in GHDataType.allCases {
            data.set(type, fetched.points(type).filter { !$0.isFromHealthKit })
        }
        var out: [Record] = []

        // 1. Workouts define windows that active energy is attached to.
        struct Window {
            let syncId: String; let start: Date; let end: Date; let pointId: String; let exercise: Exercise
            /// The workout's own calorie total, when Google provides one.
            var summaryKcal: Double? { exercise.metricsSummary?.caloriesKcal?.value }
        }
        let windows: [Window] = data.exercises.compactMap { p in
            guard let e = p.exercise, e.interval.endTime > e.interval.startTime else { return nil }
            return Window(syncId: SyncID.make("exercise", p.id), start: e.interval.startTime,
                          end: e.interval.endTime, pointId: p.id, exercise: e)
        }
        var children: [String: [Record]] = [:]

        // 2. Active energy: written once. Samples whose midpoint falls inside a workout
        //    are never standalone: they are dropped when the workout has its own calorie
        //    total (that total is used instead), otherwise they become its children.
        for p in data.activeEnergy {
            guard let e = p.activeEnergyBurned, e.kcal.value > 0, e.interval.endTime >= e.interval.startTime else { continue }
            var r = Record(syncId: SyncID.make("active-energy", p.id),
                           start: e.interval.startTime, end: e.interval.endTime,
                           payload: .quantity(.activeEnergy, e.kcal.value))
            let mid = e.interval.startTime.addingTimeInterval(e.interval.endTime.timeIntervalSince(e.interval.startTime) / 2)
            if let w = windows.first(where: { mid >= $0.start && mid < $0.end }) {
                if let kcal = w.summaryKcal, kcal > 0 { continue }
                r.parentSyncId = w.syncId
                children[w.syncId, default: []].append(r)
            }
            out.append(r)
        }

        // 3. Workouts, with the summary calories (preferred) or the in-workout samples.
        for w in windows {
            var kids = children[w.syncId] ?? []
            let summary = w.exercise.metricsSummary

            if let kcal = w.summaryKcal, kcal > 0 {
                // Fitbit's per-minute samples undercount workouts, so the workout's own
                // total wins; the samples inside it were skipped above.
                let r = Record(syncId: SyncID.make("exercise-kcal", w.pointId), start: w.start, end: w.end,
                               payload: .quantity(.activeEnergy, kcal), parentSyncId: w.syncId)
                kids.append(r); out.append(r)
            }
            if let mm = summary?.distanceMillimeters?.value, mm > 0,
               let kind = WorkoutActivity.distanceQuantity(for: w.exercise.exerciseType) {
                // v1 writes no all-day distance, so workout distance cannot double count.
                let r = Record(syncId: SyncID.make("exercise-distance", w.pointId), start: w.start, end: w.end,
                               payload: .quantity(kind, mm / 1000), parentSyncId: w.syncId)
                kids.append(r); out.append(r)
            }

            var workout = Record(syncId: w.syncId, start: w.start, end: w.end,
                                 payload: .workout(activity: w.exercise.exerciseType ?? "OTHER",
                                                   title: w.exercise.displayName))
            workout.childrenHash = hashChildren(kids)
            out.append(workout)
        }

        // 4. Steps and heart rate: one HealthKit sample per Google data point.
        for p in data.steps {
            guard let s = p.steps, s.count.value > 0, s.interval.endTime >= s.interval.startTime else { continue }
            out.append(Record(syncId: SyncID.make("steps", p.id), start: s.interval.startTime,
                              end: s.interval.endTime, payload: .quantity(.steps, s.count.value)))
        }
        for p in data.heartRate {
            guard let h = p.heartRate, h.beatsPerMinute.value > 0 else { continue }
            let t = h.sampleTime.physicalTime
            out.append(Record(syncId: SyncID.make("heart-rate", p.id), start: t, end: t,
                              payload: .quantity(.heartRate, h.beatsPerMinute.value)))
        }

        // 5. Sleep: one category sample per stage, keyed by the stage's start time.
        for p in data.sleep {
            guard let s = p.sleep else { continue }
            let stages = s.stages ?? []
            if stages.isEmpty {
                out.append(Record(syncId: SyncID.make("sleep", p.id), start: s.interval.startTime,
                                  end: s.interval.endTime, payload: .sleep(.unspecified)))
            }
            for st in stages where st.endTime > st.startTime {
                let key = String(Int64(st.startTime.timeIntervalSince1970))
                out.append(Record(syncId: SyncID.make("sleep", p.id, key), start: st.startTime,
                                  end: st.endTime, payload: .sleep(sleepStage(st.type))))
            }
        }

        // Guard against the API returning the same point twice across pages.
        var seen = Set<String>()
        return Array(out.reversed().filter { seen.insert($0.syncId).inserted }.reversed())
    }

    static func sleepStage(_ type: String) -> Record.SleepStage {
        switch type.uppercased() {
        case "AWAKE", "RESTLESS": return .awake
        case "LIGHT": return .core
        case "DEEP": return .deep
        case "REM": return .rem
        default: return .unspecified
        }
    }

    private static func hashChildren(_ kids: [Record]) -> String {
        let joined = kids.map(\.contentHash).sorted().joined(separator: ",")
        return SHA256.hash(data: Data(joined.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// Maps Google's exerciseType strings. Exact enum values are not fully documented,
/// so matching is by keyword and anything unknown becomes `.other`.
enum WorkoutActivity {
    static func distanceQuantity(for exerciseType: String?) -> Record.Quantity? {
        let t = (exerciseType ?? "").uppercased()
        if t.contains("BIK") || t.contains("CYCL") { return .distanceCycling }
        if t.contains("RUN") || t.contains("WALK") || t.contains("HIK") || t.contains("TREADMILL") { return .distanceWalkingRunning }
        return nil
    }
}
