import XCTest
@testable import FitSync

/// The core promise: syncing the same data any number of times writes nothing new.
final class DedupTests: XCTestCase {

    // MARK: Fixtures

    private func json(_ s: String) -> DataPoint {
        try! APIDate.decoder.decode(DataPoint.self, from: Data(s.utf8))
    }

    private func energy(_ id: String, _ start: String, _ end: String, _ kcal: Double) -> DataPoint {
        json(#"{"name":"users/me/dataTypes/active-energy-burned/dataPoints/\#(id)","activeEnergyBurned":{"interval":{"startTime":"\#(start)","endTime":"\#(end)"},"kcal":\#(kcal)}}"#)
    }

    private func exercise(_ id: String, _ start: String, _ end: String, kcal: Double = 300) -> DataPoint {
        json(#"{"name":"users/me/dataTypes/exercise/dataPoints/\#(id)","exercise":{"interval":{"startTime":"\#(start)","endTime":"\#(end)"},"exerciseType":"RUNNING","metricsSummary":{"caloriesKcal":\#(kcal),"distanceMillimeters":"5000000"}}}"#)
    }

    private func ledger(from records: [Record]) -> [String: LedgerState] {
        Dictionary(uniqueKeysWithValues: records.map { ($0.syncId, LedgerState(contentHash: $0.contentHash, version: 1)) })
    }

    // MARK: Tests

    func testSecondSyncWritesNothing() {
        var data = FetchedData()
        data.exercises = [exercise("run1", "2026-11-05T07:00:00Z", "2026-11-05T07:30:00Z")]
        data.activeEnergy = [
            energy("e1", "2026-11-05T06:00:00Z", "2026-11-05T06:01:00Z", 2),
            energy("e2", "2026-11-05T07:10:00Z", "2026-11-05T07:11:00Z", 12),
        ]
        let first = Planner.plan(data)
        let firstPlan = ChangeDetector.plan(first, ledger: [:])
        XCTAssertEqual(firstPlan.workouts.count, 1)

        let second = Planner.plan(data)
        XCTAssertEqual(first, second, "Planning is deterministic")
        let secondPlan = ChangeDetector.plan(second, ledger: ledger(from: first))
        XCTAssertTrue(secondPlan.standalone.isEmpty)
        XCTAssertTrue(secondPlan.workouts.isEmpty)
        XCTAssertEqual(secondPlan.unchangedCount, second.count)
    }

    func testWorkoutCaloriesAreNotCountedTwice() {
        var data = FetchedData()
        data.exercises = [exercise("run1", "2026-11-05T07:00:00Z", "2026-11-05T07:30:00Z", kcal: 300)]
        data.activeEnergy = [
            energy("outside", "2026-11-05T06:00:00Z", "2026-11-05T06:01:00Z", 2),
            energy("inside", "2026-11-05T07:10:00Z", "2026-11-05T07:11:00Z", 12),
        ]
        let records = Planner.plan(data)
        let plan = ChangeDetector.plan(records, ledger: [:])

        // The in-workout sample is a child of the workout, not standalone.
        XCTAssertEqual(plan.standalone.map(\.syncId), ["gh:active-energy:outside"])
        let children = plan.workouts.first!.children.map(\.syncId)
        XCTAssertTrue(children.contains("gh:active-energy:inside"))
        // The summary kcal fallback is NOT used when fine-grained samples exist.
        XCTAssertFalse(records.contains { $0.syncId == "gh:exercise-kcal:run1" })
    }

    func testSummaryCaloriesUsedWhenNoSamples() {
        var data = FetchedData()
        data.exercises = [exercise("run1", "2026-11-05T07:00:00Z", "2026-11-05T07:30:00Z", kcal: 300)]
        let records = Planner.plan(data)
        let kcal = records.first { $0.syncId == "gh:exercise-kcal:run1" }
        XCTAssertEqual(kcal?.payload, .quantity(.activeEnergy, 300))
        XCTAssertEqual(kcal?.parentSyncId, "gh:exercise:run1")
    }

    func testEditedValueIsRewrittenNotDuplicated() {
        var data = FetchedData()
        data.activeEnergy = [energy("e1", "2026-11-05T06:00:00Z", "2026-11-05T06:01:00Z", 2)]
        let before = Planner.plan(data)

        data.activeEnergy = [energy("e1", "2026-11-05T06:00:00Z", "2026-11-05T06:01:00Z", 3)]
        let after = Planner.plan(data)
        let plan = ChangeDetector.plan(after, ledger: ledger(from: before))

        // Same sync id → HealthKit replaces the old sample when the version is higher.
        XCTAssertEqual(plan.standalone.map(\.syncId), ["gh:active-energy:e1"])
    }

    func testVersionsAlwaysIncrease() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let v1 = ChangeDetector.nextVersion(previous: nil, now: now)
        let v2 = ChangeDetector.nextVersion(previous: v1, now: now) // same instant
        let v3 = ChangeDetector.nextVersion(previous: v2, now: now.addingTimeInterval(-3600)) // clock went back
        XCTAssertLessThan(v1, v2)
        XCTAssertLessThan(v2, v3)
    }

    func testNanosecondTimestampsParse() {
        XCTAssertNotNil(APIDate.parse("2026-11-05T07:00:00.123456789Z"))
        XCTAssertNotNil(APIDate.parse("2026-11-05T07:00:00Z"))
    }

    func testDuplicatePointsAcrossPagesCollapse() {
        var data = FetchedData()
        let e = energy("e1", "2026-11-05T06:00:00Z", "2026-11-05T06:01:00Z", 2)
        data.activeEnergy = [e, e]
        XCTAssertEqual(Planner.plan(data).count, 1)
    }
}
