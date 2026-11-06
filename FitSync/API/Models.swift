import Foundation

// Google Health API v4 data point shapes (only the fields FitSync uses).
// Reference: https://developers.google.com/health/reference/rest/v4/users.dataTypes.dataPoints
// Unknown fields are ignored, so new API fields never break decoding.

struct ListDataPointsResponse: Decodable {
    let dataPoints: [DataPoint]?
    let nextPageToken: String?
}

struct DataPoint: Decodable, Sendable {
    /// `users/{user}/dataTypes/{type}/dataPoints/{id}` from `list`.
    let name: String?
    /// Same resource name, as returned by `reconcile`.
    let dataPointName: String?
    let dataSource: DataSource?

    // Exactly one of these is set (the API's "data" union field).
    let steps: Steps?
    let activeEnergyBurned: ActiveEnergyBurned?
    let exercise: Exercise?
    let sleep: Sleep?

    struct DataSource: Decodable, Sendable {
        /// FITBIT, HEALTH_KIT, ...
        let platform: String?
    }

    /// Data that Google Health imported from Apple Health. Copying it back would duplicate it.
    var isFromHealthKit: Bool { dataSource?.platform == "HEALTH_KIT" }

    /// Stable id of this point; the basis of every HealthKit sync identifier.
    /// Derived points (e.g. Fitbit's per-minute active energy) come without a name,
    /// so they are keyed by source platform + start time instead.
    var id: String {
        if let full = name ?? dataPointName, !full.isEmpty {
            return full.split(separator: "/").last.map(String.init) ?? full
        }
        let ms = startTime.map { String(Int64($0.timeIntervalSince1970 * 1000)) } ?? "unknown"
        return "\((dataSource?.platform ?? "unknown").lowercased())-\(ms)"
    }

    private var startTime: Date? {
        steps?.interval.startTime
            ?? activeEnergyBurned?.interval.startTime
            ?? exercise?.interval.startTime
            ?? sleep?.interval.startTime
    }
}

struct APIInterval: Decodable, Sendable {
    let startTime: Date
    let endTime: Date
}

struct Steps: Decodable, Sendable {
    let interval: APIInterval
    let count: FlexibleNumber
}

struct ActiveEnergyBurned: Decodable, Sendable {
    let interval: APIInterval
    let kcal: FlexibleNumber
}

struct Exercise: Decodable, Sendable {
    let interval: APIInterval
    let exerciseType: String?
    let displayName: String?
    let metricsSummary: MetricsSummary?

    struct MetricsSummary: Decodable, Sendable {
        let caloriesKcal: FlexibleNumber?
        let distanceMillimeters: FlexibleNumber?
        let steps: FlexibleNumber?
        let averageHeartRateBeatsPerMinute: FlexibleNumber?
    }
}

struct Sleep: Decodable, Sendable {
    let interval: APIInterval
    let stages: [Stage]?

    struct Stage: Decodable, Sendable {
        let startTime: Date
        let endTime: Date
        /// AWAKE, LIGHT, DEEP, REM, ASLEEP, RESTLESS
        let type: String
    }
}

/// The API sends int64 values as JSON strings ("1234") and doubles as numbers.
struct FlexibleNumber: Decodable, Sendable, Equatable {
    let value: Double

    init(_ value: Double) { self.value = value }

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let d = try? c.decode(Double.self) {
            value = d
        } else if let s = try? c.decode(String.self), let d = Double(s) {
            value = d
        } else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "Expected a number or numeric string")
        }
    }
}

// MARK: - Dates

enum APIDate {
    /// RFC 3339 with 0, 3, 6 or 9 fractional digits, Z-normalized.
    static func parse(_ string: String) -> Date? {
        var s = string
        // ISO8601DateFormatter handles at most millisecond precision; trim extra digits.
        if let dot = s.firstIndex(of: "."),
           let end = s[dot...].firstIndex(where: { $0 == "Z" || $0 == "+" || $0 == "-" }) {
            let fraction = s[s.index(after: dot)..<end]
            s.replaceSubrange(s.index(after: dot)..<end, with: String(fraction.prefix(3)))
        }
        return withFraction.date(from: s) ?? plain.date(from: s)
    }

    static func format(_ date: Date) -> String { plain.string(from: date) }

    private static let withFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            let s = try c.decode(String.self)
            guard let date = APIDate.parse(s) else {
                throw DecodingError.dataCorruptedError(in: c, debugDescription: "Bad timestamp \(s)")
            }
            return date
        }
        return d
    }()
}
