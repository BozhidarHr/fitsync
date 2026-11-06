import Foundation

enum APIError: LocalizedError {
    case http(Int, String)
    case badResponse

    var errorDescription: String? {
        switch self {
        case let .http(status, body): return "Google Health API error \(status): \(body.prefix(300))"
        case .badResponse: return "Unexpected response from Google Health API."
        }
    }
}

/// The Google Health data types FitSync reads, with the filter each one needs.
enum GHDataType: String, CaseIterable, Sendable {
    case exercise
    case activeEnergyBurned = "active-energy-burned"
    case steps
    case sleep

    /// AIP-160 filter selecting points that start (sleep: end) inside the window.
    /// Filter prefixes use the data type name in snake_case (path uses kebab-case).
    func filter(since start: Date) -> String {
        let ts = APIDate.format(start)
        switch self {
        case .exercise:
            // Session types filter on civil (local) time without a zone.
            return "exercise.interval.civil_start_time >= \"\(Self.civil(start))\""
        case .activeEnergyBurned:
            return "active_energy_burned.interval.start_time >= \"\(ts)\""
        case .steps:
            return "steps.interval.start_time >= \"\(ts)\""
        case .sleep:
            return "sleep.interval.end_time >= \"\(ts)\""
        }
    }

    /// exercise and sleep allow at most 25 per page; others up to 10000.
    var pageSize: Int {
        switch self {
        case .exercise, .sleep: return 25
        default: return 10_000
        }
    }

    private static func civil(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return f.string(from: date)
    }
}

struct GoogleHealthClient: Sendable {
    let auth: GoogleAuth
    private let base = URL(string: "https://health.googleapis.com/v4/users/me/dataTypes")!

    /// Fetches every page of `type` from `start` until now.
    func list(_ type: GHDataType, since start: Date) async throws -> [DataPoint] {
        var all: [DataPoint] = []
        var pageToken: String?
        repeat {
            var comps = URLComponents(
                url: base.appendingPathComponent(type.rawValue).appendingPathComponent("dataPoints"),
                resolvingAgainstBaseURL: false
            )!
            var items = [
                URLQueryItem(name: "filter", value: type.filter(since: start)),
                URLQueryItem(name: "pageSize", value: String(type.pageSize)),
            ]
            if let pageToken { items.append(URLQueryItem(name: "pageToken", value: pageToken)) }
            comps.queryItems = items

            let page: ListDataPointsResponse = try await get(comps.url!)
            all += page.dataPoints ?? []
            pageToken = (page.nextPageToken?.isEmpty == false) ? page.nextPageToken : nil
        } while pageToken != nil
        return all
    }

    /// GET with bearer token, retrying 429 / 5xx with exponential backoff.
    private func get<T: Decodable>(_ url: URL, attempt: Int = 0) async throws -> T {
        var req = URLRequest(url: url)
        let token = try await auth.validAccessToken()
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw APIError.badResponse }

        switch http.statusCode {
        case 200:
            return try APIDate.decoder.decode(T.self, from: data)
        case let status where (status == 429 || (500...599).contains(status)) && attempt < 4:
            let delay = UInt64(pow(2.0, Double(attempt))) * 1_000_000_000
            try await Task.sleep(nanoseconds: delay)
            return try await get(url, attempt: attempt + 1)
        default:
            throw APIError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
    }
}
